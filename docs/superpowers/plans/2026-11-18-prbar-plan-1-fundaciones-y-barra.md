# PRBar — Plan 1: Fundaciones y barra de menú

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tener una app de barra de menú instalable (`PRBar.app`) que muestre el badge con las acciones pendientes, liste los PRs por categoría, se configure desde una ventana de Configuración y mande notificaciones push.

**Architecture:** Swift Package con tres targets:
- `PRBarCore`: toda la lógica, sin UI y testeable. Incluye modelos, clasificador, config, cliente de GitHub, snapshot y planificador de notificaciones.
- `PRBar`: la app SwiftUI. `MenuBarExtra(.window)` para el ícono y el popover; las ventanas AppKit se presentan con `NSHostingController`.
- `PRBarTests`: un runner de tests propio, porque las Command Line Tools no traen XCTest.

`Scripts/bundle.sh` arma y firma ad-hoc el `.app`.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, UserNotifications, ServiceManagement, GitHub GraphQL/REST API, `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-11-18-prbar-design.md`. **Diseño:** `docs/design/`.

**Fuera de este plan (Plan 2):** §8 flujo de review con Claude, §10 historial, notificación `reviewFinished` y limpieza de worktrees.

**Convenciones:**
- Todos los comandos corren desde `~/Documents/PRBar`.
- Los tests se corren con `swift run PRBarTests [filtro]`. El runner sale con código ≠ 0 si algo falla.
- Commits: mensajes en inglés, **sin** trailers `Co-Authored-By` (regla del usuario).
- Los textos de la UI van en español rioplatense.

---

## Estructura de archivos

```
Package.swift
.gitignore
Resources/Info.plist
Scripts/bundle.sh
Sources/PRBarCore/
  PRBarCore.swift          versión
  Models.swift             RepoRef, PullRequest, PRReview, PRComment, CIState, ReviewDecision, PRCategory, ClassifiedPR
  Support.swift            PRBarError, JSONCoding, AppPaths, AppLog
  ActionClassifier.swift   reglas §7 + FeedbackSummary
  Formatting.swift         RelativeAge, Initials, AvatarColor
  Config.swift             AppConfig y compañía + mutaciones
  ConfigStore.swift        persistencia de config.json
  ProcessRunner.swift      ProcessRunning, SystemProcessRunner
  ToolLocator.swift        encuentra gh/git/claude
  AccountProvider.swift    cuentas y tokens de gh
  RepoPathValidator.swift  valida la carpeta local contra el remote
  HTTPTransport.swift      HTTPTransport, URLSessionTransport
  GraphQLModels.swift      decodificación GraphQL → PullRequest
  GitHubClient.swift       GitHubAPI + implementación
  Snapshot.swift           Snapshot, SnapshotBuilder, SnapshotStore
  PRStore.swift            refresco periódico (ObservableObject)
  NotificationPlanner.swift
Sources/PRBar/
  PRBarApp.swift           @main
  AppModel.swift           cableado de dependencias
  Theme.swift              tokens de color y medidas
  BadgeIcon.swift          ícono template con badge
  WindowPresenter.swift    ventanas AppKit
  NotificationDelivery.swift
  LaunchAtLogin.swift
  Popover/PopoverView.swift
  Popover/PRRowView.swift
  Popover/Components.swift AvatarView, CIIcon, FeedbackLabel, SectionHeader, MessageView, ErrorBanner, CopyableCommand
  Settings/SettingsView.swift
  Settings/AccountsTab.swift
  Settings/ReposTab.swift
  Settings/UsersTab.swift
  Settings/GeneralTab.swift
Sources/PRBarTests/
  main.swift  TestKit.swift  Fixtures.swift  Fakes.swift
  SmokeTests.swift ModelsTests.swift ClassifierTests.swift FormattingTests.swift ConfigTests.swift
  ProcessTests.swift GitHubClientTests.swift SnapshotTests.swift NotificationPlannerTests.swift
```

---

### Task 1: Esqueleto del paquete y runner de tests

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/PRBarCore/PRBarCore.swift`, `Sources/PRBar/PRBarApp.swift`, `Sources/PRBarTests/TestKit.swift`, `Sources/PRBarTests/main.swift`, `Sources/PRBarTests/SmokeTests.swift`

- [ ] **Step 1: Crear `Package.swift`**

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PRBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PRBar", targets: ["PRBar"])],
    targets: [
        .target(name: "PRBarCore"),
        .executableTarget(name: "PRBar", dependencies: ["PRBarCore"]),
        .executableTarget(name: "PRBarTests", dependencies: ["PRBarCore"]),
    ]
)
```

- [ ] **Step 2: Crear `.gitignore`**

```
.build/
build/
.DS_Store
*.xcodeproj
.swiftpm/
```

- [ ] **Step 3: Crear `Sources/PRBarCore/PRBarCore.swift`**

```swift
public enum PRBarCore {
    public static let version = "0.1.0"
}
```

- [ ] **Step 4: Crear una app mínima en `Sources/PRBar/PRBarApp.swift`** (se reemplaza en la Task 9)

```swift
import SwiftUI

@main
struct PRBarApp: App {
    var body: some Scene {
        MenuBarExtra("PRBar", systemImage: "arrow.triangle.pull") {
            Text("PRBar").padding()
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 5: Crear `Sources/PRBarTests/TestKit.swift`**

```swift
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

struct TestCase {
    let name: String
    let body: () async throws -> Void

    init(_ name: String, _ body: @escaping () async throws -> Void) {
        self.name = name
        self.body = body
    }
}

func expect(
    _ condition: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #fileID, line: UInt = #line
) throws {
    if try !condition() {
        throw TestFailure(description: "\(file):\(line) expectation failed. \(message())")
    }
}

func expectEqual<T: Equatable>(
    _ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T,
    file: StaticString = #fileID, line: UInt = #line
) throws {
    let a = try actual()
    let e = try expected()
    if a != e {
        throw TestFailure(description: "\(file):\(line) expected \(e), got \(a)")
    }
}

func expectThrows(
    file: StaticString = #fileID, line: UInt = #line,
    _ body: () async throws -> Void
) async throws -> Error {
    do {
        try await body()
    } catch {
        return error
    }
    throw TestFailure(description: "\(file):\(line) expected an error, none thrown")
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
```

- [ ] **Step 6: Crear `Sources/PRBarTests/SmokeTests.swift`**

```swift
import PRBarCore

enum SmokeTests {
    static let cases: [TestCase] = [
        TestCase("smoke: versión del core") {
            try expectEqual(PRBarCore.version, "0.1.0")
        },
    ]
}
```

- [ ] **Step 7: Crear `Sources/PRBarTests/main.swift`**

```swift
import Foundation

let allTests: [TestCase] = []
    + SmokeTests.cases

let filter = CommandLine.arguments.dropFirst().first
let selected = allTests.filter { test in
    guard let filter else { return true }
    return test.name.localizedCaseInsensitiveContains(filter)
}

var failures = 0
for test in selected {
    do {
        try await test.body()
        print("✓ \(test.name)")
    } catch {
        failures += 1
        print("✗ \(test.name)\n    \(error)")
    }
}
print("\n\(selected.count - failures)/\(selected.count) passed")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 8: Correr los tests**

Run: `swift run PRBarTests`
Expected: `✓ smoke: versión del core` y `1/1 passed`.

- [ ] **Step 9: Verificar que la app compila**

Run: `swift build --product PRBar`
Expected: `Build complete!`

- [ ] **Step 10: Commit**

```bash
git add Package.swift .gitignore Sources
git commit -m "chore: scaffold Swift package with core, app and test runner targets"
```

---

### Task 2: Modelos y soporte (errores, JSON, rutas, log)

**Files:**
- Create: `Sources/PRBarCore/Models.swift`, `Sources/PRBarCore/Support.swift`, `Sources/PRBarTests/Fixtures.swift`, `Sources/PRBarTests/ModelsTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Crear `Sources/PRBarTests/Fixtures.swift`**

```swift
import Foundation
import PRBarCore

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func at(_ minutes: Int) -> Date {
    t0.addingTimeInterval(TimeInterval(minutes * 60))
}

func review(_ author: String, _ state: ReviewState, at minutes: Int, bot: Bool = false) -> PRReview {
    PRReview(author: author, isBot: bot, state: state, submittedAt: at(minutes))
}

func comment(_ author: String, at minutes: Int, bot: Bool = false) -> PRComment {
    PRComment(author: author, isBot: bot, createdAt: at(minutes))
}

func makePR(
    repo: RepoRef = RepoRef(owner: "o", name: "r"),
    number: Int = 1,
    author: String = "juan",
    isDraft: Bool = false,
    base: String = "develop",
    lastCommit: Int = 0,
    ci: CIState = .success,
    decision: ReviewDecision = .none,
    reviews: [PRReview] = [],
    comments: [PRComment] = [],
    requested: [String] = [],
    updated: Int = 0
) -> PullRequest {
    PullRequest(
        repo: repo, number: number, title: "PR \(number)",
        url: URL(string: "https://github.com/\(repo.fullName)/pull/\(number)")!,
        isDraft: isDraft, author: author, authorAvatarURL: nil,
        baseRef: base, headRef: "feature/\(number)", headOid: "abc\(number)",
        additions: 10, deletions: 2,
        createdAt: at(-60), updatedAt: at(updated), lastCommitAt: at(lastCommit),
        ciState: ci, reviewDecision: decision,
        reviews: reviews, comments: comments, requestedReviewers: requested
    )
}
```

- [ ] **Step 2: Escribir los tests en `Sources/PRBarTests/ModelsTests.swift`**

```swift
import Foundation
import PRBarCore

enum ModelsTests {
    static let cases: [TestCase] = [
        TestCase("models: categorías ordenadas por prioridad") {
            try expectEqual(PRCategory.allCases.shuffled().sorted(), [.toReview, .updatedSinceMyReview, .myFeedback, .other])
            try expect(PRCategory.toReview.countsForBadge)
            try expect(PRCategory.myFeedback.countsForBadge)
            try expect(!PRCategory.other.countsForBadge)
        },
        TestCase("models: id del PR es owner/repo#número") {
            try expectEqual(makePR(number: 42).id, "o/r#42")
        },
        TestCase("models: ClassifiedPR sobrevive un round-trip JSON") {
            let item = ClassifiedPR(pr: makePR(reviews: [review("ana", .approved, at: 5)]), category: .toReview, account: "me")
            let data = try JSONCoding.encoder.encode(item)
            try expectEqual(try JSONCoding.decoder.decode(ClassifiedPR.self, from: data), item)
        },
        TestCase("models: PRBarError tiene mensajes en español") {
            try expect(PRBarError.unauthorized.localizedDescription.contains("gh auth login"))
            try expect(PRBarError.toolNotFound("claude").localizedDescription.contains("claude"))
        },
    ]
}
```

- [ ] **Step 3: Registrar los tests en `main.swift`**

Reemplazar la definición de `allTests` por:

```swift
let allTests: [TestCase] = []
    + SmokeTests.cases
    + ModelsTests.cases
```

- [ ] **Step 4: Correr los tests y verificar que fallan**

Run: `swift run PRBarTests models`
Expected: error de compilación (`cannot find 'PRCategory' in scope`).

- [ ] **Step 5: Crear `Sources/PRBarCore/Models.swift`**

```swift
import Foundation

public struct RepoRef: Hashable, Codable, Sendable, Identifiable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public var fullName: String { "\(owner)/\(name)" }
    public var id: String { fullName }
}

public enum ReviewState: String, Codable, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case commented = "COMMENTED"
    case dismissed = "DISMISSED"
    case pending = "PENDING"
}

public struct PRReview: Hashable, Codable, Sendable {
    public let author: String
    public let isBot: Bool
    public let state: ReviewState
    public let submittedAt: Date

    public init(author: String, isBot: Bool, state: ReviewState, submittedAt: Date) {
        self.author = author
        self.isBot = isBot
        self.state = state
        self.submittedAt = submittedAt
    }
}

public struct PRComment: Hashable, Codable, Sendable {
    public let author: String
    public let isBot: Bool
    public let createdAt: Date

    public init(author: String, isBot: Bool, createdAt: Date) {
        self.author = author
        self.isBot = isBot
        self.createdAt = createdAt
    }
}

public enum CIState: String, Codable, Sendable {
    case success, failure, pending, none
}

public enum ReviewDecision: String, Codable, Sendable {
    case approved, changesRequested, reviewRequired, none
}

public struct PullRequest: Hashable, Codable, Sendable, Identifiable {
    public let repo: RepoRef
    public let number: Int
    public let title: String
    public let url: URL
    public let isDraft: Bool
    public let author: String
    public let authorAvatarURL: URL?
    public let baseRef: String
    public let headRef: String
    public let headOid: String
    public let additions: Int
    public let deletions: Int
    public let createdAt: Date
    public let updatedAt: Date
    /// Fecha del último commit; se usa como aproximación del "último push" (spec §6).
    public let lastCommitAt: Date
    public let ciState: CIState
    public let reviewDecision: ReviewDecision
    public let reviews: [PRReview]
    public let comments: [PRComment]
    public let requestedReviewers: [String]

    public init(
        repo: RepoRef, number: Int, title: String, url: URL, isDraft: Bool,
        author: String, authorAvatarURL: URL?, baseRef: String, headRef: String, headOid: String,
        additions: Int, deletions: Int, createdAt: Date, updatedAt: Date, lastCommitAt: Date,
        ciState: CIState, reviewDecision: ReviewDecision,
        reviews: [PRReview], comments: [PRComment], requestedReviewers: [String]
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.author = author
        self.authorAvatarURL = authorAvatarURL
        self.baseRef = baseRef
        self.headRef = headRef
        self.headOid = headOid
        self.additions = additions
        self.deletions = deletions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCommitAt = lastCommitAt
        self.ciState = ciState
        self.reviewDecision = reviewDecision
        self.reviews = reviews
        self.comments = comments
        self.requestedReviewers = requestedReviewers
    }

    public var id: String { "\(repo.fullName)#\(number)" }
}

public enum PRCategory: String, Codable, Sendable, CaseIterable, Comparable, Identifiable {
    case toReview, updatedSinceMyReview, myFeedback, other

    public var id: String { rawValue }
    public var countsForBadge: Bool { self != .other }

    public var title: String {
        switch self {
        case .toReview: "Para revisar"
        case .updatedSinceMyReview: "Actualizados desde mi review"
        case .myFeedback: "Mis PRs con feedback"
        case .other: "Otros"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self)! }

    public static func < (lhs: PRCategory, rhs: PRCategory) -> Bool { lhs.order < rhs.order }
}

public struct ClassifiedPR: Hashable, Codable, Sendable, Identifiable {
    public let pr: PullRequest
    public let category: PRCategory
    /// Login de la cuenta de GitHub desde la que se vio este PR.
    public let account: String

    public init(pr: PullRequest, category: PRCategory, account: String) {
        self.pr = pr
        self.category = category
        self.account = account
    }

    public var id: String { pr.id }
}
```

- [ ] **Step 6: Crear `Sources/PRBarCore/Support.swift`**

```swift
import Foundation

public enum PRBarError: Error, Equatable, LocalizedError {
    case toolNotFound(String)
    case commandFailed(command: String, status: Int32, stderr: String)
    case unauthorized
    case rateLimited(resetAt: Date)
    case http(status: Int, message: String)
    case graphQL(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            "No se encontró `\(tool)`. Instalalo o configurá su ruta en Configuración → General."
        case .commandFailed(let command, let status, let stderr):
            "Falló `\(command)` (código \(status)): \(stderr)"
        case .unauthorized:
            "GitHub rechazó el token. Corré `gh auth login --hostname github.com`."
        case .rateLimited(let resetAt):
            "Se alcanzó el límite de la API de GitHub. Reintento a las \(resetAt.formatted(date: .omitted, time: .shortened))."
        case .http(let status, let message):
            "GitHub respondió \(status): \(message)"
        case .graphQL(let message):
            "Error de GitHub: \(message)"
        case .invalidResponse(let message):
            "Respuesta inesperada de GitHub: \(message)"
        }
    }
}

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum AppPaths {
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PRBar", isDirectory: true)
    }
    public static var configFile: URL { appSupport.appendingPathComponent("config.json") }
    public static var stateFile: URL { appSupport.appendingPathComponent("state.json") }
    public static var logFile: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/PRBar/prbar.log")
    }
}

