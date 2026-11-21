# prbar-relay

The relay between PRBar on the Mac and PRBar on the phone (specs: `docs/superpowers/specs/2026-11-20-prbar-iphone-design.md`,
parts P and S, and `docs/superpowers/specs/2026-11-21-prbar-web-app-design.md`, part W). Both ends connect out to it
over WebSocket (TLS terminated by Traefik); it routes end-to-end encrypted frames by id, keeps a small encrypted
mailbox, sends Web Push notifications whose content is encrypted for the phone, and serves the phone's web app (PWA).
It never decrypts anything.

## What it sees and what it doesn't (spec P.13)

| Sees | Doesn't see |
|---|---|
| Account and device ids, connection times, IPs, approximate sizes (frames are padded) | Anything inside Noise sessions: commands, results, PR content, chat |
| Web Push subscriptions (stored; logged only as the push service host and a 6-hex tag of the endpoint's SHA-256) | Push content (HPKE-sealed for the phone, then RFC 8291-encrypted for the push service) |
| The pairing slot's `authKey` (derived from the QR secret) | The QR secret itself or the Noise PSK |

It can delay or drop traffic, but it can't read it, forge commands (it has no Noise statics and no passkey),
replay them (Noise counters, `sentAt` ≤ 120 s, request ids) or pair a phone of its own (needs the QR secret and the
6-digit code confirmed on the Mac). Whoever controls the server can change the web app it serves (accepted risk,
spec W, decision 2).

Logs are JSON on stdout and never contain `b`, `e`, push endpoints or keys, enrollment tokens or payloads.

## Endpoints

- `GET /healthz` → `ok`
- `POST /v1/accounts` `{"enrollToken","macRelayKey"}` → `{"accountId"}` (needs `RELAY_ENROLL_TOKEN`; 5 bad tokens
  from one IP in 10 min block it for 15 min)
- `GET /v1/vapid` → `{"publicKey":"<b64url, 65-byte uncompressed P-256 point>"}` (the browser's
  `applicationServerKey`); 404 when push is disabled
- `GET /v1/ws`, subprotocol `prbar-relay.v1`: challenge → signed `auth` → `ready`, then routing (spec P.4). If an
  `Origin` header is present it must be exactly `https://<RELAY_PUBLIC_HOST>` (403 otherwise; the Mac sends none)
- Every other `GET`: the web app embedded from `internal/web/dist` (`/` is `index.html`; unknown paths are 404). CSP
  and security headers as spec W.7; `Cache-Control: no-cache` (with an ETag) except `/assets/*`, which is immutable

### Push (spec W.6)

The phone registers its browser subscription with `{"t":"webpush","endpoint","p256dh","auth"}` (keys in base64url;
`p256dh` a 65-byte uncompressed P-256 point, `auth` 16 bytes). Only `https` endpoints on `web.push.apple.com`,
`fcm.googleapis.com`, `updates.push.services.mozilla.com` or a subdomain of `notify.windows.com`, without a port, up to
1 KiB, are accepted (`{"t":"error","reason":"bad subscription"}` otherwise).

The Mac's `{"t":"push","id","to","collapse","thread","b"}` becomes the payload
`{"v":1,"e":"<b, base64url>","c":"<collapse>","th":"<thread>"}`, encrypted with RFC 8291 (`aes128gcm`, one record)
and sent with VAPID (RFC 8292, ES256 JWT for 12 h, reused 1 h per push service), `TTL: 86400`, `Urgency: high` and
`Topic: <collapse, first 32 chars>`. The Mac gets `{"t":"pushResult","id","status","reason"}`: `200` delivered (the
service's `201`), `410 Unsubscribed` when the service answered 404/410 (the subscription is deleted), `410
NoSubscription`, `413 PayloadTooLarge`, `429 RelayRateLimit`, `502 PushServiceUnreachable`, `503 PushDisabled`, or the
push service's own status otherwise.

## Configuration (environment)

| Variable | Default | |
|---|---|---|
| `RELAY_LISTEN` | `:8080` | |
| `RELAY_DATA` | `/data` | bbolt file `relay.db` |
| `RELAY_PUBLIC_HOST` | — (required) | The host clients sign in the challenge (without a port); also the CSP's `wss://` host and the only allowed `Origin` |
| `RELAY_ENROLL_TOKEN` | — (required, ≥ 32 chars) | Generate on the server: `openssl rand -hex 32` |
| `RELAY_MAX_ACCOUNTS` | `4` | |
| `RELAY_TRUSTED_PROXIES` | Docker private ranges | `X-Forwarded-For` (last hop only) is trusted only from these |
| `VAPID_PRIVATE_KEY` | — | The P-256 scalar `d`, 32 bytes in base64url without padding. Without it the relay starts with pushes disabled. `deploy/deploy.sh` generates it on the server the first time |
| `VAPID_SUBJECT` | `https://<RELAY_PUBLIC_HOST>` | `mailto:…` or `https://…` contact for the push services |
| `RELAY_CLEAR_SITE_DATA` | — | `1`: `/sw.js` responses carry `Clear-Site-Data: "cache"`. Only while recovering from a server compromise (below); turn it off afterwards |
| `RELAY_TEST_MODE` | — | `1`: tests only. Also allows `Origin` `http://127.0.0.1:<any>` and `http://localhost:<any>` |
| `WEBPUSH_TEST_ENDPOINT` | — | Only with `RELAY_TEST_MODE=1`: an extra allowed endpoint prefix (`http` allowed) for the e2e fake push service |

Secrets never go in the repo: `deploy/prbar-relay.env.example` lists the variables; the real `.env` lives only in
`/root/stack/env/` on the server.

## Limits

128 KiB per frame (4413), 50 frames/s with bursts of 200 and 4 MiB/s per connection (4429), a bounded send queue per
connection (a client that doesn't read is cut with 4429), 10 WebSocket upgrades per minute per IP, 5 failed auths in
10 min block the IP for 15 min, 64 connections in total, 1 Mac + 10 devices per account, one pairing slot per account
(5 min, 3 attempts), 60 pushes per minute per account, mailbox: 4 slots per device, 7-day TTL.

## The embedded web app

`internal/web/dist` is embedded with `//go:embed`. The repo only has a placeholder `index.html` there so `go build`
works without node; the Dockerfile builds `web/` (`npm ci --ignore-scripts && npm run build` in a `node:24.21.0`
stage) and copies `web/dist` in before `go build`. For local runs, copy `web/dist/*` into `internal/web/dist/` (and
restore the placeholder afterwards: `git checkout relay/internal/web/dist`).

How the phone protects itself from a stale or tampered copy: `/sw.js` is never cached (`no-cache`, and browsers
always check the service worker script with the server), so it is the trust anchor. The build writes into it the
SHA-256 of every file the service worker precaches; on install it downloads each one bypassing the HTTP cache,
checks it, and refuses to install if any of them doesn't match. The built `index.html` carries Subresource Integrity
hashes for its script and stylesheet.

### Recovering from a server compromise

Whoever controlled the server could have served a modified app, and the `assets/` files are cached by the phones for a
year (`immutable`). To get every phone back to a clean app:

1. Secure the server (or replace it) and deploy a **clean build** from a trusted checkout. Bump `version` in
   `web/package.json` first: it goes into `sw.js`, so the phones see a new service worker even if the app's files
   didn't change (a byte-identical `sw.js` isn't reinstalled).
2. Set `RELAY_CLEAR_SITE_DATA=1` in `/root/stack/env/prbar-relay.env` and restart the relay. The next time each phone
   opens PRBar and checks for a new version, the `/sw.js` response tells it to clear its HTTP cache (`"cache"` only:
   pairing keys and settings stay). The new service worker downloads and verifies every file and, once active, deletes
   the old caches.
3. Open PRBar on every phone twice (the new version activates at the next launch), then remove the variable and
   restart the relay again.
4. On the Mac, **Reset iPhone Access…** (`prbar remote reset`) and pair the phones again: a compromised relay may have
   kept data it shouldn't.

If a phone still behaves oddly, delete PRBar from its Home Screen, clear its website data (Settings › Apps › Safari ›
Advanced › Website Data) and install and pair it again.

## Testing

```
cd relay
go vet ./... && test -z "$(gofmt -l .)" && go test ./...
```

Without Go installed: `docker run --rm -v "$PWD":/src -w /src golang:1.27.4 go test ./...`.

Swift ↔ Go integration (from the repo root):

```
(cd relay && go build -o /tmp/prbar-relay ./cmd/prbar-relay) && PRBAR_RELAY_BIN=/tmp/prbar-relay swift run PRBarTests "relay integration"
```

The web app end to end against this relay (test mode, a fake push service and a simulated Mac; Chromium and WebKit):
`Scripts/web-e2e.sh` from the repo root. It embeds the web build in a temporary copy of `relay/`, so the placeholder
here is never touched.

## Deploying

Gated: it needs the user's explicit OK at each step that touches the server. `deploy/deploy.sh` checks that
`/root/stack/env/prbar-relay.env` exists, generates `VAPID_PRIVATE_KEY` there if it's missing (never printed; an
existing valid key is never replaced, since that would invalidate the phones' subscriptions), rsyncs `relay/` and
`web/` (without `node_modules` or builds) to `/root/stack/prbar-relay/src/`, copies the compose file, builds
`prbar-relay:vps` with the repo root as context (`docker build -f src/relay/Dockerfile src`; BuildKit reads
`relay/Dockerfile.dockerignore`) and runs `docker compose up -d`. Server conventions: `/root/stack/LEEME.md`.

Long-lived WebSockets: after deploying, `go run ./cmd/wsprobe -host <host> -enroll-token-file <file>` stays connected
for 5 minutes. If the shared Traefik entrypoint cuts it, its timeouts are **not** changed; a dedicated entrypoint for
this router is added instead (spec V.2). The probe keeps its own account in `wsprobe-state.json` (it uses one of the
`RELAY_MAX_ACCOUNTS`).
