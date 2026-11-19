# PRBar — Plan 4: Bot de Slack

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Anunciar en Slack los PRs nuevos del usuario, y publicar "Updated" en el hilo cuando pushea después de recibir code review, con un canal configurable por repo (spec §15).

**Architecture:**
- Todo lo testeable vive en `PRBarCore`:
  - `SlackPlanner`: función pura que decide qué anunciar a partir del `Snapshot`, la config y el estado guardado;
  - `SlackClient`: HTTP a la API de Slack, sobre el `HTTPTransport` existente;
  - `KeychainStore`: el token;
  - `SlackStateStore`: lo ya anunciado;
  - `SlackAnnouncer`: orquesta los anteriores y publica `issues` para la UI.
- `AppModel` llama al announcer después de cada refresco, en el mismo `onChange` que las notificaciones.
- La UI suma la pestaña **Slack**, un selector de canal en **Repos** y los errores de Slack en el popover.

**Tech Stack:** Swift 5.10, SwiftUI, Security.framework (Keychain), Slack Web API (`chat.postMessage`, `auth.test`, `conversations.list`).

**Spec:** `docs/superpowers/specs/2026-11-18-prbar-design.md` §15. **Base:** rama `feat/plan-1-menubar` con el Plan 1 terminado (106 tests).

**Convenciones:**
- Tests: `swift run PRBarTests [filtro]`. Los helpers `expect`/`expectEqual` reciben autoclosures **no async**: cualquier `await` va antes, en una variable local.
- Commits en inglés, **sin** `Co-Authored-By` ni atribución a Claude. Sin push.
- Textos de la UI en español rioplatense.

## Estructura de archivos

```
Sources/PRBarCore/
  Config.swift            (modificar) SlackSettings, campos de Slack en RepoConfig, setSlackChannel
  Support.swift           (modificar) PRBarError.slack / .keychain, AppPaths.slackStateFile
  Snapshot.swift          (modificar) RefreshIssue.message para account "slack"
  SlackTemplate.swift     render de plantillas
  SlackState.swift        SlackAnnouncement, SlackState, SlackStateStore
  SlackPlanner.swift      SlackAction, SlackPlan, SlackPlanner
  SlackClient.swift       SlackChannel, SlackIdentity, SlackAPI, SlackClient
  KeychainStore.swift     SecretStore, KeychainStore
  SlackAnnouncer.swift    orquestador (@MainActor ObservableObject)
Sources/PRBarTests/
  SlackConfigTests.swift  SlackPlannerTests.swift  SlackClientTests.swift  SlackAnnouncerTests.swift
  Fakes.swift             (modificar) FakeSlackAPI, FakeSecrets
Sources/PRBar/
  AppModel.swift          (modificar) crear y llamar al announcer
  PRBarApp.swift          (modificar) pasar slack al popover
  Popover/PopoverView.swift (modificar) mostrar slack.issues
  Settings/SettingsView.swift (modificar) pestaña Slack, pasar slack a ReposTab
  Settings/SlackTab.swift   nueva pestaña
  Settings/ReposTab.swift   (modificar) selector de canal
```

---

### Task 1: Config, errores y plantillas

**Files:**
- Modify: `Sources/PRBarCore/Config.swift`, `Sources/PRBarCore/Support.swift`, `Sources/PRBarCore/Snapshot.swift`, `Sources/PRBarTests/main.swift`
- Create: `Sources/PRBarCore/SlackTemplate.swift`, `Sources/PRBarTests/SlackConfigTests.swift`

- [ ] **Step 1: Escribir `Sources/PRBarTests/SlackConfigTests.swift`**

```swift
import Foundation
import PRBarCore

enum SlackConfigTests {
    static let cases: [TestCase] = [
        TestCase("slack config: defaults y JSON viejo sin slack") {
            let json = #"{"accounts":[{"login":"me","repos":[{"owner":"o","name":"r"}]}]}"#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expectEqual(config.slack.enabled, false)
            try expectEqual(config.slack.newPRTemplate, "{link}")
            try expectEqual(config.slack.updateTemplate, "Updated {link}")
            try expectEqual(config.accounts[0].repos[0].slackChannelID, nil)
            try expectEqual(config.accounts[0].repos[0].slackEnabledAt, nil)
        },
        TestCase("slack config: elegir canal guarda la fecha; repetirlo no la cambia; quitarlo limpia") {
            var config = AppConfig()
            config.setAccountEnabled("me", true)
            config.addRepo(RepoRef(owner: "o", name: "r"), to: "me")
            config.setSlackChannel(id: "C1", name: "prs", repoID: "o/r", login: "me", now: at(0))
            config.setSlackChannel(id: "C1", name: "prs", repoID: "o/r", login: "me", now: at(10))
            var repo = config.accounts[0].repos[0]
            try expectEqual(repo.slackChannelID, "C1")
            try expectEqual(repo.slackChannelName, "prs")
            try expectEqual(repo.slackEnabledAt, at(0))
            config.setSlackChannel(id: "C2", name: "otro", repoID: "o/r", login: "me", now: at(20))
            try expectEqual(config.accounts[0].repos[0].slackEnabledAt, at(20))
            config.setSlackChannel(id: nil, name: nil, repoID: "o/r", login: "me", now: at(30))
            repo = config.accounts[0].repos[0]
            try expectEqual(repo.slackChannelID, nil)
            try expectEqual(repo.slackChannelName, nil)
            try expectEqual(repo.slackEnabledAt, nil)
        },
        TestCase("slack config: round-trip JSON con canal") {
            var config = AppConfig()
            config.slack.enabled = true
            config.setAccountEnabled("me", true)
            config.addRepo(RepoRef(owner: "o", name: "r"), to: "me")
            config.setSlackChannel(id: "C1", name: "prs", repoID: "o/r", login: "me", now: t0)
            let data = try JSONCoding.encoder.encode(config)
            try expectEqual(try JSONCoding.decoder.decode(AppConfig.self, from: data), config)
        },
        TestCase("slack template: reemplaza variables y escapa texto para Slack") {
            let pr = PullRequest(
                repo: RepoRef(owner: "o", name: "r"), number: 7, title: "Fix <b> & stuff",
                url: URL(string: "https://github.com/o/r/pull/7")!, isDraft: false, author: "me", authorAvatarURL: nil,
                baseRef: "main", headRef: "f", headOid: "x", additions: 1, deletions: 1,
                createdAt: t0, updatedAt: t0, lastCommitAt: t0, ciState: .success, reviewDecision: .none,
                reviews: [], comments: [], requestedReviewers: []
            )
            try expectEqual(SlackTemplate.render("{link}", pr: pr), "https://github.com/o/r/pull/7")
            try expectEqual(SlackTemplate.render("{repo}#{number} {title} por {author} {nada}", pr: pr),
                            "r#7 Fix &lt;b&gt; &amp; stuff por me {nada}")
            try expectEqual(SlackTemplate.render("Updated {link", pr: pr), "Updated {link")
        },
        TestCase("slack issue: mensaje con prefijo Slack y pista para not_in_channel") {
            let issue = RefreshIssue(account: "slack", repo: RepoRef(owner: "o", name: "r"), error: .slack("not_in_channel"))
            try expect(issue.message.hasPrefix("Slack · r:"))
            try expect(issue.message.contains("/invite"))
            try expect(!issue.requiresLogin)
        },
    ]
}
```