public enum AppLog {
    public static func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let url = AppPaths.logFile
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: url)
            }
        } catch {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
```

- [ ] **Step 7: Correr los tests y verificar que pasan**

Run: `swift run PRBarTests models`
Expected: 4 tests `✓` y `4/4 passed`.

- [ ] **Step 8: Commit**

```bash
git add Sources
git commit -m "feat(core): add PR models, errors and support utilities"
```

---

### Task 3: Clasificador de acciones y formateo

**Files:**
- Create: `Sources/PRBarCore/ActionClassifier.swift`, `Sources/PRBarCore/Formatting.swift`, `Sources/PRBarTests/ClassifierTests.swift`, `Sources/PRBarTests/FormattingTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

Reglas (spec §7, con un agregado): si `yo` estoy en `requestedReviewers`, el PR va a *Para revisar* aunque ya lo haya revisado. Eso pasa cuando el autor vuelve a pedir review. Los comentarios y reviews de bots nunca cuentan como feedback.

- [ ] **Step 1: Escribir `Sources/PRBarTests/ClassifierTests.swift`**

```swift
import Foundation
import PRBarCore

private func classify(_ pr: PullRequest, me: String = "me", watching: Set<String> = ["juan"]) -> PRCategory? {
    ActionClassifier.classify(pr, me: me, watchedUsers: watching)
}

enum ClassifierTests {
    static let cases: [TestCase] = [
        TestCase("classifier: autor no seguido y sin pedido de review → irrelevante") {
            try expectEqual(classify(makePR(author: "otro")), nil)
        },
        TestCase("classifier: autor seguido sin review mía → para revisar") {
            try expectEqual(classify(makePR()), .toReview)
        },
        TestCase("classifier: review pedida aunque no siga al autor → para revisar") {
            try expectEqual(classify(makePR(author: "otro", requested: ["me"])), .toReview)
        },
        TestCase("classifier: draft → otros") {
            try expectEqual(classify(makePR(isDraft: true)), .other)
        },
        TestCase("classifier: draft con review pedida → otros") {
            try expectEqual(classify(makePR(isDraft: true, requested: ["me"])), .other)
        },
        TestCase("classifier: aprobado y sin commits nuevos → otros") {
            try expectEqual(classify(makePR(lastCommit: 0, reviews: [review("me", .approved, at: 10)])), .other)
        },
        TestCase("classifier: aprobado y con commits nuevos → otros") {
            try expectEqual(classify(makePR(lastCommit: 20, reviews: [review("me", .approved, at: 10)])), .other)
        },
        TestCase("classifier: pedí cambios y hubo commit después → actualizado") {
            try expectEqual(classify(makePR(lastCommit: 20, reviews: [review("me", .changesRequested, at: 10)])), .updatedSinceMyReview)
        },
        TestCase("classifier: pedí cambios y no hubo commit después → otros") {
            try expectEqual(classify(makePR(lastCommit: 5, reviews: [review("me", .changesRequested, at: 10)])), .other)
        },
        TestCase("classifier: comenté y hubo commit después → actualizado") {
            try expectEqual(classify(makePR(lastCommit: 20, reviews: [review("me", .commented, at: 10)])), .updatedSinceMyReview)
        },
        TestCase("classifier: gana mi última review") {
            let pr = makePR(lastCommit: 20, reviews: [review("me", .changesRequested, at: 10), review("me", .approved, at: 30)])
            try expectEqual(classify(pr), .other)
        },
        TestCase("classifier: reviews pendientes o descartadas no cuentan") {
            let pr = makePR(reviews: [review("me", .pending, at: 10), review("me", .dismissed, at: 11)])
            try expectEqual(classify(pr), .toReview)
        },
        TestCase("classifier: me vuelven a pedir review después de aprobar → para revisar") {
            let pr = makePR(lastCommit: 20, reviews: [review("me", .approved, at: 10)], requested: ["me"])
            try expectEqual(classify(pr), .toReview)
        },
        TestCase("classifier: logins sin distinguir mayúsculas") {
            let pr = makePR(author: "Juan", lastCommit: 20, reviews: [review("ME", .changesRequested, at: 10)])
            try expectEqual(classify(pr, me: "me", watching: ["JUAN"]), .updatedSinceMyReview)
        },
        TestCase("classifier: mi PR con cambios pedidos después del último commit → feedback") {
            let pr = makePR(author: "me", lastCommit: 0, reviews: [review("ana", .changesRequested, at: 5)])
            try expectEqual(classify(pr), .myFeedback)
            try expectEqual(ActionClassifier.newFeedback(pr, me: "me"), FeedbackSummary(changesRequested: true, count: 1))
        },
        TestCase("classifier: mi PR con comentario de otro después del commit → feedback") {
            let pr = makePR(author: "me", lastCommit: 0, comments: [comment("ana", at: 3), comment("leo", at: 4)])
            try expectEqual(classify(pr), .myFeedback)
            try expectEqual(ActionClassifier.newFeedback(pr, me: "me"), FeedbackSummary(changesRequested: false, count: 2))
        },
        TestCase("classifier: mi PR con feedback anterior al último commit → otros") {
            let pr = makePR(author: "me", lastCommit: 10, reviews: [review("ana", .changesRequested, at: 5)], comments: [comment("ana", at: 6)])
            try expectEqual(classify(pr), .other)
        },
        TestCase("classifier: mis propios comentarios no son feedback") {
            try expectEqual(classify(makePR(author: "me", lastCommit: 0, comments: [comment("me", at: 5)])), .other)
        },
        TestCase("classifier: comentarios de bots no son feedback") {
            try expectEqual(classify(makePR(author: "me", lastCommit: 0, comments: [comment("codecov", at: 5, bot: true)])), .other)
        },
        TestCase("classifier: una aprobación no es feedback") {
            try expectEqual(classify(makePR(author: "me", lastCommit: 0, reviews: [review("ana", .approved, at: 5)])), .other)
        },
    ]
}
```

- [ ] **Step 2: Escribir `Sources/PRBarTests/FormattingTests.swift`**

```swift
import Foundation
import PRBarCore

enum FormattingTests {
    static let cases: [TestCase] = [
        TestCase("formatting: antigüedad corta") {
            try expectEqual(RelativeAge.short(from: t0.addingTimeInterval(-30), now: t0), "ahora")
            try expectEqual(RelativeAge.short(from: at(-40), now: t0), "40 min")
            try expectEqual(RelativeAge.short(from: at(-180), now: t0), "3h")
            try expectEqual(RelativeAge.short(from: at(-60 * 50), now: t0), "2d")
        },
        TestCase("formatting: iniciales") {
            try expectEqual(Initials.of("juanperez"), "JU")
            try expectEqual(Initials.of("sofia-r"), "SR")
            try expectEqual(Initials.of("nico_g"), "NG")
            try expectEqual(Initials.of("x"), "X")
            try expectEqual(Initials.of(""), "?")
        },
        TestCase("formatting: color de avatar estable y en rango") {
            let a = AvatarColor.index(for: "juanperez", paletteCount: 7)
            try expectEqual(AvatarColor.index(for: "juanperez", paletteCount: 7), a)
            try expect((0..<7).contains(a))
        },
    ]
}
```

- [ ] **Step 3: Registrar los tests en `main.swift`**

```swift
let allTests: [TestCase] = []
    + SmokeTests.cases
    + ModelsTests.cases
    + ClassifierTests.cases
    + FormattingTests.cases
```

- [ ] **Step 4: Correr los tests y verificar que fallan**

Run: `swift run PRBarTests classifier`
Expected: error de compilación (`cannot find 'ActionClassifier' in scope`).

- [ ] **Step 5: Crear `Sources/PRBarCore/ActionClassifier.swift`**

```swift
import Foundation

public struct FeedbackSummary: Equatable, Sendable {
    public let changesRequested: Bool
    public let count: Int

    public init(changesRequested: Bool, count: Int) {
        self.changesRequested = changesRequested
        self.count = count
    }

    public var isEmpty: Bool { count == 0 }
}

public enum ActionClassifier {
    /// Devuelve la categoría del PR para la cuenta `me`, o `nil` si el PR no es relevante (spec §7).
    public static func classify(_ pr: PullRequest, me: String, watchedUsers: Set<String>) -> PRCategory? {
        let me = me.lowercased()
        let author = pr.author.lowercased()

        if author == me {
            return newFeedback(pr, me: me).isEmpty ? .other : .myFeedback
        }

        let watched = Set(watchedUsers.map { $0.lowercased() })
        let requested = pr.requestedReviewers.contains { $0.lowercased() == me }
        guard watched.contains(author) || requested else { return nil }

        if pr.isDraft { return .other }
        if requested { return .toReview }

        let myReviews = pr.reviews.filter {
            $0.author.lowercased() == me && [.approved, .changesRequested, .commented].contains($0.state)
        }
        guard let last = myReviews.max(by: { $0.submittedAt < $1.submittedAt }) else {
            return .toReview
        }
        if last.state != .approved && pr.lastCommitAt > last.submittedAt {
            return .updatedSinceMyReview
        }
        return .other
    }

    /// Reviews (cambios pedidos o comentarios) y comentarios de otras personas posteriores al último commit.
    public static func newFeedback(_ pr: PullRequest, me: String) -> FeedbackSummary {
        let me = me.lowercased()
        let reviews = pr.reviews.filter {
            !$0.isBot && $0.author.lowercased() != me
                && ($0.state == .changesRequested || $0.state == .commented)
                && $0.submittedAt > pr.lastCommitAt
        }
        let comments = pr.comments.filter {
            !$0.isBot && $0.author.lowercased() != me && $0.createdAt > pr.lastCommitAt
        }
        return FeedbackSummary(
            changesRequested: reviews.contains { $0.state == .changesRequested },
            count: reviews.count + comments.count
        )
    }
}
```

- [ ] **Step 6: Crear `Sources/PRBarCore/Formatting.swift`**

```swift
import Foundation

public enum RelativeAge {
    /// "ahora", "40 min", "3h", "2d".
    public static func short(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "ahora"
        case ..<3600: return "\(seconds / 60) min"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

public enum Initials {
    public static func of(_ login: String) -> String {
        let parts = login.split(whereSeparator: { "-_.".contains($0) })
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        let letters = login.prefix(2).uppercased()
        return letters.isEmpty ? "?" : letters
    }
}

public enum AvatarColor {
    public static func index(for login: String, paletteCount: Int) -> Int {
        guard paletteCount > 0 else { return 0 }
        let sum = login.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return sum % paletteCount
    }
}
```

- [ ] **Step 7: Correr los tests y verificar que pasan**

Run: `swift run PRBarTests`
Expected: todos `✓` (28 tests).

- [ ] **Step 8: Commit**

```bash
git add Sources
git commit -m "feat(core): classify PRs into action categories and add formatting helpers"
```

---

### Task 4: Configuración y ConfigStore

**Files:**
- Create: `Sources/PRBarCore/Config.swift`, `Sources/PRBarCore/ConfigStore.swift`, `Sources/PRBarTests/ConfigTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir `Sources/PRBarTests/ConfigTests.swift`**

```swift
import Foundation
import PRBarCore

enum ConfigTests {
    static let cases: [TestCase] = [
        TestCase("config: archivo inexistente → valores por defecto") {
            let dir = try temporaryDirectory()
            let store = await ConfigStore(fileURL: dir.appendingPathComponent("config.json"))
            let config = await store.config
            try expectEqual(config, AppConfig())
            try expectEqual(config.refreshIntervalMinutes, 2)
            try expect(config.notifications.enabled && config.notifications.myPRApprovedOrCIFailed)
            try expectEqual(await store.loadError, nil)
        },
        TestCase("config: JSON parcial completa los faltantes con defaults") {
            let json = #"{"accounts":[{"login":"me","repos":[{"owner":"o","name":"r"}]}],"notifications":{"enabled":false}}"#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expectEqual(config.accounts[0].enabled, true)
            try expectEqual(config.accounts[0].watchedUsers, [])
            try expectEqual(config.accounts[0].repos[0].baseBranches, [])
            try expectEqual(config.accounts[0].repos[0].localPath, nil)
            try expectEqual(config.notifications.enabled, false)
            try expectEqual(config.notifications.newToReview, true)
            try expectEqual(config.refreshIntervalMinutes, 2)
        },
        TestCase("config: update persiste y se vuelve a leer igual") {
            let url = try temporaryDirectory().appendingPathComponent("config.json")
            let store = await ConfigStore(fileURL: url)
            try await store.update { $0.setAccountEnabled("me", true); $0.refreshIntervalMinutes = 5 }
            let reloaded = await ConfigStore(fileURL: url)
            try expectEqual(await reloaded.config, await store.config)
            try expectEqual(await reloaded.config.refreshIntervalMinutes, 5)
        },
        TestCase("config: archivo corrupto → defaults, error visible y backup") {
            let url = try temporaryDirectory().appendingPathComponent("config.json")
            try Data("{ no es json".utf8).write(to: url)
            let store = await ConfigStore(fileURL: url)
            try expectEqual(await store.config, AppConfig())
            try expect(await store.loadError != nil)
            try expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
        },
        TestCase("config: activar y desactivar cuentas") {
            var config = AppConfig()
            config.setAccountEnabled("me", false)
            try expectEqual(config.accounts.count, 0)
            config.setAccountEnabled("me", true)
            config.setAccountEnabled("me", false)
            try expectEqual(config.accounts.map(\.login), ["me"])
            try expectEqual(config.accounts[0].enabled, false)
        },
        TestCase("config: repos, carpeta local y ramas base") {
            var config = AppConfig()
            config.setAccountEnabled("me", true)
            let repo = RepoRef(owner: "o", name: "r")
            config.addRepo(repo, to: "me")
            config.addRepo(repo, to: "me")
            try expectEqual(config.accounts[0].repos.count, 1)
            config.setLocalPath("/tmp/r", repoID: "o/r", login: "me")
            config.toggleBaseBranch("develop", repoID: "o/r", login: "me")
            config.toggleBaseBranch("main", repoID: "o/r", login: "me")
            config.toggleBaseBranch("develop", repoID: "o/r", login: "me")
            try expectEqual(config.accounts[0].repos[0].localPath, "/tmp/r")
            try expectEqual(config.accounts[0].repos[0].baseBranches, ["main"])
            config.removeRepo("o/r", from: "me")
            try expectEqual(config.accounts[0].repos.count, 0)
        },
        TestCase("config: usuarios seguidos sin duplicados (sin distinguir mayúsculas)") {
            var config = AppConfig()
            config.setAccountEnabled("me", true)
            config.addWatchedUser("Juan", to: "me")
            config.addWatchedUser("juan", to: "me")
            config.addWatchedUser("ana", to: "me")
            try expectEqual(config.accounts[0].watchedUsers, ["Juan", "ana"])
            config.removeWatchedUser("JUAN", from: "me")
            try expectEqual(config.accounts[0].watchedUsers, ["ana"])
        },
    ]
}
```

- [ ] **Step 2: Registrar los tests en `main.swift`** (agregar `+ ConfigTests.cases` al final de `allTests`)

- [ ] **Step 3: Correr los tests y verificar que fallan**

Run: `swift run PRBarTests config`
Expected: error de compilación (`cannot find 'ConfigStore' in scope`).

- [ ] **Step 4: Crear `Sources/PRBarCore/Config.swift`**

```swift
import Foundation

public struct RepoConfig: Hashable, Codable, Sendable, Identifiable {
    public var owner: String
    public var name: String
    public var localPath: String?
    /// Vacío = la rama por defecto del repo.
    public var baseBranches: [String]

    public init(owner: String, name: String, localPath: String? = nil, baseBranches: [String] = []) {
        self.owner = owner
        self.name = name
        self.localPath = localPath
        self.baseBranches = baseBranches
    }

    public var repo: RepoRef { RepoRef(owner: owner, name: name) }
    public var id: String { repo.fullName }

    enum CodingKeys: String, CodingKey { case owner, name, localPath, baseBranches }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(String.self, forKey: .owner)
        name = try c.decode(String.self, forKey: .name)
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath)
        baseBranches = try c.decodeIfPresent([String].self, forKey: .baseBranches) ?? []
    }
}

