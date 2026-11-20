package hub

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"prbar-relay/internal/apns"
	"prbar-relay/internal/auth"
	"prbar-relay/internal/store"
)

const testHost = "relay.test"
const testToken = "0123456789abcdef0123456789abcdef"

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

type fakePusher struct {
	mu     sync.Mutex
	sent   []apns.Notification
	tokens []string
	status int
	reason string
}

func (p *fakePusher) Send(_ context.Context, token, _ string, n apns.Notification) (apns.Result, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.sent = append(p.sent, n)
	p.tokens = append(p.tokens, token)
	status := p.status
	if status == 0 {
		status = http.StatusOK
	}
	return apns.Result{Status: status, Reason: p.reason}, nil
}

func (p *fakePusher) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.sent)
}

type env struct {
	t      *testing.T
	hub    *Hub
	store  *store.Store
	server *httptest.Server
	clock  *clock
	logs   *syncBuffer
	pusher *fakePusher
}

func newEnv(t *testing.T, tweak func(*Options)) *env {
	t.Helper()
	c := &clock{t: time.Unix(1_800_000_000, 0)}
	s, err := store.Open(filepath.Join(t.TempDir(), "relay.db"), 4, c.now)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	logs := &syncBuffer{}
	pusher := &fakePusher{}
	o := Options{
		PublicHost:      testHost,
		EnrollToken:     testToken,
		Store:           s,
		Log:             slog.New(slog.NewJSONHandler(logs, nil)),
		Pusher:          pusher,
		Now:             c.now,
		UpgradesPerMin:  10_000,
		FailuresToBlock: 1_000,
	}
	if tweak != nil {
		tweak(&o)
	}
	h := New(o)
	server := httptest.NewServer(h.Handler())
	t.Cleanup(server.Close)
	return &env{t: t, hub: h, store: s, server: server, clock: c, logs: logs, pusher: pusher}
}

func (e *env) enroll() (string, ed25519.PrivateKey) {
	e.t.Helper()
	pub, priv, _ := ed25519.GenerateKey(nil)
	status, body := e.post(testToken, encodeB64(pub))
	if status != http.StatusOK {
		e.t.Fatalf("enroll: %d %s", status, body)
	}
	var out struct {
		AccountID string `json:"accountId"`
	}
	if err := json.Unmarshal(body, &out); err != nil || len(out.AccountID) != accountIDLength {
		e.t.Fatalf("enroll body: %s", body)
	}
	return out.AccountID, priv
}

func (e *env) post(token, key string) (int, []byte) {
	e.t.Helper()
	body := mustJSON(map[string]string{"enrollToken": token, "macRelayKey": key})
	resp, err := http.Post(e.server.URL+"/v1/accounts", "application/json", bytes.NewReader(body))
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out bytes.Buffer
	_, _ = out.ReadFrom(resp.Body)
	return resp.StatusCode, out.Bytes()
}

type client struct {
	t  *testing.T
	ws *websocket.Conn
}

func (e *env) open() (*client, Frame, error) {
	e.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(e.server.URL, "http") + "/v1/ws"
	ws, resp, err := websocket.Dial(ctx, url, &websocket.DialOptions{Subprotocols: []string{Subprotocol}})
	if err != nil {
		if resp != nil {
			return nil, Frame{}, fmt.Errorf("http %d", resp.StatusCode)
		}
		return nil, Frame{}, err
	}
	ws.SetReadLimit(4 << 20)
	c := &client{t: e.t, ws: ws}
	challenge, err := c.read()
	if err != nil || challenge.T != "challenge" {
		return nil, Frame{}, fmt.Errorf("challenge: %v %+v", err, challenge)
	}
	return c, challenge, nil
}

// connect abre, firma el desafío con sign y devuelve el `ready` (o el error con el código de cierre).
func (e *env) connect(acct, clientID string, sign func(nonce []byte) []byte) (*client, Frame, error) {
	e.t.Helper()
	c, challenge, err := e.open()
	if err != nil {
		return nil, Frame{}, err
	}
	nonce, _ := decodeB64(challenge.Nonce)
	c.write(Frame{T: "auth", Acct: acct, Client: clientID, Sig: encodeB64(sign(nonce))})
	ready, err := c.read()
	if err != nil {
		return nil, Frame{}, err
	}
	return c, ready, nil
}

func signer(key ed25519.PrivateKey, host, acct, clientID string) func([]byte) []byte {
	return func(nonce []byte) []byte { return ed25519.Sign(key, auth.Message(host, acct, clientID, nonce)) }
}

