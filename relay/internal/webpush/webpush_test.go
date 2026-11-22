package webpush

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func unb64(t *testing.T, s string) []byte {
	t.Helper()
	out, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		t.Fatalf("%s: %v", s, err)
	}
	return out
}

// RFC 8291, apéndice A: el cuerpo tiene que salir byte a byte igual.
func TestEncryptRFC8291AppendixA(t *testing.T) {
	plaintext := []byte("When I grow up, I want to be a watermelon")
	asPriv, err := ecdh.P256().NewPrivateKey(unb64(t, "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
	if err != nil {
		t.Fatal(err)
	}
	if got := base64.RawURLEncoding.EncodeToString(asPriv.PublicKey().Bytes()); got !=
		"BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8" {
		t.Fatalf("as public: %s", got)
	}
	uaPublic := unb64(t, "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
	authSecret := unb64(t, "BTBZMqHH6r4Tts7J_aSIgg")
	salt := unb64(t, "DGv6ra1nlYgDCS1FRnbzlw")

	body, err := encrypt(plaintext, uaPublic, authSecret, salt, asPriv)
	if err != nil {
		t.Fatal(err)
	}
	want := "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
	if got := base64.RawURLEncoding.EncodeToString(body); got != want {
		t.Fatalf("body\n got %s\nwant %s", got, want)
	}

	// Y el lado del navegador (la clave privada del UA del apéndice) lo abre.
	uaPriv, _ := ecdh.P256().NewPrivateKey(unb64(t, "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"))
	opened, err := decrypt(body, uaPriv, authSecret)
	if err != nil || string(opened) != string(plaintext) {
		t.Fatalf("decrypt: %q %v", opened, err)
	}
}

func TestEncryptRandomRoundTripAndLimits(t *testing.T) {
	uaPriv, _ := ecdh.P256().GenerateKey(rand.Reader)
	authSecret := make([]byte, 16)
	_, _ = rand.Read(authSecret)
	plaintext := bytes.Repeat([]byte("x"), MaxPayload)
	body, err := Encrypt(plaintext, uaPriv.PublicKey().Bytes(), authSecret)
	if err != nil {
		t.Fatal(err)
	}
	if len(body) > 4096 {
		t.Fatalf("body too large for push services: %d", len(body))
	}
	opened, err := decrypt(body, uaPriv, authSecret)
	if err != nil || !bytes.Equal(opened, plaintext) {
		t.Fatalf("round trip: %v", err)
	}
	if _, err := Encrypt(append(plaintext, 'y'), uaPriv.PublicKey().Bytes(), authSecret); err == nil {
		t.Fatal("accepted a payload over MaxPayload")
	}
	if _, err := Encrypt([]byte("hi"), []byte{4, 1, 2}, authSecret); err == nil {
		t.Fatal("accepted a bad p256dh")
	}
	if _, err := Encrypt([]byte("hi"), uaPriv.PublicKey().Bytes(), authSecret[:8]); err == nil {
		t.Fatal("accepted a short auth secret")
	}
}

func TestPayload(t *testing.T) {
	got, err := Payload("aa", "bb", []byte{1, 2, 0xfb})
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != `{"v":1,"e":"AQL7","c":"aa","th":"bb"}` {
		t.Fatalf("payload: %s", got)
	}
	if _, err := Payload("aa", "bb", make([]byte, 3000)); err == nil {
		t.Fatal("accepted an envelope too large for one record")
	}
}

func TestValidateSubscription(t *testing.T) {
	uaPriv, _ := ecdh.P256().GenerateKey(rand.Reader)
	p256dh := uaPriv.PublicKey().Bytes()
	auth := make([]byte, 16)
	good := []string{
		"https://web.push.apple.com/QGuQyavXutnMH",
		"https://fcm.googleapis.com/fcm/send/abc:def",
		"https://updates.push.services.mozilla.com/wpush/v2/gAAAA",
		"https://wns2-par02p.notify.windows.com/w/?token=BQYAAA",
	}
	for _, endpoint := range good {
		if err := ValidateSubscription(endpoint, p256dh, auth, ""); err != nil {
			t.Errorf("%s: %v", endpoint, err)
		}
	}
	bad := []string{
		"http://web.push.apple.com/x",                             // sin TLS
		"https://web.push.apple.com.evil.org/x",                   // otro host
		"https://evilweb.push.apple.com/x",                        // otro host
		"https://notify.windows.com/x",                            // el sufijo exige un subdominio
		"https://x.notify.windows.com.evil.org/x",                 // sufijo falso
		"https://web.push.apple.com:8443/x",                       // puerto
		"https://user@web.push.apple.com/x",                       // credenciales
		"https://127.0.0.1/x",                                     // IP
		"web.push.apple.com/x",                                    // sin esquema
		"https://web.push.apple.com/" + strings.Repeat("a", 1024), // > 1 KiB
		"",
	}
	for _, endpoint := range bad {
		if err := ValidateSubscription(endpoint, p256dh, auth, ""); err == nil {
			t.Errorf("accepted %q", endpoint)
		}
	}
	// La clave tiene que ser un punto sin comprimir de P-256 y auth 16 bytes.
	notOnCurve := append([]byte{4}, bytes.Repeat([]byte{1}, 64)...)
	if ValidateSubscription(good[0], notOnCurve, auth, "") == nil ||
		ValidateSubscription(good[0], p256dh[:33], auth, "") == nil ||
		ValidateSubscription(good[0], p256dh, auth[:15], "") == nil {
		t.Error("accepted bad keys")
	}
	// Modo test: un prefijo extra (http permitido), y solo ese prefijo.
	if err := ValidateSubscription("http://127.0.0.1:9999/push/abc", p256dh, auth, "http://127.0.0.1:9999/push/"); err != nil {
		t.Errorf("test prefix: %v", err)
	}
	if ValidateSubscription("http://127.0.0.1:9998/push/abc", p256dh, auth, "http://127.0.0.1:9999/push/") == nil {
		t.Error("accepted another local endpoint")
	}
}

func testKey(t *testing.T) []byte {
	t.Helper()
	priv, _ := ecdh.P256().GenerateKey(rand.Reader)
	return priv.Bytes()
}

// verifyJWT verifica un JWT ES256 con la pública VAPID (sin bibliotecas de JWT) y devuelve los claims.
func verifyJWT(t *testing.T, jwt string, public []byte) map[string]any {
	t.Helper()
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		t.Fatalf("jwt: %s", jwt)
	}
	var header map[string]any
	_ = json.Unmarshal(unb64(t, parts[0]), &header)
	if header["alg"] != "ES256" || header["typ"] != "JWT" {
		t.Fatalf("header: %v", header)
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), public) //nolint:staticcheck // solo para armar la pública en el test
	if x == nil {
		t.Fatal("bad public key")
	}
	pub := &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}
	sig := unb64(t, parts[2])
	if len(sig) != 64 {
		t.Fatalf("signature length %d", len(sig))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(pub, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		t.Fatal("JWT signature doesn't verify")
	}
	var claims map[string]any
	if err := json.Unmarshal(unb64(t, parts[1]), &claims); err != nil {
		t.Fatal(err)
	}
	return claims
}

func TestVAPIDJWT(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	clock := func() time.Time { return now }
	s, err := New(Options{PrivateKey: testKey(t), Subject: "mailto:ops@example.org", Now: clock})
	if err != nil {
		t.Fatal(err)
	}
	if len(s.PublicKey()) != 65 || s.PublicKey()[0] != 4 {
		t.Fatalf("public key: %x", s.PublicKey())
	}
	jwt, err := s.jwt("https://web.push.apple.com")
	if err != nil {
		t.Fatal(err)
	}
	claims := verifyJWT(t, jwt, s.PublicKey())
	if claims["aud"] != "https://web.push.apple.com" || claims["sub"] != "mailto:ops@example.org" ||
		claims["exp"] != float64(now.Add(12*time.Hour).Unix()) {
		t.Fatalf("claims: %v", claims)
	}
	// Se reusa durante una hora por audiencia; después se firma otro.
	again, _ := s.jwt("https://web.push.apple.com")
	other, _ := s.jwt("https://fcm.googleapis.com")
	if again != jwt || other == jwt {
		t.Fatal("cache per audience")
	}
	now = now.Add(61 * time.Minute)
	if later, _ := s.jwt("https://web.push.apple.com"); later == jwt {
		t.Fatal("JWT reused after an hour")
	}
}

func TestNewRejectsBadConfig(t *testing.T) {
	if _, err := New(Options{PrivateKey: []byte{1, 2, 3}, Subject: "mailto:a@b.c"}); err == nil {
		t.Fatal("accepted a short key")
	}
	if _, err := New(Options{PrivateKey: make([]byte, 32), Subject: "mailto:a@b.c"}); err == nil {
		t.Fatal("accepted a zero key")
	}
	if _, err := New(Options{PrivateKey: testKey(t), Subject: "ops@example.org"}); err == nil {
		t.Fatal("accepted a subject without mailto: or https://")
	}
}

type captured struct {
	mu      sync.Mutex
	headers http.Header
	body    []byte
	status  int
	reply   string
}

func (c *captured) handler(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.headers = r.Header.Clone()
	c.body, _ = io.ReadAll(r.Body)
	if c.reply != "" {
		w.Header().Set("content-type", "application/json")
	}
	w.WriteHeader(c.status)
	_, _ = io.WriteString(w, c.reply)
}

func TestSend(t *testing.T) {
	capture := &captured{status: http.StatusCreated}
	server := httptest.NewServer(http.HandlerFunc(capture.handler))
	defer server.Close()
	prefix := server.URL + "/push/"
	s, err := New(Options{PrivateKey: testKey(t), Subject: "https://relay.example.org", TestEndpointPrefix: prefix})
	if err != nil {
		t.Fatal(err)
	}
	uaPriv, _ := ecdh.P256().GenerateKey(rand.Reader)
	auth := make([]byte, 16)
	_, _ = rand.Read(auth)
	sub := Subscription{Endpoint: prefix + "abc", P256dh: uaPriv.PublicKey().Bytes(), Auth: auth}
	payload := []byte(`{"v":1,"e":"AQI","c":"aa","th":"bb"}`)

	collapse := strings.Repeat("0123456789abcdef", 4)
	result, err := s.Send(context.Background(), sub, collapse, payload)
	if err != nil || result.Status != http.StatusCreated {
		t.Fatalf("send: %+v %v", result, err)
	}
	capture.mu.Lock()
	h, body := capture.headers, capture.body
	capture.mu.Unlock()
	if h.Get("TTL") != "86400" || h.Get("Urgency") != "high" || h.Get("Content-Encoding") != "aes128gcm" ||
		h.Get("Content-Type") != "application/octet-stream" || h.Get("Topic") != collapse[:32] {
		t.Fatalf("headers: %v", h)
	}
	authz := h.Get("Authorization")
	k := base64.RawURLEncoding.EncodeToString(s.PublicKey())
	if !strings.HasPrefix(authz, "vapid t=") || !strings.HasSuffix(authz, ", k="+k) {
		t.Fatalf("authorization: %s", authz)
	}
	jwt := strings.TrimSuffix(strings.TrimPrefix(authz, "vapid t="), ", k="+k)
	if claims := verifyJWT(t, jwt, s.PublicKey()); claims["aud"] != server.URL {
		t.Fatalf("aud: %v", claims["aud"])
	}
	opened, err := decrypt(body, uaPriv, auth)
	if err != nil || string(opened) != string(payload) {
		t.Fatalf("the push service got %q (%v)", opened, err)
	}

	// Sin collapse no va Topic; un error del servicio trae su motivo.
	capture.mu.Lock()
	capture.status, capture.reply = http.StatusGone, `{"reason":"Unregistered"}`
	capture.mu.Unlock()
	result, err = s.Send(context.Background(), sub, "", payload)
	if err != nil || result.Status != http.StatusGone || result.Reason != "Unregistered" || !Gone(result) {
		t.Fatalf("gone: %+v %v", result, err)
	}
	if capture.headers.Get("Topic") != "" {
		t.Fatal("Topic without collapse")
	}
	if Gone(Result{Status: http.StatusTooManyRequests}) || !Gone(Result{Status: http.StatusNotFound}) {
		t.Fatal("Gone")
	}

	// Un endpoint fuera de la lista no se llama nunca.
	if _, err := s.Send(context.Background(), Subscription{Endpoint: "https://evil.example.org/x", P256dh: sub.P256dh,
		Auth: auth}, "", payload); err == nil {
		t.Fatal("sent to an endpoint outside the allowlist")
	}
}

func TestSendErrorHidesEndpoint(t *testing.T) {
	s, _ := New(Options{PrivateKey: testKey(t), Subject: "mailto:a@b.c", TestEndpointPrefix: "http://127.0.0.1:1/"})
	uaPriv, _ := ecdh.P256().GenerateKey(rand.Reader)
	_, err := s.Send(context.Background(), Subscription{Endpoint: "http://127.0.0.1:1/SECRETO",
		P256dh: uaPriv.PublicKey().Bytes(), Auth: make([]byte, 16)}, "", []byte("{}"))
	if err == nil || strings.Contains(err.Error(), "SECRETO") {
		t.Fatalf("error: %v", err)
	}
}
