package hub

import (
	"context"
	"io"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"prbar-relay/internal/auth"
	"prbar-relay/internal/logx"
	"prbar-relay/internal/ratelimit"
)

type role int

const (
	roleNone role = iota
	roleMac
	roleDevice
	rolePair
)

func (r role) String() string {
	switch r {
	case roleMac:
		return "mac"
	case roleDevice:
		return "device"
	case rolePair:
		return "pair"
	default:
		return "none"
	}
}

// Conn es una conexión de WebSocket: una goroutine lee (serve) y otra escribe (writer) desde una cola acotada.
type Conn struct {
	hub  *Hub
	ws   *websocket.Conn
	ip   string
	role role
	acct string
	// id: el deviceId (role device) o el pairingId (role pair).
	id string

	send      chan []byte
	done      chan struct{}
	closeOnce sync.Once

	frames *ratelimit.Bucket
	bytes  *ratelimit.Bucket
	in     atomic.Int64
	out    atomic.Int64
}

func newConn(h *Hub, ws *websocket.Conn, ip string) *Conn {
	now := h.o.Now()
	return &Conn{
		hub:    h,
		ws:     ws,
		ip:     ip,
		send:   make(chan []byte, h.o.SendQueue),
		done:   make(chan struct{}),
		frames: ratelimit.NewBucket(h.o.FrameRate, h.o.FrameBurst, now),
		bytes:  ratelimit.NewBucket(h.o.ByteRate, h.o.ByteRate, now),
	}
}

// enqueue encola un marco para escribir. Si la cola está llena (cliente que no lee), la conexión se cierra con 4429:
// mejor cortar que crecer sin límite o perder marcos en silencio.
func (c *Conn) enqueue(f Frame) {
	data := mustJSON(f)
	select {
	case <-c.done:
		return
	default:
	}
	select {
	case c.send <- data:
	default:
		c.hub.o.Log.Warn("limit", "kind", "send queue", "role", c.role.String(), "acct", logx.Prefix(c.acct))
		c.closeWith(CloseRateLimited, "too slow")
	}
}

// closeWith cierra una sola vez, con el código dado. El cierre de WebSocket espera la respuesta del otro lado, así
// que va en su propia goroutine.
func (c *Conn) closeWith(code websocket.StatusCode, reason string) {
	c.closeOnce.Do(func() {
		close(c.done)
		go func() { _ = c.ws.Close(code, reason) }()
	})
}

func (c *Conn) writer() {
	for {
		select {
		case <-c.done:
			return
		case data := <-c.send:
			ctx, cancel := context.WithTimeout(context.Background(), c.hub.o.WriteTimeout)
			err := c.ws.Write(ctx, websocket.MessageText, data)
			cancel()
			if err != nil {
				c.closeWith(websocket.StatusGoingAway, "write failed")
				return
			}
			c.out.Add(int64(len(data)))
		}
	}
}

func (c *Conn) writeNow(ctx context.Context, f Frame) error {
	ctx, cancel := context.WithTimeout(ctx, c.hub.o.WriteTimeout)
	defer cancel()
	return c.ws.Write(ctx, websocket.MessageText, mustJSON(f))
}

