// Package logx arma el logger JSON del relay y los helpers para loguear ids sin exponerlos.
//
// Regla (spec P.10): nunca se loguea `b`, `e`, tokens de APNs, payloads ni el token de inscripción. Los ids van
// recortados (Prefix) y los tokens como un tag de 6 hex de su SHA-256 (TokenTag).
package logx

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log/slog"
)

// New devuelve un logger JSON que escribe en w.
func New(w io.Writer) *slog.Logger {
	return slog.New(slog.NewJSONHandler(w, &slog.HandlerOptions{Level: slog.LevelInfo}))
}

// Prefix devuelve los primeros 4 caracteres de un id.
func Prefix(id string) string {
	if len(id) > 4 {
		return id[:4]
	}
	return id
}

// TokenTag identifica un token sin revelarlo: los 6 primeros hex de su SHA-256.
func TokenTag(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])[:6]
}
