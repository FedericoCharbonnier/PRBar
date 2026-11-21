package hub

import (
	"encoding/base64"
	"encoding/json"
	"errors"
)

// Frame es un marco del protocolo del relay (spec P.4). Un solo struct con todos los campos opcionales: `t` dice
// cuáles valen. Los mismos literales que `WireTests` (Swift) están en testdata/frames.json.
type Frame struct {
	T string `json:"t"`

	Nonce string `json:"nonce,omitempty"`
	Time  int64  `json:"time,omitempty"`

	Acct    string `json:"acct,omitempty"`
	Client  string `json:"client,omitempty"`
	Sig     string `json:"sig,omitempty"`
	Pairing string `json:"pairing,omitempty"`
	Proof   string `json:"proof,omitempty"`

	Mac   string `json:"mac,omitempty"`
	Since int64  `json:"since,omitempty"`

	To   string `json:"to,omitempty"`
	From string `json:"from,omitempty"`
	Sid  string `json:"sid,omitempty"`
	B    string `json:"b,omitempty"`

	Device string `json:"device,omitempty"`
	State  string `json:"state,omitempty"`

	ID       string `json:"id,omitempty"`
	Collapse string `json:"collapse,omitempty"`
	Thread   string `json:"thread,omitempty"`
	Status   int    `json:"status,omitempty"`
	Reason   string `json:"reason,omitempty"`

	Slot  string          `json:"slot,omitempty"`
	Items json.RawMessage `json:"items,omitempty"`

	Endpoint string `json:"endpoint,omitempty"`
	P256dh   string `json:"p256dh,omitempty"`
	Auth     string `json:"auth,omitempty"`

	AuthKey  string `json:"authKey,omitempty"`
	Expires  int64  `json:"expires,omitempty"`
	RelayKey string `json:"relayKey,omitempty"`
}

// MailboxItem es un elemento de `{"t":"mbox","items":[…]}`.
type MailboxItem struct {
	Slot string `json:"slot"`
	B    string `json:"b"`
	At   int64  `json:"at"`
}

// DeviceItem es un elemento de `{"t":"devices","items":[…]}`.
type DeviceItem struct {
	ID       string `json:"id"`
	LastSeen int64  `json:"lastSeen"`
}

var b64 = base64.RawURLEncoding.Strict()

func decodeB64(s string) ([]byte, error) { return b64.DecodeString(s) }

func encodeB64(data []byte) string { return b64.EncodeToString(data) }

// ParseFrame decodifica un marco y exige `t`.
func ParseFrame(data []byte) (Frame, error) {
	var f Frame
	if err := json.Unmarshal(data, &f); err != nil {
		return Frame{}, err
	}
	if f.T == "" {
		return Frame{}, errors.New("frame without t")
	}
	return f, nil
}

func mustJSON(v any) []byte {
	data, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return data
}

func isHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func isBase32(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '2' && c <= '7') {
			return false
		}
	}
	return true
}

// Largos de los ids (base32 minúscula sin relleno): cuenta y dispositivo 16 bytes, emparejamiento 10.
const (
	accountIDLength = 26
	deviceIDLength  = 26
	pairingIDLength = 16
	sidLength       = 16
)

func validSlot(s string) bool {
	if len(s) == 0 || len(s) > 32 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == ':') {
			return false
		}
	}
	return true
}
