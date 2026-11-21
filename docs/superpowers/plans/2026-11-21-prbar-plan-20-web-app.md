# PRBar Web App (PWA) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the native iOS app with an installable web app (PWA) served by the relay, keeping the same screens, the same end-to-end encryption with the Mac, Face ID (passkeys) and push (Web Push).

**Architecture:** `web/` is a Preact + TypeScript + Vite app that speaks the existing relay/Noise/HPKE protocol (ported with `@noble/*`, checked byte-for-byte against vectors the Mac generates). The Go relay embeds the built app and serves it with a strict CSP, swaps APNs for Web Push (own RFC 8291/8292 code). The Mac moves to protocol 8: WebAuthn presence proofs, Web Push registration, an "Open PRBar on your phone" QR. The native app (`ios/`) is deleted.

**Tech Stack:** Preact 10, @preact/signals, TypeScript 5, Vite, Vitest, Playwright (Chromium + WebKit), @noble/curves/hashes/ciphers, jsqr; Go 1.27 (stdlib + x/crypto/hkdf); Swift 6 / CryptoKit.

**Spec:** `docs/superpowers/specs/2026-11-21-prbar-web-app-design.md` (sections W.1–W.10). Base protocol: `docs/superpowers/specs/2026-11-20-prbar-iphone-design.md` sections P and Q.

**Conventions (all tasks):**
- Repo is public. Never commit the VPS IP, real tokens, `/Users/<name>` paths, or any Claude/Anthropic attribution in commit messages.
- Mac tests: `swift build --product PRBarTests && swift run PRBarTests [filter]` (plain `swift build` fails; build per product). Relay: `cd relay && go test ./...`. Web: `cd web && npm test`, `npm run build`, `npm run e2e`.
- Code comments in Spanish (as the rest of the repo); user-facing copy in English, exactly as `web/design/DESIGN.md`.
- Commit after each task with a short imperative message.

---

## Track A — Mac and fixtures (Swift)

### Task A1: Protocol 8 and WebAuthn presence on the Mac

**Files:**
- Modify: `Sources/PRBarRemoteKit/Presence.swift` (v2 challenge, `WebAuthnPresenceVerifier`, `SoftwareWebAuthnAuthenticator` for tests and the fixture phone)
- Modify: `Sources/PRBarRemoteKit/RemoteKeys.swift`, `RemoteClient.swift` (pairing payload `presence: {credentialId, publicKey(SPKI), rpId}`; client signs with an injected authenticator)
- Modify: `Sources/PRBarRemoteMac/*` where `presenceKey` is stored/verified (`RemoteDevice`, `devices.json` decode: unknown/old shape → empty list)
- Modify: `CommandProtocol.version` and `minimumRemoteVersion` → 8
- Test: `Sources/PRBarTests/Remote*Tests.swift` (new `WebAuthnPresenceTests`)

- [ ] Write failing tests: valid assertion accepted; rejected when UV flag off, UP off, origin differs, `crossOrigin: true`, rpIdHash differs, challenge differs (other reqId / other cmd bytes / other session), other credentialId, signature from another key, ts older than 60 s, reqId replayed. Build assertions in the test with a P-256 software key: `authenticatorData = SHA256(rpId) ‖ flags(0x05) ‖ signCount(u32 BE 0)`, `clientDataJSON = {"type":"webauthn.get","challenge":b64url(challenge),"origin":"https://<rpId>","crossOrigin":false}`, signature over `authenticatorData ‖ SHA256(clientDataJSON)`.
- [ ] `challenge = SHA256("PRBarPresence v2" ‖ sessionHash ‖ reqId u64 BE ‖ SHA256(cmd) ‖ ts i64 BE ms)`. `PresenceProof` becomes `{v:2, tsMillis, credentialId, authenticatorData, clientDataJSON, signature}` (Data fields as b64url in JSON). Parse `clientDataJSON` with `JSONSerialization`, compare `challenge` string exactly. SPKI → `P256.Signing.PublicKey(derRepresentation:)`.
- [ ] Device paired without a credential (`presence == nil`) → every gated command fails with `"Face ID isn't set up on this device. Pair it again."`.
- [ ] Delete the v1 (x963 / Secure Enclave) path. Update every existing remote test (they use `SoftwarePresenceSigner` → switch to `SoftwareWebAuthnAuthenticator(rpId:)`).
- [ ] Run `swift run PRBarTests remote` then the full suite; all pass. Commit.

