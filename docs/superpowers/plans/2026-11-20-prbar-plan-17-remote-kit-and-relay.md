# PRBar — Plan 17: Protocolo remoto compartido (`PRBarWire`, `PRBarRemoteKit`) y relay

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** El código que comparten la Mac y el iPhone para hablar a través del relay — los tipos de `AppCommand` en un
target multiplataforma, el cifrado (Noise KK / IKpsk2, HPKE auth, SAS, atestación de presencia), el framing, el
protocolo del relay, la política de comandos y las máquinas de estado `RemoteHost` (Mac) y `RemoteClient` (teléfono) —
más el relay en Go con su imagen, su compose y su despliegue (con compuerta). Todo se construye y se testea sin Xcode.

**Spec:** `docs/superpowers/specs/2026-11-20-prbar-iphone-design.md`, partes **P** y **S**. La Task 16 agrega
**P.14 Decisiones de implementación (Plan 17)**.

**Orden de ejecución:** después de mergear `feat/ci-cost` (protocolo 6). Este plan → Plan 18 → Plan 19.

## Qué asume

| De | Artefacto | Uso |
|---|---|---|
| Plan 7 | `AppCommand`, `AppCommandTypes`, `CommandProtocol`, `CommandResults`, `JSONValue` | Se mueven a `PRBarWire` (Task 1) |
| Plan 15 (`feat/ci-cost`) | `ciList`, `ciFix`, `usage`, `CIListEntry`, `UsageInfo`, protocolo 6 | La política los clasifica (Task 9) |
| — | `KeychainStore` | No se toca acá: el guardado de claves de la Mac es del Plan 18 |

**Si algo no está:** si `feat/ci-cost` no se mergeó, `RemotePolicy` no tiene sus casos (el `switch` exhaustivo lo dice
al compilar después del merge) y se agregan entonces con la clase de la tabla de P.7.

## Convenciones

- Build **por producto**: `swift build --product PRBar`, `swift build --product PRBarCLI`,
  `swift build --product PRBarTests` (un `swift build` pelado falla por el plugin de argument-parser). Sin warnings
  nuevos.
- Tests Swift: `swift run PRBarTests [filtro]`. Archivos nuevos al **final** de `allTests` en
  `Sources/PRBarTests/main.swift`. `expect`/`expectEqual` toman autoclosures **sin** `await`: hoistear a una variable.
- Go: `relay/`, módulo `prbar-relay`, Go ≥ 1.26 (`brew install go`, o sin instalar nada:
  `docker run --rm -v "$PWD/relay":/src -w /src golang:1.27 go test ./...`). `gofmt -l .` vacío y `go vet ./...` limpio.
- `PRBarWire` y `PRBarRemoteKit` **no** importan `AppKit`, `IOKit`, `Darwin` (sockets) ni usan `Process`: tienen que
  compilar para iOS (Plan 19). La Task 2 agrega un test que lo verifica con un `grep`.
- Los tests **nunca** hablan con el relay real, APNs ni la red: `InMemoryRelay` (Swift) y `httptest` (Go).
- Commits en inglés, **sin** `Co-Authored-By` ni atribución a Claude/Anthropic. Sin push.
- Comentarios en español; nombres en inglés.
- **Nada se despliega** sin un OK explícito del usuario (Task 15).

## Estructura de archivos

```
Package.swift                                   (modificar) targets PRBarWire, PRBarRemoteKit; producto library; iOS 26
Sources/PRBarWire/                              (nuevo, movido de PRBarCore) AppCommand.swift, AppCommandTypes.swift,
                                                CommandMessages.swift (lo de CommandProtocol sin servidor), CommandResults.swift
                                                (solo structs), JSONValue.swift, WireLeaves.swift (enums hoja)
Sources/PRBarCore/PRBarWireExport.swift         (nuevo) @_exported import PRBarWire
Sources/PRBarRemoteKit/
  Base64URL.swift, Bytes.swift                  helpers
  Noise.swift                                   CipherState, SymmetricState, HandshakeState, patrones KK e IKpsk2
  Sealed.swift                                  HPKE auth (push y buzón), PushPayload, MailboxBlob
  SAS.swift                                     código de 6 dígitos
  Presence.swift                                PresenceProof, PresenceSigner, PresenceVerifier
  Framing.swift                                 trozos, relleno, compresión, ensamblado
  RemoteFrame.swift                             marcos de aplicación (P.6)
  RelayMessages.swift                           marcos del relay (P.4)
  PairingQR.swift                               prbar://pair?… ida y vuelta
  RemotePolicy.swift                            P.7
  RelayTransport.swift                          protocolo RelayLink + WebSocketRelayLink (URLSessionWebSocketTask)
  RemoteHost.swift                              máquina de estado de la Mac
  RemoteClient.swift                            máquina de estado del teléfono
  RemoteKeys.swift                              conjuntos de claves y su serialización (sin almacenamiento)
Sources/PRBarTests/
  WireTests, NoiseTests (+ NoiseVectors.swift), SealedTests, SASTests, PresenceTests, FramingTests, PairingQRTests,
  RemotePolicyTests, InMemoryRelay.swift (helper), RemoteEndToEndTests, RelayIntegrationTests (nuevos); main.swift
relay/
  go.mod, go.sum, cmd/prbar-relay/main.go
  internal/config, internal/store (bbolt), internal/hub (conexiones, ruteo, presencia), internal/auth,
  internal/ratelimit, internal/apns, internal/logx
  Dockerfile, deploy/docker-compose.yml, deploy/prbar-relay.env.example, deploy/deploy.sh, README.md
docs/superpowers/specs/2026-11-20-prbar-iphone-design.md (P.14)
```

---