public struct AccountConfig: Hashable, Codable, Sendable, Identifiable {
    public var login: String
    public var enabled: Bool
    public var watchedUsers: [String]
    public var repos: [RepoConfig]

    public init(login: String, enabled: Bool = true, watchedUsers: [String] = [], repos: [RepoConfig] = []) {
        self.login = login
        self.enabled = enabled
        self.watchedUsers = watchedUsers
        self.repos = repos
    }

    public var id: String { login }

    enum CodingKeys: String, CodingKey { case login, enabled, watchedUsers, repos }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        login = try c.decode(String.self, forKey: .login)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        watchedUsers = try c.decodeIfPresent([String].self, forKey: .watchedUsers) ?? []
        repos = try c.decodeIfPresent([RepoConfig].self, forKey: .repos) ?? []
    }
}

public struct NotificationSettings: Hashable, Codable, Sendable {
    public var enabled = true
    public var newToReview = true
    public var reviewedPRUpdated = true
    public var myPRFeedback = true
    public var reviewFinished = true
    public var myPRApprovedOrCIFailed = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, newToReview, reviewedPRUpdated, myPRFeedback, reviewFinished, myPRApprovedOrCIFailed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        newToReview = try c.decodeIfPresent(Bool.self, forKey: .newToReview) ?? true
        reviewedPRUpdated = try c.decodeIfPresent(Bool.self, forKey: .reviewedPRUpdated) ?? true
        myPRFeedback = try c.decodeIfPresent(Bool.self, forKey: .myPRFeedback) ?? true
        reviewFinished = try c.decodeIfPresent(Bool.self, forKey: .reviewFinished) ?? true
        myPRApprovedOrCIFailed = try c.decodeIfPresent(Bool.self, forKey: .myPRApprovedOrCIFailed) ?? true
    }
}

public struct ToolPaths: Hashable, Codable, Sendable {
    public var gh: String?
    public var git: String?
    public var claude: String?

    public init(gh: String? = nil, git: String? = nil, claude: String? = nil) {
        self.gh = gh
        self.git = git
        self.claude = claude
    }
}

public struct AppConfig: Hashable, Codable, Sendable {
    public var accounts: [AccountConfig] = []
    public var refreshIntervalMinutes = 2
    public var launchAtLogin = false
    public var notifications = NotificationSettings()
    public var toolPaths = ToolPaths()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case accounts, refreshIntervalMinutes, launchAtLogin, notifications, toolPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([AccountConfig].self, forKey: .accounts) ?? []
        refreshIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? 2
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        notifications = try c.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        toolPaths = try c.decodeIfPresent(ToolPaths.self, forKey: .toolPaths) ?? ToolPaths()
    }
}

// MARK: - Mutaciones usadas por la UI de Configuración

extension AppConfig {
    public mutating func setAccountEnabled(_ login: String, _ enabled: Bool) {
        if let index = accounts.firstIndex(where: { $0.login == login }) {
            accounts[index].enabled = enabled
        } else if enabled {
            accounts.append(AccountConfig(login: login))
        }
    }

    public mutating func addRepo(_ repo: RepoRef, to login: String) {
        withAccount(login) { account in
            guard !account.repos.contains(where: { $0.id == repo.fullName }) else { return }
            account.repos.append(RepoConfig(owner: repo.owner, name: repo.name))
        }
    }

    public mutating func removeRepo(_ repoID: String, from login: String) {
        withAccount(login) { $0.repos.removeAll { $0.id == repoID } }
    }

    public mutating func setLocalPath(_ path: String?, repoID: String, login: String) {
        withRepo(repoID, login: login) { $0.localPath = path }
    }

    public mutating func toggleBaseBranch(_ branch: String, repoID: String, login: String) {
        withRepo(repoID, login: login) { repo in
            if let index = repo.baseBranches.firstIndex(of: branch) {
                repo.baseBranches.remove(at: index)
            } else {
                repo.baseBranches.append(branch)
            }
        }
    }

    public mutating func addWatchedUser(_ user: String, to login: String) {
        withAccount(login) { account in
            guard !account.watchedUsers.contains(where: { $0.lowercased() == user.lowercased() }) else { return }
            account.watchedUsers.append(user)
        }
    }

    public mutating func removeWatchedUser(_ user: String, from login: String) {
        withAccount(login) { $0.watchedUsers.removeAll { $0.lowercased() == user.lowercased() } }
    }

    private mutating func withAccount(_ login: String, _ body: (inout AccountConfig) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.login == login }) else { return }
        body(&accounts[index])
    }

    private mutating func withRepo(_ repoID: String, login: String, _ body: (inout RepoConfig) -> Void) {
        withAccount(login) { account in
            guard let index = account.repos.firstIndex(where: { $0.id == repoID }) else { return }
            body(&account.repos[index])
        }
    }
}
```

- [ ] **Step 5: Crear `Sources/PRBarCore/ConfigStore.swift`**

```swift
import Foundation

@MainActor
public final class ConfigStore: ObservableObject {
    @Published public private(set) var config: AppConfig
    @Published public private(set) var loadError: String?
    private let fileURL: URL

    public init(fileURL: URL = AppPaths.configFile) {
        self.fileURL = fileURL
        let (config, error) = Self.loadOrRecover(fileURL)
        self.config = config
        self.loadError = error
        if let error { AppLog.write(error) }
    }

    public func update(_ mutate: (inout AppConfig) -> Void) throws {
        var next = config
        mutate(&next)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(next).write(to: fileURL, options: .atomic)
        config = next
    }

    private static func loadOrRecover(_ url: URL) -> (AppConfig, String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (AppConfig(), nil) }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONCoding.decoder.decode(AppConfig.self, from: data), nil)
        } catch {
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return (AppConfig(), "No se pudo leer config.json (\(error.localizedDescription)). Se guardó una copia en config.json.bak y se usan valores por defecto.")
        }
    }
}
```

- [ ] **Step 6: Correr los tests y verificar que pasan**

Run: `swift run PRBarTests`
Expected: todos `✓`.

- [ ] **Step 7: Commit**

```bash
git add Sources
git commit -m "feat(core): add app configuration model and persistent ConfigStore"
```

---

### Task 5: Procesos, herramientas, cuentas de `gh` y validación de carpeta

**Files:**
- Create: `Sources/PRBarCore/ProcessRunner.swift`, `Sources/PRBarCore/ToolLocator.swift`, `Sources/PRBarCore/AccountProvider.swift`, `Sources/PRBarCore/RepoPathValidator.swift`, `Sources/PRBarTests/Fakes.swift`, `Sources/PRBarTests/ProcessTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Crear `Sources/PRBarTests/Fakes.swift`**

```swift
import Foundation
import PRBarCore

final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    private(set) var calls: [(executable: String, arguments: [String])] = []
    private let handler: (String, [String]) -> ProcessResult

    init(_ handler: @escaping (String, [String]) -> ProcessResult) {
        self.handler = handler
    }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?) async throws -> ProcessResult {
        calls.append((executable, arguments))
        return handler(executable, arguments)
    }
}

/// Caja mutable para capturar valores desde closures en los tests.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

func ok(_ stdout: String) -> ProcessResult { ProcessResult(status: 0, stdout: stdout, stderr: "") }
func fail(_ stderr: String, status: Int32 = 1) -> ProcessResult { ProcessResult(status: status, stdout: "", stderr: stderr) }
```

- [ ] **Step 2: Escribir `Sources/PRBarTests/ProcessTests.swift`**

```swift
import Foundation
import PRBarCore

private let ghStatusOutput = """
github.com
  ✓ Logged in to github.com account dev-sam (keyring)
  - Active account: true
  - Git operations protocol: https
  - Token: gho_************************************

  ✓ Logged in to github.com account sam-personal (keyring)
  - Active account: false
  - Git operations protocol: https

  ✓ Logged in to github.com account acme-bot (keyring)
  - Active account: false
"""

enum ProcessTests {
    static let cases: [TestCase] = [
        TestCase("process: SystemProcessRunner captura stdout y código") {
            let result = try await SystemProcessRunner().run("/bin/echo", ["hola"])
            try expectEqual(result.status, 0)
            try expectEqual(result.stdout, "hola\n")
        },
        TestCase("process: SystemProcessRunner captura stderr y código de error") {
            let result = try await SystemProcessRunner().run("/bin/sh", ["-c", "echo err >&2; exit 3"])
            try expectEqual(result.status, 3)
            try expectEqual(result.stderr, "err\n")
        },
        TestCase("accounts: parsea gh auth status con varias cuentas") {
            let accounts = AccountProvider.parseStatus(ghStatusOutput)
            try expectEqual(accounts.map(\.login), ["dev-sam", "sam-personal", "acme-bot"])
            try expectEqual(accounts.map(\.isActive), [true, false, false])
        },
        TestCase("accounts: sin sesión → lista vacía") {
            try expectEqual(AccountProvider.parseStatus("You are not logged into any GitHub hosts. To log in, run: gh auth login"), [])
        },
        TestCase("accounts: listAccounts lee stdout y stderr") {
            let runner = FakeProcessRunner { _, _ in ProcessResult(status: 0, stdout: "", stderr: ghStatusOutput) }
            let provider = AccountProvider(runner: runner, ghPath: "/usr/local/bin/gh")
            try expectEqual(try await provider.listAccounts().count, 3)
            try expectEqual(runner.calls[0].arguments, ["auth", "status", "--hostname", "github.com"])
        },
        TestCase("accounts: token pide el de la cuenta indicada") {
            let runner = FakeProcessRunner { _, _ in ok("gho_abc\n") }
            let provider = AccountProvider(runner: runner, ghPath: "/usr/local/bin/gh")
            try expectEqual(try await provider.token(for: "acme-bot"), "gho_abc")
            try expectEqual(runner.calls[0].arguments, ["auth", "token", "--hostname", "github.com", "--user", "acme-bot"])
        },
        TestCase("accounts: token falla → commandFailed") {
            let provider = AccountProvider(runner: FakeProcessRunner { _, _ in fail("no account") }, ghPath: "/gh")
            let error = try await expectThrows { _ = try await provider.token(for: "x") }
            try expect(error as? PRBarError == .commandFailed(command: "gh auth token --user x", status: 1, stderr: "no account"))
        },
        TestCase("accounts: sin ruta de gh → toolNotFound") {
            let provider = AccountProvider(runner: FakeProcessRunner { _, _ in ok("") }, ghPath: nil)
            let error = try await expectThrows { _ = try await provider.token(for: "x") }
            try expect(error as? PRBarError == .toolNotFound("gh"))
        },
        TestCase("tools: usa la última línea de command -v") {
            let runner = FakeProcessRunner { _, _ in ok("ruido del profile\n/usr/local/bin/gh\n") }
            let locator = ToolLocator(runner: runner, home: "/Users/x", isExecutable: { $0 == "/usr/local/bin/gh" })
            try expectEqual(await locator.locate("gh", override: nil), "/usr/local/bin/gh")
            try expectEqual(runner.calls[0].arguments, ["-lc", "command -v gh"])
        },
        TestCase("tools: override no ejecutable → nil") {
            let locator = ToolLocator(runner: FakeProcessRunner { _, _ in ok("") }, home: "/Users/x", isExecutable: { _ in false })
            try expectEqual(await locator.locate("gh", override: "/nope/gh"), nil)
        },
        TestCase("tools: si el shell falla, prueba rutas conocidas") {
            let locator = ToolLocator(runner: FakeProcessRunner { _, _ in fail("") }, home: "/Users/x", isExecutable: { $0 == "/Users/x/.local/bin/claude" })
            try expectEqual(await locator.locate("claude", override: nil), "/Users/x/.local/bin/claude")
        },
        TestCase("repo path: reconoce remotes https y ssh") {
            let repo = RepoRef(owner: "Acme", name: "Web-App")
            try expect(RepoPathValidator.remoteMatches("origin\thttps://github.com/Acme/Web-App.git (fetch)\n", repo: repo))
            try expect(RepoPathValidator.remoteMatches("origin\tgit@github.com:acme/web-app.git (push)\n", repo: repo))
            try expect(!RepoPathValidator.remoteMatches("origin\thttps://github.com/Acme/Web-App-Admin.git (fetch)\n", repo: repo))
        },
        TestCase("repo path: carpeta que no es repo → mensaje de error") {
            let runner = FakeProcessRunner { _, _ in fail("fatal: not a git repository", status: 128) }
            let message = await RepoPathValidator.validate(path: "/tmp", repo: RepoRef(owner: "o", name: "r"), runner: runner, gitPath: "/usr/bin/git")
            try expectEqual(message, "La carpeta no es un repositorio git.")
            try expectEqual(runner.calls[0].arguments, ["-C", "/tmp", "remote", "-v"])
        },
    ]
}
```

- [ ] **Step 3: Registrar los tests en `main.swift`** (agregar `+ ProcessTests.cases`)

- [ ] **Step 4: Correr los tests y verificar que fallan**

Run: `swift run PRBarTests process`
Expected: error de compilación (`cannot find type 'ProcessRunning'`).

- [ ] **Step 5: Crear `Sources/PRBarCore/ProcessRunner.swift`**

```swift
import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?) async throws -> ProcessResult
}

extension ProcessRunning {
    public func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        try await run(executable, arguments, environment: nil, currentDirectory: nil)
    }
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        try process.run()
        async let outData = Self.readAll(out.fileHandleForReading)
        async let errData = Self.readAll(err.fileHandleForReading)
        let (stdout, stderr) = await (outData, errData)
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}
```

- [ ] **Step 6: Crear `Sources/PRBarCore/ToolLocator.swift`**

```swift
import Foundation

/// Encuentra `gh`, `git` y `claude`. Las apps de GUI no heredan el PATH del usuario (spec §3).
public struct ToolLocator: Sendable {
    private let runner: ProcessRunning
    private let home: String
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        runner: ProcessRunning,
        home: String = NSHomeDirectory(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.runner = runner
        self.home = home
        self.isExecutable = isExecutable
    }

    public func locate(_ tool: String, override: String?) async -> String? {
        if let override, !override.isEmpty {
            return isExecutable(override) ? override : nil
        }
        guard !tool.isEmpty, tool.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }

        if let result = try? await runner.run("/bin/zsh", ["-lc", "command -v \(tool)"]), result.status == 0 {
            let path = result.stdout
                .split(separator: "\n")
                .last
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if path.hasPrefix("/"), isExecutable(path) { return path }
        }
        return fallbackCandidates(for: tool).first(where: isExecutable)
    }

    private func fallbackCandidates(for tool: String) -> [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/.local/bin", "\(home)/.claude/local"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted(by: >).map { "\(nvm)/\($0)/bin" }
        }
        return dirs.map { "\($0)/\(tool)" }
    }
}
```

- [ ] **Step 7: Crear `Sources/PRBarCore/AccountProvider.swift`**

