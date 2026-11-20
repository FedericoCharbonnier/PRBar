# PRBar para iPhone — control remoto de la Mac con cifrado de punta a punta

Fecha: 2026-11-20. Extiende `2026-11-18-prbar-design.md` ("spec base"), `2026-11-19-prbar-chat-cli-updates-design.md`
(sobre todo la parte **C**: `AppCommand`, `CommandProtocol`, `CommandDispatcher`, paridad UI ↔ CLI) y
`2026-11-20-prbar-ci-fix-and-cost-design.md` (rama `feat/ci-cost`: Fix CI y costo de Claude, protocolo 6). Tres planes:

| Parte | Plan |
|---|---|
| P. Protocolo compartido (`PRBarWire`, `PRBarRemoteKit`) y relay en el VPS | `2026-11-20-prbar-plan-17-remote-kit-and-relay.md` |
| Q. Lado Mac: acceso remoto, emparejamiento, dispositivos, puente a `AppCommand`, pushes, CLI | `2026-11-20-prbar-plan-18-mac-remote-access.md` |
| R. App de iOS (fases 1–3), extensión de notificaciones, Face ID | `2026-11-20-prbar-plan-19-ios-app.md` |

Orden: 17 → 18 → 19 (la fase 1 de la 19 puede arrancar cuando 17 y las tasks de emparejamiento y estado de 18 estén).
Los tres asumen `feat/ci-cost` ya mergeada (`CommandProtocol.version == 6`, `ciList`, `ciFix`, `usage`).

Diseño visual: proyecto de diseño "PRBar iOS" (entrada `PRBar iOS.dc.html`). El resumen que siguen los implementadores
es `DIGEST.md` (ver R.1); los ids de pantalla de este spec (`home`, `review:faceid`, …) son los del diseño.

---

## Decisiones del usuario (no se reabren)

1. App **nativa de iOS** (cuenta de Apple Developer propia) + **relay en el VPS** del usuario. Un solo usuario; varios
   dispositivos de ese usuario funcionan; equipos, más adelante.
2. **Cifrado de punta a punta**: el relay ve solo texto cifrado opaco e ids de ruteo. También manda los pushes de APNs,
   cuyo contenido visible se descifra en el teléfono (Notification Service Extension, `mutable-content`). Un VPS
   comprometido no puede leer código ni PRs, ni mandar comandos.
3. **Emparejamiento** con un QR que muestra la Mac + un **código de 6 dígitos** que se ve en los dos lados. Dispositivos
   revocables desde Settings de la Mac.