### Task 1: `PRBarWire` — los tipos del protocolo en un target multiplataforma

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PRBarWire/*`, `Sources/PRBarCore/PRBarWireExport.swift`
- Move: de `Sources/PRBarCore/` a `Sources/PRBarWire/` (con `git mv`) `AppCommand.swift`, `AppCommandTypes.swift`,
  `JSONValue.swift`; partir `CommandProtocol.swift` y `CommandResults.swift`.

- [ ] **Step 1: Package.swift.**

```swift
// swift-tools-version:5.10
let package = Package(
    name: "PRBar",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .executable(name: "PRBar", targets: ["PRBar"]),
        .executable(name: "PRBarCLI", targets: ["PRBarCLI"]),
        // La app de iOS (Plan 19) consume este producto como paquete local.
        .library(name: "PRBarRemoteKit", targets: ["PRBarRemoteKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.6.2"),
    ],
    targets: [
        .target(name: "PRBarWire"),
        .target(name: "PRBarRemoteKit", dependencies: ["PRBarWire"]),
        .target(name: "PRBarCore", dependencies: ["PRBarWire"]),
        .executableTarget(name: "PRBar", dependencies: ["PRBarCore", "PRBarRemoteKit"]),
        .target(name: "PRBarCLIKit", dependencies: [
            "PRBarCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "PRBarCLI", dependencies: ["PRBarCLIKit"]),
        .executableTarget(name: "PRBarTests", dependencies: ["PRBarCore", "PRBarCLIKit", "PRBarRemoteKit"]),
    ]
)
```

- [ ] **Step 2: Mover.** `git mv` de `AppCommand.swift`, `AppCommandTypes.swift`, `JSONValue.swift` a `Sources/PRBarWire/`.
  `CommandProtocol.swift` se parte: `Hello`, `HelloMessage`, `CommandFailure`, `CommandEvent`, `CommandEventSink`,
  `CommandResponse`, `CommandRequest` y el enum `CommandProtocol` (versión, encoder, decoder, `line`, `decode`) van a
  `Sources/PRBarWire/CommandMessages.swift`; en Core no queda nada de ese archivo (bórrese). `CommandResults.swift` se
  parte: los `public struct …Info`/`…DTO` y `PRLink`, `PopoverInfo`, `CIListEntry`, `UsageInfo` van a
  `Sources/PRBarWire/CommandResults.swift`; las `extension ReviewPhase/RespondPhase/MergePhase/FeedbackItem/ChatInfo`
  que convierten modelos de Core quedan en `Sources/PRBarCore/CommandResults+Core.swift`. Los `init` de los structs que
  reciben tipos de Core (si los hay) se vuelven extensiones en ese mismo archivo de Core.

- [ ] **Step 3: Las hojas.** `swift build --product PRBarTests 2>&1 | grep "error: cannot find type" | sort -u`. Cada tipo
  que falte en Wire (p. ej. `Severity`, `PopoverTab`, `PopoverSection`, `MergeMethod`, `ReviewEvent`, `RuleScope`,
  `RuleStage`, `PromptStage`, `SlackProvider`, `PRBarError` si aparece en un resultado) se mueve **si es un enum/struct
  Codable sin dependencias de Core**; si arrastra lógica de Core, se mueve solo la declaración y la lógica queda como
  `extension` en Core. Repetir hasta que compile. Anotar en P.14 la lista final.

- [ ] **Step 4: Re-exportar.** `Sources/PRBarCore/PRBarWireExport.swift`:

```swift
// Los tipos del protocolo viven en PRBarWire (compila también para iOS); Core los re-exporta para que ningún archivo
// existente tenga que cambiar sus imports.
@_exported import PRBarWire
```

- [ ] **Step 5: Verde.** `swift build --product PRBar && swift build --product PRBarCLI && swift build --product PRBarTests && swift run PRBarTests` → todo pasa como antes (es un movimiento puro). Si un `internal` de Core se usaba desde un archivo movido, pasarlo a `public` (o mover el helper).

- [ ] **Step 6: Commit.** `git commit -am "Move the command protocol types into a cross-platform PRBarWire target"`
  (más `git add Sources/PRBarWire Sources/PRBarCore/PRBarWireExport.swift Sources/PRBarCore/CommandResults+Core.swift`).

---

### Task 2: `PRBarRemoteKit` vacío, helpers y el guardián de portabilidad

**Files:**
- Create: `Sources/PRBarRemoteKit/Base64URL.swift`, `Sources/PRBarRemoteKit/Bytes.swift`
- Test: `Sources/PRBarTests/WireTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.**

```swift
import Foundation
import PRBarRemoteKit

enum WireTests {
    static let cases: [TestCase] = [
        TestCase("wire: base64url sin relleno ida y vuelta") {
            for n in 0..<70 {
                let data = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 37) })
                let text = Base64URL.encode(data)
                try expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
                try expectEqual(try Base64URL.decode(text), data)
            }
            try expect((try? Base64URL.decode("a")) == nil)       // largo imposible
            try expect((try? Base64URL.decode("ab+c")) == nil)    // alfabeto estándar rechazado
        },
        TestCase("wire: PRBarWire y PRBarRemoteKit no usan APIs solo de macOS") {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let forbidden = ["import AppKit", "import IOKit", "import Darwin", "Process(", "NSWorkspace", "getpeereid"]
            for target in ["PRBarWire", "PRBarRemoteKit"] {
                let dir = root.appendingPathComponent(target)
                let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
                for file in files {
                    let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                    for word in forbidden where text.contains(word) {
                        throw TestFailure(description: "\(target)/\(file) usa \(word): tiene que compilar para iOS")
                    }
                }
            }
        },
    ]
}
```

- [ ] **Step 2:** `swift build --product PRBarTests 2>&1 | grep error: | head -3` → `cannot find 'Base64URL'`.

- [ ] **Step 3: Implementar** `Base64URL` (`encode(_:) -> String`, `decode(_:) throws -> Data`, rechaza `=`, `+`, `/`,
  espacios y largos `% 4 == 1`) y en `Bytes.swift`: `Data.init(uint64BE:)`, `Data.init(uint16BE:)`, `Data.int64BE(_:)`,
  `constantTimeEquals(_:_:)`, `randomBytes(_ n: Int) -> Data` (`SystemRandomNumberGenerator`).

- [ ] **Step 4:** `swift run PRBarTests wire` → 2/2. **Commit** `"Add PRBarRemoteKit with base64url helpers and a portability check"`.

---

### Task 3: Noise (`Noise_KK` y `Noise_IKpsk2`, 25519/ChaChaPoly/SHA256) con vectores oficiales

**Files:**
- Create: `Sources/PRBarRemoteKit/Noise.swift`
- Test: `Sources/PRBarTests/NoiseTests.swift`, `Sources/PRBarTests/NoiseVectors.swift`

- [ ] **Step 1: Vectores.** Bajar el archivo de vectores de *cacophony*
  (`https://raw.githubusercontent.com/haskell-cryptography/cacophony/master/vectors/cacophony.txt`, JSON con
  `"vectors": [...]`) y extraer **solo** las entradas con `protocol_name` igual a `Noise_KK_25519_ChaChaPoly_SHA256` y
  `Noise_IKpsk2_25519_ChaChaPoly_SHA256` (si alguna no está ahí, usar el archivo de vectores de *snow*,
  `https://raw.githubusercontent.com/mcginty/snow/main/tests/vectors/snow.txt`, mismo formato). Pegar esas entradas como
  un literal `static let json = #"""…"""#` en `NoiseVectors.swift`, con un comentario con la URL y la fecha. Campos que se
  usan: `init_prologue`, `init_psks`, `init_static`, `init_ephemeral`, `init_remote_static`, `resp_*`, `handshake_hash`
  y `messages[] {payload, ciphertext}`.

- [ ] **Step 2: Tests que fallan.**

```swift
import CryptoKit
import Foundation
import PRBarRemoteKit

enum NoiseTests {
    struct Vector: Decodable { /* los campos de arriba, en hex */ }

    /// Corre un vector completo: handshake + mensajes de transporte, alternando iniciador/respondedor como el vector.
    static func run(_ v: Vector) throws {
        let pattern: NoisePattern = v.protocol_name.contains("_KK_") ? .kk : .ikpsk2
        var initiator = try NoiseHandshake(pattern: pattern, initiator: true, prologue: hex(v.init_prologue),
                                           localStatic: .init(rawRepresentation: hex(v.init_static)),
                                           remoteStatic: v.init_remote_static.map { try .init(rawRepresentation: hex($0)) },
                                           psk: v.init_psks.first.map(hex),
                                           fixedEphemeral: .init(rawRepresentation: hex(v.init_ephemeral)))
        var responder = /* idem con resp_* */
        var i = 0
        // Mensajes 0 y 1: handshake. Después: transporte con los CipherState que devuelve `split()`.
        // Para cada mensaje: el que escribe produce exactamente `ciphertext`; el que lee obtiene `payload`.
        // Al final del handshake, los dos `handshakeHash` son iguales a `handshake_hash`.
        _ = i
    }

    static let cases: [TestCase] = [
        TestCase("noise: vectores KK e IKpsk2") {
            let vectors = try NoiseVectors.load()
            try expect(vectors.contains { $0.protocol_name == "Noise_KK_25519_ChaChaPoly_SHA256" })
            try expect(vectors.contains { $0.protocol_name == "Noise_IKpsk2_25519_ChaChaPoly_SHA256" })
            for v in vectors { try run(v) }
        },
        TestCase("noise: un byte cambiado, un mensaje repetido o fuera de orden rompe la sesión") {
            let (a, b) = try NoiseTestPair.kk()          // handshake con claves al azar
            var sa = a, sb = b
            let m1 = try sa.send.encrypt(Data("uno".utf8))
            let m2 = try sa.send.encrypt(Data("dos".utf8))
            var bad = m1; bad[bad.startIndex] ^= 1
            try expect((try? sb.receive.decrypt(bad)) == nil)
            var sb2 = b
            try expectEqual(try sb2.receive.decrypt(m1), Data("uno".utf8))
            try expect((try? sb2.receive.decrypt(m1)) == nil)   // repetido
            var sb3 = b
            try expect((try? sb3.receive.decrypt(m2)) == nil)   // fuera de orden
        },
        TestCase("noise: KK con una estática remota distinta no completa") { /* el respondedor espera otra clave → error */ },
        TestCase("noise: IKpsk2 con otro psk no completa") { /* error al leer el mensaje 2 */ },
        TestCase("noise: mensaje de más de 65535 bytes rechazado") { /* encrypt de 65520 bytes de payload → error */ },
    ]
}
```

- [ ] **Step 3:** `swift build --product PRBarTests` → `cannot find 'NoiseHandshake'`.

- [ ] **Step 4: Implementar `Noise.swift`** siguiendo la especificación de Noise (rev. 34) al pie de la letra:
  - `CipherState`: clave de 32 bytes, `n: UInt64`; `encrypt(ad:plaintext:)` con `ChaChaPoly.seal` y nonce = 4 bytes
    cero ‖ `n` en **little endian** (8 bytes); `n == UInt64.max` → error. `decrypt` igual; un fallo **no** avanza `n`
    pero la sesión que lo usa se cierra (lo decide el que llama).
  - `SymmetricState`: `ck`, `h`; `InitializeSymmetric(protocolName)` (si ≤ 32 bytes, relleno con ceros; si no, SHA256),
    `MixKey` (HKDF de Noise con HMAC-SHA256: `temp = HMAC(ck, ikm)`, `out1 = HMAC(temp, 0x01)`, `out2 = HMAC(temp, out1 ‖
    0x02)`, `out3` para `MixKeyAndHash`), `MixHash`, `MixKeyAndHash` (para `psk`), `EncryptAndHash`, `DecryptAndHash`,
    `Split`.
  - `HandshakeState` con los dos patrones como tablas de tokens: KK pre-mensajes `-> s`, `<- s`; mensajes
    `-> e, es, ss` / `<- e, ee, se`. IKpsk2: pre-mensaje `<- s`; `-> e, es, s, ss` / `<- e, ee, se, psk`. Con `psk`
    presente, el token `e` también hace `MixKey(e.pub)` (regla de los modos psk).
  - DH = `Curve25519.KeyAgreement.PrivateKey.sharedSecretFromKeyAgreement` → `withUnsafeBytes` a `Data` (32 bytes).
  - `fixedEphemeral` solo para tests (parámetro `internal`/`@_spi(Testing)`; en producción, efímera al azar).
  - API pública: `NoiseHandshake(pattern:initiator:prologue:localStatic:remoteStatic:psk:)`,
    `writeMessage(payload:) throws -> Data`, `readMessage(_:) throws -> Data`, `isComplete`, `handshakeHash`,
    `remoteStaticKey`, `split() -> NoiseTransport {send: CipherState, receive: CipherState}` (orientado según el rol).

- [ ] **Step 5:** `swift run PRBarTests noise` → 5/5. **Commit** `"Implement Noise KK and IKpsk2 with the official test vectors"`.

---

### Task 4: HPKE auth para pushes y buzón (`Sealed.swift`) con vectores del RFC 9180

**Files:**
- Create: `Sources/PRBarRemoteKit/Sealed.swift`
- Test: `Sources/PRBarTests/SealedTests.swift`

- [ ] **Step 1: Tests que fallan.**
  - **Vector RFC 9180 A.2.3** (DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20Poly1305, modo **Auth**): copiar `info`,
    `skRm`, `pkSm`, `enc` y los primeros 3 `{aad, ct, pt}` de "Encryptions" (sequence 0, 1, 2) al test. Abrir con
    `HPKE.Recipient(privateKey:ciphersuite:info:encapsulatedKey:authenticatedBy:)` de CryptoKit y comparar `pt`.
  - Ida y vuelta: `SealedEnvelope.seal(PushPayload, from: macSealKey, to: devicePushKey.publicKey, info:)` →
    `open(…, by: devicePushKey, from: macSealKey.publicKey, info:)` igual.
  - Otro remitente (otra `macSealKey`) → falla. Otro `info` (otro `deviceId`) → falla. Byte cambiado → falla.
  - `PushPayload` con `title`/`body` largos: el sobre nunca supera 3 072 bytes de base64 (se corta `body` con "…" hasta
    entrar); el texto plano queda relleno a múltiplo de 256.
  - `MailboxBlob`: `{slot, rev, createdAt, data}`; `open` con `minimumRev` rechaza `rev` menor (`.rollback`).
  - `PushIdentifiers.collapse(kind:pr:)` y `.thread(pr:)`: determinísticos para el mismo par de claves, distintos para
    otro dispositivo, hex de 64 y 32 caracteres.

- [ ] **Step 2:** compilar → falta `SealedEnvelope`.

- [ ] **Step 3: Implementar.**

```swift
import CryptoKit
import Foundation