```swift
import Foundation

public struct GHAccount: Hashable, Sendable {
    public let login: String
    public var isActive: Bool

    public init(login: String, isActive: Bool) {
        self.login = login
        self.isActive = isActive
    }
}

public protocol TokenProviding: Sendable {
    func token(for login: String) async throws -> String
}

/// Lee cuentas y tokens de `gh`. Nunca guarda tokens (spec §3).
/// `ghPath` se asigna desde el main actor cuando se resuelven las herramientas y antes de empezar a refrescar.
public final class AccountProvider: TokenProviding, @unchecked Sendable {
    private let runner: ProcessRunning
    public var ghPath: String?

    public init(runner: ProcessRunning, ghPath: String?) {
        self.runner = runner
        self.ghPath = ghPath
    }

    public func listAccounts() async throws -> [GHAccount] {
        guard let ghPath else { throw PRBarError.toolNotFound("gh") }
        let result = try await runner.run(ghPath, ["auth", "status", "--hostname", "github.com"])
        return Self.parseStatus(result.stdout + "\n" + result.stderr)
    }

    public func token(for login: String) async throws -> String {
        guard let ghPath else { throw PRBarError.toolNotFound("gh") }
        let result = try await runner.run(ghPath, ["auth", "token", "--hostname", "github.com", "--user", login])
        guard result.status == 0 else {
            throw PRBarError.commandFailed(
                command: "gh auth token --user \(login)",
                status: result.status,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw PRBarError.unauthorized }
        return token
    }

    public static func parseStatus(_ text: String) -> [GHAccount] {
        var accounts: [GHAccount] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: "Logged in to github.com account ") {
                let login = line[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                if !login.isEmpty { accounts.append(GHAccount(login: login, isActive: false)) }
            } else if line.hasPrefix("- Active account: true"), !accounts.isEmpty {
                accounts[accounts.count - 1].isActive = true
            }
        }
        return accounts
    }
}
```

- [ ] **Step 8: Crear `Sources/PRBarCore/RepoPathValidator.swift`**

```swift
import Foundation

public enum RepoPathValidator {
    /// `true` si algún remote de `git remote -v` apunta a github.com/<owner>/<name> (https o ssh).
    public static func remoteMatches(_ remoteOutput: String, repo: RepoRef) -> Bool {
        let target = repo.fullName.lowercased()
        return remoteOutput.lowercased().split(separator: "\n").contains { line in
            for prefix in ["github.com/", "github.com:"] {
                guard let range = line.range(of: prefix) else { continue }
                var path = line[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                if path.hasSuffix(".git") { path.removeLast(4) }
                if path == target { return true }
            }
            return false
        }
    }

    /// Devuelve `nil` si la carpeta es válida o un mensaje de error para mostrar.
    public static func validate(path: String, repo: RepoRef, runner: ProcessRunning, gitPath: String) async -> String? {
        let result: ProcessResult
        do {
            result = try await runner.run(gitPath, ["-C", path, "remote", "-v"])
        } catch {
            return "No se pudo ejecutar git: \(error.localizedDescription)"
        }
        guard result.status == 0 else { return "La carpeta no es un repositorio git." }
        return remoteMatches(result.stdout, repo: repo) ? nil : "Ningún remote apunta a github.com/\(repo.fullName)."
    }
}
```

- [ ] **Step 9: Correr los tests y verificar que pasan**

Run: `swift run PRBarTests`
Expected: todos `✓`.

- [ ] **Step 10: Commit**

```bash
git add Sources
git commit -m "feat(core): run processes, locate tools, read gh accounts and validate repo folders"
```

---

### Task 6: Cliente de GitHub

**Files:**
- Create: `Sources/PRBarCore/HTTPTransport.swift`, `Sources/PRBarCore/GraphQLModels.swift`, `Sources/PRBarCore/GitHubClient.swift`, `Sources/PRBarTests/GitHubClientTests.swift`
- Modify: `Sources/PRBarTests/Fakes.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Agregar `FakeTransport` al final de `Sources/PRBarTests/Fakes.swift`**

```swift
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private var responses: [(status: Int, headers: [String: String], body: String)]

    init(_ responses: [(status: Int, headers: [String: String], body: String)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let next = responses.isEmpty ? (status: 500, headers: [:], body: "{}") : responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: next.headers)!
        return (Data(next.body.utf8), response)
    }

    func bodyString(_ index: Int) -> String {
        String(decoding: requests[index].httpBody ?? Data(), as: UTF8.self)
    }
}
```

- [ ] **Step 2: Escribir `Sources/PRBarTests/GitHubClientTests.swift`**

```swift
import Foundation
import PRBarCore

private let fullPage = """
{"data":{"repository":{"defaultBranchRef":{"name":"develop"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"number":482,"title":"Add rate limiting","url":"https://github.com/o/r/pull/482","isDraft":false,
  "createdAt":"2026-11-17T10:00:00Z","updatedAt":"2026-11-18T09:00:00Z","additions":214,"deletions":38,
  "baseRefName":"develop","headRefName":"feature/rate","headRefOid":"deadbeef","reviewDecision":"CHANGES_REQUESTED",
  "author":{"login":"juan","avatarUrl":"https://avatars.githubusercontent.com/u/1","__typename":"User"},
  "reviewRequests":{"nodes":[{"requestedReviewer":{"login":"me"}},{"requestedReviewer":{}}]},
  "reviews":{"nodes":[
    {"author":{"login":"ana","__typename":"User"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-17T12:00:00Z"},
    {"author":{"login":"me","__typename":"User"},"state":"PENDING","submittedAt":null}]},
  "comments":{"nodes":[
    {"author":{"login":"codecov","__typename":"Bot"},"createdAt":"2026-11-17T11:00:00Z"},
    {"author":null,"createdAt":"2026-11-17T11:30:00Z"}]},
  "commits":{"nodes":[{"commit":{"committedDate":"2026-11-18T08:00:00Z","statusCheckRollup":{"state":"FAILURE"}}}]}}
]}}}}
"""

private func minimalNode(_ number: Int) -> String {
    """
    {"number":\(number),"title":"PR \(number)","url":"https://github.com/o/r/pull/\(number)","isDraft":false,
     "createdAt":"2026-11-17T10:00:00Z","updatedAt":"2026-11-17T10:00:00Z","additions":1,"deletions":1,
     "baseRefName":"develop","headRefName":"f","headRefOid":"x","reviewDecision":null,
     "author":{"login":"juan","__typename":"User"},
     "reviewRequests":{"nodes":[]},"reviews":{"nodes":[]},"comments":{"nodes":[]},"commits":{"nodes":[]}}
    """
}

private func page(_ numbers: [Int], next: String?) -> String {
    let info = next.map { #"{"hasNextPage":true,"endCursor":"\#($0)"}"# } ?? #"{"hasNextPage":false,"endCursor":null}"#
    return #"{"data":{"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":\#(info),"nodes":[\#(numbers.map(minimalNode).joined(separator: ","))]}}}}"#
}

private let repo = RepoRef(owner: "o", name: "r")

enum GitHubClientTests {
    static let cases: [TestCase] = [
        TestCase("github: mapea un PR completo") {
            let transport = FakeTransport([(200, [:], fullPage)])
            let result = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "tok")
            try expectEqual(result.defaultBranch, "develop")
            try expectEqual(result.pullRequests.count, 1)
            let pr = result.pullRequests[0]
            try expectEqual(pr.id, "o/r#482")
            try expectEqual(pr.author, "juan")
            try expectEqual(pr.ciState, .failure)
            try expectEqual(pr.reviewDecision, .changesRequested)
            try expectEqual(pr.requestedReviewers, ["me"])
            try expectEqual(pr.reviews.map(\.author), ["ana"])
            try expectEqual(pr.comments.map(\.isBot), [true, false])
            try expectEqual(pr.comments[1].author, "ghost")
            try expectEqual(pr.lastCommitAt, ISO8601DateFormatter().date(from: "2026-11-18T08:00:00Z")!)
        },
        TestCase("github: manda el token y la query") {
            let transport = FakeTransport([(200, [:], page([1], next: nil))])
            _ = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "tok")
            try expectEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "bearer tok")
            try expectEqual(transport.requests[0].url?.absoluteString, "https://api.github.com/graphql")
            try expect(transport.bodyString(0).contains("pullRequests"))
        },
        TestCase("github: pagina hasta que no hay más") {
            let transport = FakeTransport([(200, [:], page([1, 2], next: "C1")), (200, [:], page([3], next: nil))])
            let result = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "tok")
            try expectEqual(result.pullRequests.map(\.number), [1, 2, 3])
            try expect(transport.bodyString(1).contains("C1"))
        },
        TestCase("github: 401 → unauthorized") {
            let transport = FakeTransport([(401, [:], #"{"message":"Bad credentials"}"#)])
            let error = try await expectThrows { _ = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "t") }
            try expect(error as? PRBarError == .unauthorized)
        },
        TestCase("github: 403 sin cupo → rateLimited con hora de reset") {
            let transport = FakeTransport([(403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000000"], "{}")])
            let error = try await expectThrows { _ = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "t") }
            try expect(error as? PRBarError == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_000)))
        },
        TestCase("github: errores GraphQL → graphQL") {
            let body = #"{"data":{"repository":null},"errors":[{"message":"Could not resolve to a Repository"}]}"#
            let error = try await expectThrows { _ = try await GitHubClient(transport: FakeTransport([(200, [:], body)])).openPullRequests(in: repo, token: "t") }
            try expect(error as? PRBarError == .graphQL("Could not resolve to a Repository"))
        },
        TestCase("github: usuario inexistente → nil") {
            let transport = FakeTransport([(404, [:], #"{"message":"Not Found"}"#)])
            try expectEqual(try await GitHubClient(transport: transport).user(login: "nadie", token: "t"), nil)
        },
        TestCase("github: login inválido no hace request") {
            let transport = FakeTransport([])
            try expectEqual(try await GitHubClient(transport: transport).user(login: "../etc", token: "t"), nil)
            try expectEqual(transport.requests.count, 0)
        },
        TestCase("github: ramas por REST") {
            let transport = FakeTransport([(200, [:], #"[{"name":"main"},{"name":"develop"}]"#)])
            try expectEqual(try await GitHubClient(transport: transport).branches(of: repo, token: "t"), ["main", "develop"])
            try expectEqual(transport.requests[0].url?.absoluteString, "https://api.github.com/repos/o/r/branches?per_page=100")
        },
    ]
}
```

- [ ] **Step 3: Registrar los tests en `main.swift`** (agregar `+ GitHubClientTests.cases`)

- [ ] **Step 4: Correr los tests y verificar que fallan**

Run: `swift run PRBarTests github`
Expected: error de compilación (`cannot find type 'HTTPTransport'`).

- [ ] **Step 5: Crear `Sources/PRBarCore/HTTPTransport.swift`**

```swift
import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PRBarError.invalidResponse("la respuesta no es HTTP")
        }
        return (data, http)
    }
}
```

- [ ] **Step 6: Crear `Sources/PRBarCore/GraphQLModels.swift`**

```swift
import Foundation

enum Queries {
    static let openPullRequests = """
    query($owner: String!, $name: String!, $cursor: String) {
      repository(owner: $owner, name: $name) {
        defaultBranchRef { name }
        pullRequests(states: OPEN, first: 50, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes {
            number title url isDraft createdAt updatedAt additions deletions
            baseRefName headRefName headRefOid reviewDecision
            author { login avatarUrl __typename }
            reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } } } }
            reviews(last: 50) { nodes { author { login __typename } state submittedAt } }
            comments(last: 50) { nodes { author { login __typename } createdAt } }
            commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
          }
        }
      }
    }
    """

    static let viewerRepositories = """
    query($cursor: String) {
      viewer {
        repositories(first: 100, after: $cursor, isArchived: false,
                     ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
                     orderBy: {field: PUSHED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes { name owner { login } }
        }
      }
    }
    """
}

struct GraphQLEnvelope<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLErrorItem]?
}

struct GraphQLErrorItem: Decodable {
    let message: String
}

struct Nodes<T: Decodable>: Decodable {
    let nodes: [T?]
}

struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

struct ActorNode: Decodable {
    let login: String
    let avatarUrl: URL?
    let typename: String?

    enum CodingKeys: String, CodingKey {
        case login, avatarUrl
        case typename = "__typename"
    }

    var isBot: Bool { typename == "Bot" }
}

struct PRQueryData: Decodable {
    struct Repository: Decodable {
        let defaultBranchRef: NameNode?
        let pullRequests: Connection
    }
    struct NameNode: Decodable { let name: String }
    struct Connection: Decodable {
        let pageInfo: PageInfo
        let nodes: [PRNode?]
    }
    let repository: Repository?
}

struct PRNode: Decodable {
    struct ReviewRequest: Decodable {
        struct Reviewer: Decodable { let login: String? }
        let requestedReviewer: Reviewer?
    }
    struct Review: Decodable {
        let author: ActorNode?
        let state: String
        let submittedAt: Date?
    }
    struct Comment: Decodable {
        let author: ActorNode?
        let createdAt: Date
    }
    struct CommitWrapper: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable { let state: String }
            let committedDate: Date
            let statusCheckRollup: Rollup?
        }
        let commit: Commit
    }

    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let additions: Int
    let deletions: Int
    let baseRefName: String
    let headRefName: String
    let headRefOid: String
    let reviewDecision: String?
    let author: ActorNode?
    let reviewRequests: Nodes<ReviewRequest>
    let reviews: Nodes<Review>
    let comments: Nodes<Comment>
    let commits: Nodes<CommitWrapper>

    func toPullRequest(repo: RepoRef) -> PullRequest {
        let commit = commits.nodes.compactMap { $0 }.last?.commit
        return PullRequest(
            repo: repo, number: number, title: title, url: url, isDraft: isDraft,
            author: author?.login ?? "ghost", authorAvatarURL: author?.avatarUrl,
            baseRef: baseRefName, headRef: headRefName, headOid: headRefOid,
            additions: additions, deletions: deletions,
            createdAt: createdAt, updatedAt: updatedAt,
            lastCommitAt: commit?.committedDate ?? createdAt,
            ciState: CIState(rollup: commit?.statusCheckRollup?.state),
            reviewDecision: ReviewDecision(graphQL: reviewDecision),
            reviews: reviews.nodes.compactMap { node in
                guard let node, let submittedAt = node.submittedAt, let state = ReviewState(rawValue: node.state) else { return nil }
                return PRReview(author: node.author?.login ?? "ghost", isBot: node.author?.isBot ?? false, state: state, submittedAt: submittedAt)
            },
            comments: comments.nodes.compactMap { node in
                guard let node else { return nil }
                return PRComment(author: node.author?.login ?? "ghost", isBot: node.author?.isBot ?? false, createdAt: node.createdAt)
            },
            requestedReviewers: reviewRequests.nodes.compactMap { $0?.requestedReviewer?.login }
        )
    }
}

struct ViewerReposData: Decodable {
    struct Viewer: Decodable { let repositories: Connection }
    struct Connection: Decodable {
        let pageInfo: PageInfo
        let nodes: [RepoNode?]
    }
    struct RepoNode: Decodable {
        struct Owner: Decodable { let login: String }
        let name: String
        let owner: Owner
    }
    let viewer: Viewer
}

extension CIState {
    init(rollup: String?) {
        switch rollup {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        case "PENDING", "EXPECTED": self = .pending
        default: self = .none
        }
    }
}

extension ReviewDecision {
    init(graphQL: String?) {
        switch graphQL {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .reviewRequired
        default: self = .none
        }
    }
}
```

- [ ] **Step 7: Crear `Sources/PRBarCore/GitHubClient.swift`**

```swift
import Foundation

public struct GitHubUser: Hashable, Codable, Sendable {
    public let login: String
    public let name: String?
    public let avatarURL: URL?

    public init(login: String, name: String?, avatarURL: URL?) {
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }
}

public struct RepoPRs: Equatable, Sendable {
    public let defaultBranch: String
    public let pullRequests: [PullRequest]