- [ ] **Step 2: Registrar `+ SlackConfigTests.cases` en `allTests` de `main.swift`**

- [ ] **Step 3: Correr y ver que falla**

Run: `swift run PRBarTests "slack"`
Expected: error de compilación (`value of type 'AppConfig' has no member 'slack'`).

- [ ] **Step 4: Agregar `SlackSettings` y los campos de Slack en `Config.swift`**

Antes de `public struct AppConfig`, agregar:

```swift
public struct SlackSettings: Hashable, Codable, Sendable {
    public var enabled = false
    public var newPRTemplate = "{link}"
    public var updateTemplate = "Updated {link}"

    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, newPRTemplate, updateTemplate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        newPRTemplate = try c.decodeIfPresent(String.self, forKey: .newPRTemplate) ?? "{link}"
        updateTemplate = try c.decodeIfPresent(String.self, forKey: .updateTemplate) ?? "Updated {link}"
    }
}
```

En `AppConfig`:
- agregar la propiedad `public var slack = SlackSettings()`;
- agregar `slack` a `CodingKeys`;
- en `init(from:)`, agregar `slack = try c.decodeIfPresent(SlackSettings.self, forKey: .slack) ?? SlackSettings()`.

En `RepoConfig`:
- agregar `public var slackChannelID: String?`, `public var slackChannelName: String?` y `public var slackEnabledAt: Date?`;
- agregar los tres a `CodingKeys` y decodificarlos con `decodeIfPresent`;
- extender el init público con `slackChannelID: String? = nil, slackChannelName: String? = nil, slackEnabledAt: Date? = nil` al final, asignándolos.

En la extensión de mutaciones, junto a `setLocalPath`:

```swift
    /// Elegir un canal distinto guarda `now` como `slackEnabledAt` (spec §15.1): solo se anuncian
    /// PRs posteriores. Volver a elegir el mismo canal no cambia nada; `id == nil` quita el canal.
    public mutating func setSlackChannel(id: String?, name: String?, repoID: String, login: String, now: Date = Date()) {
        withRepo(repoID, login: login) { repo in
            guard repo.slackChannelID != id else { return }
            repo.slackChannelID = id
            repo.slackChannelName = id == nil ? nil : name
            repo.slackEnabledAt = id == nil ? nil : now
        }
    }
```

- [ ] **Step 5: Agregar errores y la ruta del estado en `Support.swift`**

En `PRBarError` agregar los casos `case slack(String)` y `case keychain(Int32)`. En `errorDescription`:

```swift
        case .slack(let code):
            switch code {
            case "not_in_channel": "El bot no está en el canal. Invitalo con /invite @<nombre del bot>."
            case "channel_not_found": "No se encontró el canal configurado. Elegilo de nuevo en Configuración → Repos."
            case "invalid_auth", "token_revoked", "not_authed", "account_inactive":
                "El token de Slack no es válido. Revisalo en Configuración → Slack."
            case "missing_token": "Falta el token del bot. Pegalo en Configuración → Slack."
            case "missing_scope": "Al bot le falta un permiso (chat:write, channels:read o groups:read)."
            default: "Error de Slack: \(code)"
            }
        case .keychain(let status):
            "No se pudo acceder al Llavero (código \(status))."
```

En `AppPaths` agregar `public static var slackStateFile: URL { appSupport.appendingPathComponent("slack-state.json") }`.

- [ ] **Step 6: Mensajes de Slack en `RefreshIssue.message` (`Snapshot.swift`)**

Al principio de `message`, agregar:

```swift
        if account == "slack" {
            return "Slack\(repo.map { " · \($0.name)" } ?? ""): \(error.localizedDescription)"
        }
```

- [ ] **Step 7: Crear `Sources/PRBarCore/SlackTemplate.swift`**

```swift
import Foundation

/// Plantillas de mensajes de Slack. Variables: {link} {title} {number} {repo} {author}.
/// Los valores de texto se escapan para mrkdwn (&, <, >); el texto fijo de la plantilla no,
/// así el usuario puede usar sintaxis de Slack como <@U123>.
public enum SlackTemplate {
    public static func render(_ template: String, pr: PullRequest) -> String {
        let values: [String: String] = [
            "link": pr.url.absoluteString,
            "title": escape(pr.title),
            "number": "\(pr.number)",
            "repo": escape(pr.repo.name),
            "author": escape(pr.author),
        ]
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "}"), let value = values[String(rest[afterOpen..<close])] {
                result += value
                rest = rest[rest.index(after: close)...]
            } else {
                result += "{"
                rest = rest[afterOpen...]
            }
        }
        return result + rest
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
```

- [ ] **Step 8: Correr todo y ver que pasa**

Run: `swift run PRBarTests`
Expected: todos `✓` (111). Si algún `switch` sobre `PRBarError` deja de ser exhaustivo en otro archivo, agregar los casos nuevos ahí.

- [ ] **Step 9: Commit**

```bash
git add Sources
git commit -m "feat(core): add Slack settings, per-repo channel and message templates"
```

---

### Task 2: Estado y planificador de Slack

