// Package webpush manda las notificaciones al servicio de push del navegador (spec W.6): cifrado RFC 8291
// (`aes128gcm`, RFC 8188) y autenticación VAPID (RFC 8292, vapid.go). Implementación propia con la biblioteca
// estándar. El contenido ya viene cifrado por la Mac para el teléfono (HPKE); esto es la segunda capa que exige
// Web Push, para que el servicio de push (Apple, Google, Mozilla, Microsoft) tampoco lo vea.
package webpush

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
)

// Tamaños de RFC 8291 / RFC 8188.
const (
	recordSize   = 4096
	saltSize     = 16
	authSize     = 16
	publicSize   = 65
	tagSize      = 16
	headerSize   = saltSize + 4 + 1 + publicSize // salt ‖ rs ‖ idlen ‖ keyid
	MaxEndpoint  = 1024
	paddingDelim = 0x02 // último (y único) registro
	// MaxPayload es lo máximo que entra en un solo registro sin que el cuerpo pase los 4096 bytes que todo servicio
	// de push acepta (RFC 8030 §7.2).
	MaxPayload = recordSize - headerSize - tagSize - 1
)

var (
	ErrPayloadTooLarge = errors.New("webpush: payload too large")
	ErrEndpoint        = errors.New("webpush: endpoint not allowed")
	ErrKeys            = errors.New("webpush: bad subscription keys")
)

// Hosts de los servicios de push permitidos (exactos), más cualquier subdominio de notify.windows.com. Así el
// relay nunca hace pedidos a un lugar que elija un teléfono.
var allowedHosts = map[string]bool{
	"web.push.apple.com":                true,
	"fcm.googleapis.com":                true,
	"updates.push.services.mozilla.com": true,
}

const allowedSuffix = ".notify.windows.com"

// Subscription es lo que manda el teléfono en el marco `webpush` (PushSubscription del navegador).
type Subscription struct {
	Endpoint string `json:"endpoint"`
	P256dh   []byte `json:"p256dh"`
	Auth     []byte `json:"auth"`
}

// Result es la respuesta del servicio de push.
type Result struct {
	Status int
	Reason string
}

// Gone dice si la suscripción ya no existe (404/410): se borra.
func Gone(r Result) bool {
	return r.Status == http.StatusNotFound || r.Status == http.StatusGone
}

// ValidateSubscription aplica la allowlist de endpoints (https, host exacto de la lista, sin puerto ni
// credenciales, ≤ 1 KiB) y valida las claves: p256dh un punto P-256 sin comprimir, auth 16 bytes. testPrefix (solo
// en RELAY_TEST_MODE) es un prefijo extra permitido tal cual, http incluido.
func ValidateSubscription(endpoint string, p256dh, auth []byte, testPrefix string) error {
	if len(p256dh) != publicSize || p256dh[0] != 4 || len(auth) != authSize {
		return ErrKeys
	}
	if _, err := ecdh.P256().NewPublicKey(p256dh); err != nil {
		return ErrKeys
	}
	if endpoint == "" || len(endpoint) > MaxEndpoint {
		return ErrEndpoint
	}
	if testPrefix != "" && strings.HasPrefix(endpoint, testPrefix) {
		if _, err := url.Parse(endpoint); err != nil {
			return ErrEndpoint
		}
		return nil
	}
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" || u.Fragment != "" || u.Opaque != "" {
		return ErrEndpoint
	}
	host := u.Hostname()
	if host != strings.ToLower(host) || net.ParseIP(host) != nil {
		return ErrEndpoint
	}
	if allowedHosts[host] {
		return nil
	}
	if strings.HasSuffix(host, allowedSuffix) && len(host) > len(allowedSuffix) {
		return nil
	}
	return ErrEndpoint
}

// Payload arma el JSON que va cifrado al teléfono: {"v":1,"e":<sobre HPKE en b64url>,"c":<collapse>,"th":<thread>}.
// Falla si no entra en un registro.
func Payload(collapse, thread string, envelope []byte) ([]byte, error) {
	data, err := json.Marshal(struct {
		V  int    `json:"v"`
		E  string `json:"e"`
		C  string `json:"c"`
		Th string `json:"th"`
	}{1, base64.RawURLEncoding.EncodeToString(envelope), collapse, thread})
	if err != nil {
		return nil, err
	}
	if len(data) > MaxPayload {
		return nil, ErrPayloadTooLarge
	}
	return data, nil
}

// Encrypt cifra plaintext para una suscripción (RFC 8291) con una clave efímera y una sal al azar.
func Encrypt(plaintext, uaPublic, authSecret []byte) ([]byte, error) {
	asPriv, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	salt := make([]byte, saltSize)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	return encrypt(plaintext, uaPublic, authSecret, salt, asPriv)
}

// keys deriva la clave y el nonce del contenido (RFC 8291 §3.3–3.4 y RFC 8188 §2.2–2.3).
func keys(ecdhSecret, authSecret, uaPublic, asPublic, salt []byte) (cek, nonce []byte, err error) {
	info := append(append([]byte("WebPush: info\x00"), uaPublic...), asPublic...)
	ikm, err := hkdf.Key(sha256.New, ecdhSecret, authSecret, string(info), 32)
	if err != nil {
		return nil, nil, err
	}
	prk, err := hkdf.Extract(sha256.New, ikm, salt)
	if err != nil {
		return nil, nil, err
	}
	if cek, err = hkdf.Expand(sha256.New, prk, "Content-Encoding: aes128gcm\x00", 16); err != nil {
		return nil, nil, err
	}
	nonce, err = hkdf.Expand(sha256.New, prk, "Content-Encoding: nonce\x00", 12)
	return cek, nonce, err
}

