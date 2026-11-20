# PRBar — Plan 18: Acceso remoto desde el iPhone — lado Mac

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PRBar.app se conecta al relay (saliendo, sin puertos), empareja iPhones con QR + código de 6 dígitos, guarda y
revoca dispositivos, ejecuta los comandos que llegan del teléfono por el **mismo** `CommandDispatcher` que usa `prbar`
(con la lista permitida y la verificación de Face ID), empuja el estado en vivo, deja el último estado cifrado en el
buzón y manda las notificaciones cifradas. Todo lo nuevo tiene comando de CLI (`prbar remote …`) y entra en el test de
paridad. Sin Xcode.

**Spec:** `docs/superpowers/specs/2026-11-20-prbar-iphone-design.md`, partes **P** (P.5–P.12) y **Q**. La Task 14 agrega
**Q.4 Decisiones de implementación (Plan 18)**.

**Orden de ejecución:** después del Plan 17 (y de `feat/ci-cost`). Las Tasks 1–8 alcanzan para la fase 1 del iPhone;
el resto (presencia, feed de detalle, activity) habilita las fases 2 y 3, aunque el código es genérico.

## Qué asume del Plan 17

| Artefacto | Uso |
|---|---|
| `PRBarWire` re-exportado por Core | Sin cambios de imports |
| `RemoteHost`, `RelayLink`, `WebSocketRelayLink`, `MacKeys`, `PairedDevice`, `RemotePolicy`, `SealedEnvelope`, `PushPayload`, `PushIdentifiers`, `PresenceVerifier` | Todo el lado Mac se arma sobre esto |
| `InMemoryRelay` (tests) | Los tests de este plan usan el mismo relay en memoria |
| `CommandProtocol.version == 6` | Sube a **7** (Task 9) |

## Convenciones

- Build por producto: `swift build --product PRBar`, `swift build --product PRBarCLI`, `swift build --product PRBarTests`.
  Tests: `swift run PRBarTests [filtro]`. Archivos de test nuevos al final de `allTests`.
- **Nunca** correr la CLI sin `PRBAR_SOCKET` apuntando a un socket de prueba. Los tests nunca hablan con el relay real.
- Capturas: `Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both` y mirarlas con Read.
- UI en inglés; comentarios en español. Commits en inglés **sin** `Co-Authored-By` ni atribución a Claude/Anthropic.
  Sin push.
- Nunca se loguean argumentos de comandos, textos cifrados, claves, el token de inscripción ni contenido de PRs: solo
  nombres de comando, prefijos de 4 caracteres de ids y estados.

## Estructura de archivos

```
Sources/PRBarCore/
  RemoteSettings.swift          (nuevo) AppConfig.remote: enabled, relayHost, accountId, keepAwakeWhileCharging
  RemoteDeviceStore.swift       (nuevo) devices.json (0600) con PairedDevice; keys en el llavero (SecretStore)
  RemoteKeyStore.swift          (nuevo) MacKeys en el llavero vía SecretStore (servicio "PRBar Remote")
  RemoteStateTopics.swift       (nuevo) RemoteHome, RemotePRDetail, RemoteActivity + cómo se calculan desde PRBarActions
  RemotePushPlanner.swift       (nuevo) PlannedNotification → PushPayload (deepLink, threadId, badge)
  AppCommand.swift … (PRBarWire) (modificar) casos remote*; CommandProtocol.version 7, minimumRemoteVersion 7
  CommandActions.swift, CommandDispatcher.swift, CommandResults.swift (modificar) RemoteActions, RemoteStatusInfo,
                                RemoteDeviceInfo, RemotePairingInfo
Sources/PRBarRemoteKit/RemotePolicy.swift (modificar) casos remote*
Sources/PRBar/Remote/
  RemoteAccessService.swift     (nuevo) dueño de RemoteHost; ciclo de vida, reconexión, red, despertar
  RemoteCommandBridge.swift     (nuevo) handler del host → CommandDispatcher (con nombre en el log)
  RemoteStateFeed.swift         (nuevo) observación de AppModel → tópicos; activity cada 5 s
  RemoteMailboxWriter.swift     (nuevo) último home cifrado por dispositivo (cada 60 s si cambió)
  KeepAwake.swift               (nuevo) IOPMAssertion solo en corriente
  QRCodeImage.swift             (nuevo) CIQRCodeGenerator → NSImage; matriz para la CLI
  AppModel+Remote.swift         (nuevo) RemoteActions
Sources/PRBar/Settings/
  IPhoneTab.swift               (nuevo) Settings › iPhone
  PairIPhoneSheet.swift         (nuevo) QR → código → Codes Match
  EnableRemoteSheet.swift       (nuevo) relay + token de inscripción
  SettingsView.swift            (modificar) pestaña .iphone
Sources/PRBar/NotificationDelivery.swift, AppModel.swift (modificar) también a los iPhones
Sources/PRBarCLIKit/
  RemoteCommands.swift          (nuevo) prbar remote …
  QRRender.swift                (nuevo) matriz → medios bloques Unicode
  CLIRouter.swift, PRBarCLIKit.swift (modificar)
Sources/PRBarTests/
  RemoteSettingsTests, RemoteDeviceStoreTests, RemoteBridgeTests, RemoteStateFeedTests, RemotePushPlannerTests,
  RemoteCLITests, KeepAwakeTests (nuevos); FakeActions, CLIParsingTests, CommandDispatcherTests, UIActionInventory,
  RemotePolicyTests, main.swift (modificar)
docs/cli.md, docs/qa/plan-18-checklist.md, docs/screenshots/README.md, spec (Q.4)
```

