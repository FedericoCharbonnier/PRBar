// Package hub es el relay en sí (spec P.4): inscripción, conexiones WebSocket autenticadas, ruteo de marcos
// cifrados, presencia, buzón, ranuras de emparejamiento, pushes (Web Push, spec W.6) y límites. Nunca descifra nada
// y nunca loguea `b`, `e`, endpoints de push ni payloads.
package hub

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base32"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"prbar-relay/internal/auth"
	"prbar-relay/internal/logx"
	"prbar-relay/internal/ratelimit"
	"prbar-relay/internal/store"
	"prbar-relay/internal/webpush"
)

// Códigos de cierre (spec P.4).
const (
	CloseUnauthorized  websocket.StatusCode = 4401
	CloseDeviceRemoved websocket.StatusCode = 4403
	CloseAuthTimeout   websocket.StatusCode = 4408
	CloseReplaced      websocket.StatusCode = 4409
	CloseTooLarge      websocket.StatusCode = 4413
	CloseRateLimited   websocket.StatusCode = 4429
)

// Subprotocol es el subprotocolo de WebSocket.
const Subprotocol = "prbar-relay.v1"

// Pusher manda un push al servicio de push del navegador (webpush.Sender en producción, uno falso en los tests).
type Pusher interface {
	PublicKey() []byte
	Send(ctx context.Context, sub webpush.Subscription, collapse string, payload []byte) (webpush.Result, error)
}

// Options son los límites y dependencias del hub (los valores por defecto son los del spec P.10).
type Options struct {
	PublicHost     string
	EnrollToken    string
	Store          *store.Store
	Log            *slog.Logger
	Pusher         Pusher
	Now            func() time.Time
	TrustedProxies []netip.Prefix
	// Web sirve la web app (GET de todo lo que no es de la API). nil: solo la API.
	Web http.Handler
	// Solo RELAY_TEST_MODE: un prefijo de endpoint de push extra (http incluido) y Origin locales en el WebSocket.
	WebPushTestEndpoint string
	AllowLocalOrigins   bool

	MaxFrame         int
	FrameRate        float64
	FrameBurst       float64
	ByteRate         float64
	UpgradesPerMin   float64
	MaxConns         int
	SendQueue        int
	AuthTimeout      time.Duration
	PushesPerMin     float64
	PairingLifetime  time.Duration
	PairingAttempts  int
	FailuresToBlock  int
	FailureWindow    time.Duration
	BlockFor         time.Duration
	WriteTimeout     time.Duration
	PushTimeout      time.Duration
	MaxDevicesOnline int
}

func (o *Options) defaults() {
	setInt := func(v *int, d int) {
		if *v == 0 {
			*v = d
		}
	}
	setFloat := func(v *float64, d float64) {
		if *v == 0 {
			*v = d
		}
	}
	setDur := func(v *time.Duration, d time.Duration) {
		if *v == 0 {
			*v = d
		}
	}
	setInt(&o.MaxFrame, 128*1024)
	setFloat(&o.FrameRate, 50)
	setFloat(&o.FrameBurst, 200)
	setFloat(&o.ByteRate, 4*1024*1024)
	setFloat(&o.UpgradesPerMin, 10)
	setInt(&o.MaxConns, 64)
	setInt(&o.SendQueue, 256)
	setDur(&o.AuthTimeout, 5*time.Second)
	setFloat(&o.PushesPerMin, 60)
	setDur(&o.PairingLifetime, 5*time.Minute)
	setInt(&o.PairingAttempts, 3)
	setInt(&o.FailuresToBlock, 5)
	setDur(&o.FailureWindow, 10*time.Minute)
	setDur(&o.BlockFor, 15*time.Minute)
	setDur(&o.WriteTimeout, 10*time.Second)
	setDur(&o.PushTimeout, 15*time.Second)
	setInt(&o.MaxDevicesOnline, store.MaxDevicesPerAccount)
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Log == nil {
		o.Log = slog.New(slog.NewJSONHandler(io.Discard, nil))
	}
}

type slot struct {
	id       string
	authKey  []byte
	expires  time.Time
	failures int
	conn     *Conn
}

type account struct {
	mac      *Conn
	macSince time.Time
	devices  map[string]*Conn
	slot     *slot
}

