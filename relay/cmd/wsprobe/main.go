// wsprobe prueba que una conexión de WebSocket larga sobreviva al proxy (spec V.2): se inscribe una sola vez con el
// token (guarda la cuenta y la clave en -state), se autentica como Mac y se queda -duration con un ping cada
// -interval. Si el proxy corta, dice a los cuántos segundos.
package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/coder/websocket"
)

type state struct {
	Account string `json:"account"`
	Key     []byte `json:"key"`
}

func main() {
	host := flag.String("host", "", "relay host, e.g. prbar.example.org or prbar.example.org:8443")
	tokenFile := flag.String("enroll-token-file", "", "file with the enrollment token (only for the first run)")
	statePath := flag.String("state", "wsprobe-state.json", "where to keep the probe's account and key")
	duration := flag.Duration("duration", 5*time.Minute, "how long to stay connected")
	interval := flag.Duration("interval", 20*time.Second, "ping interval")
	insecure := flag.Bool("insecure", false, "use ws:// and http:// (local tests)")
	flag.Parse()
	if *host == "" {
		fmt.Fprintln(os.Stderr, "usage: wsprobe -host HOST [-enroll-token-file FILE]")
		os.Exit(2)
	}
	if err := probe(*host, *tokenFile, *statePath, *duration, *interval, *insecure); err != nil {
		fmt.Fprintln(os.Stderr, "wsprobe:", err)
		os.Exit(1)
	}
}

var b64 = base64.RawURLEncoding

func loadOrEnroll(base, tokenFile, path string) (state, error) {
	var s state
	if raw, err := os.ReadFile(path); err == nil {
		err = json.Unmarshal(raw, &s)
		return s, err
	}
	if tokenFile == "" {
		return s, fmt.Errorf("no %s yet: pass -enroll-token-file", path)
	}
	token, err := os.ReadFile(tokenFile)
	if err != nil {
		return s, err
	}
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		return s, err
	}
	body, _ := json.Marshal(map[string]string{"enrollToken": strings.TrimSpace(string(token)),
		"macRelayKey": b64.EncodeToString(pub)})
	resp, err := http.Post(base+"/v1/accounts", "application/json", bytes.NewReader(body))
	if err != nil {
		return s, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return s, fmt.Errorf("enroll: HTTP %d", resp.StatusCode)
	}
	var out struct {
		AccountID string `json:"accountId"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return s, err
	}
	s = state{Account: out.AccountID, Key: priv}
	raw, _ := json.Marshal(s)
	return s, os.WriteFile(path, raw, 0o600)
}

func probe(host, tokenFile, statePath string, duration, interval time.Duration, insecure bool) error {
	scheme, wsScheme := "https", "wss"
	if insecure {
		scheme, wsScheme = "http", "ws"
	}
	s, err := loadOrEnroll(scheme+"://"+host, tokenFile, statePath)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ws, _, err := websocket.Dial(ctx, wsScheme+"://"+host+"/v1/ws",
		&websocket.DialOptions{Subprotocols: []string{"prbar-relay.v1"}})
	if err != nil {
		return err
	}
	defer ws.CloseNow()
	read := func() (map[string]any, error) {
		_, data, err := ws.Read(ctx)
		if err != nil {
			return nil, err
		}
		var f map[string]any
		if err := json.Unmarshal(data, &f); err != nil {
			return nil, err
		}
		return f, nil
	}
	challenge, err := read()
	if err != nil {
		return err
	}
	nonce, err := b64.DecodeString(fmt.Sprint(challenge["nonce"]))
	if err != nil {
		return err
	}
	signedHost := strings.Split(host, ":")[0]
	msg := append([]byte("PRBarRelayAuth v1\n"+signedHost+"\n"+s.Account+"\nmac\n"), nonce...)
	sig := ed25519.Sign(ed25519.PrivateKey(s.Key), msg)
	auth, _ := json.Marshal(map[string]string{"t": "auth", "acct": s.Account, "client": "mac",
		"sig": b64.EncodeToString(sig)})
	if err := ws.Write(ctx, websocket.MessageText, auth); err != nil {
		return err
	}
	if ready, err := read(); err != nil || ready["t"] != "ready" {
		return fmt.Errorf("not ready: %v %v", ready, err)
	}
	fmt.Printf("connected; staying %s with a ping every %s\n", duration, interval)
	started := time.Now()
	deadline := time.After(duration)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	go func() {
		for {
			if _, err := read(); err != nil {
				if ctx.Err() != nil {
					return
				}
				fmt.Printf("cut after %.0f s: %v\n", time.Since(started).Seconds(), err)
				os.Exit(1)
			}
		}
	}()
	for {
		select {
		case <-deadline:
			cancel()
			fmt.Printf("ok: still connected after %.0f s\n", time.Since(started).Seconds())
			return nil
		case <-ticker.C:
			if err := ws.Write(ctx, websocket.MessageText, []byte(`{"t":"ping"}`)); err != nil {
				return fmt.Errorf("ping failed after %.0f s: %w", time.Since(started).Seconds(), err)
			}
		}
	}
}
