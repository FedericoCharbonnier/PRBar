# PRBar — Plan 8: Actualizaciones desde el repo

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PRBar se actualiza solo desde los GitHub Releases de su repo público:
1. `Scripts/release.sh <X.Y.Z>` publica una versión (Info.plist, commit "Release vX.Y.Z", tag anotado, push y GitHub Release), con `--dry-run`;
2. la app chequea `releases/latest` sin token, avisa en el popover y con una notificación (una vez por versión), y deja saltear una versión;
3. al apretar **Update**, la app clona su propio repo en `~/Library/Application Support/PRBar/source`, verifica que el tag esté en `main`, compila con `Scripts/bundle.sh --output <staging>`, verifica el `.app`, lo reemplaza en forma atómica (con rollback) y se reinicia;
4. el binario responde `PRBar --version`.

**Spec:** `docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md`, parte D. Base: `docs/superpowers/specs/2026-11-18-prbar-design.md` (endurecimiento de git `GitHardening`, convenciones de procesos). **Fuera de este plan:** los comandos `prbar version` / `prbar update` de D.4 (son del Plan 7, CLI). Este plan deja listas las APIs de Core y de `AppModel` que esos comandos van a usar (ver Task 11).

**Architecture:**
- **Core (testeable):** `AppVersion` (versión corriendo y `--version`), `SemanticVersion`, `UpdateSettings` (config tolerante), `UpdateChecker` (GET `releases/latest` por `HTTPTransport`) + `UpdatePolicy` (decisiones puras: si toca chequear, qué se ofrece, si se notifica), `UpdateSource` (clon propio, `git` endurecido, tag alcanzable desde `origin/main`), `UpdateVerifier` + `AppReplacer` (verificación y reemplazo con rollback), `UpdateInstaller` (orquesta fuente → build → verificación → reemplazo, con eventos), `Relauncher` y `PendingUpdate` (reinicio y "Updated to X").
- **App:** `UpdateController` (`@MainActor ObservableObject`, lo crea `AppModel`): chequeo automático cada hora si pasó el intervalo, chequeo manual, espera/cancelación de trabajos, instalación, log y reinicio. UI: fila en el popover, sección **Updates** en Settings › General, ventana "Update PRBar" (y "PRBar Updated" al arrancar la versión nueva) y la notificación.
- **Scripts:** `bundle.sh --output <dir>` (arma sin instalar) y `release.sh [--dry-run] <X.Y.Z>`.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, UserNotifications, git, bash, `gh`, GitHub REST API (`/repos/{owner}/{repo}/releases/latest`).

**Base:** rama `feat/plan-8-updates` desde `main` (601 tests). Si el Plan 6 (chat) ya está en `main`, partir de ahí.

**Convenciones:**
- Todos los comandos corren desde la raíz del repo (`~/Documents/PRBar`).
- Tests: `swift run PRBarTests [filtro]` (runner propio; sale con código ≠ 0 si algo falla). `expect`/`expectEqual` toman autoclosures que **no** pueden tener `await`: primero se guarda en una variable local.
- Nunca llamar a GitHub de verdad desde los tests (`FakeTransport`), nunca correr el `bundle.sh` real ni reemplazar un `.app` fuera de una carpeta temporal. Los repos git reales de los tests son temporales.
- Commits en inglés, **sin** `Co-Authored-By` ni ninguna atribución a Claude/Anthropic (regla del usuario). Sin push. `release.sh` tampoco agrega trailers.
- UI en inglés. Comentarios de código en español, como el resto del repo.

## Decisiones (ambigüedades del spec resueltas)

- **Versión 0.1.0 → 1.0.0.** El código queda en `0.1.0`; la primera versión pública la crea `Scripts/release.sh 1.0.0` (Task 14, paso manual del usuario). `release.sh` es lo único que cambia la versión: `CFBundleShortVersionString` + `CFBundleVersion` (+1) en `Resources/Info.plist` y `PRBarCore.version`. Un test exige que `PRBarCore.version` coincida con el Info.plist.
- **Orden de `release.sh`:** chequeos → notas (se editan en `$EDITOR` **antes** de tocar nada; vacías = cancelar) → subir versión → `swift build` + `swift run PRBarTests` sobre la versión ya subida (si fallan, se revierte el cambio) → commit → tag → `git push --atomic` → `gh release create --verify-tag`. El spec pone build y tests antes de editar el plist; acá se corren después para probar exactamente lo que se publica.
- **`--dry-run`:** corre los chequeos (un chequeo que falla solo avisa y sigue), el build y los tests, muestra las notas y **lista** los pasos que cambian algo (plist, commit, tag, push, release) sin hacerlos. Una versión mal escrita o no mayor que la actual corta siempre (código 2).
- **`--version`:** imprime exactamente `PRBar X.Y.Z` y sale con 0. `UpdateVerifier` exige esa línea.
- **Saltear:** el chequeo automático no ofrece ni notifica la versión salteada; el chequeo **manual** sí la muestra (el usuario pidió mirar), sin notificar.
- **Notificación:** nuevo `NotificationKind.updateAvailable`, controlado solo por el interruptor general de notificaciones (sin toggle propio). `notifiedVersion` se marca solo si la notificación se planificó de verdad.
- **Errores del chequeo:** el automático los loguea y no los muestra; el manual los muestra en Settings. Un chequeo fallido no borra la versión ofrecida antes.
- **Frecuencia:** el switch "Check automatically" pone `checkIntervalHours` en 0 (apagado) o 24; el selector ofrece 6 h, 12 h, diario y semanal. `updates.repo` se edita solo en `config.json` (el pie de la sección lo muestra).
- **Trabajos corriendo:** "Update When Done" espera; "Cancel Jobs and Update" cancela reviews, análisis, implementaciones y tests, pero **nunca** una publicación/push en curso (`RespondQueue.cancel` ya no la toca): se espera a que termine. Justo antes de reemplazar el `.app` se vuelve a esperar por si arrancó algo durante el build.
- **Chats (Plan 6):** el Plan 6 todavía no está escrito. La Task 11 tiene un paso condicional para sumar los chats al conteo de trabajos si ya existen.
- **Dónde se arma:** staging en `~/Library/Application Support/PRBar/update-staging/<uuid>` (misma unidad que `~/Applications`, así el `moveItem` es un rename). Antes de compilar se verifica que la carpeta del `.app` instalado sea escribible.
- **"Updated to X":** antes de reiniciar se escribe `update-installed.json`; la versión nueva lo lee al arrancar, borra `PRBar.app.previous` y abre la ventana "PRBar Updated" con las notas.
- **Llavero:** como la firma es ad-hoc, la versión nueva puede pedir permiso al Llavero la primera vez (igual que hoy con `bundle.sh --install`). Los datos no se tocan.

---

## Estructura de archivos

```
Resources/Info.plist                       (sin cambios en este plan; lo cambia release.sh)
Scripts/
  bundle.sh                                (modificar) --output <dir>: arma sin instalar
  release.sh                               (nuevo) release con --dry-run
Sources/PRBarCore/
  AppVersion.swift                         (nuevo) versión corriendo, --version
  SemanticVersion.swift                    (nuevo) X.Y.Z[-pre], orden, Codable como string
  UpdateSettings.swift                     (nuevo) config "updates" tolerante
  Config.swift                             (modificar) AppConfig.updates
  UpdateChecker.swift                      (nuevo) ReleaseInfo + GET releases/latest
  UpdatePolicy.swift                       (nuevo) isCheckDue, offer, UpdateCheckOutcome/Report, UpdateChecker.check
  NotificationPlanner.swift                (modificar) .updateAvailable, PlannedNotification.updateVersion
  UpdateError.swift                        (nuevo) errores de instalación
  UpdateSource.swift                       (nuevo) clon propio + git endurecido + tag en main
  AppReplacer.swift                        (nuevo) UpdateVerifier + AppReplacer
  UpdateInstaller.swift                    (nuevo) UpdatePhase/Event/BusyPolicy + UpdateInstaller
  UpdateRelaunch.swift                     (nuevo) Relauncher + PendingUpdate
  Support.swift                            (modificar) AppPaths: source, staging, update.log, update-installed.json
Sources/PRBar/
  EntryPoint.swift                         (modificar) --version
  AppModel.swift                           (modificar) updateTransport, updates, arranque
  AppModel+Updates.swift                   (nuevo) API para UI y CLI, trabajos, ventana
  NotificationDelivery.swift               (modificar) click en la notificación de actualización
  Update/UpdateController.swift            (nuevo) chequeo, instalación, log
  Update/UpdateWindow.swift                (nuevo) ventana "Update PRBar" / "PRBar Updated"
  Popover/UpdateRow.swift                  (nuevo) fila al pie del popover
  Popover/PopoverView.swift                (modificar) agrega UpdateRow
  Settings/UpdatesSection.swift            (nuevo) sección Updates
  Settings/GeneralTab.swift                (modificar) agrega UpdatesSection
  Snapshots/SnapshotFixtures.swift         (modificar) release de ejemplo
  Snapshots/SnapshotMode.swift             (modificar) captura "update", General más alto
Sources/PRBarTests/
  TestKit.swift                            (modificar) repoRoot, InfoPlist
  SmokeTests.swift                         (modificar) versión = Info.plist
  AppVersionTests.swift                    (nuevo)
  SemanticVersionTests.swift               (nuevo)
  UpdateConfigTests.swift                  (nuevo)
  ScriptTests.swift                        (nuevo)
  UpdateCheckerTests.swift                 (nuevo) + helpers makeRelease/releaseJSON
  UpdatePolicyTests.swift                  (nuevo)
  UpdateSourceTests.swift                  (nuevo)
  UpdateInstallTests.swift                 (nuevo) verifier, replacer, installer, relaunch, marker
  main.swift                               (modificar) registra las suites
docs/qa/plan-8-checklist.md                (nuevo)
```

---

### Task 1: Versión de la app y `PRBar --version`

**Files:**
- Create: `Sources/PRBarCore/AppVersion.swift`, `Sources/PRBarTests/AppVersionTests.swift`
- Modify: `Sources/PRBar/EntryPoint.swift:7-20`, `Sources/PRBarTests/TestKit.swift` (al final), `Sources/PRBarTests/SmokeTests.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Agregar helpers de tests al final de `Sources/PRBarTests/TestKit.swift`**

```swift
/// Raíz del repo: este archivo está en `Sources/PRBarTests/`.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// `Resources/Info.plist` del repo.
enum InfoPlist {
    static func read() throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Resources/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw TestFailure(description: "Info.plist isn't a dictionary")
        }
        return plist
    }
}
```

- [ ] **Step 2: Reemplazar `Sources/PRBarTests/SmokeTests.swift`**

```swift
import PRBarCore

enum SmokeTests {
    static let cases: [TestCase] = [
        TestCase("smoke: la versión del core coincide con Info.plist") {
            // `Scripts/release.sh` cambia las dos a la vez; si alguien toca una sola, esto falla.
            let plist = try InfoPlist.read()
            try expectEqual(plist["CFBundleShortVersionString"] as? String, PRBarCore.version)
            let build = plist["CFBundleVersion"] as? String ?? ""
            try expect(!build.isEmpty && build.allSatisfy { $0.isASCII && $0.isNumber }, "CFBundleVersion: \(build)")
        },
    ]
}
```

- [ ] **Step 3: Escribir los tests en `Sources/PRBarTests/AppVersionTests.swift`**

```swift
import Foundation
import PRBarCore

enum AppVersionTests {
    static let cases: [TestCase] = [
        TestCase("version: lee CFBundleShortVersionString y CFBundleVersion del bundle") {
            let app = try temporaryDirectory().appendingPathComponent("Fake.app", isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "42",
                "CFBundleIdentifier": "com.example.fake", "CFBundlePackageType": "APPL",
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            guard let bundle = Bundle(url: app) else { throw TestFailure(description: "Bundle(url:) returned nil") }
            try expectEqual(AppVersion.current(bundle: bundle), "9.8.7")
            try expectEqual(AppVersion.build(bundle: bundle), "42")
        },
        TestCase("version: sin Info.plist usa PRBarCore.version") {
            guard let bundle = Bundle(url: try temporaryDirectory()) else { throw TestFailure(description: "no bundle") }
            try expectEqual(AppVersion.current(bundle: bundle), PRBarCore.version)
            try expectEqual(AppVersion.build(bundle: bundle), nil)
        },
        TestCase("version: --version se reconoce en cualquier posición después del ejecutable") {
            try expect(AppVersion.isVersionRequest(["/Applications/PRBar.app/Contents/MacOS/PRBar", "--version"]))
            try expect(AppVersion.isVersionRequest(["PRBar", "-psn_0_12345", "--version"]))
            try expect(!AppVersion.isVersionRequest(["PRBar"]))
            try expect(!AppVersion.isVersionRequest(["--version"]))
            try expect(!AppVersion.isVersionRequest(["PRBar", "--snapshots", "out"]))
        },
        TestCase("version: la línea de --version es 'PRBar X.Y.Z'") {
            try expectEqual(AppVersion.versionLine("1.3.0"), "PRBar 1.3.0")
        },
    ]
}
```

- [ ] **Step 4: Registrar la suite en `Sources/PRBarTests/main.swift`** — agregar `+ AppVersionTests.cases` después de `+ SnapshotOptionsTests.cases`.

- [ ] **Step 5: Correr y ver que falla**

Run: `swift run PRBarTests version`
Expected: error de compilación `cannot find 'AppVersion' in scope`.

- [ ] **Step 6: Crear `Sources/PRBarCore/AppVersion.swift`**

```swift
import Foundation

/// La versión de PRBar que está corriendo y el pedido `PRBar --version` (spec D.1, D.3 paso 4).
public enum AppVersion {
    /// `CFBundleShortVersionString` del bundle; sin bundle (`swift run`), `PRBarCore.version`.
    public static func current(bundle: Bundle = .main) -> String {
        guard let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !short.isEmpty else { return PRBarCore.version }
        return short
    }