func gcm(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// encrypt es Encrypt con la sal y la clave del servidor fijas (el test usa las del apéndice A de RFC 8291).
func encrypt(plaintext, uaPublic, authSecret, salt []byte, asPriv *ecdh.PrivateKey) ([]byte, error) {
	if len(plaintext) > MaxPayload {
		return nil, ErrPayloadTooLarge
	}
	if len(authSecret) != authSize || len(salt) != saltSize {
		return nil, ErrKeys
	}
	ua, err := ecdh.P256().NewPublicKey(uaPublic)
	if err != nil {
		return nil, ErrKeys
	}
	secret, err := asPriv.ECDH(ua)
	if err != nil {
		return nil, err
	}
	asPublic := asPriv.PublicKey().Bytes()
	cek, nonce, err := keys(secret, authSecret, uaPublic, asPublic, salt)
	if err != nil {
		return nil, err
	}
	aead, err := gcm(cek)
	if err != nil {
		return nil, err
	}
	// Un solo registro (secuencia 0, así que el nonce va tal cual): texto ‖ 0x02, sin más relleno.
	record := append(append(make([]byte, 0, len(plaintext)+1), plaintext...), paddingDelim)
	out := make([]byte, headerSize, headerSize+len(record)+tagSize)
	copy(out, salt)
	binary.BigEndian.PutUint32(out[saltSize:], recordSize)
	out[saltSize+4] = publicSize
	copy(out[saltSize+5:], asPublic)
	return aead.Seal(out, nonce, record, nil), nil
}

// decrypt es el lado del navegador (solo para los tests: el relay nunca descifra).
func decrypt(body []byte, uaPriv *ecdh.PrivateKey, authSecret []byte) ([]byte, error) {
	if len(body) < headerSize+tagSize || body[saltSize+4] != publicSize {
		return nil, errors.New("webpush: short body")
	}
	salt := body[:saltSize]
	asPublic := body[saltSize+5 : headerSize]
	as, err := ecdh.P256().NewPublicKey(asPublic)
	if err != nil {
		return nil, err
	}
	secret, err := uaPriv.ECDH(as)
	if err != nil {
		return nil, err
	}
	cek, nonce, err := keys(secret, authSecret, uaPriv.PublicKey().Bytes(), asPublic, salt)
	if err != nil {
		return nil, err
	}
	aead, err := gcm(cek)
	if err != nil {
		return nil, err
	}
	record, err := aead.Open(nil, nonce, body[headerSize:], nil)
	if err != nil {
		return nil, err
	}
	end := bytes.LastIndexByte(record, paddingDelim)
	if end < 0 || len(bytes.TrimRight(record[end+1:], "\x00")) != 0 {
		return nil, errors.New("webpush: bad padding")
	}
	return record[:end], nil
}

// Send cifra el payload para la suscripción y lo manda (RFC 8030): TTL 1 día, urgencia alta y Topic (el collapse
// truncado a 32 caracteres) para que una notificación nueva del mismo PR reemplace a la vieja.
func (s *Sender) Send(ctx context.Context, sub Subscription, collapse string, payload []byte) (Result, error) {
	if err := ValidateSubscription(sub.Endpoint, sub.P256dh, sub.Auth, s.testPrefix); err != nil {
		return Result{}, err
	}
	body, err := Encrypt(payload, sub.P256dh, sub.Auth)
	if err != nil {
		return Result{}, err
	}
	u, err := url.Parse(sub.Endpoint)
	if err != nil {
		return Result{}, ErrEndpoint
	}
	authorization, err := s.authorization(u.Scheme + "://" + u.Host)
	if err != nil {
		return Result{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, sub.Endpoint, bytes.NewReader(body))
	if err != nil {
		return Result{}, ErrEndpoint
	}
	req.Header.Set("Authorization", authorization)
	req.Header.Set("TTL", "86400")
	req.Header.Set("Urgency", "high")
	req.Header.Set("Content-Encoding", "aes128gcm")
	req.Header.Set("Content-Type", "application/octet-stream")
	if topic := Topic(collapse); topic != "" {
		req.Header.Set("Topic", topic)
	}
	resp, err := s.http.Do(req)
	if err != nil {
		// *url.Error trae el endpoint, que es una credencial de la suscripción: se descarta para que no llegue a
		// los logs.
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			err = urlErr.Err
		}
		return Result{}, fmt.Errorf("webpush: %w", err)
	}
	defer resp.Body.Close()
	result := Result{Status: resp.StatusCode}
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode >= 300 {
		var reason struct {
			Reason string `json:"reason"`
		}
		if json.Unmarshal(raw, &reason) == nil {
			result.Reason = cleanReason(reason.Reason)
		}
	}
	return result, nil
}

// Topic: el collapse (hex, ya seguro para URL) truncado a los 32 caracteres que permite RFC 8030 §5.4.
func Topic(collapse string) string {
	if len(collapse) > 32 {
		collapse = collapse[:32]
	}
	for _, c := range collapse {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return ""
		}
	}
	return collapse
}

// cleanReason deja solo un motivo corto y alfanumérico (va al log y a la Mac).
func cleanReason(s string) string {
	if len(s) > 64 {
		s = s[:64]
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == ' ') {
			return ""
		}
	}
	return s
}
