# PRBar — Plan 2: Review con Claude e historial

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** El botón **Review** de los PRs ajenos hace esto:
1. crea un worktree temporal;
2. corre Claude en dos etapas: `pr-review-toolkit` para revisar y `receiving-code-review` para filtrar;
3. muestra los hallazgos para elegir y editar;
4. publica una sola review en GitHub (Comentar, Pedir cambios o Aprobar);
5. guarda todo en el historial.

Spec: §8, §10 y la notificación `reviewFinished` de §9.

**Architecture:**
- **Lógica en `PRBarCore`, con fakes:**
  - modelos de review y JSON Schemas;
  - parser del `stream-json` de Claude;
  - `WorktreeManager`;
  - `ClaudeReviewer` (las dos etapas);
  - `ReviewPipeline` (worktree, review, filtrado y limpieza);
  - `ReviewQueue` (`@MainActor`, máximo 2 en paralelo, cancelación);
  - `DiffLineMap` y `ReviewPublisher` (arman la review de GitHub);
  - `ReviewHistory`.
- **La app** agrega:
  - el botón con sus estados en `PRRowView`;
  - la ventana de Review;
  - la ventana de Historial;
  - la limpieza de worktrees huérfanos al arrancar.

**Tech Stack:** Swift 5.10, SwiftUI, `claude` CLI (`-p --output-format stream-json --verbose --json-schema`), `git worktree`, GitHub REST (`pulls/{n}/files`, `pulls/{n}/reviews`).

**Datos verificados de la CLI (`claude` 2.1.318):** con `--json-schema`, el último evento del stream es:

```json
{"type":"result","subtype":"success","is_error":false,"result":"<texto>","structured_output":{...},"total_cost_usd":0.01}
```

`structured_output` ya viene validado contra el schema. Los subagentes aparecen como eventos `{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent"|"Task",...}]}}`. El `claude -p` headless carga los hooks y plugins del usuario, así que `pr-review-toolkit` y `superpowers` están disponibles.

**Convenciones:**
- Rama `feat/plan-2-review`, creada desde `main`. Hoy hay 161 tests.
- Tests: `swift run PRBarTests [filtro]`. Los helpers `expect`/`expectEqual` no aceptan `await` adentro: primero va a una variable local.
- Commits en inglés, sin `Co-Authored-By` ni atribución a Claude. Sin push.
- UI en español rioplatense. Referencia visual: `docs/design/ReviewWindow.dc.html`, `ReviewButtons.dc.html`, `HistoryWindow.dc.html` y `Popover.dc.html`.
- **Nunca** correr el `claude` real ni hacer POST reales a GitHub en los tests.

## Estructura de archivos

```
Sources/PRBarCore/
  ReviewModels.swift        Severity, ReviewFinding, ReviewVerdict, ReviewItem, ReviewDraft, ReviewSchemas
  ClaudeStream.swift        ClaudeStreamEvent, ClaudeStreamParser, ClaudeResult
  ProcessRunner.swift       (modificar) runStreaming con callback por línea de stdout
  WorktreeManager.swift     worktree temporal por review + limpieza de huérfanos
  ClaudeReviewer.swift      prompts, argumentos, 2 etapas, reintento
  ReviewPipeline.swift      orquesta worktree → etapa 1 → etapa 2 → limpieza
  ReviewQueue.swift         estados por PR, cola de 2, cancelación (@MainActor)
  DiffLineMap.swift         líneas comentables por archivo a partir de los patches
  ReviewPublisher.swift     arma ReviewSubmission (inline vs body)
  GitHubClient.swift        (modificar) pullRequestFiles, submitReview
  ReviewHistory.swift       registros + logs en Application Support/PRBar/history
  NotificationPlanner.swift (modificar) reviewFinished
  Support.swift             (modificar) AppPaths.historyDir / worktreesDir, errores nuevos
Sources/PRBar/
  Review/ReviewButton.swift
  Review/ReviewWindow.swift
  Review/HistoryWindow.swift
  Popover/PRRowView.swift   (modificar) botón Review
  Popover/PopoverView.swift (modificar) menú "Historial…"
  AppModel.swift            (modificar) cola, publicación, historial, limpieza al arrancar
  NotificationDelivery.swift (modificar) click en "review listo" abre la ventana
```

---

### Task 1: Modelos de review y JSON Schemas

**Files:**
- Create: `Sources/PRBarCore/ReviewModels.swift`, `Sources/PRBarTests/ReviewModelsTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Tests (`ReviewModelsTests.swift`)**

```swift
import Foundation
import PRBarCore

enum ReviewModelsTests {
    static let cases: [TestCase] = [
        TestCase("review models: decodifica la salida de la etapa 1") {
            let json = #"{"summary":"Agrega rate limiting.","findings":[{"id":"f1","severity":"high","file":"a.rb","line":18,"title":"Usa la IP","body":"Cuerpo"},{"id":"f2","severity":"low","file":"b.rb","line":null,"title":"Nombre","body":"Otro"}]}"#
            let output = try JSONDecoder().decode(ReviewStageOneOutput.self, from: Data(json.utf8))
            try expectEqual(output.findings.map(\.severity), [.high, .low])
            try expectEqual(output.findings[1].line, nil)
        },
        TestCase("review models: el draft combina hallazgos y veredictos (sin veredicto = keep)") {
            let findings = [
                ReviewFinding(id: "f1", severity: .high, file: "a.rb", line: 1, title: "t1", body: "b1"),
                ReviewFinding(id: "f2", severity: .medium, file: "b.rb", line: 2, title: "t2", body: "b2"),
                ReviewFinding(id: "f3", severity: .low, file: "c.rb", line: 3, title: "t3", body: "b3"),
            ]
            let verdicts = [ReviewVerdict(id: "f2", verdict: .discard, reason: "No aplica")]
            let items = ReviewItem.combine(findings: findings, verdicts: verdicts)
            try expectEqual(items.map(\.keep), [true, false, true])
            try expectEqual(items[1].reason, "No aplica")
        },
        TestCase("review models: los schemas son JSON válido") {
            for schema in [ReviewSchemas.stageOne, ReviewSchemas.stageTwo] {
                try expect((try? JSONSerialization.jsonObject(with: Data(schema.utf8))) != nil)
            }
        },
        TestCase("review models: ReviewDraft round-trip") {
            let draft = ReviewDraft(
                prID: "o/r#1", repo: RepoRef(owner: "o", name: "r"), number: 1, title: "PR", url: URL(string: "https://github.com/o/r/pull/1")!,
                author: "juan", headOid: "abc", account: "me", summary: "s",
                items: [ReviewItem(finding: ReviewFinding(id: "f1", severity: .low, file: "a", line: 1, title: "t", body: "b"), keep: true, reason: nil)]
            )
            try expectEqual(try JSONCoding.decoder.decode(ReviewDraft.self, from: JSONCoding.encoder.encode(draft)), draft)
        },
    ]
}
```

- [ ] **Step 2:** Registrar `+ ReviewModelsTests.cases` en `main.swift`, correr y ver que falla: `swift run PRBarTests "review models"` → error de compilación.

- [ ] **Step 3: Implementar `ReviewModels.swift`**

```swift
import Foundation