**Files:**
- Create: `Sources/PRBarCore/SlackState.swift`, `Sources/PRBarCore/SlackPlanner.swift`, `Sources/PRBarTests/SlackPlannerTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir `Sources/PRBarTests/SlackPlannerTests.swift`**

```swift
import Foundation
import PRBarCore

private let repo = RepoRef(owner: "o", name: "r")

func slackConfig(enabled: Bool = true, channel: String? = "C1", enabledAt: Date = at(-120)) -> AppConfig {
    var config = AppConfig()
    config.slack.enabled = enabled
    config.accounts = [AccountConfig(login: "me", repos: [
        RepoConfig(owner: "o", name: "r", slackChannelID: channel, slackChannelName: channel, slackEnabledAt: channel == nil ? nil : enabledAt),
    ])]
    return config
}

func slackSnap(_ prs: PullRequest..., fetched: Bool = true) -> Snapshot {
    Snapshot(items: prs.map { ClassifiedPR(pr: $0, category: .other, account: "me") }, fetchedAt: t0,
             fetchedScopes: fetched ? ["me|o/r"] : [])
}

func myPR(number: Int = 1, isDraft: Bool = false, lastCommit: Int = 0, reviews: [PRReview] = []) -> PullRequest {
    makePR(number: number, author: "me", isDraft: isDraft, lastCommit: lastCommit, reviews: reviews)
}

private func announced(ts: String = "111.1", channel: String = "C9", at minutes: Int = 0, lastUpdate: Int? = nil) -> SlackState {
    var state = SlackState()
    state.announcements["o/r#1"] = SlackAnnouncement(channelID: channel, ts: ts, announcedAt: at(minutes), lastUpdatePostedAt: lastUpdate.map { at($0) })
    return state
}

enum SlackPlannerTests {
    static let cases: [TestCase] = [
        TestCase("slack planner: desactivado no hace nada") {
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(enabled: false), state: SlackState()), SlackPlan())
        },
        TestCase("slack planner: PR nuevo posterior al canal → anuncio") {
            let plan = SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(), state: SlackState())
            try expectEqual(plan.actions, [.announce(prID: "o/r#1", repo: repo, channelID: "C1", text: "https://github.com/o/r/pull/1")])
        },
        TestCase("slack planner: PR anterior a configurar el canal → nada") {
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(enabledAt: at(-30)), state: SlackState()), SlackPlan())
        },
        TestCase("slack planner: draft se recuerda y se anuncia al pasar a ready") {
            let draftPlan = SlackPlanner.plan(snapshot: slackSnap(myPR(isDraft: true)), config: slackConfig(enabledAt: at(-30)), state: SlackState())
            try expectEqual(draftPlan.actions, [])
            try expectEqual(draftPlan.newDrafts, ["o/r#1"])
            var state = SlackState()
            state.seenAsDraft = ["o/r#1"]
            let readyPlan = SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(enabledAt: at(-30)), state: state)
            try expectEqual(readyPlan.actions.count, 1)
            try expectEqual(readyPlan.newDrafts, [])
        },
        TestCase("slack planner: sin datos frescos del repo → nada") {
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR(), fetched: false), config: slackConfig(), state: SlackState()), SlackPlan())
        },
        TestCase("slack planner: PRs ajenos o repos sin canal → nada") {
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(makePR(author: "juan")), config: slackConfig(), state: SlackState()), SlackPlan())
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(channel: nil), state: SlackState()), SlackPlan())
        },
        TestCase("slack planner: review y después push → Updated en el hilo del anuncio") {
            let pr = myPR(lastCommit: 20, reviews: [review("ana", .changesRequested, at: 10)])
            let plan = SlackPlanner.plan(snapshot: slackSnap(pr), config: slackConfig(), state: announced())
            try expectEqual(plan.actions, [.update(prID: "o/r#1", repo: repo, channelID: "C9", threadTS: "111.1", text: "Updated https://github.com/o/r/pull/1")])
        },
        TestCase("slack planner: review sin push posterior → nada") {
            let pr = myPR(lastCommit: 5, reviews: [review("ana", .changesRequested, at: 10)])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(pr), config: slackConfig(), state: announced()), SlackPlan())
        },
        TestCase("slack planner: un solo Updated por ronda de review") {
            let pr = myPR(lastCommit: 30, reviews: [review("ana", .changesRequested, at: 10)])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(pr), config: slackConfig(), state: announced(lastUpdate: 25)), SlackPlan())
            let nextRound = myPR(lastCommit: 50, reviews: [review("ana", .changesRequested, at: 10), review("ana", .commented, at: 40)])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(nextRound), config: slackConfig(), state: announced(lastUpdate: 25)).actions.count, 1)
        },
        TestCase("slack planner: reviews previas al anuncio, propias o de bots no cuentan") {
            let early = myPR(lastCommit: 20, reviews: [review("ana", .changesRequested, at: -5)])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(early), config: slackConfig(), state: announced()), SlackPlan())
            let ownAndBot = myPR(lastCommit: 20, reviews: [review("me", .commented, at: 10), review("ci", .commented, at: 11, bot: true)])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(ownAndBot), config: slackConfig(), state: announced()), SlackPlan())
        },
    ]
}
```

- [ ] **Step 2: Registrar `+ SlackPlannerTests.cases` en `main.swift`**

- [ ] **Step 3: Correr y ver que falla**

Run: `swift run PRBarTests "slack planner"`
Expected: error de compilación (`cannot find 'SlackPlanner' in scope`).

- [ ] **Step 4: Crear `Sources/PRBarCore/SlackState.swift`**

```swift
import Foundation

public struct SlackAnnouncement: Codable, Equatable, Sendable {
    public var channelID: String
    public var ts: String
    public var announcedAt: Date
    public var lastUpdatePostedAt: Date?

    public init(channelID: String, ts: String, announcedAt: Date, lastUpdatePostedAt: Date? = nil) {
        self.channelID = channelID
        self.ts = ts
        self.announcedAt = announcedAt
        self.lastUpdatePostedAt = lastUpdatePostedAt
    }
}

public struct SlackState: Codable, Equatable, Sendable {
    /// Clave: `owner/repo#número`.
    public var announcements: [String: SlackAnnouncement] = [:]
    /// PRs vistos como draft con el canal ya configurado: se anuncian al pasar a ready.
    public var seenAsDraft: Set<String> = []

    public init() {}
}