---

### Task 1: Configuración y almacenamiento de claves y dispositivos

**Files:** `Sources/PRBarCore/RemoteSettings.swift`, `RemoteKeyStore.swift`, `RemoteDeviceStore.swift`, `Config.swift`
(modificar); tests `RemoteSettingsTests`, `RemoteDeviceStoreTests`.

- [ ] **Step 1: Tests que fallan.**
  - `AppConfig` sin `remote` decodifica con `RemoteSettings.default` (`enabled: false`, `relayHost: nil`, `accountId:
    nil`, `keepAwakeWhileCharging: false`); con `remote` hace ida y vuelta; `CodingKeys` al final (como `runners`).
  - `RemoteKeyStore(secrets: InMemorySecretStore())`: `loadOrCreate()` crea `MacKeys` una vez y después devuelve las
    mismas; `reset()` las borra; nunca escribe claves en `config.json`.
  - `RemoteDeviceStore(directory:)`: `add`, `remove`, `update(lastSeen:)`, `setRequirePresence`; el archivo queda 0600 y
    la carpeta 0700; un archivo corrupto se renombra a `devices.json.broken-<fecha>` y se arranca vacío (log, sin crash).
- [ ] **Step 2:** compilar → faltan tipos. **Step 3: Implementar** (usar el `SecretStore`/`KeychainStore` existente;
  servicio `"PRBar Remote"`, cuentas `mac-relay`, `mac-noise`, `mac-seal`; las claves como `rawRepresentation` en base64).
- [ ] **Step 4:** `swift run PRBarTests remote` verde. **Commit** `"Store remote access settings, Mac keys and paired devices"`.

### Task 2: `RemoteAccessService` — conexión al relay

**Files:** `Sources/PRBar/Remote/RemoteAccessService.swift`, `AppModel.swift` (modificar: arranque/parada)

- [ ] **Step 1: Implementar** una clase `@MainActor @Observable` con estado `RemoteConnectionState` (`.disabled`,
  `.connecting`, `.connected(devicesOnline: Int)`, `.offline(retryAt: Date, reason: String)`, `.enrollmentFailed(String)`),
  dueña de un `RemoteHost` (Plan 17) con `WebSocketRelayLink` a `wss://<relayHost>/v1/ws`. Reconexión con el backoff del
  host; `NWPathMonitor` (Network.framework, disponible con CLT) y `NSWorkspace.didWakeNotification` fuerzan un reintento
  inmediato; `NSWorkspace.willSleepNotification` manda `bye` y cierra.
- [ ] **Step 2: Inscripción**: `enable(relayHost:enrollToken:)` → `POST https://<host>/v1/accounts` con
  `URLSession` (timeout 15 s) → guarda `accountId` y `relayHost`, `enabled = true`, conecta. Errores: 403 → "The relay
  refused the enrollment token."; 429 → "Too many attempts. Try again in 15 minutes."; red → "Couldn’t reach <host>.".