    /// `CFBundleVersion` (número de build creciente); `nil` sin bundle.
    public static func build(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// `arguments[0]` es el ejecutable. macOS puede agregar argumentos propios (`-psn_…`), por eso se busca en todos.
    public static func isVersionRequest(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains("--version")
    }

    /// Lo que imprime `PRBar --version`. `UpdateVerifier` exige exactamente esta línea.
    public static func versionLine(_ version: String) -> String {
        "PRBar \(version)"
    }
}
```

- [ ] **Step 7: Responder `--version` en `Sources/PRBar/EntryPoint.swift`** — reemplazar el cuerpo de `main()`:

```swift
    @MainActor
    static func main() {
        // `PRBar --version`: imprime la versión y sale, sin abrir la app (lo usa el actualizador para verificar el
        // `.app` recién compilado).
        if AppVersion.isVersionRequest(CommandLine.arguments) {
            print(AppVersion.versionLine(AppVersion.current()))
            exit(0)
        }
        switch SnapshotOptions.parse(CommandLine.arguments) {
        case .none:
            PRBarApp.main()
        case .some(.success(let options)):
            SnapshotMode.run(options)
        case .some(.failure(let error)):
            FileHandle.standardError.write(Data("\(error.message)\n\(SnapshotOptions.usage)\n".utf8))
            exit(2)
        }
    }
```

Y actualizar el comentario de arriba del `enum EntryPoint`: "`PRBar --version` prints `PRBar X.Y.Z` and exits. `PRBar --snapshots <dir> …` renders … Any other launch is the menu bar app."

- [ ] **Step 8: Correr los tests**

Run: `swift run PRBarTests version` y después `swift run PRBarTests`
Expected: los 4 tests `version:` y `smoke:` con ✓; la suite completa termina en `N/N passed`.

- [ ] **Step 9: Probar el binario**

Run: `swift build --product PRBar && .build/debug/PRBar --version`
Expected: `PRBar 0.1.0` y código 0 (sin bundle usa `PRBarCore.version`).

- [ ] **Step 10: Commit**

```bash
git add Sources/PRBarCore/AppVersion.swift Sources/PRBar/EntryPoint.swift Sources/PRBarTests/TestKit.swift \
  Sources/PRBarTests/SmokeTests.swift Sources/PRBarTests/AppVersionTests.swift Sources/PRBarTests/main.swift
git commit -m "feat: answer --version and keep the core version in sync with Info.plist"
```

---

### Task 2: `SemanticVersion`

**Files:**
- Create: `Sources/PRBarCore/SemanticVersion.swift`, `Sources/PRBarTests/SemanticVersionTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests en `Sources/PRBarTests/SemanticVersionTests.swift`**

```swift
import Foundation
import PRBarCore

enum SemanticVersionTests {
    static let cases: [TestCase] = [
        TestCase("semver: parsea X.Y.Z con y sin v, con espacios y metadata de build") {
            try expectEqual(SemanticVersion("1.2.3"), SemanticVersion(1, 2, 3))
            try expectEqual(SemanticVersion("v1.2.3"), SemanticVersion(1, 2, 3))
            try expectEqual(SemanticVersion(" v10.0.12 \n"), SemanticVersion(10, 0, 12))
            try expectEqual(SemanticVersion("1.2.3+build.5"), SemanticVersion(1, 2, 3))
            try expectEqual(SemanticVersion(1, 2, 3).description, "1.2.3")
        },
        TestCase("semver: prerelease") {
            let beta = SemanticVersion("v2.0.0-beta.1")
            try expectEqual(beta?.prerelease, "beta.1")
            try expect(beta?.isPrerelease == true)
            try expectEqual(beta?.description, "2.0.0-beta.1")
            try expect(SemanticVersion("2.0.0")?.isPrerelease == false)
        },
        TestCase("semver: rechaza lo que no es X.Y.Z") {
            let invalid = ["", "v", "1", "1.2", "1.2.3.4", "1..3", "a.b.c", "1.2.x", "-1.2.3", "1.2.3-", "1.2.3-bé",
                           "nightly", "--upload-pack=x", "1.2.3456789012"]
            for text in invalid {
                try expect(SemanticVersion(text) == nil, "\"\(text)\" should be rejected")
            }
        },
        TestCase("semver: orden (números, prerelease antes que la final, prerelease numérico)") {
            let texts = ["0.1.0", "0.9.9", "1.0.0-alpha", "1.0.0-beta.2", "1.0.0-beta.10", "1.0.0", "1.0.1", "1.2.0",
                         "1.10.0", "2.0.0"]
            let ordered = texts.compactMap { SemanticVersion($0) }
            try expectEqual(ordered.count, texts.count)
            try expectEqual(ordered.shuffled().sorted(), ordered)
            try expect(SemanticVersion(1, 3, 0) > SemanticVersion(1, 2, 9))
            try expect(!(SemanticVersion(1, 3, 0) < SemanticVersion(1, 3, 0)))
        },
        TestCase("semver: JSON como string") {
            let data = try JSONCoding.encoder.encode([SemanticVersion(1, 3, 0)])
            try expectEqual(String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }, #"["1.3.0"]"#)
            let decoded = try JSONCoding.decoder.decode([SemanticVersion].self, from: Data(#"["v2.0.1"]"#.utf8))
            try expectEqual(decoded, [SemanticVersion(2, 0, 1)])
            let bad = try? JSONCoding.decoder.decode([SemanticVersion].self, from: Data(#"["latest"]"#.utf8))
            try expect(bad == nil)
        },
    ]
}
```

- [ ] **Step 2: Registrar** `+ SemanticVersionTests.cases` en `main.swift`.

- [ ] **Step 3: Correr y ver que falla**

Run: `swift run PRBarTests semver`
Expected: error de compilación `cannot find 'SemanticVersion' in scope`.

- [ ] **Step 4: Crear `Sources/PRBarCore/SemanticVersion.swift`**

```swift
import Foundation

/// Versión semántica `X.Y.Z` con `-prerelease` opcional, como la de `CFBundleShortVersionString` y la de los tags
/// `vX.Y.Z` de los releases (spec D.1). Se guarda en JSON como string.
public struct SemanticVersion: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Lo que va después del `-` (`beta.1`); `nil` en una versión final.
    public let prerelease: String?

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Acepta `1.2.3`, `v1.2.3` y `1.2.3-beta.1`; ignora la metadata de build (`+…`). `nil` si no son exactamente tres
    /// números (de hasta 9 dígitos) o si el prerelease tiene algo fuera de `[A-Za-z0-9.-]`.
    public init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        if let plus = text.firstIndex(of: "+") { text = text[..<plus] }
        var prerelease: String?
        if let dash = text.firstIndex(of: "-") {
            let suffix = text[text.index(after: dash)...]
            guard !suffix.isEmpty,
                  suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
            prerelease = String(suffix)
            text = text[..<dash]
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...9).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        self.init(numbers[0], numbers[1], numbers[2], prerelease: prerelease)
    }

    public var isPrerelease: Bool { prerelease != nil }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (left?, right?): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = SemanticVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a version: \(text)"))
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
```

- [ ] **Step 5: Correr los tests**

Run: `swift run PRBarTests semver`
Expected: 5 tests `semver:` con ✓, `5/5 passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCore/SemanticVersion.swift Sources/PRBarTests/SemanticVersionTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): add semantic versions for releases"
```

---

### Task 3: Configuración `updates`

**Files:**
- Create: `Sources/PRBarCore/UpdateSettings.swift`, `Sources/PRBarTests/UpdateConfigTests.swift`
- Modify: `Sources/PRBarCore/Config.swift:366-391` (`AppConfig`), `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests en `Sources/PRBarTests/UpdateConfigTests.swift`**

```swift
import Foundation
import PRBarCore

enum UpdateConfigTests {
    static let cases: [TestCase] = [
        TestCase("updates config: defaults") {
            let settings = AppConfig().updates
            try expectEqual(settings.repo, "FedericoCharbonnier/PRBar")
            try expectEqual(settings.checkIntervalHours, 24)
            try expect(settings.checksAutomatically)
            try expectEqual(settings.lastCheckAt, nil)
            try expectEqual(settings.notifiedVersion, nil)
            try expectEqual(settings.skippedVersion, nil)
        },
        TestCase("updates config: JSON sin 'updates' usa los defaults") {
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(#"{"refreshIntervalMinutes": 5}"#.utf8))
            try expectEqual(config.updates, UpdateSettings())
            try expectEqual(config.refreshIntervalMinutes, 5)
        },
        TestCase("updates config: parcial, tipos equivocados y negativos caen a los defaults") {
            let json = #"{"updates": {"repo": 7, "checkIntervalHours": -3, "skippedVersion": "1.3.0", "lastCheckAt": "ayer"}}"#
            let settings = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8)).updates
            try expectEqual(settings.repo, UpdateSettings.defaultRepo)
            try expectEqual(settings.checkIntervalHours, 0)
            try expectEqual(settings.skippedVersion, "1.3.0")
            try expectEqual(settings.lastCheckAt, nil)
        },
        TestCase("updates config: 'updates' que no es objeto no rompe el resto de la config") {
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(#"{"updates": "x", "launchAtLogin": true}"#.utf8))
            try expectEqual(config.updates, UpdateSettings())
            try expectEqual(config.launchAtLogin, true)
        },
        TestCase("updates config: round-trip") {
            var config = AppConfig()
            config.updates.repo = "acme/PRBar"
            config.updates.checkIntervalHours = 6
            config.updates.lastCheckAt = Date(timeIntervalSince1970: 1_800_000_000)
            config.updates.notifiedVersion = "1.3.0"
            config.updates.skippedVersion = "1.2.0"
            let data = try JSONCoding.encoder.encode(config)
            try expectEqual(try JSONCoding.decoder.decode(AppConfig.self, from: data), config)
        },
        TestCase("updates config: repo inválido → el default; válido → tal cual") {
            var settings = UpdateSettings()
            for bad in ["", "PRBar", "a/b/c", "../x", "acme/-x", "acme/.git", "ac me/x", "acme/"] {
                settings.repo = bad
                try expectEqual(settings.effectiveRepo, UpdateSettings.defaultRepo)
            }
            settings.repo = " acme-co/PRBar.fork_2 "
            try expectEqual(settings.effectiveRepo, "acme-co/PRBar.fork_2")
        },
        TestCase("updates config: switch de chequeo automático") {
            var settings = UpdateSettings()
            settings.checkIntervalHours = 6
            settings.setAutomaticChecks(true)
            try expectEqual(settings.checkIntervalHours, 6)
            settings.setAutomaticChecks(false)
            try expectEqual(settings.checkIntervalHours, 0)
            try expect(!settings.checksAutomatically)
            settings.setAutomaticChecks(true)
            try expectEqual(settings.checkIntervalHours, 24)
        },
    ]
}
```

- [ ] **Step 2: Registrar** `+ UpdateConfigTests.cases` en `main.swift`.

- [ ] **Step 3: Correr y ver que falla**

Run: `swift run PRBarTests "updates config"`
Expected: error de compilación `value of type 'AppConfig' has no member 'updates'`.

- [ ] **Step 4: Crear `Sources/PRBarCore/UpdateSettings.swift`**

```swift
import Foundation

/// Actualizaciones desde los GitHub Releases (spec D.2): `config.json` → `"updates"`.
public struct UpdateSettings: Hashable, Codable, Sendable {
    public static let defaultRepo = "FedericoCharbonnier/PRBar"
    public static let defaultCheckIntervalHours = 24
    /// Las opciones del selector de Settings › General (horas).
    public static let intervalChoices = [6, 12, 24, 168]

    /// `owner/name` del repo de donde salen los releases. Un fork lo cambia en `config.json`.
    public var repo = Self.defaultRepo
    /// Cada cuántas horas se chequea solo; 0 = solo a mano.
    public var checkIntervalHours = Self.defaultCheckIntervalHours
    /// Último chequeo que salió bien (automático o manual).
    public var lastCheckAt: Date?
    /// Última versión de la que se mandó notificación: se avisa una sola vez por versión.
    public var notifiedVersion: String?
    /// Versión que el usuario eligió saltear: no se vuelve a ofrecer sola hasta que salga otra.
    public var skippedVersion: String?

    public init() {}

    enum CodingKeys: String, CodingKey { case repo, checkIntervalHours, lastCheckAt, notifiedVersion, skippedVersion }

    /// Tolerante: una clave que falta o tiene otro tipo cae al default; un intervalo negativo es 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = (try? c.decodeIfPresent(String.self, forKey: .repo)) ?? Self.defaultRepo
        checkIntervalHours = max(0, (try? c.decodeIfPresent(Int.self, forKey: .checkIntervalHours)) ?? Self.defaultCheckIntervalHours)
        lastCheckAt = (try? c.decodeIfPresent(Date.self, forKey: .lastCheckAt)) ?? nil
        notifiedVersion = (try? c.decodeIfPresent(String.self, forKey: .notifiedVersion)) ?? nil
        skippedVersion = (try? c.decodeIfPresent(String.self, forKey: .skippedVersion)) ?? nil
    }

    public var checksAutomatically: Bool { checkIntervalHours > 0 }

    /// El switch "Check automatically": apagar es 0; prender vuelve a 24 h si estaba apagado.
    public mutating func setAutomaticChecks(_ on: Bool) {
        if !on {
            checkIntervalHours = 0
        } else if checkIntervalHours <= 0 {
            checkIntervalHours = Self.defaultCheckIntervalHours
        }
    }

    /// `repo` sin espacios alrededor si es un `owner/name` válido; si no, el default.
    public var effectiveRepo: String {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isValidRepo(trimmed) ? trimmed : Self.defaultRepo
    }

    /// Dos partes `[A-Za-z0-9._-]`, ninguna vacía ni empezando con `.` o `-` (va en una URL y en `git clone`).
    public static func isValidRepo(_ repo: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && !part.hasPrefix(".") && !part.hasPrefix("-") && part.allSatisfy { allowed.contains($0) }
        }
    }
}
```

- [ ] **Step 5: Agregar `updates` a `AppConfig` en `Sources/PRBarCore/Config.swift`**

En la lista de propiedades, después de `public var claude = ClaudeSettings()`:

```swift
    public var updates = UpdateSettings()
```

En `CodingKeys`:

```swift
    enum CodingKeys: String, CodingKey {
        case accounts, refreshIntervalMinutes, launchAtLogin, notifications, toolPaths, slack, claude, updates
    }
```

Al final de `init(from:)`, después de la línea de `claude`:

```swift
        updates = (try? c.decodeIfPresent(UpdateSettings.self, forKey: .updates)) ?? UpdateSettings()
```

- [ ] **Step 6: Correr los tests**

Run: `swift run PRBarTests config`
Expected: los 7 `updates config:` y los `config:` existentes con ✓.

- [ ] **Step 7: Commit**

```bash
git add Sources/PRBarCore/UpdateSettings.swift Sources/PRBarCore/Config.swift Sources/PRBarTests/UpdateConfigTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): add update settings to the config"
```

---

### Task 4: `bundle.sh --output <dir>`

**Files:**
- Modify: `Scripts/bundle.sh` (completo)
- Create: `Sources/PRBarTests/ScriptTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests en `Sources/PRBarTests/ScriptTests.swift`**

Solo prueban lo que corre **antes** de compilar (sintaxis y argumentos), así no hay `swift build` dentro de los tests.

```swift
import Foundation
import PRBarCore

enum ScriptTests {
    static func script(_ name: String) -> String { repoRoot.appendingPathComponent("Scripts/\(name)").path }

    static func bash(_ arguments: [String]) async throws -> ProcessResult {
        try await SystemProcessRunner().run("/bin/bash", arguments, environment: nil, currentDirectory: repoRoot, timeout: 30)
    }

    static let cases: [TestCase] = [
        TestCase("scripts: bundle.sh no tiene errores de sintaxis") {
            let result = try await bash(["-n", script("bundle.sh")])
            try expectEqual(result.status, 0)
        },
        TestCase("scripts: bundle.sh rechaza argumentos inválidos sin compilar") {
            for arguments in [["--bogus"], ["--output"], ["--output", ""], ["--install", "--output", "/tmp/x"]] {
                let result = try await bash([script("bundle.sh")] + arguments)
                try expectEqual(result.status, 2)
                try expect(result.stderr.contains("Usage: Scripts/bundle.sh"), "\(arguments): \(result.stderr)")
            }
        },
    ]
}
```

- [ ] **Step 2: Registrar** `+ ScriptTests.cases` en `main.swift`.

- [ ] **Step 3: Correr y ver que falla**

Run: `swift run PRBarTests scripts`
Expected: `✗ scripts: bundle.sh rechaza argumentos inválidos sin compilar` (hoy `--bogus` compila y sale con 0).

- [ ] **Step 4: Reemplazar `Scripts/bundle.sh`**

```bash
#!/bin/bash
# Compila en release y arma PRBar.app firmado ad-hoc.
# Uso: Scripts/bundle.sh [--install | --output <dir>]
#   (sin opciones)   arma build/PRBar.app
#   --install        además lo instala en ~/Applications y lo abre
#   --output <dir>   arma <dir>/PRBar.app y no instala ni cierra nada (lo usa el actualizador de PRBar)
set -euo pipefail

usage() {
    echo "Usage: Scripts/bundle.sh [--install | --output <dir>]" >&2
    exit 2
}

INSTALL=0
OUT_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)
            INSTALL=1
            shift
            ;;
        --output)
            [[ $# -ge 2 && -n "$2" ]] || usage
            OUT_DIR="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done
if [[ $INSTALL == 1 && -n "$OUT_DIR" ]]; then usage; fi

# Una carpeta relativa en --output es relativa a donde se llamó el script, no a la raíz del repo.
if [[ -n "$OUT_DIR" && "$OUT_DIR" != /* ]]; then OUT_DIR="$PWD/$OUT_DIR"; fi

cd "$(dirname "$0")/.."
OUT_DIR="${OUT_DIR:-build}"

swift build -c release --product PRBar
BIN="$(swift build -c release --show-bin-path)/PRBar"
APP="$OUT_DIR/PRBar.app"

mkdir -p "$OUT_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PRBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Bundle listo: $APP"

if [[ $INSTALL == 1 ]]; then
    pkill -x PRBar || true
    # Esperar (hasta ~5 s) a que el proceso viejo salga; si no, `open` falla con LSOpen -600.
    for _ in $(seq 1 50); do
        pgrep -x PRBar >/dev/null || break
        sleep 0.1
    done
    if pgrep -x PRBar >/dev/null; then
        echo "PRBar sigue corriendo; se fuerza el cierre." >&2
        pkill -9 -x PRBar || true
        sleep 0.5
    fi
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/PRBar.app"
    cp -R "$APP" "$HOME/Applications/PRBar.app"
    # LaunchServices a veces devuelve -600 justo después de reemplazar el bundle: reintentar.
    for attempt in 1 2 3 4 5; do
        if open "$HOME/Applications/PRBar.app" 2>/dev/null; then break; fi
        if [[ $attempt == 5 ]]; then echo "No se pudo abrir PRBar.app (LSOpen)." >&2; exit 1; fi
        sleep 1
    done
    echo "Instalado y abierto: ~/Applications/PRBar.app"
fi
```

- [ ] **Step 5: Correr los tests**

Run: `swift run PRBarTests scripts`
Expected: 2 tests `scripts:` con ✓.

- [ ] **Step 6: Probar el modo `--output` de verdad (no instala ni cierra la app que está corriendo)**

Run:
```bash
rm -rf "$TMPDIR/prbar-bundle-check"
Scripts/bundle.sh --output "$TMPDIR/prbar-bundle-check"
"$TMPDIR/prbar-bundle-check/PRBar.app/Contents/MacOS/PRBar" --version
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$TMPDIR/prbar-bundle-check/PRBar.app/Contents/Info.plist"
ls build/PRBar.app >/dev/null 2>&1 && echo "build/ intacto"
```
Expected: `Bundle listo: …/prbar-bundle-check/PRBar.app`, después `PRBar 0.1.0`, `0.1.0`. Una PRBar abierta sigue abierta.

Run: `(cd /tmp && /Users/federico/Documents/PRBar/Scripts/bundle.sh --output relative-check) && ls /tmp/relative-check/PRBar.app && rm -rf /tmp/relative-check "$TMPDIR/prbar-bundle-check"`
Expected: el `.app` queda en `/tmp/relative-check` (relativo al cwd de quien llama).

- [ ] **Step 7: Commit**

```bash
git add Scripts/bundle.sh Sources/PRBarTests/ScriptTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(scripts): let bundle.sh build into a folder without installing"
```

---

### Task 5: `Scripts/release.sh` con `--dry-run`

**Files:**
- Create: `Scripts/release.sh`
- Modify: `Sources/PRBarTests/ScriptTests.swift`

- [ ] **Step 1: Agregar los tests a `ScriptTests.cases`**

```swift
        TestCase("scripts: release.sh no tiene errores de sintaxis") {
            let result = try await bash(["-n", script("release.sh")])
            try expectEqual(result.status, 0)
        },
        TestCase("scripts: release.sh sin versión o con argumentos de más → uso (2)") {
            for arguments in [[String](), ["--dry-run"], ["--dry-run", "1.0.0", "1.0.1"], ["--bogus", "1.0.0"]] {
                let result = try await bash([script("release.sh")] + arguments)
                try expectEqual(result.status, 2)
                try expect(result.stderr.contains("Usage: Scripts/release.sh"), "\(arguments): \(result.stderr)")
            }
        },
        TestCase("scripts: release.sh rechaza una versión mal escrita (2)") {
            for version in ["banana", "1.2", "1.2.3-beta.1", "01.2.3"] {
                let result = try await bash([script("release.sh"), "--dry-run", version])
                try expectEqual(result.status, 2)
                try expect(result.stderr.contains("X.Y.Z"), "\(version): \(result.stderr)")
            }
        },
        TestCase("scripts: release.sh rechaza una versión que no es mayor que la actual (2)") {
            let result = try await bash([script("release.sh"), "--dry-run", "0.0.1"])
            try expectEqual(result.status, 2)
            try expect(result.stderr.contains("greater than the current version"), result.stderr)
        },
```

- [ ] **Step 2: Correr y ver que falla**

Run: `swift run PRBarTests "scripts: release"`
Expected: los 4 con ✗ (el script no existe: `bash -n` sale con 127 y los demás también).

