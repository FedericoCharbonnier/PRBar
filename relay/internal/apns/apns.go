// Package apns manda las notificaciones a Apple (spec P.9): JWT ES256 con la clave .p8 (renovado cada 50 min),
// HTTP/2 a api.push.apple.com o api.sandbox.push.apple.com según el entorno del token. El contenido va cifrado en
// `e`; lo visible es un texto genérico.
package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// Hosts de APNs.
const (
	ProductionHost = "https://api.push.apple.com"
	SandboxHost    = "https://api.sandbox.push.apple.com"
	tokenLifetime  = 50 * time.Minute
)

// Notification es lo que manda la Mac por el relay (ya cifrado).
type Notification struct {
	Collapse string
	Thread   string
	Envelope []byte
}

// Result es la respuesta de APNs.
type Result struct {
	Status int
	Reason string
}

// Client firma y manda pushes.
type Client struct {
	keyID    string
	teamID   string
	topic    string
	key      *ecdsa.PrivateKey
	http     *http.Client
	now      func() time.Time
	override string

	mu      sync.Mutex
	token   string
	tokenAt time.Time
}

// Options configura el cliente; Endpoint reemplaza los hosts de Apple (solo tests).
type Options struct {
	KeyID      string
	TeamID     string
	Topic      string
	KeyPEM     []byte
	HTTPClient *http.Client
	Now        func() time.Time
	Endpoint   string
}

// New parsea la clave .p8 (PKCS#8, P-256) y arma el cliente.
func New(o Options) (*Client, error) {
	block, _ := pem.Decode(o.KeyPEM)
	if block == nil {
		return nil, errors.New("apns: the key isn't PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("apns: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("apns: the key isn't a P-256 ECDSA key")
	}
	if o.KeyID == "" || o.TeamID == "" || o.Topic == "" {
		return nil, errors.New("apns: key id, team id and topic are required")
	}
	httpClient := o.HTTPClient
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 10 * time.Second}
	}
	now := o.Now
	if now == nil {
		now = time.Now
	}
	return &Client{keyID: o.KeyID, teamID: o.TeamID, topic: o.Topic, key: key, http: httpClient, now: now,
		override: o.Endpoint}, nil
}

func b64(data []byte) string { return base64.RawURLEncoding.EncodeToString(data) }

// JWT devuelve el token de proveedor, reusado hasta 50 min.
func (c *Client) JWT() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.token != "" && now.Sub(c.tokenAt) < tokenLifetime {
		return c.token, nil
	}
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": c.keyID})
	claims, _ := json.Marshal(map[string]any{"iss": c.teamID, "iat": now.Unix()})
	signingInput := b64(header) + "." + b64(claims)
	digest := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", err
	}
	// JOSE: r ‖ s, 32 bytes cada uno.
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	c.token = signingInput + "." + b64(sig)
	c.tokenAt = now
	return c.token, nil
}

// Body arma el JSON del push: texto genérico, mutable-content y el sobre cifrado en `e`.
func Body(n Notification) ([]byte, error) {
	return json.Marshal(map[string]any{
		"aps": map[string]any{
			"alert":           map[string]string{"title": "PRBar", "body": "New activity on your Mac"},
			"mutable-content": 1,
			"sound":           "default",
			"thread-id":       n.Thread,
			"category":        "PR",
		},
		"e": base64.StdEncoding.EncodeToString(n.Envelope),
		"v": 1,
	})
}

// Host elige el host según el entorno del token.
func (c *Client) Host(env string) string {
	if c.override != "" {
		return c.override
	}
	if env == "production" {
		return ProductionHost
	}
	return SandboxHost
}

// Send manda un push al token del dispositivo.
func (c *Client) Send(ctx context.Context, deviceToken, env string, n Notification) (Result, error) {
	jwt, err := c.JWT()
	if err != nil {
		return Result{}, err
	}
	body, err := Body(n)
	if err != nil {
		return Result{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.Host(env)+"/3/device/"+deviceToken, bytes.NewReader(body))
	if err != nil {
		return Result{}, err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-topic", c.topic)
	req.Header.Set("apns-expiration", strconv.FormatInt(c.now().Add(24*time.Hour).Unix(), 10))
	if n.Collapse != "" {
		req.Header.Set("apns-collapse-id", n.Collapse)
	}
	req.Header.Set("content-type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return Result{}, err
	}
	defer resp.Body.Close()
	result := Result{Status: resp.StatusCode}
	if resp.StatusCode != http.StatusOK {
		var reason struct {
			Reason string `json:"reason"`
		}
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		if json.Unmarshal(raw, &reason) == nil {
			result.Reason = reason.Reason
		}
	}
	return result, nil
}

// TokenGone dice si APNs dijo que el token ya no sirve (se borra).
func TokenGone(r Result) bool {
	return r.Status == http.StatusGone || (r.Status == http.StatusBadRequest && r.Reason == "BadDeviceToken")
}