public enum SealedInfo {
    public static func push(account: String, device: String) -> Data { Data("PRBar push v1|\(account)|\(device)".utf8) }
    public static func mailbox(account: String, device: String, slot: String) -> Data {
        Data("PRBar mailbox v1|\(account)|\(device)|\(slot)".utf8)
    }
}

/// Sobre HPKE modo auth (RFC 9180): `enc ‖ ciphertext`. El remitente queda autenticado por su clave estática.
public enum SealedEnvelope {
    public static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    public static func seal(_ plaintext: Data, from sender: Curve25519.KeyAgreement.PrivateKey,
                            to recipient: Curve25519.KeyAgreement.PublicKey, info: Data) throws -> Data {
        var s = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info, authenticatedBy: sender)
        let ct = try s.seal(Padding.pad(plaintext, to: 256))
        return s.encapsulatedKey + ct           // enc mide 32 bytes con X25519
    }

    public static func open(_ envelope: Data, by recipient: Curve25519.KeyAgreement.PrivateKey,
                            from sender: Curve25519.KeyAgreement.PublicKey, info: Data) throws -> Data {
        guard envelope.count > 32 + 16 else { throw SealedError.malformed }
        var r = try HPKE.Recipient(privateKey: recipient, ciphersuite: suite, info: info,
                                   encapsulatedKey: envelope.prefix(32), authenticatedBy: sender)
        return try Padding.unpad(r.open(envelope.dropFirst(32)))
    }
}
```

  `Padding`: `len(u32 BE) ‖ datos ‖ ceros` hasta múltiplo de `block`. `PushPayload` (`Codable`: `v`, `id`, `createdAt`,
  `kind`, `title`, `body`, `threadId`, `pr?`, `deepLink`, `badge?`) con `sealedForAPNs(...)` que corta `body`.
  `PushIdentifiers` deriva `pushIdKey = HKDF<SHA256>(ikm: X25519(macSeal, devicePush), info: "PRBar push ids v1", 32)` y
  usa HMAC-SHA256.

- [ ] **Step 4:** `swift run PRBarTests sealed` → todo verde. **Commit** `"Seal push and mailbox payloads with HPKE auth mode"`.

---

### Task 5: SAS de 6 dígitos y QR de emparejamiento

**Files:**
- Create: `Sources/PRBarRemoteKit/SAS.swift`, `Sources/PRBarRemoteKit/PairingQR.swift`
- Test: `Sources/PRBarTests/SASTests.swift`, `Sources/PRBarTests/PairingQRTests.swift`

- [ ] **Step 1: Tests que fallan.**
  - `SAS.code(handshakeHash: Data(repeating: 0, count: 32))` y `Data(0..<32)`: los valores fijos que dé la primera
    corrida **verificados a mano** con `openssl kdf -keylen 4 -kdfopt digest:SHA256 -kdfopt key:<hex> -kdfopt
    info:"PRBar SAS v1" HKDF` (sal vacía) → `% 1_000_000`; anotar los dos vectores en el test. Siempre 6 dígitos
    (`"000042"`), formato `"000 042"`.
  - `PairingQR`: ida y vuelta de `prbar://pair?v=1&r=…&a=…&p=…&k=…&m=…&n=…`; nombre con espacios, emoji y `&`; rechaza
    `v` ≠ 1, esquema o host distinto de `pair`, `k`/`m` que no sean 32 bytes, `r` con esquema, puerto inválido o ruta,
    parámetros repetidos y URLs de más de 512 caracteres.