- [ ] **Step 3: Tests** (`RemoteBridgeTests`, sección conexión) con `InMemoryRelay` inyectado por un `RelayLinkFactory`:
  habilitar → `.connected(0)`; el relay corta → `.offline` → reconecta solo; `disable()` → `.disabled` y no reintenta.
- [ ] **Step 4:** verde + `swift build --product PRBar`. **Commit** `"Connect PRBar to the relay with backoff and wake handling"`.

### Task 3: Emparejamiento (servicio)

**Files:** `RemoteAccessService.swift` (pairing), `AppModel+Remote.swift`

- [ ] **Step 1: Tests que fallan** (con `InMemoryRelay` y un `RemoteClient` del Plan 17 haciendo de teléfono):
  `startPairing()` → `RemotePairingInfo {pairingId, qr, expiresAt}`; el cliente escanea → el servicio publica
  `.waitingForConfirmation(code, deviceName, model)`; `confirmPairing(true)` → dispositivo en `RemoteDeviceStore` con sus
  tres claves públicas y `requirePresence = true`, `device.add` en el relay; `confirmPairing(false)` o 5 min → ranura
  cerrada, nada guardado. Un segundo `startPairing()` cancela el anterior.
- [ ] **Step 2: Implementar** sobre `RemoteHost.startPairing/confirmPairing`. **Commit** `"Pair iPhones with a QR and a matching code"`.

### Task 4: El puente de comandos

**Files:** `Sources/PRBar/Remote/RemoteCommandBridge.swift`; `RemoteBridgeTests`

- [ ] **Step 1: Tests que fallan** (con `FakeActions` existente como `PRBarActions`):
  - Un `req` `.status` desde un dispositivo emparejado → `FakeActions.calls == ["status"]`, respuesta igual a la del
    socket de la CLI para el mismo comando (mismo `JSONValue`).
  - `.reviewStart(pr:, wait: true)` → los eventos `progress` llegan al cliente en orden y después el resultado.
  - Cada comando denegado de P.7 (recorrer `AppCommand.Name.allCases` con un ejemplo construible por nombre; los
    ejemplos ya existen en `CommandDispatcherTests`/`CLIParsingTests` — reusar esa tabla) → `.unauthorized` y
    `FakeActions.calls` vacío.
  - `merge` sin prueba → `.unauthorized` "Face ID is required for this on iPhone."; con prueba válida (firmada por la
    clave del dispositivo, `SoftwarePresenceSigner`) → `FakeActions.calls == ["merge"]`; con prueba válida pero
    `confirmed: false` → `.confirmationRequired` (la verificación de siempre del dispatcher).
  - Dispositivo con `requirePresence = false` → `merge` sin prueba pasa.
  - El log (`AppLog` con destino inyectado) tiene `"iPhone <4 chars>: merge"` y **no** el PR ni argumentos.
- [ ] **Step 2: Implementar.** El handler del `RemoteHost` es:

```swift
/// El teléfono es un cliente más de `AppCommand` (spec P.1): mismos métodos de `AppModel` que la UI y `prbar`.
func handleRemote(_ command: AppCommand, device: PairedDevice, events: @escaping CommandEventSink) async
    -> Result<JSONValue, CommandFailure> {
    AppLog.write("iPhone \(device.deviceId.prefix(4)): \(command.name.rawValue)")
    return await CommandDispatcher.run(command, on: appModel, events: events)
}
```

  La política y la presencia ya las aplicó `RemoteHost` antes de llamar (Plan 17); el puente **re-verifica**
  `RemotePolicy.decide(command) != .denied` como defensa en profundidad (un test la ejerce con un host falso que se la
  saltea).
- [ ] **Step 3:** verde. **Commit** `"Run iPhone requests through the command dispatcher with the remote policy"`.

### Task 5: Feed de estado (`home`, `pr:<id>`, `activity`)

**Files:** `Sources/PRBarCore/RemoteStateTopics.swift`, `Sources/PRBar/Remote/RemoteStateFeed.swift`; `RemoteStateFeedTests`

