package webpush

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Vida del JWT de VAPID (RFC 8292 §2: a lo sumo 24 h) y cuánto se reusa el mismo por audiencia.
const (
	jwtLifetime = 12 * time.Hour
	jwtReuse    = time.Hour
)

// Options configura el Sender.
type Options struct {
	// PrivateKey: el escalar d de la clave VAPID P-256 (32 bytes, VAPID_PRIVATE_KEY en b64url).
	PrivateKey []byte
	// Subject: el contacto del operador, "mailto:…" o "https://…" (VAPID_SUBJECT).
	Subject    string
	HTTPClient *http.Client
	Now        func() time.Time
	// TestEndpointPrefix: prefijo extra permitido en la allowlist (solo RELAY_TEST_MODE).
	TestEndpointPrefix string
}

type cachedJWT struct {
	token string
	at    time.Time
}

// Sender firma (VAPID), cifra (RFC 8291) y manda pushes.
type Sender struct {
	key        *ecdsa.PrivateKey
	public     []byte
	publicB64  string
	subject    string
	http       *http.Client
	now        func() time.Time
	testPrefix string

	mu   sync.Mutex
	jwts map[string]cachedJWT
}

// New valida la clave y el subject y arma el Sender.
func New(o Options) (*Sender, error) {
	if len(o.PrivateKey) != 32 {
		return nil, errors.New("webpush: the VAPID private key must be 32 bytes")
	}
	priv, err := ecdh.P256().NewPrivateKey(o.PrivateKey)
	if err != nil {
		return nil, errors.New("webpush: invalid VAPID private key")
	}
	key, err := ecdsa.ParseRawPrivateKey(elliptic.P256(), o.PrivateKey)
	if err != nil {
		return nil, errors.New("webpush: invalid VAPID private key")
	}
	if !strings.HasPrefix(o.Subject, "mailto:") && !strings.HasPrefix(o.Subject, "https://") {
		return nil, errors.New("webpush: the VAPID subject must start with mailto: or https://")
	}
	httpClient := o.HTTPClient
	if httpClient == nil {
		// Sin seguir redirecciones: el pedido va al endpoint de la allowlist y a ningún otro lado.
		httpClient = &http.Client{Timeout: 10 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	now := o.Now
	if now == nil {
		now = time.Now
	}
	public := priv.PublicKey().Bytes()
	return &Sender{key: key, public: public, publicB64: base64.RawURLEncoding.EncodeToString(public),
		subject: o.Subject, http: httpClient, now: now, testPrefix: o.TestEndpointPrefix,
		jwts: map[string]cachedJWT{}}, nil
}

// PublicKey es la pública VAPID sin comprimir (65 bytes): la applicationServerKey del navegador.
func (s *Sender) PublicKey() []byte { return append([]byte(nil), s.public...) }

func b64(data []byte) string { return base64.RawURLEncoding.EncodeToString(data) }

// jwt devuelve el JWT ES256 para una audiencia (esquema + host del endpoint), reusado hasta una hora.
func (s *Sender) jwt(audience string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if cached, ok := s.jwts[audience]; ok && now.Sub(cached.at) < jwtReuse && !now.Before(cached.at) {
		return cached.token, nil
	}
	header, _ := json.Marshal(map[string]string{"typ": "JWT", "alg": "ES256"})
	claims, _ := json.Marshal(map[string]any{"aud": audience, "exp": now.Add(jwtLifetime).Unix(), "sub": s.subject})
	signingInput := b64(header) + "." + b64(claims)
	digest := sha256.Sum256([]byte(signingInput))
	r, sig, err := ecdsa.Sign(rand.Reader, s.key, digest[:])
	if err != nil {
		return "", err
	}
	// JOSE: r ‖ s, 32 bytes cada uno.
	raw := make([]byte, 64)
	r.FillBytes(raw[:32])
	sig.FillBytes(raw[32:])
	token := signingInput + "." + b64(raw)
	// Pocas audiencias posibles (la allowlist), pero igual se limpian las vencidas.
	for aud, cached := range s.jwts {
		if now.Sub(cached.at) >= jwtReuse {
			delete(s.jwts, aud)
		}
	}
	s.jwts[audience] = cachedJWT{token: token, at: now}
	return token, nil
}

// authorization arma el header de RFC 8292 §3: `vapid t=<jwt>, k=<pública>`.
func (s *Sender) authorization(audience string) (string, error) {
	token, err := s.jwt(audience)
	if err != nil {
		return "", err
	}
	return "vapid t=" + token + ", k=" + s.publicB64, nil
}