### Task A2: Web Push registration, settings QR, CLI

**Files:**
- Modify: `Sources/PRBarRemoteKit/RelayMessages.swift` (`.apns` → `.webpush(endpoint:p256dh:auth:)`, frame `{"t":"webpush",...}`), `Sealed.swift` (`open(apnsField:)` → `open(pushField:)`; max plaintext 2048, padding to multiple of 256), `RemoteClient.swift`
- Modify: `Sources/PRBarRemoteMac` push sender (plaintext cap 2048; titles/bodies truncated to fit)
- Modify: Settings › iPhone view (`Sources/PRBar/...Settings...iPhone...`): replace "Get PRBar for iPhone"/TestFlight block and `remote.appInstallURL` with "Open PRBar on your phone": QR of `https://<relay host>/`, text "Scan with your iPhone camera, then Share › Add to Home Screen." Hidden when remote access is disabled.
- Modify: `PairingQR.swift`: QR text = `https://<relay host>/#pair?v=1&r=…&a=…&p=…&k=…&m=…&n=…`; parser accepts that form (and keeps accepting `prbar://pair?` only in tests if needed — prefer removing it).
- Modify: CLI — delete `prbar remote app-link`; `prbar remote pair` prints the pairing URL under the QR ("Or paste this in PRBar › Pair › Paste code: <url>").
- Test: update existing tests; new tests for webpush frame encode/decode, QR round trip, 2048 cap.
- [ ] TDD each change, full suite green, commit.

### Task A3: Fixture executable for the web (vectors + fake Mac)

**Files:**
- Create: `Sources/PRBarRemoteFixtureServer/main.swift` (executable product `prbar-remote-fixture`, depends on `PRBarRemoteFixtures`)
- Modify: `Package.swift`

Two subcommands:
- `vectors <dir>`: writes deterministic JSON vectors with fixed keys (hex): `noise-kk.json` (both static/ephemeral keys, prologue, each handshake message, handshake hash, 3 transport messages each way), `noise-ikpsk2.json` (same for pairing with psk), `hpke.json` (auth mode, info, plaintext, enc, ciphertext — push envelope), `sas.json`, `relay-auth.json` (Ed25519 key, host, acct, client, nonce, sig), `presence.json` (sessionHash, reqId, cmd bytes, ts, expected challenge), `pairing-qr.json` (fields → URL), `frames.json` (one sample of every relay frame), `app.json` (one encoded sample of every `AppCommand` allowed for the phone, every event/topic payload the phone reads: home state, PR detail, review, respond, CI fix, merge preview, chat, activity, usage, history, notify settings, errors). If CryptoKit can't take a fixed ephemeral key, expose an internal seam in `Noise.swift` for tests/fixtures only (`@_spi(Fixtures)`).
- `serve --relay ws://127.0.0.1:<port> --enroll-token <t> --state <dir>`: enrolls, runs a real `RemoteAccessService` with `FixtureActions` PRs, prints one JSON line per event to stdout (`{"event":"ready"}`, `{"event":"pairing","url":"…"}`, `{"event":"sas","code":"123456"}`, `{"event":"paired","device":"…"}`, `{"event":"push","…"}`), reads commands on stdin (`pair`, `confirm`, `notify <kind>`, `quit`). Merge/review actions succeed on fixture data.
- [ ] Implement, add a smoke test in PRBarTests that `vectors` output round-trips through the Swift decoders. Generate `web/test/fixtures/` (commit the JSON). Commit.

## Track B — Relay (Go)

### Task B1: Web Push sender

**Files:**
- Create: `relay/internal/webpush/{webpush.go,vapid.go,webpush_test.go}`
- Modify: `relay/internal/config` (`VAPID_PRIVATE_KEY` b64url 32 bytes, `VAPID_SUBJECT`), `relay/internal/hub` (frame `webpush` replaces `apns`; `push` frame sends via webpush), `relay/internal/store` (subscription instead of token), `relay/cmd/prbar-relay/main.go`
- Delete: `relay/internal/apns`

