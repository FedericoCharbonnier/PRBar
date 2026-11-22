// Package auth implementa la autenticación del relay (spec P.3 y P.4): firma Ed25519 del desafío, `proof` de
// emparejamiento con HMAC-SHA256 y la comparación del token de inscripción. Todo en tiempo constante.
package auth

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
)

// NonceSize es el largo del desafío.
const NonceSize = 32

// NewNonce devuelve 32 bytes al azar.
func NewNonce() []byte {
	nonce := make([]byte, NonceSize)
	if _, err := rand.Read(nonce); err != nil {
		panic(err)
	}
	return nonce
}

// Message es lo que firma el cliente: "PRBarRelayAuth v1\n" ‖ host ‖ "\n" ‖ acct ‖ "\n" ‖ client ‖ "\n" ‖ nonce.
func Message(host, acct, client string, nonce []byte) []byte {
	msg := []byte("PRBarRelayAuth v1\n" + host + "\n" + acct + "\n" + client + "\n")
	return append(msg, nonce...)
}

// VerifySignature verifica la firma Ed25519 de un cliente.
func VerifySignature(publicKey []byte, host, acct, client string, nonce, sig []byte) bool {
	if len(publicKey) != ed25519.PublicKeySize || len(sig) != ed25519.SignatureSize || len(nonce) != NonceSize {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(publicKey), Message(host, acct, client, nonce), sig)
}

// PairingProof es HMAC-SHA256(authKey, nonce).
func PairingProof(authKey, nonce []byte) []byte {
	mac := hmac.New(sha256.New, authKey)
	mac.Write(nonce)
	return mac.Sum(nil)
}

// VerifyProof compara el proof en tiempo constante.
func VerifyProof(authKey, nonce, proof []byte) bool {
	if len(authKey) != 32 || len(nonce) != NonceSize {
		return false
	}
	return hmac.Equal(PairingProof(authKey, nonce), proof)
}

// TokenEqual compara el token de inscripción sin filtrar ni el contenido ni el largo (compara los SHA-256).
func TokenEqual(expected, got string) bool {
	a := sha256.Sum256([]byte(expected))
	b := sha256.Sum256([]byte(got))
	return subtle.ConstantTimeCompare(a[:], b[:]) == 1 && expected != ""
}
