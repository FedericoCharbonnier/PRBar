# prbar-relay

The relay between PRBar on the Mac and PRBar on the iPhone (spec: `docs/superpowers/specs/2026-11-20-prbar-iphone-design.md`,
parts P and S). Both ends connect out to it over WebSocket (TLS terminated by Traefik); it routes end-to-end
encrypted frames by id, keeps a small encrypted mailbox, and sends APNs pushes whose content is encrypted for the
phone. It never decrypts anything.

## What it sees and what it doesn't (spec P.13)

| Sees | Doesn't see |
|---|---|
| Account and device ids, connection times, IPs, approximate sizes (frames are padded) | Anything inside Noise sessions: commands, results, PR content, chat |
| APNs device tokens (stored; logged only as a 6-hex tag of their SHA-256) | Push content (HPKE-sealed for the phone; Apple shows a generic text) |
| The pairing slot's `authKey` (derived from the QR secret) | The QR secret itself or the Noise PSK |

It can delay or drop traffic, but it can't read it, forge commands (it has no Noise statics and no Face ID key),
replay them (Noise counters, `sentAt` ≤ 120 s, request ids) or pair a phone of its own (needs the QR secret and the
6-digit code confirmed on the Mac).

Logs are JSON on stdout and never contain `b`, `e`, APNs tokens, enrollment tokens or payloads.

## Endpoints

- `GET /healthz` → `ok`
- `POST /v1/accounts` `{"enrollToken","macRelayKey"}` → `{"accountId"}` (needs `RELAY_ENROLL_TOKEN`; 5 bad tokens
  from one IP in 10 min block it for 15 min)
- `GET /v1/ws`, subprotocol `prbar-relay.v1`: challenge → signed `auth` → `ready`, then routing (spec P.4)

## Configuration (environment)

| Variable | Default | |
|---|---|---|
| `RELAY_LISTEN` | `:8080` | |
| `RELAY_DATA` | `/data` | bbolt file `relay.db` |
| `RELAY_PUBLIC_HOST` | — (required) | The host clients sign in the challenge (without a port) |
| `RELAY_ENROLL_TOKEN` | — (required, ≥ 32 chars) | Generate on the server: `openssl rand -hex 32` |
| `RELAY_MAX_ACCOUNTS` | `4` | |
| `RELAY_TRUSTED_PROXIES` | Docker private ranges | `X-Forwarded-For` (last hop only) is trusted only from these |
| `APNS_KEY_FILE` | `/run/secrets/apns.p8` | Compose secret, read-only |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` | — | Without them the relay starts with pushes disabled |
| `RELAY_TEST_MODE`, `APNS_ENDPOINT_OVERRIDE` | — | Tests only |

Secrets never go in the repo: `deploy/prbar-relay.env.example` lists the variables; the real `.env` and the `.p8`
live only in `/root/stack/env/` on the server.

## Limits

128 KiB per frame (4413), 50 frames/s with bursts of 200 and 4 MiB/s per connection (4429), a bounded send queue per
connection (a client that doesn't read is cut with 4429), 10 WebSocket upgrades per minute per IP, 5 failed auths in
10 min block the IP for 15 min, 64 connections in total, 1 Mac + 10 devices per account, one pairing slot per account
(5 min, 3 attempts), 60 pushes per minute per account, mailbox: 4 slots per device, 7-day TTL.

## Testing

```
cd relay
go vet ./... && test -z "$(gofmt -l .)" && go test ./...
```

Without Go installed: `docker run --rm -v "$PWD":/src -w /src golang:1.27 go test ./...`.

Swift ↔ Go integration (from the repo root):

```
(cd relay && go build -o /tmp/prbar-relay ./cmd/prbar-relay) && PRBAR_RELAY_BIN=/tmp/prbar-relay swift run PRBarTests "relay integration"
```

## Deploying

Plan 17, Task 15 — gated: it needs the user's explicit OK at each step that touches the server. `deploy/deploy.sh`
rsyncs `relay/` to `/root/stack/prbar-relay/src/`, copies the compose file, builds `prbar-relay:vps` on the server
and runs `docker compose up -d`. Server conventions: `/root/stack/LEEME.md`.

Long-lived WebSockets: after deploying, `go run ./cmd/wsprobe -host <host> -enroll-token-file <file>` stays connected
for 5 minutes. If the shared Traefik entrypoint cuts it, its timeouts are **not** changed; a dedicated entrypoint for
this router is added instead (spec V.2). The probe keeps its own account in `wsprobe-state.json` (it uses one of the
`RELAY_MAX_ACCOUNTS`).