public struct SlackStateStore: Sendable {
    private let url: URL

    public init(url: URL = AppPaths.slackStateFile) {
        self.url = url
    }

    public func load() -> SlackState {
        guard let data = try? Data(contentsOf: url) else { return SlackState() }
        do {
            return try JSONCoding.decoder.decode(SlackState.self, from: data)
        } catch {
            AppLog.write("slack-state.json ilegible, se empieza de cero: \(error)")
            return SlackState()
        }
    }

    public func save(_ state: SlackState) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONCoding.encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            AppLog.write("No se pudo guardar slack-state.json: \(error)")
        }
    }
}
```

- [ ] **Step 5: Crear `Sources/PRBarCore/SlackPlanner.swift`**

```swift
import Foundation

public enum SlackAction: Equatable, Sendable {
    case announce(prID: String, repo: RepoRef, channelID: String, text: String)
    case update(prID: String, repo: RepoRef, channelID: String, threadTS: String, text: String)

    public var prID: String {
        switch self {
        case .announce(let prID, _, _, _), .update(let prID, _, _, _, _): prID
        }
    }

    public var repo: RepoRef {
        switch self {
        case .announce(_, let repo, _, _), .update(_, let repo, _, _, _): repo
        }
    }
}

public struct SlackPlan: Equatable, Sendable {
    public var actions: [SlackAction] = []
    public var newDrafts: Set<String> = []

    public init(actions: [SlackAction] = [], newDrafts: Set<String> = []) {
        self.actions = actions
        self.newDrafts = newDrafts
    }
}

/// Decide qué mandar a Slack (spec §15.2). Función pura: no hace red ni disco.
public enum SlackPlanner {
    public static func plan(snapshot: Snapshot, config: AppConfig, state: SlackState) -> SlackPlan {
        guard config.slack.enabled else { return SlackPlan() }
        var plan = SlackPlan()

        for account in config.accounts where account.enabled {
            let me = account.login.lowercased()
            for repoConfig in account.repos {
                guard let channelID = repoConfig.slackChannelID,
                      let enabledAt = repoConfig.slackEnabledAt,
                      snapshot.fetchedScopes.contains(Snapshot.scope(account: account.login, repo: repoConfig.repo))
                else { continue }

                let mine = snapshot.items.filter {
                    $0.account == account.login && $0.pr.repo == repoConfig.repo && $0.pr.author.lowercased() == me
                }
                for item in mine {
                    let pr = item.pr
                    if let announcement = state.announcements[pr.id] {
                        if needsUpdate(pr, me: me, since: announcement.lastUpdatePostedAt ?? announcement.announcedAt) {
                            plan.actions.append(.update(
                                prID: pr.id, repo: pr.repo, channelID: announcement.channelID, threadTS: announcement.ts,
                                text: SlackTemplate.render(config.slack.updateTemplate, pr: pr)
                            ))
                        }
                    } else if pr.isDraft {
                        if !state.seenAsDraft.contains(pr.id) { plan.newDrafts.insert(pr.id) }
                    } else if pr.createdAt >= enabledAt || state.seenAsDraft.contains(pr.id) {
                        plan.actions.append(.announce(
                            prID: pr.id, repo: pr.repo, channelID: channelID,
                            text: SlackTemplate.render(config.slack.newPRTemplate, pr: pr)
                        ))
                    }
                }
            }
        }
        return plan
    }

    /// Hubo una review de otra persona después de `since` y un commit posterior a esa review.
    static func needsUpdate(_ pr: PullRequest, me: String, since: Date) -> Bool {
        let latestReview = pr.reviews
            .filter {
                !$0.isBot && $0.author.lowercased() != me
                    && [.approved, .changesRequested, .commented].contains($0.state)
                    && $0.submittedAt > since
            }
            .map(\.submittedAt)
            .max()
        guard let latestReview else { return false }
        return pr.lastCommitAt > latestReview
    }
}
```

- [ ] **Step 6: Correr todo y ver que pasa**

Run: `swift run PRBarTests`
Expected: todos `✓`.

- [ ] **Step 7: Commit**

```bash
git add Sources
git commit -m "feat(core): plan Slack announcements and thread updates"
```

---

### Task 3: Cliente de Slack

**Files:**
- Create: `Sources/PRBarCore/SlackClient.swift`, `Sources/PRBarTests/SlackClientTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir `Sources/PRBarTests/SlackClientTests.swift`**

```swift
import Foundation
import PRBarCore

private func client(_ transport: FakeTransport) -> SlackClient {
    SlackClient(transport: transport, now: { t0 })
}

private func json(_ request: URLRequest) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
}

enum SlackClientTests {
    static let cases: [TestCase] = [
        TestCase("slack client: postMessage en hilo manda token, canal, texto y thread_ts") {
            let transport = FakeTransport([(200, [:], #"{"ok":true,"ts":"171.5"}"#)])
            let ts = try await client(transport).postMessage(channel: "C1", text: "hola", threadTS: "111.1", token: "xoxb-1")
            try expectEqual(ts, "171.5")
            let request = transport.requests[0]
            try expectEqual(request.url?.absoluteString, "https://slack.com/api/chat.postMessage")
            try expectEqual(request.httpMethod, "POST")
            try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xoxb-1")
            let body = try json(request)
            try expectEqual(body["channel"] as? String, "C1")
            try expectEqual(body["text"] as? String, "hola")
            try expectEqual(body["thread_ts"] as? String, "111.1")
        },
        TestCase("slack client: mensaje nuevo no manda thread_ts") {
            let transport = FakeTransport([(200, [:], #"{"ok":true,"ts":"1.0"}"#)])
            _ = try await client(transport).postMessage(channel: "C1", text: "x", threadTS: nil, token: "t")
            try expect(try json(transport.requests[0])["thread_ts"] == nil)
        },
        TestCase("slack client: ok=false → PRBarError.slack con el código") {
            let transport = FakeTransport([(200, [:], #"{"ok":false,"error":"not_in_channel"}"#)])
            let error = try await expectThrows { _ = try await client(transport).postMessage(channel: "C1", text: "x", threadTS: nil, token: "t") }
            try expect(error as? PRBarError == .slack("not_in_channel"))
        },
        TestCase("slack client: 429 → rateLimited con Retry-After") {
            let transport = FakeTransport([(429, ["Retry-After": "30"], "")])
            let error = try await expectThrows { _ = try await client(transport).postMessage(channel: "C1", text: "x", threadTS: nil, token: "t") }
            try expect(error as? PRBarError == .rateLimited(resetAt: t0.addingTimeInterval(30)))
        },
        TestCase("slack client: auth.test devuelve equipo y bot") {
            let transport = FakeTransport([(200, [:], #"{"ok":true,"team":"Acme","user":"prbar"}"#)])
            let identity = try await client(transport).authTest(token: "t")
            try expectEqual(identity, SlackIdentity(team: "Acme", user: "prbar"))
        },
        TestCase("slack client: canales paginados, ordenados y con is_member") {
            let transport = FakeTransport([
                (200, [:], #"{"ok":true,"channels":[{"id":"C2","name":"zeta","is_private":false,"is_member":true}],"response_metadata":{"next_cursor":"abc"}}"#),
                (200, [:], #"{"ok":true,"channels":[{"id":"C1","name":"alfa","is_private":true,"is_member":false}],"response_metadata":{"next_cursor":""}}"#),
            ])
            let channels = try await client(transport).channels(token: "t")
            try expectEqual(channels, [
                SlackChannel(id: "C1", name: "alfa", isPrivate: true, isMember: false),
                SlackChannel(id: "C2", name: "zeta", isPrivate: false, isMember: true),
            ])
            try expect(transport.requests[0].url?.absoluteString.contains("types=public_channel,private_channel") == true)
            try expect(transport.requests[1].url?.absoluteString.contains("cursor=abc") == true)
        },
    ]
}
```