func (e *env) mac(acct string, key ed25519.PrivateKey) *client {
	e.t.Helper()
	c, ready, err := e.connect(acct, "mac", signer(key, testHost, acct, "mac"))
	if err != nil || ready.T != "ready" || ready.Mac != "online" {
		e.t.Fatalf("mac connect: %v %+v", err, ready)
	}
	return c
}

// addDevice da de alta un dispositivo desde la Mac y espera a que esté en la base.
func (e *env) addDevice(mac *client, acct string) (string, ed25519.PrivateKey) {
	e.t.Helper()
	pub, priv, _ := ed25519.GenerateKey(nil)
	id := newID(16)
	mac.write(Frame{T: "device.add", Device: id, RelayKey: encodeB64(pub)})
	e.eventually("device stored", func() bool {
		_, ok, _ := e.store.Device(acct, id)
		return ok
	})
	return id, priv
}

func (e *env) device(acct, id string, key ed25519.PrivateKey) (*client, Frame) {
	e.t.Helper()
	c, ready, err := e.connect(acct, id, signer(key, testHost, acct, id))
	if err != nil || ready.T != "ready" {
		e.t.Fatalf("device connect: %v %+v", err, ready)
	}
	return c, ready
}

func (e *env) eventually(what string, ok func() bool) {
	e.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	e.t.Fatalf("never: %s", what)
}

func (c *client) write(f Frame) {
	c.t.Helper()
	c.writeRaw(mustJSON(f))
}

func (c *client) writeRaw(data []byte) {
	c.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.ws.Write(ctx, websocket.MessageText, data); err != nil {
		c.t.Fatalf("write: %v", err)
	}
}

func (c *client) read() (Frame, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := c.ws.Read(ctx)
	if err != nil {
		return Frame{}, err
	}
	return ParseFrame(data)
}

func (c *client) expect(t string) Frame {
	c.t.Helper()
	f, err := c.read()
	if err != nil || f.T != t {
		c.t.Fatalf("expected %s, got %+v (%v)", t, f, err)
	}
	return f
}

// closedWith lee hasta el cierre y devuelve el código.
func (c *client) closedWith() websocket.StatusCode {
	for {
		if _, err := c.read(); err != nil {
			return websocket.CloseStatus(err)
		}
	}
}

func sid() string { return strings.Repeat("ab", 8) }

// MARK: tests

func TestFramesRoundTrip(t *testing.T) {
	raw, err := os.ReadFile("testdata/frames.json")
	if err != nil {
		t.Fatal(err)
	}
	var literals []string
	if err := json.Unmarshal(raw, &literals); err != nil {
		t.Fatal(err)
	}
	if len(literals) < 20 {
		t.Fatalf("only %d frames", len(literals))
	}
	for _, literal := range literals {
		f, err := ParseFrame([]byte(literal))
		if err != nil {
			t.Fatalf("%s: %v", literal, err)
		}
		var want, got any
		_ = json.Unmarshal([]byte(literal), &want)
		_ = json.Unmarshal(mustJSON(f), &got)
		if !reflect.DeepEqual(want, got) {
			t.Errorf("round trip changed\n%s\n%s", literal, mustJSON(f))
		}
	}
}

func TestEnrollment(t *testing.T) {
	e := newEnv(t, func(o *Options) { o.FailuresToBlock = 5 })
	pub, _, _ := ed25519.GenerateKey(nil)
	if status, _ := e.post(testToken, encodeB64(pub)); status != http.StatusOK {
		t.Fatalf("good token: %d", status)
	}
	if status, _ := e.post(testToken, "short"); status != http.StatusBadRequest {
		t.Fatalf("bad key: %d", status)
	}
	for i := 0; i < 5; i++ {
		if status, _ := e.post("wrong-token", encodeB64(pub)); status != http.StatusForbidden {
			t.Fatalf("bad token %d: %d", i, status)
		}
	}
	if status, _ := e.post(testToken, encodeB64(pub)); status != http.StatusTooManyRequests {
		t.Fatalf("not blocked after 5 failures: %d", status)
	}
	e.clock.advance(14 * time.Minute)
	if status, _ := e.post(testToken, encodeB64(pub)); status != http.StatusTooManyRequests {
		t.Fatalf("unblocked too soon: %d", status)
	}
	e.clock.advance(2 * time.Minute)
	if status, _ := e.post(testToken, encodeB64(pub)); status != http.StatusOK {
		t.Fatalf("still blocked after 15 min: %d", status)
	}
	if strings.Contains(e.logs.String(), testToken) || strings.Contains(e.logs.String(), "wrong-token") {
		t.Fatal("token in the logs")
	}
}

