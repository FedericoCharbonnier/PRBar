package apns

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func testKey(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return key, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

func TestJWTIsValidAndReused(t *testing.T) {
	key, keyPEM := testKey(t)
	now := time.Unix(1_800_000_000, 0)
	c, err := New(Options{KeyID: "KEYID12345", TeamID: "TEAM123456", Topic: "com.example.app", KeyPEM: keyPEM,
		Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	token, err := c.JWT()
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("jwt: %s", token)
	}
	decode := func(s string) []byte {
		raw, err := base64.RawURLEncoding.DecodeString(s)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	var header map[string]string
	var claims map[string]any
	_ = json.Unmarshal(decode(parts[0]), &header)
	_ = json.Unmarshal(decode(parts[1]), &claims)
	if header["alg"] != "ES256" || header["kid"] != "KEYID12345" {
		t.Fatalf("header: %v", header)
	}
	if claims["iss"] != "TEAM123456" || claims["iat"] != float64(1_800_000_000) {
		t.Fatalf("claims: %v", claims)
	}
	sig := decode(parts[2])
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if len(sig) != 64 || !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("signature doesn't verify")
	}
	now = now.Add(49 * time.Minute)
	if again, _ := c.JWT(); again != token {
		t.Fatal("token not reused within 50 min")
	}
	now = now.Add(2 * time.Minute)
	if again, _ := c.JWT(); again == token {
		t.Fatal("token not renewed after 50 min")
	}
}

func TestNewRejectsBadKeys(t *testing.T) {
	if _, err := New(Options{KeyID: "k", TeamID: "t", Topic: "x", KeyPEM: []byte("nope")}); err == nil {
		t.Fatal("accepted a non-PEM key")
	}
	_, keyPEM := testKey(t)
	if _, err := New(Options{KeyPEM: keyPEM}); err == nil {
		t.Fatal("accepted missing ids")
	}
}

type captured struct {
	path   string
	header http.Header
	body   []byte
}

func fakeAPNs(t *testing.T, status int, reason string) (*httptest.Server, *[]captured, *sync.Mutex) {
	t.Helper()
	var (
		mu   sync.Mutex
		seen []captured
	)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		seen = append(seen, captured{path: r.URL.Path, header: r.Header.Clone(), body: body})
		mu.Unlock()
		if r.ProtoMajor != 2 {
			t.Errorf("not HTTP/2: %s", r.Proto)
		}
		w.WriteHeader(status)
		if reason != "" {
			_, _ = w.Write([]byte(`{"reason":"` + reason + `"}`))
		}
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	t.Cleanup(server.Close)
	return server, &seen, &mu
}

func TestSendBuildsTheRequest(t *testing.T) {
	server, seen, mu := fakeAPNs(t, http.StatusOK, "")
	_, keyPEM := testKey(t)
	now := time.Unix(1_800_000_000, 0)
	c, err := New(Options{KeyID: "KEYID12345", TeamID: "TEAM123456", Topic: "com.example.app", KeyPEM: keyPEM,
		HTTPClient: server.Client(), Now: func() time.Time { return now }, Endpoint: server.URL})
	if err != nil {
		t.Fatal(err)
	}
	envelope := []byte{1, 2, 3, 250}
	result, err := c.Send(context.Background(), "abcd1234", "sandbox",
		Notification{Collapse: strings.Repeat("a", 64), Thread: strings.Repeat("b", 32), Envelope: envelope})
	if err != nil || result.Status != http.StatusOK {
		t.Fatalf("send: %+v %v", result, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(*seen) != 1 {
		t.Fatalf("requests: %d", len(*seen))
	}
	got := (*seen)[0]
	if got.path != "/3/device/abcd1234" {
		t.Fatalf("path: %s", got.path)
	}
	want := map[string]string{
		"apns-push-type":   "alert",
		"apns-priority":    "10",
		"apns-topic":       "com.example.app",
		"apns-expiration":  "1800086400",
		"apns-collapse-id": strings.Repeat("a", 64),
	}
	for name, value := range want {
		if got.header.Get(name) != value {
			t.Errorf("%s = %q, want %q", name, got.header.Get(name), value)
		}
	}
	if !strings.HasPrefix(got.header.Get("authorization"), "bearer ") {
		t.Error("no bearer token")
	}
	wantBody := `{"aps":{"alert":{"body":"New activity on your Mac","title":"PRBar"},"category":"PR","mutable-content":1,` +
		`"sound":"default","thread-id":"` + strings.Repeat("b", 32) + `"},"e":"AQID+g==","v":1}`
	if string(got.body) != wantBody {
		t.Fatalf("body:\n%s\nwant:\n%s", got.body, wantBody)
	}
}

func TestNetworkErrorsDontCarryTheToken(t *testing.T) {
	server, _, _ := fakeAPNs(t, http.StatusOK, "")
	url := server.URL
	server.Close()
	_, keyPEM := testKey(t)
	c, _ := New(Options{KeyID: "k", TeamID: "t", Topic: "x", KeyPEM: keyPEM, Endpoint: url})
	token := strings.Repeat("ef", 32)
	_, err := c.Send(context.Background(), token, "sandbox", Notification{Envelope: []byte{1}})
	if err == nil || strings.Contains(err.Error(), token) {
		t.Fatalf("error leaks the token: %v", err)
	}
}

func TestGoneTokenAndHosts(t *testing.T) {
	server, _, _ := fakeAPNs(t, http.StatusGone, "Unregistered")
	_, keyPEM := testKey(t)
	c, _ := New(Options{KeyID: "k", TeamID: "t", Topic: "x", KeyPEM: keyPEM, HTTPClient: server.Client(),
		Endpoint: server.URL})
	result, err := c.Send(context.Background(), "tok", "production", Notification{Envelope: []byte{1}})
	if err != nil || result.Status != http.StatusGone || result.Reason != "Unregistered" || !TokenGone(result) {
		t.Fatalf("gone: %+v %v", result, err)
	}
	if !TokenGone(Result{Status: 400, Reason: "BadDeviceToken"}) || TokenGone(Result{Status: 400, Reason: "Other"}) {
		t.Fatal("TokenGone")
	}
	plain, _ := New(Options{KeyID: "k", TeamID: "t", Topic: "x", KeyPEM: keyPEM})
	if plain.Host("production") != ProductionHost || plain.Host("sandbox") != SandboxHost {
		t.Fatal("hosts")
	}
}
