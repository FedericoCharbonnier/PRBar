package auth

import (
	"crypto/ed25519"
	"testing"
)

func TestSignature(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	nonce := NewNonce()
	sig := ed25519.Sign(priv, Message("relay.example.org", "acct", "mac", nonce))
	if !VerifySignature(pub, "relay.example.org", "acct", "mac", nonce, sig) {
		t.Fatal("good signature rejected")
	}
	otherPub, _, _ := ed25519.GenerateKey(nil)
	cases := map[string]bool{
		"other host":   VerifySignature(pub, "evil.example.org", "acct", "mac", nonce, sig),
		"other acct":   VerifySignature(pub, "relay.example.org", "acct2", "mac", nonce, sig),
		"other client": VerifySignature(pub, "relay.example.org", "acct", "dev", nonce, sig),
		"other nonce":  VerifySignature(pub, "relay.example.org", "acct", "mac", NewNonce(), sig),
		"other key":    VerifySignature(otherPub, "relay.example.org", "acct", "mac", nonce, sig),
		"short sig":    VerifySignature(pub, "relay.example.org", "acct", "mac", nonce, sig[:63]),
		"short key":    VerifySignature(pub[:31], "relay.example.org", "acct", "mac", nonce, sig),
	}
	for name, ok := range cases {
		if ok {
			t.Errorf("%s accepted", name)
		}
	}
}

func TestProofAndToken(t *testing.T) {
	key := make([]byte, 32)
	nonce := NewNonce()
	proof := PairingProof(key, nonce)
	if !VerifyProof(key, nonce, proof) {
		t.Fatal("good proof rejected")
	}
	proof[0] ^= 1
	if VerifyProof(key, nonce, proof) {
		t.Fatal("bad proof accepted")
	}
	if !TokenEqual("secret-token", "secret-token") || TokenEqual("secret-token", "secret-tokem") || TokenEqual("", "") {
		t.Fatal("token comparison")
	}
}