- [ ] **Step 2: Registrar `+ SlackClientTests.cases`, correr y ver que falla**

Run: `swift run PRBarTests "slack client"`
Expected: error de compilación (`cannot find 'SlackClient' in scope`).

- [ ] **Step 3: Crear `Sources/PRBarCore/SlackClient.swift`**

```swift
import Foundation

public struct SlackChannel: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isPrivate: Bool
    public let isMember: Bool

    public init(id: String, name: String, isPrivate: Bool, isMember: Bool) {
        self.id = id
        self.name = name
        self.isPrivate = isPrivate
        self.isMember = isMember
    }
}

public struct SlackIdentity: Equatable, Sendable {
    public let team: String
    public let user: String

    public init(team: String, user: String) {
        self.team = team
        self.user = user
    }
}

public protocol SlackAPI: Sendable {
    /// Devuelve el `ts` del mensaje publicado.
    func postMessage(channel: String, text: String, threadTS: String?, token: String) async throws -> String
    func authTest(token: String) async throws -> SlackIdentity
    func channels(token: String) async throws -> [SlackChannel]
}

public struct SlackClient: SlackAPI {
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private static let maxChannelPages = 10

    public init(transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    public func postMessage(channel: String, text: String, threadTS: String?, token: String) async throws -> String {
        struct Response: Decodable { let ts: String }
        var body: [String: Any] = ["channel": channel, "text": text, "unfurl_links": false]
        if let threadTS { body["thread_ts"] = threadTS }
        let response: Response = try await call("chat.postMessage", json: body, token: token)
        return response.ts
    }

    public func authTest(token: String) async throws -> SlackIdentity {
        struct Response: Decodable { let team: String; let user: String }
        let response: Response = try await call("auth.test", json: [:], token: token)
        return SlackIdentity(team: response.team, user: response.user)
    }

    public func channels(token: String) async throws -> [SlackChannel] {
        struct Response: Decodable {
            struct Channel: Decodable {
                let id: String
                let name: String
                let is_private: Bool?
                let is_member: Bool?
            }
            struct Metadata: Decodable { let next_cursor: String? }
            let channels: [Channel]
            let response_metadata: Metadata?
        }
        var result: [SlackChannel] = []
        var cursor: String?
        for _ in 0..<Self.maxChannelPages {
            var query = ["types": "public_channel,private_channel", "exclude_archived": "true", "limit": "200"]
            if let cursor { query["cursor"] = cursor }
            let page: Response = try await call("conversations.list", query: query, token: token)
            result += page.channels.map {
                SlackChannel(id: $0.id, name: $0.name, isPrivate: $0.is_private ?? false, isMember: $0.is_member ?? false)
            }
            guard let next = page.response_metadata?.next_cursor, !next.isEmpty else { break }
            cursor = next
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func call<T: Decodable>(_ method: String, json: [String: Any]? = nil, query: [String: String]? = nil, token: String) async throws -> T {
        var components = URLComponents(string: "https://slack.com/api/\(method)")!
        if let query {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as PRBarError {
            throw error
        } catch {
            throw PRBarError.network(error.localizedDescription)
        }

        if response.statusCode == 429 {
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) } ?? 60
            throw PRBarError.rateLimited(resetAt: now().addingTimeInterval(retry))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw PRBarError.http(status: response.statusCode, message: "Slack \(method)")
        }

        struct Envelope: Decodable { let ok: Bool; let error: String? }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw PRBarError.invalidResponse("Slack \(method): \(error)")
        }
        guard envelope.ok else { throw PRBarError.slack(envelope.error ?? "unknown_error") }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PRBarError.invalidResponse("Slack \(method): \(error)")
        }
    }
}
```

- [ ] **Step 4: Correr todo y ver que pasa**

Run: `swift run PRBarTests`
Expected: todos `✓`.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat(core): add Slack Web API client"
```

---

### Task 4: Keychain y SlackAnnouncer

**Files:**
- Create: `Sources/PRBarCore/KeychainStore.swift`, `Sources/PRBarCore/SlackAnnouncer.swift`, `Sources/PRBarTests/SlackAnnouncerTests.swift`
- Modify: `Sources/PRBarTests/Fakes.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Agregar los fakes al final de `Sources/PRBarTests/Fakes.swift`**

