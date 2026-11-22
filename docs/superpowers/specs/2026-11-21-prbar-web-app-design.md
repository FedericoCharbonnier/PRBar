# PRBar en el celular como web app (PWA) — reemplaza a la app nativa de iOS

Fecha: 2026-11-21. Reemplaza la parte **R** (app de iOS) de `2026-11-20-prbar-iphone-design.md` ("spec del iPhone") y
cambia P.2, P.8, P.9, P.11 y Q.2 de ese spec como dice abajo. Todo lo demás de P y Q (relay, cuentas, WebSocket,
Noise, marcos de aplicación, comandos permitidos, topes, redactor, buzón) **sigue igual**. Plan: `2026-11-21-prbar-plan-20-web-app.md`.

## Decisiones del usuario (2026-11-21, no se reabren)

1. **Web app instalable** (se agrega a la pantalla de inicio) en vez de app de Apple. No hace falta cuenta de Apple
   Developer, Xcode ni APNs.
2. **La sirve el mismo VPS** (el relay). Riesgo aceptado: quien controle el VPS puede cambiar la página y leer lo que pasa
   entre el celular y la Mac. El cifrado sigue protegiendo contra todos los demás (Traefik mal configurado, logs,
   backups del VPS, el servicio de push).
3. **Se borra la app nativa** (`ios/`, scripts de iOS, APNs). Queda en el historial de git.
4. **Preact + TypeScript + Vite**. Las pantallas son **las del mockup de iPhone** (`ios/DESIGN.md`, capturas en
   `ios/snapshots/`, que se mueven a `web/design/` antes de borrar `ios/`): mismas vistas, colores, textos, modo claro y
   oscuro. La app tiene que verse igual.
5. Siguen: un solo usuario, cifrado punta a punta, emparejamiento con QR + código de 6 dígitos, Face ID para merge, push,
   approve, tests y apagar Face ID, buzón de 7 días con toggle.

---

## W.1 Plataforma

- iOS 16.4+ (Web Push para apps en pantalla de inicio), Safari. Funciona también en Android/Chrome y en escritorio, sin
  trabajo extra (no se prueba a mano en cada uno).
- `manifest.webmanifest`: `display: standalone`, `name: "PRBar"`, íconos 180/192/512 (de `ios/Icon/` antes de borrarlo;
  el de iOS `apple-touch-icon` 180), `theme_color`/`background_color` de los tokens `bg` claro/oscuro.
- **Service worker** (`sw.ts`): precarga el shell (index, JS, CSS, íconos) para abrir sin red; maneja `push` y
  `notificationclick`. Estrategia: los assets con hash son inmutables; `index.html` y `sw.js` siempre se revalidan.
  Una versión nueva se activa al próximo arranque (sin recargar en medio de una acción).
- iOS guarda aparte los datos de Safari y los de la app en inicio: **todo pasa dentro de la app instalada**. Si la página
  se abre en Safari (no instalada), muestra solo la pantalla "Agregá PRBar a tu inicio" (W.4) y nunca genera claves.

## W.2 Código: `web/`

```
web/
  package.json, tsconfig.json, vite.config.ts, vitest.config.ts, playwright.config.ts
  index.html, public/ (íconos, manifest)
  design/ (DESIGN.md y capturas de referencia, movidas de ios/)
  src/
    crypto/   noise.ts (Noise_KK y Noise_IKpsk2 sobre @noble), hpke.ts (RFC 9180 modo auth), sas.ts, relayAuth.ts, b64.ts
    protocol/ relayFrames.ts, appFrames.ts, commands.ts (tipos TS de PRBarWire), remoteVersion.ts
    transport/ RelayClient.ts (WebSocket, auth, reconexión con backoff), Session.ts (KK, reqId, eventos), Transport.ts (interfaz + FakeTransport)
    store/    keys.ts (IndexedDB + envoltura AES-GCM no exportable), cache.ts (home y ≤ 50 PRs, LRU), seen.ts
    presence/ webauthn.ts (crear passkey, firmar desafío)
    push/     subscribe.ts, open.ts (HPKE del sobre; lo comparte el SW)
    ui/       tokens.css (de DESIGN.md), components/, screens/ (un archivo por id de pantalla), router.ts, app.tsx
    sw.ts
  test/       unit (vitest), fixtures/ (vectores de la Mac), e2e/ (playwright)
```

- Dependencias de runtime: `preact`, `@preact/signals`, `@noble/curves`, `@noble/hashes`, `@noble/ciphers`, `jsqr`
  (leer el QR con la cámara; Safari no tiene `BarcodeDetector`). Nada más. Versiones fijas y `package-lock.json`.