- [ ] **Step 3: Crear `Scripts/release.sh`**

```bash
#!/bin/bash
# Publica una versión de PRBar (spec D.1):
#   1. chequea gh, la rama main limpia y al día con origin, y que el tag no exista;
#   2. arma las notas con los commits desde el tag anterior y las abre en $EDITOR (vacías = cancelar);
#   3. sube la versión (CFBundleShortVersionString, CFBundleVersion + 1 y PRBarCore.version);
#   4. corre `swift build` y `swift run PRBarTests` (si fallan, revierte el cambio de versión);
#   5. commitea "Release vX.Y.Z", crea el tag anotado vX.Y.Z, pushea los dos y crea el GitHub Release.
# Uso: Scripts/release.sh [--dry-run] <X.Y.Z>
#   --dry-run  corre los chequeos (los que fallan solo avisan), el build y los tests, muestra las notas y lista los
#              pasos que cambiarían algo (archivos, commit, tag, push, release) sin hacerlos.
set -euo pipefail

usage() {
    echo "Usage: Scripts/release.sh [--dry-run] <X.Y.Z>" >&2
    exit 2
}

DRY_RUN=0
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*) usage ;;
        *)
            [[ -z "$VERSION" ]] || usage
            VERSION="$arg"
            ;;
    esac
done
[[ -n "$VERSION" ]] || usage
VERSION="${VERSION#v}"
if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "release: the version must look like X.Y.Z (got \"$VERSION\")." >&2
    exit 2
fi

cd "$(dirname "$0")/.."
PLIST=Resources/Info.plist
CORE=Sources/PRBarCore/PRBarCore.swift
BRANCH=main
TAG="v$VERSION"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }

# 0 si $1 > $2 (los dos X.Y.Z).
version_gt() {
    local IFS=.
    local -a a=($1) b=($2)
    local i
    for i in 0 1 2; do
        if (( 10#${a[i]} > 10#${b[i]} )); then return 0; fi
        if (( 10#${a[i]} < 10#${b[i]} )); then return 1; fi
    done
    return 1
}

CURRENT="$(plist_get CFBundleShortVersionString)"
BUILD="$(plist_get CFBundleVersion)"
if ! version_gt "$VERSION" "$CURRENT"; then
    echo "release: $VERSION must be greater than the current version ($CURRENT)." >&2
    exit 2
fi
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "release: CFBundleVersion ($BUILD) isn't a number." >&2
    exit 1
fi
NEXT_BUILD=$((BUILD + 1))

step() { printf '\n==> %s\n' "$*"; }

# Lo que cambia algo (archivos, git, GitHub): en --dry-run solo se muestra.
run() {
    if (( DRY_RUN )); then
        printf '[dry-run] would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Un chequeo que no se cumple: corta la release; en --dry-run avisa y sigue, para ver el resto del plan.
fail() {
    if (( DRY_RUN )); then
        echo "[dry-run] a real release would stop here: $*" >&2
    else
        echo "release: $*" >&2
        exit 1
    fi
}

NOTES="$(mktemp -t prbar-release-notes)"
BUMPED=0
cleanup() {
    rm -f "$NOTES"
    if (( BUMPED )); then
        git checkout -- "$PLIST" "$CORE"
        echo "release: the version change was reverted; nothing was committed." >&2
    fi
}
trap cleanup EXIT

MODE=""
if (( DRY_RUN )); then MODE=" — dry run"; fi
step "PRBar $CURRENT → $VERSION (build $NEXT_BUILD)$MODE"

step "Checking tools"
for tool in git swift gh; do
    command -v "$tool" >/dev/null || fail "\`$tool\` isn't installed."
done
gh auth status --hostname github.com >/dev/null 2>&1 || fail "gh isn't signed in (run \`gh auth login\`)."
REPO="${PRBAR_RELEASE_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
[[ -n "$REPO" ]] || fail "couldn't tell the GitHub repo (set PRBAR_RELEASE_REPO=owner/name)."
echo "Repo: ${REPO:-unknown}"

step "Checking the working tree"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || fail "you're not on $BRANCH."
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has uncommitted changes."
git fetch --quiet --tags origin "$BRANCH" || fail "couldn't fetch origin."
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$BRANCH" 2>/dev/null)" ]] \
    || fail "$BRANCH isn't the same as origin/$BRANCH (pull or push first)."
if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then fail "the tag $TAG already exists."; fi
if [[ -n "$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null)" ]]; then fail "the tag $TAG already exists on origin."; fi

step "Release notes"
PREVIOUS="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)"
{
    echo "# Release notes for PRBar $VERSION (commits since ${PREVIOUS:-the beginning})."
    echo "# Lines starting with # are removed. Leave the file empty to cancel the release."
    git log --no-merges --reverse --pretty='- %s' ${PREVIOUS:+"$PREVIOUS..HEAD"}
} > "$NOTES"
if (( DRY_RUN )); then
    echo "[dry-run] these notes would open in your editor:"
    grep -v '^#' "$NOTES" || true
else
    ${VISUAL:-${EDITOR:-vi}} "$NOTES"
fi
sed -i '' '/^#/d' "$NOTES"
if ! grep -q '[^[:space:]]' "$NOTES"; then
    if (( DRY_RUN )); then
        echo "[dry-run] the notes are empty: a real release would stop here." >&2
    else
        echo "release: the notes are empty, nothing was released." >&2
        exit 1
    fi
fi

step "Setting the version to $VERSION (build $NEXT_BUILD)"
run /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
run /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" "$PLIST"
run sed -i '' -E "s/(static let version = \")[^\"]*(\")/\\1$VERSION\\2/" "$CORE"
if (( ! DRY_RUN )); then
    BUMPED=1
    grep -q "static let version = \"$VERSION\"" "$CORE" || fail "couldn't update $CORE."
fi

step "Building and testing"
swift build
swift run PRBarTests

step "Committing and tagging"
run git commit --quiet -m "Release $TAG" -- "$PLIST" "$CORE"
BUMPED=0
run git tag -a "$TAG" -m "PRBar $VERSION"

step "Pushing $BRANCH and $TAG"
if ! run git push --atomic origin "$BRANCH" "$TAG"; then
    echo "release: the push failed. The commit and the tag are only local: fix the problem and run" >&2
    echo "  git push --atomic origin $BRANCH $TAG && gh release create $TAG --title \"PRBar $VERSION\" --verify-tag" >&2
    exit 1
fi

step "Creating the GitHub release"
run gh release create "$TAG" --repo "$REPO" --title "PRBar $VERSION" --notes-file "$NOTES" --verify-tag

echo
if (( DRY_RUN )); then
    echo "Dry run finished: nothing was changed, committed or pushed."
else
    echo "Released PRBar $VERSION: https://github.com/$REPO/releases/tag/$TAG"
fi
```

Run: `chmod +x Scripts/release.sh`

- [ ] **Step 4: Correr los tests**

Run: `swift run PRBarTests scripts`
Expected: 6 tests `scripts:` con ✓.

- [ ] **Step 5: Probar el `--dry-run` completo (no cambia nada)**

Run: `Scripts/release.sh --dry-run 1.0.0; git status --porcelain; git tag --list 'v*'`
Expected:
- las secciones `==> Checking tools`, `==> Checking the working tree`, `==> Release notes` (con la lista de commits), `==> Setting the version…` con tres líneas `[dry-run] would run: …PlistBuddy…/sed…`, el build y la suite (`N/N passed`), y `[dry-run] would run: git commit …`, `git tag -a v1.0.0 …`, `git push --atomic origin main v1.0.0`, `gh release create v1.0.0 …`;
- si la rama no está limpia (estamos en la rama del plan), aparece `[dry-run] a real release would stop here: you're not on main.` y sigue;
- al final `Dry run finished: nothing was changed, committed or pushed.`;
- `git status --porcelain` vacío salvo los cambios propios de la tarea; no hay tags nuevos.

- [ ] **Step 6: Commit**

```bash
git add Scripts/release.sh Sources/PRBarTests/ScriptTests.swift
git commit -m "feat(scripts): add a release script with a dry-run mode"
```

---

### Task 6: `ReleaseInfo` y `UpdateChecker` (GET `releases/latest`)

**Files:**
- Create: `Sources/PRBarCore/UpdateChecker.swift`, `Sources/PRBarTests/UpdateCheckerTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests en `Sources/PRBarTests/UpdateCheckerTests.swift`** (con helpers que usan también las Tasks 7–10)

```swift
import Foundation
import PRBarCore

/// Un release como los que devuelve `UpdateChecker`.
func makeRelease(_ version: String, notes: String = "- Faster refresh") -> ReleaseInfo {
    ReleaseInfo(
        version: SemanticVersion(version)!, tag: "v\(version)", title: "PRBar \(version)", notes: notes,
        url: URL(string: "https://github.com/FedericoCharbonnier/PRBar/releases/tag/v\(version)")!, publishedAt: nil
    )
}