func TestAccountLimit(t *testing.T) {
	e := newEnv(t, nil)
	for i := 0; i < 4; i++ {
		e.enroll()
	}
	pub, _, _ := ed25519.GenerateKey(nil)
	if status, _ := e.post(testToken, encodeB64(pub)); status != http.StatusConflict {
		t.Fatalf("5th account: %d", status)
	}
}

func TestAuth(t *testing.T) {
	e := newEnv(t, func(o *Options) { o.AuthTimeout = 300 * time.Millisecond })
	acct, key := e.enroll()
	mac := e.mac(acct, key)
	mac.ws.CloseNow()
	_, otherKey, _ := ed25519.GenerateKey(nil)
	otherNonce := func([]byte) []byte { return ed25519.Sign(key, auth.Message(testHost, acct, "mac", auth.NewNonce())) }
	bad := []func([]byte) []byte{
		signer(key, "evil.test", acct, "mac"),
		signer(otherKey, testHost, acct, "mac"),
		otherNonce,
	}
	for i, sign := range bad {
		if _, _, err := e.connect(acct, "mac", sign); websocket.CloseStatus(err) != CloseUnauthorized {
			t.Errorf("bad signature %d: %v", i, err)
		}
	}
	if _, _, err := e.connect(newID(16), "mac", signer(key, testHost, acct, "mac")); websocket.CloseStatus(err) != CloseUnauthorized {
		t.Errorf("unknown account: %v", err)
	}
	c, _, err := e.open()
	if err != nil {
		t.Fatal(err)
	}
	if code := c.closedWith(); code != CloseAuthTimeout {
		t.Fatalf("no auth: %d", code)
	}
}

func TestAuthLockout(t *testing.T) {
	e := newEnv(t, func(o *Options) { o.FailuresToBlock = 5 })
	acct, key := e.enroll()
	_, otherKey, _ := ed25519.GenerateKey(nil)
	for i := 0; i < 5; i++ {
		_, _, _ = e.connect(acct, "mac", signer(otherKey, testHost, acct, "mac"))
	}
	if _, _, err := e.connect(acct, "mac", signer(key, testHost, acct, "mac")); err == nil ||
		!strings.Contains(err.Error(), "429") {
		t.Fatalf("not blocked: %v", err)
	}
	e.clock.advance(16 * time.Minute)
	e.mac(acct, key)
}

func pairAuth(e *env, acct, pairing string, authKey []byte) (*client, Frame, error) {
	c, challenge, err := e.open()
	if err != nil {
		return nil, Frame{}, err
	}
	nonce, _ := decodeB64(challenge.Nonce)
	c.write(Frame{T: "auth", Acct: acct, Client: "pair", Pairing: pairing,
		Proof: encodeB64(auth.PairingProof(authKey, nonce))})
	ready, err := c.read()
	return c, ready, err
}