- [ ] RFC 8291 `aes128gcm` encryption with stdlib `crypto/ecdh` P-256 + `x/crypto/hkdf` + AES-128-GCM, record size 4096, single record, padding delimiter `0x02`. Test with RFC 8291 Appendix A (fixed salt and server key via an internal seam) — output must equal the RFC's body exactly.
- [ ] VAPID (RFC 8292): JWT ES256 (`aud` = scheme+host of endpoint, `exp` = now+12h, `sub`), header `Authorization: vapid t=<jwt>, k=<pub b64url>`; cache per audience for 1 h. Test: verify the JWT with the public key.
- [ ] Endpoint allowlist: https only, host exactly `web.push.apple.com`, `fcm.googleapis.com`, `updates.push.services.mozilla.com`, or suffix `.notify.windows.com`; `p256dh` 65 bytes uncompressed point on curve, `auth` 16 bytes; endpoint ≤ 1 KiB. In `RELAY_TEST_MODE` an extra allowed endpoint prefix comes from `WEBPUSH_TEST_ENDPOINT` (for e2e).
- [ ] Send: `POST` with `TTL: 86400`, `Urgency: high`, `Topic` (collapse, ≤ 32 chars b64url-safe), `Content-Encoding: aes128gcm`. 201 → ok; 404/410 → delete subscription, `pushResult` to Mac; others → `pushResult` with status. Rate limit unchanged (60/min/account). Payload JSON `{"v":1,"e":…,"c":…,"th":…}`.
- [ ] `GET /v1/vapid` → `{"publicKey":"<b64url 65B>"}`; 404 when push disabled.
- [ ] `go test ./...` green. Commit.

### Task B2: Serve the web app, Origin check, deploy

**Files:**
- Create: `relay/internal/web/{web.go,web_test.go}`, `relay/internal/web/dist/` (embed target; a placeholder `index.html` committed so `go build` works without node; real build copied in by Dockerfile and by `Scripts/web-build.sh`)
- Modify: `relay/cmd/prbar-relay/main.go`, `relay/Dockerfile` (stage `node:24` builds `web/` → copies `web/dist` into `relay/internal/web/dist` before `go build`; build context becomes repo root — update `relay/deploy/deploy.sh` and compose accordingly), `relay/deploy/docker-compose.yml` (drop `apns_p8` secret), `relay/deploy/prbar-relay.env.example`, `relay/deploy/deploy.sh` (first deploy generates VAPID key on the server with `openssl ecparam -genkey -name prime256v1` → raw 32-byte d in b64url, appends to env if missing; never prints it), `relay/README.md`
- [ ] Handler: `/` → `index.html`; `/assets/*`, `/sw.js`, `/manifest.webmanifest`, icons from embed; unknown path → 404 (no SPA fallback needed: routing is by hash). Headers exactly as spec W.7 (CSP `connect-src 'self' wss://<RELAY_PUBLIC_HOST>`). Tests assert headers and cache policy.
- [ ] WebSocket upgrade: if `Origin` header present and ≠ `https://<RELAY_PUBLIC_HOST>` → 403. In test mode also allow `http://127.0.0.1:<any>`/`http://localhost:<any>`. Test.
- [ ] `go test ./...` green; `docker build` is NOT required locally (no Docker daemon assumption) but `go vet` and build must pass. Commit.

## Track C — Web app

### Task C1: Scaffold and design references

- [ ] `git mv ios/DESIGN.md web/design/DESIGN.md`; copy `ios/snapshots/*` → `web/design/snapshots/`; icons: generate `web/public/icons/{apple-touch-icon-180.png, icon-192.png, icon-512.png, icon-512-maskable.png}` from `ios/PRBarMobile/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` with `sips`.
- [ ] `web/package.json` with exact versions (latest stable at implementation time, ≥ 2 weeks old), scripts `dev`, `build` (`tsc --noEmit && vite build`), `test` (vitest run), `e2e` (playwright), `snapshots`. `tsconfig` strict. Vite config: output `dist/` with hashed assets under `assets/`, `sw.ts` built as `/sw.js` (separate entry, no hash), no inline scripts/styles (CSP), `base: "/"`.
- [ ] `index.html`, `manifest.webmanifest` (W.1), `src/ui/tokens.css` with every token of DESIGN.md (light + `prefers-color-scheme: dark`), SF system font stack (`-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui`), safe-area insets (`env(safe-area-inset-*)`), `viewport-fit=cover`, `apple-mobile-web-app-capable`, status bar style.
- [ ] `npm run build` ok. Commit (`web/node_modules` and `web/dist` gitignored).

