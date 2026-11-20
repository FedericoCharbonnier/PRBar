// Package config lee la configuración del relay desde el entorno.
package config

import (
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

	APNsKeyFile string
	APNsKeyID   string
	APNsTeamID  string
	APNsTopic   string

	// TestMode habilita APNsEndpointOverride (los tests de integración usan un APNs falso).
	TestMode             bool
	APNsEndpointOverride string

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
		APNsKeyFile: get("APNS_KEY_FILE", "/run/secrets/apns.p8"),
		APNsKeyID:   get("APNS_KEY_ID", ""),
		APNsTeamID:  get("APNS_TEAM_ID", ""),
		APNsTopic:   get("APNS_TOPIC", ""),
		TestMode:    get("RELAY_TEST_MODE", "") == "1",
	}
	if c.PublicHost == "" {
		return Config{}, errors.New("RELAY_PUBLIC_HOST is required")
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
		c.APNsEndpointOverride = get("APNS_ENDPOINT_OVERRIDE", "")
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

// APNsConfigured dice si están los datos de APNs (la clave puede igual faltar en disco).
func (c Config) APNsConfigured() bool {
	return c.APNsKeyID != "" && c.APNsTeamID != "" && c.APNsTopic != ""
}