func TestPairingSlot(t *testing.T) {
	e := newEnv(t, nil)
	acct, key := e.enroll()
	mac := e.mac(acct, key)
	pairing := newID(10)
	authKey := bytes.Repeat([]byte{7}, 32)
	mac.write(Frame{T: "pair.open", Pairing: pairing, AuthKey: encodeB64(authKey), Expires: e.clock.now().Add(time.Hour).Unix()})
	var phone *client
	e.eventually("slot open", func() bool {
		c, ready, err := pairAuth(e, acct, pairing, authKey)
		if err != nil || ready.T != "ready" {
			return false
		}
		phone = c
		return true
	})
	// El teléfono habla con la Mac como pair:<id>; la Mac le contesta.
	phone.write(Frame{T: "send", To: "mac", Sid: sid(), B: "AQID"})
	if f := mac.expect("recv"); f.From != "pair:"+pairing || f.B != "AQID" {
		t.Fatalf("recv: %+v", f)
	}
	mac.write(Frame{T: "send", To: "pair:" + pairing, Sid: sid(), B: "BAUG"})
	if f := phone.expect("recv"); f.From != "mac" || f.B != "BAUG" {
		t.Fatalf("reply: %+v", f)
	}
	// Un segundo teléfono quema la ranura y corta al primero.
	if _, _, err := pairAuth(e, acct, pairing, authKey); websocket.CloseStatus(err) != CloseUnauthorized {
		t.Fatalf("second phone: %v", err)
	}
	if code := phone.closedWith(); code != CloseUnauthorized {
		t.Fatalf("first phone: %d", code)
	}
	if f := mac.expect("pair.close"); f.Pairing != pairing {
		t.Fatalf("mac not told: %+v", f)
	}
	// Tres proofs malos queman la ranura nueva.
	pairing2 := newID(10)
	mac.write(Frame{T: "pair.open", Pairing: pairing2, AuthKey: encodeB64(authKey), Expires: e.clock.now().Add(time.Minute).Unix()})
	e.eventually("second slot", func() bool {
		e.hub.mu.Lock()
		defer e.hub.mu.Unlock()
		a := e.hub.accounts[acct]
		return a != nil && a.slot != nil && a.slot.id == pairing2
	})
	for i := 0; i < 3; i++ {
		if _, _, err := pairAuth(e, acct, pairing2, bytes.Repeat([]byte{8}, 32)); websocket.CloseStatus(err) != CloseUnauthorized {
			t.Fatalf("bad proof %d: %v", i, err)
		}
	}
	if _, _, err := pairAuth(e, acct, pairing2, authKey); websocket.CloseStatus(err) != CloseUnauthorized {
		t.Fatalf("burned slot accepted: %v", err)
	}
	if f := mac.expect("pair.close"); f.Pairing != pairing2 {
		t.Fatalf("mac not told: %+v", f)
	}
	// Una ranura vencida no deja entrar.
	pairing3 := newID(10)
	mac.write(Frame{T: "pair.open", Pairing: pairing3, AuthKey: encodeB64(authKey), Expires: e.clock.now().Add(time.Minute).Unix()})
	e.eventually("third slot", func() bool {
		e.hub.mu.Lock()
		defer e.hub.mu.Unlock()
		a := e.hub.accounts[acct]
		return a != nil && a.slot != nil && a.slot.id == pairing3
	})
	e.clock.advance(2 * time.Minute)
	if _, _, err := pairAuth(e, acct, pairing3, authKey); websocket.CloseStatus(err) != CloseUnauthorized {
		t.Fatalf("expired slot accepted: %v", err)
	}
}

func TestRoutingPresenceAndOrder(t *testing.T) {
	e := newEnv(t, func(o *Options) {
		o.FrameRate = 1e6
		o.FrameBurst = 1e6
		o.SendQueue = 4096
	})
	acct, key := e.enroll()
	mac := e.mac(acct, key)
	d1, k1 := e.addDevice(mac, acct)
	d2, k2 := e.addDevice(mac, acct)
	phone1, ready := e.device(acct, d1, k1)
	if ready.Mac != "online" {
		t.Fatalf("ready: %+v", ready)
	}
	if f := mac.expect("presence"); f.Device != d1 || f.State != "online" {
		t.Fatalf("presence: %+v", f)
	}
	phone2, _ := e.device(acct, d2, k2)
	mac.expect("presence")
	// Teléfono → Mac, con `from`.
	phone1.write(Frame{T: "send", To: "mac", Sid: sid(), B: "AQID"})
	if f := mac.expect("recv"); f.From != d1 || f.Sid != sid() || f.B != "AQID" {
		t.Fatalf("recv: %+v", f)
	}
	// Teléfono → otro teléfono: no.
	phone1.write(Frame{T: "send", To: d2, Sid: sid(), B: "AQID"})
	if f := phone1.expect("error"); f.Reason != "forbidden" {
		t.Fatalf("error: %+v", f)
	}
	// Mac → teléfono.
	mac.write(Frame{T: "send", To: d2, Sid: sid(), B: "BAUG"})
	if f := phone2.expect("recv"); f.From != "mac" {
		t.Fatalf("to phone: %+v", f)
	}
	// FIFO con 1000 marcos.
	go func() {
		for i := 0; i < 1000; i++ {
			data := mustJSON(Frame{T: "send", To: "mac", Sid: sid(), B: encodeB64([]byte(fmt.Sprintf("%04d", i)))})
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			err := phone1.ws.Write(ctx, websocket.MessageText, data)
			cancel()
			if err != nil {
				return
			}
		}
	}()
	for i := 0; i < 1000; i++ {
		f := mac.expect("recv")
		got, _ := decodeB64(f.B)
		if string(got) != fmt.Sprintf("%04d", i) {
			t.Fatalf("order: %d got %s", i, got)
		}
	}
	// Mac offline: undeliverable y presencia a los teléfonos.
	mac.ws.Close(websocket.StatusNormalClosure, "")
	if f := phone1.expect("presence"); f.Mac != "offline" {
		t.Fatalf("presence offline: %+v", f)
	}
	phone2.expect("presence")
	phone1.write(Frame{T: "send", To: "mac", Sid: sid(), B: "AQID"})
	if f := phone1.expect("undeliverable"); f.To != "mac" || f.Sid != sid() {
		t.Fatalf("undeliverable: %+v", f)
	}
	mac = e.mac(acct, key)
	if f := phone1.expect("presence"); f.Mac != "online" {
		t.Fatalf("presence online: %+v", f)
	}
	phone2.ws.Close(websocket.StatusNormalClosure, "")
	if f := mac.expect("presence"); f.Device != d2 || f.State != "offline" {
		t.Fatalf("device offline: %+v", f)
	}
}