    public init(defaultBranch: String, pullRequests: [PullRequest]) {
        self.defaultBranch = defaultBranch
        self.pullRequests = pullRequests
    }
}

public protocol GitHubAPI: Sendable {
    func openPullRequests(in repo: RepoRef, token: String) async throws -> RepoPRs
    func viewerRepositories(token: String) async throws -> [RepoRef]
    func branches(of repo: RepoRef, token: String) async throws -> [String]
    func user(login: String, token: String) async throws -> GitHubUser?
}

public struct GitHubClient: GitHubAPI {
    private let transport: HTTPTransport
    private static let maxPRPages = 4
    private static let maxRepoPages = 3

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func openPullRequests(in repo: RepoRef, token: String) async throws -> RepoPRs {
        var cursor: String?
        var pullRequests: [PullRequest] = []
        var defaultBranch = "main"
        for _ in 0..<Self.maxPRPages {
            let data: PRQueryData = try await graphQL(
                Queries.openPullRequests,
                variables: ["owner": repo.owner, "name": repo.name, "cursor": cursor],
                token: token
            )
            guard let repository = data.repository else {
                throw PRBarError.graphQL("No se encontró el repo \(repo.fullName)")
            }
            defaultBranch = repository.defaultBranchRef?.name ?? defaultBranch
            pullRequests += repository.pullRequests.nodes.compactMap { $0?.toPullRequest(repo: repo) }
            guard repository.pullRequests.pageInfo.hasNextPage, let next = repository.pullRequests.pageInfo.endCursor else { break }
            cursor = next
        }
        return RepoPRs(defaultBranch: defaultBranch, pullRequests: pullRequests)
    }

    public func viewerRepositories(token: String) async throws -> [RepoRef] {
        var cursor: String?
        var repos: [RepoRef] = []
        for _ in 0..<Self.maxRepoPages {
            let data: ViewerReposData = try await graphQL(Queries.viewerRepositories, variables: ["cursor": cursor], token: token)
            repos += data.viewer.repositories.nodes.compactMap { node in
                node.map { RepoRef(owner: $0.owner.login, name: $0.name) }
            }
            guard data.viewer.repositories.pageInfo.hasNextPage, let next = data.viewer.repositories.pageInfo.endCursor else { break }
            cursor = next
        }
        return repos
    }

    public func branches(of repo: RepoRef, token: String) async throws -> [String] {
        struct Branch: Decodable { let name: String }
        let data = try await restGET("/repos/\(repo.owner)/\(repo.name)/branches?per_page=100", token: token)
        do {
            return try JSONCoding.decoder.decode([Branch].self, from: data).map(\.name)
        } catch {
            throw PRBarError.invalidResponse("ramas: \(error)")
        }
    }

    public func user(login: String, token: String) async throws -> GitHubUser? {
        struct User: Decodable {
            let login: String
            let name: String?
            let avatar_url: URL?
        }
        guard !login.isEmpty, login.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        do {
            let data = try await restGET("/users/\(login)", token: token)
            let user = try JSONCoding.decoder.decode(User.self, from: data)
            return GitHubUser(login: user.login, name: user.name, avatarURL: user.avatar_url)
        } catch PRBarError.http(let status, _) where status == 404 {
            return nil
        }
    }

    // MARK: - HTTP

    private func graphQL<T: Decodable>(_ query: String, variables: [String: String?], token: String) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        applyHeaders(&request, token: token)
        let encodedVariables: [String: Any] = variables.mapValues { value -> Any in
            if let value { return value }
            return NSNull()
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": encodedVariables])

        let data = try await perform(request)
        let envelope: GraphQLEnvelope<T>
        do {
            envelope = try JSONCoding.decoder.decode(GraphQLEnvelope<T>.self, from: data)
        } catch {
            throw PRBarError.invalidResponse("GraphQL: \(error)")
        }
        if let errors = envelope.errors, !errors.isEmpty {
            throw PRBarError.graphQL(errors.map(\.message).joined(separator: "; "))
        }
        guard let payload = envelope.data else { throw PRBarError.invalidResponse("GraphQL sin data") }
        return payload
    }

    private func restGET(_ path: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        applyHeaders(&request, token: token)
        return try await perform(request)
    }

    private func applyHeaders(_ request: inout URLRequest, token: String) {
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PRBar", forHTTPHeaderField: "User-Agent")
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            throw PRBarError.unauthorized
        case 403, 429:
            if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0",
               let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap({ TimeInterval($0) }) {
                throw PRBarError.rateLimited(resetAt: Date(timeIntervalSince1970: reset))
            }
            throw PRBarError.http(status: response.statusCode, message: Self.errorMessage(from: data))
        default:
            throw PRBarError.http(status: response.statusCode, message: Self.errorMessage(from: data))
        }
    }

    private static func errorMessage(from data: Data) -> String {
        struct Body: Decodable { let message: String }
        if let body = try? JSONDecoder().decode(Body.self, from: data) { return body.message }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }
}
```

- [ ] **Step 8: Correr los tests y verificar que pasan**

Run: `swift run PRBarTests`
Expected: todos `✓`.

- [ ] **Step 9: Smoke test contra GitHub real (manual, lectura)**

Run:
```bash
swift run PRBarTests github
GH_TOKEN=$(gh auth token --user sam-personal) gh api graphql -f query='query{viewer{login}}'
```
Expected: los tests pasan y `gh api` devuelve `{"data":{"viewer":{"login":"sam-personal"}}}`. Esto confirma que el token sirve para GraphQL. La validación real del cliente se hace en la Task 12 con la app corriendo.

- [ ] **Step 10: Commit**

```bash
git add Sources
git commit -m "feat(core): add GitHub GraphQL/REST client with rate-limit and error mapping"
```

---

### Task 7: Snapshot, builder y PRStore

**Files:**
- Create: `Sources/PRBarCore/Snapshot.swift`, `Sources/PRBarCore/PRStore.swift`, `Sources/PRBarTests/SnapshotTests.swift`
- Modify: `Sources/PRBarTests/Fakes.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Agregar los fakes de API y tokens al final de `Sources/PRBarTests/Fakes.swift`**

```swift
struct FakeAPI: GitHubAPI {
    var prs: [String: Result<RepoPRs, PRBarError>] = [:]

    func openPullRequests(in repo: RepoRef, token: String) async throws -> RepoPRs {
        guard let result = prs[repo.fullName] else { throw PRBarError.http(status: 404, message: "not found") }
        return try result.get()
    }
    func viewerRepositories(token: String) async throws -> [RepoRef] { [] }
    func branches(of repo: RepoRef, token: String) async throws -> [String] { [] }
    func user(login: String, token: String) async throws -> GitHubUser? { nil }
}

struct FakeTokens: TokenProviding {
    var failing: Set<String> = []

    func token(for login: String) async throws -> String {
        if failing.contains(login) { throw PRBarError.unauthorized }
        return "tok-\(login)"
    }
}

func account(_ login: String, watching: [String] = ["juan"], bases: [String] = [], enabled: Bool = true) -> AccountConfig {
    AccountConfig(login: login, enabled: enabled, watchedUsers: watching, repos: [RepoConfig(owner: "o", name: "r", baseBranches: bases)])
}

func config(_ accounts: AccountConfig...) -> AppConfig {
    var config = AppConfig()
    config.accounts = accounts
    return config
}
```

- [ ] **Step 2: Escribir `Sources/PRBarTests/SnapshotTests.swift`**

```swift
import Foundation
import PRBarCore

private func builder(_ api: FakeAPI, tokens: FakeTokens = FakeTokens()) -> SnapshotBuilder {
    SnapshotBuilder(api: api, tokens: tokens, now: { t0 })
}

private func repoPRs(_ prs: PullRequest..., defaultBranch: String = "develop") -> Result<RepoPRs, PRBarError> {
    .success(RepoPRs(defaultBranch: defaultBranch, pullRequests: prs))
}

enum SnapshotTests {
    static let cases: [TestCase] = [
        TestCase("snapshot: sin ramas configuradas usa la rama por defecto") {
            let api = FakeAPI(prs: ["o/r": repoPRs(makePR(number: 1, base: "develop"), makePR(number: 2, base: "main"))])
            let snapshot = await builder(api).build(config: config(account("me")), previous: nil)
            try expectEqual(snapshot.items.map(\.id), ["o/r#1"])
            try expectEqual(snapshot.items[0].category, .toReview)
            try expectEqual(snapshot.badgeCount, 1)
        },
        TestCase("snapshot: ramas configuradas filtran") {
            let api = FakeAPI(prs: ["o/r": repoPRs(makePR(number: 1, base: "develop"), makePR(number: 2, base: "main"))])
            let snapshot = await builder(api).build(config: config(account("me", bases: ["main"])), previous: nil)
            try expectEqual(snapshot.items.map(\.id), ["o/r#2"])
        },
        TestCase("snapshot: un PR visto desde dos cuentas aparece una vez con la categoría más urgente") {
            let pr = makePR(number: 1, reviews: [review("a", .approved, at: 10)])
            let api = FakeAPI(prs: ["o/r": repoPRs(pr)])
            let snapshot = await builder(api).build(config: config(account("a"), account("b")), previous: nil)
            try expectEqual(snapshot.items.count, 1)
            try expectEqual(snapshot.items[0].category, .toReview)
            try expectEqual(snapshot.items[0].account, "b")
        },
        TestCase("snapshot: ordena por categoría y después por actualización") {
            let api = FakeAPI(prs: ["o/r": repoPRs(
                makePR(number: 1, updated: 1),
                makePR(number: 2, author: "me", lastCommit: 0, comments: [comment("ana", at: 5)], updated: 9),
                makePR(number: 3, updated: 5)
            )])
            let snapshot = await builder(api).build(config: config(account("me")), previous: nil)
            try expectEqual(snapshot.items.map(\.pr.number), [3, 1, 2])
        },
        TestCase("snapshot: cuentas desactivadas se ignoran") {
            let api = FakeAPI(prs: ["o/r": repoPRs(makePR())])
            let snapshot = await builder(api).build(config: config(account("me", enabled: false)), previous: nil)
            try expectEqual(snapshot.items, [])
            try expectEqual(snapshot.failedCompletely, false)
        },
        TestCase("snapshot: si falla el token se conserva lo anterior y se informa") {
            let previous = Snapshot(items: [ClassifiedPR(pr: makePR(), category: .toReview, account: "me")], fetchedAt: at(-14), errors: [])
            let snapshot = await builder(FakeAPI(), tokens: FakeTokens(failing: ["me"])).build(config: config(account("me")), previous: previous)
            try expectEqual(snapshot.items, previous.items)
            try expect(snapshot.errors.first?.hasPrefix("me:") == true)
            try expectEqual(snapshot.failedCompletely, true)
            try expectEqual(snapshot.fetchedAt, at(-14))
        },
        TestCase("snapshot: si falla un repo se conserva lo anterior de ese repo") {
            let previous = Snapshot(items: [ClassifiedPR(pr: makePR(), category: .toReview, account: "me")], fetchedAt: at(-5), errors: [])
            let api = FakeAPI(prs: ["o/r": .failure(.http(status: 502, message: "Bad gateway"))])
            let snapshot = await builder(api).build(config: config(account("me")), previous: previous)
            try expectEqual(snapshot.items, previous.items)
            try expect(snapshot.errors.first?.contains("o/r") == true)
        },
        TestCase("snapshot: rate limit queda registrado") {
            let reset = at(30)
            let api = FakeAPI(prs: ["o/r": .failure(.rateLimited(resetAt: reset))])
            let snapshot = await builder(api).build(config: config(account("me")), previous: nil)
            try expectEqual(snapshot.rateLimitedUntil, reset)
        },
        TestCase("snapshot: SnapshotStore guarda y lee") {
            let url = try temporaryDirectory().appendingPathComponent("state.json")
            let store = SnapshotStore(url: url)
            try expectEqual(store.load(), nil)
            let snapshot = Snapshot(items: [ClassifiedPR(pr: makePR(), category: .toReview, account: "me")], fetchedAt: t0, errors: ["x"])
            store.save(snapshot)
            try expectEqual(store.load(), snapshot)
        },
        TestCase("prstore: refresh publica, persiste y avisa con el snapshot anterior") {
            let url = try temporaryDirectory().appendingPathComponent("config.json")
            let configStore = await ConfigStore(fileURL: url)
            try await configStore.update { $0 = config(account("me")) }
            let stateStore = SnapshotStore(url: url.deletingLastPathComponent().appendingPathComponent("state.json"))
            let changes = Box<[(Snapshot?, Snapshot)]>([])
            let store = await PRStore(
                builder: builder(FakeAPI(prs: ["o/r": repoPRs(makePR())])),
                configStore: configStore, stateStore: stateStore, now: { t0 },
                onChange: { changes.value.append(($0, $1)) }
            )
            await store.refresh()
            await store.refresh()
            try expectEqual(changes.value.count, 2)
            try expectEqual(changes.value[0].0, nil)
            try expectEqual(changes.value[1].0?.items.count, 1)
            try expectEqual(await store.snapshot?.badgeCount, 1)
            try expectEqual(stateStore.load()?.items.count, 1)
        },
        TestCase("prstore: no refresca mientras dura el rate limit") {
            let url = try temporaryDirectory().appendingPathComponent("config.json")
            let configStore = await ConfigStore(fileURL: url)
            let stateStore = SnapshotStore(url: url.deletingLastPathComponent().appendingPathComponent("state.json"))
            stateStore.save(Snapshot(items: [], fetchedAt: t0, errors: [], rateLimitedUntil: at(10)))
            let calls = Box(0)
            let store = await PRStore(builder: builder(FakeAPI()), configStore: configStore, stateStore: stateStore, now: { t0 }, onChange: { _, _ in calls.value += 1 })
            await store.refresh()
            try expectEqual(calls.value, 0)
        },
    ]
}
```

- [ ] **Step 3: Registrar los tests en `main.swift`** (agregar `+ SnapshotTests.cases`)

- [ ] **Step 4: Correr los tests y verificar que fallan**

Run: `swift run PRBarTests snapshot`
Expected: error de compilación (`cannot find 'SnapshotBuilder' in scope`).

- [ ] **Step 5: Crear `Sources/PRBarCore/Snapshot.swift`**