- [ ] **Step 1: Tests que fallan** (Core, con `FakeActions`):
  - `RemoteStateTopics.home(actions)` = `{status: actions.status(), prs: actions.listPRs(nil, nil, nil), ci: actions.ciList()}`.
  - `RemoteStateTopics.prDetail("a/b#1", actions)`: `review`/`respond`/`chat` en `nil` cuando el método lanza
    `notFound`/`invalidState` ("no hay review"), y el error se propaga si es otro.
  - `activity`: `resources()` + `usage(nil)` + `historyList(limit: 20)`.
  - `RemoteTopic.parse("pr:acme/api#12")` y rechazos (`pr:`, tópicos desconocidos, más de 20 tópicos por `sub`).
- [ ] **Step 2: Implementar `RemoteStateFeed`** (app): por cada tópico suscrito por alguna sesión, recalcula con
  `withObservationTracking { _ = topics.compute(appModel) } onChange: { schedule() }` agrupado cada 300 ms, compara con el
  último enviado (`Equatable`) y publica con `rev + 1` vía `RemoteHost.publish`. `activity` además con un `Timer` de 5 s
  mientras esté suscrito. Chat en streaming iniciado desde la Mac: `AppModel+Chat` expone un `onChatDelta(pr, text)` que
  el feed reenvía como `chatDelta` a las sesiones suscritas a `pr:<id>`.
- [ ] **Step 3: Test del feed** (app, con `InMemoryRelay` + cliente): suscribir `home`, cambiar el `AppModel` de prueba
  (los snapshots de `Scripts/snapshots.sh` ya arman un `AppModel` con datos de prueba; reusar esa fábrica), recibir un
  `state` con `rev` 2; sin cambios no se manda nada en 1 s.
- [ ] **Step 4:** verde. **Commit** `"Push live home, PR and activity state to paired iPhones"`.

### Task 6: Buzón con el último `home`

**Files:** `Sources/PRBar/Remote/RemoteMailboxWriter.swift`

- [ ] **Step 1: Test que falla:** con dos dispositivos, un cambio de `home` → a los 60 s (reloj inyectado) un `mbox.put`
  por dispositivo, slot `home`, abrible solo con la clave de cada uno, `rev` creciente persistido (en
  `RemoteSettings.mailboxRev`) para que no baje después de reiniciar la app. Sin cambios → nada. Opción apagada
  (`RemoteSettings.mailboxEnabled = false`, pregunta abierta 3 del spec) → nada y se borra el slot.
- [ ] **Step 2: Implementar. Commit** `"Leave the latest encrypted home state in each iPhone's mailbox"`.

### Task 7: Notificaciones push

**Files:** `Sources/PRBarCore/RemotePushPlanner.swift`, `NotificationDelivery.swift`/`AppModel.swift` (modificar);
`RemotePushPlannerTests`

- [ ] **Step 1: Tests que fallan.** `RemotePushPlanner.payloads(for: [PlannedNotification], badge:)` →
  `PushPayload` con el mismo título y cuerpo que la notificación de la Mac, `kind`, `pr`, `threadId`, y `deepLink`:
  `newToReview`/`reviewedPRUpdated` → `prbar://pr/<o>/<r>/<n>?screen=review`; `myPRFeedback` → `screen=respond`;
  `readyToMerge` → `screen=merge`; Fix CI (de `feat/ci-cost`) → `screen=respond`; `updateAvailable`/`diskUsage` →
  `prbar://activity`; agrupadas ("3 new PRs to review") → `prbar://home`. `badge` = `StatusInfo.badgeCount`.
- [ ] **Step 2: Implementar** y conectar: donde `AppModel` llama `notificationDelivery.deliver(planned)`, también
  `remoteAccess.push(planned)` → para cada dispositivo con token conocido (el relay avisa con `pushResult`; un 410 marca
  el dispositivo "notifications off" en la lista de Settings). Las notificaciones respetan los mismos ajustes de
  `notify` (ya filtradas por el planner).
- [ ] **Step 3:** verde (incluye un test con `InMemoryRelay`: `push` con `collapse` y `thread` opacos, abrible por el
  dispositivo). **Commit** `"Send encrypted push notifications to paired iPhones"`.

### Task 8: Mantener la Mac despierta en corriente

**Files:** `Sources/PRBar/Remote/KeepAwake.swift`; `KeepAwakeTests`