- Estado: un `AppStore` con signals (equivale al de R.3), un modelo por pantalla con `Transport` + `AppStore` inyectados.
- Rutas por hash (`#/home`, `#/pr/<owner>/<repo>/<n>/review`, …) con los mismos ids de pantalla del diseño.
- Los tipos de `PRBarWire` se escriben a mano en `commands.ts` y se prueban contra JSON que genera la Mac (W.9), así que
  un cambio en la Mac que rompa el formato rompe un test.

## W.3 Claves (cambia P.2 para el teléfono)

| Clave | Tipo | Dónde | Cambio |
|---|---|---|---|
| `deviceRelayKey` | Ed25519 (`@noble/curves`) | IndexedDB, envuelta | igual que antes |
| `deviceStatic` | X25519 | idem | igual |
| `devicePushKey` | X25519 | idem (el SW la lee) | igual |
| `presenceCredential` | passkey WebAuthn (ES256, P-256) | el iPhone (Llavero de iCloud) | **reemplaza** a `presenceKey` del Secure Enclave |

- **Envoltura**: una clave AES-GCM de WebCrypto creada con `extractable: false` y guardada como `CryptoKey` en IndexedDB;
  las privadas se guardan cifradas con ella. Protege contra copiar el almacenamiento, no contra código malicioso en la
  página (riesgo ya aceptado en la decisión 2).
- `navigator.storage.persist()` al emparejar. Si iOS borra los datos, la app vuelve a `pair:welcome` con "Este
  dispositivo perdió el vínculo. Volvé a vincularlo desde tu Mac." y la Mac lo da de baja cuando el usuario lo revoca.

## W.4 Instalación y emparejamiento (cambia P.11 y Q.2)

1. **Settings › iPhone** de la Mac (reemplaza el QR de TestFlight y `remote.appInstallURL`): "Open PRBar on your
   phone" con un QR a `https://<relay host>/` y el texto "Scan with your iPhone camera, then Share › Add to Home Screen."
   Se borran `remote.appInstallURL`, su allowlist y `prbar remote app-link`.
2. **La página en Safari** (no instalada): pantalla `install` con el ícono, "Add PRBar to your Home Screen" y los 3 pasos
   (Compartir → Agregar a inicio → abrir desde el ícono), en el estilo de `pair:welcome`. En Android/Chrome, botón
   "Install" con `beforeinstallprompt`.
3. **Ya instalada**: `pair:welcome` → **Pair** → `pair:scan` (cámara con `getUserMedia`, `jsqr`) o "Paste code" (pega el
   texto del QR, que `prbar remote pair` también imprime).
4. **QR de emparejamiento**: `https://<relay host>/#pair?v=1&r=…&a=…&p=…&k=…&m=…&n=…` (mismos campos que P.11; el
   fragmento `#` nunca llega al servidor). Si lo abre la cámara del sistema, cae en la página: instalada o no, el
   fragmento no se usa fuera de la app instalada (se muestra `install`).
5. Handshake `Noise_IKpsk2`, SAS y confirmación: **igual que P.11**. El payload cifrado del teléfono cambia
   `presenceKey.pub` por `{presence: {credentialId: b64url, publicKey: <SPKI DER b64url>, rpId: <relay host>}}`, y
   `model` es lo que se pueda saber (`"iPhone"`, `"Android"`, `"Mac"`; del user agent) más el nombre que elige el usuario
   en `pair:welcome` (por defecto "iPhone").
6. **La passkey se crea antes del handshake** (en el toque de "Pair", que es el gesto del usuario):
   `navigator.credentials.create` con `rp.id = <relay host>`, `user.id` = 16 bytes al azar, `pubKeyCredParams: ES256`,
   `authenticatorSelection: {authenticatorAttachment: "platform", residentKey: "required", userVerification:
   "required"}`, `attestation: "none"`. La clave pública sale de `response.getPublicKey()` (SPKI); si el navegador no lo tiene, se arma desde la clave COSE de `attestedCredentialData` en `authenticatorData`. Sin passkey (el
   navegador no la soporta o el usuario cancela) no se puede emparejar con Face ID; el emparejamiento sigue y la Mac
   marca ese dispositivo con `requirePresence = true` y sin credencial, así que **los comandos gated quedan bloqueados**
   ("Face ID isn't set up on this device. Pair it again.").