```swift
final class FakeSlackAPI: SlackAPI, @unchecked Sendable {
    private(set) var posts: [(channel: String, text: String, threadTS: String?)] = []
    /// Resultados por post, en orden; sin resultados programados devuelve "ts-<n>".
    var results: [Result<String, PRBarError>] = []

    func postMessage(channel: String, text: String, threadTS: String?, token: String) async throws -> String {
        posts.append((channel, text, threadTS))
        if !results.isEmpty { return try results.removeFirst().get() }
        return "ts-\(posts.count)"
    }

    func authTest(token: String) async throws -> SlackIdentity { SlackIdentity(team: "Acme", user: "prbar") }
    func channels(token: String) async throws -> [SlackChannel] { [] }
}

final class FakeSecrets: SecretStore, @unchecked Sendable {
    private var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func read(_ key: String) throws -> String? { values[key] }

    func write(_ value: String?, for key: String) throws {
        values[key] = value
    }
}
```

- [ ] **Step 2: Escribir `Sources/PRBarTests/SlackAnnouncerTests.swift`**

```swift
import Foundation
import PRBarCore

private func makeAnnouncer(
    _ api: FakeSlackAPI,
    secrets: FakeSecrets = FakeSecrets(["bot-token": "xoxb"]),
    clock: Box<Date> = Box(t0)
) async throws -> (SlackAnnouncer, SlackStateStore) {
    let store = SlackStateStore(url: try temporaryDirectory().appendingPathComponent("slack-state.json"))
    let announcer = await SlackAnnouncer(api: api, secrets: secrets, stateStore: store, now: { clock.value })
    return (announcer, store)
}

enum SlackAnnouncerTests {
    static let cases: [TestCase] = [
        TestCase("slack announcer: anuncia, guarda el ts y no repite") {
            let api = FakeSlackAPI()
            let (announcer, store) = try await makeAnnouncer(api)
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            try expectEqual(api.posts[0].channel, "C1")
            try expectEqual(store.load().announcements["o/r#1"]?.ts, "ts-1")
            let issues = await announcer.issues
            try expectEqual(issues, [])
        },
        TestCase("slack announcer: después de review + push manda Updated en el hilo una sola vez") {
            let api = FakeSlackAPI()
            let clock = Box(at(0))
            let (announcer, _) = try await makeAnnouncer(api, clock: clock)
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            clock.value = at(30)
            let updated = myPR(lastCommit: 20, reviews: [review("ana", .changesRequested, at: 10)])
            await announcer.process(snapshot: slackSnap(updated), config: slackConfig())
            await announcer.process(snapshot: slackSnap(updated), config: slackConfig())
            try expectEqual(api.posts.count, 2)
            try expectEqual(api.posts[1].threadTS, "ts-1")
            try expectEqual(api.posts[1].text, "Updated https://github.com/o/r/pull/1")
        },
        TestCase("slack announcer: sin token → issue y ningún post") {
            let api = FakeSlackAPI()
            let (announcer, _) = try await makeAnnouncer(api, secrets: FakeSecrets())
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 0)
            let issues = await announcer.issues
            try expectEqual(issues.map(\.error), [.slack("missing_token")])
        },
        TestCase("slack announcer: error de Slack queda como issue y se reintenta") {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack("not_in_channel"))]
            let (announcer, store) = try await makeAnnouncer(api)
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            let firstIssues = await announcer.issues
            try expectEqual(firstIssues.map(\.error), [.slack("not_in_channel")])
            try expectEqual(store.load().announcements.count, 0)
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            let secondIssues = await announcer.issues
            try expectEqual(secondIssues, [])
            try expectEqual(store.load().announcements.count, 1)
        },
        TestCase("slack announcer: rate limit corta el resto de los envíos") {
            let api = FakeSlackAPI()
            api.results = [.failure(.rateLimited(resetAt: at(5)))]
            let (announcer, _) = try await makeAnnouncer(api)
            await announcer.process(snapshot: slackSnap(myPR(number: 1), myPR(number: 2)), config: slackConfig())
            try expectEqual(api.posts.count, 1)
        },
        TestCase("slack announcer: drafts se guardan en el estado") {
            let api = FakeSlackAPI()
            let (announcer, store) = try await makeAnnouncer(api)
            await announcer.process(snapshot: slackSnap(myPR(isDraft: true)), config: slackConfig())
            try expectEqual(store.load().seenAsDraft, ["o/r#1"])
            try expectEqual(api.posts.count, 0)
        },
        TestCase("slack announcer: desactivado no postea y limpia issues") {
            let api = FakeSlackAPI()
            let (announcer, _) = try await makeAnnouncer(api, secrets: FakeSecrets())
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig(enabled: false))
            try expectEqual(api.posts.count, 0)
            let issues = await announcer.issues
            try expectEqual(issues, [])
        },
        TestCase("slack announcer: guardar y borrar token actualiza hasToken") {
            let (announcer, _) = try await makeAnnouncer(FakeSlackAPI(), secrets: FakeSecrets())
            let before = await announcer.hasToken
            try expectEqual(before, false)
            try await announcer.saveToken("xoxb-nuevo")
            let after = await announcer.hasToken
            try expectEqual(after, true)
            try await announcer.saveToken(nil)
            let cleared = await announcer.hasToken
            try expectEqual(cleared, false)
        },
    ]
}
```

- [ ] **Step 3: Registrar `+ SlackAnnouncerTests.cases`, correr y ver que falla**

Run: `swift run PRBarTests "slack announcer"`
Expected: error de compilación (`cannot find type 'SecretStore'`).

- [ ] **Step 4: Crear `Sources/PRBarCore/KeychainStore.swift`**

```swift
import Foundation
import Security

public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> String?
    /// `nil` o vacío borra el secreto.
    func write(_ value: String?, for key: String) throws
}

/// Secretos en el Llavero de macOS (generic password). Nunca se loguean.
public struct KeychainStore: SecretStore {
    private let service: String

    public init(service: String = "com.federico.prbar.slack") {
        self.service = service
    }

    public func read(_ key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw PRBarError.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ value: String?, for key: String) throws {
        let deleteStatus = SecItemDelete(baseQuery(key) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw PRBarError.keychain(deleteStatus)
        }
        guard let value, !value.isEmpty else { return }
        var attributes = baseQuery(key)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw PRBarError.keychain(status) }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
```

- [ ] **Step 5: Crear `Sources/PRBarCore/SlackAnnouncer.swift`**

