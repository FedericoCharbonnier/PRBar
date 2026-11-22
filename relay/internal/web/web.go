// Package web sirve la web app del teléfono (spec W.7), embebida en el binario: `dist` es la salida de `web/`
// (`npm run build`), que el Dockerfile copia antes de compilar. En el repo hay un index.html de placeholder para que
// `go build` funcione sin node.
//
// Rutas: `/` es index.html y cualquier otro archivo de dist se sirve por su ruta; lo demás es 404 (la app rutea por
// hash, no hace falta fallback). Cada respuesta lleva la CSP y los headers de seguridad de W.7.
package web

import (
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"errors"
	"io/fs"
	"mime"
	"net/http"
	"path"
	"strings"
	"time"
)

//go:embed dist
var dist embed.FS

// Cache-Control: los assets con hash no cambian nunca; todo lo demás (index.html, sw.js, el manifest, íconos) se
// revalida siempre (con ETag) para que una versión nueva llegue en el próximo arranque.
const (
	cacheImmutable  = "public, max-age=31536000, immutable"
	cacheRevalidate = "no-cache"
)

// Tipos que no siempre están en la tabla de mime (la imagen distroless no tiene /etc/mime.types).
var contentTypes = map[string]string{
	".html":        "text/html; charset=utf-8",
	".js":          "text/javascript; charset=utf-8",
	".mjs":         "text/javascript; charset=utf-8",
	".css":         "text/css; charset=utf-8",
	".json":        "application/json",
	".webmanifest": "application/manifest+json",
	".png":         "image/png",
	".svg":         "image/svg+xml",
	".ico":         "image/x-icon",
	".webp":        "image/webp",
	".woff2":       "font/woff2",
	".txt":         "text/plain; charset=utf-8",
	".wasm":        "application/wasm",
}

type file struct {
	data        []byte
	etag        string
	contentType string
	cache       string
}

// Handler sirve los archivos ya leídos en memoria.
type Handler struct {
	files   map[string]file
	headers map[string]string
	// clearSiteData: `/sw.js` sale con `Clear-Site-Data: "cache"` (RELAY_CLEAR_SITE_DATA=1). Es para después de un
	// compromiso del VPS: con un build limpio desplegado, borra en cada teléfono la caché HTTP y la del service worker
	// que pudo haber sembrado una versión maliciosa. Se apaga una vez que los teléfonos abrieron la app.
	clearSiteData bool
}

// New arma el handler con la web embebida. publicHost es el host del relay (va en `connect-src` de la CSP).
func New(publicHost string, clearSiteData bool) (*Handler, error) {
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		return nil, err
	}
	h, err := newHandler(sub, publicHost)
	if err != nil {
		return nil, err
	}
	h.clearSiteData = clearSiteData
	return h, nil
}

func validHost(host string) bool {
	if host == "" || len(host) > 253 {
		return false
	}
	for _, c := range host {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '.' || c == ':') {
			return false
		}
	}
	return true
}

func newHandler(fsys fs.FS, publicHost string) (*Handler, error) {
	if !validHost(publicHost) {
		return nil, errors.New("web: invalid public host")
	}
	files := map[string]file{}
	err := fs.WalkDir(fsys, ".", func(name string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		data, err := fs.ReadFile(fsys, name)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(data)
		contentType := contentTypes[path.Ext(name)]
		if contentType == "" {
			contentType = mime.TypeByExtension(path.Ext(name))
		}
		if contentType == "" {
			contentType = "application/octet-stream"
		}
		cache := cacheRevalidate
		if strings.HasPrefix(name, "assets/") {
			cache = cacheImmutable
		}
		files[name] = file{data: data, etag: `"` + hex.EncodeToString(sum[:12]) + `"`, contentType: contentType,
			cache: cache}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if _, ok := files["index.html"]; !ok {
		return nil, errors.New("web: the build has no index.html")
	}
	csp := "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; " +
		"connect-src 'self' wss://" + publicHost + "; media-src 'self' blob:; worker-src 'self'; manifest-src 'self'; " +
		"frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
	return &Handler{files: files, headers: map[string]string{
		"Content-Security-Policy":   csp,
		"X-Content-Type-Options":    "nosniff",
		"Referrer-Policy":           "no-referrer",
		"Permissions-Policy":        "camera=(self)",
		"Strict-Transport-Security": "max-age=31536000",
	}}, nil
}

// lookup traduce la ruta del pedido a un archivo; rutas no canónicas ("..", "//", "/" al final) no existen.
func (h *Handler) lookup(urlPath string) (string, file, bool) {
	if urlPath == "/" {
		urlPath = "/index.html"
	}
	if !strings.HasPrefix(urlPath, "/") || path.Clean(urlPath) != urlPath {
		return "", file{}, false
	}
	name := urlPath[1:]
	f, ok := h.files[name]
	return name, f, ok
}

// ServeHTTP sirve GET y HEAD.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	header := w.Header()
	for k, v := range h.headers {
		header.Set(k, v)
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		header.Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	name, f, ok := h.lookup(r.URL.Path)
	if !ok {
		header.Set("Cache-Control", cacheRevalidate)
		http.NotFound(w, r)
		return
	}
	header.Set("Content-Type", f.contentType)
	header.Set("Cache-Control", f.cache)
	header.Set("ETag", f.etag)
	if h.clearSiteData && name == "sw.js" {
		header.Set("Clear-Site-Data", `"cache"`)
	}
	http.ServeContent(w, r, name, time.Time{}, bytes.NewReader(f.data))
}