7. Después de `pair:paired`: pedir permiso de notificaciones (botón, iOS exige gesto) y suscribir Web Push (W.6).

## W.5 Face ID con passkey (reemplaza P.8)

- Para un comando gated el teléfono llama `navigator.credentials.get({publicKey: {rpId, challenge, allowCredentials:
  [credentialId], userVerification: "required", timeout: 60000}})`. En iPhone eso es Face ID (o el código, si iOS lo
  ofrece: lo decide iOS; la Mac exige `UV`).
- `challenge = SHA256("PRBarPresence v2" ‖ sessionHash(32) ‖ reqId(u64 BE) ‖ SHA256(cmd bytes) ‖ ts(i64 BE, ms))`.
- `PresenceProof` pasa a `{v: 2, ts, credentialId, authenticatorData, clientDataJSON, signature}` (b64url).
- **La Mac verifica** (`WebAuthnPresenceVerifier`, en `PRBarRemoteKit`, con CryptoKit):
  1. `credentialId` es el del dispositivo; `clientDataJSON` parsea, `type == "webauthn.get"`, `challenge` (b64url) es
     el esperado, `origin == "https://<relay host>"`, sin `crossOrigin: true`.
  2. `authenticatorData`: `rpIdHash == SHA256(relay host)`, flags `UP` y `UV` prendidos.
  3. Firma ECDSA P-256 (DER) sobre `authenticatorData ‖ SHA256(clientDataJSON)` con la SPKI guardada.
  4. `|ts − ahora| ≤ 60 s` y `reqId` no usado (igual que P.8). El contador de firmas no se usa (las passkeys de iCloud
     dan 0).
  Falla → `CommandFailure(.unauthorized, "Face ID is required for this on iPhone.")`, igual que hoy.
- Las passkeys se sincronizan por el Llavero de iCloud: otro dispositivo Apple del mismo usuario podría firmar, pero
  además necesita las claves de sesión de este teléfono, que no salen de él. Aceptado.
- La versión 1 (Secure Enclave) se borra de la Mac.

## W.6 Notificaciones con Web Push (reemplaza la parte de APNs de P.9)

- El relay tiene un par **VAPID** (P-256) en el `.env` (`VAPID_PRIVATE_KEY` b64url, `VAPID_SUBJECT=mailto:` o
  `https://<relay host>`); `GET /v1/vapid` devuelve la pública. Sin VAPID el relay arranca con pushes apagados (como
  hoy sin APNs).
- El teléfono: `pushManager.subscribe({userVisibleOnly: true, applicationServerKey})` y manda por el WebSocket
  `{"t":"webpush","endpoint":"…","p256dh":"<b64url>","auth":"<b64url>"}` (reemplaza `apns`). **El relay solo acepta
  endpoints https de** `web.push.apple.com`, `fcm.googleapis.com`, `updates.push.services.mozilla.com` y
  `*.notify.windows.com` (evita que el relay haga pedidos a cualquier lado), ≤ 1 KiB.
- Contenido: el mismo sobre HPKE de P.9 (`info = "PRBar push v1" ‖ accountId ‖ deviceId`), pero el texto plano baja a
  **≤ 2 048 bytes** (relleno a múltiplo de 256) porque Web Push admite ~4 KB cifrados. El relay arma
  `{"v":1,"e":"<b64>","c":"<collapse>","th":"<thread>"}` y lo cifra con RFC 8291 (`aes128gcm`) para la suscripción;
  headers `TTL: 86400`, `Urgency: high`, `Topic: <collapse truncado a 32 chars b64url>`, `Authorization: vapid t=…, k=…`
  (RFC 8292, JWT ES256 de 12 h, `aud` = origen del endpoint). Implementación propia en Go con la biblioteca estándar
  (`crypto/ecdh`, `crypto/ecdsa`, AES-GCM) + `golang.org/x/crypto/hkdf`, probada con el vector del apéndice A de
  RFC 8291. `404`/`410` borran la suscripción y la Mac recibe `pushResult`. Tope igual: 60/min por cuenta.
- **Service worker** en `push`: abre el sobre con `devicePushKey` (lee IndexedDB), rechaza `createdAt` > 24 h o > 10 min
  en el futuro e ids ya vistos (últimos 200), y llama `showNotification(title, {body, tag: thread, data: {deepLink},
  badge, icon})`. **Siempre muestra algo** (iOS corta las suscripciones que reciben pushes sin notificación): si no
  descifra, "PRBar — New activity on your Mac". `setAppBadge` con el badge descifrado si existe.
