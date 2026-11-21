package main

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHealthURL(t *testing.T) {
	for listen, want := range map[string]string{
		"":               "http://127.0.0.1:8080/healthz",
		":8080":          "http://127.0.0.1:8080/healthz",
		"0.0.0.0:9000":   "http://127.0.0.1:9000/healthz",
		"127.0.0.1:7000": "http://127.0.0.1:7000/healthz",
		"[::]:8081":      "http://127.0.0.1:8081/healthz",
	} {
		if got := healthURL(listen); got != want {
			t.Errorf("%q: %s", listen, got)
		}
	}
}

func TestProbeHealth(t *testing.T) {
	status := http.StatusOK
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(status) }))
	defer server.Close()
	if err := probeHealth(server.URL+"/healthz", time.Second); err != nil {
		t.Fatalf("healthy: %v", err)
	}
	status = http.StatusServiceUnavailable
	if err := probeHealth(server.URL+"/healthz", time.Second); err == nil {
		t.Fatal("503 reported healthy")
	}
	server.Close()
	if err := probeHealth(server.URL+"/healthz", time.Second); err == nil {
		t.Fatal("closed server reported healthy")
	}
}

func TestCheckEnv(t *testing.T) {
	priv, _ := ecdh.P256().GenerateKey(rand.Reader)
	good := base64.RawURLEncoding.EncodeToString(priv.Bytes())
	zero := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	base := map[string]string{
		"RELAY_PUBLIC_HOST":  "relay.example.org",
		"RELAY_ENROLL_TOKEN": "0123456789abcdef0123456789abcdef",
	}
	run := func(extra map[string]string) (string, error) {
		values := map[string]string{}
		for k, v := range base {
			values[k] = v
		}
		for k, v := range extra {
			values[k] = v
		}
		return checkEnv(func(key string) string { return values[key] })
	}
	if summary, err := run(nil); err != nil || !strings.Contains(summary, "push off") {
		t.Fatalf("no key: %q %v", summary, err)
	}
	// Con espacios y \r alrededor (archivo editado en otro sistema) vale igual que al arrancar.
	if summary, err := run(map[string]string{"VAPID_PRIVATE_KEY": " " + good + "\r"}); err != nil ||
		!strings.Contains(summary, "push on") || strings.Contains(summary, good) {
		t.Fatalf("good key: %q %v", summary, err)
	}
	for _, bad := range []string{good[:40], good + "A", zero} {
		if _, err := run(map[string]string{"VAPID_PRIVATE_KEY": bad}); err == nil {
			t.Fatalf("bad key accepted: %q", bad)
		}
	}
	if _, err := run(map[string]string{"RELAY_ENROLL_TOKEN": "short"}); err == nil {
		t.Fatal("short token accepted")
	}
}