// Hub mantiene las conexiones y rutea.
type Hub struct {
	o        Options
	mu       sync.Mutex
	accounts map[string]*account
	conns    int

	upgrades *ratelimit.Keyed
	pushes   *ratelimit.Keyed
	authFail *ratelimit.Lockout
	enroll   *ratelimit.Lockout

	frames   atomic.Int64
	pushed   atomic.Int64
	accepted atomic.Int64
}

// New crea el hub.
func New(o Options) *Hub {
	o.defaults()
	return &Hub{
		o:        o,
		accounts: map[string]*account{},
		upgrades: ratelimit.NewKeyed(o.UpgradesPerMin/60, o.UpgradesPerMin, o.Now),
		pushes:   ratelimit.NewKeyed(o.PushesPerMin/60, o.PushesPerMin, o.Now),
		authFail: ratelimit.NewLockout(o.FailuresToBlock, o.FailureWindow, o.BlockFor, o.Now),
		enroll:   ratelimit.NewLockout(o.FailuresToBlock, o.FailureWindow, o.BlockFor, o.Now),
	}
}

// Handler devuelve las rutas: GET /healthz, POST /v1/accounts, GET /v1/vapid, GET /v1/ws y, si hay Web, la web app
// en el resto de los GET.
func (h *Hub) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("content-type", "text/plain")
		_, _ = io.WriteString(w, "ok")
	})
	mux.HandleFunc("POST /v1/accounts", h.handleEnroll)
	mux.HandleFunc("GET /v1/vapid", h.handleVAPID)
	mux.HandleFunc("GET /v1/ws", h.handleWebSocket)
	if h.o.Web != nil {
		mux.Handle("GET /", h.o.Web)
	}
	return mux
}

// handleVAPID devuelve la pública VAPID (la applicationServerKey del navegador). 404 con los pushes apagados.
func (h *Hub) handleVAPID(w http.ResponseWriter, _ *http.Request) {
	if h.o.Pusher == nil {
		http.Error(w, "push disabled", http.StatusNotFound)
		return
	}
	w.Header().Set("content-type", "application/json")
	w.Header().Set("cache-control", "no-cache")
	_, _ = w.Write(mustJSON(map[string]string{"publicKey": encodeB64(h.o.Pusher.PublicKey())}))
}

// clientIP: la IP de la conexión, o el último salto de X-Forwarded-For si la conexión viene de un proxy de
// confianza (Traefik en la red de Docker). Nunca se confía en lo que el cliente pone antes.
func (h *Hub) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	addr = addr.Unmap()
	trusted := false
	for _, prefix := range h.o.TrustedProxies {
		if prefix.Contains(addr) {
			trusted = true
			break
		}
	}
	if !trusted {
		return addr.String()
	}
	forwarded := r.Header.Values("X-Forwarded-For")
	if len(forwarded) == 0 {
		return addr.String()
	}
	hops := strings.Split(forwarded[len(forwarded)-1], ",")
	last := strings.TrimSpace(hops[len(hops)-1])
	if parsed, err := netip.ParseAddr(last); err == nil {
		return parsed.Unmap().String()
	}
	return addr.String()
}

// MARK: inscripción (spec P.3)

var idEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

func newID(n int) string {
	raw := make([]byte, n)
	if _, err := rand.Read(raw); err != nil {
		panic(err)
	}
	return strings.ToLower(idEncoding.EncodeToString(raw))
}