- `notificationclick`: enfoca la ventana abierta o abre una, y navega al `deepLink` (ruta por hash). Las acciones de la
  notificación del diseño se omiten (Web Push en iOS no las muestra); tocar la notificación abre la pantalla del PR. Las
  gated piden Face ID ahí, nunca desde la notificación.

## W.7 Relay (cambios)

- **Sirve la web app** embebida en el binario (`//go:embed` de `web/dist`, que el Dockerfile construye en una etapa
  `node`): `GET /` y los assets. Headers: `Content-Security-Policy: default-src 'self'; script-src 'self';
  style-src 'self'; img-src 'self' data: blob:; connect-src 'self' wss://<host>; media-src 'self' blob:;
  worker-src 'self'; manifest-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Permissions-Policy: camera=(self)`,
  `Strict-Transport-Security: max-age=31536000`. `Cache-Control: no-cache` para `/`, `/index.html`, `/sw.js`,
  `/manifest.webmanifest`; `immutable, max-age=31536000` para `/assets/*`.
- **WebSocket**: si llega header `Origin`, tiene que ser `https://<relay host>` (la Mac no manda `Origin`); si no, 403.
- Se borran `internal/apns`, las variables `APNS_*` y el secreto `.p8` del compose; se agrega `internal/webpush`.
- `relay/deploy/deploy.sh` genera el par VAPID en el server la primera vez (como el token de inscripción) si falta.

## W.8 Mac (cambios)

- `CommandProtocol.version` y `minimumRemoteVersion` → **8** (cambia la prueba de presencia y el registro de push).
- `RemoteDevice` guarda `presence: {credentialId, spki}?` en lugar de `presenceKey` (x963). `devices.json` viejos (de
  la app nativa, que nunca se usó con un teléfono real) se descartan: el servicio los lee como vacíos.
- `WebAuthnPresenceVerifier` reemplaza la verificación P-256 de P.8.
- Settings › iPhone: el QR "Open PRBar on your phone" (W.4.1). El QR de emparejamiento usa el URL https de W.4.4;
  `prbar remote pair` imprime también ese URL para pegar.
- `docs/iphone.md` se reescribe para la web app; `docs/ios.md` se borra.

## W.9 Pruebas

- **Cripto (vitest)**: los mismos vectores oficiales que usa la Mac (Noise KK/IKpsk2 de cacophony, HPKE RFC 9180,
  X25519/Ed25519), más **vectores cruzados** que genera la Mac (`swift run PRBarRemoteFixtures --web-vectors
  web/test/fixtures/`): un emparejamiento y una sesión KK completos con claves fijas, un sobre HPKE, un SAS, una firma de
  auth del relay y JSON de muestra de cada comando, evento y marco. La web tiene que producir y aceptar los mismos bytes.
- **Mac**: tests del `WebAuthnPresenceVerifier` con una aserción real generada en el test (P-256 de software armando
  `authenticatorData` y `clientDataJSON`), y los casos de rechazo (UV apagado, otro origen, otro rpId, otro challenge,
  otra credencial, `ts` viejo, `reqId` repetido).
- **Relay (go test)**: Web Push con el vector de RFC 8291, JWT VAPID, allowlist de endpoints, headers de la web,
  `Origin`.
- **E2E (Playwright)**: `Scripts/web-e2e.sh` levanta el relay local (`RELAY_TEST_MODE`), una Mac simulada
  (`PRBarRemoteFixtures --serve`) y la web; en **Chromium** con autenticador virtual de WebAuthn: emparejar (SAS),
  ver la lista, abrir un PR, merge con Face ID simulado, recibir un push (endpoint falso que captura el relay en modo
  test); en **WebKit**: emparejar y ver la lista (WebKit de Playwright no tiene autenticador virtual).
- **Visual**: capturas de cada pantalla en claro y oscuro (`npm run snapshots` → `web/test/snapshots/`), comparadas
  con `web/design/` a ojo por quien revisa.
- Todo corre sin Xcode.

## W.10 Lo que tiene que hacer el usuario

1. Volver a desplegar el relay (`relay/deploy/deploy.sh`; genera VAPID).
2. Instalar en la Mac la versión de esta rama (con confirmación).
3. En el iPhone: escanear el QR de Settings › iPhone, Agregar a inicio, abrir, Pair, escanear el QR de
   `prbar remote pair`, comparar el código, permitir notificaciones.

No hace falta: cuenta paga, APNs, Xcode, cable, Developer Mode ni espacio para el SDK de iOS.