- [ ] **Step 2–3: Implementar.** `SAS.code` = `HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: hash),
  info: Data("PRBar SAS v1".utf8), outputByteCount: 4)` → `UInt32` big endian `% 1_000_000`. `PairingQR` con
  `URLComponents`; `relayHost` validado como hostname (letras, dígitos, `-`, `.`; opcional `:puerto` solo para tests con
  `allowInsecure`).

- [ ] **Step 4:** `swift run PRBarTests sas` y `swift run PRBarTests "pairing qr"` verdes. **Commit** `"Derive the pairing code and parse pairing QR links"`.

---

### Task 6: Atestación de presencia (Face ID)

**Files:**
- Create: `Sources/PRBarRemoteKit/Presence.swift`
- Test: `Sources/PRBarTests/PresenceTests.swift`

- [ ] **Step 1: Tests que fallan** (con un `SoftwarePresenceSigner` de P-256 en memoria; el del Secure Enclave es del Plan 19):
  - Bytes firmados exactos: `PresenceMessage.bytes(sessionHash:reqId:commandBytes:ts:)` =
    `"PRBarPresence v1"` ‖ 32 ‖ `u64 BE` ‖ `SHA256(cmd)` ‖ `i64 BE ms` (test con valores fijos, largo 16+32+8+32+8).
  - `PresenceVerifier.verify(proof, publicKey:, sessionHash:, reqId:, commandBytes:, now:)` acepta la buena; rechaza
    otra sesión, otro id, otro comando (un byte), `ts` a 61 s (pasado o futuro), otra clave, firma truncada.
  - `PresenceReplayGuard`: el mismo `(sessionHash, reqId)` dos veces → `.replayed`.