public enum Severity: String, Codable, Sendable, CaseIterable {
    case high, medium, low

    public var label: String {
        switch self {
        case .high: "Alta"
        case .medium: "Media"
        case .low: "Baja"
        }
    }
}

public struct ReviewFinding: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let severity: Severity
    public let file: String
    public let line: Int?
    public let title: String
    public let body: String

    public init(id: String, severity: Severity, file: String, line: Int?, title: String, body: String) {
        self.id = id
        self.severity = severity
        self.file = file
        self.line = line
        self.title = title
        self.body = body
    }

    public var location: String { line.map { "\(file):\($0)" } ?? file }
}

public struct ReviewStageOneOutput: Codable, Equatable, Sendable {
    public let summary: String
    public let findings: [ReviewFinding]
}

public struct ReviewVerdict: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case keep, discard }
    public let id: String
    public let verdict: Kind
    public let reason: String

    public init(id: String, verdict: Kind, reason: String) {
        self.id = id
        self.verdict = verdict
        self.reason = reason
    }
}

public struct ReviewStageTwoOutput: Codable, Equatable, Sendable {
    public let verdicts: [ReviewVerdict]
}

public struct ReviewItem: Codable, Equatable, Sendable, Identifiable {
    public let finding: ReviewFinding
    /// Veredicto del filtro (etapa 2). Un hallazgo sin veredicto se mantiene.
    public let keep: Bool
    public let reason: String?

    public init(finding: ReviewFinding, keep: Bool, reason: String?) {
        self.finding = finding
        self.keep = keep
        self.reason = reason
    }

    public var id: String { finding.id }

    public static func combine(findings: [ReviewFinding], verdicts: [ReviewVerdict]) -> [ReviewItem] {
        let byID = Dictionary(verdicts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return findings.map { finding in
            let verdict = byID[finding.id]
            return ReviewItem(finding: finding, keep: verdict?.verdict != .discard, reason: verdict?.reason)
        }
    }
}

public struct ReviewDraft: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public let prID: String
    public let repo: RepoRef
    public let number: Int
    public let title: String
    public let url: URL
    public let author: String
    /// Commit sobre el que se hizo la review (se usa como `commit_id` al publicar).
    public let headOid: String
    public let account: String
    public let summary: String
    public let items: [ReviewItem]

    public init(prID: String, repo: RepoRef, number: Int, title: String, url: URL, author: String,
                headOid: String, account: String, summary: String, items: [ReviewItem]) {
        self.prID = prID
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.headOid = headOid
        self.account = account
        self.summary = summary
        self.items = items
    }

    public var keptCount: Int { items.filter(\.keep).count }
}

public enum ReviewSchemas {
    public static let stageOne = """
    {"type":"object","additionalProperties":false,"required":["summary","findings"],
     "properties":{
      "summary":{"type":"string"},
      "findings":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["id","severity","file","line","title","body"],
        "properties":{
          "id":{"type":"string"},
          "severity":{"type":"string","enum":["high","medium","low"]},
          "file":{"type":"string"},
          "line":{"type":["integer","null"]},
          "title":{"type":"string"},
          "body":{"type":"string"}}}}}}
    """

    public static let stageTwo = """
    {"type":"object","additionalProperties":false,"required":["verdicts"],
     "properties":{"verdicts":{"type":"array","items":{"type":"object","additionalProperties":false,
       "required":["id","verdict","reason"],
       "properties":{"id":{"type":"string"},"verdict":{"type":"string","enum":["keep","discard"]},"reason":{"type":"string"}}}}}}
    """
}
```

- [ ] **Step 4:** Correr todo → verde. **Step 5:** Commit `feat(core): add review models and Claude output schemas`.

---

### Task 2: Parser del stream de Claude

**Files:**
- Create: `Sources/PRBarCore/ClaudeStream.swift`, `Sources/PRBarTests/ClaudeStreamTests.swift`

- [ ] **Step 1: Tests**

```swift
import Foundation
import PRBarCore

private let agentLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}"#
private let taskLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hola"},{"type":"tool_use","name":"Task","input":{}}]}}"#
private let readLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#
private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"ok","structured_output":{"summary":"s","findings":[]},"total_cost_usd":0.12}"#