- [ ] **Step 1: Test que falla** con un `PowerSource` falso y un `AssertionTaker` falso: habilitado + AC → toma una
  aserción con el nombre "PRBar: iPhone remote access"; pasa a batería → la suelta; deshabilitar remoto → la suelta;
  nunca dos aserciones a la vez.
- [ ] **Step 2: Implementar** con `IOPSCopyPowerSourcesInfo`/`IOPSGetProvidingPowerSourceType` y
  `IOPSNotificationCreateRunLoopSource` para enterarse del cambio, `IOPMAssertionCreateWithName(
  kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id)` y
  `IOPMAssertionRelease`. **Commit** `"Keep the Mac awake while charging when iPhone access is on"`.

### Task 9: `AppCommand` `remote*`, política, protocolo 7

**Files:** `Sources/PRBarWire/AppCommand.swift`, `CommandMessages.swift`, `CommandResults.swift`;
`Sources/PRBarCore/CommandActions.swift`, `CommandDispatcher.swift`; `Sources/PRBarRemoteKit/RemotePolicy.swift`;
`Sources/PRBar/AppModel+Remote.swift`; `FakeActions.swift`, `CommandDispatcherTests`, `RemotePolicyTests`

- [ ] **Step 1: Tests que fallan.**
  - Dispatcher: cada caso nuevo llama a su método de `RemoteActions` en `FakeActions`; `remoteRevoke`/`remoteReset` sin
    `confirmed` → `.confirmationRequired`.
  - Política: todos los `remote*` `.denied` salvo `remoteSetPresenceRequirement(enabled: true)` `.allowed` y
    `(enabled: false)` `.gated`. Desde el teléfono, `remoteSetPresenceRequirement` solo puede cambiar **su propio**
    dispositivo: el puente reemplaza `device` por el id de la sesión (test: un teléfono intenta cambiar otro → se aplica
    al suyo).
  - `CommandProtocol.version == 7`, `minimumRemoteVersion == 7`.
- [ ] **Step 2: Implementar.** Casos:

```swift
// Acceso desde el iPhone (spec Q.3)
case remoteStatus
case remoteEnable(relay: String, enrollToken: String)
case remoteDisable
case remotePairStart
/// Espera a que un teléfono se una a la ranura (evento `progress` con el código) o a que venza.
case remotePairWait(pairing: String)
case remotePairConfirm(pairing: String, confirmed: Bool)
case remoteDevices
case remoteRevoke(device: String, confirmed: Bool)
case remoteSetKeepAwake(enabled: Bool)
case remoteReset(confirmed: Bool)
case remoteSetPresenceRequirement(device: String, enabled: Bool)
```

  `runsToCompletion`: `remoteEnable` (como `slackTokenSet`). `remoteEnable` lleva un secreto: `AppLog` ya loguea solo el
  nombre. Resultados: `RemoteStatusInfo {enabled, relayHost?, state, devicesOnline, keepAwake, accountPrefix?}`,
  `RemoteDeviceInfo {id, name, model, pairedAt, lastSeen?, online, requirePresence, notifications}`,
  `RemotePairingInfo {pairing, qr, expiresAt, code?, deviceName?, model?}`. Comentario de versión:
  `/// 7: acceso desde el iPhone (remote*, minimumRemoteVersion).`
- [ ] **Step 3:** verde. **Commit** `"Add the remote AppCommands and bump the command protocol to 7"`.

### Task 10: CLI `prbar remote …`

**Files:** `Sources/PRBarCLIKit/RemoteCommands.swift`, `QRRender.swift`, `CLIRouter.swift`, `PRBarCLIKit.swift`;
`Sources/PRBar/Remote/QRCodeImage.swift`; `RemoteCLITests`, `CLIParsingTests`

- [ ] **Step 1: Tests que fallan.**
  - Parseo: `remote status [--json]`, `remote enable --relay H --enroll-token-stdin` (lee una línea de stdin; sin
    `--enroll-token-stdin` y en TTY pide sin eco con `readpassphrase`), `remote disable`, `remote pair`, `remote devices
    [--json]`, `remote revoke <device> [--yes]`, `remote keep-awake on|off`, `remote reset [--yes]` → el `AppCommand`
    correcto. `CLIRouter.commands` tiene una entrada por cada `remote*` (la paridad lo exige) salvo
    `remoteSetPresenceRequirement`, que mapea a `remote devices --require-face-id <device> on|off` (agregar la opción).
  - `QRRender.halfBlocks(matrix:)`: una matriz conocida de 21×21 produce las líneas esperadas (`▀`, `▄`, `█`, espacio)
    con zona silenciosa de 2 módulos.
  - `remote pair` sin TTY → exit 2 ("Pairing needs a terminal to show the QR code."). En TTY (test con `Interactive`
    falso): imprime el QR, la URL de respaldo, "Waiting for your iPhone… (expires in 5:00)", y al llegar el evento del
    código pregunta `Does your iPhone show 123 456? [y/N]`.