func (c *Conn) serve(ctx context.Context) {
	h := c.hub
	started := h.o.Now()
	nonce := auth.NewNonce()
	if err := c.writeNow(ctx, Frame{T: "challenge", Nonce: encodeB64(nonce), Time: started.Unix()}); err != nil {
		c.ws.CloseNow()
		return
	}
	// Sin `auth` en 5 s: 4408. Se cierra desde un timer (cancelar el contexto de Read cerraría sin ese código).
	var timedOut atomic.Bool
	timer := time.AfterFunc(h.o.AuthTimeout, func() {
		timedOut.Store(true)
		_ = c.ws.Close(CloseAuthTimeout, "auth timeout")
	})
	data, err := c.readFrame(ctx)
	timer.Stop()
	if timedOut.Load() {
		h.o.Log.Warn("auth failed", "ip", c.ip, "reason", "timeout")
		return
	}
	if err != nil {
		c.ws.CloseNow()
		return
	}
	f, err := ParseFrame(data)
	credential, wellFormed := authCredential(f)
	if err != nil || len(data) > h.o.MaxFrame || !wellFormed {
		h.ipFail.Fail(c.ip)
		h.o.Log.Warn("auth failed", "ip", c.ip, "reason", "malformed")
		c.ws.Close(CloseUnauthorized, "unauthorized")
		return
	}
	pairing := f.Client == "pair"
	lockKey := c.ip + " " + credential
	if !pairing && h.authFail.Blocked(lockKey) {
		h.o.Log.Warn("limit", "kind", "auth failures", "ip", c.ip, "acct", logx.Prefix(f.Acct),
			"client", logx.Prefix(f.Client))
		c.ws.Close(CloseRateLimited, "too many attempts")
		return
	}
	ready, err := h.authenticate(c, f, nonce)
	if err != nil {
		// Los emparejamientos fallidos no cuentan (QR vencido, ranura quemada…): la ranura tiene su propio límite.
		if !pairing {
			h.authFail.Fail(lockKey)
			h.ipFail.Fail(c.ip)
		}
		h.o.Log.Warn("auth failed", "ip", c.ip, "reason", "credentials", "acct", logx.Prefix(f.Acct),
			"client", logx.Prefix(f.Client))
		c.ws.Close(CloseUnauthorized, "unauthorized")
		return
	}
	h.accepted.Add(1)
	defer h.unregister(c)
	if err := c.writeNow(ctx, ready); err != nil {
		c.closeWith(websocket.StatusGoingAway, "write failed")
		return
	}
	// Sin la IP: solo se loguea en los rechazos y los límites (logs mínimos, spec P.10).
	h.o.Log.Info("connection open", "role", c.role.String(), "acct", logx.Prefix(c.acct), "client", logx.Prefix(c.id))
	go c.writer()
	reason := c.readLoop(ctx)
	c.closeWith(reason.code, reason.text)
	h.o.Log.Info("connection closed", "role", c.role.String(), "acct", logx.Prefix(c.acct),
		"client", logx.Prefix(c.id), "seconds", int(h.o.Now().Sub(started)/time.Second), "in", c.in.Load(), "out", c.out.Load(),
		"code", int(reason.code))
}

// authCredential: la credencial que intenta entrar ("cuenta cliente"), o false si el `auth` está malformado (eso
// cuenta solo para el tope por IP: sin ids válidos no hay credencial que bloquear).
func authCredential(f Frame) (string, bool) {
	if f.T != "auth" || !isBase32(f.Acct, accountIDLength) {
		return "", false
	}
	if f.Client != "mac" && f.Client != "pair" && !isBase32(f.Client, deviceIDLength) {
		return "", false
	}
	return f.Acct + " " + f.Client, true
}

// readFrame lee un mensaje sin guardar más de MaxFrame+1 bytes (quien llama corta con 4413 si pasa el tope).
func (c *Conn) readFrame(ctx context.Context) ([]byte, error) {
	_, reader, err := c.ws.Reader(ctx)
	if err != nil {
		return nil, err
	}
	return io.ReadAll(io.LimitReader(reader, int64(c.hub.o.MaxFrame)+1))
}

type closeReason struct {
	code websocket.StatusCode
	text string
}

func (c *Conn) readLoop(ctx context.Context) closeReason {
	h := c.hub
	for {
		// Sin límite de la biblioteca (cerraría con 1009): se lee como mucho MaxFrame+1 y un marco más grande se
		// corta con 4413 sin guardarlo entero.
		data, err := c.readFrame(ctx)
		if err != nil {
			return closeReason{code: websocket.StatusNormalClosure, text: "closed"}
		}
		c.in.Add(int64(len(data)))
		h.frames.Add(1)
		if len(data) > h.o.MaxFrame {
			h.o.Log.Warn("limit", "kind", "frame size", "role", c.role.String(), "acct", logx.Prefix(c.acct))
			return closeReason{code: CloseTooLarge, text: "frame too large"}
		}
		now := h.o.Now()
		if !c.frames.Allow(now, 1) || !c.bytes.Allow(now, float64(len(data))) {
			h.o.Log.Warn("limit", "kind", "rate", "role", c.role.String(), "acct", logx.Prefix(c.acct))
			return closeReason{code: CloseRateLimited, text: "rate limited"}
		}
		f, err := ParseFrame(data)
		if err != nil {
			c.enqueue(Frame{T: "error", Reason: "bad frame"})
			continue
		}
		h.route(c, f)
		select {
		case <-c.done:
			return closeReason{code: websocket.StatusNormalClosure, text: "closed"}
		default:
		}
	}
}