/// El JSON de `GET /repos/{repo}/releases/latest` (solo los campos que se leen).
func releaseJSON(
    tag: String = "v1.3.0", draft: Bool = false, prerelease: Bool = false,
    body: String = #"## What's new\n\n- Faster refresh\n- Chat with Claude"#
) -> String {
    #"""
    {"tag_name": "\#(tag)", "name": "PRBar \#(tag)", "body": "\#(body)", "draft": \#(draft), "prerelease": \#(prerelease),
     "html_url": "https://github.com/FedericoCharbonnier/PRBar/releases/tag/\#(tag)", "published_at": "2026-11-20T10:00:00Z"}
    """#
}

/// Transporte que falla como sin red.
struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

enum UpdateCheckerTests {
    static let cases: [TestCase] = [
        TestCase("update checker: lee el último release sin token") {
            let transport = FakeTransport([(200, [:], releaseJSON())])
            let checker = UpdateChecker(transport: transport, repo: "FedericoCharbonnier/PRBar")
            let release = try await checker.latestRelease()
            try expectEqual(release, ReleaseInfo(
                version: SemanticVersion(1, 3, 0), tag: "v1.3.0", title: "PRBar v1.3.0",
                notes: "## What's new\n\n- Faster refresh\n- Chat with Claude",
                url: URL(string: "https://github.com/FedericoCharbonnier/PRBar/releases/tag/v1.3.0")!,
                publishedAt: ISO8601DateFormatter().date(from: "2026-11-20T10:00:00Z")
            ))
            let request = transport.requests[0]
            try expectEqual(request.url?.absoluteString, "https://api.github.com/repos/FedericoCharbonnier/PRBar/releases/latest")
            try expectEqual(request.httpMethod, "GET")
            try expectEqual(request.value(forHTTPHeaderField: "Authorization"), nil)
            try expectEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            try expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("PRBar/") == true)
        },
        TestCase("update checker: el repo de un fork va en la URL") {
            let transport = FakeTransport([(200, [:], releaseJSON())])
            _ = try await UpdateChecker(transport: transport, repo: "acme/PRBar-fork").latestRelease()
            try expectEqual(transport.requests[0].url?.absoluteString, "https://api.github.com/repos/acme/PRBar-fork/releases/latest")
        },
        TestCase("update checker: sin releases (404) → nil") {
            let checker = UpdateChecker(transport: FakeTransport([(404, [:], #"{"message":"Not Found"}"#)]), repo: "a/b")
            let release = try await checker.latestRelease()
            try expectEqual(release, nil)
        },
        TestCase("update checker: ignora drafts, prereleases y tags que no son versión") {
            let bodies = [releaseJSON(draft: true), releaseJSON(prerelease: true), releaseJSON(tag: "v2.0.0-beta.1"),
                          releaseJSON(tag: "nightly")]
            for body in bodies {
                let release = try await UpdateChecker(transport: FakeTransport([(200, [:], body)]), repo: "a/b").latestRelease()
                try expectEqual(release, nil)
            }
        },
        TestCase("update checker: sin título ni notas usa 'PRBar X.Y.Z' y notas vacías") {
            let body = #"{"tag_name": "v1.4.0", "name": "", "body": null, "draft": false, "prerelease": false, "html_url": "https://github.com/a/b/releases/tag/v1.4.0"}"#
            let release = try await UpdateChecker(transport: FakeTransport([(200, [:], body)]), repo: "a/b").latestRelease()
            try expectEqual(release?.title, "PRBar 1.4.0")
            try expectEqual(release?.notes, "")
            try expectEqual(release?.publishedAt, nil)
        },
        TestCase("update checker: errores HTTP, límite y red") {
            let server = try await expectThrows {
                _ = try await UpdateChecker(transport: FakeTransport([(500, [:], #"{"message":"boom"}"#)]), repo: "a/b").latestRelease()
            }
            try expectEqual(server as? PRBarError, .http(status: 500, message: "boom"))
            let limited = try await expectThrows {
                _ = try await UpdateChecker(transport: FakeTransport([
                    (403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"], #"{"message":"rate limit"}"#),
                ]), repo: "a/b").latestRelease()
            }
            try expectEqual(limited as? PRBarError, .rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_000)))
            let offline = try await expectThrows {
                _ = try await UpdateChecker(transport: OfflineTransport(), repo: "a/b").latestRelease()
            }
            guard case .network? = offline as? PRBarError else { throw TestFailure(description: "expected .network, got \(offline)") }
            let garbage = try await expectThrows {
                _ = try await UpdateChecker(transport: FakeTransport([(200, [:], "<html>")]), repo: "a/b").latestRelease()
            }
            guard case .invalidResponse? = garbage as? PRBarError else { throw TestFailure(description: "got \(garbage)") }
        },
        TestCase("update checker: resumen de las notas para la notificación") {
            try expectEqual(makeRelease("1.3.0", notes: "## What's new\n\n- Faster refresh\n- Chat").summary, "Faster refresh")
            try expectEqual(makeRelease("1.3.0", notes: "  * Fixed the badge  ").summary, "Fixed the badge")
            try expectEqual(makeRelease("1.3.0", notes: "# Only a heading\n\n").summary, nil)
            let long = makeRelease("1.3.0", notes: String(repeating: "a", count: 200)).summary ?? ""
            try expectEqual(long.count, 120)
            try expect(long.hasSuffix("…"))
        },
    ]
}
```

- [ ] **Step 2: Registrar** `+ UpdateCheckerTests.cases` en `main.swift`.

- [ ] **Step 3: Correr y ver que falla**

Run: `swift run PRBarTests "update checker"`
Expected: error de compilación `cannot find type 'ReleaseInfo' in scope`.

- [ ] **Step 4: Crear `Sources/PRBarCore/UpdateChecker.swift`**

```swift
import Foundation

/// Un release publicado de PRBar (spec D.2).
public struct ReleaseInfo: Codable, Equatable, Sendable {
    public var version: SemanticVersion
    /// El tag tal cual está en GitHub (`v1.3.0`): es lo que se descarga y compila.
    public var tag: String
    public var title: String
    /// Notas del release (Markdown).
    public var notes: String
    public var url: URL
    public var publishedAt: Date?

    public init(version: SemanticVersion, tag: String, title: String, notes: String, url: URL, publishedAt: Date?) {
        self.version = version
        self.tag = tag
        self.title = title
        self.notes = notes
        self.url = url
        self.publishedAt = publishedAt
    }

    /// La primera línea con texto de las notas que no es un título, sin la viñeta (`-`, `*`, `+`), de hasta 120
    /// caracteres. Es el cuerpo de la notificación.
    public var summary: String? {
        for raw in notes.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            guard !line.isEmpty else { continue }
            return line.count > 120 ? String(line.prefix(119)) + "…" : line
        }
        return nil
    }
}

/// Pregunta a GitHub cuál es el último release de PRBar: `GET /repos/{repo}/releases/latest`, sin token (el repo es
/// público). Ignora drafts, prereleases y tags que no son `vX.Y.Z`.
public struct UpdateChecker: Sendable {
    public static let timeout: TimeInterval = 15

    private let transport: HTTPTransport
    private let repo: String

    /// `repo`: `owner/name` ya validado (`UpdateSettings.effectiveRepo`).
    public init(transport: HTTPTransport, repo: String) {
        self.transport = transport
        self.repo = repo
    }

    public static func latestURL(repo: String) -> URL {
        URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    /// `nil` si el repo no tiene releases (404) o si el último no se puede instalar (draft, prerelease, tag raro).
    public func latestRelease() async throws -> ReleaseInfo? {
        var request = URLRequest(url: Self.latestURL(repo: repo), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PRBar/\(AppVersion.current())", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as PRBarError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PRBarError.network(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            break
        case 404:
            return nil
        case 403, 429:
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
               let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) {
                throw PRBarError.rateLimited(resetAt: Date(timeIntervalSince1970: reset))
            }
            throw PRBarError.http(status: response.statusCode, message: Self.message(from: data))
        default:
            throw PRBarError.http(status: response.statusCode, message: Self.message(from: data))
        }

        let release: GitHubRelease
        do {
            release = try JSONCoding.decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw PRBarError.invalidResponse("latest release: \(error.localizedDescription)")
        }
        guard !release.draft, !release.prerelease,
              let version = SemanticVersion(release.tagName), !version.isPrerelease else { return nil }
        let name = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ReleaseInfo(
            version: version, tag: release.tagName, title: name.isEmpty ? "PRBar \(version)" : name,
            notes: release.body ?? "", url: release.htmlURL, publishedAt: release.publishedAt
        )
    }

    private static func message(from data: Data) -> String {
        struct Body: Decodable { let message: String? }
        return (try? JSONDecoder().decode(Body.self, from: data))?.message ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", name, body, htmlURL = "html_url", draft, prerelease, publishedAt = "published_at"
        }
    }
}
```

- [ ] **Step 5: Correr los tests**

Run: `swift run PRBarTests "update checker"`
Expected: 7 tests con ✓.

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCore/UpdateChecker.swift Sources/PRBarTests/UpdateCheckerTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): fetch the latest PRBar release from GitHub"
```

---

### Task 7: Política de chequeo, reporte y notificación

**Files:**
- Create: `Sources/PRBarCore/UpdatePolicy.swift`, `Sources/PRBarTests/UpdatePolicyTests.swift`
- Modify: `Sources/PRBarCore/NotificationPlanner.swift` (`NotificationKind`, `PlannedNotification`, `isOn`, `title`, `groupTitle`, nueva función), `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests en `Sources/PRBarTests/UpdatePolicyTests.swift`**

```swift
import Foundation
import PRBarCore

enum UpdatePolicyTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func check(
        installed: String = "1.2.0", settings: UpdateSettings = UpdateSettings(),
        notifications: NotificationSettings = NotificationSettings(), manual: Bool = false,
        transport: HTTPTransport = FakeTransport([(200, [:], releaseJSON(tag: "v1.3.0"))])
    ) async -> UpdateCheckReport {
        await UpdateChecker(transport: transport, repo: "a/b").check(
            installed: SemanticVersion(installed)!, settings: settings, notifications: notifications, manual: manual, now: now
        )
    }

    static let cases: [TestCase] = [
        TestCase("update policy: toca chequear según el intervalo") {
            var settings = UpdateSettings()
            try expect(UpdatePolicy.isCheckDue(settings, now: now))
            settings.lastCheckAt = now.addingTimeInterval(-23 * 3600)
            try expect(!UpdatePolicy.isCheckDue(settings, now: now))
            settings.lastCheckAt = now.addingTimeInterval(-24 * 3600)
            try expect(UpdatePolicy.isCheckDue(settings, now: now))
            settings.lastCheckAt = now.addingTimeInterval(3600)   // el reloj volvió para atrás
            try expect(UpdatePolicy.isCheckDue(settings, now: now))
            settings.checkIntervalHours = 0
            settings.lastCheckAt = nil
            try expect(!UpdatePolicy.isCheckDue(settings, now: now))
        },
        TestCase("update policy: versión nueva → se ofrece y se notifica una vez") {
            let report = await check()
            let release = report.offered
            try expectEqual(release?.version, SemanticVersion(1, 3, 0))
            guard case .available(let available) = report.outcome else { throw TestFailure(description: "\(report.outcome)") }
            try expectEqual(available.tag, "v1.3.0")
            try expectEqual(report.notification?.title, "PRBar 1.3.0 is available")
            try expectEqual(report.notification?.body, "Faster refresh")
            try expectEqual(report.notification?.updateVersion, "1.3.0")
            try expectEqual(report.settings.notifiedVersion, "1.3.0")
            try expectEqual(report.settings.lastCheckAt, now)
            try expectEqual(report.visibleError, nil)
        },
        TestCase("update policy: misma versión o más vieja → al día") {
            for installed in ["1.3.0", "1.4.0"] {
                let report = await check(installed: installed)
                try expectEqual(report.outcome, .upToDate(installed: SemanticVersion(installed)!))
                try expectEqual(report.offered, nil)
                try expectEqual(report.notification, nil)
                try expectEqual(report.settings.lastCheckAt, now)
            }
        },
        TestCase("update policy: sin releases → al día") {
            let report = await check(transport: FakeTransport([(404, [:], "{}")]))
            try expectEqual(report.outcome, .upToDate(installed: SemanticVersion(1, 2, 0)))
            try expectEqual(report.offered, nil)
        },
        TestCase("update policy: versión salteada → no se ofrece sola; a mano sí, sin notificar") {
            var settings = UpdateSettings()
            settings.skippedVersion = "1.3.0"
            let automatic = await check(settings: settings)
            guard case .available = automatic.outcome else { throw TestFailure(description: "\(automatic.outcome)") }
            try expectEqual(automatic.offered, nil)
            try expectEqual(automatic.notification, nil)
            try expectEqual(automatic.settings.notifiedVersion, nil)
            let manual = await check(settings: settings, manual: true)
            try expectEqual(manual.offered?.version, SemanticVersion(1, 3, 0))
            try expectEqual(manual.notification, nil)
        },
        TestCase("update policy: salteada una vieja, sale otra → se ofrece") {
            var settings = UpdateSettings()
            settings.skippedVersion = "v1.2.5"
            let report = await check(settings: settings)
            try expectEqual(report.offered?.version, SemanticVersion(1, 3, 0))
            try expect(report.notification != nil)
        },
        TestCase("update policy: ya notificada → se ofrece sin volver a notificar") {
            var settings = UpdateSettings()
            settings.notifiedVersion = "1.3.0"
            let report = await check(settings: settings)
            try expectEqual(report.offered?.version, SemanticVersion(1, 3, 0))
            try expectEqual(report.notification, nil)
        },
        TestCase("update policy: chequeo manual → no notifica") {
            let report = await check(manual: true)
            try expectEqual(report.offered?.version, SemanticVersion(1, 3, 0))
            try expectEqual(report.notification, nil)
            try expectEqual(report.settings.notifiedVersion, nil)
        },
        TestCase("update policy: notificaciones apagadas → no notifica ni marca notificada") {
            var notifications = NotificationSettings()
            notifications.enabled = false
            let report = await check(notifications: notifications)
            try expectEqual(report.offered?.version, SemanticVersion(1, 3, 0))
            try expectEqual(report.notification, nil)
            try expectEqual(report.settings.notifiedVersion, nil)
        },
        TestCase("update policy: error de red silencioso en el automático, visible en el manual") {
            let automatic = await check(transport: OfflineTransport())
            guard case .failed(let message) = automatic.outcome else { throw TestFailure(description: "\(automatic.outcome)") }
            try expect(message.hasPrefix("Couldn't check for updates"), message)
            try expectEqual(automatic.visibleError, nil)
            try expectEqual(automatic.offered, nil)
            try expectEqual(automatic.settings, UpdateSettings())
            let manual = await check(manual: true, transport: OfflineTransport())
            try expectEqual(manual.visibleError, message)
        },
        TestCase("update policy: la notificación de actualización") {
            let planned = NotificationPlanner.updateAvailable(makeRelease("1.3.0", notes: "# Title"), settings: NotificationSettings())
            try expectEqual(planned?.kind, .updateAvailable)
            try expectEqual(planned?.body, "Open PRBar to update.")
            try expectEqual(planned?.identifier, "updateAvailable:1.3.0:group")
            try expectEqual(planned?.url, nil)
            var off = NotificationSettings()
            off.enabled = false
            try expect(NotificationPlanner.updateAvailable(makeRelease("1.3.0"), settings: off) == nil)
        },
    ]
}
```

- [ ] **Step 2: Registrar** `+ UpdatePolicyTests.cases` en `main.swift`.

- [ ] **Step 3: Correr y ver que falla**

Run: `swift run PRBarTests "update policy"`
Expected: error de compilación `cannot find 'UpdatePolicy' in scope`.

- [ ] **Step 4: Notificaciones en `Sources/PRBarCore/NotificationPlanner.swift`**

`NotificationKind`:

```swift
public enum NotificationKind: String, Codable, Sendable, CaseIterable {
    case newToReview, reviewedPRUpdated, myPRFeedback, reviewFinished, myPRApprovedOrCIFailed
    /// Hay una versión nueva de PRBar (spec D.2). Solo depende del interruptor general.
    case updateAvailable
}
```

En `PlannedNotification`, después de `public let prID: String?`:

```swift
    /// Versión nueva de PRBar: el click abre la ventana "Update PRBar".
    public let updateVersion: String?
```

y el `init` pasa a:

```swift
    public init(
        kind: NotificationKind, title: String, body: String, url: URL?, reviewPRID: String? = nil,
        reviewRecordID: UUID? = nil, respondPRID: String? = nil, prID: String? = nil, event: String? = nil,
        updateVersion: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.url = url
        self.reviewPRID = reviewPRID
        self.reviewRecordID = reviewRecordID
        self.respondPRID = respondPRID
        self.prID = prID ?? reviewPRID ?? respondPRID
        self.updateVersion = updateVersion
        identifier = [kind.rawValue, event, self.prID ?? "group"].compactMap { $0 }.joined(separator: ":")
    }
```

En `NotificationSettings.isOn`, agregar el caso:

```swift
        case .updateAvailable: return true
```

En `title(for:)`: `case .updateAvailable: "PRBar Update Available"`. En `groupTitle(for:count:)`: `case .updateAvailable: "\(count) PRBar updates available"` (nunca se agrupan; el `switch` tiene que ser exhaustivo).

Al final del archivo:

```swift
extension NotificationPlanner {
    /// "PRBar 1.3.0 is available" con la primera línea de las notas (spec D.2). `nil` con las notificaciones apagadas.
    public static func updateAvailable(_ release: ReleaseInfo, settings: NotificationSettings) -> PlannedNotification? {
        guard settings.isOn(.updateAvailable) else { return nil }
        let version = release.version.description
        return PlannedNotification(
            kind: .updateAvailable, title: "PRBar \(version) is available", body: release.summary ?? "Open PRBar to update.",
            url: nil, event: version, updateVersion: version
        )
    }
}
```

- [ ] **Step 5: Crear `Sources/PRBarCore/UpdatePolicy.swift`**

```swift
import Foundation

/// Resultado de un chequeo, tal como lo ven la UI y la CLI (`prbar update --check`, Plan 7).
public enum UpdateCheckOutcome: Codable, Equatable, Sendable {
    case upToDate(installed: SemanticVersion)
    /// Hay una versión mayor que la instalada (aunque esté salteada).
    case available(ReleaseInfo)
    case failed(String)
}

/// Todo lo que deja un chequeo: qué mostrar, qué notificar y qué guardar en la config.
public struct UpdateCheckReport: Equatable, Sendable {
    public var outcome: UpdateCheckOutcome
    /// La versión que se ofrece en el popover y Settings (`nil` = ninguna). Si el chequeo falló es `nil` y la UI
    /// conserva lo que ofrecía antes.
    public var offered: ReleaseInfo?
    public var notification: PlannedNotification?
    /// Error para mostrar: solo en el chequeo manual (el automático solo lo loguea).
    public var visibleError: String?
    /// `lastCheckAt` y `notifiedVersion` actualizados.
    public var settings: UpdateSettings
}

/// Decisiones puras del chequeo de actualizaciones (spec D.2).
public enum UpdatePolicy {
    /// Chequeo automático: si está prendido y pasó el intervalo (o nunca se chequeó, o el reloj volvió para atrás).
    public static func isCheckDue(_ settings: UpdateSettings, now: Date) -> Bool {
        guard settings.checksAutomatically else { return false }
        guard let last = settings.lastCheckAt, last <= now else { return true }
        return now.timeIntervalSince(last) >= TimeInterval(settings.checkIntervalHours) * 3600
    }

    /// La versión a ofrecer: mayor que la instalada y, salvo en el chequeo manual, no salteada.
    public static func offer(latest: ReleaseInfo?, installed: SemanticVersion, settings: UpdateSettings, manual: Bool) -> ReleaseInfo? {
        guard let latest, latest.version > installed else { return nil }
        if !manual, let skipped = settings.skippedVersion.flatMap({ SemanticVersion($0) }), skipped == latest.version {
            return nil
        }
        return latest
    }
}

extension UpdateChecker {
    /// Chequea y decide. Nunca lanza: un error vuelve como `.failed` (y en `visibleError` si es manual).
    public func check(
        installed: SemanticVersion, settings: UpdateSettings, notifications: NotificationSettings, manual: Bool, now: Date
    ) async -> UpdateCheckReport {
        var next = settings
        do {
            let latest = try await latestRelease()
            next.lastCheckAt = now
            let outcome: UpdateCheckOutcome
            if let latest, latest.version > installed {
                outcome = .available(latest)
            } else {
                outcome = .upToDate(installed: installed)
            }
            let offered = UpdatePolicy.offer(latest: latest, installed: installed, settings: settings, manual: manual)
            var notification: PlannedNotification?
            if !manual, let offered, settings.notifiedVersion.flatMap({ SemanticVersion($0) }) != offered.version,
               let planned = NotificationPlanner.updateAvailable(offered, settings: notifications) {
                notification = planned
                next.notifiedVersion = offered.version.description
            }
            return UpdateCheckReport(outcome: outcome, offered: offered, notification: notification, visibleError: nil, settings: next)
        } catch {
            let message = "Couldn't check for updates: \(error.localizedDescription)"
            AppLog.write(message)
            return UpdateCheckReport(outcome: .failed(message), offered: nil, notification: nil,
                                     visibleError: manual ? message : nil, settings: next)
        }
    }
}
```

- [ ] **Step 6: Correr los tests**

Run: `swift run PRBarTests "update policy"` y `swift run PRBarTests notification`
Expected: 11 `update policy:` con ✓ y los de `NotificationPlannerTests` siguen con ✓.

- [ ] **Step 7: Commit**

```bash
git add Sources/PRBarCore/UpdatePolicy.swift Sources/PRBarCore/NotificationPlanner.swift Sources/PRBarTests/UpdatePolicyTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): decide when to check, offer and notify about updates"
```

---

### Task 8: Errores de instalación y `UpdateSource` (clon propio con git endurecido)

**Files:**
- Create: `Sources/PRBarCore/UpdateError.swift`, `Sources/PRBarCore/UpdateSource.swift`, `Sources/PRBarTests/UpdateSourceTests.swift`
- Modify: `Sources/PRBarCore/Support.swift` (`AppPaths`), `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests en `Sources/PRBarTests/UpdateSourceTests.swift`**

```swift
import Foundation
import PRBarCore

enum UpdateSourceTests {
    static let sha = String(repeating: "c", count: 40)

    /// git falso: `rev-parse` devuelve `sha` (o `revParseStatus`), `merge-base` sale con `mergeBaseStatus`.
    static func fakeGit(revParseStatus: Int32 = 0, mergeBaseStatus: Int32 = 0) -> FakeProcessRunner {
        FakeProcessRunner { _, arguments in
            if arguments.contains("rev-parse") {
                return ProcessResult(status: revParseStatus, stdout: revParseStatus == 0 ? sha + "\n" : "", stderr: "")
            }
            if arguments.contains("merge-base") { return ProcessResult(status: mergeBaseStatus, stdout: "", stderr: "") }
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
    }

    static let cases: [TestCase] = [
        TestCase("update source: primera vez clona sin checkout; todos los git endurecidos") {
            let dir = try temporaryDirectory().appendingPathComponent("source", isDirectory: true)
            let runner = fakeGit()
            let source = UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: dir,
                                      remoteURL: UpdateSource.remoteURL(forRepo: "acme/PRBar"))
            let result = try await source.checkout(tag: "v1.3.0")
            try expectEqual(result, sha)
            let h = GitHardening.arguments
            try expectEqual(runner.calls.map(\.arguments), [
                h + ["clone", "--no-checkout", "--quiet", "https://github.com/acme/PRBar.git", dir.path],
                h + ["-C", dir.path, "fetch", "--quiet", "--tags", "--force", "--prune", "origin"],
                h + ["-C", dir.path, "rev-parse", "--verify", "--quiet", "refs/tags/v1.3.0^{commit}"],
                h + ["-C", dir.path, "merge-base", "--is-ancestor", sha, "refs/remotes/origin/main"],
                h + ["-C", dir.path, "checkout", "--quiet", "--force", "--detach", sha],
                h + ["-C", dir.path, "clean", "-ffdq"],
            ])
            try expect(runner.calls.allSatisfy { $0.executable == "/usr/bin/git" })
            try expect(runner.calls.allSatisfy { $0.environment == GitHardening.environment })
        },
        TestCase("update source: con clon existente actualiza la URL de origin en vez de clonar") {
            let dir = try temporaryDirectory().appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let runner = fakeGit()
            let source = UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: dir, remoteURL: "https://github.com/acme/fork.git")
            _ = try await source.checkout(tag: "v1.3.0")
            try expectEqual(runner.calls.first?.arguments,
                            GitHardening.arguments + ["-C", dir.path, "remote", "set-url", "origin", "https://github.com/acme/fork.git"])
            try expect(!runner.calls.contains { $0.arguments.contains("clone") })
        },
        TestCase("update source: tag inexistente → tagMissing, sin checkout") {
            let runner = fakeGit(revParseStatus: 1)
            let source = UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: try temporaryDirectory().appendingPathComponent("s"),
                                      remoteURL: "https://github.com/a/b.git")
            let error = try await expectThrows { _ = try await source.checkout(tag: "v9.9.9") }
            try expectEqual(error as? UpdateError, .tagMissing("v9.9.9"))
            try expect(!runner.calls.contains { $0.arguments.contains("checkout") })
        },
        TestCase("update source: tag no alcanzable desde origin/main → tagNotOnMain, sin checkout") {
            let runner = fakeGit(mergeBaseStatus: 1)
            let source = UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: try temporaryDirectory().appendingPathComponent("s"),
                                      remoteURL: "https://github.com/a/b.git")
            let error = try await expectThrows { _ = try await source.checkout(tag: "v1.3.0") }
            try expectEqual(error as? UpdateError, .tagNotOnMain("v1.3.0"))
            try expect(!runner.calls.contains { $0.arguments.contains("checkout") })
        },
        TestCase("update source: un tag que no es versión no llega a git") {
            let runner = fakeGit()
            let source = UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: try temporaryDirectory().appendingPathComponent("s"),
                                      remoteURL: "https://github.com/a/b.git")
            for tag in ["--upload-pack=touch /tmp/x", "main", "v1.3"] {
                let error = try await expectThrows { _ = try await source.checkout(tag: tag) }
                try expectEqual(error as? UpdateError, .invalidTag(tag))
            }
            try expectEqual(runner.calls.count, 0)
        },
        TestCase("update source: git real — tag en main sí, tag en otra rama no") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let origin = base.appendingPathComponent("origin", isDirectory: true)
            try TempGitRepo.run(base, ["init", "-q", "-b", "main", origin.path])
            try Data("1\n".utf8).write(to: origin.appendingPathComponent("VERSION"))
            try TempGitRepo.run(origin, ["add", "-A"])
            try TempGitRepo.run(origin, ["commit", "-q", "-m", "one"])
            try TempGitRepo.run(origin, ["tag", "-a", "v1.0.0", "-m", "1.0.0"])
            let mainSHA = try TempGitRepo.run(origin, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try TempGitRepo.run(origin, ["checkout", "-q", "-b", "side"])
            try Data("9\n".utf8).write(to: origin.appendingPathComponent("VERSION"))
            try TempGitRepo.run(origin, ["commit", "-q", "-am", "side"])
            try TempGitRepo.run(origin, ["tag", "-a", "v9.0.0", "-m", "9.0.0"])
            try TempGitRepo.run(origin, ["checkout", "-q", "main"])

            let source = UpdateSource(runner: SystemProcessRunner(), gitPath: TempGitRepo.git,
                                      directory: base.appendingPathComponent("source", isDirectory: true), remoteURL: origin.path)
            let sha = try await source.checkout(tag: "v1.0.0")
            try expectEqual(sha, mainSHA)
            let version = try String(contentsOf: source.directory.appendingPathComponent("VERSION"), encoding: .utf8)
            try expectEqual(version, "1\n")

            let error = try await expectThrows { _ = try await source.checkout(tag: "v9.0.0") }
            try expectEqual(error as? UpdateError, .tagNotOnMain("v9.0.0"))
            // El clon se reusa y sigue en el tag bueno.
            let again = try await source.checkout(tag: "v1.0.0")
            try expectEqual(again, mainSHA)
        },
    ]
}
```

- [ ] **Step 2: Registrar** `+ UpdateSourceTests.cases` en `main.swift`.

- [ ] **Step 3: Correr y ver que falla**

Run: `swift run PRBarTests "update source"`
Expected: error de compilación `cannot find 'UpdateSource' in scope`.

- [ ] **Step 4: Crear `Sources/PRBarCore/UpdateError.swift`**

```swift
import Foundation

/// Por qué no se pudo instalar una actualización (spec D.3). Si pasa cualquiera de estos, el `.app` instalado
/// queda como estaba (salvo `relaunchFailed`, que llega cuando la versión nueva ya está instalada).
public enum UpdateError: Error, Equatable, Sendable, LocalizedError {
    case notInstalledAsApp
    case alreadyInstalling
    case notWritable(String)
    case invalidTag(String)
    case tagMissing(String)
    case tagNotOnMain(String)
    case buildFailed(status: Int32)
    case appMissing(String)
    case versionMismatch(expected: String, found: String)
    case bundleIdentifierMismatch(expected: String, found: String)
    case launchCheckFailed(String)
    /// El texto ya dice qué pasó y en qué estado quedó la app.
    case replaceFailed(String)
    case relaunchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalledAsApp:
            "Updates need PRBar.app. Install it with Scripts/bundle.sh --install."
        case .alreadyInstalling:
            "An update is already being installed."
        case .notWritable(let folder):
            "PRBar can't replace itself in \(folder). Move PRBar.app to ~/Applications and try again."
        case .invalidTag(let tag):
            "The release tag \"\(tag)\" isn't a version."
        case .tagMissing(let tag):
            "The tag \(tag) isn't in the repository."
        case .tagNotOnMain(let tag):
            "The tag \(tag) isn't on the main branch, so PRBar won't install it."
        case .buildFailed(let status):
            "The build failed (code \(status)). Show Log has the details."
        case .appMissing(let path):
            "The build didn't produce a usable PRBar.app (\(path))."
        case .versionMismatch(let expected, let found):
            "The new app says it's version \(found.isEmpty ? "unknown" : found), not \(expected)."
        case .bundleIdentifierMismatch(let expected, let found):
            "The new app's bundle identifier is \(found.isEmpty ? "missing" : found), not \(expected)."
        case .launchCheckFailed(let detail):
            "The new app didn't start correctly (\(detail))."
        case .replaceFailed(let message):
            message
        case .relaunchFailed(let version):
            "PRBar \(version) is installed. Quit PRBar and open it again to finish."
        }
    }
}
```

- [ ] **Step 5: Agregar a `AppPaths` en `Sources/PRBarCore/Support.swift`** (después de `historyDir`)

```swift
    /// Clon propio del repo de PRBar del que se compilan las actualizaciones (spec D.3). Nunca es el checkout de
    /// desarrollo del usuario.
    public static var updateSourceDir: URL { appSupport.appendingPathComponent("source", isDirectory: true) }
```

- [ ] **Step 6: Crear `Sources/PRBarCore/UpdateSource.swift`**

```swift
import Foundation

/// El clon propio del repo de PRBar del que se compilan las actualizaciones (spec D.3, paso 2). Se crea con
/// `git clone --no-checkout` la primera vez y después se reusa. Todos los `git` llevan `GitHardening` (sin hooks,
/// sin fsmonitor, sin submódulos, sin pedir credenciales).
public struct UpdateSource: Sendable {
    /// Para `clone` y `fetch`.
    public static let fetchTimeout: TimeInterval = 300
    /// El tag tiene que ser alcanzable desde acá.
    public static let mainRef = "refs/remotes/origin/main"

    public let directory: URL
    public let remoteURL: String
    private let runner: ProcessRunning
    private let gitPath: String

    public init(runner: ProcessRunning, gitPath: String, directory: URL = AppPaths.updateSourceDir, remoteURL: String) {
        self.runner = runner
        self.gitPath = gitPath
        self.directory = directory
        self.remoteURL = remoteURL
    }

    /// `owner/name` (ya validado con `UpdateSettings.effectiveRepo`) → URL https del repo.
    public static func remoteURL(forRepo repo: String) -> String { "https://github.com/\(repo).git" }

    /// Deja `directory` en el commit del tag, detached y sin archivos de más (los ignorados, como `.build`, quedan
    /// para que el build sea incremental). Devuelve el sha. Rechaza un tag que no es versión, que no existe o cuyo
    /// commit no es alcanzable desde `origin/main`.
    @discardableResult
    public func checkout(tag: String) async throws -> String {
        guard !tag.hasPrefix("-"), SemanticVersion(tag) != nil else { throw UpdateError.invalidTag(tag) }
        let fileManager = FileManager.default
        let path = directory.path
        if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            // El repo pudo cambiar en la config (un fork).
            try await git(["-C", path, "remote", "set-url", "origin", remoteURL])
        } else {
            // Un clon a medio hacer de un intento anterior.
            try? fileManager.removeItem(at: directory)
            try fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await git(["clone", "--no-checkout", "--quiet", remoteURL, path], timeout: Self.fetchTimeout)
        }
        try await git(["-C", path, "fetch", "--quiet", "--tags", "--force", "--prune", "origin"], timeout: Self.fetchTimeout)

        let resolved = try await run(["-C", path, "rev-parse", "--verify", "--quiet", "refs/tags/\(tag)^{commit}"])
        guard resolved.status == 0, let sha = CommitSHA.parse(resolved.stdout) else { throw UpdateError.tagMissing(tag) }

        let reachable = try await run(["-C", path, "merge-base", "--is-ancestor", sha, Self.mainRef])
        switch reachable.status {
        case 0: break
        case 1: throw UpdateError.tagNotOnMain(tag)
        default: throw Self.failure(["merge-base", "--is-ancestor", sha, Self.mainRef], reachable)
        }

        // Se hace checkout del sha verificado, no del tag: un fetch en el medio no puede cambiar lo que se compila.
        try await git(["-C", path, "checkout", "--quiet", "--force", "--detach", sha], timeout: Self.fetchTimeout)
        try await git(["-C", path, "clean", "-ffdq"])
        return sha
    }

    private func run(_ arguments: [String], timeout: TimeInterval = ProcessTimeouts.standard) async throws -> ProcessResult {
        try await runner.run(gitPath, GitHardening.arguments + arguments, environment: GitHardening.environment,
                             currentDirectory: nil, timeout: timeout)
    }

    @discardableResult
    private func git(_ arguments: [String], timeout: TimeInterval = ProcessTimeouts.standard) async throws -> String {
        let result = try await run(arguments, timeout: timeout)
        guard result.status == 0 else { throw Self.failure(arguments, result) }
        return result.stdout
    }

    private static func failure(_ arguments: [String], _ result: ProcessResult) -> PRBarError {
        .commandFailed(command: (["git"] + arguments).joined(separator: " "), status: result.status,
                       stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
```

- [ ] **Step 7: Correr los tests**

Run: `swift run PRBarTests "update source"`
Expected: 6 tests con ✓ (el de git real tarda ~1 s).

- [ ] **Step 8: Commit**

```bash
git add Sources/PRBarCore/UpdateError.swift Sources/PRBarCore/UpdateSource.swift Sources/PRBarCore/Support.swift \
  Sources/PRBarTests/UpdateSourceTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): check out release tags from a private hardened clone"
```

---

### Task 9: Verificación del `.app` y reemplazo atómico con rollback

**Files:**
- Create: `Sources/PRBarCore/AppReplacer.swift`, `Sources/PRBarTests/UpdateInstallTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests en `Sources/PRBarTests/UpdateInstallTests.swift`**

```swift
import Foundation
import PRBarCore

/// Un `.app` mínimo: Info.plist, un ejecutable que imprime `PRBar <version>` y `Contents/marker.txt` para saber cuál es.
func makeFakeApp(at app: URL, version: String, identifier: String = "com.federico.prbar", marker: String) throws {
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": identifier, "CFBundleExecutable": "PRBar"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let executable = macOS.appendingPathComponent("PRBar")
    try Data("#!/bin/sh\necho \"PRBar \(version)\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try Data(marker.utf8).write(to: contents.appendingPathComponent("marker.txt"))
}

func marker(of app: URL) -> String? {
    try? String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
}

enum UpdateInstallTests {
    static let cases: [TestCase] = verifierCases + replacerCases

    static let verifierCases: [TestCase] = [
        TestCase("update verifier: versión, bundle id y --version correctos") {
            let app = try temporaryDirectory().appendingPathComponent("PRBar.app", isDirectory: true)
            try makeFakeApp(at: app, version: "1.3.0", marker: "new")
            try await UpdateVerifier.verify(app: app, expectedVersion: SemanticVersion(1, 3, 0),
                                            bundleIdentifier: "com.federico.prbar", runner: SystemProcessRunner())
        },
        TestCase("update verifier: rechaza versión, bundle id, app faltante y --version distinto") {
            let dir = try temporaryDirectory()
            let wrongVersion = dir.appendingPathComponent("a/PRBar.app", isDirectory: true)
            try makeFakeApp(at: wrongVersion, version: "1.2.9", marker: "x")
            let e1 = try await expectThrows {
                try await UpdateVerifier.verify(app: wrongVersion, expectedVersion: SemanticVersion(1, 3, 0),
                                                bundleIdentifier: "com.federico.prbar", runner: SystemProcessRunner())
            }
            try expectEqual(e1 as? UpdateError, .versionMismatch(expected: "1.3.0", found: "1.2.9"))

            let wrongID = dir.appendingPathComponent("b/PRBar.app", isDirectory: true)
            try makeFakeApp(at: wrongID, version: "1.3.0", identifier: "com.evil.app", marker: "x")
            let e2 = try await expectThrows {
                try await UpdateVerifier.verify(app: wrongID, expectedVersion: SemanticVersion(1, 3, 0),
                                                bundleIdentifier: "com.federico.prbar", runner: SystemProcessRunner())
            }
            try expectEqual(e2 as? UpdateError, .bundleIdentifierMismatch(expected: "com.federico.prbar", found: "com.evil.app"))

            let missing = dir.appendingPathComponent("c/PRBar.app", isDirectory: true)
            let e3 = try await expectThrows {
                try await UpdateVerifier.verify(app: missing, expectedVersion: SemanticVersion(1, 3, 0),
                                                bundleIdentifier: "com.federico.prbar", runner: SystemProcessRunner())
            }
            try expectEqual(e3 as? UpdateError, .appMissing(missing.path))

            let liar = dir.appendingPathComponent("d/PRBar.app", isDirectory: true)
            try makeFakeApp(at: liar, version: "1.3.0", marker: "x")
            let runner = FakeProcessRunner { _, _ in ProcessResult(status: 0, stdout: "PRBar 1.2.0\n", stderr: "") }
            let e4 = try await expectThrows {
                try await UpdateVerifier.verify(app: liar, expectedVersion: SemanticVersion(1, 3, 0),
                                                bundleIdentifier: "com.federico.prbar", runner: runner)
            }
            guard case .launchCheckFailed? = e4 as? UpdateError else { throw TestFailure(description: "\(e4)") }
            try expectEqual(runner.calls.first?.arguments, ["--version"])
        },
    ]

    static let replacerCases: [TestCase] = [
        TestCase("app replacer: mueve el actual a .previous y el nuevo a su lugar") {
            let dir = try temporaryDirectory()
            let installed = dir.appendingPathComponent("Applications/PRBar.app", isDirectory: true)
            let staged = dir.appendingPathComponent("staging/PRBar.app", isDirectory: true)
            try makeFakeApp(at: installed, version: "1.2.0", marker: "old")
            try makeFakeApp(at: staged, version: "1.3.0", marker: "new")
            // Un .previous de una actualización anterior se reemplaza.
            try makeFakeApp(at: AppReplacer.previousURL(for: installed), version: "1.1.0", marker: "older")
            try AppReplacer().replace(installed: installed, with: staged)
            try expectEqual(marker(of: installed), "new")
            try expectEqual(marker(of: AppReplacer.previousURL(for: installed)), "old")
            try expectEqual(AppReplacer.previousURL(for: installed).lastPathComponent, "PRBar.app.previous")
            try expect(!FileManager.default.fileExists(atPath: staged.path))
        },
        TestCase("app replacer: si falla mover el nuevo, vuelve a poner el anterior") {
            let dir = try temporaryDirectory()
            let installed = dir.appendingPathComponent("Applications/PRBar.app", isDirectory: true)
            let staged = dir.appendingPathComponent("staging/PRBar.app", isDirectory: true)
            try makeFakeApp(at: installed, version: "1.2.0", marker: "old")
            try makeFakeApp(at: staged, version: "1.3.0", marker: "new")
            let moves = Box(0)
            let replacer = AppReplacer(move: { from, to in
                moves.value += 1
                if moves.value == 2 { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: from, to: to)
            })
            let error = try await expectThrows { try replacer.replace(installed: installed, with: staged) }
            guard case .replaceFailed(let message)? = error as? UpdateError else { throw TestFailure(description: "\(error)") }
            try expect(message.contains("wasn't changed"), message)
            try expectEqual(marker(of: installed), "old")
            try expect(!FileManager.default.fileExists(atPath: AppReplacer.previousURL(for: installed).path))
            try expectEqual(moves.value, 3)
        },
        TestCase("app replacer: carpeta sin permiso de escritura → notWritable") {
            let dir = try temporaryDirectory().appendingPathComponent("ro", isDirectory: true)
            let installed = dir.appendingPathComponent("PRBar.app", isDirectory: true)
            try makeFakeApp(at: installed, version: "1.2.0", marker: "old")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
            let error = try await expectThrows { try AppReplacer.checkWritable(installed) }
            try expectEqual(error as? UpdateError, .notWritable(dir.path))
        },
        TestCase("app replacer: removePrevious borra PRBar.app.previous y no falla si no está") {
            let dir = try temporaryDirectory()
            let installed = dir.appendingPathComponent("PRBar.app", isDirectory: true)
            try makeFakeApp(at: AppReplacer.previousURL(for: installed), version: "1.2.0", marker: "old")
            AppReplacer.removePrevious(nextTo: installed)
            try expect(!FileManager.default.fileExists(atPath: AppReplacer.previousURL(for: installed).path))
            AppReplacer.removePrevious(nextTo: installed)
        },
    ]
}
```

Nota: `expectThrows` toma un cuerpo `async throws`; un `try` sincrónico adentro también vale.

- [ ] **Step 2: Registrar** `+ UpdateInstallTests.cases` en `main.swift`.

- [ ] **Step 3: Correr y ver que falla**

Run: `swift run PRBarTests "update verifier"`
Expected: error de compilación `cannot find 'UpdateVerifier' in scope`.

- [ ] **Step 4: Crear `Sources/PRBarCore/AppReplacer.swift`**

```swift
import Foundation

/// Revisa el `.app` recién compilado antes de instalarlo (spec D.3, paso 4): existe, su versión es la esperada, su
/// bundle id es el de la app instalada y el binario arranca con `--version`.
public enum UpdateVerifier {
    public static let launchTimeout: TimeInterval = 15

    public static func verify(app: URL, expectedVersion: SemanticVersion, bundleIdentifier: String, runner: ProcessRunning) async throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw UpdateError.appMissing(app.path)
        }
        let found = info["CFBundleShortVersionString"] as? String ?? ""
        guard SemanticVersion(found) == expectedVersion else {
            throw UpdateError.versionMismatch(expected: expectedVersion.description, found: found)
        }
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        guard identifier == bundleIdentifier else {
            throw UpdateError.bundleIdentifierMismatch(expected: bundleIdentifier, found: identifier)
        }
        let name = info["CFBundleExecutable"] as? String ?? ""
        let executable = app.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(name)
        guard !name.isEmpty, !name.contains("/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.appMissing(executable.path)
        }
        let result = try await runner.run(executable.path, ["--version"], environment: nil, currentDirectory: nil, timeout: launchTimeout)
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, output == AppVersion.versionLine(expectedVersion.description) else {
            let detail = output.isEmpty ? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) : output
            throw UpdateError.launchCheckFailed("exit code \(result.status): \(detail.prefix(200))")
        }
    }
}

/// Reemplazo del `.app` instalado (spec D.3, paso 5): el actual pasa a `PRBar.app.previous` (en la misma carpeta) y
/// el nuevo ocupa su lugar; si el segundo paso falla, el anterior vuelve. Funciona donde esté instalada la app
/// (`Bundle.main.bundleURL`).
public struct AppReplacer: Sendable {
    public typealias Move = @Sendable (URL, URL) throws -> Void

    private let move: Move

    /// `move` se puede reemplazar en los tests para simular fallas.
    public init(move: @escaping Move = { try FileManager.default.moveItem(at: $0, to: $1) }) {
        self.move = move
    }

    public static func previousURL(for installed: URL) -> URL {
        installed.deletingLastPathComponent().appendingPathComponent(installed.lastPathComponent + ".previous", isDirectory: true)
    }

    /// Antes de compilar: sin permiso de escritura en la carpeta del `.app` no se puede reemplazar.
    public static func checkWritable(_ installed: URL) throws {
        let folder = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw UpdateError.notWritable(folder.path) }
    }

    public func replace(installed: URL, with newApp: URL) throws {
        let fileManager = FileManager.default
        let previous = Self.previousURL(for: installed)
        do {
            if fileManager.fileExists(atPath: previous.path) { try fileManager.removeItem(at: previous) }
            try move(installed, previous)
        } catch {
            throw UpdateError.replaceFailed(
                "Couldn't move the installed app aside (\(error.localizedDescription)). The installed version wasn't changed."
            )
        }
        do {
            try move(newApp, installed)
        } catch {
            do {
                try move(previous, installed)
            } catch let restoreError {
                throw UpdateError.replaceFailed(
                    "Couldn't install the new app (\(error.localizedDescription)) or put the previous one back "
                        + "(\(restoreError.localizedDescription)). The previous version is at \(previous.path)."
                )
            }
            throw UpdateError.replaceFailed(
                "Couldn't install the new app (\(error.localizedDescription)). The installed version wasn't changed."
            )
        }
    }

    /// La versión nueva, al arrancar, borra la anterior. Nunca lanza: los errores se loguean.
    public static func removePrevious(nextTo installed: URL) {
        let previous = previousURL(for: installed)
        guard FileManager.default.fileExists(atPath: previous.path) else { return }
        do {
            try FileManager.default.removeItem(at: previous)
        } catch {
            AppLog.write("Couldn't delete \(previous.path): \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 5: Correr los tests**

Run: `swift run PRBarTests "update verifier"` y `swift run PRBarTests "app replacer"`
Expected: 2 + 4 tests con ✓.

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCore/AppReplacer.swift Sources/PRBarTests/UpdateInstallTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): verify a built app and replace the installed one with rollback"
```

---

### Task 10: `UpdateInstaller`, reinicio y marca de "Updated to"

**Files:**
- Create: `Sources/PRBarCore/UpdateInstaller.swift`, `Sources/PRBarCore/UpdateRelaunch.swift`
- Modify: `Sources/PRBarCore/Support.swift` (`AppPaths`), `Sources/PRBarTests/UpdateInstallTests.swift`

- [ ] **Step 1: Agregar tests a `UpdateInstallTests.swift`**

Cambiar `static let cases: [TestCase] = verifierCases + replacerCases` por `verifierCases + replacerCases + installerCases + relaunchCases`, y agregar:

```swift
    static let sha = String(repeating: "a", count: 40)

    /// git falso (sha en rev-parse, merge-base con `mergeBaseStatus`) y `--version` que dice `versionLine`.
    static func fakeRunner(mergeBaseStatus: Int32 = 0, versionLine: String = "PRBar 1.3.0") -> FakeProcessRunner {
        FakeProcessRunner { _, arguments in
            if arguments.contains("rev-parse") { return ProcessResult(status: 0, stdout: sha + "\n", stderr: "") }
            if arguments.contains("merge-base") { return ProcessResult(status: mergeBaseStatus, stdout: "", stderr: "") }
            if arguments == ["--version"] { return ProcessResult(status: 0, stdout: versionLine + "\n", stderr: "") }
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
    }

    /// `bundle.sh` falso: arma `<--output>/PRBar.app` con `version` y sale con `status`.
    static func fakeBuilder(version: String = "1.3.0", status: Int32 = 0) -> FakeStreamingRunner {
        FakeStreamingRunner { _, arguments, _ in
            if status == 0 {
                let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
                try makeFakeApp(at: output.appendingPathComponent("PRBar.app", isDirectory: true), version: version, marker: "new")
            }
            return (lines: ["Compiling PRBar", "Bundle listo"],
                    result: ProcessResult(status: status, stdout: "", stderr: status == 0 ? "" : "error: boom\n"))
        }
    }

    static func makeInstaller(base: URL, runner: FakeProcessRunner, builder: FakeStreamingRunner) -> UpdateInstaller {
        UpdateInstaller(
            source: UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: base.appendingPathComponent("source", isDirectory: true),
                                 remoteURL: "https://github.com/acme/PRBar.git"),
            builder: builder, runner: runner, stagingRoot: base.appendingPathComponent("staging", isDirectory: true),
            bundleIdentifier: "com.federico.prbar"
        )
    }

    static func phases(_ events: [UpdateEvent]) -> [UpdatePhase] {
        events.compactMap { event -> UpdatePhase? in
            if case .phase(let phase) = event { return phase }
            return nil
        }
    }

    static func setUp() throws -> (base: URL, installed: URL) {
        let base = try temporaryDirectory()
        let installed = base.appendingPathComponent("Applications/PRBar.app", isDirectory: true)
        try makeFakeApp(at: installed, version: "1.2.0", marker: "old")
        return (base, installed)
    }

    static let installerCases: [TestCase] = [
        TestCase("update installer: baja, compila, verifica y reemplaza; eventos en orden") {
            let (base, installed) = try setUp()
            let runner = fakeRunner()
            let builder = fakeBuilder()
            let events = Box<[UpdateEvent]>([])
            let replaces = Box(0)
            try await makeInstaller(base: base, runner: runner, builder: builder).install(
                makeRelease("1.3.0"), replacing: installed,
                beforeReplace: { replaces.value += 1 }, onEvent: { events.value.append($0) }
            )
            try expectEqual(marker(of: installed), "new")
            try expectEqual(marker(of: AppReplacer.previousURL(for: installed)), "old")
            try expectEqual(replaces.value, 1)
            try expectEqual(phases(events.value), [.fetching, .building, .verifying, .installing])
            try expect(events.value.contains(.log("Compiling PRBar")))
            try expectEqual(builder.calls.count, 1)
            try expectEqual(builder.calls[0].executable, "/bin/bash")
            try expectEqual(Array(builder.calls[0].arguments.prefix(2)),
                            [base.appendingPathComponent("source/Scripts/bundle.sh").path, "--output"])
            try expectEqual(builder.calls[0].currentDirectory?.path, base.appendingPathComponent("source").path)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("staging").path)
            try expectEqual(leftovers, [])
        },
        TestCase("update installer: build que falla → no toca el .app") {
            let (base, installed) = try setUp()
            let runner = fakeRunner()
            let events = Box<[UpdateEvent]>([])
            let error = try await expectThrows {
                try await makeInstaller(base: base, runner: runner, builder: fakeBuilder(status: 1)).install(
                    makeRelease("1.3.0"), replacing: installed, onEvent: { events.value.append($0) }
                )
            }
            try expectEqual(error as? UpdateError, .buildFailed(status: 1))
            try expectEqual(marker(of: installed), "old")
            try expect(!FileManager.default.fileExists(atPath: AppReplacer.previousURL(for: installed).path))
            try expectEqual(phases(events.value), [.fetching, .building])
            try expect(events.value.contains(.log("error: boom")))
            try expect(!runner.calls.contains { $0.arguments == ["--version"] })
        },
        TestCase("update installer: verificación que falla → no toca el .app") {
            let (base, installed) = try setUp()
            let error = try await expectThrows {
                try await makeInstaller(base: base, runner: fakeRunner(), builder: fakeBuilder(version: "1.2.9")).install(
                    makeRelease("1.3.0"), replacing: installed, onEvent: { _ in }
                )
            }
            try expectEqual(error as? UpdateError, .versionMismatch(expected: "1.3.0", found: "1.2.9"))
            try expectEqual(marker(of: installed), "old")
        },
        TestCase("update installer: tag fuera de main → no compila") {
            let (base, installed) = try setUp()
            let builder = fakeBuilder()
            let error = try await expectThrows {
                try await makeInstaller(base: base, runner: fakeRunner(mergeBaseStatus: 1), builder: builder).install(
                    makeRelease("1.3.0"), replacing: installed, onEvent: { _ in }
                )
            }
            try expectEqual(error as? UpdateError, .tagNotOnMain("v1.3.0"))
            try expectEqual(builder.calls.count, 0)
            try expectEqual(marker(of: installed), "old")
        },
        TestCase("update installer: cancelado antes de reemplazar → no toca el .app") {
            let (base, installed) = try setUp()
            let error = try await expectThrows {
                try await makeInstaller(base: base, runner: fakeRunner(), builder: fakeBuilder()).install(
                    makeRelease("1.3.0"), replacing: installed, beforeReplace: { throw CancellationError() }, onEvent: { _ in }
                )
            }
            try expect(error is CancellationError, "\(error)")
            try expectEqual(marker(of: installed), "old")
        },
        TestCase("update installer: carpeta de la app sin escritura → falla antes de git") {
            let (base, installed) = try setUp()
            let folder = installed.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            let runner = fakeRunner()
            let error = try await expectThrows {
                try await makeInstaller(base: base, runner: runner, builder: fakeBuilder()).install(
                    makeRelease("1.3.0"), replacing: installed, onEvent: { _ in }
                )
            }
            try expectEqual(error as? UpdateError, .notWritable(folder.path))
            try expectEqual(runner.calls.count, 0)
        },
    ]

    static let relaunchCases: [TestCase] = [
        TestCase("relaunch: argumentos de /bin/sh") {
            try expectEqual(Relauncher.arguments(waitingFor: 4242, appPath: "/Users/me/Applications/PRBar.app"), [
                "-c",
                "while kill -0 4242 2>/dev/null; do sleep 0.2; done; "
                    + "for attempt in 1 2 3 4 5; do /usr/bin/open \"$0\" && exit 0; sleep 1; done; exit 1",
                "/Users/me/Applications/PRBar.app",
            ])
        },
        TestCase("relaunch: espera al pid y pasa la ruta tal cual (espacios y comillas)") {
            let target = try temporaryDirectory().appendingPathComponent("Pr Bar 'x\" $HOME.app").path
            let finished = Process()
            finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try finished.run()
            finished.waitUntilExit()
            let arguments = Relauncher.arguments(waitingFor: finished.processIdentifier, appPath: target, openCommand: "/usr/bin/touch")
            let result = try await SystemProcessRunner().run("/bin/sh", arguments, timeout: 10)
            try expectEqual(result.status, 0)
            try expect(FileManager.default.fileExists(atPath: target))
        },
        TestCase("pending update: se lee una sola vez y solo si es la versión que corre") {
            let url = try temporaryDirectory().appendingPathComponent("update-installed.json")
            let update = PendingUpdate(version: "1.3.0", notes: "- Chat", installedAt: Date(timeIntervalSince1970: 1_800_000_000))
            try PendingUpdate.save(update, to: url)
            try expectEqual(PendingUpdate.take(currentVersion: "1.3.0", from: url), update)
            try expectEqual(PendingUpdate.take(currentVersion: "1.3.0", from: url), nil)

            try PendingUpdate.save(update, to: url)
            try expectEqual(PendingUpdate.take(currentVersion: "1.2.0", from: url), nil)
            try expect(!FileManager.default.fileExists(atPath: url.path))

            try Data("{".utf8).write(to: url)
            try expectEqual(PendingUpdate.take(currentVersion: "1.3.0", from: url), nil)
            try expect(!FileManager.default.fileExists(atPath: url.path))
        },
    ]
```

- [ ] **Step 2: Correr y ver que falla**

Run: `swift run PRBarTests "update installer"`
Expected: error de compilación `cannot find 'UpdateInstaller' in scope`.

- [ ] **Step 3: Agregar rutas a `AppPaths` en `Sources/PRBarCore/Support.swift`** (junto a `updateSourceDir`)

```swift
    /// Donde se arma el `.app` nuevo: misma unidad que `~/Applications`, así reemplazarlo es un rename.
    public static var updateStagingDir: URL { appSupport.appendingPathComponent("update-staging", isDirectory: true) }
    /// La versión recién instalada; la lee la versión nueva al arrancar para mostrar "Updated to …".
    public static var pendingUpdateFile: URL { appSupport.appendingPathComponent("update-installed.json") }
    /// Log de la última actualización ("Show Log").
    public static var updateLog: URL { logFile.deletingLastPathComponent().appendingPathComponent("update.log") }
```

- [ ] **Step 4: Crear `Sources/PRBarCore/UpdateInstaller.swift`**

```swift
import Foundation

/// Etapas de una actualización (ventana "Update PRBar" y eventos de `prbar update`).
public enum UpdatePhase: String, Codable, CaseIterable, Sendable {
    case waitingForJobs, fetching, building, verifying, installing, relaunching

    public var title: String {
        switch self {
        case .waitingForJobs: "Waiting for running jobs"
        case .fetching: "Downloading the source"
        case .building: "Building (takes a minute or two)"
        case .verifying: "Checking the new app"
        case .installing: "Installing"
        case .relaunching: "Restarting PRBar"
        }
    }
}

public enum UpdateEvent: Equatable, Sendable {
    case phase(UpdatePhase)
    /// Una línea del log (git, build).
    case log(String)
}

/// Qué hacer con los trabajos (reviews, responds, chats) que están corriendo al actualizar (spec D.3, paso 1).
public enum UpdateBusyPolicy: String, Codable, Sendable {
    /// Actualizar cuando terminen.
    case wait
    /// Cancelarlos (salvo una publicación o un push en curso, que se espera) y actualizar.
    case cancelJobs
}

/// Instala un release (spec D.3, pasos 2 a 5): fuente → build con `Scripts/bundle.sh --output` → verificación →
/// reemplazo. Si algo falla antes del reemplazo, el `.app` instalado no se toca; la carpeta de staging siempre se
/// borra. Esperar trabajos y reiniciar quedan para la app (`beforeReplace`, `Relauncher`).
public struct UpdateInstaller: Sendable {
    public static let buildTimeout: TimeInterval = 30 * 60

    private let source: UpdateSource
    private let builder: StreamingProcessRunning
    private let runner: ProcessRunning
    private let stagingRoot: URL
    private let bundleIdentifier: String
    private let replacer: AppReplacer

    public init(
        source: UpdateSource, builder: StreamingProcessRunning, runner: ProcessRunning,
        stagingRoot: URL = AppPaths.updateStagingDir, bundleIdentifier: String, replacer: AppReplacer = AppReplacer()
    ) {
        self.source = source
        self.builder = builder
        self.runner = runner
        self.stagingRoot = stagingRoot
        self.bundleIdentifier = bundleIdentifier
        self.replacer = replacer
    }

    /// `beforeReplace` corre después de verificar y antes de reemplazar (la app vuelve a esperar trabajos ahí).
    /// `onEvent` se llama desde cualquier hilo.
    public func install(
        _ release: ReleaseInfo, replacing installedApp: URL,
        beforeReplace: @escaping @Sendable () async throws -> Void = {},
        onEvent: @escaping @Sendable (UpdateEvent) -> Void
    ) async throws {
        try AppReplacer.checkWritable(installedApp)
        let fileManager = FileManager.default
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        onEvent(.phase(.fetching))
        let sha = try await source.checkout(tag: release.tag)
        onEvent(.log("\(release.tag) is \(sha)"))

        onEvent(.phase(.building))
        let script = source.directory.appendingPathComponent("Scripts/bundle.sh")
        let build = try await builder.runStreaming(
            "/bin/bash", [script.path, "--output", staging.path],
            environment: nil, currentDirectory: source.directory, timeout: Self.buildTimeout,
            onStdoutLine: { onEvent(.log($0)) }
        )
        for line in build.stderr.split(whereSeparator: \.isNewline) { onEvent(.log(String(line))) }
        guard build.status == 0 else { throw UpdateError.buildFailed(status: build.status) }

        onEvent(.phase(.verifying))
        let newApp = staging.appendingPathComponent("PRBar.app", isDirectory: true)
        try await UpdateVerifier.verify(app: newApp, expectedVersion: release.version, bundleIdentifier: bundleIdentifier, runner: runner)

        try await beforeReplace()
        try Task.checkCancellation()
        onEvent(.phase(.installing))
        try replacer.replace(installed: installedApp, with: newApp)
        onEvent(.log("Installed PRBar \(release.version) at \(installedApp.path)"))
    }
}
```

- [ ] **Step 5: Crear `Sources/PRBarCore/UpdateRelaunch.swift`**

```swift
import Foundation

/// Reinicio después de instalar (spec D.3, paso 6): un `/bin/sh` desacoplado espera a que termine este proceso y abre
/// el `.app` (reintenta si LaunchServices devuelve -600 justo después del reemplazo). La ruta va como `$0`, nunca
/// dentro del script, así espacios o comillas no se interpretan.
public enum Relauncher {
    public static func arguments(waitingFor pid: Int32, appPath: String, openCommand: String = "/usr/bin/open") -> [String] {
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; "
            + "for attempt in 1 2 3 4 5; do \(openCommand) \"$0\" && exit 0; sleep 1; done; exit 1"
        return ["-c", script, appPath]
    }

    /// Lanza el `/bin/sh` y vuelve enseguida; el proceso sigue vivo cuando la app termina.
    public static func launch(waitingFor pid: Int32, appPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(waitingFor: pid, appPath: appPath)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

/// La versión recién instalada, para que la nueva muestre "Updated to X" con las notas al arrancar.
public struct PendingUpdate: Codable, Equatable, Sendable {
    public var version: String
    public var notes: String
    public var installedAt: Date

    public init(version: String, notes: String, installedAt: Date) {
        self.version = version
        self.notes = notes
        self.installedAt = installedAt
    }

    public static func save(_ update: PendingUpdate, to url: URL = AppPaths.pendingUpdateFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(update).write(to: url, options: .atomic)
    }

    /// Lee y borra el archivo. Devuelve la actualización solo si es la versión que está corriendo (si no, la
    /// instalación no llegó a arrancar o es de otra vez).
    public static func take(currentVersion: String, from url: URL = AppPaths.pendingUpdateFile) -> PendingUpdate? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let update = try? JSONCoding.decoder.decode(PendingUpdate.self, from: data),
              let version = SemanticVersion(update.version), version == SemanticVersion(currentVersion) else { return nil }
        return update
    }
}
```

- [ ] **Step 6: Correr los tests**

Run: `swift run PRBarTests "update installer"`, `swift run PRBarTests relaunch` y `swift run PRBarTests "pending update"`
Expected: 6 + 2 + 1 tests con ✓.

- [ ] **Step 7: Suite completa**

Run: `swift run PRBarTests`
Expected: `N/N passed`, sin fallas.

- [ ] **Step 8: Commit**

```bash
git add Sources/PRBarCore/UpdateInstaller.swift Sources/PRBarCore/UpdateRelaunch.swift Sources/PRBarCore/Support.swift Sources/PRBarTests/UpdateInstallTests.swift
git commit -m "feat(core): install a release from source and relaunch"
```

---

### Task 11: `UpdateController` y la API de `AppModel`

Sin tests automáticos (el target `PRBar` no se testea); la lógica ya está probada en Core. La verificación es que compile y la suite siga verde.

**Files:**
- Create: `Sources/PRBar/Update/UpdateController.swift`, `Sources/PRBar/AppModel+Updates.swift`
- Modify: `Sources/PRBar/AppModel.swift` (`AppModelServices` líneas 21-36, propiedades 61-73, `init` 131-170, `bootstrap` 186-192), `Sources/PRBar/NotificationDelivery.swift`

- [ ] **Step 1: Crear `Sources/PRBar/Update/UpdateController.swift`**

```swift
import AppKit
import PRBarCore

/// Chequeo e instalación de actualizaciones (spec D). Lo crea `AppModel`; la UI (popover, Settings, ventana
/// "Update PRBar") y la CLI (Plan 7, por los métodos de `AppModel+Updates`) pasan por acá.
@MainActor
final class UpdateController: ObservableObject {
    enum InstallState: Equatable {
        case idle
        case running(UpdatePhase)
        case failed(String)
    }

    /// Cada cuánto se fija si toca chequear (el intervalo real es `updates.checkIntervalHours`).
    private static let schedulerTick: Duration = .seconds(3600)
    private static let maxLogLines = 2000

    /// Versión nueva que se ofrece (popover, Settings). `nil`: al día, salteada o sin chequear.
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var isChecking = false
    /// Resultado del último chequeo manual (Settings muestra "up to date" o el error).
    @Published private(set) var lastManualOutcome: UpdateCheckOutcome?
    @Published private(set) var installState: InstallState = .idle
    @Published private(set) var log: [String] = []
    /// Trabajos que se están esperando antes de reemplazar la app.
    @Published private(set) var waitingJobs = 0

    let currentVersion = AppVersion.current()

    private let configStore: ConfigStore
    private let transport: any HTTPTransport
    private let runner: SystemProcessRunner
    private let notifications: NotificationDelivery?
    private let gitPath: () -> String?
    private let activeJobs: () -> Int
    private let cancelJobs: () -> Void
    private var scheduler: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    /// Id de la instalación en curso: los eventos de una instalación vieja (que llegan tarde al hilo principal) se ignoran.
    private var installID: UUID?
    /// Quien pidió la instalación por `install(_:whenBusy:onEvent:)` (la CLI) recibe también los eventos.
    private var eventObserver: ((UpdateEvent) -> Void)?

    init(
        configStore: ConfigStore, transport: any HTTPTransport, runner: SystemProcessRunner, notifications: NotificationDelivery?,
        gitPath: @escaping () -> String?, activeJobs: @escaping () -> Int, cancelJobs: @escaping () -> Void
    ) {
        self.configStore = configStore
        self.transport = transport
        self.runner = runner
        self.notifications = notifications
        self.gitPath = gitPath
        self.activeJobs = activeJobs
        self.cancelJobs = cancelJobs
    }

    var installedVersion: SemanticVersion { SemanticVersion(currentVersion) ?? SemanticVersion(0, 0, 0) }

    /// El `.app` que está corriendo; `nil` con `swift run` (ahí se puede chequear pero no instalar).
    var installedApp: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    var isInstalling: Bool {
        if case .running = installState { return true }
        return false
    }

    var runningJobs: Int { activeJobs() }

    static func openLog() {
        NSWorkspace.shared.open(AppPaths.updateLog)
    }

    // MARK: Chequeo

    /// Al arrancar y después cada hora: chequea si pasó el intervalo.
    func startAutomaticChecks() {
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: Self.schedulerTick)
            }
        }
    }

    func checkIfDue() async {
        guard !isChecking, UpdatePolicy.isCheckDue(configStore.config.updates, now: Date()) else { return }
        await check(manual: false)
    }

    @discardableResult
    func check(manual: Bool) async -> UpdateCheckOutcome {
        isChecking = true
        defer { isChecking = false }
        let settings = configStore.config.updates
        let checker = UpdateChecker(transport: transport, repo: settings.effectiveRepo)
        let report = await checker.check(
            installed: installedVersion, settings: settings, notifications: configStore.config.notifications,
            manual: manual, now: Date()
        )
        save { updates in
            updates.lastCheckAt = report.settings.lastCheckAt
            updates.notifiedVersion = report.settings.notifiedVersion
        }
        if case .failed = report.outcome {} else { available = report.offered }
        if let notification = report.notification { notifications?.deliver([notification]) }
        if manual { lastManualOutcome = report.outcome }
        return report.outcome
    }

    func skip(_ release: ReleaseInfo) {
        save { $0.skippedVersion = release.version.description }
        if available?.version == release.version { available = nil }
    }

    // MARK: Instalación

    /// Desde la ventana: corre `install` en una tarea propia y deja el error en `installState`.
    func startInstall(_ release: ReleaseInfo, whenBusy: UpdateBusyPolicy) {
        guard !isInstalling else { return }
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.install(release, whenBusy: whenBusy)
            } catch is CancellationError {
                self.installState = .idle
                self.appendLog("Update canceled.")
            } catch {
                self.installState = .failed(error.localizedDescription)
                self.appendLog("Update failed: \(error.localizedDescription)")
            }
        }
    }

    /// Solo antes de instalar (la ventana no ofrece Cancel en `installing`/`relaunching`).
    func cancelInstall() {
        installTask?.cancel()
    }

    /// Todo el flujo: esperar trabajos, bajar, compilar, verificar, reemplazar y reiniciar. Si sale bien no vuelve:
    /// la app termina y la versión nueva arranca sola.
    func install(_ release: ReleaseInfo, whenBusy: UpdateBusyPolicy, onEvent: ((UpdateEvent) -> Void)? = nil) async throws {
        guard !isInstalling else { throw UpdateError.alreadyInstalling }
        guard let installedApp else { throw UpdateError.notInstalledAsApp }
        guard let git = gitPath() else { throw PRBarError.toolNotFound("git") }
        let id = UUID()
        installID = id
        eventObserver = onEvent
        defer {
            if installID == id { installID = nil }
            eventObserver = nil
        }
        log = []
        UpdateLogFile.reset()
        appendLog("Updating PRBar \(currentVersion) → \(release.version)")
        // En el acto (los eventos llegan un instante después): un segundo click en "Update" no arranca otra instalación.
        installState = .running(.fetching)

        try await drainJobs(whenBusy)
        let installer = UpdateInstaller(
            source: UpdateSource(
                runner: runner, gitPath: git,
                remoteURL: UpdateSource.remoteURL(forRepo: configStore.config.updates.effectiveRepo)
            ),
            builder: runner, runner: runner,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.federico.prbar"
        )
        try await installer.install(
            release, replacing: installedApp,
            beforeReplace: { [weak self] in try await self?.drainJobs(whenBusy) },
            onEvent: { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.record(event, install: id) } }
            }
        )

        do {
            try PendingUpdate.save(PendingUpdate(version: release.version.description, notes: release.notes, installedAt: Date()))
        } catch {
            AppLog.write("Couldn't save update-installed.json: \(error.localizedDescription)")
        }
        record(.phase(.relaunching))
        do {
            try Relauncher.launch(waitingFor: ProcessInfo.processInfo.processIdentifier, appPath: installedApp.path)
        } catch {
            throw UpdateError.relaunchFailed(release.version.description)
        }
        NSApp.terminate(nil)
    }

    /// Espera a que no quede ningún trabajo; con `.cancelJobs` primero los cancela (las publicaciones y pushes en
    /// curso no se cancelan: se esperan).
    private func drainJobs(_ policy: UpdateBusyPolicy) async throws {
        guard activeJobs() > 0 else { return }
        if policy == .cancelJobs {
            appendLog("Canceling running jobs (posting and pushing finish first).")
            cancelJobs()
        }
        record(.phase(.waitingForJobs))
        while activeJobs() > 0 {
            waitingJobs = activeJobs()
            try await Task.sleep(for: .seconds(1))
        }
        waitingJobs = 0
    }

    // MARK: Arranque

    /// Al arrancar: borra `PRBar.app.previous` y devuelve la actualización recién instalada (para "Updated to …").
    func finishPendingInstall() -> PendingUpdate? {
        if let installedApp { AppReplacer.removePrevious(nextTo: installedApp) }
        return PendingUpdate.take(currentVersion: currentVersion)
    }

    /// Modo de capturas.
    func applySnapshotState(available: ReleaseInfo?) {
        self.available = available
    }

    // MARK: Log y estado

    private func record(_ event: UpdateEvent, install id: UUID) {
        guard installID == id else { return }
        record(event)
    }

    private func record(_ event: UpdateEvent) {
        switch event {
        case .phase(let phase):
            installState = .running(phase)
            appendLog("== \(phase.title)")
        case .log(let line):
            appendLog(line)
        }
        eventObserver?(event)
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
        UpdateLogFile.append(line)
    }

    private func save(_ mutate: (inout UpdateSettings) -> Void) {
        var next = configStore.config.updates
        mutate(&next)
        guard next != configStore.config.updates else { return }
        do {
            try configStore.update { $0.updates = next }
        } catch {
            AppLog.write("Couldn't save the update settings: \(error.localizedDescription)")
        }
    }
}

/// `~/Library/Logs/PRBar/update.log`: el log de la última actualización ("Show Log").
private enum UpdateLogFile {
    static func reset() {
        let url = AppPaths.updateLog
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    static func append(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: AppPaths.updateLog) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
```

- [ ] **Step 2: `AppModelServices` en `Sources/PRBar/AppModel.swift`** — después de `var respondPipeline: (any RespondPipelineRunning)?`:

```swift
    /// Para chequear los releases en GitHub (spec D.2). El modo de capturas nunca chequea.
    var updateTransport: any HTTPTransport = URLSessionTransport()
```

- [ ] **Step 3: Propiedades de `AppModel`** — después de `private let respondPipeline: (any RespondPipelineRunning)?`:

```swift
    private let updateTransport: any HTTPTransport
```

y después del `lazy var respond`:

```swift
    /// Actualizaciones (spec D). `lazy` por lo mismo que `reviews`: sus closures capturan `self` (débil).
    private(set) lazy var updates = UpdateController(
        configStore: configStore, transport: updateTransport, runner: runner, notifications: notifications,
        gitPath: { [weak self] in self?.tools.git },
        activeJobs: { [weak self] in self?.activeJobCount ?? 0 },
        cancelJobs: { [weak self] in self?.cancelJobsForUpdate() }
    )
```

- [ ] **Step 4: `init`** — después de `self.respondPipeline = services.respondPipeline`:

```swift
        self.updateTransport = services.updateTransport
```

- [ ] **Step 5: `bootstrap`** — después de `prStore.start()`:

```swift
        updates.startAutomaticChecks()
```

- [ ] **Step 6: Crear `Sources/PRBar/AppModel+Updates.swift`**

```swift
import AppKit
import PRBarCore

/// Actualizaciones (spec D). La CLI (Plan 7: `prbar version`, `prbar update [--check] [--yes]`) llama a estos mismos
/// métodos desde `CommandServer`, así la UI y la CLI comparten el flujo.
extension AppModel {
    /// La versión instalada (`prbar version`).
    var appVersion: String { updates.currentVersion }

    /// Chequeo manual (botón "Check for Updates", `prbar update --check`). Nunca lanza.
    func checkForUpdates() async -> UpdateCheckOutcome {
        await updates.check(manual: true)
    }

    /// Instala `release` y reinicia la app. `onEvent` recibe las etapas y el log (la CLI los reenvía como eventos).
    func installUpdate(_ release: ReleaseInfo, whenBusy: UpdateBusyPolicy, onEvent: ((UpdateEvent) -> Void)? = nil) async throws {
        try await updates.install(release, whenBusy: whenBusy, onEvent: onEvent)
    }

    func skipUpdate(_ release: ReleaseInfo) {
        updates.skip(release)
    }

    /// Reviews, análisis, implementaciones, tests y publicaciones de Responder en cola o corriendo.
    var activeJobCount: Int {
        reviews.phases.values.filter(\.isActive).count
            + respond.phases.values.filter(\.isActive).count
            + respond.runningTests.count
    }

    /// "Cancel Jobs and Update": cancela todo salvo las publicaciones/pushes en curso (`RespondQueue.cancel` no las
    /// toca), que se esperan.
    func cancelJobsForUpdate() {
        reviews.cancelAll()
        for prID in Set(respond.phases.keys).union(respond.runningTests) {
            respond.cancel(prID: prID)
        }
    }
}
```

- [ ] **Step 7: Chats del Plan 6 (condicional)**

Run: `grep -n "chat" Sources/PRBar/AppModel.swift Sources/PRBarCore/*.swift | grep -i "queue\|running\|scheduler" | head`
- Si no hay nada (el Plan 6 no está implementado), no hacer nada.
- Si existe (el Plan 6 define `ChatCoordinator` con `isRunning` y `stop()`, uno por ventana, y un `JobScheduler` de chats en `AppModel`), sumar a `activeJobCount` la cantidad de coordinadores con `isRunning == true` que tenga registrados `AppModel` y, en `cancelJobsForUpdate()`, llamar `stop()` en cada uno (lo mismo que el botón **Stop**). Usar los nombres reales con los que el Plan 6 guarda los coordinadores en `AppModel`.

- [ ] **Step 8: Click en la notificación en `Sources/PRBar/NotificationDelivery.swift`**

Después de `var onOpenRespond: ((String) -> Void)?`:

```swift
    /// Click en la notificación de una versión nueva (lo asigna `AppModel`).
    var onOpenUpdate: (() -> Void)?
```

En `deliver`, después de `if let prID = notification.respondPRID { userInfo["respondPRID"] = prID }`:

```swift
            if let version = notification.updateVersion { userInfo["updateVersion"] = version }
```

En `userNotificationCenter(_:didReceive:…)`, el primer caso del `if` pasa a ser:

```swift
        if userInfo["updateVersion"] is String {
            Task { @MainActor in self.onOpenUpdate?() }
        } else if let prID = userInfo["respondPRID"] as? String {
```

(el resto de la cadena queda igual).

- [ ] **Step 9: Compilar y correr la suite**

Run: `swift build && swift run PRBarTests`
Expected: `Build complete!` sin errores; `N/N passed`.

- [ ] **Step 10: Commit**

```bash
git add Sources/PRBar/Update/UpdateController.swift Sources/PRBar/AppModel+Updates.swift Sources/PRBar/AppModel.swift Sources/PRBar/NotificationDelivery.swift
git commit -m "feat(app): check for updates and install them from the app model"
```

---

### Task 12: UI — ventana "Update PRBar", fila del popover y Settings › General › Updates

**Files:**
- Create: `Sources/PRBar/Update/UpdateWindow.swift`, `Sources/PRBar/Popover/UpdateRow.swift`, `Sources/PRBar/Settings/UpdatesSection.swift`
- Modify: `Sources/PRBar/AppModel+Updates.swift`, `Sources/PRBar/AppModel.swift` (`init`, `bootstrap`), `Sources/PRBar/Popover/PopoverView.swift:14-21`, `Sources/PRBar/Settings/GeneralTab.swift:11-67`

- [ ] **Step 1: Crear `Sources/PRBar/Update/UpdateWindow.swift`**

```swift
import AppKit
import PRBarCore
import SwiftUI

/// Lo que muestra la ventana de actualización.
enum UpdateWindowMode: Equatable {
    /// Hay una versión nueva: notas, Update / Skip This Version / Later, y el progreso.
    case available(ReleaseInfo)
    /// La versión nueva acaba de arrancar después de actualizarse.
    case installed(PendingUpdate)

    var id: String {
        switch self {
        case .available(let release): "available-\(release.version)"
        case .installed(let update): "installed-\(update.version)"
        }
    }

    var title: String {
        switch self {
        case .available: "Update PRBar"
        case .installed: "PRBar Updated"
        }
    }
}

struct UpdateWindow: View {
    static let size = NSSize(width: 540, height: 460)

    @ObservedObject var updates: UpdateController
    let mode: UpdateWindowMode
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            notesView
            if case .available = mode { progress }
            HStack(spacing: 8) { buttons }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    // MARK: Encabezado y notas

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.title3.weight(.semibold))
                Text(subheadline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: String {
        switch mode {
        case .available(let release): "PRBar \(release.version) is available"
        case .installed(let update): "Updated to PRBar \(update.version)"
        }
    }

    private var subheadline: String {
        switch mode {
        case .available:
            "You have \(updates.currentVersion). PRBar builds the new version from its source on GitHub, which takes a minute or two, and then restarts."
        case .installed:
            "Here’s what’s new."
        }
    }

    private var notes: String {
        switch mode {
        case .available(let release): release.notes
        case .installed(let update): update.notes
        }
    }

    private var notesView: some View {
        ScrollView {
            Text(Self.markdown(notes.isEmpty ? "No release notes." : notes))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
    }

    /// Markdown en línea (negrita, código, links) respetando los saltos de línea de las notas.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // MARK: Progreso

    @ViewBuilder
    private var progress: some View {
        switch updates.installState {
        case .idle:
            if updates.installedApp == nil {
                Label("PRBar isn’t running as PRBar.app, so it can’t update itself. Install it with Scripts/bundle.sh --install.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .running(let phase):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phase == .waitingForJobs ? Self.waitingText(updates.waitingJobs) : phase.title).font(.callout)
                }
                logView
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.redText)
                    .fixedSize(horizontal: false, vertical: true)
                logView
            }
        }
    }

    static func waitingText(_ count: Int) -> String {
        count == 1 ? "Waiting for 1 running job to finish…" : "Waiting for \(count) running jobs to finish…"
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(updates.log.suffix(200).enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(item.offset)
                    }
                }
                .padding(6)
            }
            .frame(height: 90)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
            .onChange(of: updates.log.count) {
                proxy.scrollTo(min(updates.log.count, 200) - 1, anchor: .bottom)
            }
        }
    }

    // MARK: Botones

    @ViewBuilder
    private var buttons: some View {
        switch mode {
        case .installed:
            Spacer()
            Button("OK", action: close).keyboardShortcut(.defaultAction)
        case .available(let release):
            switch updates.installState {
            case .running(let phase):
                Button("Show Log") { UpdateController.openLog() }
                Spacer()
                Button("Hide", action: close)
                Button("Cancel") { updates.cancelInstall() }
                    .disabled(phase == .installing || phase == .relaunching)
            case .idle, .failed:
                Button("Skip This Version") {
                    updates.skip(release)
                    close()
                }
                if case .failed = updates.installState {
                    Button("Show Log") { UpdateController.openLog() }
                }
                Spacer()
                Button("Later", action: close).keyboardShortcut(.cancelAction)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    installButtons(release, jobs: updates.runningJobs)
                }
            }
        }
    }

    /// Sin trabajos: "Update". Con trabajos: esperar o cancelarlos (spec D.3, paso 1).
    @ViewBuilder
    private func installButtons(_ release: ReleaseInfo, jobs: Int) -> some View {
        let retry = updates.installState != .idle
        HStack(spacing: 8) {
            if jobs == 0 {
                Button(retry ? "Try Again" : "Update") { updates.startInstall(release, whenBusy: .wait) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel Jobs and Update") { updates.startInstall(release, whenBusy: .cancelJobs) }
                    .help("Cancels running reviews, analyses and fixes. Posting and pushing finish first.")
                Button("Update When Done") { updates.startInstall(release, whenBusy: .wait) }
                    .keyboardShortcut(.defaultAction)
                    .help("\(jobs) job\(jobs == 1 ? " is" : "s are") running.")
            }
        }
        .disabled(updates.installedApp == nil)
    }
}
```

- [ ] **Step 2: Abrir la ventana desde `AppModel+Updates.swift`** — agregar dentro de la `extension AppModel`:

```swift
    static let updateWindowID = "update"

    /// Sin `mode`, la versión que se ofrece; si no hay ninguna (p. ej. se salteó después de la notificación), abre
    /// Settings, donde está "Check for Updates".
    func openUpdateWindow(_ mode: UpdateWindowMode? = nil) {
        guard let mode = mode ?? updates.available.map({ UpdateWindowMode.available($0) }) else {
            openSettings()
            return
        }
        WindowPresenter.shared.show(
            id: Self.updateWindowID, title: mode.title, size: UpdateWindow.size,
            options: WindowOptions(autosaveName: "UpdateWindow", miniaturizable: false, resizable: false, allowsTabbing: false),
            contentID: mode.id
        ) {
            UpdateWindow(updates: self.updates, mode: mode, close: { WindowPresenter.shared.close(id: Self.updateWindowID) })
        }
    }
```

- [ ] **Step 3: Engancharla en `AppModel.swift`**

En `init`, después de `notifications?.onOpenRespond = …`:

```swift
        notifications?.onOpenUpdate = { [weak self] in self?.openUpdateWindow() }
```

En `bootstrap`, reemplazar la línea `updates.startAutomaticChecks()` de la Task 11 por:

```swift
        // La versión nueva recién instalada borra la anterior y muestra "Updated to …" (spec D.3, paso 6).
        if let installed = updates.finishPendingInstall() { openUpdateWindow(.installed(installed)) }
        updates.startAutomaticChecks()
```

- [ ] **Step 4: Crear `Sources/PRBar/Popover/UpdateRow.swift`**

```swift
import PRBarCore
import SwiftUI

/// Fila al pie del popover: "PRBar 1.3.0 is available — Update…" con punto azul (spec D.2), o "Updating PRBar…"
/// mientras se instala. No se muestra si no hay nada.
struct UpdateRow: View {
    @ObservedObject var updates: UpdateController
    let open: () -> Void

    var body: some View {
        if let text {
            VStack(spacing: 0) {
                Divider()
                Button(action: open) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Theme.blue)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(text).font(.callout).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .accessibilityLabel(text)
            }
        }
    }

    private var text: String? {
        if updates.isInstalling { return "Updating PRBar…" }
        return updates.available.map { "PRBar \($0.version) is available — Update…" }
    }
}
```

- [ ] **Step 5: Agregarla en `Sources/PRBar/Popover/PopoverView.swift`** — el `body` pasa a:

```swift
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.bottom, 4)
            content
            UpdateRow(updates: model.updates) { model.openUpdateWindow() }
        }
        .frame(width: Theme.popoverWidth)
    }
```

- [ ] **Step 6: Crear `Sources/PRBar/Settings/UpdatesSection.swift`**

```swift
import PRBarCore
import SwiftUI

/// Settings › General › Updates (spec D.2): versión instalada, chequeo automático y su frecuencia, y "Check for Updates".
struct UpdatesSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateController
    @ObservedObject var configStore: ConfigStore

    private var settings: UpdateSettings { configStore.config.updates }

    var body: some View {
        Section {
            LabeledContent("Installed version", value: updates.currentVersion)
            Toggle("Check automatically", isOn: Binding(
                get: { settings.checksAutomatically },
                set: { on in model.updateConfig(refresh: false) { $0.updates.setAutomaticChecks(on) } }
            ))
            Picker("Frequency", selection: Binding(
                get: { shownInterval },
                set: { hours in model.updateConfig(refresh: false) { $0.updates.checkIntervalHours = hours } }
            )) {
                ForEach(intervalChoices, id: \.self) { Text(Self.intervalTitle($0)).tag($0) }
            }
            .disabled(!settings.checksAutomatically)
            HStack(alignment: .firstTextBaseline) {
                status
                Spacer()
                Button("Check for Updates") { Task { await updates.check(manual: true) } }
                    .disabled(updates.isChecking || updates.isInstalling)
            }
        } header: {
            Text("Updates")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("New versions come from github.com/\(settings.effectiveRepo) and are built on this Mac.")
                if updates.installedApp == nil {
                    Text("PRBar isn’t running as PRBar.app, so updates can be checked but not installed.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Apagado muestra el default (el selector queda deshabilitado).
    private var shownInterval: Int {
        settings.checksAutomatically ? settings.checkIntervalHours : UpdateSettings.defaultCheckIntervalHours
    }

    /// Las opciones fijas más la guardada, si alguien puso otra en `config.json`.
    private var intervalChoices: [Int] {
        Array(Set(UpdateSettings.intervalChoices + [shownInterval])).sorted()
    }

    static func intervalTitle(_ hours: Int) -> String {
        switch hours {
        case 1: "Every hour"
        case 24: "Daily"
        case 168: "Weekly"
        default: "Every \(hours) hours"
        }
    }

    @ViewBuilder
    private var status: some View {
        if updates.isInstalling {
            Text("Updating…").foregroundStyle(.secondary)
        } else if updates.isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        } else if let release = updates.available {
            HStack(spacing: 8) {
                Text("PRBar \(release.version.description) is available").foregroundStyle(Theme.blueText)
                Button("Update…") { model.openUpdateWindow() }.controlSize(.small)
            }
        } else if case .failed(let message)? = updates.lastManualOutcome {
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.redText)
                .fixedSize(horizontal: false, vertical: true)
        } else if case .upToDate? = updates.lastManualOutcome {
            Text("PRBar is up to date").foregroundStyle(.secondary)
        } else if let last = settings.lastCheckAt {
            let age = RelativeAge.short(from: last)
            Text(age == "now" ? "Checked just now" : "Last checked \(age) ago").foregroundStyle(.secondary)
        } else {
            Text("Not checked yet").foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 7: Agregar la sección en `Sources/PRBar/Settings/GeneralTab.swift`** — como última sección del `Form`, después de la de Notifications (justo antes del `}` que cierra el `Form` y precede a `.formStyle(.grouped)`):

```swift
            UpdatesSection(model: model, updates: model.updates, configStore: configStore)
```

- [ ] **Step 8: Compilar, correr la suite e instalar**

Run: `swift build && swift run PRBarTests && Scripts/bundle.sh --install`
Expected: build sin errores, `N/N passed`, `Instalado y abierto: ~/Applications/PRBar.app`.

- [ ] **Step 9: Mirarlo en la app**
- Settings › General: al final, **Updates** con "Installed version 0.1.0", "Check automatically" prendido, "Frequency: Daily". "Check for Updates" → mientras no haya releases públicos dice "PRBar is up to date" (404 = sin releases).
- Apagar "Check automatically" → el selector queda deshabilitado; `~/Library/Application Support/PRBar/config.json` tiene `"checkIntervalHours" : 0`. Volver a prenderlo → 24.
- El popover no muestra fila de actualización.

- [ ] **Step 10: Commit**

```bash
git add Sources/PRBar/Update/UpdateWindow.swift Sources/PRBar/Popover/UpdateRow.swift Sources/PRBar/Settings/UpdatesSection.swift \
  Sources/PRBar/AppModel+Updates.swift Sources/PRBar/AppModel.swift Sources/PRBar/Popover/PopoverView.swift Sources/PRBar/Settings/GeneralTab.swift
git commit -m "feat(app): show available updates and install them from a window"
```

---

### Task 13: Capturas (snapshot mode)

**Files:**
- Modify: `Sources/PRBar/Snapshots/SnapshotFixtures.swift` (al final), `Sources/PRBar/Snapshots/SnapshotMode.swift:64-91` (`renderAll`) y `:243-273` (`settings`)

- [ ] **Step 1: Release de ejemplo al final de `SnapshotFixtures.swift`**

```swift
extension SnapshotFixtures {
    /// Versión nueva ficticia para la ventana "Update PRBar" y Settings › General.
    static let updateRelease = ReleaseInfo(
        version: SemanticVersion(1, 3, 0), tag: "v1.3.0", title: "PRBar 1.3.0",
        notes: """
        - Chat with Claude in the Review and Respond windows
        - New `prbar` command-line tool
        - Faster refresh with many repos
        """,
        url: URL(string: "https://github.com/FedericoCharbonnier/PRBar/releases/tag/v1.3.0")!, publishedAt: nil
    )
}
```

- [ ] **Step 2: Captura `update` en `SnapshotMode.swift`**

En `renderAll()`, después de `try await notification()`:

```swift
        try await updateWindow()
```

Y en `// MARK: Screens`:

```swift
    private func updateWindow() async throws {
        let model = try makeModel("update", snapshot: fixtures.snapshot)
        model.updates.applySnapshotState(available: SnapshotFixtures.updateRelease)
        try await window("update", title: "Update PRBar", size: UpdateWindow.size) {
            UpdateWindow(updates: model.updates, mode: .available(SnapshotFixtures.updateRelease), close: {})
        }
    }
```

- [ ] **Step 3: Settings › General con la sección Updates**

En `settings()`, después de `let model = try makeModel("settings", snapshot: fixtures.snapshot)`:

```swift
        model.updates.applySnapshotState(available: SnapshotFixtures.updateRelease)
```

y en `sizes`, `.general: NSSize(width: 700, height: 940)` (antes 780) para que entre la sección nueva sin scroll.

- [ ] **Step 4: Generar y mirar**

Run: `Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both`
Expected: la lista incluye `update-light.png`, `update-dark.png`, `settings-general-light.png`, `settings-general-dark.png`. Abrir `update-*.png`: título "PRBar 1.3.0 is available", las tres notas, botones Skip This Version / Later / Update. En `settings-general-*`: sección Updates completa con "PRBar 1.3.0 is available" y "Update…".

- [ ] **Step 5: Actualizar las capturas del repo y commitear**

Run: `Scripts/snapshots.sh docs/screenshots both`

```bash
git add Sources/PRBar/Snapshots/SnapshotFixtures.swift Sources/PRBar/Snapshots/SnapshotMode.swift docs/screenshots
git commit -m "feat(snapshots): capture the update window and the updates settings"
```

---

### Task 14: QA manual, verificación final y primera release

**Files:**
- Create: `docs/qa/plan-8-checklist.md`

- [ ] **Step 1: Crear `docs/qa/plan-8-checklist.md`**

```markdown
# QA manual — Plan 8 (actualizaciones desde el repo)

Para probar una actualización real sin publicar nada nuevo: con el release `v1.0.0` ya publicado en
`FedericoCharbonnier/PRBar`, instalar una copia local con una versión menor (sección B).

## A. Versión y scripts
- [ ] `~/Applications/PRBar.app/Contents/MacOS/PRBar --version` → `PRBar <versión instalada>`, código 0, no abre la app.
- [ ] `Scripts/bundle.sh --output /tmp/prbar-out` arma `/tmp/prbar-out/PRBar.app` y no cierra la PRBar abierta.
- [ ] `Scripts/bundle.sh --bogus` → "Usage: …", código 2, sin compilar.
- [ ] `Scripts/release.sh --dry-run 9.9.9` → chequeos, notas, build y tests; cada paso que cambia algo aparece como
      `[dry-run] would run: …`; termina con "Dry run finished…"; `git status` y `git tag` no cambian.
- [ ] `Scripts/release.sh 0.0.1` → "must be greater than the current version", código 2.

## B. Chequeo
- [ ] Preparar: `/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.9.0" Resources/Info.plist`,
      `Scripts/bundle.sh --install`, `git checkout Resources/Info.plist`.
- [ ] Settings › General › Updates: "Installed version 0.9.0". "Check for Updates" → "PRBar 1.0.0 is available" y "Update…".
- [ ] El popover muestra al pie "PRBar 1.0.0 is available — Update…" con punto azul; click → ventana "Update PRBar" con las notas.
- [ ] Borrar `lastCheckAt` y `notifiedVersion` de `config.json`, salir y abrir PRBar → llega **una** notificación
      "PRBar 1.0.0 is available" con la primera línea de las notas; click → ventana "Update PRBar". Salir y abrir de
      nuevo → no se repite.
- [ ] Notificaciones apagadas en Settings → no hay notificación (y `notifiedVersion` sigue vacío).
- [ ] "Skip This Version" → la fila del popover desaparece; al reabrir PRBar no vuelve. "Check for Updates" a mano la
      muestra de nuevo (sin notificación). Borrar `skippedVersion` para seguir.
- [ ] Sin red (Wi-Fi apagado): "Check for Updates" muestra "Couldn't check for updates: …" en rojo; el chequeo
      automático solo lo deja en `~/Library/Logs/PRBar/prbar.log`.
- [ ] "Check automatically" apagado → `checkIntervalHours: 0`; prendido → 24; "Frequency" cambia el valor.
- [ ] Con `"updates": {"repo": "no/existe"}` → "Check for Updates" dice "PRBar is up to date" (404); con `"repo": "../x"`
      se usa el default (el pie de la sección dice github.com/FedericoCharbonnier/PRBar).

## C. Instalación
- [ ] "Update" → la ventana muestra "Downloading the source", "Building (takes a minute or two)" con el log, "Checking the
      new app", "Installing", "Restarting PRBar". PRBar se cierra y vuelve a abrir sola.
- [ ] Al volver: ventana "PRBar Updated" — "Updated to PRBar 1.0.0" con las notas; `~/Applications/PRBar.app.previous` ya no existe;
      `--version` dice `PRBar 1.0.0`. Config, historial, estado de Slack y token siguen (puede pedir permiso al Llavero una vez).
- [ ] `~/Library/Application Support/PRBar/source` es un clon con `HEAD` detached en el commit de `v1.0.0`
      (`git -C … rev-parse HEAD` = `git rev-parse v1.0.0` en el repo); `.git/hooks` no corrió nada; el checkout de
      desarrollo (`~/Documents/PRBar`) no cambió.
- [ ] `~/Library/Logs/PRBar/update.log` tiene el log completo; "Show Log" lo abre.
- [ ] Con un review corriendo: la ventana ofrece "Cancel Jobs and Update" y "Update When Done". "Update When Done" → "Waiting
      for 1 running job to finish…" y sigue sola al terminar. "Cancel Jobs and Update" → el review se cancela y sigue.
- [ ] Durante "Building", "Cancel" → vuelve a "Update", la app instalada no cambió. "Hide" cierra la ventana y el popover dice
      "Updating PRBar…".
- [ ] Falla de build (simular: `chmod -w ~/Library/Application\ Support/PRBar/source/Scripts` antes de actualizar, o cortar la red
      durante "Downloading") → error en rojo, "Show Log", "Try Again"; la app instalada sigue siendo la misma.
- [ ] PRBar.app copiada en una carpeta sin permiso de escritura → "PRBar can't replace itself in …".
- [ ] Corriendo con `swift run PRBar`: Settings dice que se puede chequear pero no instalar; "Update" está deshabilitado.
```

- [ ] **Step 2: Verificación final**

Run: `swift build && swift run PRBarTests && bash -n Scripts/bundle.sh && bash -n Scripts/release.sh`
Expected: build sin errores ni warnings nuevos, `N/N passed`, los `bash -n` sin salida.

Run: `git log --format='%B' main..HEAD | grep -i -E 'co-authored|claude|anthropic' || echo "sin atribuciones"`
Expected: `sin atribuciones`.

- [ ] **Step 3: Commit**

```bash
git add docs/qa/plan-8-checklist.md
git commit -m "docs(qa): add the manual checklist for updates"
```

- [ ] **Step 4: Primera release (la hace Federico a mano; el agente que ejecuta el plan NO la corre)**

Después de mergear la rama en `main` y pushear:

```bash
git checkout main && git pull
Scripts/release.sh --dry-run 1.0.0   # revisar notas y pasos
Scripts/release.sh 1.0.0             # abre $EDITOR con las notas; después commitea, taggea, pushea y crea el Release
```

Expected: `Released PRBar 1.0.0: https://github.com/FedericoCharbonnier/PRBar/releases/tag/v1.0.0`; el commit "Release v1.0.0" no tiene trailers; `Resources/Info.plist` queda en `1.0.0` / build `2`. Recién ahí se pueden correr las secciones B y C del checklist.

- [ ] **Step 5: Cerrar la rama** con superpowers:finishing-a-development-branch.