4. **Face ID** en el teléfono para **merge, push y approve** (ajuste del diseño: "Require Face ID for merge, push and
   approve").
5. **La Mac hace todo** (GitHub, Claude, Slack, push, merge). La Mac sale **hacia** el relay (WebSocket sobre TLS); no
   abre puertos. Mac dormida o apagada → el teléfono muestra el estado offline con lo cacheado en gris.
6. **Alcance**: todo lo que hace la app de la Mac, en fases. Fase 1: relay + emparejamiento + listas en vivo (las dos
   pestañas) + notificaciones + offline. Fase 2: Review y publicar; Respond y Fix CI con diff/undo/push. Fase 3: Merge con
   Face ID, chat con Claude, Activity, Settings (el subconjunto del diseño).
7. **VPS**: ARM64 (2 vCPU, 4 GB), `docker compose` + Traefik (`/root/stack/proxy`), red externa `coolify`, host
   `prbar.fcharbonnier.duckdns.org`. Guía del server: `/root/stack/LEEME.md`.
8. La Mac tiene solo Command Line Tools; el usuario instala Xcode para la app de iOS. **El relay y todo lo de la Mac se
   construyen y testean sin Xcode.**

---

## P. Arquitectura y protocolo

### P.1 Vista general

```
iPhone (PRBar iOS)                         VPS (prbar-relay, Go)                       Mac (PRBar.app)
┌──────────────────────┐   wss (TLS por    ┌──────────────────────────┐   wss (sale    ┌───────────────────────┐
│ SwiftUI + view models│   Traefik)        │ auth por desafío Ed25519 │   de la Mac)   │ RemoteAccessService    │
│ RemoteClient ────────┼──────────────────►│ ruteo por ids            │◄───────────────┼─ RemoteHost (Kit)      │
│  Noise KK (sesión)   │  ciphertext       │ buzón (TTL)              │  ciphertext    │  Noise KK, HPKE        │
│ NSE: HPKE open       │◄── APNs ──────────┤ APNs (.p8 solo acá)      │                │  RemotePolicy          │
│ Secure Enclave (P256)│                   │ sin contenido en logs    │                │  → CommandDispatcher   │
└──────────────────────┘                   └──────────────────────────┘                │  → AppModel (lo mismo  │
                                                                                       │    que la UI y la CLI) │
                                                                                       └───────────────────────┘
```

- **El teléfono es otro cliente de `AppCommand`**, como `prbar`: no reimplementa lógica. Cada acción del teléfono es un
  `AppCommand` que la Mac pasa por `CommandDispatcher.run` sobre el mismo `AppModel`. Lo nuevo es el transporte
  (relay + cifrado), una **lista permitida** (P.7), la **atestación de presencia** (P.8) y un **feed de estado** que la
  Mac empuja (P.6), porque la CLI hace polling y el teléfono necesita listas en vivo.
- **Código compartido** (SwiftPM, compila en macOS con CLT y en iOS con Xcode):
  - `PRBarWire` (target nuevo): los tipos `Codable` puros que viajan — `AppCommand`, `AppCommandTypes`, los structs de
    `CommandResults`, `JSONValue`, `CommandRequest`/`CommandResponse`/`CommandEvent`/`CommandFailure`/`Hello`, y las
    hojas que referencian (`Severity`, `PopoverTab`, `PopoverSection`, `MergeMethod`, `ReviewEvent`, …). Solo
    `Foundation`. `PRBarCore` depende de `PRBarWire` y lo re-exporta (`@_exported import PRBarWire`): ningún archivo
    existente cambia sus `import`.
  - `PRBarRemoteKit` (target nuevo): cifrado (Noise, HPKE, SAS, presencia), framing, protocolo del relay, cliente de
    WebSocket (`URLSessionWebSocketTask`), política (`RemotePolicy`), y las dos máquinas de estado: `RemoteHost` (Mac) y
    `RemoteClient` (teléfono), cada una detrás de protocolos para testear sin red. Depende de `PRBarWire` y `CryptoKit`.
  - Producto `.library(name: "PRBarRemoteKit")` que la app de iOS consume como paquete local.
  - Ninguno de los dos importa `AppKit`, `Darwin` de sockets, `Process` ni `IOKit` (un test lo verifica con `grep`).
- **Relay**: Go, binario estático en una imagen distroless (P.10). Nunca descifra nada.

### P.2 Identidades y claves

Todas las primitivas son de **CryptoKit** en los dos lados de Apple. Los nombres de las claves son los del código.

| Dueño | Clave | Tipo | Dónde vive | Para qué |
|---|---|---|---|---|
| Mac | `macRelayKey` | Ed25519 (`Curve25519.Signing`) | Llavero de login (`KeychainStore`, servicio `PRBar Remote`) | Autenticarse ante el relay |
| Mac | `macStatic` | X25519 (`Curve25519.KeyAgreement`) | idem | Estática de Noise (sesiones y emparejamiento) |
| Mac | `macSealKey` | X25519 | idem | Remitente HPKE (modo auth) de pushes y buzón |
| iPhone | `deviceRelayKey` | Ed25519 | Llavero, `AfterFirstUnlockThisDeviceOnly`, grupo compartido con la NSE | Autenticarse ante el relay |
| iPhone | `deviceStatic` | X25519 | idem | Estática de Noise |
| iPhone | `devicePushKey` | X25519 | idem (la NSE la necesita para descifrar) | Destinatario HPKE de pushes y buzón |
| iPhone | `presenceKey` | P-256 en **Secure Enclave** (`SecureEnclave.P256.Signing`) con `[.privateKeyUsage, .biometryCurrentSet]` | Secure Enclave; nunca sale | Firmar la atestación de Face ID (P.8) |

- Claves separadas por uso (no se reusa una X25519 para Noise y HPKE). Ninguna clave privada sale de su dispositivo.
- La Mac guarda por dispositivo: `deviceId`, nombre y modelo (los manda el teléfono), `deviceStatic.pub`,
  `devicePushKey.pub`, `presenceKey.pub` (x963), fecha de emparejamiento, `requirePresence` (P.8), último visto. En
  `~/Library/Application Support/PRBar/remote/devices.json` (0600; solo claves públicas). El relay guarda solo
  `deviceId`, `deviceRelayKey.pub` y el token de APNs.
- `accountId`: 16 bytes al azar (base32 minúscula sin relleno, 26 caracteres) que la Mac elige al habilitar. `deviceId`:
  igual, lo elige la Mac al emparejar.

### P.3 Cuenta en el relay e inscripción

- El relay solo acepta cuentas nuevas con un **token de inscripción** (`RELAY_ENROLL_TOKEN`, 32 bytes al azar, en el
  `.env` del server). Sin eso cualquiera podría usar el relay (y los pushes del usuario).
- `POST /v1/accounts` `{"enrollToken": "...", "macRelayKey": "<b64url 32B>"}` → `{"accountId": "..."}`. Comparación en
  tiempo constante. Tope de cuentas (`RELAY_MAX_ACCOUNTS`, por defecto 4). 5 intentos fallidos por IP en 10 min →
  bloqueo de 15 min.
- La Mac pide el token una sola vez (Settings › iPhone o `prbar remote enable --relay H --enroll-token-stdin`) y no lo
  guarda: después se autentica con `macRelayKey`.

### P.4 Conexión al relay (WebSocket)

`GET wss://<host>/v1/ws`, subprotocolo `prbar-relay.v1`. Marcos de texto JSON (claves cortas; el cifrado va en base64url
sin relleno, campo `b`). Máximo 128 KiB por marco.

1. Servidor → `{"t":"challenge","nonce":"<b64url 32B>","time":<unix>}`.
2. Cliente (en ≤ 5 s) → uno de:
   - Mac: `{"t":"auth","acct":"<accountId>","client":"mac","sig":"<b64url>"}`
   - Teléfono: `{"t":"auth","acct":"…","client":"<deviceId>","sig":"…"}`
   - Emparejamiento: `{"t":"auth","acct":"…","client":"pair","pairing":"<pairingId>","proof":"<b64url>"}`
   `sig` = Ed25519 sobre `"PRBarRelayAuth v1\n" ‖ host ‖ "\n" ‖ acct ‖ "\n" ‖ client ‖ "\n" ‖ nonce` (bytes; `host` es
   el host público del relay, para que una firma no sirva en otro relay). `proof` = HMAC-SHA256(`pairAuthKey`, `nonce`).
3. Servidor → `{"t":"ready","mac":"online"|"offline","since":<unix>}` o cierra con un código (abajo).

Después, **solo ruteo**:

| Marco | Quién | Qué hace el relay |
|---|---|---|
| `{"t":"send","to":"mac"\|"<deviceId>"\|"pair:<pairingId>","sid":"<16 hex>","b":"…"}` | todos (un teléfono solo a `mac`; `pair` solo a `mac`; la Mac a sus dispositivos o a `pair:`) | Entrega `{"t":"recv","from":…,"sid":…,"b":…}` si el destino está conectado; si no, `{"t":"undeliverable","to":…,"sid":…}`. Orden FIFO por par origen→destino. |
| `{"t":"presence",…}` | relay → clientes | A los teléfonos: `{"mac":"online"\|"offline","since":…}`. A la Mac: `{"device":"<id>","state":"online"\|"offline"}`. |
| `{"t":"push","id":"<uuid>","to":"<deviceId>","collapse":"<≤64 hex>","thread":"<32 hex>","b":"…"}` | solo Mac | Arma y manda el push de APNs (P.9). Contesta `{"t":"pushResult","id":…,"status":<http>,"reason":"…"}`. |
| `{"t":"mbox.put","to":"<deviceId>","slot":"home","b":"…"}` | solo Mac | Guarda el blob (reemplaza el del mismo slot). TTL 7 días, ≤ 512 KiB, ≤ 4 slots por dispositivo. |
| `{"t":"mbox.get"}` | teléfono | `{"t":"mbox","items":[{"slot":…,"b":…,"at":<unix>}]}` |
| `{"t":"apns","token":"<hex>","env":"sandbox"\|"production"}` | teléfono | Guarda/actualiza su token. |
| `{"t":"pair.open","pairing":"<id>","authKey":"<b64url 32B>","expires":<unix>}` / `{"t":"pair.close","pairing":…}` | solo Mac | Abre/cierra la ranura de emparejamiento (en memoria, ≤ 5 min, una por cuenta). |
| `{"t":"device.add","device":"<id>","relayKey":"<b64url>"}` / `{"t":"device.remove","device":…}` / `{"t":"devices"}` | solo Mac | Alta/baja (la baja cierra su conexión con 4403, borra token y buzón) / lista `{id, lastSeen}`. |
| `{"t":"ping"}` → `{"t":"pong"}` | todos | Cada 20 s (además del ping de WebSocket). |

Códigos de cierre: 4401 no autorizado · 4403 dispositivo dado de baja · 4408 sin `auth` a tiempo · 4409 reemplazado (el
mismo cliente se conectó de nuevo: gana el último) · 4413 marco demasiado grande · 4429 límite de tasa.

### P.5 Sesiones cifradas (Noise)

- **Sesión normal: `Noise_KK_25519_ChaChaPoly_SHA256`.** Inicia el teléfono cuando el relay le dice que la Mac está
  online (al conectar, o con `presence`). Las dos estáticas ya se conocen (emparejamiento). Prólogo:
  `"PRBar Remote v1" ‖ accountId ‖ deviceId`. Dos mensajes (`-> e, es, ss` / `<- e, ee, se`): autenticación mutua y
  secreto hacia adelante. Payload del primer mensaje: vacío (es repetible: nunca lleva comandos).
- **`sid`**: 8 bytes al azar del iniciador (hex). La Mac mantiene `sid → sesión`; una sesión nueva del mismo dispositivo
  reemplaza a la anterior.
- **Transporte**: los `CipherState` de Noise (nonce = contador de 64 bits, estricto y en orden). Un mensaje fuera de
  orden, repetido o que no autentica **cierra la sesión** (el teléfono reconecta y hace otro handshake). El relay
  preserva el orden; no hay retransmisión dentro de una sesión.
- **Rotación**: handshake nuevo en cada reconexión, a las 24 h de sesión, o a los 2²⁰ mensajes en cualquier dirección.
  No se usa `Rekey()` de Noise.
- **Tamaño**: un mensaje de Noise es ≤ 65 535 bytes. Cada marco de aplicación (P.6) se parte en **trozos**; el texto
  plano de cada trozo es `flags(u8) ‖ len(u16 BE) ‖ datos ‖ ceros` hasta un múltiplo de 256 bytes (máximo 65 280 de
  texto plano por trozo). `flags`: bit 0 = siguen más trozos, bit 1 = datos comprimidos (zlib de Foundation). Un marco
  armado mide ≤ 16 MiB; más → se cierra la sesión.
- **Compresión**: **ninguna al mandar** (corregido tras la revisión de cifrado, P.15 M2). `home` y muchas respuestas
  mezclan datos privados (PRs de repos privados, código, salida de Claude) con texto que escribe cualquiera (títulos y
  comentarios de PRs de repos públicos): comprimir antes de cifrar dejaría que quien mide los marcos (el relay, o la red
  por el tamaño de los registros TLS) adivine lo privado inyectando texto, al estilo CRIME. El bit 1 del trozo se sigue
  aceptando al recibir, por compatibilidad; los marcos son más grandes pero el tope de 16 MiB sobra.
- **Emparejamiento: `Noise_IKpsk2_25519_ChaChaPoly_SHA256`** (P.11): el teléfono conoce la estática de la Mac por el QR;
  el PSK sale del secreto del QR.

Vectores de prueba: los oficiales de Noise (formato de *cacophony*) para `Noise_KK_25519_ChaChaPoly_SHA256` y
`Noise_IKpsk2_25519_ChaChaPoly_SHA256`, embebidos en los tests de `PRBarRemoteKit` (con efímeras fijas inyectadas).

### P.6 Marcos de aplicación

Dentro de la sesión, JSON (`CommandProtocol.encoder`: claves ordenadas, fechas ISO 8601). Un tipo por marco, `RemoteFrame`:

| Marco | Dirección | Contenido |
|---|---|---|
| `hello` | ambos, primero | `{remoteProtocol: 1, commandProtocol: N, appVersion, deviceName?, macName?}` |
| `req` | teléfono → Mac | `{id: Int, sentAt: Date, cmd: <bytes JSON de AppCommand, base64>, presence?: PresenceProof}` |
| `res` | Mac → teléfono | `CommandResponse` tal cual (`id`, `ok`, `result`, `error`, `event`): los eventos `progress`/`text` del dispatcher llegan igual que a la CLI |
| `sub` | teléfono → Mac | `{topics: [String]}` (reemplaza el conjunto anterior) |
| `state` | Mac → teléfono | `{topic, rev: Int, data: JSONValue}` |
| `chatDelta` | Mac → teléfono | `{pr, text}` para un chat que no inició el teléfono (p. ej. desde la Mac) |
| `unpair` | teléfono → Mac | "Unpair this iPhone": la Mac lo da de baja como un Revoke |
| `presencePolicy` | Mac → teléfono | `{requirePresence: Bool, gated: [AppCommand.Name]}` (con `hello` y al cambiar) |
| `bye` | ambos | cierre ordenado |

- **`cmd` va como bytes**: la Mac hashea exactamente lo que recibió (P.8) y recién después decodifica `AppCommand`.
- **`sentAt`**: la Mac rechaza un `req` con más de **120 s** de antigüedad o más de 30 s en el futuro
  (`CommandFailure(.invalidState, "This request expired. Try again.")`). Así el relay no puede retener un comando y
  soltarlo después. Los ids de `req` son crecientes por sesión; uno repetido se rechaza.
- **Tópicos** (los arma `RemoteStateFeed` en la Mac reusando los resultados de `AppCommand`):
  - `home`: `RemoteHome {status: StatusInfo, prs: [PRInfo] (las dos pestañas, con tab y section), ci: [CIListEntry] (de ciList)}`
    — es `status` + `listPRs(nil, nil, nil)` + `ciList`.
  - `pr:<owner/repo#N>`: `RemotePRDetail {pr: PRInfo, review: ReviewInfo?, respond: RespondInfo?, merge: MergeInfo?, chat: ChatInfo?}`
    — `reviewShow`/`respondShow`/`chatShow` sin errores de "no hay".
  - `activity`: `ResourcesInfo` + `usage(nil)` + los últimos 20 `history`.
  La Mac recalcula un tópico cuando cambia `AppModel` (observación con `withObservationTracking`, agrupado cada 300 ms) y
  lo manda solo si cambió (`Equatable`), con `rev` creciente. `activity` se recalcula cada 5 s mientras esté suscrito.
- **Versiones**: `remoteProtocol` (este documento, 1) cambia solo si cambia el framing. `commandProtocol` es
  `CommandProtocol.version`. La Mac acepta un teléfono con `commandProtocol` entre
  `CommandProtocol.minimumRemoteVersion` y el actual (los casos de `AppCommand` solo se agregan; un cambio que rompe sube
  el mínimo). Fuera de rango → `hello` con error y el teléfono muestra "Update PRBar on your Mac" o "Update PRBar on this
  iPhone". Al implementar, `CommandProtocol.version` sube a **7** (comandos `remote*`, Q.5) y `minimumRemoteVersion = 7`.

### P.7 Qué comandos se permiten desde el teléfono

`RemotePolicy` (en `PRBarRemoteKit`) clasifica **cada** `AppCommand.Name` con un `switch` exhaustivo: un caso nuevo no
compila hasta que alguien decide. Clases: `.allowed`, `.gated` (Face ID, P.8), `.denied`.

| Clase | Comandos |
|---|---|
| Lectura (allowed) | `status`, `listPRs`, `resolvePR`, `history`, `historyShow`, `reviewShow`, `respondShow`, `respondDiff`, `mergePreview`, `chatShow`, `resources`, `usage`, `ciList`, `notifyList` |
| Acciones (allowed) | `refresh`, `reviewStart`, `reviewEdit`, `reviewSetIncluded`, `reviewSetComment`, `reviewPublish` (comment / request changes), `reviewCancel`, `reviewDismiss`, `respondStart`, `respondSelect`, `respondReset`, `respondImplement`, `respondTest`, `respondReplyOnly`, `respondCancel`, `respondDismiss`, `ciFix`, `mergeDismiss`, `chatSend`, `chatUndo`, `chatStop`, `notifySet`, `notifySetEnabled` |
| Face ID (gated) | `merge`, `respondPush`, `respondPushAnyway`, `reviewPublish` con `event == .approve`, y `remoteSetPresenceRequirement(false)` |
| Denegados | todo lo demás: ventanas y app (`open*`, `quit`, `openPopover`, `historyReopen`), cuentas/repos/follow, `tools*`, Slack (incluye tokens y `slackSelfTest`), `update*`, `runner*`, `rules*`, `claude*` de escritura, prompts, `cleanup`, `setLaunchAtLogin`, `setRefreshInterval`, `setDiskWarning`, `setUpdateInterval`, `chatProposal`, `configShow`, `claudeShow`, `toolsList`, `slackShow`, y todos los `remote*` |

- Criterio: nada que cambie rutas de herramientas, tokens, destinos SSH, el updater, o que muestre secretos o rutas
  locales; de Settings solo las notificaciones (el resto de Settings del teléfono es local al teléfono, R.6).
- Un comando denegado contesta `CommandFailure(.unauthorized, "This can’t be done from iPhone. Use PRBar on your Mac.")`
  y se loguea su `name` (nunca los argumentos).
- `confirmed` sigue siendo obligatorio donde hoy lo es (el teléfono lo manda después de su hoja de confirmación).

### P.8 Face ID: atestación de presencia firmada en el Secure Enclave

- En el teléfono, las acciones gated piden Face ID (pantallas `review:faceid`, `merge:faceid`). La firma con
  `presenceKey` **es** el Face ID: la clave tiene `.biometryCurrentSet`, así que el Secure Enclave no firma sin una
  autenticación biométrica actual (sin código de desbloqueo como alternativa).
- `PresenceProof {ts: Date, sig: Data}` va en el `req`. Lo firmado (ECDSA P-256/SHA-256, DER):
  `"PRBarPresence v1" ‖ sessionHash(32) ‖ reqId(u64 BE) ‖ SHA256(cmd bytes) ‖ ts(i64 BE, ms)`.
  `sessionHash` es el hash del handshake de Noise de esa sesión: la prueba no sirve en otra sesión, para otro comando, ni
  para otro `req`.
- La Mac, para un comando gated y un dispositivo con `requirePresence` (por defecto `true`): exige la prueba, verifica la
  firma con la `presenceKey.pub` registrada al emparejar, `|ts − ahora| ≤ 60 s`, y que el `req` no se haya usado.
  Si falla: `CommandFailure(.unauthorized, "Face ID is required for this on iPhone.")`. **La verificación es de la Mac**:
  un teléfono modificado no puede saltearla.
- `requirePresence` es por dispositivo y lo decide la Mac. El ajuste del teléfono ("Require Face ID for merge, push and
  approve") manda `remoteSetPresenceRequirement(enabled:)`; **apagarlo es en sí gated** (hay que pasar Face ID para
  apagarlo), prenderlo no.
- Si cambian los rostros de Face ID, la clave queda inválida: el teléfono lo detecta (`SecKeyCreateSignature` falla con
  `errSecItemNotFound`/biometría cambiada) y muestra "Face ID changed. Pair this iPhone again from your Mac." Re-emparejar
  reemplaza al dispositivo (mismo nombre, `deviceId` nuevo).

### P.9 Notificaciones push

- **Quién decide**: la Mac, con el mismo `NotificationPlanner` de hoy (y las de Fix CI de `feat/ci-cost`). Cuando
  `AppModel` entrega `PlannedNotification`s locales, `RemoteAccessService` también las manda a cada dispositivo con
  token. Las preferencias son las de la Mac (`notifySet`, que el teléfono puede cambiar).
- **Cifrado**: **HPKE modo auth** (RFC 9180) de CryptoKit, suite `DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
  ChaCha20Poly1305` (`HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly`): remitente `macSealKey`, destinatario
  `devicePushKey`, `info = "PRBar push v1" ‖ accountId ‖ deviceId`. Texto plano (JSON, relleno a múltiplo de 256, ≤ 2 816
  bytes): `{v:1, id: UUID, createdAt, kind, title, body, threadId, pr?, deepLink, badge?}`. Encapsulado + cifrado en
  base64 en el campo `e` del payload de APNs.
- **Payload que arma el relay** (lo único que ven el relay y Apple):

  ```json
  {"aps":{"alert":{"title":"PRBar","body":"New activity on your Mac"},"mutable-content":1,"sound":"default",
          "thread-id":"<thread>","category":"PR"},"e":"<b64>","v":1}
  ```
  Headers: `apns-push-type: alert`, `apns-priority: 10`, `apns-topic: <bundle id>`, `apns-expiration: now+86400`,
  `apns-collapse-id: <collapse>`. `collapse` = hex de HMAC-SHA256(`pushIdKey`, `kind ‖ pr`) truncado a 32 bytes, y
  `thread` = lo mismo con `"thread" ‖ pr` truncado a 16: opacos para el relay y para Apple, estables para agrupar y
  reemplazar. `pushIdKey` = HKDF de la clave compartida HPKE estática (sale de `macSealKey` × `devicePushKey`), así que
  los dos lados lo saben y nadie más.
- **NSE** (`PRBarMobileNotifications`): abre el sobre con `devicePushKey` (llavero compartido), rechaza `createdAt` de
  más de 24 h y `id` ya vistos (últimos 200 en el contenedor del grupo), y reemplaza título, cuerpo, `threadIdentifier`,
  `badge` y `userInfo["deepLink"]`. **Si no puede descifrar** (clave borrada, dispositivo revocado, payload roto) queda lo
  visible: "PRBar — New activity on your Mac". Nunca muestra texto sin descifrar.
- **Acciones de la notificación** (pantalla `lock notifications` del diseño): todas `.foreground` (abren la app en la
  pantalla del PR). Las gated nunca corren desde la notificación: abren la hoja con Face ID.
- **APNs en el relay**: autenticación por token (JWT ES256 con la `.p8`, `kid` = Key ID, `iss` = Team ID, renovado cada
  50 min), HTTP/2 a `api.push.apple.com` o `api.sandbox.push.apple.com` según el `env` del token. La `.p8` vive **solo**
  en el VPS (`/root/stack/env/prbar-relay.p8`, montada de solo lectura). Un `410 Unregistered` o `400 BadDeviceToken`
  borra el token y la Mac recibe el `pushResult`. Tope: 60 pushes/min por cuenta.

### P.10 Relay: tecnología, persistencia, observabilidad

- **Go** (un binario estático, `CGO_ENABLED=0`, `linux/arm64`) en `gcr.io/distroless/static-debian12:nonroot`.
  Por qué: HTTP/2 para APNs y TLS-less detrás de Traefik vienen en la biblioteca estándar; un binario de ~10 MB y
  ~15 MB de RAM entra cómodo en 4 GB compartidos; el build es reproducible con Docker en la Mac o en el server, sin
  Xcode. Swift en Linux funcionaría pero la imagen y la RAM son mayores y el server no tiene toolchain. Dependencias:
  `github.com/coder/websocket` y `go.etcd.io/bbolt` (versiones fijas en `go.sum`); el JWT ES256 se hace con
  `crypto/ecdsa` de la estándar.
- **Persistencia** (bbolt en el volumen `prbar-relay-data`, `/data/relay.db`):
  - `accounts`: `accountId → {macRelayKey, createdAt}`
  - `devices`: `accountId/deviceId → {relayKey, apnsToken?, apnsEnv?, lastSeen}`
  - `mailbox`: `accountId/deviceId/slot → {blob, at}` (TTL 7 días; barrido cada hora)
  - En memoria: conexiones, ranuras de emparejamiento, contadores de tasa, bloqueos por IP.
  Sin backup: perderlo = volver a habilitar y emparejar. Nada de eso es secreto (claves públicas y tokens de APNs).
- **Límites**: 10 upgrades de WebSocket por minuto por IP; 5 `auth` fallidos en 10 min → 15 min de bloqueo; por conexión
  autenticada 50 marcos/s (ráfaga 200) y 4 MiB/s; 128 KiB por marco; 1 Mac + 10 dispositivos por cuenta; 64 conexiones en
  total; ranura de emparejamiento: una por cuenta, 5 min, 3 intentos y se quema.
  Un cliente al azar no puede ocupar el buzón de una Mac: sin firma de una clave registrada (o `proof` de una ranura
  abierta) no pasa del `challenge`, y un `deviceId` conectado de nuevo solo reemplaza al anterior si firma con la misma clave.
- **Observabilidad sin contenido**: logs JSON a stdout (Docker los rota): conexión abierta/cerrada (rol, prefijo de 4
  caracteres de cuenta y dispositivo, duración, bytes), `auth` fallido (IP, motivo), resultado de push (status, motivo,
  latencia), límites alcanzados, y cada 10 min un resumen (conexiones, marcos, pushes, tamaño del buzón). **Nunca**:
  `b`, `e`, tokens de APNs (solo los 6 primeros hex de su SHA-256), ni payloads. `GET /healthz` → `ok` para el panel y
  Traefik.
- **Despliegue**: `/root/stack/prbar-relay/docker-compose.yml` con las labels de Traefik del `LEEME.md` (host
  `prbar.fcharbonnier.duckdns.org`, red `coolify`, puerto interno 8080), `mem_limit: 128m`, `env_file:
  /root/stack/env/prbar-relay.env` (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, `RELAY_ENROLL_TOKEN`,
  `RELAY_PUBLIC_HOST`), la `.p8` como secreto de compose. Imagen `prbar-relay:vps` construida en el server con el código
  subido por `rsync` (como dice el `LEEME.md`). Sin `ports:`.

### P.11 Emparejamiento

1. **Mac** (Settings › iPhone › "Pair iPhone…" o `prbar remote pair`): genera `pairingId` (10 bytes, base32) y `ps`
   (32 bytes al azar). Deriva `pairAuthKey = HKDF-SHA256(ps, info "PRBar relay pairing v1")` y
   `psk = HKDF-SHA256(ps, info "PRBar noise psk v1")`. Manda `pair.open` con `pairAuthKey` (el relay nunca ve `ps` ni
   `psk`). Muestra el QR (`pair:welcome` → QR en la Mac); vence a los 5 min.
2. **QR**: `prbar://pair?v=1&r=<host del relay>&a=<accountId>&p=<pairingId>&k=<ps b64url>&m=<macStatic.pub b64url>&n=<nombre de la Mac, url-encoded>`.
   Con el esquema `prbar://` la cámara del sistema abre la app; dentro de la app, `pair:scan` lee el mismo formato.
3. **Teléfono** genera sus claves (P.2), conecta como `pair` con `proof`, y manda el primer mensaje de
   `Noise_IKpsk2` a `pair:`→`mac`, con payload cifrado `{deviceName, model, deviceRelayKey.pub, devicePushKey.pub,
   presenceKey.pub}`. Prólogo: `"PRBar Pair v1" ‖ accountId ‖ pairingId`.
4. **Mac** responde el segundo mensaje (mezcla el `psk`), y espera el primer mensaje de transporte del teléfono
   (`{"confirm":true}`), que prueba que el teléfono tenía `ps`.
5. **Código de 6 dígitos (SAS)** en los dos lados: `sas = UInt32(bigEndian: HKDF-SHA256(ikm: handshakeHash, info:
   "PRBar SAS v1", 4 bytes)) % 1_000_000`, mostrado `"123 456"`. La Mac muestra el código, el nombre y el modelo del
   teléfono con "Codes Match" / "Cancel"; el teléfono muestra el código con "Confirm on your Mac".
6. **Codes Match** (o `y` en `prbar remote pair`): la Mac asigna `deviceId`, guarda las claves públicas, manda
   `device.add` al relay, y por la sesión de emparejamiento `{deviceId, macName, macSealKey.pub, relayHost}`; cierra la
   ranura (`pair.close`). El teléfono guarda todo, muestra `pair:paired`, pide permiso de notificaciones, registra el
   token (`apns`) y abre una sesión KK normal.
7. Cancelar, vencer, 3 `proof` fallidos o un segundo teléfono en la misma ranura → la ranura se quema y hay que generar
   otro QR. El SAS defiende contra un QR fotografiado: el atacante tendría que ganar la carrera y además que el usuario
   apruebe un código que su teléfono no muestra.

### P.12 Revocación, rotación y reset

- **Revoke** (Settings › iPhone, `prbar remote revoke <device>`, o "Unpair this iPhone" desde el teléfono): la Mac borra
  el dispositivo (claves públicas incluidas), corta sus sesiones, deja de mandarle pushes y buzón, y manda
  `device.remove`. A una sesión abierta le manda `bye(revoked)` (autenticado por Noise): **solo eso** hace que el
  teléfono borre sus claves y su caché y vuelva a `pair:welcome` ("This iPhone was removed from <Mac>"). El 4403 (o un
  4401 al conectar) del relay no está autenticado (un relay malicioso, o uno que perdió su base, lo puede mandar): el
  teléfono lo muestra como `relayRejected` ("The relay server didn’t accept this iPhone. Check iPhone access in PRBar on
  your Mac."), no borra nada y reintenta en la próxima operación (P.15 M3). Si la Mac lo revocó mientras el teléfono no
  estaba conectado, al conectar no llega el `bye`: el usuario lo confirma con "Unpair this iPhone". **Aunque el relay no obedezca**, la Mac ya no acepta su estática
  en Noise: la revocación la hace cumplir la Mac.
- **Rotación**: sesiones con secreto hacia adelante (P.5). Las claves de largo plazo se rotan re-emparejando.
  **"Reset iPhone Access…"** en la Mac genera claves y cuenta nuevas (borra todos los dispositivos); para un relay
  comprometido o una Mac clonada.
- **Deshabilitar** (`prbar remote disable`): cierra la conexión y deja de reconectar; los dispositivos quedan
  registrados (al habilitar vuelven a andar).

### P.13 Modelo de amenazas

| Actor | Puede | No puede (y por qué) |
|---|---|---|
| VPS/relay comprometido | Ver ids, tamaños aproximados (con relleno), horarios, IPs, tokens de APNs; cortar o demorar mensajes; borrar datos; mandar pushes con contenido falso visible solo como el texto genérico | Leer contenido (Noise/HPKE); mandar comandos (no tiene estáticas ni `presenceKey`); repetir comandos (contadores de Noise, `sentAt` ≤ 120 s, ids de `req`); falsificar notificaciones (HPKE auth con `macSealKey`; sin eso la NSE muestra el texto genérico); emparejar un teléfono suyo (necesita `ps` del QR y que el usuario apruebe el SAS en la Mac) |
| Alguien en la red | Lo mismo que el relay menos ver ids (TLS) | — |
| Cliente al azar en internet | Llegar al `challenge` | Crear cuentas (token de inscripción), ocupar buzones (firma), agotar recursos (límites por IP y conexión) |
| Teléfono robado y desbloqueado | Ver listas, chatear, empezar reviews (lo que haría el dueño sin Face ID) | Merge, push, approve (Face ID en Secure Enclave verificado por la Mac); apagar Face ID (gated); cambiar tokens, herramientas, destinos SSH o actualizar (denegados). Mitigación: Revoke desde la Mac |
| Teléfono robado y bloqueado | Nada: el llavero de la app es `AfterFirstUnlockThisDeviceOnly` y la caché tiene protección de datos | — |
| Contenido de PRs ajenos | Llega al teléfono como texto | Ejecutar nada: el teléfono solo muestra texto (`Text` sin markdown activo para contenido ajeno, links sin auto-abrir) |
| Apple (APNs) | Ver tokens, horarios, colapso/hilo opacos | Leer contenido |

Fuera de alcance: una Mac comprometida (ya controla todo), malware en el teléfono con root.

### P.14 Decisiones de implementación (Plan 17)

**Tipos movidos a `PRBarWire`** (solo la declaración y lo que no depende de Core): `AppCommand` (+ `AppCommand.Name`,
ahora `Codable`), `AppCommandTypes`, `JSONValue`, `CommandProtocol` y sus mensajes (`CommandMessages.swift`), los
structs de `CommandResults`, y las hojas `CommitMode`, `DiskUsage`, `DiskItem`, `DiskItemState`, `DiskCategoryKind`,
`MergeDetail` (+ `Section`), `MergeReviewSummary`, `MergeCheck`, `MergeChangedFile`, `MergeableState`,
`MergeStateStatus`, `ReviewDecision`, `MergeMethod`, `PopoverSection`, `PopoverTab`, `PRCategory`, `PromptStage`,
`PromptVariable`, `PromptIssue`, `ResourceUsage`, `ProcessUsage`, `ProcessActivity`, `ReviewEvent`, `ReviewTone`,
`RuleScope`, `RuleStage`, `RunnerHostInfo`, `Severity`, `SlackProvider` y `LossyArray` (ahora `public`). Quedan en Core
como `extension` (`WireLeaves+Core.swift`, `CommandResults+Core.swift`): `PromptStage.validate/isUsable`,
`RuleScope.covers`, `RunnerHostInfo.statusSummary`, los `keyPath`/`toggle`/`kind` de los nombres de la CLI,
`RespondSelectionChange.apply`, `PRListing`, las fases (`cliName`/`cliDetail`) y las 21 conversiones de modelos de Core
a resultados. Las que asignaban campo por campo ahora delegan en un `init` memberwise público nuevo de cada struct
(Swift no deja asignar campos de un struct de otro módulo desde una extensión sin warning).

**`feat/ci-cost` no está mergeada en esta rama** (protocolo 5): `RemotePolicy` no tiene `usage`, `ciList` ni `ciFix`.
Al mergear, el `switch` exhaustivo no compila hasta clasificarlos (`usage` y `ciList` lectura, `ciFix` acción: los tres
`.allowed`, como en P.7) y se agregan al test. `CommandProtocol.minimumRemoteVersion` existe y vale lo mismo que
`version` (5); el Plan 18 los sube a 7.

**Vectores**:
- Noise: cacophony (`vectors/cacophony.txt`, commit `8ee9d41e34a1a596cfa3ab12aa4069ff87dc1247`) para
  `Noise_KK_25519_ChaChaPoly_SHA256` e `Noise_IKpsk2_25519_ChaChaPoly_SHA256`, más snow (`tests/vectors/snow.txt`,
  commit `8ac60f51cfe3e010c84f0a454cc575ad9204fa12`) para KK como segunda fuente. Los dos pasan byte a byte (mensajes de
  handshake, transporte y hash final), y un cambio de una constante del HKDF los rompe.
- HPKE: RFC 9180 A.2.3 (DHKEM(X25519), HKDF-SHA256, ChaCha20Poly1305, modo Auth), tomado de `test-vectors.json` del
  repo `cfrg/draft-irtf-cfrg-hpke`: `HPKE.Recipient` de CryptoKit abre las tres primeras encriptaciones. CryptoKit no deja
  fijar la efímera del remitente, así que el lado que sella se prueba por ida y vuelta.
- SAS: `SAS.code(32 × 0x00) = "745502"` y `SAS.code(0x00…0x1f) = "425641"`, calculados aparte con
  `openssl kdf -keylen 4 -kdfopt digest:SHA256 -kdfopt hexkey:<hash> -kdfopt info:"PRBar SAS v1" HKDF`.

**Desvíos y precisiones del protocolo**:
- Prólogos: `"PRBar Remote v1" ‖ accountId ‖ 0x00 ‖ deviceId` y `"PRBar Pair v1" ‖ accountId ‖ 0x00 ‖ pairingId` (un
  separador para que dos pares de ids distintos no den el mismo prólogo).
- `collapse` = HMAC(`pushIdKey`, `"collapse" 0x00 kind 0x00 pr`) y `thread` = HMAC(`pushIdKey`, `"thread" 0x00 pr`)
  truncado a 16 (separadores por la misma razón).
- Push: el sobre en base64 se limita a 3 072 caracteres; con el relleno a 256 eso deja ~2 040 bytes de JSON (no 2 816):
  `PushPayload.sealedForAPNs` corta `body` (y si hace falta `title`) con "…" hasta que entra. El relay recibe el sobre
  crudo en `b` y lo pone en base64 estándar en `e`.
- `PresenceProof.ts` viaja como milisegundos enteros (`"ts": 1800000000123`), los mismos que se firmaron (las fechas
  ISO 8601 de `CommandProtocol.encoder` no tienen milisegundos).
- El relay le avisa a la Mac cuando quema o vence una ranura: `{"t":"pair.close","pairing":…}` en sentido relay → Mac
  (antes solo existía Mac → relay). Si el resultado de "Codes Match" no llega al teléfono (`undeliverable` a `pair:…`),
  la Mac deshace el alta.
- Nuevo marco `{"t":"error","reason":…}` del relay para pedidos rechazados sin cerrar la conexión (p. ej. un teléfono
  que manda a otro teléfono). `{"t":"devices"}` sin `items` es el pedido; con `items`, la respuesta.
- La Mac manda `presencePolicy` **antes** del `hello`: cuando `connect()` del teléfono termina, ya la tiene.
- `relayHost` acepta `host:puerto` siempre (para el entrypoint dedicado de V.2); una IP literal solo con
  `allowInsecureTransportForTests`. La firma del desafío usa el host **sin** puerto (`RELAY_PUBLIC_HOST`).
- Buzón: un blob viaja en un solo marco del relay (≤ 128 KiB), así que el tope práctico es ~90 KiB cifrados
  (`RemoteHost.maxMailboxBlob`), no 512 KiB; si `home` no entra, no se guarda (el estado en vivo igual llega).
- Seguridad extra: un `CipherState` que falla al descifrar queda inutilizable (no se puede seguir con el mensaje bueno);
  las colas del `WebSocketRelayLink` son acotadas y una cola llena corta la conexión en vez de perder marcos; los
  timeouts del cliente quedan atados a la espera que los creó.
- Eventos del host: en vez de callbacks sueltos, `RemoteHost.events` (`AsyncStream<RemoteHostEvent>`: estado,
  `pairingJoined`, `pairingEnded`, `devicesChanged`, `deviceOnline`, `sessionRejected`, `commandRefused`).
- Relay: el límite de pushes cuenta solo los que irían a Apple (no los rechazados por falta de token); el `auth` sin
  respuesta se corta con un timer (cancelar el contexto de lectura cerraría sin el código 4408).

**Go**: módulo `prbar-relay`, `go 1.26`; `github.com/coder/websocket v1.8.15`, `go.etcd.io/bbolt v1.5.0`
(`golang.org/x/sys v0.45.0` indirecta), Go 1.27.4 de Homebrew. `go vet` y `gofmt -l` limpios, `go test -race
-count=3 ./...` verde, y la integración Swift ↔ Go (`PRBAR_RELAY_BIN`) pasa contra el binario real. La integración no
usa un APNs falso: sin APNs configurado el relay contesta el push con 410/503 y el test verifica que el pedido llega y
vuelve (el pedido HTTP/2 a APNs se prueba en Go contra `httptest` con TLS y HTTP/2).

### P.15 Revisión de cifrado del Plan 17 y topes de la Mac

Una revisión independiente de `PRBarRemoteKit` (en 93c9080) no encontró nada crítico ni alto. Lo que se cambió:

- **M1 — el relay podía deshacer un emparejamiento terminado.** Antes, la Mac guardaba el dispositivo en "Codes Match" y
  lo borraba si después llegaba un `undeliverable` a `pair:<id>` (un marco que el relay puede inventar cuando quiera).
  Ahora el teléfono contesta el resultado con un acuse cifrado (`PairingMessage.ack`, por la sesión IKpsk2) y **la Mac
  guarda el dispositivo recién al recibirlo**; `confirmPairing` espera ese acuse (20 s; sin él manda `device.remove`, no
  guarda nada y falla con "Your iPhone didn’t confirm the pairing. Try again."). Un `undeliverable` a `pair:` solo
  cuenta durante esa espera. Lo peor que puede hacer el relay es que un emparejamiento no termine (temporal).
- **M2 — compresión antes de cifrar.** Ya no se comprime nada al mandar (P.5).
- **M3 — códigos de cierre del relay como revocación.** Solo `bye(revoked)` dentro de la sesión revoca (P.12); 4403 y
  4401 son `relayRejected` (`RemoteClientStatus` y `RemoteError` nuevos) y no borran nada.
- **L1 — `rev` hacia atrás después de reiniciar la Mac.** El teléfono olvida los `rev` vistos al abrir cada sesión: el
  orden de `state` vale dentro de una sesión (Noise ya lo garantiza ahí).
- **L2 — un primer mensaje de KK repetido tiraba la sesión viva.** El handshake nuevo queda pendiente y reemplaza a la
  sesión viva recién cuando su primer marco (`hello`) descifra.
- **L3 — la Mac podía ejecutar un pedido que el teléfono ya había dado por vencido.** `req` lleva `deadline` (= `sentAt`
  + el timeout del teléfono, 60 s); la Mac rechaza un pedido pasado ese plazo ("This request expired. Try again."),
  además del tope de 120 s de antigüedad. En el teléfono un timeout dice "Your Mac didn’t answer in time. Refresh to see
  whether it ran."
- **L4 (Plan 19)** — un link `prbar://pair` no puede reemplazar en silencio un emparejamiento: lo resuelve la app del
  iPhone. Del lado Mac no cambia nada (cada emparejamiento lo aprueba el usuario con el código).
- **L5 (Plan 18)** — `remoteSetPresenceRequirement(enabled: false)` pasa por `RemotePolicy` como gated (y está en
  `gatedNames`); las claves de la Mac viven solo en el llavero (Q.4).
- **L6** — los demás cortes que puede provocar el relay (cerrar una ranura, marcar un teléfono offline) son temporales y
  los acepta el modelo de amenazas.

**Topes de la Mac** (`RemoteLimits.standard`, en `RemoteHost`; un teléfono emparejado o robado y desbloqueado no puede
inundar la Mac, y un relay malicioso no puede hacerla trabajar):

| Qué | Tope | Al pasarlo |
|---|---|---|
| Pedidos ejecutándose a la vez por sesión (un `--wait` ocupa uno hasta terminar) | 8 | `CommandFailure(.invalidState, "Too many requests from this iPhone. Wait a moment and try again.")` |
| `req` + `sub` por dispositivo | ráfaga 30, 5/s sostenido | igual (un `sub` de más se ignora) |
| Handshakes KK por dispositivo (cuatro Diffie-Hellman cada uno) | ráfaga 6, 6/min sostenido | se ignora el mensaje sin hacer ningún DH |

Un `deviceId` desconocido o revocado se rechaza antes de cualquier DH, y el emparejamiento ya era una ranura con un
solo teléfono. Cada tope frenado emite `RemoteHostEvent.rateLimited(device:)` (la app lo loguea con el prefijo del id).

---

## Q. Lado Mac

### Q.1 `RemoteAccessService`

- Vive en la app (`Sources/PRBar/Remote/`), usa `RemoteHost` de `PRBarRemoteKit`. Arranca con la app si está habilitado.
- Conexión: `URLSessionWebSocketTask` saliente al relay; reconexión con backoff exponencial (1 s → 60 s, ±20 %),
  inmediata al cambiar la red (`NWPathMonitor`) y al despertar (`NSWorkspace.didWakeNotification`). Sin puertos
  entrantes.
- Por cada sesión de un dispositivo: `RemoteCommandBridge` → `RemotePolicy` → verificación de presencia → 
  `CommandDispatcher.run(command, on: appModel, events:)` (el **mismo** camino que la CLI) → `res`.
- `RemoteStateFeed`: los tópicos de P.6. `RemotePushSender`: P.9. `RemoteMailbox`: cada vez que cambia `home`
  (agrupado cada 60 s) guarda el último `RemoteHome` cifrado (HPKE auth, `info = "PRBar mailbox v1" ‖ accountId ‖
  deviceId ‖ slot`, con `rev`) en el slot `home` de cada dispositivo, para que el teléfono tenga algo reciente aunque la
  Mac se haya ido antes de que él abriera la app. El teléfono ignora un `rev` menor al último visto (el relay no puede
  volver atrás el estado).
- **"Keep this Mac awake while charging"** (apagado por defecto): con acceso remoto habilitado y la Mac en corriente
  (`IOPSGetProvidingPowerSourceType == kIOPMACPowerKey`), toma `IOPMAssertionCreateWithName(
  kIOPMAssertPreventUserIdleSystemSleep, "PRBar: iPhone remote access")`; la suelta en batería o al deshabilitar. La
  pantalla puede apagarse. Tapa cerrada sin monitor externo: macOS duerme igual (se documenta).

### Q.2 Settings › iPhone (pestaña nueva, `SettingsTabName.iphone`)

- **Allow iPhone remote control** (toggle). Al prenderlo la primera vez: hoja con "Relay server" (host) y "Enrollment
  token" (campo seguro), "Enable". Errores claros ("The relay refused the enrollment token.").
- **Estado**: "Connected to prbar.… · 1 iPhone online" / "Connecting…" / "Offline — retrying in 30 s" / "Disabled".
- **Pair iPhone…**: hoja con el QR (CoreImage `CIQRCodeGenerator`, corrección M), el vencimiento y "Scan this with the
  Camera app or with PRBar on your iPhone". Cuando el teléfono se une: el código grande `123 456`, "Federico’s iPhone
  (iPhone 17 Pro)", **Codes Match** / Cancel.
- **Devices**: lista con nombre, modelo, "Paired Nov 20", "Last seen 5 min ago" / "Online", Face ID requerido (sí/no) y
  **Revoke…** (confirmación).
- **Keep this Mac awake while charging** (toggle) y **Reset iPhone Access…** (confirmación destructiva).

### Q.3 CLI (paridad)

```
prbar remote status [--json]                       # habilitado, relay, conexión, dispositivos online
prbar remote enable --relay HOST [--enroll-token-stdin]
prbar remote disable
prbar remote pair                                   # QR en la terminal (medios bloques), espera, muestra el código, pregunta
prbar remote devices [--json]
prbar remote revoke <device> [--yes]                # nombre o prefijo del id
prbar remote keep-awake on|off
prbar remote reset [--yes]
```

`AppCommand` nuevos (todos **denegados** desde el teléfono salvo `remoteSetPresenceRequirement`, que entra por el
teléfono y es gated al apagar): `remoteStatus`, `remoteEnable(relay:enrollToken:)`, `remoteDisable`,
`remotePairStart` (devuelve el texto del QR y el vencimiento), `remotePairWait(pairing:)` (evento con el código y el
dispositivo cuando se une), `remotePairConfirm(pairing:confirmed:)`, `remoteDevices`, `remoteRevoke(device:confirmed:)`,
`remoteSetKeepAwake(enabled:)`, `remoteReset(confirmed:)`, `remoteSetPresenceRequirement(device:enabled:)`.
`CommandProtocol.version` → 7. El token de inscripción viaja de la CLI a la app (como `slack token set`), nunca al revés.

### Q.4 Decisiones de implementación (Plan 18)

**Merge de `main` (plan 15, protocolo 6) antes del Plan 18.** `ClaudeUsage`, `UsageTask`, `UsageMonth`, `UsageFormat`,
`RespondMode` y `CICheckFailure` pasaron a `PRBarWire` (los usan `ReviewInfo`, `RespondInfo`, `HistoryEntryInfo`,
`ResourcesInfo` y `UsageInfo`); `ClaudeUsage.run(duration:tokens:cost:)` (usa `ClaudeTokenUsage`, que queda en Core) y
las conversiones de registros (`HistoryEntryInfo(review:/respond:/merge:)`, los `init` de `ReviewInfo`/`RespondInfo`)
quedan en Core como extensiones; los `clamped*`/`plus` de `ClaudeUsage` son públicos para que Core los use.
`HistoryEntryInfo.listing` es puro y quedó en Wire. `RemotePolicy`: `usage` y `ciList` lectura, `ciFix` acción (los tres
allowed); `prbar ci show/diff/test/push` son los comandos de Respond (`ci push` = `respondPush`/`respondPushAnyway`,
gated). El merge dejó protocolo 6 y `minimumRemoteVersion` 6; el Plan 18 los sube a **7 y 7**.

**Dónde vive el código.** Un target nuevo, **`PRBarRemoteMac`** (Core + RemoteKit), con `RemoteKeyStore`,
`RemoteDeviceStore`, `RemoteAccessService` (conexión, emparejamiento, puente, feed, buzón, pushes, keep awake),
`RemotePushPlanner`, `KeepAwake` y `RelayEnroller`. No en la app (los tests no pueden importar un ejecutable) ni en Core
(así `prbar` no carga CryptoKit ni el protocolo del relay). En Core: `RemoteSettings`, `RemoteStateTopics`,
`RemoteActions` y `QRCodeMatrix` (CoreImage, lo usan la app y la CLI). En Wire: los resultados `remote*` y los tipos de
los tópicos (`RemoteTopic`, `RemoteHome`, `RemotePRDetail`, `RemoteActivity`) y `RemoteRedaction`, que la app de iOS
decodifica. En la app: `AppModel+Remote` (adaptador de config, comandos, avisos del sistema y chats) y Settings › iPhone.

**Config y claves.** `AppConfig.remote`: `enabled`, `relayHost` (`host[:puerto]` normalizado: acepta `https://`/`wss://`
y barra final, nunca `http://`, rutas, usuarios ni IP salvo en tests), `accountId`, `keepAwakeWhileCharging`,
`mailboxEnabled` (por defecto **sí**, V.3) y `appInstallURL`. El relay por defecto es
`prbar.fcharbonnier.duckdns.org` (configurable en la hoja y con `--relay`). Decodificación tolerante; sin host o cuenta
válidos, `enabled` queda en `false`. Las claves de la Mac, solo en el llavero (servicio `PRBar Remote`, cuentas
`mac-relay`, `mac-noise`, `mac-seal`, `rawRepresentation` en base64); una clave rota falla (no se reemplaza en silencio).
`remote/devices.json` guarda `StoredDevice {device, lastSeen, notificationsOff}`; se escribe ya con 0600 (archivo
temporal + reemplazo) en una carpeta 0700; uno roto se aparta como `devices.json.broken-<fecha>`.

**Habilitar.** `POST https://<host>/v1/accounts` con `URLSession` (15 s): 403 → "The relay refused the enrollment
token.", 429 → "Too many attempts. Try again in 15 minutes.", 409 → "The relay has no room for another Mac.", red →
"Couldn’t reach <host>.". El token no se guarda; volver a habilitar el mismo relay con la cuenta guardada no lo pide (la
UI y `prbar remote enable` mandan el token vacío). Otra cuenta u otro relay borra los dispositivos de la anterior.

**Conexión.** El primer `connect` lo reintenta el servicio (backoff 1 → 60 s); después reconecta `RemoteHost`. Al
despertar y cuando vuelve la red (`NWPathMonitor`), si no está conectado se rehace la conexión sin esperar el backoff;
antes de dormir y al salir se corta ordenado (el relay marca la Mac offline enseguida).

**Emparejamiento.** `remotePairStart` → `{pairing, qr, expiresAt}`; `remotePairWait` devuelve la misma info con `code`
("123 456"), `deviceName` y `model` cuando el teléfono se une (evento `progress` "Waiting for your iPhone…"), o falla si
vence (5 min, timer del servicio además del relay), se cancela o se abre otra ranura. `remotePairConfirm(confirmed:
false)` también cierra una ranura a la que nadie se unió. "Codes Match" espera el acuse del teléfono (P.15 M1).

**El puente.** `RemoteHost` le pasa al handler el `PairedDevice` (`DeviceHandler`, agregado en RemoteKit); el puente
loguea `iPhone <4>: <comando>`, vuelve a mirar `RemotePolicy` (defensa en profundidad), reemplaza el `device` de
`remoteSetPresenceRequirement` por el del teléfono que lo pidió y llama a `CommandDispatcher.run` sobre el mismo
`AppModel`. **Redacción**: a todo resultado y tópico que va al teléfono se le aplica `RemoteRedaction.scrub`: `logPath`,
`worktree` y `path` quedan en su último componente y `tools` vacío (P.7: ni rutas locales ni herramientas; `status`
traía las rutas de `gh`/`git`/`claude` y `resources` las carpetas del disco). Los tipos se siguen decodificando.

**Feed.** `AppModel` es `ObservableObject` (Combine), no `@Observable`: en vez de `withObservationTracking`, el servicio
recibe los `objectWillChange` de `AppModel`, `PRStore`, las colas de review/respond y `MergeQueue`, agrupados cada 300 ms.
Se calculan solo los tópicos suscritos (como mucho 20 válidos por suscripción, `RemoteTopic.parse`) más `home` (lo usa
el buzón); `RemoteHost.publish` manda solo lo que cambió. `activity` además cada 5 s mientras esté suscrito.
`RemotePRDetail` no trae `merge`: `mergePreview` va a GitHub y no se recalcula en cada cambio (el teléfono lo pide al
abrir Merge). `chatDelta`: la app mira el `partialText` de cada chat (Review, Respond, Merge) y manda lo nuevo a quien
mire `pr:<id>`; también para chats que inició el teléfono (el teléfono ignora `chatDelta` de un PR con un `chatSend`
propio en curso: Plan 19).

**Buzón.** Cada 60 s, si `home` cambió, un `mbox.put` por dispositivo (HPKE, P.9). El `rev` lo pone `RemoteHost` como
`max(rev + 1, milisegundos de reloj)`: crece aunque la app reinicie sin guardar nada (el plan proponía
`RemoteSettings.mailboxRev`; no hace falta salvo que el reloj vuelva atrás). Apagado: el protocolo del relay no tiene
"borrar", así que se pisa el slot con un estado vacío (el teléfono lo trata como "nada"; vence a los 7 días). Un
dispositivo nuevo recibe el próximo aunque no haya cambiado.

**Pushes.** `NotificationDelivery.onDeliver` (corre aunque no haya bundle) → `RemotePushPlanner`: mismo título y
cuerpo, `kind` = `NotificationKind.rawValue`, `threadId` = el de la Mac, `badge` = `StatusInfo.badgeCount`, y
`deepLink`: `newToReview`/`reviewedPRUpdated` → `?screen=review`, `myPRFeedback` → `respond`, `readyToMerge` → `merge`,
`reviewFinished` → `respond` si es de Respond o Fix CI y `review` si no, `myPRApprovedOrCIFailed` → el PR sin
pantalla, `updateAvailable`/`diskUsage` → `prbar://activity`, sin PR → `prbar://home`. 410/400 marcan el dispositivo
"Notifications off"; un 200 lo vuelve a prender.

**Comandos y CLI.** Además de los de Q.3: `remoteSetMailbox(enabled:)` (`prbar remote mailbox on|off`) y
`remoteSetAppLink(url:)` (`prbar remote app-link set <url>|clear`); los dos denegados desde el teléfono.
`remoteSetPresenceRequirement` es `dependsOnArguments` en `RemotePolicy` (`true` allowed, `false` gated) y está en
`gatedNames`. `prbar remote pair` corre `remotePairStart` y `remotePairWait` en `prepare` y pregunta con la confirmación
de siempre; contestar que no manda `remotePairConfirm(false)` (`RemoteCommand.declinedCommand`, nuevo); en la tabla de
paridad, `CLICommandSpec.prepares` cuenta los comandos que manda antes. El QR de la terminal dibuja los módulos claros
con medios bloques; con colores fuerza blanco sobre negro (se lee en temas claros y oscuros). `prbar remote enable`
lee el token sin eco (vacío = reusar la cuenta) o con `--enroll-token-stdin`.

**Settings › iPhone** (700 × 520): arriba **Get PRBar for iPhone** (QR del link de instalación con Copy Link y Open
Link, o el texto de Xcode sin link); el QR de instalación se oculta mientras la hoja de emparejar está abierta (nunca
los dos QR juntos). Después Remote Control (toggle, estado, Pair iPhone…), iPhones (nombre, modelo, "Paired …", "Online"
o "Last seen …", "Require Face ID", Revoke…, aviso de notificaciones apagadas) y Options (keep awake, buzón, Reset
iPhone Access…). Capturas: `settings-iphone` (conectado, dos iPhones, con link), `settings-iphone-off`,
`settings-iphone-off-link`, `iphone-pair-qr`, `iphone-pair-code`, `iphone-enable`.

**Revocar con el acceso apagado** solo borra el dispositivo en la Mac (no hay conexión para mandar `device.remove`);
la Mac igual rechaza su estática, y un relay que lo siga conociendo solo le deja llegar al `challenge`/handshake fallido.

**Tests.** `RemoteSettingsTests`, `RemoteBridgeTests` (servicio + `InMemoryRelay` + `FakeActions` + `RemoteClient`),
`RemoteCLITests`, `RemoteHardeningTests` (P.15), y `RemoteMacIntegrationTests` contra el binario del relay en
`127.0.0.1` (solo con `PRBAR_RELAY_BIN`). `RemoteSmokeTests` (solo con `PRBAR_PAIR_URL`) es el iPhone simulado de la QA
manual. Nada habla con el relay desplegado (todavía no existe).

---

## R. App de iOS

### R.1 Diseño y `DIGEST.md`

El diseño es la referencia visual (pantallas, textos, tokens claro/oscuro, espaciados, SF Symbols, interacciones).
`DIGEST.md` (en el scratchpad del diseño, y copiado a `ios/DESIGN.md` por la Task 0 del Plan 19) lo resume por id de
pantalla: `home`, `home:mine`, `home:offline`, `pair:welcome`, `pair:scan`, `pair:paired`, `review`, `review:menu`,
`review:faceid`, `review:posted`, `edit`, `respond`, `respond:fixci`, `respond:diff`, `merge`, `merge:faceid`,
`merge:merged`, `chat:review`, `chat:respond`, `chat:merge`, `activity`, `settings`, `lock notifications`. Los archivos
`MenuBar`, `Popover`, `ReviewWindow`, `SettingsWindow`, `HistoryWindow`, `IconStates`, `PRBar.dc.html` y
`ReviewButtons` son el diseño de la app de la Mac (ya en `docs/design/`), no del teléfono.

### R.2 Plataforma

- **iOS 26 mínimo**, solo iPhone, Swift 6, SwiftUI. Por qué: el diseño es Liquid Glass (APIs de iOS 26: `glassEffect`,
  `GlassEffectContainer`, barra de pestañas que se minimiza, botones `.glass`); el único usuario tiene un iPhone actual;
  soportar iOS 18 duplicaría cada superficie con `if #available` y un segundo aspecto que nadie usaría. Si algún día hay
  equipo, bajar el mínimo es un cambio acotado a las vistas.
- Bundle ids: app `com.federico.prbar.ios`, extensión `com.federico.prbar.ios.notifications`. App Group
  `group.com.federico.prbar.ios`. Grupo de llavero `$(AppIdentifierPrefix)com.federico.prbar.ios.shared`. Esquema de URL
  `prbar`.
- Proyecto: **XcodeGen** (`ios/project.yml` versionado; el `.xcodeproj` se genera con `Scripts/ios-generate.sh` y está
  en `.gitignore`). Un agente no puede hacer clics en Xcode: con un YAML todo cambio de targets, capacidades y
  dependencias es texto revisable, y `xcodebuild` compila y testea desde la terminal. La firma va en
  `ios/Config/Local.xcconfig` (no versionado: `DEVELOPMENT_TEAM`).

### R.3 Arquitectura

- `PRBarRemoteKit` (paquete local `..`) para todo el protocolo. La app agrega:
  - `RemoteConnection` (`@Observable @MainActor`): ciclo de vida — conecta al pasar a primer plano, se va a los 30 s de
    pasar a segundo plano (`beginBackgroundTask`); sin conexiones en segundo plano (para eso están los pushes). Estado:
    `.unpaired`, `.connecting`, `.online`, `.macOffline(since)`, `.relayUnreachable`, `.revoked`, `.incompatible(…)`.
  - `RemoteTransport` (protocolo): `send(_ command: AppCommand, presence:) async throws -> JSONValue`,
    `events(for id:) -> AsyncStream<CommandEvent>`, `subscribe(_ topics:)`, `states: AsyncStream<RemoteState>`. La real
    usa `RemoteClient`; los tests usan `FakeTransport`.
  - `AppStore` (`@Observable`): `home`, `details[pr]`, `activity`, `isStale`, `lastUpdated`; se alimenta de `state` y del
    buzón; escribe la caché.
  - Un view model por pantalla (`HomeModel`, `PairingModel`, `ReviewModel`, `RespondModel`, `MergeModel`, `ChatModel`,
    `ActivityModel`, `SettingsModel`), cada uno con `RemoteTransport` + `AppStore` inyectados.
  - `PresenceAuthorizer`: firma con la clave del Secure Enclave (y en tests, una P-256 de software).
- **Caché**: JSON en el contenedor del App Group (`Cache/home.json`, `Cache/pr/<hash>.json`, ≤ 50 PRs, LRU), con
  `FileProtectionType.completeUntilFirstUserAuthentication`. Se borra al desemparejar.
- **Offline** (`home:offline`): con la Mac offline o el relay inalcanzable se muestra lo cacheado en gris, el banner con
  "Last updated …" y las acciones deshabilitadas (no hay cola de comandos: un comando viejo ejecutado tarde sería peor
  que no ejecutarlo; además `sentAt` lo rechazaría).
- **Deep links**: `prbar://pr/<owner>/<repo>/<n>[?screen=review|respond|merge|chat]` desde notificaciones; `prbar://pair?…`
  desde la cámara.

### R.4 Fases

| Fase | Pantallas | Comandos |
|---|---|---|
| 1 | `pair:*`, `home`, `home:mine`, `home:offline`, `lock notifications`, NSE | `sub home`, `refresh`, buzón, `apns` |
| 2 | `review`, `review:menu`, `review:faceid`, `review:posted`, `edit`, `respond`, `respond:fixci`, `respond:diff`, `chat:review`, `chat:respond` (el chat es parte del flujo de diff/undo) | `review*`, `respond*`, `ciFix`, `chatSend/Undo/Stop/Show` |
| 3 | `merge`, `merge:faceid`, `merge:merged`, `chat:merge`, `activity`, `settings` | `mergePreview`, `merge`, `mergeDismiss`, `resources`, `usage`, `history`, `notify*`, `remoteSetPresenceRequirement` |

### R.5 Notificaciones

NSE según P.9. La app registra la categoría `PR` con las acciones del diseño (todas `.foreground`). `UNUserNotificationCenter`
delegado: con la app abierta en ese PR no muestra el banner. El badge lo pone la NSE con el valor descifrado.

### R.6 Settings del teléfono

Lo que muestre el diseño, con esta regla: lo que es de la Mac va por `AppCommand` permitido (`notifySet`,
`notifySetEnabled`, `remoteSetPresenceRequirement`); lo demás es local (Mac emparejada, "Unpair this iPhone", versión).

### R.7 Decisiones de implementación (Plan 19)

Estado: la app habla con la Mac por el relay (`LiveTransport`, `LivePairingService`); falta lo que requiere al usuario
(Team ID, iPhone) y las notificaciones (Task 8).

- **Dónde vive el código.** La lógica y las vistas están en el paquete `ios/PRBarMobileKit` (targets
  `PRBarMobileCore`, `PRBarMobileUI`, `PRBarMobileSnapshots`), que compila para iOS 26 **y macOS 26**: los tests de los
  view models corren con `swift test` en la Mac, sin simulador, y `swift run PRBarMobileSnapshots` dibuja cada pantalla
  en claro y oscuro a `ios/snapshots/` (ignorado). El target de Xcode (`ios/PRBarMobile`) solo tiene el arranque
  (`AppBootstrap`), el gesto de volver y los recursos. Proyecto `PRBarMobile` por XcodeGen como dice el plan.
- **La costura con el relay.** `RemoteTransport` (conectar, `sub`, `send` con firma de presencia, buzón, `unpair`,
  eventos) y `PairingService` (unirse a la ranura, código, resultado). `AppBootstrap.make()` arma `LiveTransport` y
  `LivePairingService`; con el argumento `-demo` arma `FakeTransport`/`FakePairingService` con la muestra del diseño
  (capturas, previews y tests siguen usando el fake). El transporte arma él mismo el `PresenceProof` (conoce
  `sessionHash` y reserva el `reqId`): los view models le pasan un `PresenceSigner` solo si el comando es gated
  (`RemotePolicy`) y la Mac exige presencia (`presencePolicy`).
- **`LiveTransport`** (sobre `RemoteClient`). El cliente se arma con lo que hay en el llavero al conectar y se rearma si
  cambia el emparejamiento (otra Mac, o un emparejamiento nuevo después de una revocación). `RemoteClient` ganó
  `statusUpdates` (cada cambio de estado) y `lastRelayCloseCode`: cada estado pasa a un `LinkState`; mientras la app
  quiere estar conectada, un relay caído se reintenta con backoff (1, 2, 4, 8, 16 y 30 s) y una Mac que vuelve
  (`presence` online) se reconecta enseguida. Un código de cierre del relay (44xx) es `relayRejected(closeCode:)`, un
  problema de conexión; solo `bye(revoked)` dentro de la sesión es `.revoked` y borra claves y caché (M3). Un handshake
  sin respuesta (una Mac que no reconoce al teléfono) también es un problema de conexión. Pedidos con `deadline`
  (L3), eventos en orden, `CommandFailure` tal cual a la UI, `chatDelta` y tópicos reenviados, buzón `home` abierto (un
  slot vacío = nada). La app ignora el `chatDelta` de un PR mientras corre su propio `chatSend` (ya le llega como eventos).
- **`LivePairingService`.** Un `RemoteClient` por intento, hacia el relay del QR, con las claves que generó la app
  (`startPairing(…, keys:)`, nuevo): se guardan en el llavero recién con el resultado de la Mac, al que RemoteKit
  contesta con el acuse cifrado (M1). "Codes Don't Match" suelta la ranura (`cancelPairing()`, nuevo).
- **Tipos compartidos.** El teléfono usa directamente `AppCommand` (`ciFix`, `usage` y
  `remoteSetPresenceRequirement` ya están; este último va con `device` vacío: el puente pone el de la sesión),
  `PairedMac` de RemoteKit (en el llavero, en vez de `StoredPairedMac`; `StoredDeviceKeys` queda porque guarda además la
  clave de presencia, con `deviceKeys()` para RemoteKit) y los tópicos de PRBarWire (`RemoteHome`, `RemotePRDetail`,
  `RemoteActivity`, `CIListEntry`, `CICheckFailure`, `UsageInfo`). Se borraron `RemoteCommand`, `RespondExtras`,
  `CIEntry`, `CICheck`, `UsageDigest`, `SystemStats` y `RunningJob`.
- **Tópicos.** Cada pantalla retiene su tópico mientras está visible (`activity` solo con Activity abierta). `rev`: por
  sesión para los `state`; el del buzón se compara con el último `home` guardado.
- **Datos que el diseño muestra (campos opcionales, sin cambiar el protocolo).** La Mac los llena con lo que ya
  tiene, sin pedidos nuevos a GitHub; sin ellos la UI usa su texto genérico:
  - `PRInfo.authorName` (nombre visible del autor; `... on User { name }` en la consulta de PRs abiertos que ya se hacía,
    guardado en `state.json`), `PRInfo.changedFiles` (`changedFiles` en la misma consulta; "· 5 files") y
    `PRInfo.approvals` (revisores cuyo último review que cuenta es un approve; "Approved by 2").
  - `RemoteHome.findingCounts` (comentarios incluidos de un review listo; "4 comments").
  - `CIListEntry.failedChecks` (de un Fix CI ya corrido sobre ese head; si no, "Checks failed").
  - `CICheckFailure.durationSeconds` (`started_at`/`completed_at` de los check runs que el Fix CI ya pide) y
    `logExcerpt` (las últimas 8 líneas del log ya saneado); `RespondInfo.totalChecks` ("2 of 9", checks del head),
    `startedAt` (cronómetro, el `startedAt` del registro) y `testSummary` ("142 passed", de la salida de los tests:
    Jest, Vitest, pytest, Mocha, XCTest, Swift Testing, cargo).
  - `RemotePRDetail.slackChannel` (canal del aviso de merge si Slack y ese aviso están prendidos; "Posted in
    #api-reviews"; un id sin nombre no se muestra).
  - `RemoteActivity.system` (`MacSystemSampler` en PRBarRemoteMac: núcleos, RAM usada/total, disco libre/total) y
    `running` (los trabajos de `status` con la hora del proceso de Claude más viejo de cada uno).
  - Mensajes de chat del mes: cada mensaje es una corrida, así que alcanza con `byKind["chat"].runs`.
  - **Quedan sin llenar**: `RespondInfo.currentFile` (declarado; la cola de Responder no sigue las herramientas de
    Claude), el costo de un trabajo en curso (Claude lo informa recién al terminar), el extracto de código en `edit`, y
    los nombres de los revisores que no son autores de un PR visible (no se piden).
  La redacción de rutas (`RemoteRedaction`) sigue corriendo sobre cada tópico.
- **Punta a punta sin simulador.** `Scripts/ios-e2e.sh` compila el relay en una carpeta temporal y corre
  `PRBarMobileEndToEndTests` (solo macOS, con `PRBAR_RELAY_BIN`): un `RemoteAccessService` con `FixtureActions`
  (librería nueva `PRBarRemoteFixtures`) en 127.0.0.1 y los view models del teléfono sobre `LiveTransport`: empareja
  (QR, código, acuse), llega `home` con los datos nuevos, cambia un finding, aprueba y mergea con prueba de presencia,
  chatea (el texto llega una sola vez y después un `chatDelta` de la Mac en vivo), la Mac revoca (claves y caché
  borradas) y un 4403 del relay (la Mac manda `device.remove` sin `bye`) deja las claves.
- **Copy que no está en el diseño** (de la app de la Mac cuando existe): vacíos de las pestañas (`PopoverTabs.emptyState`),
  "Cancel this review?" / "Keep Running" / "Cancel Review" / "Dismiss", "Undo Claude’s changes?" con el mensaje de
  `confirmationRequired`, "Review with Claude" (plan). Inventado: QR inválido ("This isn't a PRBar pairing code…"),
  vencido, cancelado, códigos distintos, "Connecting to <Mac>…", "Confirm on your Mac" (spec P.11) tras "Codes Match",
  la pantalla de confirmación de un link de emparejamiento, "Can't connect to <Mac>" (problema de relay),
  "Face ID changed" + "Pair Again", "Implement" en la barra de Respond, "Respond with Claude"/"Fix CI with Claude".
- **Pantallas.** El encabezado de cada pantalla es propio (círculos de vidrio del diseño) y se oculta la barra del
  sistema; el gesto de volver se conserva. `pair:paired` muestra el código con "Codes Match"/"Codes Don't Match" (diseño);
  tras "Codes Match" espera la confirmación de la Mac. "CI Failing" es una sección más de My PRs (los PRs de `ciList`
  salen de su sección). "Waiting for Review" y "Other" arrancan colapsadas. Settings no muestra la sección CLAUDE del
  diseño (Repositories, Claude rules): son comandos denegados (P.7, R.6). "CI failed on my PRs" maneja el interruptor
  `approved-or-ci` de la Mac. Tipografía con estilos de texto (Dynamic Type); el título de 24 del diseño usa `title2` (22).
- **Revisión criptográfica.** (L4) Un link `prbar://pair` o un QR nunca reemplaza un emparejamiento en silencio: pantalla
  de confirmación con el nombre de la Mac y el host del relay, aviso "This replaces your pairing with <Mac>", toque
  explícito, y después el código de 6 dígitos; un intento fallido no toca las claves existentes (se guardan recién con
  la confirmación de la Mac). (M3) Los códigos de cierre del relay (4401/4403/…) no prueban nada: son
  `LinkState.relayRejected` → problema de conexión con Try Again; las claves se borran solo con un `bye(revoked)` dentro
  de la sesión cifrada (`LinkState.revoked`, lo emite `LiveTransport`) o con Unpair. Las claves privadas viven solo en
  el llavero (la de presencia en el Secure Enclave; en el llavero va su `dataRepresentation`); la caché del App Group
  tiene solo datos de PRs.
- **Face ID.** `SecureEnclavePresence` evalúa primero la biometría con `LAContext` (cancelar es un `LAError` limpio) y
  después restaura la clave con ese contexto; si igual no firma, la clave es inválida ("Face ID changed. Pair this iPhone
  again from your Mac."). En el simulador (DEBUG) se usa una P-256 de software.
- **Compilar sin la plataforma iOS 26.** Con Xcode 26.6 sin el componente iOS 26.5 no hay destinos para el esquema y
  `actool` no compila el catálogo sin un runtime de simulador. `Scripts/ios-build-check.sh` compila en modo target (sin
  destino) para el simulador, el SDK del dispositivo sin firma y el bundle de tests, dejando afuera `Assets.xcassets`.
  Con la plataforma instalada valen los comandos del plan.
- **Pendiente.** Task 8 (APNs, NSE, `aps-environment`, categoría `PR`): necesita Team ID y App IDs. Tasks 9, 14 y 18
  (checklists en el iPhone real). Ícono de la app (el catálogo tiene el slot vacío).

---

## S. Testing

- **Sin Xcode** (`swift run PRBarTests`): `PRBarRemoteKit` completo — vectores de Noise (KK e IKpsk2), vectores de HPKE
  (RFC 9180 A.2, modo auth), SAS con vectores fijos, framing (trozos, relleno, compresión, límites), parser del QR,
  `RemotePolicy` (exhaustiva: cada `AppCommand.Name` clasificado; tabla de P.7 como test), presencia (firma de una P-256
  de software, bytes exactos, reloj, sesión, reuso), y **de punta a punta** `RemoteHost` ↔ `RemoteClient` sobre un
  `InMemoryRelay` (Swift) que implementa P.4 a nivel de marcos: emparejamiento, sesión, comando, eventos, revocación,
  Mac offline, rechazo de repeticiones. Del lado Mac: el puente con `FakeActions` (llama al método correcto, deniega lo
  denegado, exige presencia), el feed, el sender de pushes, el buzón, la CLI (`prbar remote …`) y la paridad.
- **Relay (Go)**: `go test ./...` (con Go de Homebrew o `docker run golang`): auth, ruteo, presencia, límites, buzón con
  TTL, ranuras de emparejamiento, inscripción, JWT de APNs y el pedido HTTP/2 contra un APNs falso (`httptest` con TLS y
  HTTP/2), logs sin contenido (un test busca el `b` en los logs y falla si aparece).
- **Integración Swift ↔ Go**: un test de `PRBarTests` que, si `PRBAR_RELAY_BIN` apunta al binario del relay, lo levanta
  en `127.0.0.1` y corre emparejamiento + sesión + push (con APNs falso) con `RemoteHost` y `RemoteClient` reales sobre
  `ws://` (solo permitido con `allowInsecureTransportForTests`).
- **No hay vectores Go ↔ Swift de cifrado**: el relay nunca cifra ni descifra. Los vectores son Swift ↔ Swift (Mac e iOS
  usan el mismo código de `PRBarRemoteKit`).
- **iOS** (`xcodebuild test`, simulador): view models con `FakeTransport`; la NSE con un sobre generado por
  `RemoteHost` de prueba; Face ID con `PresenceAuthorizer` falso. QA manual en el iPhone con checklist
  (`docs/qa/plan-19-checklist.md`).

---

## T. Lo que tiene que dar el usuario

1. **Team ID** de Apple Developer.
2. **Clave de APNs** (`.p8`) + su **Key ID** (Certificates, Identifiers & Profiles › Keys › Apple Push Notifications
   service). Se copia directo al VPS; nunca al repo ni a la Mac más allá de la descarga.
3. **App IDs** `com.federico.prbar.ios` (Push Notifications, App Groups) y `com.federico.prbar.ios.notifications` (App
   Groups), y el App Group `group.com.federico.prbar.ios` (o dejar que Xcode los cree con "Automatically manage signing").
4. **Xcode** instalado (26 o más nuevo) con la cuenta de desarrollador agregada.
5. El **iPhone conectado por cable una vez**, con Modo de desarrollador activado, para instalar la build.
6. **OK explícito** para desplegar en el VPS (task con compuerta en el Plan 17) y para el cambio de Traefik si hiciera
   falta (ver preguntas).

---

## U. Decisiones (resumen)

1. El teléfono es un cliente más de `AppCommand`; la Mac despacha con `CommandDispatcher` como para la CLI.
2. Tipos del protocolo en `PRBarWire` (multiplataforma) y protocolo/cifrado en `PRBarRemoteKit`; se testean con SwiftPM.
3. Noise KK para sesiones, Noise IKpsk2 para emparejar, HPKE auth para pushes y buzón; todo CryptoKit.
4. SAS = HKDF del hash del handshake, 6 dígitos; la Mac confirma.
5. Face ID = firma P-256 del Secure Enclave atada a sesión, comando, id y hora; la verifica la Mac.
6. Lista permitida exhaustiva en código compartido; por defecto se deniega.
7. Sin cola de comandos offline; con buzón de estado cifrado (último `home`) y caché local.
8. Relay en Go/distroless con bbolt, inscripción por token, auth Ed25519 por desafío, logs sin contenido.
9. iOS 26 mínimo; XcodeGen; bundle ids `com.federico.prbar.ios[.notifications]`.
10. `CommandProtocol.version` 7 y `minimumRemoteVersion` para tolerar una app de iPhone un poco más vieja.

## V. Preguntas abiertas (respondidas por el usuario, 2026-11-20)

1. **Face ID solo para merge, push / push anyway y approve.** "Comment" y "Request changes" al publicar un review **no**
   piden Face ID (confirmado; es la tabla de P.7).
2. **WebSockets largos y el `readTimeout` de 60 s de Traefik v3: se resuelve en el VPS sin afectar a otros servicios.**
   La task de despliegue primero prueba una conexión de 5 min (inactiva + `ping`) por el entrypoint existente. Si se
   corta: se agrega un **entrypoint de Traefik dedicado**, usado solo por el router de PRBar (p. ej. `:8443`, con
   `readTimeout` 0 o largo, y pings de aplicación cada 25 s); si eso no se puede, el relay termina TLS él mismo en su
   propio puerto. **Nunca** se cambian los timeouts del entrypoint compartido (`https`/`websecure`). Abrir un puerto
   extra en el firewall del VPS está bien, pero es parte del despliegue con compuerta (OK del usuario en ese momento).
3. **Buzón**: la Mac guarda su último estado cifrado (`home`) en el buzón del relay hasta 7 días, con un ajuste en la Mac
   para apagarlo (confirmado).