enum ClaudeStreamTests {
    static let cases: [TestCase] = [
        TestCase("claude stream: cuenta subagentes y ignora otras herramientas") {
            var parser = ClaudeStreamParser()
            try expectEqual(parser.consume(agentLine), .agentStarted(total: 1))
            try expectEqual(parser.consume(readLine), nil)
            try expectEqual(parser.consume(taskLine), .agentStarted(total: 2))
        },
        TestCase("claude stream: ignora líneas que no son JSON o eventos de sistema") {
            var parser = ClaudeStreamParser()
            try expectEqual(parser.consume("not json"), nil)
            try expectEqual(parser.consume(#"{"type":"system","subtype":"init"}"#), nil)
            try expectEqual(parser.result, nil)
        },
        TestCase("claude stream: guarda el resultado con structured_output") {
            var parser = ClaudeStreamParser()
            _ = parser.consume(resultLine)
            let result = try parser.decodeResult(ReviewStageOneOutput.self)
            try expectEqual(result.summary, "s")
            try expectEqual(parser.result?.costUSD, 0.12)
        },
        TestCase("claude stream: sin structured_output usa el último bloque json del texto") {
            var parser = ClaudeStreamParser()
            let text = "bla\\n```json\\n{\\\"verdicts\\\":[]}\\n```\\notro\\n```json\\n{\\\"verdicts\\\":[{\\\"id\\\":\\\"f1\\\",\\\"verdict\\\":\\\"keep\\\",\\\"reason\\\":\\\"r\\\"}]}\\n```"
            _ = parser.consume(#"{"type":"result","subtype":"success","is_error":false,"result":"\#(text)"}"#)
            let output = try parser.decodeResult(ReviewStageTwoOutput.self)
            try expectEqual(output.verdicts.count, 1)
        },
        TestCase("claude stream: error o sin resultado → ClaudeError") {
            var failed = ClaudeStreamParser()
            _ = failed.consume(#"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Se cortó"}"#)
            let error = try await expectThrows { _ = try failed.decodeResult(ReviewStageTwoOutput.self) }
            try expect(error as? ClaudeError == .failed("Se cortó"))
            let empty = ClaudeStreamParser()
            let missing = try await expectThrows { _ = try empty.decodeResult(ReviewStageTwoOutput.self) }
            try expect(missing as? ClaudeError == .noResult)
        },
        TestCase("claude stream: JSON que no respeta el schema → invalidOutput") {
            var parser = ClaudeStreamParser()
            _ = parser.consume(#"{"type":"result","is_error":false,"result":"x","structured_output":{"nope":1}}"#)
            let error = try await expectThrows { _ = try parser.decodeResult(ReviewStageOneOutput.self) }
            guard case .invalidOutput = error as? ClaudeError else { throw TestFailure(description: "esperaba invalidOutput, fue \(error)") }
        },
    ]
}
```

- [ ] **Step 2:** Registrar, correr y ver que falla.

- [ ] **Step 3: Implementar `ClaudeStream.swift`**

```swift
import Foundation

public enum ClaudeError: Error, Equatable, LocalizedError {
    case noResult
    case failed(String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .noResult: "Claude terminó sin devolver un resultado."
        case .failed(let message): "Claude falló: \(message)"
        case .invalidOutput(let detail): "Claude devolvió un resultado con formato inválido: \(detail)"
        }
    }
}

public enum ClaudeStreamEvent: Equatable, Sendable {
    case agentStarted(total: Int)
}

public struct ClaudeResult: Equatable, Sendable {
    public let isError: Bool
    public let text: String
    /// JSON crudo de `structured_output`, si vino.
    public let structuredJSON: Data?
    public let costUSD: Double?
}

/// Lee el `--output-format stream-json` de `claude -p`, línea por línea.
public struct ClaudeStreamParser: Sendable {
    public private(set) var agentCount = 0
    public private(set) var result: ClaudeResult?

    public init() {}

    public mutating func consume(_ line: String) -> ClaudeStreamEvent? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return nil }

        switch type {
        case "assistant":
            let content = ((object["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            let agents = content.filter { ($0["type"] as? String) == "tool_use" && ["Agent", "Task"].contains($0["name"] as? String ?? "") }
            guard !agents.isEmpty else { return nil }
            agentCount += agents.count
            return .agentStarted(total: agentCount)
        case "result":
            let structured = object["structured_output"].flatMap { value -> Data? in
                guard !(value is NSNull) else { return nil }
                return try? JSONSerialization.data(withJSONObject: value)
            }
            result = ClaudeResult(
                isError: object["is_error"] as? Bool ?? false,
                text: object["result"] as? String ?? "",
                structuredJSON: structured,
                costUSD: object["total_cost_usd"] as? Double
            )
            return nil
        default:
            return nil
        }
    }

    public func decodeResult<T: Decodable>(_ type: T.Type) throws -> T {
        guard let result else { throw ClaudeError.noResult }
        if result.isError { throw ClaudeError.failed(result.text.isEmpty ? "error sin detalle" : result.text) }
        guard let json = result.structuredJSON ?? Self.lastJSONBlock(in: result.text) else {
            throw ClaudeError.invalidOutput("no hay JSON en la respuesta")
        }
        do {
            return try JSONDecoder().decode(T.self, from: json)
        } catch {
            throw ClaudeError.invalidOutput("\(error)")
        }
    }

    static func lastJSONBlock(in text: String) -> Data? {
        let blocks = text.components(separatedBy: "```json").dropFirst()
        guard let last = blocks.last, let end = last.range(of: "```") else { return nil }
        return String(last[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)
    }
}
```

- [ ] **Step 4:** Verde. **Step 5:** Commit `feat(core): parse Claude stream-json output`.

---

### Task 3: Ejecución de procesos con streaming

**Files:**
- Modify: `Sources/PRBarCore/ProcessRunner.swift`, `Sources/PRBarTests/Fakes.swift`, `Sources/PRBarTests/ProcessTests.swift`

`SystemProcessRunner` ya lee stdout y stderr con `poll()` en un reader de fondo, y tiene timeout y cancelación (SIGTERM → SIGKILL). Claude necesita además recibir **cada línea de stdout a medida que llega**, para el progreso y el log.

- [ ] **Step 1: Agregar el protocolo**, sin romper `ProcessRunning`:

```swift
public protocol StreamingProcessRunning: Sendable {
    /// Igual que `ProcessRunning.run`, pero llama a `onStdoutLine` (en un hilo de fondo) por cada línea
    /// completa de stdout, sin el `\n`. La última línea sin `\n` también se entrega al terminar.
    /// `stdout` en el resultado contiene todo lo leído.
    func runStreaming(
        _ executable: String, _ arguments: [String],
        environment: [String: String]?, currentDirectory: URL?, timeout: TimeInterval?,
        onStdoutLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult
}
```

- [ ] **Step 2: Tests en `ProcessTests.swift`** (con el `SystemProcessRunner` real):
  - `/bin/sh -c 'echo uno; sleep 0.3; echo dos; printf tres'` entrega `["uno", "dos", "tres"]` en orden. La primera línea llega **antes** de que termine el proceso: guardá en un `Box<[Date]>` la hora de cada línea y verificá que la primera sea ≥ 0.2 s anterior a la última.
  - Una línea de 200.000 caracteres llega entera, como una sola línea.
  - El timeout y la cancelación se comportan igual que en `run` (reusá los casos existentes con `runStreaming`).
  - Una salida con UTF-8 multibyte partido entre dos `read()` (`printf 'añ\nñ\n'`) se decodifica bien: el buffer se divide por bytes `\n`, no por caracteres.

- [ ] **Step 3: Implementar.** `SystemProcessRunner` conforma `StreamingProcessRunning`. Refactorizá el loop de lectura existente para que acepte un callback opcional de stdout. `run(...)` llama al mismo camino sin callback, sin duplicar código. Acumulá los bytes en un buffer y emití una línea por cada `\n` (0x0A), decodificando cada línea completa con `String(decoding:as: UTF8.self)`.

- [ ] **Step 4: `FakeStreamingRunner` en `Fakes.swift`**: recibe un handler `(executable, args, cwd) -> (lines: [String], result: ProcessResult)` o un error; emite las líneas por el callback y guarda las llamadas (`executable`, `arguments`, `environment`, `currentDirectory`, `timeout`).

- [ ] **Step 5:** Suite verde. Commit `feat(core): stream stdout lines from child processes`.

---

### Task 4: Worktrees temporales

**Files:**
- Create: `Sources/PRBarCore/WorktreeManager.swift`, `Sources/PRBarTests/WorktreeTests.swift`
- Modify: `Sources/PRBarCore/Support.swift` (`AppPaths.worktreesDir` = `~/Library/Caches/PRBar/worktrees`)

**Contrato (spec §8.2):**

```swift
public struct ReviewWorkspace: Equatable, Sendable {
    /// Directorio donde corre Claude. Con clone local es el worktree; sin clone, una carpeta temporal vacía.
    public let directory: URL
    /// Ref de la base (`refs/prbar/base-<N>`) o nil en modo solo diff.
    public let baseRef: String?
    public let isDiffOnly: Bool
}

public struct WorktreeManager: Sendable {
    public init(runner: ProcessRunning, gitPath: String, root: URL = AppPaths.worktreesDir, now: @escaping @Sendable () -> Date = { Date() })
    /// Con `localPath`: fetch de `+pull/<N>/head:refs/prbar/pr-<N>` y `+refs/heads/<base>:refs/prbar/base-<N>`,
    /// después `worktree add --detach <root>/<repo>-<N>-<epoch> refs/prbar/pr-<N>`.
    /// Sin `localPath`: crea `<root>/<repo>-<N>-<epoch>-diff` vacío.
    public func prepare(repo: RepoRef, number: Int, baseRef: String, localPath: String?) async throws -> ReviewWorkspace
    /// `worktree remove --force`, `worktree prune`, `update-ref -d` de las dos refs y borrar la carpeta. Nunca lanza: los errores se loguean.
    public func cleanup(_ workspace: ReviewWorkspace, repo: RepoRef, number: Int, localPath: String?) async
    /// Al arrancar: borra todo `root`, y en cada `localPath`: `worktree prune` + `update-ref -d` de cada ref en `refs/prbar/`.
    public func cleanupOrphans(localPaths: [String]) async
}
```

- [ ] **Step 1: Tests con `FakeProcessRunner`**, verificando la lista exacta de comandos y argumentos:
  1. `prepare` con clone local corre, en orden:
     - `git -C <path> fetch origin +pull/42/head:refs/prbar/pr-42 +refs/heads/develop:refs/prbar/base-42`;
     - `git -C <path> worktree add --detach <root>/r-42-<epoch> refs/prbar/pr-42`.

     Devuelve `baseRef == "refs/prbar/base-42"` e `isDiffOnly == false`. Usá un `root` temporal y `now` fijo, así `<epoch>` es determinístico.
  2. Si el fetch falla, `prepare` lanza `PRBarError.commandFailed` con el stderr y no crea el worktree (la segunda llamada nunca ocurre).
  3. Sin `localPath`, `prepare` no corre git, crea la carpeta `-diff` y devuelve `isDiffOnly == true`, `baseRef == nil`.
  4. `cleanup` corre `worktree remove --force <dir>`, `worktree prune` y `update-ref -d refs/prbar/pr-42` + `update-ref -d refs/prbar/base-42`. Si alguno falla, sigue con el resto y borra la carpeta igual.
  5. `cleanupOrphans` corre `for-each-ref --format=%(refname) refs/prbar/` y después un `update-ref -d` por cada ref listada, más `worktree prune`, en cada path. Además vacía `root`.
- [ ] **Step 2: Implementar.** Fetch y worktree con timeout de 120 s; el resto con `ProcessTimeouts.standard`. El nombre del directorio es `"\(repo.name)-\(number)-\(Int(now().timeIntervalSince1970))"`.
- [ ] **Step 3:** Verde. Commit `feat(core): manage temporary review worktrees`.

---

### Task 5: ClaudeReviewer (dos etapas)

**Files:**
- Create: `Sources/PRBarCore/ClaudeReviewer.swift`, `Sources/PRBarTests/ClaudeReviewerTests.swift`
- Modify: `Sources/PRBarCore/ReviewHistory.swift` no existe todavía; los logs se escriben a una URL que recibe el reviewer.

**Contrato:**

```swift
public enum ReviewStage: Equatable, Sendable { case reviewing, filtering }

public struct ClaudeReviewer: Sendable {
    public static let stageTimeout: TimeInterval = 15 * 60
    public static let reviewTools = ["Read", "Grep", "Glob", "Agent", "Task", "Skill",
        "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)", "Bash(gh pr view:*)", "Bash(gh pr diff:*)"]
    public static let forbiddenTools = ["Edit", "Write", "NotebookEdit"]

    public init(runner: StreamingProcessRunning, claudePath: String, logURL: URL)
    /// Etapa 1 y etapa 2. `onProgress` se llama en el main actor con la etapa y la cantidad de subagentes.
    public func review(
        pr: PullRequest, workspace: ReviewWorkspace, token: String,
        onProgress: @escaping @MainActor @Sendable (ReviewStage, Int) -> Void
    ) async throws -> (summary: String, items: [ReviewItem])

    static func arguments(prompt: String, schema: String) -> [String]
    static func stageOnePrompt(pr: PullRequest, workspace: ReviewWorkspace) -> String
    static func stageTwoPrompt(pr: PullRequest, findingsJSON: String) -> String
}
```

**Argumentos** (`arguments`), en este orden:

```
-p <prompt> --output-format stream-json --verbose --json-schema <schema>
--allowedTools <reviewTools unidos con ",">  --disallowedTools Edit,Write,NotebookEdit
```

Entorno: `GH_TOKEN=<token>` y `cwd = workspace.directory`.

**Prompt de la etapa 1** (en español; los valores entre `<>` se completan):

```
Estás revisando el PR #<N> de <owner/repo>: "<title>" (autor @<author>, rama <headRef> → <baseRef>).
<si hay worktree:> El código del PR está en el directorio actual (HEAD). La base está en <workspace.baseRef>; el diff a revisar es `git diff <baseRef>...HEAD`.
<si es solo diff:> No hay checkout local: usá `gh pr diff <N> --repo <owner/repo>` y `gh pr view <N> --repo <owner/repo>` para leer el PR.
Usá el skill `pr-review-toolkit:review-pr` para hacer un review completo de ese diff. No modifiques ningún archivo.
Devolvé el resultado con la salida estructurada:
- summary: 2-3 líneas en español sobre qué hace el PR y su estado general.
- findings: un elemento por problema real. id "f1", "f2"…; severity high|medium|low; file: ruta relativa al repo;
  line: número de línea en la versión NUEVA del archivo (o null si no aplica a una línea); title: resumen de una línea en español;
  body: el comentario completo en Markdown, listo para publicar en GitHub, en el idioma predominante de los comentarios del repo (español si no está claro).
```

**Prompt de la etapa 2:**

```
Un review automático del PR #<N> de <owner/repo> ("<title>") produjo estos hallazgos:
<findingsJSON>
Usá el skill `superpowers:receiving-code-review` para evaluar cada uno con rigor técnico contra el código real
(el PR está en el directorio actual <o "usá gh pr diff" en modo solo diff>). No modifiques archivos.
Para cada hallazgo devolvé un veredicto: keep si es correcto y vale la pena comentarlo; discard si es incorrecto, no aplica,
es duplicado de otro, ya está cubierto (por CI, linters, middleware, etc.) o es una preferencia sin impacto.
reason: una línea en español explicando por qué.
```

**Comportamiento:**
- Cada etapa escribe todas sus líneas de stdout en `logURL` (append, con un encabezado `=== etapa 1 ===`). El stderr también va al log al terminar.
- Si una etapa termina con `ClaudeError.invalidOutput` o `.noResult`, se reintenta **una vez**, agregando al prompt: `\n\nEl intento anterior devolvió un resultado inválido (<detalle>). Respondé solo con la salida estructurada pedida.` Un segundo fallo se propaga.
- Si `findings` está vacío, se saltea la etapa 2.
- Un código de salida ≠ 0 sin `result` lanza `PRBarError.commandFailed(command: "claude", status:, stderr:)`.

- [ ] **Step 1: Tests** con `FakeStreamingRunner` y un `logURL` temporal:
  1. Los argumentos incluyen `-p`, `--output-format stream-json`, `--verbose`, `--json-schema <stageOne>`, `--allowedTools` con `Skill` y `Bash(gh pr diff:*)`, `--disallowedTools Edit,Write,NotebookEdit`; el entorno lleva `GH_TOKEN` y `cwd` es el workspace.
  2. Una corrida feliz devuelve `summary` e `items` combinados: la etapa 2 descarta `f2`, así que `keep == [true, false]`. `onProgress` recibe `(.reviewing, 0)`, `(.reviewing, 1)` cuando aparece un `Agent` y `(.filtering, 0)`.
  3. Si el primer intento de la etapa 1 trae JSON inválido, se reintenta y el segundo prompt contiene "El intento anterior devolvió un resultado inválido".
  4. Dos fallos seguidos propagan `ClaudeError.invalidOutput`.
  5. Sin hallazgos, solo hay 1 llamada al runner.
  6. El prompt en modo solo diff menciona `gh pr diff 7 --repo o/r` y no menciona `git diff`.
  7. El log contiene las líneas de las dos etapas.
- [ ] **Step 2: Implementar** según el contrato.
- [ ] **Step 3:** Verde. Commit `feat(core): run two-stage Claude review with schema-validated output`.

---

### Task 6: Pipeline y cola de reviews

**Files:**
- Create: `Sources/PRBarCore/ReviewPipeline.swift`, `Sources/PRBarCore/ReviewQueue.swift`, `Sources/PRBarTests/ReviewQueueTests.swift`

**Contrato:**

```swift
public struct ReviewRequest: Sendable {
    public let item: ClassifiedPR
    public let localPath: String?
    public let baseRef: String          // pr.baseRef
}

public protocol ReviewPipelineRunning: Sendable {
    /// Hace worktree → Claude → limpieza (la limpieza corre siempre, incluso con error o cancelación).
    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft
}

public enum ReviewPhase: Equatable, Sendable {
    case queued, preparing
    case reviewing(agents: Int)
    case filtering
    case ready(ReviewDraft)
    case failed(String, logURL: URL?)
    case published(URL)
}

@MainActor
public final class ReviewQueue: ObservableObject {
    @Published public private(set) var phases: [String: ReviewPhase]   // por prID
    public init(pipeline: ReviewPipelineRunning, maxConcurrent: Int = 2,
                onFinished: @escaping @MainActor (ReviewRequest, Result<ReviewDraft, Error>) -> Void)
    public func enqueue(_ request: ReviewRequest)     // ignora si ya hay un job activo o en cola para ese PR
    public func cancel(prID: String)                  // cancela la Task; la fase se borra (vuelve a idle)
    public func markPublished(prID: String, url: URL)
    public func dismiss(prID: String)                 // borra failed/ready/published (vuelve a idle)
    public func restore(_ draft: ReviewDraft)         // .ready(draft), para reabrir desde el historial
}
```

- `ReviewPipeline` (implementación real): resuelve el token con `TokenProviding` (cuenta `item.account`), llama a `WorktreeManager.prepare`, después a `ClaudeReviewer.review` y arma el `ReviewDraft`. Cleanup siempre en un `defer` asíncrono (usá `do/catch` + cleanup explícito antes de relanzar). El log va a `ReviewHistory.logURL(for: draftID)`, definido en la Task 8; en esta tarea, recibí un `logURLProvider: @Sendable (UUID) -> URL` en el init.
- La cancelación se propaga a los procesos: `withTaskCancellationHandler` en el runner ya mata al hijo.

- [ ] **Step 1: Tests** con un `FakePipeline` que permite suspender cada job (un `CheckedContinuation` por prID) y completarlo a mano:
  1. Con 3 encolados y máximo 2, quedan 2 corriendo y 1 `.queued`. Al terminar uno, arranca el tercero.
  2. Las fases que manda `onPhase` se reflejan en `phases`.
  3. Si un pipeline exitoso termina, la fase queda `.ready(draft)` y se llama a `onFinished` con `.success`.
  4. Un error deja `.failed(mensaje, logURL)` y `onFinished` recibe `.failure`.
  5. `cancel` de un job corriendo borra la fase, no llama a `onFinished` con éxito y libera el lugar para el siguiente en cola.
  6. `cancel` de uno en cola lo saca de la cola.
  7. Encolar el mismo PR dos veces no duplica.
  8. Para `ReviewPipeline` real, con `FakeProcessRunner` + `FakeStreamingRunner` + `FakeTokens`: el cleanup corre cuando Claude falla, y el draft lleva `headOid`, `account` y `url` del PR.
- [ ] **Step 2: Implementar.**
- [ ] **Step 3:** Verde. Commit `feat(core): queue Claude reviews with concurrency limit and cancellation`.

---

### Task 7: Publicación en GitHub

**Files:**
- Create: `Sources/PRBarCore/DiffLineMap.swift`, `Sources/PRBarCore/ReviewPublisher.swift`, `Sources/PRBarTests/ReviewPublisherTests.swift`
- Modify: `Sources/PRBarCore/GitHubClient.swift`, `Sources/PRBarTests/Fakes.swift` (`FakeAPI` implementa los métodos nuevos)

- [ ] **Step 1: `DiffLineMap`.** Código completo:

```swift
import Foundation

/// Líneas comentables (lado RIGHT) por archivo, a partir de los `patch` de `GET /pulls/{n}/files`.
/// En GitHub se puede comentar en líneas agregadas y de contexto dentro de un hunk.
public struct DiffLineMap: Equatable, Sendable {
    private var lines: [String: Set<Int>] = [:]

    public init(files: [(filename: String, patch: String?)]) {
        for file in files {
            guard let patch = file.patch else { continue }
            lines[file.filename] = Self.commentableLines(in: patch)
        }
    }

    public func contains(file: String, line: Int) -> Bool {
        lines[file]?.contains(line) ?? false
    }

    static func commentableLines(in patch: String) -> Set<Int> {
        var result: Set<Int> = []
        var newLine = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = Substring(raw)
            if line.hasPrefix("@@") {
                // @@ -a,b +c,d @@
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    newLine = Int(plus.dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
            } else if line.hasPrefix("+") {
                result.insert(newLine)
                newLine += 1
            } else if line.hasPrefix("-") || line.hasPrefix("\\") {
                continue
            } else {
                result.insert(newLine)
                newLine += 1
            }
        }
        return result
    }
}
```

- [ ] **Step 2: `ReviewPublisher`.** Código completo:

```swift
import Foundation

public enum ReviewEvent: String, Codable, Sendable {
    case comment = "COMMENT"
    case requestChanges = "REQUEST_CHANGES"
    case approve = "APPROVE"
}

public struct ReviewSubmission: Equatable, Sendable {
    public struct InlineComment: Equatable, Sendable {
        public let path: String
        public let line: Int
        public let body: String
    }
    public let commitID: String
    public let event: ReviewEvent
    public let body: String
    public let comments: [InlineComment]
}

/// Un hallazgo elegido por el usuario, con el texto final (posiblemente editado).
public struct SelectedComment: Equatable, Sendable {
    public let finding: ReviewFinding
    public let body: String

    public init(finding: ReviewFinding, body: String) {
        self.finding = finding
        self.body = body
    }
}

public enum ReviewPublisher {
    public static func build(
        draft: ReviewDraft, selected: [SelectedComment], generalComment: String, event: ReviewEvent, lineMap: DiffLineMap
    ) throws -> ReviewSubmission {
        var inline: [ReviewSubmission.InlineComment] = []
        var unanchored: [String] = []
        for comment in selected {
            let text = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let line = comment.finding.line, lineMap.contains(file: comment.finding.file, line: line) {
                inline.append(.init(path: comment.finding.file, line: line, body: text))
            } else {
                unanchored.append("**\(comment.finding.location)** — \(text)")
            }
        }
        let body = ([generalComment.trimmingCharacters(in: .whitespacesAndNewlines)] + unanchored)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if event != .approve && body.isEmpty && inline.isEmpty {
            throw PRBarError.invalidResponse("Elegí al menos un comentario o escribí uno general.")
        }
        return ReviewSubmission(commitID: draft.headOid, event: event, body: body, comments: inline)
    }
}
```

> Nota: el error de validación reusa `PRBarError.invalidResponse` solo si no existe uno mejor. Preferí agregar `PRBarError.emptyReview` con el mensaje "Elegí al menos un comentario o escribí uno general." y usarlo acá (ajustá el test).

- [ ] **Step 3: Métodos nuevos en `GitHubAPI` / `GitHubClient`:**
  - `func pullRequestFiles(repo: RepoRef, number: Int, token: String) async throws -> [(filename: String, patch: String?)]`. Hace `GET /repos/{o}/{r}/pulls/{n}/files?per_page=100&page=K`, paginando hasta que una página traiga menos de 100 o se llegue a 30 páginas. Como las tuplas no son `Equatable`, devolvé un `struct PRFile: Equatable, Sendable { filename, patch }` y adaptá el init de `DiffLineMap` para aceptarlo.
  - `func submitReview(repo: RepoRef, number: Int, submission: ReviewSubmission, token: String) async throws -> URL`. Hace `POST /repos/{o}/{r}/pulls/{n}/reviews` con `{"commit_id","event","body","comments":[{"path","line","side":"RIGHT","body"}]}` y devuelve el `html_url` de la respuesta. Usá el mismo `perform`, para mapear 401, 403 y 429. Un 422 se mapea a `.http(422, message)` con el mensaje de GitHub.

- [ ] **Step 4: Tests:**
  - `DiffLineMap`: un patch con dos hunks (`@@ -1,3 +1,4 @@` y `@@ -10,2 +11,3 @@`) donde las líneas agregadas, las de contexto y las borradas se mapean bien; un archivo sin patch (binario) no tiene líneas.
  - `ReviewPublisher`:
    - los comentarios en líneas del diff van inline;
    - los que tienen línea fuera del diff o `line == nil` van al body con el formato `**a.rb:99** — texto`;
    - el comentario general va primero;
    - un texto vacío se ignora;
    - `COMMENT` sin nada lanza el error;
    - `APPROVE` sin nada es válido;
    - `commitID == draft.headOid`.
  - `GitHubClient`:
    - `submitReview` manda el método, la URL y el JSON esperados (incluido `side: RIGHT`) y devuelve el `html_url`;
    - un 422 se convierte en `.http(422, "Unprocessable…")`;
    - `pullRequestFiles` pagina (100 + 3 archivos → 2 requests).
- [ ] **Step 5:** Verde. Commit `feat(core): build and submit GitHub reviews with inline comments`.

---

### Task 8: Historial

**Files:**
- Create: `Sources/PRBarCore/ReviewHistory.swift`, `Sources/PRBarTests/ReviewHistoryTests.swift`
- Modify: `Sources/PRBarCore/Support.swift` (`AppPaths.historyDir` = `appSupport/history`)

```swift
public struct ReviewRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case ready, failed, published, abandoned }
    public enum Action: String, Codable, Sendable { case approve, requestChanges, comment, none }
    public var id: UUID { draft.id }
    public var draft: ReviewDraft
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var errorMessage: String?
    /// Textos finales publicados, por id de hallazgo.
    public var published: [String: String]
    public var generalComment: String?
    public var action: Action
    public var reviewURL: URL?
    public var kind: String = "review"   // "respond" en el Plan 3
}

public struct ReviewHistory: Sendable {
    public init(directory: URL = AppPaths.historyDir)
    public func save(_ record: ReviewRecord) throws          // <dir>/<uuid>.json, atómico
    public func all() -> [ReviewRecord]                     // ordenado por startedAt desc; ignora y loguea archivos ilegibles
    public func logURL(for id: UUID) -> URL                 // <dir>/logs/<uuid>.jsonl
}
```

- [ ] **Step 1: Tests:**
  - guardar y leer un registro;
  - `all()` ordena del más nuevo al más viejo;
  - un archivo corrupto se ignora sin romper el resto;
  - `logURL` queda dentro de `logs/`;
  - un mismo id se sobrescribe (un registro pasa de `ready` a `published`).
- [ ] **Step 2: Implementar.** **Step 3:** Commit `feat(core): persist review history and logs`.

---

### Task 9: Notificación de review listo

**Files:**
- Modify: `Sources/PRBarCore/NotificationPlanner.swift`, `Sources/PRBarTests/NotificationPlannerTests.swift`

- [ ] Agregar `PlannedNotification.reviewPRID: String?` (default nil) y:

```swift
extension NotificationPlanner {
    public static func reviewFinished(prID: String, repo: RepoRef, number: Int, keptCount: Int?, settings: NotificationSettings) -> PlannedNotification? {
        guard settings.isOn(.reviewFinished) else { return nil }
        let body = keptCount.map { "\(repo.name)#\(number): \($0) comentario\($0 == 1 ? "" : "s") para elegir" }
            ?? "\(repo.name)#\(number): el review falló. Abrí PRBar para ver el log."
        return PlannedNotification(kind: .reviewFinished, title: keptCount == nil ? "Falló el review" : "Review listo",
                                   body: body, url: nil, reviewPRID: prID)
    }
}
```

- [ ] Tests:
  - con éxito: título "Review listo", body "r#7: 3 comentarios para elegir", `reviewPRID` cargado;
  - con 1 comentario: singular;
  - con falla: "Falló el review";
  - con el toggle apagado: nil.
- [ ] Commit `feat(core): notify when a Claude review finishes`.

---

### Task 10: Botón Review y cableado de la app

**Files:**
- Create: `Sources/PRBar/Review/ReviewButton.swift`
- Modify: `Sources/PRBar/AppModel.swift`, `Sources/PRBar/Popover/PRRowView.swift`, `Sources/PRBar/Popover/PopoverView.swift`, `Sources/PRBar/PRBarApp.swift`, `Sources/PRBar/NotificationDelivery.swift`

- [ ] **`AppModel`:**
  - Crear `let reviews: ReviewQueue` y `let history = ReviewHistory()`.
  - El `ReviewPipeline` real se arma con `runner`, `accounts` (tokens) y la ruta de `claude`/`git` resueltas. Si falta `claude` o `git`, `enqueue` no se llama: se muestra el error en la fila (fase `.failed(PRBarError.toolNotFound(...).localizedDescription, nil)`). Exponé `func startReview(_ item: ClassifiedPR)`, que busca el `localPath` del repo en la config de la cuenta del item.
  - `onFinished`:
    - guarda un `ReviewRecord`: `.ready` con el draft, o `.failed` con el mensaje (para un draft fallido, armá uno con `items: []` y `summary: ""`);
    - entrega `NotificationPlanner.reviewFinished(...)`.
  - En `bootstrap()`, después de `resolveTools()`, corre `WorktreeManager(...).cleanupOrphans(localPaths:)` con todos los `localPath` configurados (spec §11).
  - `func openReview(prID:)`: si la fase es `.ready(draft)` o `.published`, abre la ventana de Review (Task 11) con `WindowPresenter.shared.show(id: "review-\(prID)", title: "Review · \(draft.repo.name)#\(draft.number)", size: NSSize(width: 720, height: 640))`.
  - `func openHistory()`: abre la ventana de Historial (Task 12), 760×520.
- [ ] **`NotificationDelivery`:** guardar `reviewPRID` en `userInfo`. Al hacer click, si viene, llamar a un closure `onOpenReview: (String) -> Void` (que `AppModel` asigna a `openReview`); si no viene, abrir la URL como ahora.
- [ ] **`ReviewButton.swift`:** según `docs/design/ReviewButtons.dc.html` y `Popover.dc.html`. Alto 20, radio 6, fuente 11 medium.

| Fase | Aspecto | Acción |
|---|---|---|
| idle (sin fase) | "Review", estilo `.bordered` `.controlSize(.small)` | `startReview` |
| `.queued` | `pause.fill` + "En cola", fondo `fill`, texto secundario | hover muestra `xmark.circle.fill` → cancel |
| `.preparing` | `hourglass` + "Preparando…", violeta sobre `tint(violet)` | hover → cancel |
| `.reviewing(n)` | `ProgressView().controlSize(.mini)` + "Revisando…" (tooltip "n agentes") | hover → cancel |
| `.filtering` | `line.3.horizontal.decrease` + "Filtrando…" | hover → cancel |
| `.ready(d)` | `checkmark.circle.fill` + "N comentarios" (N = `d.keptCount`), verde, semibold | `openReview` |
| `.failed` | `exclamationmark.triangle.fill` + "Error", rojo; tooltip con el mensaje | menú: "Ver log", "Reintentar", "Descartar" |
| `.published` | `checkmark.seal.fill` + "Publicado", verde | abre la URL de la review |

- [ ] **`PRRowView`:** en `trailingAccessory`, para `.toReview` y `.updatedSinceMyReview`, mostrar `ReviewButton(phase: reviews.phases[item.id], …)`. Pasá `ReviewQueue` como `@ObservedObject` desde `PopoverView`. El tap del botón **no** debe disparar el `onTapGesture` de la fila: usá un `Button` real y `.buttonStyle`, sin gestures superpuestos.
- [ ] **`PopoverView`:** en el menú del engranaje, agregar "Historial…" → `model.openHistory()` antes de "Configuración…".
- [ ] Compilar. Sin tests de UI. Commit `feat(app): add Review button with live progress and wire the review queue`.

---

### Task 11: Ventana de Review

**Files:**
- Create: `Sources/PRBar/Review/ReviewWindow.swift`
- Modify: `Sources/PRBar/AppModel.swift` (publicar)

Referencia: `docs/design/ReviewWindow.dc.html` (estados default, discarded y published).

- [ ] **Estructura** (720×640, `.windowResizability(.contentMinSize)`):
  - **Header:** `repo#N` en monoespaciada, link "Abrir en GitHub" con `arrow.up.right`, título 17 semibold, y una línea con avatar + autor · `head → base` en chips mono · `+adds −dels`.
  - **Resumen de Claude:** caja con fondo `tint(violet)`, `sparkles` + "Resumen de Claude" y el `draft.summary`.
  - **Aviso de PR desactualizado:** si el `headOid` actual del PR en `prStore.snapshot` es distinto de `draft.headOid`, mostrar la barra naranja "El PR cambió desde esta review" con el botón "Volver a revisar", que llama a `dismiss` + `startReview`.
  - **Barra de selección:** "X de Y seleccionados" + botones "Todos" y "Ninguno".
  - **Tarjetas** de los `keep` (tildadas por defecto). Cada una tiene:
    - checkbox, punto de color de severidad + `severity.label`, `finding.location` en mono 11;
    - `finding.title` en 13;
    - "▸ ver comentario completo", que abre un `TextEditor` mono 11.5 de 150 de alto con el `body` editable y la leyenda "Markdown · se publica en la línea N" o "se publica en el comentario general" si no hay línea.
  - **Sección colapsada "Descartados por el filtro (n)"** · "Claude los marcó como no aplicables": tarjetas grises sin tildar, con `line.3.horizontal.decrease` + `reason` y la acción "Incluir igual" / "Quitar".
  - **Footer fijo** (`.safeAreaInset(edge: .bottom)`):
    - campo "Comentario general (opcional)";
    - la leyenda "Se publica como @<account> · K comentarios";
    - los botones **Comentar** (normal), **Pedir cambios** (naranja) y **Aprobar** (verde, `.keyboardShortcut(.defaultAction)`).
- [ ] **Estado local** de la vista: `selected: Set<String>`, `edited: [String: String]`, `general`, `publishing`, `error: String?`. Se inicializa con los `keep`.
- [ ] **`AppModel.publish(draft:selected:general:event:) async throws -> URL`:**
  1. token de `draft.account`;
  2. `pullRequestFiles`;
  3. `DiffLineMap`;
  4. `ReviewPublisher.build`;
  5. `submitReview`;
  6. `reviews.markPublished`;
  7. actualizar el `ReviewRecord` (`.published`, `published`, `action`, `reviewURL`, `finishedAt`);
  8. refrescar `prStore`.

  Si falla, se lanza el error: la vista lo muestra y **conserva** la selección y lo editado (spec §8.7).
- [ ] **Estado publicado:** ícono verde 52, "Publicado ✓", pill con la acción y "N comentarios en línea · 1 comentario general · hace unos segundos", botones "Ver en GitHub" y "Cerrar".
- [ ] **Al cerrar** sin publicar, el `ReviewRecord` queda `.ready`; se puede reabrir desde el historial mientras el PR no cambie (§10).
- [ ] Compilar, instalar (`Scripts/bundle.sh --install`). Commit `feat(app): add review window to pick, edit and publish findings`.

---

### Task 12: Ventana de Historial

**Files:**
- Create: `Sources/PRBar/Review/HistoryWindow.swift`

Referencia: `docs/design/HistoryWindow.dc.html`.

- [ ] `NavigationSplitView` con sidebar de 290:
  - `.searchable` (por título, repo o número);
  - `Picker` "Todos los repos" / cada repo;
  - lista agrupada por "Hoy", "Esta semana" y "Antes". Cada fila tiene `repo#N`, fecha corta, título en una línea y una pill con la acción: Aprobado (verde), Cambios pedidos (naranja), Comentado (gris), Sin publicar (azul) o Falló (rojo).
- [ ] **Detalle** (solo lectura): `repo#N` + "Abrir PR", título, autor · fecha · acción, caja "Resumen", "Publicados (n)" con `location` + título y "Descartados (n)" con la razón. Botones:
  - "Ver log de Claude" abre el `.jsonl` con `NSWorkspace.shared.open`;
  - "Abrir para publicar" aparece si el registro es `.ready` y el `headOid` del PR no cambió, y llama a `reviews.restore(draft)` + `openReview`.
- [ ] Se recarga con `history.all()` al aparecer y cada vez que termina o se publica una review (un `@Published var historyRevision` en `AppModel`).
- [ ] Compilar, instalar. Commit `feat(app): add review history window`.

---

### Task 13: QA manual

- [ ] Crear `docs/qa/plan-2-checklist.md`:

```markdown
# QA manual — Plan 2 (Review con Claude)

- [ ] En un PR ajeno de un repo con carpeta local: Review → En cola/Preparando → Revisando… (tooltip con agentes) → Filtrando… → "N comentarios".
- [ ] `git worktree list` en el clone durante el review muestra el worktree temporal; al terminar ya no está. `git branch` no cambió; `git for-each-ref refs/prbar/` vacío al terminar.
- [ ] Llega la notificación "Review listo"; click abre la ventana.
- [ ] La ventana coincide con docs/design/ReviewWindow.dc.html (claro y oscuro). Editar un comentario, destildar otro, incluir un descartado.
- [ ] Publicar como "Comentar" en un PR de prueba propio de otra cuenta → en GitHub aparece una sola review con comentarios inline y los fuera del diff en el cuerpo.
- [ ] Cortar la red y publicar → error visible, la selección y lo editado se conservan; reconectar y publicar funciona.
- [ ] Cancelar un review en curso → el botón vuelve a "Review"; no quedan procesos `claude` (`pgrep -fl claude`) ni worktrees.
- [ ] Tres reviews a la vez → el tercero queda "En cola" hasta que termina uno.
- [ ] Repo sin carpeta local → el review funciona en modo solo diff.
- [ ] Sin `claude` en el PATH (ruta personalizada inválida en General) → el botón muestra Error con mensaje claro.
- [ ] Historial lista los reviews; el detalle muestra publicados/descartados; "Ver log" abre el .jsonl; uno sin publicar se puede reabrir.
- [ ] Matar la app durante un review y volver a abrirla → los worktrees huérfanos se limpian al arrancar.
```

- [ ] Commit `docs: add manual QA checklist for Claude reviews`.