- [ ] **Step 2: Implementar.** La matriz del QR la arma la app (`remotePairStart` devuelve `qr` y la CLI genera la matriz
  con CoreImage: `CIFilter(name: "CIQRCodeGenerator")` con `inputCorrectionLevel = "M"`, leyendo los píxeles del
  `CIImage` a escala 1; disponible en macOS sin Xcode). `docs/cli.md`: sección "iPhone".
- [ ] **Step 3:** `swift run PRBarTests cli` y `swift run PRBarTests parity` verdes. **Commit** `"Add prbar remote for iPhone access"`.

### Task 11: Settings › iPhone

**Files:** `Sources/PRBar/Settings/IPhoneTab.swift`, `PairIPhoneSheet.swift`, `EnableRemoteSheet.swift`,
`SettingsView.swift`; `SettingsTabName.iphone` (Wire); `UIActionInventory`; snapshots.

- [ ] **Step 1: UI** según Q.2 del spec. `SettingsView.Tab.iphone` ("iPhone", símbolo `iphone`, 700×520). Controles y
  sus comandos de CLI en `UIActionInventory`:
  - "Allow iPhone remote control" → `remote enable` / `remote disable`
  - "Pair iPhone…" → `remote pair`; "Codes Match" → `remote pair` (confirmación); "Cancel" → `viewOnly`
  - "Revoke…" → `remote revoke`; "Require Face ID" (por dispositivo) → `remote devices --require-face-id`
  - "Keep this Mac awake while charging" → `remote keep-awake`
  - "Reset iPhone Access…" → `remote reset`
  - "Enable" en la hoja → `remote enable`
- [ ] **Step 2: Snapshots** nuevos en `Sources/PRBar/Snapshots`: pestaña deshabilitada, conectada con 2 dispositivos,
  hoja con QR, hoja con código. `Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both` y mirarlas.
- [ ] **Step 3:** `swift run PRBarTests "ui parity"` verde. **Commit** `"Add Settings › iPhone with pairing and devices"`.

### Task 12: Prueba de punta a punta con el relay real (local)

- [ ] `(cd relay && go build -o /tmp/prbar-relay ./cmd/prbar-relay)`; test `RemoteMacIntegrationTests` (corre solo con
  `PRBAR_RELAY_BIN`): `RemoteAccessService` real + `RemoteClient` (teléfono simulado) contra el relay local: habilitar
  con token, emparejar, `status`, un `reviewStart` falso con eventos, `merge` con presencia, revocar. **Commit**
  `"Test Mac remote access end to end against a local relay"`.

### Task 13: QA manual (con el relay desplegado y antes del iPhone)

- [ ] `docs/qa/plan-18-checklist.md`: habilitar con el token real; ver "Connected"; `prbar remote status`; `prbar remote
  pair` muestra el QR legible; con el teléfono simulado (`swift run PRBarTests "remote smoke"` contra el relay real, con
  `PRBAR_RELAY_HOST`) emparejar y revocar; dormir la Mac → el relay marca offline; keep-awake en corriente
  (`pmset -g assertions | grep PRBar`). Nada de esto se automatiza contra el relay real en la suite.

### Task 14: Decisiones en el spec

- [ ] **Q.4 Decisiones de implementación (Plan 18)** en el spec. **Commit** `"Record the plan 18 implementation decisions in the spec"`.

---

## Verificación final

```
swift build --product PRBar && swift build --product PRBarCLI && swift build --product PRBarTests
swift run PRBarTests
(cd relay && go build -o /tmp/prbar-relay ./cmd/prbar-relay) && PRBAR_RELAY_BIN=/tmp/prbar-relay swift run PRBarTests "integration"
Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both
```
