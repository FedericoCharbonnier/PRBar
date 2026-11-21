// Package config lee la configuración del relay desde el entorno.
package config

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
)

// Config es todo lo que el relay necesita para arrancar.
type Config struct {
	Listen      string
	DataDir     string
	PublicHost  string
	EnrollToken string
	MaxAccounts int

	// VAPIDPrivateKey: el escalar d (32 bytes) de la clave VAPID P-256. Sin ella los pushes quedan apagados.
	VAPIDPrivateKey []byte
	VAPIDSubject    string

	// TestMode habilita WebPushTestEndpoint (un servicio de push falso para los e2e, http incluido) y los Origin
	// locales (http://127.0.0.1:* y http://localhost:*) en el WebSocket.
	TestMode            bool
	WebPushTestEndpoint string

	// TrustedProxies: solo de estas redes se acepta X-Forwarded-For (la red de Docker de Traefik).
	TrustedProxies []netip.Prefix
}

// MinEnrollTokenLength es el largo mínimo del token de inscripción.
const MinEnrollTokenLength = 32

// Load lee las variables con getenv (os.Getenv en producción).
func Load(getenv func(string) string) (Config, error) {
	get := func(key, fallback string) string {
		if v := strings.TrimSpace(getenv(key)); v != "" {
			return v
		}
		return fallback
	}
	c := Config{
		Listen:      get("RELAY_LISTEN", ":8080"),
		DataDir:     get("RELAY_DATA", "/data"),
		PublicHost:  get("RELAY_PUBLIC_HOST", ""),
		EnrollToken: get("RELAY_ENROLL_TOKEN", ""),
		TestMode:    get("RELAY_TEST_MODE", "") == "1",
	}
	if c.PublicHost == "" {
		return Config{}, errors.New("RELAY_PUBLIC_HOST is required")
	}
	c.VAPIDSubject = get("VAPID_SUBJECT", "https://"+c.PublicHost)
	if raw := get("VAPID_PRIVATE_KEY", ""); raw != "" {
		key, err := base64.RawURLEncoding.Strict().DecodeString(raw)
		if err != nil || len(key) != 32 {
			return Config{}, errors.New("VAPID_PRIVATE_KEY must be 32 bytes in base64url without padding")
		}
		c.VAPIDPrivateKey = key
	}
	if len(c.EnrollToken) < MinEnrollTokenLength {
		return Config{}, fmt.Errorf("RELAY_ENROLL_TOKEN must have at least %d characters", MinEnrollTokenLength)
	}
	maxAccounts, err := strconv.Atoi(get("RELAY_MAX_ACCOUNTS", "4"))
	if err != nil || maxAccounts < 1 || maxAccounts > 100 {
		return Config{}, errors.New("RELAY_MAX_ACCOUNTS must be a number between 1 and 100")
	}
	c.MaxAccounts = maxAccounts
	if c.TestMode {
		c.WebPushTestEndpoint = get("WEBPUSH_TEST_ENDPOINT", "")
	}
	proxies := get("RELAY_TRUSTED_PROXIES", "172.16.0.0/12,10.0.0.0/8,192.168.0.0/16")
	for _, part := range strings.Split(proxies, ",") {
		part = strings.TrimSpace(part)
		if part == "" || part == "none" {
			continue
		}
		prefix, err := netip.ParsePrefix(part)
		if err != nil {
			return Config{}, fmt.Errorf("RELAY_TRUSTED_PROXIES: %w", err)
		}
		c.TrustedProxies = append(c.TrustedProxies, prefix)
	}
	return c, nil
}

// PushConfigured dice si hay clave VAPID (la clave puede igual no ser un escalar válido de P-256).
func (c Config) PushConfigured() bool {
	return len(c.VAPIDPrivateKey) == 32
}