- [ ] **Step 2–3: Implementar.** `public protocol PresenceSigner { func sign(_ message: Data) async throws -> Data }`
  (DER), `PresenceProof {ts: Date, sig: Data}` (`Codable`, `sig` en base64url), `PresenceVerifier` con
  `P256.Signing.PublicKey(x963Representation:)` y `P256.Signing.ECDSASignature(derRepresentation:)`.

- [ ] **Step 4:** `swift run PRBarTests presence` verde. **Commit** `"Verify Face ID presence proofs bound to session, request and command"`.

---

### Task 7: Framing (trozos, relleno, compresión)

**Files:**
- Create: `Sources/PRBarRemoteKit/Framing.swift`
- Test: `Sources/PRBarTests/FramingTests.swift`

- [ ] **Step 1: Tests que fallan.**
  - `FrameChunker.chunks(for: data, compress:)` → cada trozo mide múltiplo de 256 y ≤ 65 280; `FrameAssembler` los
    rearma (0 bytes, 1 byte, 65 277, 65 278, 1 MiB al azar, 16 MiB exactos).
  - 16 MiB + 1 → `FramingError.tooLarge` al armar y al rearmar (sin guardar todo en memoria antes de fallar).
  - `compress: true` con 1 MiB de JSON repetitivo produce menos trozos y rearma igual; bit de compresión en todos los
    trozos del marco; un trozo con `len` mayor que lo que queda → `.malformed`; relleno no cero → `.malformed`.

- [ ] **Step 2–3: Implementar** con `import Compression` (macOS e iOS): `compression_stream` con `COMPRESSION_ZLIB`,
  comprimiendo de una vez y **descomprimiendo por partes** con salida acotada a 16 MiB (un marco comprimido malicioso
  no puede inflarse sin límite). No usar `NSData.decompressed(using:)`, que no tiene tope.

- [ ] **Step 4:** verde. **Commit** `"Split, pad and compress remote frames"`.

---

### Task 8: Marcos de aplicación y del relay

**Files:**
- Create: `Sources/PRBarRemoteKit/RemoteFrame.swift`, `Sources/PRBarRemoteKit/RelayMessages.swift`
- Test: agregar a `WireTests`.

- [ ] **Step 1: Tests que fallan.** JSON estable (claves ordenadas) para cada caso de `RemoteFrame` (`hello`, `req` con y
  sin `presence`, `res`, `sub`, `state`, `chatDelta`, `unpair`, `presencePolicy`, `bye`) y de `RelayMessage` (todos los
  `t` de P.4), con los literales esperados en el test (son el contrato con el relay en Go: la Task 11 copia los mismos
  literales a `relay/internal/hub/testdata/frames.json`). Un `t` desconocido decodifica como `.unknown(t)` (no falla).

- [ ] **Step 2–3: Implementar** con `enum … : Codable` y `CodingKeys` cortos (`t`, `b`, `sid`, …). `RemoteFrame.req`
  guarda `cmd` como `Data` (bytes JSON del `AppCommand`, base64 estándar en JSON) y expone `func command() throws ->
  AppCommand`.

- [ ] **Step 4:** verde. **Commit** `"Define the remote application frames and the relay messages"`.

---

### Task 9: `RemotePolicy`

**Files:**
- Create: `Sources/PRBarRemoteKit/RemotePolicy.swift`
- Test: `Sources/PRBarTests/RemotePolicyTests.swift`

- [ ] **Step 1: Tests que fallan.**

```swift
enum RemotePolicyTests {
    static let cases: [TestCase] = [
        TestCase("remote policy: la tabla del spec P.7") {
            let allowed: Set<AppCommand.Name> = [.status, .listPRs, .resolvePR, .history, .historyShow, .reviewShow,
                .respondShow, .respondDiff, .mergePreview, .chatShow, .resources, .usage, .ciList, .notifyList, .refresh,
                .reviewStart, .reviewEdit, .reviewSetIncluded, .reviewSetComment, .reviewCancel, .reviewDismiss,
                .respondStart, .respondSelect, .respondReset, .respondImplement, .respondTest, .respondReplyOnly,
                .respondCancel, .respondDismiss, .ciFix, .mergeDismiss, .chatSend, .chatUndo, .chatStop, .notifySet,
                .notifySetEnabled]
            let gated: Set<AppCommand.Name> = [.merge, .respondPush, .respondPushAnyway]
            for name in AppCommand.Name.allCases {
                let expected: RemotePolicy.Class = allowed.contains(name) ? .allowed : gated.contains(name) ? .gated
                    : name == .reviewPublish ? .dependsOnArguments : .denied
                try expectEqual(RemotePolicy.classify(name), expected)
            }
        },
        TestCase("remote policy: approve pide Face ID; comment y request changes no") {
            let approve = AppCommand.reviewPublish(pr: "a/b#1", event: .approve, only: nil, withComments: true,
                                                   allInBody: false, confirmed: true)
            try expectEqual(RemotePolicy.decide(approve), .gated)
            let comment = AppCommand.reviewPublish(pr: "a/b#1", event: .comment, only: nil, withComments: true,
                                                   allInBody: false, confirmed: true)
            try expectEqual(RemotePolicy.decide(comment), .allowed)
        },
    ]
}
```

  (El Plan 18 agrega los casos `remote*` y extiende el test: todos denegados salvo `remoteSetPresenceRequirement`, que es
  `.allowed` al prender y `.gated` al apagar.)

- [ ] **Step 2–3: Implementar** `RemotePolicy.classify(_ name: AppCommand.Name) -> Class` con un `switch` **exhaustivo
  sin `default`** y `decide(_ command: AppCommand) -> Decision` (`.allowed`, `.gated`, `.denied`) que resuelve los casos
  que dependen de argumentos. Mensajes: `RemotePolicy.deniedMessage = "This can’t be done from iPhone. Use PRBar on your
  Mac."`, `presenceRequiredMessage = "Face ID is required for this on iPhone."`.