```swift
import Foundation

public struct Snapshot: Codable, Equatable, Sendable {
    public var items: [ClassifiedPR]
    /// Fecha del último refresco con al menos una consulta exitosa.
    public var fetchedAt: Date
    public var errors: [String]
    /// `true` si fallaron todas las consultas: el popover muestra "Sin conexión".
    public var failedCompletely: Bool
    public var rateLimitedUntil: Date?

    public init(items: [ClassifiedPR], fetchedAt: Date, errors: [String], failedCompletely: Bool = false, rateLimitedUntil: Date? = nil) {
        self.items = items
        self.fetchedAt = fetchedAt
        self.errors = errors
        self.failedCompletely = failedCompletely
        self.rateLimitedUntil = rateLimitedUntil
    }

    public var badgeCount: Int { items.filter { $0.category.countsForBadge }.count }

    public func items(in category: PRCategory) -> [ClassifiedPR] {
        items.filter { $0.category == category }
    }
}

public struct SnapshotBuilder: Sendable {
    private let api: GitHubAPI
    private let tokens: TokenProviding
    private let now: @Sendable () -> Date

    public init(api: GitHubAPI, tokens: TokenProviding, now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.tokens = tokens
        self.now = now
    }

    public func build(config: AppConfig, previous: Snapshot?) async -> Snapshot {
        var collected: [ClassifiedPR] = []
        var errors: [String] = []
        var attempts = 0
        var successes = 0
        var rateLimitedUntil: Date?

        func record(_ error: Error, context: String) {
            errors.append("\(context): \(error.localizedDescription)")
            AppLog.write("Error al refrescar \(context): \(error)")
            if case PRBarError.rateLimited(let reset) = error {
                rateLimitedUntil = max(rateLimitedUntil ?? reset, reset)
            }
        }

        for account in config.accounts where account.enabled {
            attempts += 1
            let token: String
            do {
                token = try await tokens.token(for: account.login)
            } catch {
                record(error, context: account.login)
                collected += carryOver(previous, account: account.login, repo: nil)
                continue
            }
            for repoConfig in account.repos {
                attempts += 1
                do {
                    let result = try await api.openPullRequests(in: repoConfig.repo, token: token)
                    successes += 1
                    let bases = Set(repoConfig.baseBranches.isEmpty ? [result.defaultBranch] : repoConfig.baseBranches)
                    for pr in result.pullRequests where bases.contains(pr.baseRef) {
                        if let category = ActionClassifier.classify(pr, me: account.login, watchedUsers: Set(account.watchedUsers)) {
                            collected.append(ClassifiedPR(pr: pr, category: category, account: account.login))
                        }
                    }
                } catch {
                    record(error, context: "\(repoConfig.repo.fullName) (\(account.login))")
                    collected += carryOver(previous, account: account.login, repo: repoConfig.repo)
                }
            }
        }

        let failedCompletely = attempts > 0 && successes == 0
        return Snapshot(
            items: Self.dedupeAndSort(collected),
            fetchedAt: failedCompletely ? (previous?.fetchedAt ?? now()) : now(),
            errors: errors,
            failedCompletely: failedCompletely,
            rateLimitedUntil: rateLimitedUntil
        )
    }

    private func carryOver(_ previous: Snapshot?, account: String, repo: RepoRef?) -> [ClassifiedPR] {
        (previous?.items ?? []).filter { item in
            item.account == account && (repo == nil || item.pr.repo == repo)
        }
    }

    static func dedupeAndSort(_ items: [ClassifiedPR]) -> [ClassifiedPR] {
        var best: [String: ClassifiedPR] = [:]
        for item in items {
            if let current = best[item.id], current.category <= item.category { continue }
            best[item.id] = item
        }
        return best.values.sorted {
            $0.category != $1.category ? $0.category < $1.category : $0.pr.updatedAt > $1.pr.updatedAt
        }
    }
}

public struct SnapshotStore: Sendable {
    private let url: URL

    public init(url: URL = AppPaths.stateFile) {
        self.url = url
    }

    public func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONCoding.decoder.decode(Snapshot.self, from: data)
        } catch {
            AppLog.write("state.json ilegible, se ignora: \(error)")
            return nil
        }
    }

    public func save(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONCoding.encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            AppLog.write("No se pudo guardar state.json: \(error)")
        }
    }
}
```

- [ ] **Step 6: Crear `Sources/PRBarCore/PRStore.swift`**

```swift
import Foundation

@MainActor
public final class PRStore: ObservableObject {
    @Published public private(set) var snapshot: Snapshot?
    @Published public private(set) var isRefreshing = false

    private let builder: SnapshotBuilder
    private let configStore: ConfigStore
    private let stateStore: SnapshotStore
    private let now: () -> Date
    private let onChange: @MainActor (Snapshot?, Snapshot) -> Void
    private var loop: Task<Void, Never>?

    public init(
        builder: SnapshotBuilder,
        configStore: ConfigStore,
        stateStore: SnapshotStore = SnapshotStore(),
        now: @escaping () -> Date = { Date() },
        onChange: @escaping @MainActor (Snapshot?, Snapshot) -> Void
    ) {
        self.builder = builder
        self.configStore = configStore
        self.stateStore = stateStore
        self.now = now
        self.onChange = onChange
        self.snapshot = stateStore.load()
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        if let until = snapshot?.rateLimitedUntil, until > now() { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let previous = snapshot
        let next = await builder.build(config: configStore.config, previous: previous)
        snapshot = next
        stateStore.save(next)
        onChange(previous, next)
    }

    public func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let minutes = max(1, self.configStore.config.refreshIntervalMinutes)
                try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }
}
```

- [ ] **Step 7: Correr los tests y verificar que pasan**

Run: `swift run PRBarTests`
Expected: todos `✓`.

- [ ] **Step 8: Commit**

```bash
git add Sources
git commit -m "feat(core): build PR snapshots across accounts and refresh them periodically"
```

---

### Task 8: Planificador de notificaciones

**Files:**
- Create: `Sources/PRBarCore/NotificationPlanner.swift`, `Sources/PRBarTests/NotificationPlannerTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir `Sources/PRBarTests/NotificationPlannerTests.swift`**

```swift
import Foundation
import PRBarCore

private func snap(_ items: ClassifiedPR...) -> Snapshot {
    Snapshot(items: items, fetchedAt: t0, errors: [])
}

private func item(_ pr: PullRequest, _ category: PRCategory, account: String = "me") -> ClassifiedPR {
    ClassifiedPR(pr: pr, category: category, account: account)
}

enum NotificationPlannerTests {
    static let cases: [TestCase] = [
        TestCase("notif: primera ejecución no notifica") {
            try expectEqual(NotificationPlanner.plan(previous: nil, current: snap(item(makePR(), .toReview)), settings: NotificationSettings()), [])
        },
        TestCase("notif: PR que entra a Para revisar notifica") {
            let planned = NotificationPlanner.plan(previous: snap(), current: snap(item(makePR(number: 7), .toReview)), settings: NotificationSettings())
            try expectEqual(planned.map(\.kind), [.newToReview])
            try expectEqual(planned[0].title, "Nuevo PR para revisar")
            try expectEqual(planned[0].body, "r#7 · juan: PR 7")
            try expectEqual(planned[0].url?.absoluteString, "https://github.com/o/r/pull/7")
        },
        TestCase("notif: sin cambio de categoría no repite") {
            let s = snap(item(makePR(), .toReview))
            try expectEqual(NotificationPlanner.plan(previous: s, current: s, settings: NotificationSettings()), [])
        },
        TestCase("notif: cambio a actualizado y a feedback") {
            let previous = snap(item(makePR(number: 1), .other), item(makePR(number: 2, author: "me"), .other))
            let current = snap(item(makePR(number: 1), .updatedSinceMyReview), item(makePR(number: 2, author: "me"), .myFeedback))
            try expectEqual(NotificationPlanner.plan(previous: previous, current: current, settings: NotificationSettings()).map(\.kind), [.reviewedPRUpdated, .myPRFeedback])
        },
        TestCase("notif: respeta el toggle por tipo y el general") {
            var settings = NotificationSettings()
            settings.newToReview = false
            try expectEqual(NotificationPlanner.plan(previous: snap(), current: snap(item(makePR(), .toReview)), settings: settings), [])
            settings = NotificationSettings()
            settings.enabled = false
            try expectEqual(NotificationPlanner.plan(previous: snap(), current: snap(item(makePR(), .toReview)), settings: settings), [])
        },
        TestCase("notif: mi PR aprobado o con CI fallando") {
            let previous = snap(item(makePR(number: 1, author: "me", ci: .pending, decision: .reviewRequired), .other))
            let current = snap(item(makePR(number: 1, author: "me", ci: .failure, decision: .approved), .other))
            let planned = NotificationPlanner.plan(previous: previous, current: current, settings: NotificationSettings())
            try expectEqual(planned.map(\.title), ["Tu PR fue aprobado", "Falló el CI de tu PR"])
        },
        TestCase("notif: CI de PRs ajenos no notifica") {
            let previous = snap(item(makePR(ci: .pending), .other))
            let current = snap(item(makePR(ci: .failure), .other))
            try expectEqual(NotificationPlanner.plan(previous: previous, current: current, settings: NotificationSettings()), [])
        },
        TestCase("notif: más de 5 eventos se agrupan por tipo") {
            let current = Snapshot(items: (1...7).map { item(makePR(number: $0), .toReview) }, fetchedAt: t0, errors: [])
            let planned = NotificationPlanner.plan(previous: snap(), current: current, settings: NotificationSettings())
            try expectEqual(planned.count, 1)
            try expectEqual(planned[0].title, "7 PRs nuevos para revisar")
            try expectEqual(planned[0].url, nil)
        },
    ]
}
```

- [ ] **Step 2: Registrar los tests en `main.swift`** (agregar `+ NotificationPlannerTests.cases`)

- [ ] **Step 3: Correr los tests y verificar que fallan**

Run: `swift run PRBarTests notif`
Expected: error de compilación (`cannot find 'NotificationPlanner' in scope`).

- [ ] **Step 4: Crear `Sources/PRBarCore/NotificationPlanner.swift`**

```swift
import Foundation

public enum NotificationKind: String, Codable, Sendable, CaseIterable {
    case newToReview, reviewedPRUpdated, myPRFeedback, reviewFinished, myPRApprovedOrCIFailed
}

public struct PlannedNotification: Equatable, Sendable {
    public let kind: NotificationKind
    public let title: String
    public let body: String
    public let url: URL?

    public init(kind: NotificationKind, title: String, body: String, url: URL?) {
        self.kind = kind
        self.title = title
        self.body = body
        self.url = url
    }
}

extension NotificationSettings {
    public func isOn(_ kind: NotificationKind) -> Bool {
        guard enabled else { return false }
        switch kind {
        case .newToReview: return newToReview
        case .reviewedPRUpdated: return reviewedPRUpdated
        case .myPRFeedback: return myPRFeedback
        case .reviewFinished: return reviewFinished
        case .myPRApprovedOrCIFailed: return myPRApprovedOrCIFailed
        }
    }
}

public enum NotificationPlanner {
    static let groupingThreshold = 5

    public static func plan(previous: Snapshot?, current: Snapshot, settings: NotificationSettings) -> [PlannedNotification] {
        guard settings.enabled, let previous else { return [] }
        let before = Dictionary(previous.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var planned: [PlannedNotification] = []

        for item in current.items {
            let old = before[item.id]
            let pr = item.pr
            let body = "\(pr.repo.name)#\(pr.number) · \(pr.author): \(pr.title)"

            if item.category.countsForBadge, old?.category != item.category,
               let kind = kind(for: item.category), settings.isOn(kind) {
                planned.append(PlannedNotification(kind: kind, title: title(for: kind), body: body, url: pr.url))
            }

            let isMine = pr.author.lowercased() == item.account.lowercased()
            if isMine, let old, settings.isOn(.myPRApprovedOrCIFailed) {
                if old.pr.reviewDecision != .approved && pr.reviewDecision == .approved {
                    planned.append(PlannedNotification(kind: .myPRApprovedOrCIFailed, title: "Tu PR fue aprobado", body: body, url: pr.url))
                }
                if old.pr.ciState != .failure && pr.ciState == .failure {
                    planned.append(PlannedNotification(kind: .myPRApprovedOrCIFailed, title: "Falló el CI de tu PR", body: body, url: pr.url))
                }
            }
        }
        return group(planned)
    }

    private static func kind(for category: PRCategory) -> NotificationKind? {
        switch category {
        case .toReview: .newToReview
        case .updatedSinceMyReview: .reviewedPRUpdated
        case .myFeedback: .myPRFeedback
        case .other: nil
        }
    }

    private static func title(for kind: NotificationKind) -> String {
        switch kind {
        case .newToReview: "Nuevo PR para revisar"
        case .reviewedPRUpdated: "Un PR que revisaste tiene commits nuevos"
        case .myPRFeedback: "Tu PR recibió feedback"
        case .reviewFinished: "Review listo"
        case .myPRApprovedOrCIFailed: "Novedades en tu PR"
        }
    }

    private static func groupTitle(for kind: NotificationKind, count: Int) -> String {
        switch kind {
        case .newToReview: "\(count) PRs nuevos para revisar"
        case .reviewedPRUpdated: "\(count) PRs que revisaste tienen commits nuevos"
        case .myPRFeedback: "\(count) PRs tuyos recibieron feedback"
        case .reviewFinished: "\(count) reviews listos"
        case .myPRApprovedOrCIFailed: "\(count) novedades en tus PRs"
        }
    }

    private static func group(_ planned: [PlannedNotification]) -> [PlannedNotification] {
        guard planned.count > groupingThreshold else { return planned }
        return NotificationKind.allCases.compactMap { kind in
            let list = planned.filter { $0.kind == kind }
            guard !list.isEmpty else { return nil }
            if list.count == 1 { return list[0] }
            return PlannedNotification(
                kind: kind,
                title: groupTitle(for: kind, count: list.count),
                body: list.prefix(3).map(\.body).joined(separator: "\n"),
                url: nil
            )
        }
    }
}
```

- [ ] **Step 5: Correr los tests y verificar que pasan**

Run: `swift run PRBarTests`
Expected: todos `✓`.

- [ ] **Step 6: Commit**

```bash
git add Sources
git commit -m "feat(core): plan push notifications from snapshot transitions"
```

---

### Task 9: Shell de la app, ícono con badge y bundle

**Files:**
- Create: `Sources/PRBar/Theme.swift`, `Sources/PRBar/BadgeIcon.swift`, `Sources/PRBar/WindowPresenter.swift`, `Sources/PRBar/NotificationDelivery.swift`, `Sources/PRBar/LaunchAtLogin.swift`, `Sources/PRBar/AppModel.swift`, `Resources/Info.plist`, `Scripts/bundle.sh`
- Modify: `Sources/PRBar/PRBarApp.swift`

La UI no tiene tests automáticos (spec §12). Cada tarea de UI termina con una verificación manual.

- [ ] **Step 1: Crear `Sources/PRBar/Theme.swift`** (tokens de `docs/design/StyleGuide.dc.html`)

```swift
import AppKit
import SwiftUI

enum Theme {
    static let accent = Color.dynamic(light: 0x2D4EFF, dark: 0x4D6BFF)
    static let green = Color.dynamic(light: 0x1A9E46, dark: 0x32D35A)
    static let orange = Color.dynamic(light: 0xD46B00, dark: 0xFF9F0A)
    static let red = Color.dynamic(light: 0xD92D20, dark: 0xFF5A50)
    static let violet = Color.dynamic(light: 0x8B3FD9, dark: 0xC88BFF)
    static let blue = Color.dynamic(light: 0x0A72E8, dark: 0x47A0FF)

    static func tint(_ color: Color) -> Color { color.opacity(0.16) }

    static let avatarPalette: [Color] = [0xC2410C, 0x0E7490, 0x6D28D9, 0x15803D, 0xA16207, 0xBE185D, 0x1D4ED8].map(Color.init(hex:))

    enum Radius {
        static let popover: CGFloat = 12
        static let card: CGFloat = 8
        static let row: CGFloat = 7
        static let button: CGFloat = 6
    }

    static let popoverWidth: CGFloat = 380
    static let popoverMaxHeight: CGFloat = 640
    static let settingsSize = NSSize(width: 620, height: 520)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
```

- [ ] **Step 2: Crear `Sources/PRBar/BadgeIcon.swift`**

```swift
import AppKit

enum MenuBarIconState: Equatable {
    case idle
    case count(Int)
    case error
}

/// Ícono template para la barra de menú: glifo + badge en cápsula con el número calado (diseño 01).
enum BadgeIcon {
    static func image(for state: MenuBarIconState) -> NSImage {
        let symbolName = state == .error ? "exclamationmark.triangle" : "arrow.triangle.pull"
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: "PRBar")?
            .withSymbolConfiguration(configuration) ?? NSImage()

        guard case .count(let count) = state, count > 0 else {
            glyph.isTemplate = true
            return glyph
        }

        let text = count > 99 ? "99+" : "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let badgeHeight: CGFloat = 14
        let badgeWidth = max(badgeHeight, ceil(textSize.width) + 8)
        let size = NSSize(width: glyph.size.width + 3 + badgeWidth, height: max(glyph.size.height, badgeHeight))