```swift
import Foundation

/// Ejecuta el plan de Slack después de cada refresco y publica los problemas para la UI (spec §15).
@MainActor
public final class SlackAnnouncer: ObservableObject {
    public static let tokenKey = "bot-token"

    @Published public private(set) var issues: [RefreshIssue] = []
    @Published public private(set) var hasToken = false

    private let api: SlackAPI
    private let secrets: SecretStore
    private let stateStore: SlackStateStore
    private let now: () -> Date
    private var state: SlackState
    private var isRunning = false

    public init(api: SlackAPI, secrets: SecretStore, stateStore: SlackStateStore = SlackStateStore(), now: @escaping () -> Date = { Date() }) {
        self.api = api
        self.secrets = secrets
        self.stateStore = stateStore
        self.now = now
        self.state = stateStore.load()
        self.hasToken = ((try? secrets.read(Self.tokenKey)) ?? nil)?.isEmpty == false
    }

    public func process(snapshot: Snapshot, config: AppConfig) async {
        guard config.slack.enabled else {
            issues = []
            return
        }
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let token: String
        do {
            guard let stored = try secrets.read(Self.tokenKey), !stored.isEmpty else {
                issues = [RefreshIssue(account: "slack", repo: nil, error: .slack("missing_token"))]
                return
            }
            token = stored
        } catch {
            issues = [RefreshIssue(account: "slack", repo: nil, error: Self.prbarError(error))]
            return
        }

        let plan = SlackPlanner.plan(snapshot: snapshot, config: config, state: state)
        if !plan.newDrafts.isEmpty {
            state.seenAsDraft.formUnion(plan.newDrafts)
            stateStore.save(state)
        }

        var newIssues: [RefreshIssue] = []
        for action in plan.actions {
            do {
                switch action {
                case .announce(let prID, _, let channelID, let text):
                    let ts = try await api.postMessage(channel: channelID, text: text, threadTS: nil, token: token)
                    state.announcements[prID] = SlackAnnouncement(channelID: channelID, ts: ts, announcedAt: now())
                case .update(let prID, _, let channelID, let threadTS, let text):
                    _ = try await api.postMessage(channel: channelID, text: text, threadTS: threadTS, token: token)
                    state.announcements[prID]?.lastUpdatePostedAt = now()
                }
                stateStore.save(state)
            } catch {
                let prbarError = Self.prbarError(error)
                newIssues.append(RefreshIssue(account: "slack", repo: action.repo, error: prbarError))
                AppLog.write("Slack falló para \(action.prID): \(prbarError)")
                if Self.stopsCycle(prbarError) { break }
            }
        }
        issues = newIssues
    }

    public func saveToken(_ token: String?) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        try secrets.write(trimmed, for: Self.tokenKey)
        hasToken = trimmed?.isEmpty == false
    }

    public func testConnection() async throws -> SlackIdentity {
        try await api.authTest(token: try requireToken())
    }

    public func channels() async throws -> [SlackChannel] {
        try await api.channels(token: try requireToken())
    }

    private func requireToken() throws -> String {
        guard let token = try secrets.read(Self.tokenKey), !token.isEmpty else { throw PRBarError.slack("missing_token") }
        return token
    }

    private static func prbarError(_ error: Error) -> PRBarError {
        (error as? PRBarError) ?? .network(error.localizedDescription)
    }

    private static func stopsCycle(_ error: PRBarError) -> Bool {
        switch error {
        case .rateLimited: true
        case .slack(let code): ["invalid_auth", "token_revoked", "not_authed", "account_inactive"].contains(code)
        default: false
        }
    }
}
```

- [ ] **Step 6: Correr todo y ver que pasa**

Run: `swift run PRBarTests`
Expected: todos `✓`.

- [ ] **Step 7: Commit**

```bash
git add Sources
git commit -m "feat(core): announce PRs on Slack with keychain-stored bot token"
```

---

### Task 5: UI y cableado

**Files:**
- Create: `Sources/PRBar/Settings/SlackTab.swift`
- Modify: `Sources/PRBar/AppModel.swift`, `Sources/PRBar/PRBarApp.swift`, `Sources/PRBar/Popover/PopoverView.swift`, `Sources/PRBar/Settings/SettingsView.swift`, `Sources/PRBar/Settings/ReposTab.swift`

- [ ] **Step 1: Cablear el announcer en `AppModel.swift`**

- Agregar la propiedad `let slack: SlackAnnouncer`.
- En `init()`, crear `let slack = SlackAnnouncer(api: SlackClient(), secrets: KeychainStore())` junto a los demás locales y asignar `self.slack = slack`.
- En el closure `onChange` del `PRStore`, después de `notifications.deliver(...)`, agregar:

```swift
                Task { await slack.process(snapshot: next, config: configStore.config) }
```

- En `openSettings()`, no hay que cambiar nada: `SettingsView` toma `model.slack`.

- [ ] **Step 2: Mostrar los problemas de Slack en el popover**

En `PRBarApp.swift`, pasar `slack: model.slack` al crear `PopoverView`. En `PopoverView.swift`:
- agregar `@ObservedObject var slack: SlackAnnouncer` después de `configStore`;
- en `list(_:)`, justo después del bloque `if !snapshot.issues.isEmpty { IssuesBanner(...) }`, agregar:

```swift
                if !slack.issues.isEmpty {
                    IssuesBanner(groups: [(account: "Slack", issues: slack.issues)])
                }
```

- [ ] **Step 3: Crear `Sources/PRBar/Settings/SlackTab.swift`**