- [ ] **Step 4:** verde. **Commit** `"Classify every AppCommand for remote use"`.

---

### Task 10: `RemoteHost` y `RemoteClient` sobre un relay en memoria

**Files:**
- Create: `Sources/PRBarRemoteKit/RelayTransport.swift`, `RemoteKeys.swift`, `RemoteHost.swift`, `RemoteClient.swift`
- Test: `Sources/PRBarTests/InMemoryRelay.swift`, `Sources/PRBarTests/RemoteEndToEndTests.swift`

- [ ] **Step 1: `RelayLink`** (protocolo): `connect() async throws -> RelayReady`, `send(_ RelayMessage) async throws`,
  `incoming: AsyncThrowingStream<RelayMessage, Error>`, `close(code:)`. `WebSocketRelayLink` lo implementa con
  `URLSessionWebSocketTask` (subprotocolo `prbar-relay.v1`, solo `wss://` salvo `allowInsecureTransportForTests`), hace
  el `challenge`/`auth` con un `RelayAuthenticator` (firma Ed25519 o `proof` de emparejamiento) y el `ping` cada 20 s.
  `InMemoryRelay` (tests) implementa la **misma semántica de P.4** a nivel de `RelayMessage`: cuentas, auth por firma,
  ruteo, presencia, `undeliverable`, buzón, ranuras, `device.add/remove` (cierra con 4403), pushes registrados en una lista.

- [ ] **Step 2: `RemoteKeys`**: `MacKeys {relay: Curve25519.Signing.PrivateKey, noise, seal}` y `DeviceKeys {relay, noise,
  push}` + `PairedMac {accountId, deviceId, relayHost, macName, macStatic, macSeal}` + `PairedDevice {deviceId, name,
  model, noise, push, presence (x963), pairedAt, requirePresence}`, todos `Codable` con `rawRepresentation` en base64url.
  Sin almacenamiento (eso es de cada app).

- [ ] **Step 3: Tests de punta a punta que fallan** (`RemoteEndToEndTests`), con `InMemoryRelay`, un `RemoteHost` con un
  `handler` falso (`(AppCommand, sink) async -> Result<JSONValue, CommandFailure>`) y un `RemoteClient`:
  1. **Emparejar**: `host.startPairing()` → QR; `client.pair(qr:)`; los dos ven el mismo SAS; `host.confirmPairing(true)`
     → el cliente recibe `PairedMac`, el host tiene `PairedDevice`, el relay tiene el dispositivo. Cancelar → el cliente
     recibe `.pairingCancelled`. QR vencido → `.pairingExpired`. Un segundo cliente en la ranura → rechazado y ranura
     quemada. `proof` equivocado 3 veces → ranura quemada.
  2. **Sesión**: `client.connect()` → KK → `hello` en los dos lados; `client.send(.status)` llega al handler y vuelve.
     Eventos `progress`/`text` del handler llegan en orden antes de la respuesta.
  3. **Política**: `client.send(.toolsSet(...))` → `.unauthorized` sin llamar al handler. `merge` sin presencia →
     `.unauthorized`; con `SoftwarePresenceSigner` correcto → llega; con firma de otra sesión → rechazado.
  4. **Tiempo**: un `req` con `sentAt` de hace 121 s (reloj inyectado) → `.invalidState` "This request expired. Try again."
  5. **Repetición**: el relay en memoria re-entrega un marco ya entregado → el host cierra la sesión; el cliente reconecta
     y sigue.
  6. **Revocar**: `host.revoke(deviceId)` → el cliente recibe 4403 → `.revoked`; un handshake KK forzado con la estática
     vieja (relay "malicioso" que no cerró) → el host lo rechaza.
  7. **Mac offline**: `host.disconnect()` → el cliente ve `.macOffline(since:)`; `send` falla con `.macOffline` sin colgar.
  8. **Estado**: `host.publish(topic: "home", data:)` solo a sesiones suscritas; `rev` crece; `sub` reemplaza el conjunto.
  9. **Buzón**: `host.putMailbox(slot: "home", data:)` → el cliente con `fetchMailbox()` lo abre; un blob con `rev` menor
     se ignora.
  10. **Push**: `host.push(PlannedPush, to:)` → el relay en memoria recibe `push` con `collapse`/`thread` opacos; abrir
      `b` con la clave del dispositivo da el payload.
  11. **Tamaño**: un resultado de 5 MiB vuelve entero (trozos).
  12. **Versión**: cliente con `commandProtocol` menor que `minimumRemoteVersion` → `.incompatible(.updateIPhone)`; mayor
      que el del host → `.incompatible(.updateMac)`.

- [ ] **Step 4: Implementar** `RemoteHost` (actor): conexión al relay con backoff inyectable, tabla `sid → Session`, una
  `Session` = transporte Noise + `FrameAssembler` + `PresenceReplayGuard` + último `reqId` + tópicos; despacha cada `req`:
  bytes → `RemotePolicy.decide` → (gated y `requirePresence`) `PresenceVerifier` → `handler`. Callbacks:
  `onPairingJoined(sas, deviceName, model)`, `onDevicesChanged`, `onStatusChanged`. `RemoteClient` (actor): emparejar,
  conectar, `send(_ command:, presence: PresenceSigner?) -> AsyncThrowingStream<CommandResponse>` (eventos + final),
  `subscribe`, `states`, `fetchMailbox`, `registerPushToken(_:env:)`, `unpair()`. Errores como `RemoteError` con textos
  de UI en inglés.

- [ ] **Step 5:** `swift run PRBarTests remote` → todo verde. **Commit** `"Add the remote host and client state machines with an in-memory relay"`.

---

### Task 11: Relay en Go — esqueleto, configuración, almacenamiento

**Files:** `relay/go.mod`, `relay/cmd/prbar-relay/main.go`, `relay/internal/config/config.go`,
`relay/internal/store/store.go` (+ `_test.go`), `relay/internal/logx/logx.go`

- [ ] **Step 1:** `cd relay && go mod init prbar-relay && go get github.com/coder/websocket@latest go.etcd.io/bbolt@latest`
  y fijar las versiones resultantes (quedan en `go.sum`).