func (h *Hub) handleEnroll(w http.ResponseWriter, r *http.Request) {
	ip := h.clientIP(r)
	if h.enroll.Blocked(ip) {
		http.Error(w, "too many attempts", http.StatusTooManyRequests)
		return
	}
	var body struct {
		EnrollToken string `json:"enrollToken"`
		MacRelayKey string `json:"macRelayKey"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if !auth.TokenEqual(h.o.EnrollToken, body.EnrollToken) {
		h.enroll.Fail(ip)
		h.o.Log.Warn("enroll refused", "ip", ip, "reason", "token")
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	key, err := decodeB64(body.MacRelayKey)
	if err != nil || len(key) != ed25519.PublicKeySize {
		http.Error(w, "bad key", http.StatusBadRequest)
		return
	}
	id := newID(16)
	if err := h.o.Store.CreateAccount(id, key); err != nil {
		if errors.Is(err, store.ErrTooManyAccounts) {
			http.Error(w, "account limit reached", http.StatusConflict)
			return
		}
		h.o.Log.Error("enroll failed", "err", err.Error())
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	h.o.Log.Info("account created", "acct", logx.Prefix(id), "ip", ip)
	w.Header().Set("content-type", "application/json")
	_, _ = w.Write(mustJSON(map[string]string{"accountId": id}))
}

// MARK: WebSocket

func (h *Hub) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	ip := h.clientIP(r)
	if h.authFail.Blocked(ip) || !h.upgrades.Allow(ip) {
		h.o.Log.Warn("limit", "kind", "upgrade", "ip", ip)
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}
	h.mu.Lock()
	if h.conns >= h.o.MaxConns {
		h.mu.Unlock()
		h.o.Log.Warn("limit", "kind", "connections", "ip", ip)
		http.Error(w, "busy", http.StatusServiceUnavailable)
		return
	}
	h.conns++
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		h.conns--
		h.mu.Unlock()
	}()

	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{Subprotocol}})
	if err != nil {
		return
	}
	if ws.Subprotocol() != Subprotocol {
		ws.Close(websocket.StatusPolicyViolation, "subprotocol "+Subprotocol+" required")
		return
	}
	// Sin el límite de la biblioteca (que cierra con 1009): readLoop corta con 4413 apenas pasa MaxFrame. El `auth`
	// se lee con Read y un límite propio.
	ws.SetReadLimit(-1)
	c := newConn(h, ws, ip)
	c.serve(r.Context())
}

// MARK: registro de conexiones

func (h *Hub) accountLocked(id string) *account {
	a := h.accounts[id]
	if a == nil {
		a = &account{devices: map[string]*Conn{}, macSince: h.o.Now()}
		h.accounts[id] = a
	}
	return a
}

// authenticate valida el `auth` y registra la conexión. Devuelve el `ready`.
func (h *Hub) authenticate(c *Conn, f Frame, nonce []byte) (Frame, error) {
	if f.T != "auth" || !isBase32(f.Acct, accountIDLength) {
		return Frame{}, errUnauthorized
	}
	acct, ok, err := h.o.Store.Account(f.Acct)
	if err != nil || !ok {
		return Frame{}, errUnauthorized
	}
	switch {
	case f.Client == "mac":
		sig, err := decodeB64(f.Sig)
		if err != nil || !auth.VerifySignature(acct.MacRelayKey, h.o.PublicHost, f.Acct, "mac", nonce, sig) {
			return Frame{}, errUnauthorized
		}
		return h.registerMac(c, f.Acct), nil
	case f.Client == "pair":
		return h.registerPairing(c, f, nonce)
	case isBase32(f.Client, deviceIDLength):
		device, ok, err := h.o.Store.Device(f.Acct, f.Client)
		if err != nil || !ok {
			return Frame{}, errUnauthorized
		}
		sig, err := decodeB64(f.Sig)
		if err != nil || !auth.VerifySignature(device.RelayKey, h.o.PublicHost, f.Acct, f.Client, nonce, sig) {
			return Frame{}, errUnauthorized
		}
		return h.registerDevice(c, f.Acct, f.Client), nil
	default:
		return Frame{}, errUnauthorized
	}
}

var errUnauthorized = errors.New("unauthorized")

func (h *Hub) registerMac(c *Conn, acct string) Frame {
	h.mu.Lock()
	a := h.accountLocked(acct)
	old := a.mac
	a.mac = c
	a.macSince = h.o.Now()
	c.role, c.acct = roleMac, acct
	since := a.macSince.Unix()
	devices := make([]*Conn, 0, len(a.devices))
	for _, d := range a.devices {
		devices = append(devices, d)
	}
	h.mu.Unlock()
	if old != nil {
		old.closeWith(CloseReplaced, "replaced")
	}
	for _, d := range devices {
		d.enqueue(Frame{T: "presence", Mac: "online", Since: since})
	}
	return Frame{T: "ready", Mac: "online", Since: since}
}

func (h *Hub) registerDevice(c *Conn, acct, device string) Frame {
	h.mu.Lock()
	a := h.accountLocked(acct)
	old := a.devices[device]
	a.devices[device] = c
	c.role, c.acct, c.id = roleDevice, acct, device
	mac := a.mac
	ready := Frame{T: "ready", Mac: "offline", Since: a.macSince.Unix()}
	if mac != nil {
		ready.Mac = "online"
	}
	h.mu.Unlock()
	// Gana el último (spec P.4): el anterior firmó con la misma clave, así que es el mismo dispositivo.
	if old != nil {
		old.closeWith(CloseReplaced, "replaced")
	}
	if mac != nil {
		mac.enqueue(Frame{T: "presence", Device: device, State: "online"})
	}
	_ = h.o.Store.Touch(acct, device)
	return ready
}

func (h *Hub) registerPairing(c *Conn, f Frame, nonce []byte) (Frame, error) {
	proof, err := decodeB64(f.Proof)
	if err != nil {
		return Frame{}, errUnauthorized
	}
	h.mu.Lock()
	a := h.accountLocked(f.Acct)
	s := a.slot
	if s == nil || s.id != f.Pairing || !h.o.Now().Before(s.expires) {
		h.mu.Unlock()
		return Frame{}, errUnauthorized
	}
	var burned, existing *Conn
	mac := a.mac
	if !auth.VerifyProof(s.authKey, nonce, proof) {
		s.failures++
		burnedSlot := s.failures >= h.o.PairingAttempts
		if burnedSlot {
			// Tres proofs malos queman la ranura (spec P.11).
			a.slot = nil
			burned = s.conn
		}
		h.mu.Unlock()
		if burnedSlot && mac != nil {
			mac.enqueue(Frame{T: "pair.close", Pairing: s.id})
		}
		if burned != nil {
			burned.closeWith(CloseUnauthorized, "pairing closed")
		}
		return Frame{}, errUnauthorized
	}
	if s.conn != nil {
		// Un segundo teléfono en la misma ranura: se quema (spec P.11).
		existing = s.conn
		a.slot = nil
		h.mu.Unlock()
		existing.closeWith(CloseUnauthorized, "pairing closed")
		if mac != nil {
			mac.enqueue(Frame{T: "pair.close", Pairing: s.id})
		}
		return Frame{}, errUnauthorized
	}
	s.conn = c
	c.role, c.acct, c.id = rolePair, f.Acct, s.id
	ready := Frame{T: "ready", Mac: "offline", Since: a.macSince.Unix()}
	if mac != nil {
		ready.Mac = "online"
	}
	h.mu.Unlock()
	return ready, nil
}

func (h *Hub) unregister(c *Conn) {
	h.mu.Lock()
	a := h.accounts[c.acct]
	if a == nil {
		h.mu.Unlock()
		return
	}
	var notify []*Conn
	var presence Frame
	switch c.role {
	case roleMac:
		if a.mac == c {
			a.mac = nil
			a.macSince = h.o.Now()
			presence = Frame{T: "presence", Mac: "offline", Since: a.macSince.Unix()}
			for _, d := range a.devices {
				notify = append(notify, d)
			}
		}
	case roleDevice:
		if a.devices[c.id] == c {
			delete(a.devices, c.id)
			if a.mac != nil {
				notify = append(notify, a.mac)
				presence = Frame{T: "presence", Device: c.id, State: "offline"}
			}
		}
	case rolePair:
		if a.slot != nil && a.slot.conn == c {
			a.slot.conn = nil
		}
	}
	h.mu.Unlock()
	for _, n := range notify {
		n.enqueue(presence)
	}
	if c.role == roleDevice {
		_ = h.o.Store.Touch(c.acct, c.id)
	}
}

// MARK: ruteo

func (h *Hub) route(c *Conn, f Frame) {
	if f.T == "ping" {
		c.enqueue(Frame{T: "pong"})
		return
	}
	switch c.role {
	case roleMac:
		h.fromMac(c, f)
	case roleDevice:
		h.fromDevice(c, f)
	case rolePair:
		if f.T == "send" && f.To == "mac" {
			h.toMac(c, Frame{T: "recv", From: "pair:" + c.id, Sid: f.Sid, B: f.B})
			return
		}
		c.enqueue(Frame{T: "error", Reason: "forbidden"})
	}
}

func validSend(f Frame) bool {
	if !isHex(f.Sid, sidLength) || f.B == "" {
		return false
	}
	_, err := decodeB64(f.B)
	return err == nil
}

func (h *Hub) toMac(c *Conn, f Frame) {
	if !validSend(f) {
		c.enqueue(Frame{T: "error", Reason: "bad frame"})
		return
	}
	h.mu.Lock()
	var mac *Conn
	if a := h.accounts[c.acct]; a != nil {
		mac = a.mac
	}
	h.mu.Unlock()
	if mac == nil {
		c.enqueue(Frame{T: "undeliverable", To: "mac", Sid: f.Sid})
		return
	}
	mac.enqueue(f)
}

func (h *Hub) fromDevice(c *Conn, f Frame) {
	switch f.T {
	case "send":
		// Un teléfono solo habla con su Mac.
		if f.To != "mac" {
			c.enqueue(Frame{T: "error", Reason: "forbidden"})
			return
		}
		h.toMac(c, Frame{T: "recv", From: c.id, Sid: f.Sid, B: f.B})
	case "mbox.get":
		items, err := h.o.Store.Mailbox(c.acct, c.id)
		if err != nil {
			c.enqueue(Frame{T: "error", Reason: "internal"})
			return
		}
		out := make([]MailboxItem, 0, len(items))
		for _, item := range items {
			out = append(out, MailboxItem{Slot: item.Slot, B: encodeB64(item.Blob), At: item.At.Unix()})
		}
		c.enqueue(Frame{T: "mbox", Items: mustJSON(out)})
	case "webpush":
		h.webPushSubscribe(c, f)
	default:
		c.enqueue(Frame{T: "error", Reason: "forbidden"})
	}
}

// webPushSubscribe guarda la suscripción del navegador si el endpoint está en la allowlist (spec W.6): así el relay
// nunca hace pedidos a un lugar que elija un teléfono.
func (h *Hub) webPushSubscribe(c *Conn, f Frame) {
	p256dh, err1 := decodeB64(strings.TrimRight(f.P256dh, "="))
	authSecret, err2 := decodeB64(strings.TrimRight(f.Auth, "="))
	if err1 != nil || err2 != nil ||
		webpush.ValidateSubscription(f.Endpoint, p256dh, authSecret, h.o.WebPushTestEndpoint) != nil {
		c.enqueue(Frame{T: "error", Reason: "bad subscription"})
		return
	}
	sub := store.WebPush{Endpoint: f.Endpoint, P256dh: p256dh, Auth: authSecret}
	if err := h.o.Store.SetWebPush(c.acct, c.id, sub); err != nil {
		c.enqueue(Frame{T: "error", Reason: "internal"})
		return
	}
	h.o.Log.Info("push subscription", "acct", logx.Prefix(c.acct), "device", logx.Prefix(c.id),
		"service", pushService(f.Endpoint), "endpoint", logx.TokenTag(f.Endpoint))
}

// pushService es el host del endpoint (para los logs; el resto del URL es una credencial).
func pushService(endpoint string) string {
	if u, err := url.Parse(endpoint); err == nil {
		return u.Hostname()
	}
	return ""
}

func (h *Hub) fromMac(c *Conn, f Frame) {
	switch f.T {
	case "send":
		h.macSend(c, f)
	case "push":
		h.macPush(c, f)
	case "mbox.put":
		blob, err := decodeB64(f.B)
		if err != nil || !validSlot(f.Slot) || !isBase32(f.To, deviceIDLength) {
			c.enqueue(Frame{T: "error", Reason: "bad frame"})
			return
		}
		if err := h.o.Store.PutMailbox(c.acct, f.To, f.Slot, blob); err != nil {
			c.enqueue(Frame{T: "error", Reason: "mailbox: " + mailboxReason(err)})
		}
	case "pair.open":
		h.pairOpen(c, f)
	case "pair.close":
		h.pairClose(c, f.Pairing)
	case "device.add":
		key, err := decodeB64(f.RelayKey)
		if err != nil || len(key) != ed25519.PublicKeySize || !isBase32(f.Device, deviceIDLength) {
			c.enqueue(Frame{T: "error", Reason: "bad frame"})
			return
		}
		if err := h.o.Store.AddDevice(c.acct, f.Device, key); err != nil {
			c.enqueue(Frame{T: "error", Reason: "device limit"})
			return
		}
		h.o.Log.Info("device added", "acct", logx.Prefix(c.acct), "device", logx.Prefix(f.Device))
	case "device.remove":
		h.deviceRemove(c, f.Device)
	case "devices":
		entries, err := h.o.Store.Devices(c.acct)
		if err != nil {
			c.enqueue(Frame{T: "error", Reason: "internal"})
			return
		}
		out := make([]DeviceItem, 0, len(entries))
		for _, e := range entries {
			out = append(out, DeviceItem{ID: e.ID, LastSeen: e.LastSeen.Unix()})
		}
		c.enqueue(Frame{T: "devices", Items: mustJSON(out)})
	default:
		c.enqueue(Frame{T: "error", Reason: "forbidden"})
	}
}

func mailboxReason(err error) string {
	switch {
	case errors.Is(err, store.ErrNotFound):
		return "unknown device"
	case errors.Is(err, store.ErrMailboxFull):
		return "slot limit"
	case errors.Is(err, store.ErrBlobTooLarge):
		return "too large"
	default:
		return "internal"
	}
}

func (h *Hub) macSend(c *Conn, f Frame) {
	if !validSend(f) {
		c.enqueue(Frame{T: "error", Reason: "bad frame"})
		return
	}
	var target *Conn
	h.mu.Lock()
	if a := h.accounts[c.acct]; a != nil {
		if strings.HasPrefix(f.To, "pair:") {
			if a.slot != nil && "pair:"+a.slot.id == f.To {
				target = a.slot.conn
			}
		} else {
			target = a.devices[f.To]
		}
	}
	h.mu.Unlock()
	if target == nil {
		c.enqueue(Frame{T: "undeliverable", To: f.To, Sid: f.Sid})
		return
	}
	target.enqueue(Frame{T: "recv", From: "mac", Sid: f.Sid, B: f.B})
}

func (h *Hub) pairOpen(c *Conn, f Frame) {
	key, err := decodeB64(f.AuthKey)
	if err != nil || len(key) != 32 || !isBase32(f.Pairing, pairingIDLength) {
		c.enqueue(Frame{T: "error", Reason: "bad frame"})
		return
	}
	now := h.o.Now()
	expires := time.Unix(f.Expires, 0)
	if limit := now.Add(h.o.PairingLifetime); expires.After(limit) {
		expires = limit
	}
	h.mu.Lock()
	a := h.accountLocked(c.acct)
	var old *Conn
	if a.slot != nil {
		old = a.slot.conn
	}
	a.slot = &slot{id: f.Pairing, authKey: key, expires: expires}
	h.mu.Unlock()
	if old != nil {
		old.closeWith(CloseUnauthorized, "pairing closed")
	}
}

func (h *Hub) pairClose(c *Conn, pairing string) {
	h.mu.Lock()
	var conn *Conn
	if a := h.accounts[c.acct]; a != nil && a.slot != nil && a.slot.id == pairing {
		conn = a.slot.conn
		a.slot = nil
	}
	h.mu.Unlock()
	if conn != nil {
		conn.closeWith(CloseUnauthorized, "pairing closed")
	}
}

func (h *Hub) deviceRemove(c *Conn, device string) {
	if !isBase32(device, deviceIDLength) {
		c.enqueue(Frame{T: "error", Reason: "bad frame"})
		return
	}
	if err := h.o.Store.RemoveDevice(c.acct, device); err != nil {
		c.enqueue(Frame{T: "error", Reason: "internal"})
		return
	}
	h.mu.Lock()
	var conn *Conn
	if a := h.accounts[c.acct]; a != nil {
		conn = a.devices[device]
		delete(a.devices, device)
	}
	h.mu.Unlock()
	if conn != nil {
		conn.closeWith(CloseDeviceRemoved, "removed")
	}
	h.o.Log.Info("device removed", "acct", logx.Prefix(c.acct), "device", logx.Prefix(device))
}

func (h *Hub) macPush(c *Conn, f Frame) {
	reply := func(status int, reason string) {
		c.enqueue(Frame{T: "pushResult", ID: f.ID, Status: status, Reason: reason})
	}
	envelope, err := decodeB64(f.B)
	if err != nil || len(f.ID) == 0 || len(f.ID) > 64 || len(envelope) > 4096 || !isBase32(f.To, deviceIDLength) ||
		!isHex(f.Collapse, len(f.Collapse)) || len(f.Collapse) > 64 || !isHex(f.Thread, len(f.Thread)) || len(f.Thread) > 64 {
		reply(http.StatusBadRequest, "BadFrame")
		return
	}
	payload, err := webpush.Payload(f.Collapse, f.Thread, envelope)
	if err != nil {
		reply(http.StatusRequestEntityTooLarge, "PayloadTooLarge")
		return
	}
	if h.o.Pusher == nil {
		reply(http.StatusServiceUnavailable, "PushDisabled")
		return
	}
	device, ok, err := h.o.Store.Device(c.acct, f.To)
	if err != nil || !ok || device.WebPush == nil {
		reply(http.StatusGone, "NoSubscription")
		return
	}
	// Solo cuentan los pushes que irían al servicio de push: 60 por minuto por cuenta.
	if !h.pushes.Allow(c.acct) {
		h.o.Log.Warn("limit", "kind", "push", "acct", logx.Prefix(c.acct))
		reply(http.StatusTooManyRequests, "RelayRateLimit")
		return
	}
	sub := webpush.Subscription{Endpoint: device.WebPush.Endpoint, P256dh: device.WebPush.P256dh,
		Auth: device.WebPush.Auth}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), h.o.PushTimeout)
		defer cancel()
		started := h.o.Now()
		result, err := h.o.Pusher.Send(ctx, sub, f.Collapse, payload)
		if err != nil {
			h.o.Log.Warn("push failed", "acct", logx.Prefix(c.acct), "device", logx.Prefix(f.To), "err", err.Error())
			reply(http.StatusBadGateway, "PushServiceUnreachable")
			return
		}
		h.pushed.Add(1)
		h.o.Log.Info("push", "acct", logx.Prefix(c.acct), "device", logx.Prefix(f.To), "status", result.Status,
			"reason", result.Reason, "ms", h.o.Now().Sub(started).Milliseconds(), "service", pushService(sub.Endpoint),
			"endpoint", logx.TokenTag(sub.Endpoint))
		switch {
		case webpush.Gone(result):
			// La suscripción ya no existe: se borra y la Mac recibe 410 (lo marca "Notifications off").
			_ = h.o.Store.ClearWebPush(c.acct, f.To, sub.Endpoint)
			reply(http.StatusGone, "Unsubscribed")
		case result.Status >= 200 && result.Status < 300:
			// 201 Created del servicio: para la Mac, 200 = entregado (el contrato de pushResult de siempre).
			reply(http.StatusOK, "")
		default:
			reply(result.Status, result.Reason)
		}
	}()
}

// MARK: mantenimiento

// Sweep vence las ranuras de emparejamiento (cierra su conexión y avisa a la Mac). Lo llama main cada 30 s.
func (h *Hub) Sweep() {
	now := h.o.Now()
	type expired struct {
		conn, mac *Conn
		id        string
	}
	var list []expired
	h.mu.Lock()
	for _, a := range h.accounts {
		if a.slot != nil && !now.Before(a.slot.expires) {
			list = append(list, expired{conn: a.slot.conn, mac: a.mac, id: a.slot.id})
			a.slot = nil
		}
	}
	h.mu.Unlock()
	for _, e := range list {
		if e.conn != nil {
			e.conn.closeWith(CloseUnauthorized, "pairing expired")
		}
		if e.mac != nil {
			e.mac.enqueue(Frame{T: "pair.close", Pairing: e.id})
		}
	}
}

// Summary loguea el resumen periódico (sin contenido).
func (h *Hub) Summary() {
	h.mu.Lock()
	conns := h.conns
	h.mu.Unlock()
	mailbox, _ := h.o.Store.MailboxBytes()
	h.o.Log.Info("summary", "connections", conns, "frames", h.frames.Swap(0), "pushes", h.pushed.Swap(0),
		"accepted", h.accepted.Swap(0), "mailboxBytes", mailbox)
}