func TestReplacementAndRemoval(t *testing.T) {
	e := newEnv(t, nil)
	acct, key := e.enroll()
	mac := e.mac(acct, key)
	d1, k1 := e.addDevice(mac, acct)
	first, _ := e.device(acct, d1, k1)
	mac.expect("presence")
	second, _ := e.device(acct, d1, k1)
	if code := first.closedWith(); code != CloseReplaced {
		t.Fatalf("replaced: %d", code)
	}
	second.write(Frame{T: "apns", Token: strings.Repeat("ab", 32), Env: "sandbox"})
	e.eventually("token stored", func() bool {
		d, _, _ := e.store.Device(acct, d1)
		return d.APNsToken != ""
	})
	mac.write(Frame{T: "device.remove", Device: d1})
	if code := second.closedWith(); code != CloseDeviceRemoved {
		t.Fatalf("removed: %d", code)
	}
	if _, ok, _ := e.store.Device(acct, d1); ok {
		t.Fatal("device still stored")
	}
	if _, _, err := e.connect(acct, d1, signer(k1, testHost, acct, d1)); websocket.CloseStatus(err) != CloseUnauthorized {
		t.Fatalf("removed device authenticated: %v", err)
	}
	if strings.Contains(e.logs.String(), strings.Repeat("ab", 32)) {
		t.Fatal("APNs token in the logs")
	}
}

func TestLimits(t *testing.T) {
	e := newEnv(t, nil)
	acct, key := e.enroll()
	mac := e.mac(acct, key)
	mac.writeRaw(append([]byte(`{"t":"ping","b":"`), bytes.Repeat([]byte("A"), 128*1024)...))
	if code := mac.closedWith(); code != CloseTooLarge {
		t.Fatalf("large frame: %d", code)
	}
	// El reloj no avanza: 300 marcos "en el mismo instante" pasan la ráfaga de 200.
	mac = e.mac(acct, key)
	go func() {
		for i := 0; i < 300; i++ {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			err := mac.ws.Write(ctx, websocket.MessageText, []byte(`{"t":"ping"}`))
			cancel()
			if err != nil {
				return
			}
		}
	}()
	if code := mac.closedWith(); code != CloseRateLimited {
		t.Fatalf("rate: %d", code)
	}
}

func TestUpgradeLimit(t *testing.T) {
	e := newEnv(t, func(o *Options) { o.UpgradesPerMin = 10 })
	for i := 0; i < 10; i++ {
		c, _, err := e.open()
		if err != nil {
			t.Fatalf("upgrade %d: %v", i, err)
		}
		c.ws.CloseNow()
	}
	if _, _, err := e.open(); err == nil || !strings.Contains(err.Error(), "429") {
		t.Fatalf("11th upgrade: %v", err)
	}
}