- [ ] **Step 2: Tests que fallan** (`store_test.go`): cuentas (crear, tope `RELAY_MAX_ACCOUNTS`), dispositivos (alta, baja
  borra token y buzón), token de APNs, buzón (reemplazo por slot, tope 4 slots, 512 KiB, barrido de TTL con reloj
  inyectado), reabrir el archivo conserva todo.
- [ ] **Step 3: Implementar** `store` sobre bbolt (buckets `accounts`, `devices`, `mailbox`; valores JSON),
  `config.Load()` desde el entorno (`RELAY_LISTEN=:8080`, `RELAY_DATA=/data`, `RELAY_PUBLIC_HOST`, `RELAY_ENROLL_TOKEN`
  (≥ 32 caracteres o no arranca), `RELAY_MAX_ACCOUNTS=4`, `APNS_KEY_FILE=/run/secrets/apns.p8`, `APNS_KEY_ID`,
  `APNS_TEAM_ID`, `APNS_TOPIC`), `logx` con `log/slog` JSON y helpers `Prefix(id)` (4 caracteres) y `TokenTag(token)`
  (6 hex de SHA-256).
- [ ] **Step 4:** `go test ./internal/store/... && go vet ./... && test -z "$(gofmt -l .)"`. **Commit** `"Add the relay skeleton with bbolt storage"`.

### Task 12: Relay — auth, ruteo, presencia, emparejamiento, límites

**Files:** `relay/internal/auth`, `relay/internal/ratelimit`, `relay/internal/hub` (+ tests), `relay/internal/hub/testdata/frames.json`

- [ ] **Step 1: Tests que fallan** (`httptest.NewServer` + cliente de `coder/websocket`):
  - `frames.json` (copiado de la Task 8): cada marco se decodifica y se vuelve a codificar idéntico.
  - Inscripción: token bueno → cuenta; malo → 403; 5 malos de una IP → 429 durante 15 min (reloj inyectado).
  - Auth: firma Ed25519 buena entra; firma con otro host, otro nonce, otra clave, o sin `auth` en 5 s → 4401/4408.
    `proof` de emparejamiento con ranura abierta entra; tres malos queman la ranura.
  - Ruteo: teléfono → `mac` entrega `recv` con `from`; teléfono → otro teléfono rechazado; Mac offline → `undeliverable`;
    orden FIFO con 1 000 marcos; presencia al conectar/desconectar la Mac.
  - Reemplazo: el mismo dispositivo conecta dos veces → la primera cierra con 4409.
  - `device.remove` cierra al dispositivo con 4403 y su próxima auth falla.
  - Límites: marco de 128 KiB + 1 → 4413; 300 marcos en 1 s → 4429; 11 upgrades/min de una IP → 429.
  - Logs: con un `slog` a un buffer, enviar marcos con `b` = `"SECRETO-…"` y verificar que el buffer no lo contiene, ni
    el token de APNs.
- [ ] **Step 2: Implementar** `hub` (un `Hub` con mapa `account → {mac *Conn, devices map[id]*Conn, pairing *Slot}`;
  cada `Conn` con una goroutine de lectura y una de escritura con canal acotado (256); si se llena, se cierra con 4429),
  `auth` (desafío, verificación con `crypto/ed25519`, `hmac.Equal`), `ratelimit` (token bucket por conexión y por IP;
  IP real desde `X-Forwarded-For` **solo** si la conexión viene de la red de Docker de Traefik — confiar en el último
  salto). Rutas: `GET /healthz`, `POST /v1/accounts`, `GET /v1/ws`.
- [ ] **Step 3:** `go test ./...` verde. **Commit** `"Route encrypted frames with signed auth, presence and rate limits"`.

### Task 13: Relay — buzón y APNs

**Files:** `relay/internal/apns/apns.go` (+ test), cambios en `hub`.

- [ ] **Step 1: Tests que fallan.**
  - JWT: con una P-256 de prueba en PEM PKCS#8, el token tiene header `{"alg":"ES256","kid":…}`, claims `{"iss":team,
    "iat":…}`, firma verificable con la pública, y se reusa hasta 50 min (reloj inyectado).
  - Pedido: contra un `httptest.NewUnstartedServer` con `EnableHTTP2 = true` + `StartTLS`, `push` arma `POST
    /3/device/<token>` con los headers de P.9 y el cuerpo exacto (`aps.alert` genérico, `mutable-content: 1`,
    `thread-id`, `category: "PR"`, `e`, `v`); `410` → borra el token y responde `pushResult{status:410}`; 60 pushes/min
    por cuenta → el 61 responde `pushResult{status:429}` sin llamar a APNs.
  - `sandbox` vs `production` elige el host.
  - `mbox.put`/`mbox.get` por WebSocket.
- [ ] **Step 2: Implementar** con `crypto/ecdsa`, `crypto/x509` (`ParsePKCS8PrivateKey`), `net/http` (HTTP/2 automático
  con TLS) y un cliente con timeout de 10 s.
- [ ] **Step 3:** verde. **Commit** `"Send APNs pushes and keep the encrypted mailbox"`.

### Task 14: Imagen, compose y prueba de integración Swift ↔ Go

**Files:** `relay/Dockerfile`, `relay/deploy/docker-compose.yml`, `relay/deploy/prbar-relay.env.example`,
`relay/deploy/deploy.sh`, `relay/README.md`, `Sources/PRBarTests/RelayIntegrationTests.swift`

- [ ] **Step 1: Dockerfile.**

```dockerfile
FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o /out/prbar-relay ./cmd/prbar-relay \
 && mkdir -p /out/data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/prbar-relay /prbar-relay
COPY --from=build --chown=65532:65532 /out/data /data
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/prbar-relay"]
```

- [ ] **Step 2: Compose** (`relay/deploy/docker-compose.yml`, para `/root/stack/prbar-relay/`; convenciones del `LEEME.md`):

```yaml
services:
  prbar-relay:
    image: prbar-relay:vps
    container_name: prbar-relay
    restart: unless-stopped
    env_file: /root/stack/env/prbar-relay.env
    mem_limit: 128m
    read_only: true
    security_opt: ["no-new-privileges:true"]
    cap_drop: [ALL]
    secrets:
      - source: apns_p8
        target: /run/secrets/apns.p8
    volumes:
      - prbar-relay-data:/data
    networks: [coolify]
    labels:
      traefik.enable: "true"
      traefik.docker.network: coolify
      traefik.http.routers.prbar-relay.rule: Host(`prbar.fcharbonnier.duckdns.org`)
      traefik.http.routers.prbar-relay.entrypoints: https
      traefik.http.routers.prbar-relay.tls: "true"
      traefik.http.routers.prbar-relay.tls.certresolver: letsencrypt
      traefik.http.services.prbar-relay.loadbalancer.server.port: "8080"
      traefik.http.routers.prbar-relay-http.rule: Host(`prbar.fcharbonnier.duckdns.org`)
      traefik.http.routers.prbar-relay-http.entrypoints: http
      traefik.http.routers.prbar-relay-http.middlewares: redirect-https@file