```swift
import PRBarCore
import SwiftUI

struct SlackTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var slack: SlackAnnouncer

    @State private var tokenInput = ""
    @State private var status: String?
    @State private var statusOK = false
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Toggle("Anunciar mis PRs en Slack", isOn: Binding(
                    get: { configStore.config.slack.enabled },
                    set: { enabled in model.updateConfig(refresh: false) { $0.slack.enabled = enabled } }
                ))
                .toggleStyle(.switch)
                Text("Cada repo elige su canal en la pestaña Repos. Solo se anuncian PRs creados después de elegir el canal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bot token") {
                SecureField(slack.hasToken ? "Guardado en el Llavero · pegá uno nuevo para reemplazarlo" : "xoxb-…", text: $tokenInput)
                HStack {
                    Button("Guardar y probar") { saveAndTest() }
                        .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    Button("Probar conexión") { test() }
                        .disabled(!slack.hasToken || busy)
                    Spacer()
                    if slack.hasToken {
                        Button("Borrar token", role: .destructive) {
                            do {
                                try slack.saveToken(nil)
                                show("Token borrado", ok: true)
                            } catch {
                                show(error.localizedDescription, ok: false)
                            }
                        }
                    }
                }
                if let status {
                    Label(status, systemImage: statusOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(statusOK ? Theme.green : Theme.red)
                }
            }

            Section("Mensajes") {
                TextField("PR nuevo", text: template(\.newPRTemplate))
                TextField("Actualización (en el hilo)", text: template(\.updateTemplate))
                Text("Variables: {link} {title} {number} {repo} {author}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cómo crear el bot") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. En api.slack.com/apps → Create New App → From scratch.")
                    Text("2. OAuth & Permissions → Bot Token Scopes: chat:write, channels:read, groups:read.")
                    Text("3. Install to Workspace (puede requerir aprobación de un admin).")
                    Text("4. Copiá el Bot User OAuth Token (xoxb-…) y pegalo arriba.")
                    Text("5. En cada canal escribí /invite @<nombre del bot> y elegilo en Repos.")
                }
                .font(.callout)
                Link("Abrir api.slack.com/apps", destination: URL(string: "https://api.slack.com/apps")!)
            }
        }
        .formStyle(.grouped)
    }

    private func template(_ keyPath: WritableKeyPath<SlackSettings, String>) -> Binding<String> {
        Binding(
            get: { configStore.config.slack[keyPath: keyPath] },
            set: { value in model.updateConfig(refresh: false) { $0.slack[keyPath: keyPath] = value } }
        )
    }

    private func saveAndTest() {
        do {
            try slack.saveToken(tokenInput)
            tokenInput = ""
            test()
        } catch {
            show(error.localizedDescription, ok: false)
        }
    }

    private func test() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let identity = try await slack.testConnection()
                show("Conectado a \(identity.team) como @\(identity.user)", ok: true)
            } catch {
                show(error.localizedDescription, ok: false)
            }
        }
    }

    private func show(_ message: String, ok: Bool) {
        status = message
        statusOK = ok
    }
}
```

- [ ] **Step 4: Agregar la pestaña en `SettingsView.swift`**

Agregar `slack: model.slack` a la llamada de `ReposTab(...)`. Después de la pestaña General, agregar:

```swift
                SlackTab(model: model, configStore: configStore, slack: model.slack)
                    .tabItem { Label("Slack", systemImage: "number") }
```

- [ ] **Step 5: Selector de canal en `ReposTab.swift`**

- Agregar `@ObservedObject var slack: SlackAnnouncer` después de `configStore`.
- Agregar `@State private var slackChannels: [SlackChannel] = []` y `@State private var slackError: String?`.
- En `detail(_:)`, después del `VStack` de "Ramas base" y antes de `Spacer()`, agregar:

```swift
                VStack(alignment: .leading, spacing: 6) {
                    Text("Canal de Slack").font(.subheadline.weight(.semibold))
                    if !configStore.config.slack.enabled || !slack.hasToken {
                        Text("Activá Slack y guardá el token en la pestaña Slack.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Canal", selection: Binding(
                            get: { repo.slackChannelID ?? "" },
                            set: { id in
                                let channel = slackChannels.first { $0.id == id }
                                model.updateConfig(refresh: false) {
                                    $0.setSlackChannel(id: channel?.id, name: channel?.name, repoID: repo.id, login: login)
                                }
                            }
                        )) {
                            Text("Sin anuncios").tag("")
                            if let id = repo.slackChannelID, !slackChannels.contains(where: { $0.id == id }) {
                                Text("#\(repo.slackChannelName ?? id)").tag(id)
                            }
                            ForEach(slackChannels) { channel in
                                Text((channel.isPrivate ? "🔒 " : "#") + channel.name + (channel.isMember ? "" : " · el bot no está"))
                                    .tag(channel.id)
                            }
                        }
                        .labelsHidden()
                        if let slackError {
                            Text(slackError).font(.caption).foregroundStyle(Theme.red)
                        }
                    }
                }
                .task(id: slack.hasToken) { await loadSlackChannels() }
```

- Agregar el método:

```swift
    private func loadSlackChannels() async {
        guard configStore.config.slack.enabled, slack.hasToken else { return }
        do {
            slackChannels = try await slack.channels()
            slackError = nil
        } catch {
            slackChannels = []
            slackError = "No se pudieron cargar los canales: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 6: Compilar, testear e instalar**

Run: `swift run PRBarTests && Scripts/bundle.sh --install && pgrep -x PRBar`
Expected: tests verdes, `Instalado y abierto` y un PID.

- [ ] **Step 7: Commit**

```bash
git add Sources
git commit -m "feat(app): add Slack settings tab, per-repo channel picker and Slack issues in popover"
```

---

### Task 6: QA manual

**Files:**
- Create: `docs/qa/plan-4-checklist.md`

- [ ] **Step 1: Crear `docs/qa/plan-4-checklist.md`**

```markdown
# QA manual — Plan 4 (Slack)

- [ ] Crear la app de Slack según la guía de Configuración → Slack e invitar el bot a un canal de prueba (ej. #prbar-test).
- [ ] Pegar el token → "Guardar y probar" muestra "Conectado a <equipo> como @<bot>".
- [ ] macOS puede pedir permiso de Llavero tras reinstalar la app (firma ad-hoc): elegir "Permitir siempre".
- [ ] Repos → elegir #prbar-test en un repo propio de prueba (ej. FedericoCharbonnier/PRBar).
- [ ] Crear un PR (no draft) en ese repo → en el siguiente refresco llega un mensaje con solo el link.
- [ ] Reiniciar la app → no se repite el mensaje.
- [ ] Crear un PR draft → no se anuncia; marcarlo Ready → se anuncia.
- [ ] Pedir a alguien (o desde otra cuenta) una review con comentario → pushear un commit → llega "Updated <link>" en el hilo.
- [ ] Pushear otro commit sin review nueva → no llega otro "Updated".
- [ ] Sacar al bot del canal → el popover muestra "Slack · <repo>: El bot no está en el canal…".
- [ ] Desactivar Slack → no hay más mensajes ni errores de Slack en el popover.
- [ ] El token no aparece en `config.json` ni en `~/Library/Logs/PRBar/prbar.log`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/qa
git commit -m "docs: add manual QA checklist for the Slack bot"
```