### Task C2: Crypto

**Files:** `web/src/crypto/{b64.ts,bytes.ts,noise.ts,hpke.ts,sas.ts,relayAuth.ts,presence.ts}` + tests.
- [ ] Noise `Noise_KK_25519_ChaChaPoly_SHA256` and `Noise_IKpsk2_25519_ChaChaPoly_SHA256` (CipherState, SymmetricState, HandshakeState; nonce 64-bit LE in 12-byte nonce, rekey not needed). Tests: the official cacophony vectors already used by the Swift tests (copy the JSON they use) + `web/test/fixtures/noise-*.json`.
- [ ] HPKE RFC 9180 mode_auth with DHKEM(X25519, HKDF-SHA256)/HKDF-SHA256/ChaCha20Poly1305 (open only is required on the phone; implement seal too for tests). Tests: RFC 9180 A.? auth-mode vector for this suite + `hpke.json`.
- [ ] SAS, relay auth signature (Ed25519), presence challenge — against fixtures.
- [ ] Everything works on `Uint8Array`; constant-time compare for tags comes from noble. Commit.

### Task C3: Protocol, transport, storage

**Files:** `web/src/protocol/*`, `web/src/transport/*`, `web/src/store/*`, `web/src/push/open.ts` + tests.
- [ ] Relay frames encode/decode (all of P.4 plus `webpush`), tested against `frames.json`.
- [ ] `commands.ts`: TS types + encoders/decoders for every phone-allowed `AppCommand` and every payload the screens read; tested against `app.json` (decode → encode → equal JSON).
- [ ] `RelayClient`: WebSocket `wss://<host>/v1/ws` subprotocol `prbar-relay.v1`, challenge/auth, ping 20 s, backoff 1→30 s with jitter, close codes (4403 → revoked state, 4409 → replaced), reconnect on `visibilitychange` to visible; disconnect 30 s after hidden.
- [ ] `Session`: KK handshake with the Mac over `send/recv`, reqIds, request/response with timeout, event streams, `sub` topics, protocol version check (→ `incompatible` state with "Update PRBar on your Mac.").
- [ ] Pairing driver: QR/URL parse, IKpsk2 with psk, SAS, confirm, store Mac info.
- [ ] `Transport` interface + `FakeTransport` for UI tests.
- [ ] `keys.ts` (IndexedDB `prbar` db; wrapping key `AES-GCM` 256 non-extractable; Ed25519/X25519 privates wrapped), `cache.ts`, `seen.ts` — tested with `fake-indexeddb` (dev dependency).
- [ ] Commit.

### Task C4: UI shell and phase 1 screens

**Files:** `web/src/ui/{app.tsx,router.ts,components/*,screens/{install,pairWelcome,pairScan,pairPaired,home,homeOffline}.tsx}`, `web/src/presence/webauthn.ts`
- [ ] Match `web/design/DESIGN.md` and the snapshots exactly: tab bar (To Review / My PRs / Activity / Settings), large titles, grouped lists, row layouts, badges, glass nav buttons, sheets. Components: `NavBar`, `TabBar`, `List/Row`, `Badge`, `Button` (filled/tinted/plain), `Sheet`, `Banner`, `Avatar`, `StatusDot`, `SegmentedControl`, `Toggle`, `CodeBlock/DiffView`.
- [ ] `install` screen when `!matchMedia('(display-mode: standalone)').matches && !navigator.standalone` (never generates keys there); Android `beforeinstallprompt` button.
- [ ] Pairing: name field, Pair → create passkey (W.4.6) → scan (getUserMedia rear camera + jsqr on a canvas, ~8 fps) or Paste code → SAS screen → paired → "Allow notifications" button.
- [ ] home, home:mine, home:offline with cache + stale banner; pull to refresh → `refresh`.
- [ ] Component tests with FakeTransport (vitest + @testing-library/preact). Commit.

