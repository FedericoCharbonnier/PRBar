package web

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

const host = "relay.example.org"

func testFS() fstest.MapFS {
	return fstest.MapFS{
		"index.html":              {Data: []byte("<!doctype html><title>PRBar</title>")},
		"sw.js":                   {Data: []byte("self.addEventListener('push', () => {})")},
		"manifest.webmanifest":    {Data: []byte(`{"name":"PRBar"}`)},
		"assets/index-abc123.js":  {Data: []byte("console.log(1)")},
		"assets/index-abc123.css": {Data: []byte("body{}")},
		"icon-192.png":            {Data: []byte("\x89PNG")},
	}
}

func get(t *testing.T, h http.Handler, path string, header ...string) *http.Response {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	for i := 0; i+1 < len(header); i += 2 {
		req.Header.Set(header[i], header[i+1])
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Result()
}

func body(r *http.Response) string {
	data, _ := io.ReadAll(r.Body)
	return string(data)
}

// Spec W.7, al pie de la letra.
const wantCSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; " +
	"connect-src 'self' wss://relay.example.org; media-src 'self' blob:; worker-src 'self'; manifest-src 'self'; " +
	"frame-ancestors 'none'; base-uri 'none'; form-action 'none'"

func checkSecurityHeaders(t *testing.T, path string, r *http.Response) {
	t.Helper()
	want := map[string]string{
		"Content-Security-Policy":   wantCSP,
		"X-Content-Type-Options":    "nosniff",
		"Referrer-Policy":           "no-referrer",
		"Permissions-Policy":        "camera=(self)",
		"Strict-Transport-Security": "max-age=31536000",
	}
	for k, v := range want {
		if got := r.Header.Get(k); got != v {
			t.Errorf("%s %s:\n got %q\nwant %q", path, k, got, v)
		}
	}
}

func TestServesFilesWithHeaders(t *testing.T) {
	h, err := newHandler(testFS(), host)
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		path, contentType, cache, body string
	}{
		{"/", "text/html; charset=utf-8", "no-cache", "<!doctype html><title>PRBar</title>"},
		{"/index.html", "text/html; charset=utf-8", "no-cache", "<!doctype html><title>PRBar</title>"},
		{"/sw.js", "text/javascript; charset=utf-8", "no-cache", "self.addEventListener('push', () => {})"},
		{"/manifest.webmanifest", "application/manifest+json", "no-cache", `{"name":"PRBar"}`},
		{"/assets/index-abc123.js", "text/javascript; charset=utf-8", "public, max-age=31536000, immutable", "console.log(1)"},
		{"/assets/index-abc123.css", "text/css; charset=utf-8", "public, max-age=31536000, immutable", "body{}"},
		{"/icon-192.png", "image/png", "no-cache", "\x89PNG"},
	}
	for _, c := range cases {
		r := get(t, h, c.path)
		if r.StatusCode != http.StatusOK {
			t.Errorf("%s: %d", c.path, r.StatusCode)
			continue
		}
		if got := r.Header.Get("Content-Type"); got != c.contentType {
			t.Errorf("%s content-type %q", c.path, got)
		}
		if got := r.Header.Get("Cache-Control"); got != c.cache {
			t.Errorf("%s cache-control %q", c.path, got)
		}
		if got := body(r); got != c.body {
			t.Errorf("%s body %q", c.path, got)
		}
		checkSecurityHeaders(t, c.path, r)
	}
}

func TestUnknownPathsAre404(t *testing.T) {
	h, _ := newHandler(testFS(), host)
	for _, path := range []string{"/nope", "/assets/", "/assets", "/pair", "/../index.html", "/assets/../sw.js",
		"/.well-known/x", "//index.html", "/index.html/"} {
		r := get(t, h, path)
		if r.StatusCode != http.StatusNotFound {
			t.Errorf("%s: %d", path, r.StatusCode)
		}
		checkSecurityHeaders(t, path, r)
	}
}

func TestRevalidation(t *testing.T) {
	h, _ := newHandler(testFS(), host)
	first := get(t, h, "/sw.js")
	etag := first.Header.Get("ETag")
	if etag == "" {
		t.Fatal("no ETag")
	}
	again := get(t, h, "/sw.js", "If-None-Match", etag)
	if again.StatusCode != http.StatusNotModified {
		t.Fatalf("revalidation: %d", again.StatusCode)
	}
	if other := get(t, h, "/index.html").Header.Get("ETag"); other == etag {
		t.Fatal("same ETag for different files")
	}
}

func TestHead(t *testing.T) {
	h, _ := newHandler(testFS(), host)
	req := httptest.NewRequest(http.MethodHead, "/", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || rec.Body.Len() != 0 {
		t.Fatalf("HEAD: %d %d", rec.Code, rec.Body.Len())
	}
}

func TestNeedsIndexAndHost(t *testing.T) {
	if _, err := newHandler(fstest.MapFS{"sw.js": {Data: []byte("x")}}, host); err == nil {
		t.Fatal("accepted a build without index.html")
	}
	if _, err := newHandler(testFS(), ""); err == nil {
		t.Fatal("accepted no host")
	}
	if _, err := newHandler(testFS(), "relay.example.org; script-src *"); err == nil {
		t.Fatal("accepted a host that changes the CSP")
	}
}

// El binario siempre trae algo en dist (el placeholder del repo o la web construida por el Dockerfile).
func TestEmbeddedBuild(t *testing.T) {
	h, err := New(host)
	if err != nil {
		t.Fatal(err)
	}
	r := get(t, h, "/")
	if r.StatusCode != http.StatusOK || !strings.Contains(strings.ToLower(body(r)), "<!doctype html>") {
		t.Fatalf("embedded index: %d", r.StatusCode)
	}
}