secrets:
  apns_p8:
    file: /root/stack/env/prbar-relay.p8
volumes:
  prbar-relay-data:
networks:
  coolify:
    external: true
```

  `prbar-relay.env.example` con las variables (sin valores). `deploy.sh`: `rsync -a --delete --exclude .git ./relay/
  root@<vps>:/root/stack/prbar-relay/src/`, copia el compose, y `ssh … 'cd /root/stack/prbar-relay && docker build
  -t prbar-relay:vps src && docker compose up -d && docker image prune -f'`. **No se corre en esta task.**

- [ ] **Step 3: Build local de la imagen** (si Docker está corriendo): `docker build --platform linux/arm64 -t
  prbar-relay:test relay` → OK; `docker run --rm -e RELAY_ENROLL_TOKEN=$(openssl rand -hex 32) -e
  RELAY_PUBLIC_HOST=localhost -p 18080:8080 prbar-relay:test` y `curl -s localhost:18080/healthz` → `ok` (sin APNs el
  relay arranca con pushes apagados y lo loguea).

- [ ] **Step 4: Integración Swift ↔ Go** (`RelayIntegrationTests`): si `PRBAR_RELAY_BIN` está definido (binario de `go
  build ./cmd/prbar-relay` para macOS), lo lanza con datos en una carpeta temporal, `RELAY_LISTEN=127.0.0.1:<libre>`,
  APNs apuntando a un servidor falso (`APNS_ENDPOINT_OVERRIDE`, solo si `RELAY_TEST_MODE=1`), y corre los escenarios 1, 2,
  3, 6 y 10 de la Task 10 con `WebSocketRelayLink` real sobre `ws://`. Sin la variable, el test imprime "skipped" y pasa.
  Comando: `(cd relay && go build -o /tmp/prbar-relay ./cmd/prbar-relay) && PRBAR_RELAY_BIN=/tmp/prbar-relay swift run PRBarTests "relay integration"`.

- [ ] **Step 5: `relay/README.md`**: qué es, qué ve y qué no (P.13), variables, cómo testear, cómo desplegar (apunta a la
  Task 15 y al `LEEME.md` del server). **Commit** `"Package the relay as a distroless image with its compose file"`.

### Task 15: Despliegue en el VPS (**con compuerta: pedir OK al usuario antes de cada paso que toca el server**)

- [ ] **Step 1: Pedir OK** explícito al usuario, mostrando lo que se va a crear: `/root/stack/prbar-relay/`,
  `/root/stack/env/prbar-relay.env` y `.p8`, el contenedor `prbar-relay`, el volumen `prbar-relay-data`, y el host
  `prbar.fcharbonnier.duckdns.org`. Sin OK, el plan termina acá.
- [ ] **Step 2: Secretos** (el usuario pasa la `.p8` y el Key ID; el agente no los imprime):
  `scp AuthKey_XXXX.p8 root@<vps>:/root/stack/env/prbar-relay.p8` y en el server
  `chown 65532:65532 /root/stack/env/prbar-relay.p8 && chmod 400 /root/stack/env/prbar-relay.p8`. Crear
  `/root/stack/env/prbar-relay.env` (modo 600) con `RELAY_PUBLIC_HOST=prbar.fcharbonnier.duckdns.org`,
  `RELAY_ENROLL_TOKEN=$(openssl rand -hex 32)` (generado **en el server**; se le muestra al usuario una vez para el
  Plan 18), `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC=com.federico.prbar.ios`.
- [ ] **Step 3:** `free -h` (que queden > 300 MB), `relay/deploy/deploy.sh`, `curl -sI https://prbar.fcharbonnier.duckdns.org/healthz` → 200, `docker logs prbar-relay | tail`.
- [ ] **Step 4: Prueba de WebSocket largo** (spec V.2): desde la Mac, un cliente de prueba (`go run ./cmd/wsprobe` en
  `relay/`, que hace `challenge` y se queda 5 min inactivo con `ping` cada 20–25 s) por el entrypoint existente. Si
  aguanta los 5 min, listo. Si se corta (~60 s, el `readTimeout` de Traefik v3): **nunca** tocar los timeouts del
  entrypoint compartido. En su lugar, **con OK del usuario**: (a) agregar un entrypoint dedicado de Traefik solo para el
  router de PRBar (p. ej. `prbar` en `:8443`, `respondingTimeouts.readTimeout=0` o largo), mover a él el router
  `prbar-relay` y abrir ese puerto en el firewall del VPS; los clientes usan `host:8443` y mandan pings de aplicación
  cada 25 s; o (b) si (a) no se puede, que el relay termine TLS él mismo en su propio puerto publicado. Repetir la
  prueba de 5 min.
- [ ] **Step 5:** Agregar el relay al panel (`/root/stack/panel/config.json`, `"prbar-relay": {"nombre": "PRBar relay",
  "orden": 80}`) y una sección corta en `/root/stack/LEEME.md` ("Apps actuales" + secretos) — **solo con OK**.

### Task 16: Decisiones en el spec

- [ ] Agregar **P.14 Decisiones de implementación (Plan 17)** al spec: lista final de tipos movidos a `PRBarWire`,
  versiones fijadas de Go y dependencias, vectores usados (archivo y commit), valores de los vectores de SAS, y cualquier
  desvío. **Commit** `"Record the plan 17 implementation decisions in the spec"`.

---

## Verificación final

```
swift build --product PRBar && swift build --product PRBarCLI && swift build --product PRBarTests
swift run PRBarTests
(cd relay && go vet ./... && test -z "$(gofmt -l .)" && go test ./...)
(cd relay && go build -o /tmp/prbar-relay ./cmd/prbar-relay) && PRBAR_RELAY_BIN=/tmp/prbar-relay swift run PRBarTests "relay integration"
```