### Task C5: Phase 2 and 3 screens

- [ ] review, review:menu, review:faceid, review:posted, edit, respond, respond:fixci, respond:diff, chat:review, chat:respond, merge, merge:faceid, merge:merged, chat:merge, activity, settings — exactly as DESIGN.md, with the same commands as R.4 of the iPhone spec. Gated actions call `presence/webauthn.ts` (W.5) right on the button tap (user gesture), then send the command with the proof. Settings: "Require Face ID for merge, push, approve and tests" (turning off is gated), notification kinds (Mac's `notifySet`), paired Mac, "Unpair this device" (clears IndexedDB, unsubscribes push), version.
- [ ] Tests per screen model with FakeTransport. Commit (can be split per phase).

### Task C6: Push and service worker

- [ ] `sw.ts`: precache shell (list injected at build), `push` handler per W.6 (open envelope with `devicePushKey` from IndexedDB through `keys.ts`; `seen.ts`; always `showNotification`), `notificationclick` (focus/open + navigate to deepLink hash), `setAppBadge`.
- [ ] `push/subscribe.ts`: get `/v1/vapid`, subscribe, send `webpush` frame; re-subscribe if `pushsubscriptionchange` or key changed.
- [ ] Unit tests for the push handler logic (pure function: payload → notification options). Commit.

### Task C7: E2E and snapshots

- [ ] `Scripts/web-e2e.sh`: builds relay (`go build`) and web (`npm run build`, then copies `web/dist` into the relay embed dir for the run only), builds `prbar-remote-fixture`, runs relay in test mode on a free port, runs the fixture Mac, runs Playwright. Re-exec under `arch -arm64` if under Rosetta (like `ios-e2e.sh`).
- [ ] Chromium (virtual WebAuthn authenticator via CDP `WebAuthn.addVirtualAuthenticator` with `isUserVerified: true`): install bypass (`display-mode` emulation or `?standalone=1` only honored in test builds — prefer Playwright `emulateMedia` + `navigator.standalone` init script), pair (read SAS from fixture stdout, `confirm`), home list shows fixture PRs, open PR, merge with Face ID → fixture reports merged, push arrives through test endpoint captured by a tiny local HTTP server and the SW shows the notification (assert via `registration.getNotifications()`).
- [ ] WebKit: pair + home list.
- [ ] `npm run snapshots`: Playwright screenshots of every screen (FakeTransport-driven story routes under a test-only entry, not shipped) at 393×852 @3x, light and dark → `web/test/snapshots/`.
- [ ] Run 3 times green. Commit.

## Track D — Cleanup and docs

### Task D1: Remove the native app and APNs

- [ ] Delete `ios/` (after C1 moved what's needed), `Scripts/ios-build-check.sh`, `Scripts/ios-e2e.sh`, Xcode/Team ID/APNs parts of `Scripts/iphone-setup.sh` and its tests (rewrite to: `--deploy-relay`, `--install-mac`, status; keep the confirmation prompts and stdin token piping), `docs/ios.md`, `docs/qa/plan-19-checklist.md`. Keep `ios/Icon/make_icon.py` only if still used (move to `web/design/icon/`).
- [ ] `.gitignore`: drop iOS entries, add `web/node_modules`, `web/dist`, `relay/internal/web/dist/*` except placeholder.
- [ ] Rewrite `docs/iphone.md` for the web app (install, pair, notifications, Face ID, limits, iOS data eviction). New `docs/qa/plan-20-checklist.md` (on-device steps).
- [ ] Spec: mark R of the iPhone spec as replaced by the web spec (one line at the top of R).
- [ ] Full Mac suite, `go test ./...`, `npm test`, e2e green. Commit.

### Task D2: Final review and push

- [ ] Security review of the whole diff (crypto port, WebAuthn verifier, Web Push, CSP/headers, Origin, SW). Fix findings.
- [ ] Scan diff for IP/paths/secrets/attribution. Push `feat/ios-app`.

---

**Parallelism:** A, B and C1–C2 are independent (different directories). C3 needs A3's fixtures (it can start with official vectors and add the cross-vectors when A3 lands). C4–C6 need C3. C7 needs A, B and C6. D after everything.