        let image = NSImage(size: size, flipped: false) { _ in
            glyph.draw(in: NSRect(x: 0, y: (size.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            let badge = NSRect(x: glyph.size.width + 3, y: (size.height - badgeHeight) / 2, width: badgeWidth, height: badgeHeight)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: badge, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            (text as NSString).draw(
                at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
                withAttributes: attributes
            )
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            return true
        }
        image.isTemplate = true
        return image
    }
}
```

- [ ] **Step 3: Crear `Sources/PRBar/WindowPresenter.swift`**

```swift
import AppKit
import SwiftUI

/// Presenta ventanas AppKit desde una app solo-barra de menú (LSUIElement) y las trae al frente.
@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()
    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(id: String, title: String, size: NSSize, @ViewBuilder content: () -> Content) {
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.center()
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 4: Crear `Sources/PRBar/NotificationDelivery.swift`**

```swift
import AppKit
import PRBarCore
import UserNotifications

/// Entrega notificaciones de macOS. Solo funciona si la app corre como bundle (`Scripts/bundle.sh`);
/// con `swift run` no hay bundle id y se registra en el log en vez de fallar.
@MainActor
final class NotificationDelivery: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center else {
            AppLog.write("Notificaciones desactivadas: la app no corre como bundle.")
            return
        }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { AppLog.write("Permiso de notificaciones: \(error.localizedDescription)") }
            if !granted { AppLog.write("El usuario no dio permiso para notificaciones.") }
        }
    }

    func deliver(_ notifications: [PlannedNotification]) {
        guard let center else { return }
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            if let url = notification.url { content.userInfo = ["url": url.absoluteString] }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error { AppLog.write("No se pudo mostrar la notificación: \(error.localizedDescription)") }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let string = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: string) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
```

- [ ] **Step 5: Crear `Sources/PRBar/LaunchAtLogin.swift`**

```swift
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 6: Crear `Sources/PRBar/AppModel.swift`**

```swift
import AppKit
import PRBarCore
import SwiftUI

struct ResolvedTools: Equatable {
    var gh: String?
    var git: String?
    var claude: String?
}

@MainActor
final class AppModel: ObservableObject {
    let configStore: ConfigStore
    let prStore: PRStore
    let accounts: AccountProvider
    let api: GitHubClient
    let runner: SystemProcessRunner
    private let notifications: NotificationDelivery

    @Published private(set) var tools = ResolvedTools()
    @Published private(set) var toolsResolved = false
    @Published private(set) var ghAccounts: [GHAccount] = []
    @Published private(set) var accountsError: String?
    @Published var settingsError: String?
    @Published private(set) var launchAtLoginEnabled = LaunchAtLogin.isEnabled

    init() {
        let runner = SystemProcessRunner()
        let accounts = AccountProvider(runner: runner, ghPath: nil)
        let api = GitHubClient()
        let configStore = ConfigStore()
        let notifications = NotificationDelivery()

        self.runner = runner
        self.accounts = accounts
        self.api = api
        self.configStore = configStore
        self.notifications = notifications
        self.prStore = PRStore(
            builder: SnapshotBuilder(api: api, tokens: accounts),
            configStore: configStore,
            onChange: { previous, next in
                notifications.deliver(
                    NotificationPlanner.plan(previous: previous, current: next, settings: configStore.config.notifications)
                )
            }
        )
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        await resolveTools()
        await reloadAccounts()
        notifications.requestAuthorization()
        prStore.start()
    }

    func resolveTools() async {
        let locator = ToolLocator(runner: runner)
        let overrides = configStore.config.toolPaths
        tools = ResolvedTools(
            gh: await locator.locate("gh", override: overrides.gh),
            git: await locator.locate("git", override: overrides.git),
            claude: await locator.locate("claude", override: overrides.claude)
        )
        accounts.ghPath = tools.gh
        toolsResolved = true
    }

    func reloadAccounts() async {
        do {
            ghAccounts = try await accounts.listAccounts()
            accountsError = nil
        } catch {
            ghAccounts = []
            accountsError = error.localizedDescription
        }
    }

    func updateConfig(refresh: Bool = true, _ mutate: (inout AppConfig) -> Void) {
        do {
            try configStore.update(mutate)
            settingsError = nil
            if refresh { Task { await prStore.refresh() } }
        } catch {
            settingsError = "No se pudo guardar la configuración: \(error.localizedDescription)"
            AppLog.write(settingsError ?? "")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            updateConfig(refresh: false) { $0.launchAtLogin = enabled }
        } catch {
            settingsError = "No se pudo cambiar el inicio de sesión: \(error.localizedDescription)"
        }
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    func validateRepoPath(_ path: String, repo: RepoRef) async -> String? {
        guard let git = tools.git else { return PRBarError.toolNotFound("git").localizedDescription }
        return await RepoPathValidator.validate(path: path, repo: repo, runner: runner, gitPath: git)
    }

    func openSettings() {
        WindowPresenter.shared.show(id: "settings", title: "Configuración de PRBar", size: Theme.settingsSize) {
            SettingsView(model: self, configStore: self.configStore)
        }
    }
}
```

- [ ] **Step 7: Reemplazar `Sources/PRBar/PRBarApp.swift`**

```swift
import PRBarCore
import SwiftUI

@main
struct PRBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, prStore: model.prStore, configStore: model.configStore)
        } label: {
            MenuBarLabel(prStore: model.prStore)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var prStore: PRStore

    var body: some View {
        Image(nsImage: BadgeIcon.image(for: state))
            .accessibilityLabel("PRBar, \(prStore.snapshot?.badgeCount ?? 0) pendientes")
    }

    private var state: MenuBarIconState {
        guard let snapshot = prStore.snapshot else { return .idle }
        if snapshot.failedCompletely { return .error }
        return .count(snapshot.badgeCount)
    }
}
```

- [ ] **Step 8: Agregar stubs temporales para que compile**

`PopoverView` y `SettingsView` se implementan en las Tasks 10 y 11. Crear `Sources/PRBar/Popover/PopoverView.swift`:

```swift
import PRBarCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prStore: PRStore
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRBar · \(prStore.snapshot?.badgeCount ?? 0) pendientes")
            Button("Configuración…") { model.openSettings() }
            Button("Salir") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(width: Theme.popoverWidth)
    }
}
```

Y `Sources/PRBar/Settings/SettingsView.swift`:

```swift
import PRBarCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        Text("Configuración").frame(width: Theme.settingsSize.width, height: Theme.settingsSize.height)
    }
}
```

- [ ] **Step 9: Crear `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.federico.prbar</string>
    <key>CFBundleName</key>
    <string>PRBar</string>
    <key>CFBundleDisplayName</key>
    <string>PRBar</string>
    <key>CFBundleExecutable</key>
    <string>PRBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 10: Crear `Scripts/bundle.sh` y hacerlo ejecutable**

```bash
#!/bin/bash
# Compila en release, arma PRBar.app, firma ad-hoc y opcionalmente lo instala en ~/Applications.
# Uso: Scripts/bundle.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product PRBar
BIN="$(swift build -c release --show-bin-path)/PRBar"
APP="build/PRBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PRBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Bundle listo: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x PRBar || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/PRBar.app"
    cp -R "$APP" "$HOME/Applications/PRBar.app"
    open "$HOME/Applications/PRBar.app"
    echo "Instalado y abierto: ~/Applications/PRBar.app"
fi
```

Run: `chmod +x Scripts/bundle.sh`

- [ ] **Step 11: Compilar, instalar y verificar a mano**

Run: `swift run PRBarTests && Scripts/bundle.sh --install`
Expected: los tests pasan, aparece `Instalado y abierto` y en la barra de menú se ve el glifo `arrow.triangle.pull`. Al hacer click se abre el popover provisorio y "Configuración…" abre una ventana al frente. macOS pide permiso para notificaciones.

- [ ] **Step 12: Commit**

```bash
git add Sources Resources Scripts
git commit -m "feat(app): wire app model, badge icon, notifications and app bundle script"
```

---

### Task 10: Popover

**Files:**
- Create: `Sources/PRBar/Popover/Components.swift`, `Sources/PRBar/Popover/PRRowView.swift`
- Modify: `Sources/PRBar/Popover/PopoverView.swift` (reemplazo completo)

Referencia visual: `docs/design/Popover.dc.html` (estados main, empty y error).

- [ ] **Step 1: Crear `Sources/PRBar/Popover/Components.swift`**

```swift
import AppKit
import PRBarCore
import SwiftUI

struct AvatarView: View {
    let login: String
    let url: URL?
    var size: CGFloat = 22

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Theme.avatarPalette[AvatarColor.index(for: login, paletteCount: Theme.avatarPalette.count)]
                Text(Initials.of(login))
                    .font(.system(size: size * 0.43, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct CIIcon: View {
    let state: CIState

    var body: some View {
        switch state {
        case .success: Image(systemName: "checkmark").foregroundStyle(Theme.green).help("CI OK")
        case .failure: Image(systemName: "xmark").foregroundStyle(Theme.red).help("CI fallando")
        case .pending: Image(systemName: "circle.fill").foregroundStyle(Theme.orange).help("CI corriendo")
        case .none: EmptyView()
        }
    }
}

struct FeedbackLabel: View {
    let summary: FeedbackSummary

    var body: some View {
        if summary.changesRequested {
            Label("Cambios pedidos", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.orange)
        } else {
            Label(summary.count == 1 ? "1 comentario" : "\(summary.count) comentarios", systemImage: "text.bubble")
                .foregroundStyle(.secondary)
        }
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int
    let collapsed: Bool
    var dimmed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(title).font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 15)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer()
            }
            .foregroundStyle(dimmed ? .tertiary : .primary)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.top, 7)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MessageView: View {
    let icon: String
    var iconColor: Color = .secondary
    let title: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(iconColor)
                .padding(.bottom, 6)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).padding(.top, 10)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let messages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(messages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.tint(Theme.red)))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

struct CopyableCommand: View {
    let command: String

    init(_ command: String) {
        self.command = command
    }

    var body: some View {
        HStack {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copiar")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(Color.primary.opacity(0.06)))
    }
}
```

- [ ] **Step 2: Crear `Sources/PRBar/Popover/PRRowView.swift`**

```swift
import AppKit
import PRBarCore
import SwiftUI

struct PRRowView: View {
    let item: ClassifiedPR
    var dimmed = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AvatarView(login: item.pr.author, url: item.pr.authorAvatarURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.pr.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    (Text(item.pr.repo.name).foregroundColor(.secondary) + Text("#\(item.pr.number)").foregroundColor(.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·").foregroundStyle(.tertiary)
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                    Text(item.pr.baseRef).lineLimit(1)
                    Text("·").foregroundStyle(.tertiary)
                    Text(RelativeAge.short(from: item.pr.updatedAt)).fixedSize()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                trailingAccessory
                    .font(.system(size: 11, weight: .medium))
                HStack(spacing: 6) {
                    CIIcon(state: item.pr.ciState).font(.system(size: 9, weight: .bold))
                    Text("+\(item.pr.additions)").foregroundStyle(Theme.green)
                    Text("−\(item.pr.deletions)").foregroundStyle(Theme.red)
                }
                .font(.system(size: 10, design: .monospaced))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row)
                .fill(hovering ? Color.primary.opacity(0.07) : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .opacity(dimmed ? 0.6 : 1)
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(item.pr.url) }
        .help("\(item.pr.repo.fullName)#\(item.pr.number) · \(item.pr.title)")
    }

    /// En el Plan 2 se agrega el botón Review para .toReview y .updatedSinceMyReview.
    @ViewBuilder
    private var trailingAccessory: some View {
        if item.category == .myFeedback {
            FeedbackLabel(summary: ActionClassifier.newFeedback(item.pr, me: item.account))
        }
    }
}
```

- [ ] **Step 3: Reemplazar `Sources/PRBar/Popover/PopoverView.swift`**

```swift
import AppKit
import PRBarCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prStore: PRStore
    @ObservedObject var configStore: ConfigStore
    @State private var collapsed: Set<PRCategory> = [.other]

    private let actionable: [PRCategory] = [.toReview, .updatedSinceMyReview, .myFeedback]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.bottom, 4)
            content
        }
        .frame(width: Theme.popoverWidth)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("PRBar").font(.system(size: 13, weight: .bold))
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await prStore.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(prStore.isRefreshing)
            .help("Refrescar")
            Menu {
                Button("Configuración…") { model.openSettings() }
                Divider()
                Button("Salir de PRBar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
    }

    private var subtitle: String {
        if prStore.isRefreshing { return "actualizando…" }
        guard let snapshot = prStore.snapshot else { return "sin datos" }
        if snapshot.failedCompletely { return "sin conexión" }
        return "actualizado hace \(RelativeAge.short(from: snapshot.fetchedAt))"
    }

    // MARK: Contenido

    @ViewBuilder
    private var content: some View {
        if model.toolsResolved && model.tools.gh == nil {
            MessageView(
                icon: "exclamationmark.triangle.fill", iconColor: Theme.orange,
                title: "No encontramos gh",
                text: "Instalá GitHub CLI (brew install gh) o configurá su ruta en Configuración → General.",
                actionTitle: "Abrir configuración", action: model.openSettings
            )
        } else if !configStore.config.accounts.contains(where: \.enabled) {
            MessageView(
                icon: "person.crop.circle",
                title: "Configurá una cuenta",
                text: "Elegí qué cuentas de GitHub, repos y usuarios seguir.",
                actionTitle: "Abrir configuración", action: model.openSettings
            )
        } else if let snapshot = prStore.snapshot {
            if snapshot.failedCompletely && snapshot.items.isEmpty {
                MessageView(
                    icon: "wifi.slash",
                    title: "Sin conexión",
                    text: snapshot.errors.first ?? "No pudimos contactar a GitHub.",
                    actionTitle: "Reintentar", action: { Task { await prStore.refresh() } }
                )
            } else {
                list(snapshot)
            }
        } else {
            ProgressView().controlSize(.small).padding(40)
        }
    }

    private func list(_ snapshot: Snapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if snapshot.failedCompletely {
                    ErrorBanner(messages: ["Sin conexión. Los datos son de hace \(RelativeAge.short(from: snapshot.fetchedAt))."])
                } else if !snapshot.errors.isEmpty {
                    ErrorBanner(messages: snapshot.errors)
                }

                let sections = actionable.filter { !snapshot.items(in: $0).isEmpty }
                if sections.isEmpty {
                    MessageView(
                        icon: "checkmark.seal", iconColor: Theme.green,
                        title: "Todo al día",
                        text: "No hay PRs esperando tu review ni feedback nuevo en los tuyos."
                    )
                }
                ForEach(sections) { category in
                    section(category, items: snapshot.items(in: category))
                }

                let others = snapshot.items(in: .other)
                if !others.isEmpty {
                    Divider().padding(.vertical, 4)
                    section(.other, items: others, dimmed: true)
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxHeight: Theme.popoverMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func section(_ category: PRCategory, items: [ClassifiedPR], dimmed: Bool = false) -> some View {
        SectionHeader(
            title: category == .other ? "Otros · drafts y sin acción pendiente" : category.title,
            count: items.count,
            collapsed: collapsed.contains(category),
            dimmed: dimmed
        ) {
            if collapsed.contains(category) { collapsed.remove(category) } else { collapsed.insert(category) }
        }
        if !collapsed.contains(category) {
            ForEach(items) { item in
                PRRowView(item: item, dimmed: dimmed)
            }
        }
    }
}
```

- [ ] **Step 4: Compilar, instalar y verificar a mano**

Run: `Scripts/bundle.sh --install`