func TestMailboxAndPushes(t *testing.T) {
	e := newEnv(t, nil)
	acct, key := e.enroll()
	mac := e.mac(acct, key)
	d1, k1 := e.addDevice(mac, acct)
	phone, _ := e.device(acct, d1, k1)
	mac.expect("presence")
	mac.write(Frame{T: "mbox.put", To: d1, Slot: "home", B: "AQID"})
	mac.write(Frame{T: "mbox.put", To: d1, Slot: "home", B: "BAUG"})
	e.eventually("mailbox", func() bool {
		items, _ := e.store.Mailbox(acct, d1)
		return len(items) == 1 && string(items[0].Blob) == "\x04\x05\x06"
	})
	phone.write(Frame{T: "mbox.get"})
	f := phone.expect("mbox")
	var items []MailboxItem
	if err := json.Unmarshal(f.Items, &items); err != nil || len(items) != 1 || items[0].B != "BAUG" || items[0].Slot != "home" {
		t.Fatalf("mbox: %s", f.Items)
	}
	// Push sin token: 410 sin llamar a APNs.
	push := Frame{T: "push", ID: "p0", To: d1, Collapse: strings.Repeat("a", 64), Thread: strings.Repeat("b", 32),
		B: "SECRETO-abc"}
	mac.write(push)
	if r := mac.expect("pushResult"); r.ID != "p0" || r.Status != http.StatusGone {
		t.Fatalf("no token: %+v", r)
	}
	token := strings.Repeat("cd", 32)
	phone.write(Frame{T: "apns", Token: token, Env: "production"})
	e.eventually("token", func() bool {
		d, _, _ := e.store.Device(acct, d1)
		return d.APNsToken == token
	})
	for i := 1; i <= 60; i++ {
		push.ID = fmt.Sprintf("p%d", i)
		mac.write(push)
		if r := mac.expect("pushResult"); r.Status != http.StatusOK {
			t.Fatalf("push %d: %+v", i, r)
		}
	}
	push.ID = "p61"
	mac.write(push)
	if r := mac.expect("pushResult"); r.Status != http.StatusTooManyRequests {
		t.Fatalf("61st push: %+v", r)
	}
	if e.pusher.count() != 60 {
		t.Fatalf("pushes sent: %d", e.pusher.count())
	}
	e.pusher.mu.Lock()
	first := e.pusher.sent[0]
	e.pusher.mu.Unlock()
	if first.Collapse != strings.Repeat("a", 64) || first.Thread != strings.Repeat("b", 32) {
		t.Fatalf("notification: %+v", first)
	}
	// 410 de APNs borra el token.
	e.clock.advance(2 * time.Minute)
	e.pusher.mu.Lock()
	e.pusher.status, e.pusher.reason = http.StatusGone, "Unregistered"
	e.pusher.mu.Unlock()
	push.ID = "p62"
	mac.write(push)
	if r := mac.expect("pushResult"); r.Status != http.StatusGone || r.Reason != "Unregistered" {
		t.Fatalf("gone: %+v", r)
	}
	if d, _, _ := e.store.Device(acct, d1); d.APNsToken != "" {
		t.Fatal("token not cleared after 410")
	}
	logs := e.logs.String()
	if strings.Contains(logs, "SECRETO") || strings.Contains(logs, token) || strings.Contains(logs, "BAUG") {
		t.Fatalf("content in the logs:\n%s", logs)
	}
}

func TestLogsNeverContainFrameBodies(t *testing.T) {
	e := newEnv(t, nil)
	acct, key := e.enroll()
	mac := e.mac(acct, key)
	d1, k1 := e.addDevice(mac, acct)
	phone, _ := e.device(acct, d1, k1)
	mac.expect("presence")
	phone.write(Frame{T: "send", To: "mac", Sid: sid(), B: "SECRETO-12A"})
	mac.expect("recv")
	mac.write(Frame{T: "send", To: d1, Sid: sid(), B: "SECRETO-45A"})
	phone.expect("recv")
	phone.ws.Close(websocket.StatusNormalClosure, "")
	mac.expect("presence")
	if logs := e.logs.String(); strings.Contains(logs, "SECRETO") {
		t.Fatalf("frame body in the logs:\n%s", logs)
	}
}

func TestHealthz(t *testing.T) {
	e := newEnv(t, nil)
	resp, err := http.Get(e.server.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body bytes.Buffer
	_, _ = body.ReadFrom(resp.Body)
	if resp.StatusCode != http.StatusOK || body.String() != "ok" {
		t.Fatalf("healthz: %d %s", resp.StatusCode, body.String())
	}
}

func TestClientIPTrustsOnlyTheProxyHop(t *testing.T) {
	h := New(Options{TrustedProxies: []netip.Prefix{netip.MustParsePrefix("172.16.0.0/12")}})
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "172.18.0.5:1234"
	req.Header.Set("X-Forwarded-For", "6.6.6.6, 203.0.113.9")
	if ip := h.clientIP(req); ip != "203.0.113.9" {
		t.Fatalf("proxied: %s", ip)
	}
	req.RemoteAddr = "198.51.100.7:1234"
	if ip := h.clientIP(req); ip != "198.51.100.7" {
		t.Fatalf("direct: %s", ip)
	}
}