Expected:
- Sin cuentas configuradas, el popover muestra "Configurá una cuenta" con el botón que abre Configuración.
- Al editar `~/Library/Application Support/PRBar/config.json` a mano (`{"accounts":[{"login":"sam-personal","watchedUsers":[],"repos":[{"owner":"FedericoCharbonnier","name":"PRBar"}]}]}`) y apretar refrescar, aparece "Todo al día" (el repo no tiene PRs) y el header dice "actualizado hace ahora".
- Con el popover abierto, compará contra `docs/design/Popover.dc.html` en claro y oscuro (Ajustes del Sistema → Apariencia).

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat(app): build popover with PR sections, rows and empty/error states"
```

---

### Task 11: Ventana de Configuración

**Files:**
- Create: `Sources/PRBar/Settings/AccountsTab.swift`, `Sources/PRBar/Settings/ReposTab.swift`, `Sources/PRBar/Settings/UsersTab.swift`, `Sources/PRBar/Settings/GeneralTab.swift`
- Modify: `Sources/PRBar/Settings/SettingsView.swift` (reemplazo completo)

Referencia visual: `docs/design/SettingsWindow.dc.html` (tabs accounts, accounts-empty, repos, users y general).

- [ ] **Step 1: Reemplazar `Sources/PRBar/Settings/SettingsView.swift`**

```swift
import PRBarCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        VStack(spacing: 0) {
            if let error = configStore.loadError ?? model.settingsError {
                ErrorBanner(messages: [error])
            }
            TabView {
                AccountsTab(model: model, configStore: configStore)
                    .tabItem { Label("Cuentas", systemImage: "person.crop.circle") }
                ReposTab(model: model, configStore: configStore)
                    .tabItem { Label("Repos", systemImage: "books.vertical") }
                UsersTab(model: model, configStore: configStore)
                    .tabItem { Label("Usuarios", systemImage: "person.2") }
                GeneralTab(model: model, configStore: configStore)
                    .tabItem { Label("General", systemImage: "gearshape") }
            }
        }
        .frame(minWidth: Theme.settingsSize.width, minHeight: Theme.settingsSize.height)
        .tint(Theme.accent)
    }
}

/// Selector de cuenta compartido por las pestañas Repos y Usuarios.
struct AccountPicker: View {
    let logins: [String]
    @Binding var selection: String

    var body: some View {
        if logins.count > 1 {
            Picker("Cuenta", selection: $selection) {
                ForEach(logins, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

extension ConfigStore {
    var enabledLogins: [String] { config.accounts.filter(\.enabled).map(\.login) }

    func account(_ login: String) -> AccountConfig? {
        config.accounts.first { $0.login == login && $0.enabled }
    }
}
```

- [ ] **Step 2: Crear `Sources/PRBar/Settings/AccountsTab.swift`**

```swift
import PRBarCore
import SwiftUI

struct AccountsTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        Form {
            if model.ghAccounts.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No hay cuentas de GitHub en gh", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.orange)
                        if let error = model.accountsError {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Iniciá sesión en una terminal y volvé a cargar:").foregroundStyle(.secondary)
                        CopyableCommand("gh auth login --hostname github.com")
                        Button("Volver a cargar") { Task { await model.reloadAccounts() } }
                    }
                }
            } else {
                Section("Cuentas detectadas en gh") {
                    ForEach(model.ghAccounts, id: \.login) { account in
                        Toggle(isOn: enabledBinding(for: account.login)) {
                            HStack(spacing: 8) {
                                AvatarView(login: account.login, url: URL(string: "https://github.com/\(account.login).png?size=64"))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(account.login)
                                    Text(account.isActive ? "github.com · cuenta activa en gh" : "github.com")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
                Section {
                    Button("Volver a cargar cuentas") { Task { await model.reloadAccounts() } }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func enabledBinding(for login: String) -> Binding<Bool> {
        Binding(
            get: { configStore.config.accounts.first { $0.login == login }?.enabled ?? false },
            set: { enabled in model.updateConfig { $0.setAccountEnabled(login, enabled) } }
        )
    }
}
```

- [ ] **Step 3: Crear `Sources/PRBar/Settings/ReposTab.swift`**

```swift
import AppKit
import PRBarCore
import SwiftUI

struct ReposTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore

    @State private var login = ""
    @State private var selectedRepoID: String?
    @State private var available: [RepoRef] = []
    @State private var query = ""
    @State private var loadError: String?
    @State private var branches: [String] = []
    @State private var pathMessage: String?
    @State private var pathValid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AccountPicker(logins: configStore.enabledLogins, selection: $login)
            if let account = configStore.account(login) {
                HStack(alignment: .top, spacing: 12) {
                    repoList(account).frame(width: 250)
                    Divider()
                    detail(account).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                Text("Activá una cuenta en la pestaña Cuentas.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .onAppear { if login.isEmpty { login = configStore.enabledLogins.first ?? "" } }
        .task(id: login) { await loadAvailable() }
    }

    // MARK: Lista de repos

    private func repoList(_ account: AccountConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selectedRepoID) {
                ForEach(account.repos) { repo in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.id).lineLimit(1)
                        Text(meta(repo)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(repo.id)
                }
            }
            .listStyle(.bordered)

            TextField("Agregar repo (owner/nombre)", text: $query)
                .textFieldStyle(.roundedBorder)
            let matches = suggestions(for: account)
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches) { repo in
                        Button(repo.fullName) {
                            model.updateConfig { $0.addRepo(repo, to: login) }
                            selectedRepoID = repo.fullName
                            query = ""
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(Theme.red)
            }
            Button("Quitar repo seleccionado") {
                if let id = selectedRepoID { model.updateConfig { $0.removeRepo(id, from: login) } }
                selectedRepoID = nil
            }
            .disabled(selectedRepoID == nil)
        }
    }

    private func meta(_ repo: RepoConfig) -> String {
        let bases = repo.baseBranches.isEmpty ? "rama por defecto" : repo.baseBranches.joined(separator: ", ")
        return repo.localPath == nil ? "\(bases) · sin carpeta local" : bases
    }

    private func suggestions(for account: AccountConfig) -> [RepoRef] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return [] }
        let configured = Set(account.repos.map(\.id))
        return Array(available.filter { $0.fullName.lowercased().contains(text) && !configured.contains($0.fullName) }.prefix(6))
    }

    private func loadAvailable() async {
        guard !login.isEmpty else { return }
        do {
            let token = try await model.accounts.token(for: login)
            available = try await model.api.viewerRepositories(token: token)
            loadError = nil
        } catch {
            available = []
            loadError = "No se pudieron cargar tus repos: \(error.localizedDescription)"
        }
    }

    // MARK: Detalle del repo

    @ViewBuilder
    private func detail(_ account: AccountConfig) -> some View {
        if let repo = account.repos.first(where: { $0.id == selectedRepoID }) {
            VStack(alignment: .leading, spacing: 14) {
                Text(repo.id).font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Carpeta local").font(.subheadline.weight(.semibold))
                    HStack {
                        Image(systemName: "folder")
                        Text(repo.localPath ?? "Sin carpeta: el review usará solo el diff")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Button("Elegir…") { chooseFolder(for: repo) }
                        if repo.localPath != nil {
                            Button("Quitar") { model.updateConfig(refresh: false) { $0.setLocalPath(nil, repoID: repo.id, login: login) } }
                        }
                    }
                    if let pathMessage {
                        Label(pathMessage, systemImage: pathValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(pathValid ? Theme.green : Theme.red)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Ramas base").font(.subheadline.weight(.semibold))
                    Text("Sin ninguna marcada se usa la rama por defecto.").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(branches, id: \.self) { branch in
                                Toggle(branch, isOn: Binding(
                                    get: { repo.baseBranches.contains(branch) },
                                    set: { _ in model.updateConfig { $0.toggleBaseBranch(branch, repoID: repo.id, login: login) } }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                Spacer()
            }
            .task(id: repo.id) {
                pathMessage = nil
                await loadBranches(repo.repo)
            }
        } else {
            Text("Elegí un repo de la lista o agregá uno.").foregroundStyle(.secondary)
        }
    }

    private func loadBranches(_ repo: RepoRef) async {
        do {
            let token = try await model.accounts.token(for: login)
            branches = try await model.api.branches(of: repo, token: token)
        } catch {
            branches = []
            pathMessage = "No se pudieron cargar las ramas: \(error.localizedDescription)"
            pathValid = false
        }
    }

    private func chooseFolder(for repo: RepoConfig) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Usar esta carpeta"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let error = await model.validateRepoPath(url.path, repo: repo.repo) {
                pathMessage = error
                pathValid = false
            } else {
                model.updateConfig(refresh: false) { $0.setLocalPath(url.path, repoID: repo.id, login: login) }
                pathMessage = "Remote verificado"
                pathValid = true
            }
        }
    }
}
```

- [ ] **Step 4: Crear `Sources/PRBar/Settings/UsersTab.swift`**

```swift
import PRBarCore
import SwiftUI

struct UsersTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore

    @State private var login = ""
    @State private var newUser = ""
    @State private var adding = false
    @State private var addError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AccountPicker(logins: configStore.enabledLogins, selection: $login)
            if let account = configStore.account(login) {
                HStack {
                    TextField("Agregar usuario de GitHub", text: $newUser)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Agregar", action: add)
                        .disabled(newUser.trimmingCharacters(in: .whitespaces).isEmpty || adding)
                }
                if let addError {
                    Text(addError).font(.caption).foregroundStyle(Theme.red)
                }
                List {
                    ForEach(account.watchedUsers, id: \.self) { user in
                        HStack(spacing: 8) {
                            AvatarView(login: user, url: URL(string: "https://github.com/\(user).png?size=64"))
                            Text(user)
                            Spacer()
                            Button {
                                model.updateConfig { $0.removeWatchedUser(user, from: login) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Dejar de seguir")
                        }
                    }
                }
                .listStyle(.bordered)
                Text("Los PRs de estos usuarios aparecen en “Para revisar”. \(account.watchedUsers.count) usuarios en \(login).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Activá una cuenta en la pestaña Cuentas.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .onAppear { if login.isEmpty { login = configStore.enabledLogins.first ?? "" } }
    }

    private func add() {
        let name = newUser.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                let token = try await model.accounts.token(for: login)
                if let user = try await model.api.user(login: name, token: token) {
                    model.updateConfig { $0.addWatchedUser(user.login, to: login) }
                    newUser = ""
                    addError = nil
                } else {
                    addError = "No existe el usuario \(name) en GitHub."
                }
            } catch {
                addError = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 5: Crear `Sources/PRBar/Settings/GeneralTab.swift`**

```swift
import PRBarCore
import SwiftUI

struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        Form {
            Section {
                Picker("Refrescar cada", selection: Binding(
                    get: { configStore.config.refreshIntervalMinutes },
                    set: { minutes in model.updateConfig(refresh: false) { $0.refreshIntervalMinutes = minutes } }
                )) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                }
                Toggle("Abrir al iniciar sesión", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
            }

            Section("Herramientas") {
                toolRow("gh", resolved: model.tools.gh, override: \.gh)
                toolRow("git", resolved: model.tools.git, override: \.git)
                toolRow("claude", resolved: model.tools.claude, override: \.claude)
            }

            Section("Notificaciones") {
                Toggle(isOn: notification(\.enabled)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mostrar notificaciones")
                        Text("Usa el estilo configurado en Ajustes del Sistema").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Group {
                    Toggle("PR nuevo para revisar", isOn: notification(\.newToReview))
                    Toggle("PR que revisé tiene commits nuevos", isOn: notification(\.reviewedPRUpdated))
                    Toggle("Mi PR recibió cambios pedidos o comentarios", isOn: notification(\.myPRFeedback))
                    Toggle("Terminó un review de Claude", isOn: notification(\.reviewFinished))
                    Toggle("Mi PR fue aprobado o el CI falló", isOn: notification(\.myPRApprovedOrCIFailed))
                }
                .disabled(!configStore.config.notifications.enabled)
            }
            .toggleStyle(.switch)
        }
        .formStyle(.grouped)
    }

    private func notification(_ keyPath: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { configStore.config.notifications[keyPath: keyPath] },
            set: { value in model.updateConfig(refresh: false) { $0.notifications[keyPath: keyPath] = value } }
        )
    }

    private func toolRow(_ name: String, resolved: String?, override: WritableKeyPath<ToolPaths, String?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Ruta de ").foregroundStyle(.secondary) + Text(name).font(.system(.body, design: .monospaced))
                Spacer()
                if let resolved {
                    Label(configStore.config.toolPaths[keyPath: override] == nil ? "Detectada automáticamente" : "Ruta personalizada",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.green)
                        .help(resolved)
                } else {
                    Label("No encontrada", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.red)
                }
            }
            TextField(resolved ?? "/ruta/a/\(name)", text: Binding(
                get: { configStore.config.toolPaths[keyPath: override] ?? "" },
                set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    model.updateConfig(refresh: false) { $0.toolPaths[keyPath: override] = trimmed.isEmpty ? nil : trimmed }
                }
            ))
            .font(.system(size: 11, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await model.resolveTools(); await model.prStore.refresh() } }
        }
    }
}
```

- [ ] **Step 6: Compilar, instalar y verificar a mano**

Run: `swift run PRBarTests && Scripts/bundle.sh --install`

Expected (contra `docs/design/SettingsWindow.dc.html`):
- **Cuentas:** aparecen `dev-sam` (activa en gh), `sam-personal` y `acme-bot`. Al activar una, el popover deja de mostrar "Configurá una cuenta".
- **Repos:** al escribir "PRBar" se sugiere `FedericoCharbonnier/PRBar`, que se agrega con un click. Elegir `~/Documents/PRBar` como carpeta muestra "Remote verificado". Elegir `~/Documents` muestra "La carpeta no es un repositorio git.". Las ramas listan `main`.
- **Usuarios:** al agregar un login inexistente aparece el error; uno real se agrega con su avatar.
- **General:** al cambiar los toggles, `config.json` se actualiza (`cat ~/Library/Application\ Support/PRBar/config.json`).

- [ ] **Step 7: Commit**

```bash
git add Sources
git commit -m "feat(app): add settings window for accounts, repos, users and general options"
```

---

### Task 12: Verificación de punta a punta y push

**Files:**
- Create: `docs/qa/plan-1-checklist.md`

- [ ] **Step 1: Crear `docs/qa/plan-1-checklist.md`**

```markdown
# QA manual — Plan 1

Con `Scripts/bundle.sh --install` recién corrido:

- [ ] Configuración → Cuentas: activar `acme-bot` y `dev-sam`.
- [ ] Repos: agregar `acme/posts-api` y `acme/web-app` (cuenta acme-bot), ramas base `develop`, carpeta local verificada.
- [ ] Usuarios: agregar a 2–3 compañeros.
- [ ] El badge del ícono coincide con la suma de "Para revisar" + "Actualizados desde mi review" + "Mis PRs con feedback".
- [ ] Click en una fila abre el PR en el navegador.
- [ ] Un PR mío con comentarios nuevos muestra "N comentarios" o "Cambios pedidos".
- [ ] Desconectar el Wi-Fi y refrescar: el ícono pasa a ⚠︎ y el popover dice "Sin conexión" (o muestra el banner y mantiene la lista).
- [ ] Reconectar y refrescar: vuelve el número.
- [ ] Notificaciones: borrar un PR de `state.json` (o esperar uno nuevo) y refrescar → llega el banner; un click abre el PR.
- [ ] Desactivar "Mostrar notificaciones" → no llegan más.
- [ ] "Abrir al iniciar sesión" activado aparece en Ajustes del Sistema → General → Ítems de inicio.
- [ ] Modo claro y oscuro se ven como `docs/design/` (popover, configuración).
- [ ] `~/Library/Logs/PRBar/prbar.log` registra los errores provocados.
```

- [ ] **Step 2: Correr la suite completa**

Run: `swift run PRBarTests`
Expected: todos los tests `✓`, código de salida 0.

- [ ] **Step 3: Recorrer la checklist** y anotar en el mismo archivo lo que falle. Cada falla se arregla con un commit aparte antes de seguir.

- [ ] **Step 4: Commit y push**

```bash
git add docs/qa
git commit -m "docs: add manual QA checklist for plan 1"
git push
```
