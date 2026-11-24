# Plan 22: Claude session in a terminal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A **Terminal** button next to **Chat** (plus Pull Request › Open Claude Session in Terminal ⌥⌘T, History › Open in Terminal and `prbar session list|open`) that resumes, with `claude --resume <id>`, the Claude Code session of a PR's last review stages, Respond fixes or Fix CI, in the folder PRBar kept for it, in the terminal chosen in Settings › General (Terminal, iTerm, Warp, Ghostty, Orca or a custom command). Spec: `docs/superpowers/specs/2026-11-24-prbar-session-terminal-design.md` (T.1–T.7).

**Architecture:** `ClaudeStreamParser` reads `session_id` from the `system/init` event and `ClaudeRunner` reports it through `ClaudeInvocation.onSession`; the review pipeline, `FixImplementer` and `RespondQueue` turn those ids into `ClaudeSessionRef`s stored in `ReviewRecord.sessions` / `RespondRecord.sessions`. The review and pushed-fix folders are no longer deleted: `AppModel` keeps them in `RetainedWorktreeStore` (`retained-worktrees.json`) with pure rules (`RetainedWorktreeRules`), removing them when the PR is merged/closed, replaced by a newer job of the same kind (unless `lsof` sees a process inside) or through Clean Up (never with uncommitted/unpushed work). `ClaudeSessionCommand` builds the quoted `cd … && claude --resume …` (or `ssh -t …`) command; `TerminalLauncher` (pure plans) and `TerminalOpener` (side effects: `.command` file + `open -a`, `orca terminal create`, `/bin/sh -c`) open it. The CLI talks to the app through new `AppCommand` cases dispatched to a new `SessionActions` protocol; the iPhone never gets them (`RemotePolicy` denies them).

**Tech Stack:** Swift 6 / SwiftUI / AppKit, custom test runner (PRBarTests), TypeScript web (PWA) for RemotePolicy sync.

---

## Conventions for every task

- Work only in `/Users/federico/Documents/PRBar-wt-term` (branch `feat/session-terminal`).
- Tests: `swift run PRBarTests "<substring of the TestCase name>"` (a filter, case-insensitive). New test files are registered in `Sources/PRBarTests/main.swift` (`+ XTests.cases`).
- Assertions: `try expect(cond, "message")`, `try expectEqual(a, b)` (no message argument), `try expectSome(x)`, `try await expectThrows { … }`.
- Builds: `swift build --product PRBar`, `swift build --product PRBarCLI`, `swift build --product PRBarTests`.
- Never use bare `git stash`. Commit messages carry no Co-Authored-By / Claude attribution lines.
- Code comments: Spanish or English like the surrounding code; UI strings in English with typographic apostrophes (`’`).
- `swift run PRBarTests "paridad UI"` fails between Task 9/11 and Task 14 (new controls without inventory entries yet); that is expected and fixed in Task 14.

## File structure

| File | Status | Responsibility |
|---|---|---|
| `docs/superpowers/specs/2026-11-24-prbar-session-terminal-design.md` | modify | T.5 with the spike results; T.3 clarification about the review folder |
| `Sources/PRBarCore/ClaudeStream.swift` | modify | `ClaudeStreamParser.sessionID` from `{"type":"system","subtype":"init","session_id":…}` |
| `Sources/PRBarCore/ClaudeRunner.swift` | modify | `ClaudeInvocation.onSession`; `attempt` reports each attempt's new session id |
| `Sources/PRBarCore/ClaudeSessions.swift` | create | `ClaudeSessionStamp`, `ClaudeSessionCapture`, `ClaudeSessionRef` (labels, builders), `SessionOffer` (what is offered, grouping, picking, help text, CLI info) |
| `Sources/PRBarCore/ReviewHistory.swift` | modify | `ReviewRecord.sessions` (optional) |
| `Sources/PRBarCore/RespondPipeline.swift` | modify | `RespondRecord.sessions` (optional, tolerant decoding) |
| `Sources/PRBarCore/RespondModels.swift` | modify | `ItemResult.session` |
| `Sources/PRBarCore/ReviewModels.swift` | modify | `ReviewDraft.sessions` / `ReviewDraft.retainedLocation` (transient, not encoded) |
| `Sources/PRBarCore/ClaudeReviewer.swift` | modify | `review(…, onSession:, onProgress:)` reports each stage's session |
| `Sources/PRBarCore/ReviewPipeline.swift` | modify | collects stage sessions; `ReviewFailure.sessions`; keeps (releases) the worktree on success |
| `Sources/PRBarCore/FixImplementer.swift` | modify | one `ClaudeSessionCapture` per fix; squash keeps the session |
| `Sources/PRBarCore/RespondQueue.swift` | modify | sessions into the record at `readyToPush`; `onRetain` instead of deleting a pushed worktree |
| `Sources/PRBarCore/RetainedWorktrees.swift` | create | `WorktreeLocation`, `RetainedWorktree`, `RetainedWorktreeStore`, `RetainedWorktreeRules`, `ProcessCwd`, `RetainedWorktreeCleaner` |
| `Sources/PRBarCore/Support.swift` | modify | `AppPaths.retainedWorktreesFile`, `AppPaths.terminalDir` |
| `Sources/PRBarCore/WorktreeManager.swift` | modify | `release(_:)`; `cleanupOrphans(localPaths:keeping:)` |
| `Sources/PRBarCore/WorktreeResolver.swift` | modify | `cleanupOrphans(localPath:worktreeDir:keeping:)` |
| `Sources/PRBarCore/RemoteWorkspaces.swift` | modify | `release(_:)`; `cleanupOrphans(olderThan:keeping:)` |
| `Sources/PRBarCore/DiskCleanup.swift` | modify | `DiskCleanupExecutor(retained:)`: retained review folders need the unpushed-work check |
| `Sources/PRBarCore/SSHCommand.swift` | modify | `SSHCommandBuilder.interactiveArguments` (`-t`, same connection hardening, no BatchMode/RequestTTY=no) |
| `Sources/PRBarCore/ClaudeSessionCommand.swift` | create | `cd '<dir>' && '<claude>' --resume <uuid>` and its `ssh -t` form |
| `Sources/PRBarWire/AppCommandTypes.swift` | modify | `TerminalChoice`, `SessionJob` |
| `Sources/PRBarCore/TerminalLauncher.swift` | create | `TerminalRequest`, `TerminalPlan`, `TerminalLaunchError`, `TerminalLauncher` (pure), `TerminalOpener` (side effects) |
| `Sources/PRBarCore/Config.swift` | modify | `AppConfig.terminal`, `AppConfig.terminalCommand`, `setTerminal`, `setTerminalCommand` |
| `Sources/PRBarWire/AppCommand.swift` | modify | `sessionList`, `sessionOpen`, `setTerminal`, `setTerminalCommand` (+ `Name`) |
| `Sources/PRBarWire/CommandResults.swift` | modify | `ClaudeSessionInfo` |
| `Sources/PRBarCore/CommandActions.swift` | modify | `ConfigActions.configSetTerminal*`; new `SessionActions`; `PRBarActions` |
| `Sources/PRBarCore/CommandDispatcher.swift` | modify | dispatch of the four new commands |
| `Sources/PRBarRemoteKit/RemotePolicy.swift` | modify | the four new names are `.denied` |
| `Sources/PRBarRemoteFixtures/FixtureActions.swift` | modify | stubs for the new actions |
| `Sources/PRBarCLIKit/ConfigCommands.swift` | modify | `config set terminal` / `terminal-command` |
| `Sources/PRBarCLIKit/SessionCommands.swift` | create | `prbar session list` / `prbar session open` |
| `Sources/PRBarCLIKit/PRBarCLIKit.swift` | modify | registers `SessionGroup` |
| `Sources/PRBarCLIKit/CLIRouter.swift` | modify | parity rows |
| `Sources/PRBar/AppModel.swift` | modify | `retainedWorktrees`, `retainedStore`, `retainedPrune`, `retainedCheckedAt`; hooks in `reviewFinished`, `respond`, snapshot observer, orphan cleanup |
| `Sources/PRBar/AppModel+Sessions.swift` | create | retention, pruning, offered sessions, busy check, opening, `SessionActions`, `configSetTerminal*` |
| `Sources/PRBar/AppModel+Resources.swift` | modify | Clean Up passes and forgets retained folders |
| `Sources/PRBar/AppModel+Runners.swift` | modify | remote orphan cleanup keeps retained folders |
| `Sources/PRBar/Snapshots/SnapshotMode.swift` | modify | a retained store inside the snapshot folder |
| `Sources/PRBar/Settings/TerminalApps.swift` | create | installed terminals (bundle ids), picker titles |
| `Sources/PRBar/Settings/GeneralTab.swift` | modify | Claude Sessions › Terminal picker + Custom command field |
| `Sources/PRBar/Main/SessionTerminalButton.swift` | create | the Terminal button / menu (toolbar and History) |
| `Sources/PRBar/Main/PRDetailView.swift` | modify | toolbar button (PR window), ⌥⌘T registration |
| `Sources/PRBar/Main/MainWindow.swift` | modify | toolbar button (main window) |
| `Sources/PRBar/Components/WindowCommands.swift` | modify | `WindowCommand.openClaudeSession` |
| `Sources/PRBar/AppMenu.swift` | modify | Pull Request › Open Claude Session in Terminal ⌥⌘T |
| `Sources/PRBarCore/KeyboardShortcutList.swift` | modify | ⌥⌘T in Help › Keyboard Shortcuts |
| `Sources/PRBar/Review/HistoryDetailView.swift`, `Sources/PRBar/Respond/RespondHistoryDetailView.swift`, `Sources/PRBar/Review/HistoryPane.swift` | modify | History › Open in Terminal |
| `web/src/protocol/commands.ts` | modify | comment: the new Mac-only commands are not phone commands |
| `Sources/PRBarTests/*` | create/modify | `ClaudeSessionsTests`, `RetainedWorktreesTests`, `ClaudeSessionCommandTests`, `TerminalLauncherTests`, `SessionCommandsTests` + edits listed per task |
| `Sources/PRBarTests/UIActionInventory.swift` | modify | the new controls |
| `docs/cli.md` | modify | `prbar session …`, `prbar config set terminal…` |
| `docs/qa/plan-22-checklist.md` | create | manual checklist |

---

### Task 1: Spec T.5 with the spike results

**Files:**
- Modify: `docs/superpowers/specs/2026-11-24-prbar-session-terminal-design.md`

- [ ] **Step 1: Replace the T.5 launcher bullets.** Replace this block:

```markdown
- `TerminalLauncher` lo abre según la terminal elegida:
  - **Terminal** e **iTerm**: un script `.command` ejecutable en Application Support (`terminal/`, se borran los de
    más de un día) abierto con `open -a <app>`; no pide permiso de automatización.
  - **Ghostty**: `open -na Ghostty --args --working-directory=<carpeta> -e /bin/zsh -lc <comando>`.
  - **Warp**: una launch configuration en `~/.warp/launch_configurations/prbar-session.yaml`, abierta con
    `warp://launch/prbar-session.yaml`.
  - **Orca**: su CLI (`orca`), abriendo una terminal en la carpeta con el comando.
  - **Custom**: un comando con `{dir}` y `{command}` (ya entre comillas), corrido con `/bin/sh -c`.
  - La forma exacta de cada una se verifica primero en el plan (spike). Si alguna no se puede abrir de forma confiable,
    se avisa al usuario antes de seguir.
```

with:

```markdown
- `TerminalLauncher` lo abre según la terminal elegida (verificado en esta Mac el 2026-11-24, con una carpeta con
  espacios en la ruta):
  - **Terminal**, **iTerm**, **Warp** y **Ghostty**: un script `.command` ejecutable (`#!/bin/zsh`,
    `cd '<carpeta>' && <comando>` y después `exec /bin/zsh -l`, para que la ventana quede abierta al salir de Claude)
    en Application Support (`terminal/`, modo 755; los de más de un día se borran en cada apertura), abierto con
    `open -a <app>` (`Terminal`, `iTerm`, `Warp`, `Ghostty`). No pide permiso de automatización y Warp no necesita
    una launch configuration. Instaladas según su bundle id: `com.apple.Terminal`, `com.googlecode.iterm2`,
    `dev.warp.Warp-Stable`, `com.mitchellh.ghostty`.
  - **Orca** (`com.stablyai.orca`): `orca terminal create --worktree "path:<carpeta>" --title "<título>"
    --command "<comando>" --focus --json` (el binario está en `/Applications/Orca.app/Contents/Resources/bin/orca`).
    Solo funciona si la carpeta es un worktree de un repo agregado en Orca (`orca repo list`); si no, contesta
    `"ok": false` con `"code": "selector_not_found"` y PRBar avisa "This folder isn’t in Orca. Add the repo in Orca or
    choose another terminal." Para una sesión de un runner, la carpeta es la carpeta local del repo (Settings › Repos) y
    el comando, el de `ssh`.
  - **Custom**: un comando con `{dir}` y `{command}` (ya entre comillas), corrido con `/bin/sh -c`.
```

- [ ] **Step 2: Add the T.3 clarification** right after the first T.3 bullet (the one ending in "sobrevive a reiniciar PRBar."):

```markdown
- La carpeta de la review hoy se borra apenas termina Claude, antes de publicar. Por eso se conserva **al terminar bien
  la review** (publicada después o no): es la carpeta de la última review del PR. Una review que falla se limpia como
  hoy (sus sesiones quedan en el registro, pero no se ofrecen).
- Al mergear o cerrar el PR también se mira `lsof`: una carpeta con un proceso adentro queda para Clean Up.
```

- [ ] **Step 3: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add docs/superpowers/specs/2026-11-24-prbar-session-terminal-design.md
git -C /Users/federico/Documents/PRBar-wt-term commit -m "Spec T.5: terminal launch forms verified by the spike"
```

---

### Task 2: Session id from the stream and from `ClaudeRunner`

**Files:**
- Modify: `Sources/PRBarCore/ClaudeStream.swift`
- Modify: `Sources/PRBarCore/ClaudeRunner.swift`
- Create: `Sources/PRBarCore/ClaudeSessions.swift`
- Test: `Sources/PRBarTests/ClaudeStreamTests.swift`, `Sources/PRBarTests/ClaudeRunnerTests.swift`

- [ ] **Step 1: Write the failing tests.** Append to `ClaudeStreamTests.cases` (in `Sources/PRBarTests/ClaudeStreamTests.swift`):

```swift
        TestCase("claude stream: lee el session_id del evento init; sin init no hay ID") {
            var parser = ClaudeStreamParser()
            try expectEqual(parser.sessionID, nil)
            _ = parser.consumeAll(readLine)
            _ = parser.consumeAll(resultLine)
            try expectEqual(parser.sessionID, nil)
            let initLine = #"{"type":"system","subtype":"init","session_id":"1b4e28ba-2fa1-11d2-883f-0016d3cca427","tools":["Read"]}"#
            try expectEqual(parser.consumeAll(initLine), [])
            try expectEqual(parser.sessionID, "1b4e28ba-2fa1-11d2-883f-0016d3cca427")
            // Otros eventos de sistema (hooks, compactación) traen session_id: no lo pisan.
            _ = parser.consumeAll(#"{"type":"system","subtype":"hook_response","session_id":"otro"}"#)
            try expectEqual(parser.sessionID, "1b4e28ba-2fa1-11d2-883f-0016d3cca427")
        },
```

Append to `ClaudeRunnerTests.cases` (in `Sources/PRBarTests/ClaudeRunnerTests.swift`):

```swift
        TestCase("claude runner: avisa el session_id de cada intento, también si la corrida falla después de arrancar") {
            let initLine = #"{"type":"system","subtype":"init","session_id":"1b4e28ba-2fa1-11d2-883f-0016d3cca427"}"#
            let seen = Box<[String]>([])
            var failing = invocation()
            failing.onSession = { seen.value.append($0) }
            let crashed = FakeStreamingRunner { _, _, _ in ([initLine], fail("boom", status: 3)) }
            _ = try await expectThrows { _ = try await claude(crashed, log: try logFile()).run(failing, as: Answer.self, onAgent: { _ in }) }
            try expectEqual(seen.value, ["1b4e28ba-2fa1-11d2-883f-0016d3cca427"])

            // Salida inválida: el reintento es otra corrida con su propio init.
            seen.value = []
            let retried = FakeStreamingRunner { _, _, _ in ([initLine, invalidLine], ok("")) }
            _ = try await expectThrows { _ = try await claude(retried, log: try logFile()).run(failing, as: Answer.self, onAgent: { _ in }) }
            try expectEqual(seen.value.count, 2)

            // Sin init no se avisa nada.
            seen.value = []
            let plain = FakeStreamingRunner { _, _, _ in ([validLine], ok("")) }
            _ = try await claude(plain, log: try logFile()).run(failing, as: Answer.self, onAgent: { _ in })
            try expectEqual(seen.value, [])
        },
```

- [ ] **Step 2: Run them and see them fail to compile**

Run: `swift run PRBarTests "session_id"`
Expected: build error `value of type 'ClaudeStreamParser' has no member 'sessionID'` and `value of type 'ClaudeInvocation' has no member 'onSession'`.

- [ ] **Step 3: Implement the parser.** In `Sources/PRBarCore/ClaudeStream.swift`, inside `ClaudeStreamParser`, add the property after `result`:

```swift
    /// The Claude Code session of this run (`session_id` of the `system/init` event, spec T.2); nil until it arrives.
    public private(set) var sessionID: String?
```

and add a case to the `switch type` in `consumeAll(_:)`, before `default`:

```swift
        case "system":
            // Solo el `init` dice de qué sesión es la corrida; los otros eventos de sistema no la cambian.
            if object["subtype"] as? String == "init", sessionID == nil,
               let id = object["session_id"] as? String, !id.isEmpty {
                sessionID = id
            }
            return []
```

- [ ] **Step 4: Implement the invocation callback.** In `Sources/PRBarCore/ClaudeRunner.swift`, add to `ClaudeInvocation` after `deadline`:

```swift
    /// Called with the run's Claude Code session id as soon as `claude -p` reports it (spec T.2), from any thread;
    /// once per attempt (a retry is another run). `nil` = nobody keeps it.
    public var onSession: (@Sendable (String) -> Void)?
```

Change its `init` to:

```swift
    public init(prompt: String, schema: String, tools: [String], workingDirectory: URL,
                additionalDirectories: [URL] = [], timeout: TimeInterval, logHeader: String,
                session: ClaudeSessionFlag? = nil, deadline: Date? = nil,
                onSession: (@Sendable (String) -> Void)? = nil) {
        self.prompt = prompt
        self.schema = schema
        self.tools = tools
        self.workingDirectory = workingDirectory
        self.additionalDirectories = additionalDirectories
        self.timeout = timeout
        self.logHeader = logHeader
        self.session = session
        self.deadline = deadline
        self.onSession = onSession
    }
```

In `attempt(_:as:onEvent:)`, replace the `onLine` closure with:

```swift
            let onSession = invocation.onSession
            let onLine: @Sendable (String) -> Void = { line in
                // Redacted before parsing: the decoded output and the errors don't carry the token either.
                let line = Redactor.redact(line, secrets: secrets)
                log.append(line + "\n")
                let (events, newSession) = parser.withLock { parser -> ([ClaudeStreamEvent], String?) in
                    let before = parser.sessionID
                    let events = parser.consumeAll(line)
                    return (events, parser.sessionID != before ? parser.sessionID : nil)
                }
                if let newSession { onSession?(newSession) }
                for event in events { onEvent(event) }
            }
```

- [ ] **Step 5: Create `Sources/PRBarCore/ClaudeSessions.swift`** with the capture helper used by the fixes (Task 4):

```swift
import Foundation
import os

/// A Claude Code session id and when PRBar heard of it (spec T.2).
public struct ClaudeSessionStamp: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var startedAt: Date

    public init(id: String, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }
}

/// Keeps the last session id `ClaudeInvocation.onSession` reported (the retry's, if there was one). Thread-safe:
/// the runner calls it from the process's reader thread.
public final class ClaudeSessionCapture: Sendable {
    private let state = OSAllocatedUnfairLock<ClaudeSessionStamp?>(initialState: nil)
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func record(_ id: String) {
        let stamp = ClaudeSessionStamp(id: id, startedAt: now())
        state.withLock { $0 = stamp }
    }

    public var stamp: ClaudeSessionStamp? { state.withLock { $0 } }
}
```

- [ ] **Step 6: Run the tests**

Run: `swift run PRBarTests "claude stream"` then `swift run PRBarTests "claude runner"`
Expected: all pass, including the two new cases.

- [ ] **Step 7: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources/PRBarCore/ClaudeStream.swift Sources/PRBarCore/ClaudeRunner.swift Sources/PRBarCore/ClaudeSessions.swift Sources/PRBarTests/ClaudeStreamTests.swift Sources/PRBarTests/ClaudeRunnerTests.swift
git -C /Users/federico/Documents/PRBar-wt-term commit -m "Read Claude's session id from stream-json and report it per run"
```

---

### Task 3: `ClaudeSessionRef` and `sessions` on the history records

**Files:**
- Modify: `Sources/PRBarCore/ClaudeSessions.swift`
- Modify: `Sources/PRBarCore/ReviewHistory.swift`
- Modify: `Sources/PRBarCore/RespondPipeline.swift`
- Modify: `Sources/PRBarCore/RespondModels.swift`
- Create: `Sources/PRBarTests/ClaudeSessionsTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Write the failing tests.** Create `Sources/PRBarTests/ClaudeSessionsTests.swift`:

```swift
import Foundation
import PRBarCore

private let sessionA = "0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50"
private let sessionB = "6f1c2d3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f"

private func comment(_ body: String) -> FeedbackComment {
    FeedbackComment(databaseID: 1, author: "ana", isBot: false, body: body, createdAt: t0,
                    url: URL(string: "https://github.com/o/r/pull/7#discussion_r1")!)
}

private func respondItem(_ id: String, kind: FeedbackItem.Kind = .thread, body: String) -> RespondItem {
    RespondItem(feedback: FeedbackItem(id: id, kind: kind, path: kind == .ciChecks ? nil : "README.md", line: nil,
                                       isOutdated: false, comments: kind == .ciChecks ? [] : [comment(body)]),
                assessment: "", action: .fix, fixPlan: "", reply: "")
}

private func respondDraft(_ items: [RespondItem]) -> RespondDraft {
    var draft = RespondDraft(prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "PR 7",
                             url: URL(string: "https://github.com/o/r/pull/7")!, headRef: "feature", account: "me",
                             worktree: ResolvedWorktree(path: "/repos/r-worktrees/r-7-respond-0a1b2c3d", origin: .dedicated,
                                                        localPath: "/repos/r", ref: "refs/prbar/respond-7-0a1b2c3d"),
                             startHeadOid: String(repeating: "0", count: 40), items: items)
    draft.runner = "devbox"
    return draft
}

private func reviewDraft() -> ReviewDraft {
    ReviewDraft(prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "PR 7",
                url: URL(string: "https://github.com/o/r/pull/7")!, author: "ana", headOid: "abc", account: "me",
                summary: "ok", items: [])
}

enum ClaudeSessionsTests {
    static let cases: [TestCase] = [
        TestCase("sesiones: nombres de las etapas, los fixes (truncados a 50) y el Fix CI") {
            let stamp = ClaudeSessionStamp(id: sessionA, startedAt: t0)
            let stage = ClaudeSessionRef.reviewStage(2, stamp: stamp, directory: "/wt/r-7", runner: nil)
            try expectEqual(stage.label, "Review · stage 2")
            try expectEqual(stage.kind, .review)

            let long = String(repeating: "x", count: 60)
            let items = [respondItem("thread:1", body: "\n  Renombrá la variable\nporque confunde"),
                         respondItem("thread:2", body: long),
                         respondItem("ci", kind: .ciChecks, body: "")]
            let results = [
                ItemResult(id: "thread:1", status: .committed, commit: nil, summary: "", session: stamp),
                ItemResult(id: "thread:2", status: .noChanges, commit: nil, summary: "",
                           session: ClaudeSessionStamp(id: sessionB, startedAt: t0.addingTimeInterval(60))),
                ItemResult(id: "ci", status: .failed, commit: nil, summary: "", session: stamp),
                ItemResult(id: "thread:9", status: .failed, commit: nil, summary: "", session: nil),
            ]
            let fixes = ClaudeSessionRef.fixes(draft: respondDraft(items), items: results)
            try expectEqual(fixes.map(\.label), ["Fix 1: Renombrá la variable", "Fix 2: " + String(repeating: "x", count: 49) + "…", "CI fix"])
            try expectEqual(fixes.map(\.kind), [.fix, .fix, .ciFix])
            try expectEqual(Set(fixes.map(\.directory)), ["/repos/r-worktrees/r-7-respond-0a1b2c3d"])
            try expectEqual(Set(fixes.map(\.runner)), ["devbox"])
            try expectEqual(ClaudeSessionRef.truncated(long).count, 50)
        },
        TestCase("sesiones: un ReviewRecord sin sessions carga; con sesiones, ida y vuelta") {
            let old = ReviewRecord(draft: reviewDraft(), startedAt: t0, status: .ready)
            let oldJSON = try JSONCoding.encoder.encode(old)
            try expect(!String(decoding: oldJSON, as: UTF8.self).contains("sessions"))
            try expectEqual(try JSONCoding.decoder.decode(ReviewRecord.self, from: oldJSON).sessions, nil)

            let session = ClaudeSessionRef.reviewStage(1, stamp: ClaudeSessionStamp(id: sessionA, startedAt: t0),
                                                       directory: "/wt/r-7", runner: "devbox")
            let record = ReviewRecord(draft: reviewDraft(), startedAt: t0, status: .ready, sessions: [session])
            let back = try JSONCoding.decoder.decode(ReviewRecord.self, from: JSONCoding.encoder.encode(record))
            try expectEqual(back.sessions, [session])
        },
        TestCase("sesiones: un RespondRecord sin sessions (o roto) carga; con sesiones, ida y vuelta") {
            let draft = respondDraft([respondItem("thread:1", body: "Arreglá esto")])
            let old = RespondRecord(draft: draft, startedAt: t0)
            try expectEqual(try JSONCoding.decoder.decode(RespondRecord.self, from: JSONCoding.encoder.encode(old)).sessions, nil)

            var broken = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(old)) as! [String: Any]
            broken["sessions"] = "not a list"
            let tolerated = try JSONCoding.decoder.decode(RespondRecord.self, from: JSONSerialization.data(withJSONObject: broken))
            try expectEqual(tolerated.sessions, nil)

            let sessions = ClaudeSessionRef.fixes(draft: draft, items: [
                ItemResult(id: "thread:1", status: .committed, commit: nil, summary: "",
                           session: ClaudeSessionStamp(id: sessionA, startedAt: t0)),
            ])
            let record = RespondRecord(draft: draft, startedAt: t0, sessions: sessions)
            let back = try JSONCoding.decoder.decode(RespondRecord.self, from: JSONCoding.encoder.encode(record))
            try expectEqual(back.sessions, sessions)
        },
        TestCase("sesiones: la captura se queda con el último ID (el del reintento)") {
            let capture = ClaudeSessionCapture(now: { t0 })
            try expectEqual(capture.stamp, nil)
            capture.record(sessionA)
            capture.record(sessionB)
            try expectEqual(capture.stamp, ClaudeSessionStamp(id: sessionB, startedAt: t0))
            try expect(ClaudeSessionRef.isValidID(sessionA))
            try expect(!ClaudeSessionRef.isValidID("abc; rm -rf ~"))
        },
    ]
}
```

Register it: in `Sources/PRBarTests/main.swift`, after `+ DiffFilesTests.cases` add:

```swift
    + ClaudeSessionsTests.cases
```

- [ ] **Step 2: Run and see it fail**

Run: `swift run PRBarTests "sesiones:"`
Expected: build errors (`ClaudeSessionRef` not found, `extra argument 'session' in call`, `extra argument 'sessions' in call`).

- [ ] **Step 3: Implement `ClaudeSessionRef`.** Append to `Sources/PRBarCore/ClaudeSessions.swift`:

```swift
/// One `claude -p` run of a PR job that can be resumed in a terminal (spec T.1/T.2): a review stage, a Respond fix or
/// the Fix CI. The chat isn't one.
public struct ClaudeSessionRef: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case review, fix, ciFix }

    /// Claude Code's session id (a UUID).
    public var id: String
    /// `Review · stage N`, `Fix N: <title>` or `CI fix`.
    public var label: String
    public var kind: Kind
    /// The folder it ran in, on the machine where it ran (`claude --resume` has to run there).
    public var directory: String
    /// `nil` = this Mac; otherwise the runner's name (`RunnerSettings`).
    public var runner: String?
    public var startedAt: Date

    public init(id: String, label: String, kind: Kind, directory: String, runner: String?, startedAt: Date) {
        self.id = id
        self.label = label
        self.kind = kind
        self.directory = directory
        self.runner = runner
        self.startedAt = startedAt
    }

    /// The fix titles in the labels are cut to this many characters (with the ellipsis).
    public static let titleLimit = 50

    public static func reviewStage(_ number: Int, stamp: ClaudeSessionStamp, directory: String, runner: String?) -> ClaudeSessionRef {
        ClaudeSessionRef(id: stamp.id, label: "Review · stage \(number)", kind: .review, directory: directory, runner: runner,
                         startedAt: stamp.startedAt)
    }

    /// The sessions of a Respond or Fix CI implementation, in the order the fixes ran: `Fix N: <title>` (N counts the
    /// fixes that ran, from 1) or `CI fix`. Items without a session (Claude never started) are skipped.
    public static func fixes(draft: RespondDraft, items: [ItemResult]) -> [ClaudeSessionRef] {
        items.enumerated().compactMap { index, result in
            guard let stamp = result.session else { return nil }
            let item = draft.items.first { $0.id == result.id }
            let isCI = item?.feedback.kind == .ciChecks
            let label = isCI ? "CI fix" : "Fix \(index + 1): " + truncated(item.map(title(of:)) ?? result.id)
            return ClaudeSessionRef(id: stamp.id, label: label, kind: isCI ? .ciFix : .fix, directory: draft.worktree.path,
                                    runner: draft.runner, startedAt: stamp.startedAt)
        }
    }

    /// The finding's title: the first non-empty line of its first comment, or its file.
    static func title(of item: RespondItem) -> String {
        let body = item.feedback.comments.first?.body ?? ""
        let line = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? item.feedback.path ?? item.id
    }

    /// At most `limit` characters, the last one `…` when it was cut.
    public static func truncated(_ text: String, limit: Int = titleLimit) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// Only a UUID goes after `--resume` (spec T.5).
    public static func isValidID(_ id: String) -> Bool { UUID(uuidString: id) != nil }
}
```

- [ ] **Step 4: `ItemResult.session`.** In `Sources/PRBarCore/RespondModels.swift`, replace `ItemResult` with:

```swift
public struct ItemResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case committed, noChanges, failed }
    public let id: String
    public let status: Status
    public let commit: String?
    public let summary: String
    /// The Claude Code session of this fix (spec T.2); nil if Claude never started or in older records.
    public var session: ClaudeSessionStamp?

    public init(id: String, status: Status, commit: String?, summary: String, session: ClaudeSessionStamp? = nil) {
        self.id = id
        self.status = status
        self.commit = commit
        self.summary = summary
        self.session = session
    }
}
```

- [ ] **Step 5: `ReviewRecord.sessions`.** In `Sources/PRBarCore/ReviewHistory.swift`, add after `requestedOnPhone`:

```swift
    /// The Claude sessions of the review's stages (spec T.2). Nil in older records (synthesized decoding: optional).
    public var sessions: [ClaudeSessionRef]?
```

and change the `init` signature and body end to:

```swift
    public init(
        draft: ReviewDraft, startedAt: Date, finishedAt: Date? = nil, status: Status, errorMessage: String? = nil,
        published: [String: String] = [:], generalComment: String? = nil, action: Action = .none,
        reviewURL: URL? = nil, kind: String = "review", requestedOnPhone: Bool? = nil, sessions: [ClaudeSessionRef]? = nil
    ) {
        self.draft = draft
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.errorMessage = errorMessage
        self.published = published
        self.generalComment = generalComment
        self.action = action
        self.reviewURL = reviewURL
        self.kind = kind
        self.requestedOnPhone = requestedOnPhone
        self.sessions = sessions
    }
```

- [ ] **Step 6: `RespondRecord.sessions`.** In `Sources/PRBarCore/RespondPipeline.swift`, in `RespondRecord`:

Add the property after `requestedOnPhone`:

```swift
    /// The Claude sessions of the fixes or the Fix CI (spec T.2). Nil in older history files.
    public var sessions: [ClaudeSessionRef]?
```

Replace the `init` with:

```swift
    public init(draft: RespondDraft, selections: [String: RespondSelection] = [:], result: RespondResult? = nil,
                posted: [String: PostedReply] = [:], pushed: Bool = false, startedAt: Date, finishedAt: Date? = nil,
                errorMessage: String? = nil, chat: ChatSession? = nil, usage: ClaudeUsage? = nil,
                requestedOnPhone: Bool? = nil, sessions: [ClaudeSessionRef]? = nil) {
        self.draft = draft
        self.selections = selections
        self.result = result
        self.posted = posted
        self.pushed = pushed
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.chat = chat
        self.usage = usage
        self.requestedOnPhone = requestedOnPhone
        self.sessions = sessions
    }
```

Replace `CodingKeys` with:

```swift
    private enum CodingKeys: String, CodingKey {
        case draft, selections, result, posted, pushed, startedAt, finishedAt, errorMessage, chat, usage, requestedOnPhone
        case sessions
    }
```

and add as the last line of `init(from:)`:

```swift
        sessions = (try? c.decodeIfPresent([ClaudeSessionRef].self, forKey: .sessions)) ?? nil
```

- [ ] **Step 7: Run the tests**

Run: `swift run PRBarTests "sesiones:"`
Expected: 4/4 passed. Then `swift build --product PRBar` (no errors).

- [ ] **Step 8: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources/PRBarCore/ClaudeSessions.swift Sources/PRBarCore/ReviewHistory.swift Sources/PRBarCore/RespondPipeline.swift Sources/PRBarCore/RespondModels.swift Sources/PRBarTests/ClaudeSessionsTests.swift Sources/PRBarTests/main.swift
git -C /Users/federico/Documents/PRBar-wt-term commit -m "ClaudeSessionRef and sessions on review and respond records"
```

---

### Task 4: Record the sessions of review stages, fixes and Fix CI

**Files:**
- Modify: `Sources/PRBarCore/ClaudeReviewer.swift`
- Modify: `Sources/PRBarCore/ReviewModels.swift`
- Modify: `Sources/PRBarCore/ReviewPipeline.swift`
- Modify: `Sources/PRBarCore/FixImplementer.swift`
- Modify: `Sources/PRBarCore/RespondQueue.swift`
- Modify: `Sources/PRBar/AppModel.swift`
- Test: `Sources/PRBarTests/ReviewQueueTests.swift`, `Sources/PRBarTests/FixImplementerTests.swift`, `Sources/PRBarTests/RespondQueueTests.swift`

- [ ] **Step 1: Write the failing tests.**

In `Sources/PRBarTests/ReviewQueueTests.swift`, next to `stageOneEmpty` add:

```swift
private let reviewSessionID = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
private let initLine = #"{"type":"system","subtype":"init","session_id":"1b4e28ba-2fa1-11d2-883f-0016d3cca427"}"#
```

Append to `ReviewPipelineTests.cases`:

```swift
        TestCase("review pipeline: guarda la sesión de cada etapa (también si Claude falla)") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let claude = FakeStreamingRunner { _, _, _ in ([initLine, stageOneEmpty], ok("")) }
            let draft = try await pipeline(git: gitFake(), claude: claude, root: root.appendingPathComponent("wt"), logs: root)
                .run(clonedRequest(9)) { _ in }
            try expectEqual(draft.sessions.map(\.label), ["Review · stage 1"])
            try expectEqual(draft.sessions.map(\.id), [reviewSessionID])
            try expectEqual(draft.sessions.map(\.runner), [nil])
            try expect(draft.sessions[0].directory.hasPrefix(root.appendingPathComponent("wt").path), draft.sessions[0].directory)

            let crashed = FakeStreamingRunner { _, _, _ in ([initLine], fail("boom", status: 3)) }
            let error = try await expectThrows {
                _ = try await pipeline(git: gitFake(), claude: crashed, root: root.appendingPathComponent("wt2"), logs: root)
                    .run(clonedRequest(9)) { _ in }
            }
            try expectEqual((error as? ReviewFailure)?.sessions.map(\.id), [reviewSessionID])
        },
```

In `Sources/PRBarTests/FixImplementerTests.swift`, append to the test enum's `cases` (the `static let cases: [TestCase]` of `FixImplementerTests`):

```swift
        TestCase("fixes: cada fix guarda la sesión de su corrida de Claude") {
            let repo = try FixRepo.make()
            defer { repo.remove() }
            let session = "0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50"
            let initLine = #"{"type":"system","subtype":"init","session_id":"\#(session)"}"#
            let claude = FakeStreamingRunner { _, _, cwd in
                guard let cwd else { throw TestFailure(description: "sin cwd") }
                try edit("README.md", "chau\n")(cwd)
                return ([initLine, fixLine("done", message: "Arreglar el README")], ok(""))
            }
            let one = item("thread:1", marker: "uno")
            let result = try await run(implementer(claude, log: try logURL()), try draft(repo, items: [one]), selections([one]))
            try expectEqual(result.items.map(\.status), [.committed])
            try expectEqual(result.items.map(\.session?.id), [session])
        },
```

In `Sources/PRBarTests/RespondQueueTests.swift`, append to `RespondQueueTests.cases`:

```swift
        TestCase("respond queue: guarda las sesiones de Claude de los fixes en el registro") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            let stamp = ClaudeSessionStamp(id: "6f1c2d3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f", startedAt: t0)
            let result = RespondResult(items: [ItemResult(id: "thread:A", status: .committed, commit: sha1, summary: "ok", session: stamp)],
                                       diffStat: " README.md | 1 +", tests: nil)
            h.pipeline.completeImplementation(prID(1), .success(result))
            try await h.events.wait(for: reached(1, "readyToPush"))
            let sessions = try h.saved(1).sessions ?? []
            try expectEqual(sessions.map(\.label), ["Fix 1: Cambiá esto."])
            try expectEqual(sessions.map(\.directory), ["/wt/1"])
            try expectEqual(sessions.map(\.kind), [.fix])
        },
```

- [ ] **Step 2: Run and see them fail**

Run: `swift run PRBarTests "sesión"`
Expected: build errors (`value of type 'ReviewDraft' has no member 'sessions'`, `ReviewFailure` has no member `sessions`).

- [ ] **Step 3: `ReviewDraft` transient fields.** In `Sources/PRBarCore/ReviewModels.swift`, inside `ReviewDraft`, after `usage`, add (they are not in `CodingKeys`, so they are never encoded):

```swift
    /// The Claude sessions of this run's stages (spec T.2), until `AppModel` saves them in the record. Not encoded.
    public var sessions: [ClaudeSessionRef] = []
    /// The review's folder kept for "Open in Terminal" (spec T.3, Task 5); nil = it was removed. Not encoded.
    public var retainedLocation: WorktreeLocation? = nil
```

`WorktreeLocation` is created in Task 5; to keep this task compiling, add it now at the top of a new file `Sources/PRBarCore/RetainedWorktrees.swift` (Task 5 adds the rest of the file):

```swift
import Foundation

/// Where a kept folder lives and what removes it (spec T.3).
public struct WorktreeLocation: Codable, Equatable, Hashable, Sendable {
    /// The folder, on the machine where it is.
    public var directory: String
    /// `nil` = this Mac; otherwise the runner's name.
    public var runner: String?
    /// The repo the worktree hangs from: the user's clone on this Mac or PRBar's bare mirror on the runner. Nil for a
    /// diff-only review folder (not a git worktree).
    public var repository: String?
    /// PRBar's own refs of that run (`refs/prbar/…`), deleted with the folder.
    public var refs: [String]

    public init(directory: String, runner: String?, repository: String?, refs: [String]) {
        self.directory = directory
        self.runner = runner
        self.repository = repository
        self.refs = refs
    }
}
```

- [ ] **Step 4: `ClaudeReviewer` reports each stage.** In `Sources/PRBarCore/ClaudeReviewer.swift`:

Change `review`'s signature to:

```swift
    public func review(
        pr: PullRequest, workspace: ReviewWorkspace, language: PRLanguage, ignorePaths: [String] = [],
        onSession: @escaping @Sendable (_ stage: Int, ClaudeSessionStamp) -> Void = { _, _ in },
        onProgress: @escaping @MainActor @Sendable (ReviewStage, Int) -> Void
    ) async throws -> (summary: String, items: [ReviewItem]) {
```

In both `runStage` calls inside `review`, add `onSession: onSession,` before `onProgress: onProgress` (stage 1: after `workspace: workspace,`; stage 2 the same).

Replace `runStage` with:

```swift
    private func runStage<Output: Decodable>(
        _ stage: ReviewStage, number: Int, prompt: String, schema: String,
        workspace: ReviewWorkspace,
        onSession: @escaping @Sendable (Int, ClaudeSessionStamp) -> Void,
        onProgress: @escaping @MainActor @Sendable (ReviewStage, Int) -> Void
    ) async throws -> Output {
        let progress = MainActorRelay<Int> { onProgress(stage, $0) }
        var invocation = Self.invocation(prompt: prompt, schema: schema, workspace: workspace, header: "=== stage \(number) ===")
        invocation.onSession = { id in onSession(number, ClaudeSessionStamp(id: id, startedAt: Date())) }
        do {
            let output = try await claude.run(invocation, as: Output.self, onAgent: { progress.send($0) })
            await progress.finish()
            return output
        } catch {
            await progress.finish()
            throw error
        }
    }
```

- [ ] **Step 5: `ReviewPipeline` collects them.** In `Sources/PRBarCore/ReviewPipeline.swift`:

Add `import os` under `import Foundation`.

Replace `ReviewFailure` with:

```swift
public struct ReviewFailure: Error, LocalizedError {
    public let underlying: Error
    public let logURL: URL?
    /// The sessions of the stages that started (spec T.2): History keeps them.
    public var sessions: [ClaudeSessionRef]

    public init(underlying: Error, logURL: URL?, sessions: [ClaudeSessionRef] = []) {
        self.underlying = underlying
        self.logURL = logURL
        self.sessions = sessions
    }

    public var errorDescription: String? { underlying.localizedDescription }
}
```

Replace `run(_:onPhase:)` with:

```swift
    public func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        let pr = request.item.pr
        let draftID = UUID()
        let logURL = logURLProvider(draftID)
        // The stages' sessions (spec T.2), by stage: a retry replaces its stage's.
        let recorded = OSAllocatedUnfairLock(initialState: [Int: ClaudeSessionRef]())
        let sessions: @Sendable () -> [ClaudeSessionRef] = {
            recorded.withLock { $0.sorted { $0.key < $1.key }.map(\.value) }
        }
        let runnerName = placement?.name

        do {
            let token = try await tokens.token(for: request.item.account)
            let parts = try await parts(request, token: token, logURL: logURL)
            try Task.checkCancellation()
            await onPhase(.preparing)
            let description = try await Self.description(of: pr, api: api, token: token)
            let language = PRLanguage.detect(description: description, title: pr.title)
            let workspace = try await parts.prepare()

            let result: (summary: String, items: [ReviewItem])
            let headOid: String
            do {
                headOid = try await parts.writeContext(workspace, description ?? "")
                try Task.checkCancellation()
                result = try await parts.reviewer.review(
                    pr: pr, workspace: workspace, language: language, ignorePaths: request.ignorePaths,
                    onSession: { stage, stamp in
                        let session = ClaudeSessionRef.reviewStage(stage, stamp: stamp, directory: workspace.directory.path,
                                                                   runner: runnerName)
                        recorded.withLock { $0[stage] = session }
                    }
                ) { stage, agents in
                    onPhase(stage == .reviewing ? .reviewing(agents: agents) : .filtering)
                }
            } catch {
                await Self.cleanup(workspace, parts, after: error)
                throw error
            }
            await Self.cleanup(workspace, parts, after: nil)
            try Task.checkCancellation()

            var draft = ReviewDraft(
                prID: request.item.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url,
                author: pr.author, headOid: headOid, account: request.item.account,
                summary: result.summary,
                items: ReviewOptionsFilter.apply(result.items, options: settings.review, repoIgnorePaths: request.ignorePaths),
                language: language
            )
            draft.id = draftID
            draft.sessions = sessions()
            return draft
        } catch {
            if RemoteUnstoppedJobs.isNotStopped(error) {
                // Claude puede seguir corriendo en el host: el error lo dice (también si fue un Stop).
                let existingLog = FileManager.default.fileExists(atPath: logURL.path) ? logURL : nil
                throw ReviewFailure(underlying: error, logURL: existingLog, sessions: sessions())
            }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let failure = error as? ReviewFailure { throw failure }
            let existingLog = FileManager.default.fileExists(atPath: logURL.path) ? logURL : nil
            throw ReviewFailure(underlying: error, logURL: existingLog, sessions: sessions())
        }
    }
```

- [ ] **Step 6: `FixImplementer` captures one session per fix.** In `Sources/PRBarCore/FixImplementer.swift`:

In `implement(draft:selections:onProgress:)`, replace the `for` loop with:

```swift
        var results: [ItemResult] = []
        for (index, (item, fixPlan)) in work.enumerated() {
            // Claude's session of this fix (spec T.2), also when the fix failed after Claude started.
            let capture = ClaudeSessionCapture()
            var result = try await implementOne(item, fixPlan: fixPlan, draft: draft, worktree: worktree, start: start,
                                                guarded: guarded, capture: capture)
            result.session = capture.stamp
            results.append(result)
            await onProgress(index + 1, work.count)
        }
```

Change `implementOne`'s signature to:

```swift
    private func implementOne(_ item: RespondItem, fixPlan: String, draft: RespondDraft, worktree: URL, start: String,
                              guarded: GitPaths, capture: ClaudeSessionCapture) async throws -> ItemResult {
```

and its `ClaudeInvocation(…)` to:

```swift
        let invocation = ClaudeInvocation(
            prompt: isCI ? CIFixPrompt.prompt(item: item, draft: draft, settings: settings, rules: effectiveRules)
                         : Self.prompt(item: item, fixPlan: fixPlan, settings: settings, rules: effectiveRules),
            schema: RespondSchemas.fix, tools: Self.tools,
            workingDirectory: worktree, timeout: Self.fixTimeout, logHeader: isCI ? "=== CI fix ===" : "=== fix \(item.id) ===",
            onSession: { capture.record($0) }
        )
```

In `squash`, replace the last line with:

```swift
        return results.map {
            $0.status == .committed ? ItemResult(id: $0.id, status: .committed, commit: sha, summary: $0.summary, session: $0.session) : $0
        }
```

- [ ] **Step 7: `RespondQueue` saves them.** In `Sources/PRBarCore/RespondQueue.swift`, replace `reachReadyToPush` with:

```swift
    private func reachReadyToPush(_ prID: String, draft: RespondDraft, result: RespondResult) {
        leftWork.remove(prID)
        records[prID]?.result = result
        records[prID]?.errorMessage = nil
        // Claude's sessions of the fixes (spec T.2). A test run or a chat turn brings no new ones: they stay.
        let sessions = ClaudeSessionRef.fixes(draft: draft, items: result.items)
        if !sessions.isEmpty { records[prID]?.sessions = sessions }
        if let record = records[prID] { save(record) }
        finish(prID, .readyToPush(draft, result))
    }
```

- [ ] **Step 8: `AppModel` writes the review's into History.** In `Sources/PRBar/AppModel.swift`, in `reviewFinished(_:_:)`:

Replace `record = ReviewRecord(draft: draft, startedAt: startedAt, finishedAt: Date(), status: .ready)` with:

```swift
            record = ReviewRecord(draft: draft, startedAt: startedAt, finishedAt: Date(), status: .ready,
                                  sessions: draft.sessions.isEmpty ? nil : draft.sessions)
```

and in the failure branch, right after the `record = ReviewRecord(… status: .failed …)` statement:

```swift
            if let sessions = (error as? ReviewFailure)?.sessions, !sessions.isEmpty { record.sessions = sessions }
```

- [ ] **Step 9: Run the tests**

Run: `swift run PRBarTests "review pipeline"`, `swift run PRBarTests "fixes:"`, `swift run PRBarTests "respond queue"`, `swift run PRBarTests "remote flow"`
Expected: all pass. `swift build --product PRBar` succeeds.

- [ ] **Step 10: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources/PRBarCore Sources/PRBar/AppModel.swift Sources/PRBarTests/ReviewQueueTests.swift Sources/PRBarTests/FixImplementerTests.swift Sources/PRBarTests/RespondQueueTests.swift
git -C /Users/federico/Documents/PRBar-wt-term commit -m "Record Claude sessions of review stages, fixes and Fix CI"
```

---

### Task 5: Retained worktrees (store, rules, release, orphan and Clean Up protection)

**Files:**
- Modify: `Sources/PRBarCore/RetainedWorktrees.swift`
- Modify: `Sources/PRBarCore/Support.swift`
- Modify: `Sources/PRBarCore/WorktreeManager.swift`
- Modify: `Sources/PRBarCore/WorktreeResolver.swift`
- Modify: `Sources/PRBarCore/RemoteWorkspaces.swift`
- Modify: `Sources/PRBarCore/ReviewPipeline.swift`
- Modify: `Sources/PRBarCore/DiskCleanup.swift`
- Modify: `Sources/PRBarCore/RespondQueue.swift`
- Create: `Sources/PRBarTests/RetainedWorktreesTests.swift`
- Modify: `Sources/PRBarTests/main.swift`, `Sources/PRBarTests/ReviewQueueTests.swift`, `Sources/PRBarTests/RemoteFlowTests.swift`, `Sources/PRBarTests/RespondQueueTests.swift`, `Sources/PRBarTests/DiskCleanupTests.swift`

- [ ] **Step 1: Write the failing tests.** Create `Sources/PRBarTests/RetainedWorktreesTests.swift`:

```swift
import Foundation
import PRBarCore

private func entry(_ number: Int, _ job: RetainedWorktree.Job, dir: String, account: String = "me",
                   runner: String? = nil, superseded: Bool = false) -> RetainedWorktree {
    RetainedWorktree(prID: "o/r#\(number)", account: account, repo: RepoRef(owner: "o", name: "r"), number: number, job: job,
                     recordID: UUID(), location: WorktreeLocation(directory: dir, runner: runner, repository: "/repos/r",
                                                                  refs: ["refs/prbar/pr-\(number)-0a0a0a0a", "refs/prbar/base-\(number)-0a0a0a0a"]),
                     sessions: [], retainedAt: t0, superseded: superseded)
}

enum RetainedWorktreesTests {
    static let cases: [TestCase] = [
        TestCase("carpetas conservadas: un trabajo nuevo del mismo tipo reemplaza la anterior; los otros quedan") {
            let review = entry(7, .review, dir: "/wt/r-7-a")
            let respond = entry(7, .respond, dir: "/repos/r-worktrees/r-7-respond-0a0a0a0a")
            let other = entry(8, .review, dir: "/wt/r-8-a")
            let newer = entry(7, .review, dir: "/wt/r-7-b")
            let (entries, replaced) = RetainedWorktreeRules.retain(newer, in: [review, respond, other])
            try expectEqual(replaced, [review])
            try expectEqual(Set(entries.map(\.location.directory)), ["/wt/r-7-b", "/repos/r-worktrees/r-7-respond-0a0a0a0a", "/wt/r-8-a"])
            // Volver a conservar la misma carpeta no la reemplaza.
            try expectEqual(RetainedWorktreeRules.retain(newer, in: entries).replaced, [])
        },
        TestCase("carpetas conservadas: se borran al mergear o cerrar; abiertas o sin respuesta quedan") {
            let merged = entry(1, .review, dir: "/wt/1")
            let closed = entry(2, .respond, dir: "/wt/2")
            let open = entry(3, .review, dir: "/wt/3")
            let unknown = entry(4, .review, dir: "/wt/4")
            let states: [String: PRDetails.State] = ["o/r#1": .merged, "o/r#2": .closed, "o/r#3": .open]
            try expectEqual(RetainedWorktreeRules.closedOnes([merged, closed, open, unknown], states: states), [merged, closed])
        },
        TestCase("carpetas conservadas: solo se le pregunta a GitHub por PRs fuera de la lista, de repos que respondieron, una vez por hora") {
            let listed = entry(1, .review, dir: "/wt/1")
            let gone = entry(2, .review, dir: "/wt/2")
            let otherAccount = entry(3, .review, dir: "/wt/3", account: "work")
            let scope = Snapshot.scope(account: "me", repo: RepoRef(owner: "o", name: "r"))
            let due = RetainedWorktreeRules.needsStateCheck([listed, gone, otherAccount], listed: ["o/r#1"], fetchedScopes: [scope],
                                                            checkedAt: [:], now: t0)
            try expectEqual(due, [gone])
            try expectEqual(RetainedWorktreeRules.needsStateCheck([gone], listed: [], fetchedScopes: [scope],
                                                                  checkedAt: ["o/r#2": t0.addingTimeInterval(-600)], now: t0), [])
            try expectEqual(RetainedWorktreeRules.needsStateCheck([gone], listed: [], fetchedScopes: [scope],
                                                                  checkedAt: ["o/r#2": t0.addingTimeInterval(-7200)], now: t0), [gone])
        },
        TestCase("carpetas conservadas: lsof con un proceso adentro (cwd) la deja, marcada como reemplazada") {
            let output = "p12\nfcwd\nn/Users/me/wt/r-1\np13\nfcwd\nn/Users/me/wt/r-10/src\n"
            try expect(ProcessCwd.anyInside(["/Users/me/wt/r-1"], lsofOutput: output))
            try expect(ProcessCwd.anyInside(["/Users/me/wt/r-10"], lsofOutput: output))
            try expect(!ProcessCwd.anyInside(["/Users/me/wt/r"], lsofOutput: output))
            try expect(!ProcessCwd.anyInside(["/Users/me/wt/r-2"], lsofOutput: output))

            let busy = entry(1, .review, dir: "/Users/me/wt/r-1")
            let free = entry(2, .review, dir: "/Users/me/wt/r-2")
            let removed = Box<[String]>([])
            let cleaner = RetainedWorktreeCleaner(
                isBusy: { $0.directory == "/Users/me/wt/r-1" },
                remove: { removed.value.append($0.location.directory) })
            let left = await cleaner.removeUnlessBusy([busy, free])
            try expectEqual(removed.value, ["/Users/me/wt/r-2"])
            try expectEqual(left.map(\.location.directory), ["/Users/me/wt/r-1"])
            try expect(left.allSatisfy(\.superseded))
        },
        TestCase("carpetas conservadas: el archivo, ida y vuelta; ilegible = vacío") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = RetainedWorktreeStore(fileURL: dir.appendingPathComponent("retained-worktrees.json"))
            try expectEqual(store.load(), [])
            let entries = [entry(1, .review, dir: "/wt/1"), entry(2, .respond, dir: "/wt/2", runner: "devbox", superseded: true)]
            try store.save(entries)
            try expectEqual(store.load(), entries)
            try Data("{".utf8).write(to: store.fileURL)
            try expectEqual(store.load(), [])
        },
        TestCase("carpetas conservadas: lo que hace falta para borrarlas (review y Respond)") {
            let review = entry(7, .review, dir: "/wt/r-7-1700000000-0a0a0a0a").location
            try expectEqual(review.reviewWorkspace.prRef, "refs/prbar/pr-7-0a0a0a0a")
            try expectEqual(review.reviewWorkspace.baseRef, "refs/prbar/base-7-0a0a0a0a")
            try expect(!review.reviewWorkspace.isDiffOnly)
            let respond = WorktreeLocation(directory: "/repos/r-worktrees/r-7-respond-0a0a0a0a", runner: nil, repository: "/repos/r",
                                           refs: ["refs/prbar/respond-7-0a0a0a0a"])
            try expectEqual(respond.respondWorktree, ResolvedWorktree(path: "/repos/r-worktrees/r-7-respond-0a0a0a0a", origin: .dedicated,
                                                                      localPath: "/repos/r", ref: "refs/prbar/respond-7-0a0a0a0a"))
        },
        TestCase("carpetas conservadas: la limpieza del arranque no toca las conservadas (review y Respond)") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let kept = repo.root.appendingPathComponent("local-7-1700000000-0a0a0a0a")
            let orphan = repo.root.appendingPathComponent("local-7-1700000000-0b0b0b0b")
            let respondDir = repo.base.appendingPathComponent("local-worktrees")
            let keptRespond = respondDir.appendingPathComponent("local-7-respond-0c0c0c0c")
            for url in [kept, orphan, keptRespond] {
                try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", url.path, "HEAD"])
            }
            let isolated = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
            await WorktreeResolver(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, environment: isolated)
                .cleanupOrphans(localPath: repo.local.path, worktreeDir: respondDir.path, keeping: [keptRespond.path])
            await WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
                .cleanupOrphans(localPaths: [repo.local.path], keeping: [kept.path])
            try expect(FileManager.default.fileExists(atPath: kept.path))
            try expect(FileManager.default.fileExists(atPath: keptRespond.path))
            try expect(!FileManager.default.fileExists(atPath: orphan.path))
        },
    ]
}
```

Register in `Sources/PRBarTests/main.swift` (after `+ ClaudeSessionsTests.cases`):

```swift
    + RetainedWorktreesTests.cases
```

Append to `DiskCleanupTests.cases` (in `Sources/PRBarTests/DiskCleanupTests.swift`):

```swift
        TestCase("cleanup: una carpeta de review conservada con cambios sin commitear se saltea; limpia se borra") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let clean = repo.root.appendingPathComponent("local-7-1700000000-0a0a0a0a")
            let dirty = repo.root.appendingPathComponent("local-7-1700000000-0b0b0b0b")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", clean.path, "HEAD"])
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", dirty.path, "HEAD"])
            try Data("wip\n".utf8).write(to: dirty.appendingPathComponent("wip.txt"))
            let executor = DiskCleanupExecutor(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, worktreeRoots: [repo.root],
                                               repos: [DiskScanInput.RespondDir(repo: "acme/local", path: repo.base.appendingPathComponent("local-worktrees").path,
                                                                                localPath: repo.local.path)],
                                               retained: [clean.path, dirty.path],
                                               gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                                               registry: WorkspaceRegistry())
            let result = await executor.run(CleanupPlan(candidates: [
                CleanupCandidate(path: clean.path, bytes: 1, kind: .workspace, clone: repo.local.path, title: "clean"),
                CleanupCandidate(path: dirty.path, bytes: 1, kind: .workspace, clone: repo.local.path, title: "dirty"),
            ]))
            try expectEqual(result.removed, [clean.path])
            try expectEqual(result.skipped, ["dirty: has uncommitted changes"])
            try expect(FileManager.default.fileExists(atPath: dirty.path))
        },
```

In `Sources/PRBarTests/ReviewQueueTests.swift`, replace the test `"review pipeline: éxito arma el draft con headOid, account y url, y limpia"` with:

```swift
        TestCase("review pipeline: éxito arma el draft con headOid, account y url, y conserva la carpeta sin su contexto") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let git = gitFake()
            let claude = FakeStreamingRunner { _, _, _ in ([stageOneEmpty], ok("")) }
            let phases = Box<[ReviewPhase]>([])
            let req = clonedRequest(9)
            let draft = try await pipeline(git: git, claude: claude, root: root.appendingPathComponent("wt"), logs: root)
                .run(req) { phases.value.append($0) }
            // El commit revisado es el que se trajo con el fetch, no el del snapshot ("deadbeef").
            try expectEqual(draft.headOid, fetchedSHA)
            try expectEqual(draft.account, "fede")
            try expectEqual(draft.url, req.item.pr.url)
            try expectEqual(draft.prID, req.item.id)
            try expectEqual(draft.summary, "Todo bien.")
            try expectEqual(phases.value, [.preparing, .reviewing(agents: 0)])
            try expectEqual(claude.calls[0].environment?["GH_TOKEN"], nil)
            let args = claude.calls[0].arguments
            try expectEqual(args.filter { $0 == "--plugin-dir" }.count, 2)
            try expect(args.contains(root.appendingPathComponent("plugins/official/superpowers/1.0").path), "\(args)")
            // Spec T.3: la carpeta y sus refs quedan para "Open in Terminal"; el contexto (pr.diff, pr.md) no.
            try expect(!cleanedUp(git))
            let kept = try expectSome(draft.retainedLocation)
            try expectEqual(kept.repository, "/repos/r")
            try expectEqual(kept.runner, nil)
            try expectEqual(kept.refs.count, 2)
            try expect(!FileManager.default.fileExists(atPath: kept.directory + ".context"))
            try expect(!WorkspaceRegistry.shared.contains(kept.directory))
            // El log usa el id del draft.
            try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(draft.id.uuidString).log").path))
        },
```

In `Sources/PRBarTests/RemoteFlowTests.swift`, in `"remote flow: un review corre en el host (worktree, contexto, claude aislado) y limpia todo"`, rename it to `"remote flow: un review corre en el host (worktree, contexto, claude aislado) y conserva solo el worktree"` and replace the line `try expectEqual(try FileManager.default.contentsOfDirectory(atPath: remote.root.work), [])` with:

```swift
            let kept = try expectSome(draft.retainedLocation)
            try expectEqual(kept.runner, remote.name)
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: remote.root.work),
                            [URL(fileURLWithPath: kept.directory).lastPathComponent])
```

In `Sources/PRBarTests/RespondQueueTests.swift`, give `Harness` an optional retention hook. Replace its stored properties/`init` head with:

```swift
@MainActor
private final class Harness {
    let events = QueueEventLog()
    let pipeline: FakeRespondPipeline
    let history: RespondHistory
    let historyDir: URL
    var emitted: [(String, RespondPhase)] = []
    /// The drafts `RespondQueue` handed to `onRetain` (only with `retains: true`).
    var retained: [UUID] = []
    private(set) var queue: RespondQueue!

    init(maxConcurrent: Int = 2, retains: Bool = false) throws {
        pipeline = FakeRespondPipeline(events: events)
        historyDir = try temporaryDirectory()
        history = RespondHistory(historyDir: historyDir)
        queue = RespondQueue(pipeline: pipeline, history: history, maxConcurrent: maxConcurrent, onEvent: { [unowned self] prID, phase in
            self.emitted.append((prID, phase))
            self.events.record(.finished("\(prID)|\(phase.name)"))
        }, onRetain: retains ? { [unowned self] record in self.retained.append(record.id) } : nil)
    }
```

and append to `RespondQueueTests.cases`:

```swift
        TestCase("respond queue: con onRetain, un push terminado conserva la carpeta en vez de borrarla") { @MainActor in
            let h = try Harness(retains: true)
            try await h.toReadyToPush(1)
            let draft = try h.saved(1).draft
            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
            await h.settle()
            try expectEqual(h.retained, [draft.id])
            try expectEqual(h.pipeline.cleanups, [])
        },
```

- [ ] **Step 2: Run and see them fail**

Run: `swift run PRBarTests "carpetas conservadas"`
Expected: build errors (`RetainedWorktree`, `RetainedWorktreeRules`, `ProcessCwd`, `RetainedWorktreeCleaner`, `RetainedWorktreeStore` not found; extra arguments `keeping:`, `retained:`, `onRetain:`).

- [ ] **Step 3: AppPaths.** In `Sources/PRBarCore/Support.swift`, after `slackStateFile`:

```swift
    /// The folders kept for "Open in Terminal" (spec T.3).
    public static var retainedWorktreesFile: URL { appSupport.appendingPathComponent("retained-worktrees.json") }
    /// The `.command` scripts that open a Claude session in a terminal (spec T.5); the ones older than a day go.
    public static var terminalDir: URL { appSupport.appendingPathComponent("terminal", isDirectory: true) }
```

- [ ] **Step 4: The rest of `Sources/PRBarCore/RetainedWorktrees.swift`.** Append after `WorktreeLocation` (and add `import os` under `import Foundation`):

```swift
extension WorktreeLocation {
    /// The review workspace `WorktreeManager.cleanup` / `RemoteWorkspaces.cleanup` remove.
    public var reviewWorkspace: ReviewWorkspace {
        ReviewWorkspace(directory: URL(fileURLWithPath: directory, isDirectory: true),
                        baseRef: refs.first { $0.hasPrefix("refs/prbar/base-") },
                        prRef: refs.first { $0.hasPrefix("refs/prbar/pr-") },
                        isDiffOnly: repository == nil)
    }

    /// The Respond worktree `WorktreeResolver.cleanup` / `RemoteWorkspaces.cleanupRespond` remove.
    public var respondWorktree: ResolvedWorktree {
        ResolvedWorktree(path: directory, origin: .dedicated, localPath: repository, ref: refs.first)
    }
}

/// A folder PRBar keeps after a review or pushed fixes so its Claude sessions can be resumed (spec T.3).
public struct RetainedWorktree: Codable, Equatable, Hashable, Sendable {
    /// Respond and Fix CI share the branch's folder: one `respond` folder per PR.
    public enum Job: String, Codable, Sendable { case review, respond }

    public var prID: String
    public var account: String
    public var repo: RepoRef
    public var number: Int
    public var job: Job
    /// The History record whose sessions ran here.
    public var recordID: UUID
    public var location: WorktreeLocation
    /// That record's sessions (spec T.1): what "Terminal" offers, without reading History on every render.
    public var sessions: [ClaudeSessionRef]
    public var retainedAt: Date
    /// A newer job replaced it but a process had its cwd inside (spec T.3.2): not offered, left for Clean Up.
    public var superseded: Bool

    public init(prID: String, account: String, repo: RepoRef, number: Int, job: Job, recordID: UUID,
                location: WorktreeLocation, sessions: [ClaudeSessionRef], retainedAt: Date, superseded: Bool = false) {
        self.prID = prID
        self.account = account
        self.repo = repo
        self.number = number
        self.job = job
        self.recordID = recordID
        self.location = location
        self.sessions = sessions
        self.retainedAt = retainedAt
        self.superseded = superseded
    }
}

/// `retained-worktrees.json` in Application Support: survives restarting PRBar.
public struct RetainedWorktreeStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = AppPaths.retainedWorktreesFile) {
        self.fileURL = fileURL
    }

    /// Empty if the file doesn't exist or can't be read (logged).
    public func load() -> [RetainedWorktree] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try JSONCoding.decoder.decode([RetainedWorktree].self, from: Data(contentsOf: fileURL))
        } catch {
            AppLog.write("Retained worktrees: couldn't read \(fileURL.lastPathComponent): \(error)")
            return []
        }
    }

    public func save(_ entries: [RetainedWorktree]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(entries).write(to: fileURL, options: .atomic)
    }
}

/// The retention rules (spec T.3), without side effects.
public enum RetainedWorktreeRules {
    /// How often PRBar asks GitHub whether a PR that left the list was merged or closed.
    public static let stateCheckInterval: TimeInterval = 3600

    /// `entry` becomes the kept folder of its (PR, job); the previous ones of that pair come back to be removed.
    public static func retain(_ entry: RetainedWorktree, in entries: [RetainedWorktree])
        -> (entries: [RetainedWorktree], replaced: [RetainedWorktree]) {
        let isSamePair: (RetainedWorktree) -> Bool = { $0.prID == entry.prID && $0.job == entry.job }
        let replaced = entries.filter { isSamePair($0) && $0.location.directory != entry.location.directory }
        let kept = entries.filter { !isSamePair($0) }
        return (kept + [entry], replaced)
    }

    /// The entries whose PR isn't in the list any more, whose repo was fetched fine in this refresh and that weren't
    /// asked about in the last `stateCheckInterval`: GitHub has to say whether they were merged or closed.
    public static func needsStateCheck(_ entries: [RetainedWorktree], listed: Set<String>, fetchedScopes: Set<String>,
                                       checkedAt: [String: Date], now: Date) -> [RetainedWorktree] {
        entries.filter { entry in
            guard !listed.contains(entry.prID),
                  fetchedScopes.contains(Snapshot.scope(account: entry.account, repo: entry.repo)) else { return false }
            guard let last = checkedAt[entry.prID] else { return true }
            return now.timeIntervalSince(last) >= stateCheckInterval
        }
    }

    /// The entries of merged or closed PRs (spec T.3.1). An unknown state keeps the folder.
    public static func closedOnes(_ entries: [RetainedWorktree], states: [String: PRDetails.State]) -> [RetainedWorktree] {
        entries.filter { [.merged, .closed].contains(states[$0.prID]) }
    }
}

/// Which processes have their working directory inside a folder (`lsof -d cwd -Fn`, spec T.3.2).
public enum ProcessCwd {
    public static let lsofPath = "/usr/sbin/lsof"
    public static let lsofArguments = ["-n", "-P", "-w", "-d", "cwd", "-Fn"]
    /// On a runner: exit 97 when there is no `lsof` (then the folder counts as busy).
    public static let remoteScript = "command -v lsof >/dev/null 2>&1 || exit 97\nlsof -n -P -w -d cwd -Fn 2>/dev/null\nexit 0"

    /// Some `n<path>` line of the output is one of `directories` or inside one of them.
    public static func anyInside(_ directories: [String], lsofOutput: String) -> Bool {
        let roots = directories.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty }
        return lsofOutput.split(whereSeparator: \.isNewline).contains { line in
            guard line.hasPrefix("n") else { return false }
            let path = String(line.dropFirst())
            return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }
}

/// Removes kept folders unless a process has its cwd inside (those come back marked `superseded`).
public struct RetainedWorktreeCleaner: Sendable {
    let isBusy: @Sendable (WorktreeLocation) async -> Bool
    let remove: @Sendable (RetainedWorktree) async -> Void

    public init(isBusy: @escaping @Sendable (WorktreeLocation) async -> Bool,
                remove: @escaping @Sendable (RetainedWorktree) async -> Void) {
        self.isBusy = isBusy
        self.remove = remove
    }

    /// Returns the ones left on disk, with `superseded` set.
    public func removeUnlessBusy(_ entries: [RetainedWorktree]) async -> [RetainedWorktree] {
        var left: [RetainedWorktree] = []
        for entry in entries {
            if await isBusy(entry.location) {
                var kept = entry
                kept.superseded = true
                left.append(kept)
                AppLog.write("Retained worktree: a process is working in \(entry.location.directory); left for Clean Up.")
            } else {
                await remove(entry)
            }
        }
        return left
    }
}
```

- [ ] **Step 5: `WorktreeManager`.** In `Sources/PRBarCore/WorktreeManager.swift`:

Add after `cleanup(_:localPath:)`:

```swift
    /// The review's folder stays for "Open in Terminal" (spec T.3): its context folder goes, the worktree and its refs
    /// stay, and it stops counting as in use (Activity and Clean Up see it). Never throws.
    public func release(_ workspace: ReviewWorkspace) {
        if isDirectChildOfRoot(workspace.contextDirectory) { removeItem(workspace.contextDirectory) }
        WorkspaceRegistry.shared.remove(workspace.directory.path)
        WorkspaceRegistry.shared.remove(workspace.contextDirectory.path)
    }
```

Change `cleanupOrphans(localPaths:)` to take the kept folders:

```swift
    public func cleanupOrphans(localPaths: [String], keeping kept: Set<String> = []) async {
        let keptPaths = Set(kept.map(CanonicalPath.of))
        let isKept: (URL) -> Bool = { keptPaths.contains(CanonicalPath.of($0.path)) }
```

and in its body: replace `.filter { isDirectChildOfRoot($0) && Self.isWorkspaceName($0.lastPathComponent) }` with `.filter { isDirectChildOfRoot($0) && Self.isWorkspaceName($0.lastPathComponent) && !isKept($0) }`, and replace `for entry in entries where Self.isWorkspaceName(entry.lastPathComponent) {` with `for entry in entries where Self.isWorkspaceName(entry.lastPathComponent) && !isKept(entry) {`. (As implemented, a kept review worktree keeps its two refs too — `WorktreeManager.reviewRefs(forWorkspaceName:)` derives them from the folder name — because Clean Up's unpushed-work check counts `refs/prbar/*` as safe: without them a fork PR's commits would look unpushed forever. `keeping:` is a required argument on the three `cleanupOrphans`, and `WorktreeManager.cleanupOrphans` also leaves, with its refs, any worktree with uncommitted changes or unpushed commits (logged), like `WorktreeResolver.cleanupOrphans`.)

- [ ] **Step 6: `WorktreeResolver`.** In `Sources/PRBarCore/WorktreeResolver.swift`, change the signature of `cleanupOrphans` to:

```swift
    public func cleanupOrphans(localPath: String, worktreeDir: String?, keeping kept: Set<String> = []) async {
        let keptPaths = Set(kept.map(CanonicalPath.of))
```

and right after the `guard parent == realBase, … else { continue }` line add:

```swift
                // Kept for "Open in Terminal" (spec T.3): it goes when its PR is merged or closed, or with Clean Up.
                if keptPaths.contains(CanonicalPath.of(path)) { continue }
```

- [ ] **Step 7: `RemoteWorkspaces`.** In `Sources/PRBarCore/RemoteWorkspaces.swift`:

Add after `cleanup(_:localPath:)`:

```swift
    /// The review's folder stays on the host for "Open in Terminal" (spec T.3): only its context folder goes.
    public func release(_ workspace: ReviewWorkspace) async {
        try? await host.removeTree(workspace.contextDirectory.path, root: root)
    }
```

Change the signature of `cleanupOrphans` to `public func cleanupOrphans(olderThan age: TimeInterval = 12 * 3600, keeping kept: Set<String> = []) async {` and, right after the `for line in … workScript …` loop that fills `stale` and `present`, add:

```swift
        // Kept for "Open in Terminal" (spec T.3): never stale, however old.
        stale.subtract(kept)
```

- [ ] **Step 8: `ReviewPipeline` releases instead of cleaning up on success.** In `Sources/PRBarCore/ReviewPipeline.swift`:

Add two members to `Parts`:

```swift
        /// Success (spec T.3): the folder stays, without its context.
        let release: @Sendable (ReviewWorkspace) async -> Void
        let location: @Sendable (ReviewWorkspace) -> WorktreeLocation
```

In the local `Parts(…)` add, after `cleanup:`:

```swift
                release: { workspace in worktrees.release(workspace) },
                location: { workspace in
                    WorktreeLocation(directory: workspace.directory.path, runner: nil,
                                     repository: workspace.isDiffOnly ? nil : request.localPath,
                                     refs: [workspace.prRef, workspace.baseRef].compactMap { $0 })
                },
```

In the remote `Parts(…)` add, after `cleanup:`:

```swift
            release: { workspace in await spaces.release(workspace) },
            location: { workspace in
                WorktreeLocation(directory: workspace.directory.path, runner: remote.name, repository: bare,
                                 refs: [workspace.prRef, workspace.baseRef].compactMap { $0 })
            },
```

In `run(_:onPhase:)` replace:

```swift
            await Self.cleanup(workspace, parts, after: nil)
            try Task.checkCancellation()
```

with:

```swift
            await parts.release(workspace)
            if Task.isCancelled {
                await Self.cleanup(workspace, parts, after: nil)
                throw CancellationError()
            }
```

and after `draft.sessions = sessions()` add:

```swift
            draft.retainedLocation = parts.location(workspace)
```

- [ ] **Step 9: Clean Up checks kept review folders.** In `Sources/PRBarCore/DiskCleanup.swift`, in `DiskCleanupExecutor`:

Add the property after `repos`:

```swift
    /// Folders kept for "Open in Terminal" (spec T.3), canonical: never removed with uncommitted or unpushed work.
    let retained: Set<String>
```

Change the `init` signature to add `retained: [String] = [],` right after `repos: [DiskScanInput.RespondDir],` and set `self.retained = Set(retained.map(CanonicalPath.of))` in its body.

In `run(_:)`, case `.workspace`, inside `if let clone = listed?[path] {`, before creating the `WorktreeManager`, add:

```swift
                    if retained.contains(path), let reason = await unpushedWork(url) {
                        result.skipped.append("\(candidate.title): \(reason)")
                        continue
                    }
```

- [ ] **Step 10: `RespondQueue.onRetain`.** In `Sources/PRBarCore/RespondQueue.swift`:

Add the property after `onEvent`:

```swift
    /// A push finished (spec T.3): the worktree is kept for "Open in Terminal" instead of deleted. `nil` = delete it.
    private let onRetain: (@MainActor (RespondRecord) -> Void)?
```

Replace the `init` with:

```swift
    public init(pipeline: RespondPipelineRunning, history: RespondHistory = RespondHistory(), maxConcurrent: Int = 2,
                onEvent: @escaping @MainActor (String, RespondPhase) -> Void,
                onRetain: (@MainActor (RespondRecord) -> Void)? = nil) {
        self.pipeline = pipeline
        self.history = history
        self.scheduler = JobScheduler(maxConcurrent: maxConcurrent)
        self.onEvent = onEvent
        self.onRetain = onRetain
    }
```

In `startPublish`, `case .success:` replace `self.cleanupWorktree(record.draft)` with:

```swift
                if record.pushed, let onRetain = self.onRetain {
                    onRetain(record)
                } else {
                    self.cleanupWorktree(record.draft)
                }
```

- [ ] **Step 11: Run the tests**

Run: `swift run PRBarTests "carpetas conservadas"`, `swift run PRBarTests "cleanup:"`, `swift run PRBarTests "review pipeline"`, `swift run PRBarTests "remote flow"`, `swift run PRBarTests "respond queue"`, `swift run PRBarTests "worktree"`
Expected: all pass.

- [ ] **Step 12: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources/PRBarCore Sources/PRBarTests
git -C /Users/federico/Documents/PRBar-wt-term commit -m "Keep review and pushed-fix folders for Claude sessions"
```

---

### Task 6: `ClaudeSessionCommand` (local and ssh)

**Files:**
- Modify: `Sources/PRBarCore/SSHCommand.swift`
- Create: `Sources/PRBarCore/ClaudeSessionCommand.swift`
- Create: `Sources/PRBarTests/ClaudeSessionCommandTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Write the failing tests.** Create `Sources/PRBarTests/ClaudeSessionCommandTests.swift`:

```swift
import Foundation
import PRBarCore

private let id = "0D5B2F4E-8C1A-4E3B-9F6D-2A7C1B3E4F50"

private func session(_ directory: String, id: String = id, runner: String? = nil) -> ClaudeSessionRef {
    ClaudeSessionRef(id: id, label: "Review · stage 1", kind: .review, directory: directory, runner: runner, startedAt: t0)
}

enum ClaudeSessionCommandTests {
    static let cases: [TestCase] = [
        TestCase("session command: esta Mac, con espacios y comillas en la carpeta y en claude") {
            let command = try ClaudeSessionCommand.local(session: session("/Users/me/PR Bar/it's"), claudePath: "/opt/claude code/claude")
            try expectEqual(command, #"cd '/Users/me/PR Bar/it'\''s' && '/opt/claude code/claude' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50"#)
        },
        TestCase("session command: un ID que no es UUID se rechaza") {
            let error = try await expectThrows {
                _ = try ClaudeSessionCommand.local(session: session("/wt", id: "abc; rm -rf ~"), claudePath: "/usr/local/bin/claude")
            }
            try expectEqual(error as? ClaudeSessionCommand.Failure, .invalidSessionID("abc; rm -rf ~"))
        },
        TestCase("session command: runner, ssh -t con las opciones de conexión de PRBar y el comando entre comillas") {
            let devbox = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(user: "fede", host: "devbox.local", port: 2222))
            let command = try ClaudeSessionCommand.remote(session: session("/srv/prbar/work/api 7", runner: "devbox"),
                                                          destination: devbox, claudePath: "/home/fede/.local/bin/claude")
            let inner = "cd '/srv/prbar/work/api 7' && '/home/fede/.local/bin/claude' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50"
            let arguments = SSHCommandBuilder.interactiveArguments(devbox, remoteCommand: inner)
            try expectEqual(command, try ShellQuote.command(["/usr/bin/ssh"] + arguments))
            try expectEqual(Array(arguments.suffix(4)), ["-t", "--", "devbox.local", inner])
            try expect(arguments.contains("-p") && arguments.contains("2222") && arguments.contains("-l") && arguments.contains("fede"))
            try expect(!arguments.contains("BatchMode=yes") && !arguments.contains("RequestTTY=no"), "\(arguments)")
            try expect(arguments.contains("ForwardAgent=no") && arguments.contains("RemoteCommand=none"), "\(arguments)")
        },
    ]
}
```

Register in `Sources/PRBarTests/main.swift`: `+ ClaudeSessionCommandTests.cases`.

- [ ] **Step 2: Run and see it fail**

Run: `swift run PRBarTests "session command"`
Expected: build error `cannot find 'ClaudeSessionCommand' in scope`.

- [ ] **Step 3: Interactive ssh arguments.** In `Sources/PRBarCore/SSHCommand.swift`, inside `SSHCommandBuilder`, after `arguments(_:controlDirectory:enforceHostKey:remoteCommand:)`:

```swift
    /// The connection options of `fixedOptions` that also make sense for a person at a terminal (spec T.5): no agent,
    /// X11, forwardings, local commands, sent variables or `RemoteCommand`. Without `BatchMode` (ssh may ask for a
    /// passphrase or a new host key) and with a TTY.
    public static let interactiveOptions = [
        "ConnectTimeout=10", "ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes", "PermitLocalCommand=no",
        "ServerAliveInterval=15", "ServerAliveCountMax=4", "LogLevel=ERROR", "SendEnv=-*", "Tunnel=no",
        "SessionType=default", "ForkAfterAuthentication=no", "StdinNull=no", "RemoteCommand=none",
    ]

    /// `ssh -t` for Claude's session on a runner: `remoteCommand` is **one** argument, run by the login shell.
    public static func interactiveArguments(_ destination: RunnerDestination, remoteCommand: String) -> [String] {
        var args: [String] = []
        for option in interactiveOptions { args += ["-o", option] }
        args += target(destination)
        args += ["-t", "--", destination.endpoint.host, remoteCommand]
        return args
    }
```

- [ ] **Step 4: Create `Sources/PRBarCore/ClaudeSessionCommand.swift`:**

```swift
import Foundation

/// The shell command that resumes a Claude session where it ran (spec T.5). Every value goes in single quotes
/// (`ShellQuote`) and the id must be a UUID: nothing from a record is interpolated as shell.
public enum ClaudeSessionCommand {
    public enum Failure: Error, Equatable, LocalizedError {
        case invalidSessionID(String)

        public var errorDescription: String? {
            switch self {
            case .invalidSessionID: "This Claude session can’t be resumed: its id isn’t valid."
            }
        }
    }

    /// `cd '<folder>' && '<claude>' --resume <uuid>` (`claudePath`: Settings › Tools).
    public static func local(session: ClaudeSessionRef, claudePath: String) throws -> String {
        "cd \(try ShellQuote.posix(session.directory)) && \(try ShellQuote.posix(claudePath)) --resume \(try validID(session))"
    }

    /// `ssh … -t -- <host> "cd '<folder>' && '<claude>' --resume <uuid>"`, quoted as one line for a shell
    /// (`claudePath`: the runner's claude, from its check).
    public static func remote(session: ClaudeSessionRef, destination: RunnerDestination, claudePath: String,
                              sshPath: String = OpenSSHVersion.systemPath) throws -> String {
        let inner = "cd \(try ShellQuote.posix(session.directory)) && \(try ShellQuote.posix(claudePath)) --resume \(try validID(session))"
        return try ShellQuote.command([sshPath] + SSHCommandBuilder.interactiveArguments(destination, remoteCommand: inner))
    }

    /// The id, lowercased, if it is a UUID.
    static func validID(_ session: ClaudeSessionRef) throws -> String {
        guard ClaudeSessionRef.isValidID(session.id), let uuid = UUID(uuidString: session.id) else {
            throw Failure.invalidSessionID(session.id)
        }
        return uuid.uuidString.lowercased()
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift run PRBarTests "session command"` and `swift run PRBarTests "ssh"`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources/PRBarCore/SSHCommand.swift Sources/PRBarCore/ClaudeSessionCommand.swift Sources/PRBarTests/ClaudeSessionCommandTests.swift Sources/PRBarTests/main.swift
git -C /Users/federico/Documents/PRBar-wt-term commit -m "Quoted claude --resume command, local and over ssh"
```

---

### Task 7: `TerminalLauncher` and `TerminalOpener`

**Files:**
- Modify: `Sources/PRBarWire/AppCommandTypes.swift`
- Create: `Sources/PRBarCore/TerminalLauncher.swift`
- Create: `Sources/PRBarTests/TerminalLauncherTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Write the failing tests.** Create `Sources/PRBarTests/TerminalLauncherTests.swift`:

```swift
import Foundation
import PRBarCore

private let request = TerminalRequest(command: "'/usr/local/bin/claude' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50",
                                      directory: "/tmp/PR Bar/it's", title: "o/r#7 · Review · stage 1")

enum TerminalLauncherTests {
    static let cases: [TestCase] = [
        TestCase("terminal: Terminal, iTerm, Warp y Ghostty abren un .command con open -a") {
            let script = try TerminalLauncher.script(request)
            try expectEqual(script, "#!/bin/zsh\ncd '/tmp/PR Bar/it'\\''s' && '/usr/local/bin/claude' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50\nexec /bin/zsh -l\n")
            for (choice, app) in [(TerminalChoice.terminal, "Terminal"), (.iterm, "iTerm"), (.warp, "Warp"), (.ghostty, "Ghostty")] {
                try expectEqual(try TerminalLauncher.plan(request, choice: choice, customCommand: nil), .commandFile(app: app, script: script))
            }
            var noFolder = request
            noFolder.directory = nil
            try expectEqual(try TerminalLauncher.script(noFolder),
                            "#!/bin/zsh\n'/usr/local/bin/claude' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50\nexec /bin/zsh -l\n")
        },
        TestCase("terminal: Orca usa su CLI con la carpeta como worktree; sin carpeta no se puede") {
            try expectEqual(try TerminalLauncher.plan(request, choice: .orca, customCommand: nil), .orca(arguments: [
                "terminal", "create", "--worktree", "path:/tmp/PR Bar/it's", "--title", "o/r#7 · Review · stage 1",
                "--command", request.command, "--focus", "--json",
            ]))
            var noFolder = request
            noFolder.directory = nil
            let error = try await expectThrows { _ = try TerminalLauncher.plan(noFolder, choice: .orca, customCommand: nil) }
            try expectEqual(error as? TerminalLaunchError, .notInOrca)
        },
        TestCase("terminal: lo que contesta Orca") {
            try expectEqual(TerminalLauncher.orcaOutcome(stdout: #"{"id":"x","ok":true,"result":{}}"#, status: 0), nil)
            let notFound = #"{"id":"x","ok":false,"error":{"code":"selector_not_found","message":"selector_not_found"}}"#
            try expectEqual(TerminalLauncher.orcaOutcome(stdout: notFound, status: 1), .notInOrca)
            try expectEqual(TerminalLauncher.orcaOutcome(stdout: #"{"ok":false,"error":{"code":"boom","message":"No runtime"}}"#, status: 1),
                            .failed("No runtime"))
            try expectEqual(TerminalLauncher.orcaOutcome(stdout: "", status: 2), .failed("orca exited with status 2"))
            try expectEqual(TerminalLaunchError.notInOrca.errorDescription,
                            "This folder isn’t in Orca. Add the repo in Orca or choose another terminal.")
        },
        TestCase("terminal: Custom reemplaza {dir} y {command} ya entre comillas") {
            let template = "open -na Ghostty --args --working-directory={dir} -e /bin/zsh -lc {command}"
            try expectEqual(try TerminalLauncher.plan(request, choice: .custom, customCommand: template), .shell(command:
                #"open -na Ghostty --args --working-directory='/tmp/PR Bar/it'\''s' -e /bin/zsh -lc ''\''/usr/local/bin/claude'\'' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50'"#))
            let none = try await expectThrows { _ = try TerminalLauncher.plan(request, choice: .custom, customCommand: "  ") }
            try expectEqual(none as? TerminalLaunchError, .noCustomCommand)
            let noPlaceholder = try await expectThrows { _ = try TerminalLauncher.plan(request, choice: .custom, customCommand: "open -a Terminal {dir}") }
            try expectEqual(noPlaceholder as? TerminalLaunchError, .customCommandWithoutPlaceholder)
        },
        TestCase("terminal: el opener escribe el .command 755, lo abre con open -a y borra los de más de un día") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let old = dir.appendingPathComponent("prbar-session-old.command")
            let fresh = dir.appendingPathComponent("prbar-session-fresh.command")
            try Data("x".utf8).write(to: old)
            try Data("x".utf8).write(to: fresh)
            try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
            try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-3600)], ofItemAtPath: fresh.path)
            let runner = FakeProcessRunner { _, _ in ok("") }
            let opener = TerminalOpener(runner: runner, directory: dir, now: { t0 }, isExecutable: { _ in false })
            try await opener.open(request, choice: .iterm, customCommand: nil)
            try expectEqual(runner.calls.count, 1)
            try expectEqual(runner.calls[0].executable, "/usr/bin/open")
            try expectEqual(Array(runner.calls[0].arguments.prefix(2)), ["-a", "iTerm"])
            let file = try expectSome(runner.calls[0].arguments.last)
            try expectEqual(try String(contentsOfFile: file, encoding: .utf8), try TerminalLauncher.script(request))
            let mode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
            try expectEqual(mode, 0o755)
            try expect(!FileManager.default.fileExists(atPath: old.path))
            try expect(FileManager.default.fileExists(atPath: fresh.path))
        },
        TestCase("terminal: Orca sin su binario no está instalado; con ok:false avisa") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let missing = TerminalOpener(runner: FakeProcessRunner { _, _ in ok("") }, directory: dir, now: { t0 }, isExecutable: { _ in false })
            let error = try await expectThrows { try await missing.open(request, choice: .orca, customCommand: nil) }
            try expectEqual(error as? TerminalLaunchError, .notInstalled("Orca"))
            let orca = FakeProcessRunner { _, _ in ProcessResult(status: 1, stdout: #"{"ok":false,"error":{"code":"selector_not_found"}}"#, stderr: "") }
            let opener = TerminalOpener(runner: orca, directory: dir, now: { t0 }, isExecutable: { $0 == TerminalOpener.orcaCandidates[0] })
            let notInOrca = try await expectThrows { try await opener.open(request, choice: .orca, customCommand: nil) }
            try expectEqual(notInOrca as? TerminalLaunchError, .notInOrca)
            try expectEqual(orca.calls.first?.executable, TerminalOpener.orcaCandidates[0])
        },
    ]
}
```

Register in `Sources/PRBarTests/main.swift`: `+ TerminalLauncherTests.cases`.

- [ ] **Step 2: Run and see it fail**

Run: `swift run PRBarTests "terminal:"`
Expected: build errors (`TerminalRequest`, `TerminalChoice`, `TerminalLauncher`, `TerminalOpener` not found).

- [ ] **Step 3: `TerminalChoice`.** In `Sources/PRBarWire/AppCommandTypes.swift`, after `SettingsTabName`:

```swift
/// Where "Terminal" opens Claude's session of a PR (Settings › General, spec T.6).
public enum TerminalChoice: String, Codable, CaseIterable, Sendable {
    case terminal, iterm, warp, ghostty, orca, custom

    public var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .warp: "Warp"
        case .ghostty: "Ghostty"
        case .orca: "Orca"
        case .custom: "Custom"
        }
    }
}
```

- [ ] **Step 4: Create `Sources/PRBarCore/TerminalLauncher.swift`:**

```swift
import Foundation

/// What to open: a shell command (already quoted), the folder on this Mac it belongs to and a title.
public struct TerminalRequest: Equatable, Sendable {
    public var command: String
    /// Where the terminal starts (`cd`), Orca's worktree and `{dir}`. For a runner's session, the repo's local folder;
    /// nil if it has none.
    public var directory: String?
    public var title: String

    public init(command: String, directory: String?, title: String) {
        self.command = command
        self.directory = directory
        self.title = title
    }
}

/// How each terminal opens it (spec T.5, verified 2026-11-24).
public enum TerminalPlan: Equatable, Sendable {
    /// An executable `.command` script opened with `open -a <app>`.
    case commandFile(app: String, script: String)
    /// `orca <arguments>`.
    case orca(arguments: [String])
    /// `/bin/sh -c <command>` (Custom).
    case shell(command: String)
}

public enum TerminalLaunchError: Error, Equatable, LocalizedError {
    case notInstalled(String)
    case noCustomCommand
    case customCommandWithoutPlaceholder
    case notInOrca
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "\(name) isn’t installed. Choose another terminal in Settings › General."
        case .noCustomCommand: "There’s no custom terminal command. Set one in Settings › General."
        case .customCommandWithoutPlaceholder: "The custom terminal command needs {command}: it’s where Claude runs."
        case .notInOrca: "This folder isn’t in Orca. Add the repo in Orca or choose another terminal."
        case .failed(let message): "The terminal couldn’t open Claude’s session: \(message)"
        }
    }
}

/// The plans, without side effects (`TerminalOpener` runs them).
public enum TerminalLauncher {
    /// Installed = an app with this bundle id (Terminal always is; Custom has none).
    public static let bundleIDs: [TerminalChoice: String] = [
        .terminal: "com.apple.Terminal", .iterm: "com.googlecode.iterm2", .warp: "dev.warp.Warp-Stable",
        .ghostty: "com.mitchellh.ghostty", .orca: "com.stablyai.orca",
    ]

    /// The name `open -a` takes, for the terminals that open a `.command` file.
    public static func appName(_ choice: TerminalChoice) -> String? {
        switch choice {
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .warp: "Warp"
        case .ghostty: "Ghostty"
        case .orca, .custom: nil
        }
    }

    /// `#!/bin/zsh`, `cd '<folder>' && <command>`, then a login shell so the window stays open after Claude.
    public static func script(_ request: TerminalRequest) throws -> String {
        let run = try request.directory.map { "cd \(try ShellQuote.posix($0)) && \(request.command)" } ?? request.command
        return "#!/bin/zsh\n\(run)\nexec /bin/zsh -l\n"
    }

    public static func plan(_ request: TerminalRequest, choice: TerminalChoice, customCommand: String?) throws -> TerminalPlan {
        if let app = appName(choice) { return .commandFile(app: app, script: try script(request)) }
        switch choice {
        case .orca:
            return .orca(arguments: try orcaArguments(request))
        case .custom:
            guard let template = customCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty else {
                throw TerminalLaunchError.noCustomCommand
            }
            return .shell(command: try expand(template, request))
        case .terminal, .iterm, .warp, .ghostty:
            throw TerminalLaunchError.failed("unknown terminal")   // `appName` covers them.
        }
    }

    /// `terminal create --worktree path:<folder> --title <title> --command <command> --focus --json` (verified with
    /// Orca: only a worktree of a repo added in Orca works).
    public static func orcaArguments(_ request: TerminalRequest) throws -> [String] {
        guard let directory = request.directory else { throw TerminalLaunchError.notInOrca }
        return ["terminal", "create", "--worktree", "path:\(directory)", "--title", request.title,
                "--command", request.command, "--focus", "--json"]
    }

    /// `{dir}` and `{command}`, each as one single-quoted word. Without `{command}` Claude wouldn't run.
    public static func expand(_ template: String, _ request: TerminalRequest) throws -> String {
        guard template.contains("{command}") else { throw TerminalLaunchError.customCommandWithoutPlaceholder }
        let directory = try ShellQuote.posix(request.directory ?? NSHomeDirectory())
        let command = try ShellQuote.posix(request.command)
        return template.replacingOccurrences(of: "{dir}", with: directory).replacingOccurrences(of: "{command}", with: command)
    }

    /// nil = Orca opened it (`"ok": true`).
    public static func orcaOutcome(stdout: String, status: Int32) -> TerminalLaunchError? {
        guard let data = stdout.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return status == 0 ? nil : .failed(stdout.isEmpty ? "orca exited with status \(status)" : stdout)
        }
        if object["ok"] as? Bool == true { return nil }
        let error = object["error"] as? [String: Any]
        if (error?["code"] as? String) == "selector_not_found" { return .notInOrca }
        return .failed((error?["message"] as? String) ?? "orca exited with status \(status)")
    }
}

/// Runs a `TerminalPlan`: writes the `.command` file (Application Support `terminal/`, 755) and opens it, runs Orca's
/// CLI or the custom command.
public struct TerminalOpener: Sendable {
    /// Where Orca's CLI may be (`/Applications/Orca.app` ships it; it can also be linked on the PATH).
    public static let orcaCandidates = ["/Applications/Orca.app/Contents/Resources/bin/orca", "/opt/homebrew/bin/orca",
                                        "/usr/local/bin/orca"]
    /// `.command` files older than this are deleted at each opening.
    public static let commandFileLifetime: TimeInterval = 86_400

    let runner: ProcessRunning
    let directory: URL
    let now: @Sendable () -> Date
    let isExecutable: @Sendable (String) -> Bool

    public init(runner: ProcessRunning, directory: URL = AppPaths.terminalDir, now: @escaping @Sendable () -> Date = { Date() },
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.runner = runner
        self.directory = directory
        self.now = now
        self.isExecutable = isExecutable
    }

    public func open(_ request: TerminalRequest, choice: TerminalChoice, customCommand: String?) async throws {
        switch try TerminalLauncher.plan(request, choice: choice, customCommand: customCommand) {
        case .commandFile(let app, let script):
            let file = try writeCommandFile(script)
            let result = try await runner.run("/usr/bin/open", ["-a", app, file.path], environment: nil, currentDirectory: nil, timeout: 30)
            guard result.status == 0 else { throw TerminalLaunchError.failed(Self.message(result)) }
        case .orca(let arguments):
            guard let orca = Self.orcaCandidates.first(where: isExecutable) else { throw TerminalLaunchError.notInstalled("Orca") }
            let result = try await runner.run(orca, arguments, environment: nil, currentDirectory: nil, timeout: 30)
            if let error = TerminalLauncher.orcaOutcome(stdout: result.stdout, status: result.status) { throw error }
        case .shell(let command):
            let result = try await runner.run("/bin/sh", ["-c", command], environment: nil, currentDirectory: nil, timeout: 30)
            guard result.status == 0 else { throw TerminalLaunchError.failed(Self.message(result)) }
        }
    }

    func writeCommandFile(_ script: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.prune(directory, now: now())
        let file = directory.appendingPathComponent("prbar-session-\(UUID().uuidString.lowercased()).command")
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// Deletes the `.command` files modified more than `commandFileLifetime` ago.
    static func prune(_ directory: URL, now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "command" {
            guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(date) > commandFileLifetime else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func message(_ result: ProcessResult) -> String {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "exit status \(result.status)" : text
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift run PRBarTests "terminal:"`
Expected: 6/6 passed.

- [ ] **Step 6: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources/PRBarWire/AppCommandTypes.swift Sources/PRBarCore/TerminalLauncher.swift Sources/PRBarTests/TerminalLauncherTests.swift Sources/PRBarTests/main.swift
git -C /Users/federico/Documents/PRBar-wt-term commit -m "TerminalLauncher: command files, Orca and custom command"
```

---

### Task 8: Config fields and `prbar config set terminal|terminal-command`

**Files:**
- Modify: `Sources/PRBarCore/Config.swift`
- Modify: `Sources/PRBarWire/AppCommand.swift`
- Modify: `Sources/PRBarCore/CommandActions.swift`
- Modify: `Sources/PRBarCore/CommandDispatcher.swift`
- Modify: `Sources/PRBarRemoteKit/RemotePolicy.swift`
- Modify: `Sources/PRBarRemoteFixtures/FixtureActions.swift`
- Modify: `Sources/PRBarCLIKit/ConfigCommands.swift`
- Modify: `Sources/PRBarCLIKit/CLIRouter.swift`
- Create: `Sources/PRBar/AppModel+Sessions.swift`
- Test: `Sources/PRBarTests/ConfigTests.swift`, `Sources/PRBarTests/AppCommandTests.swift`, `Sources/PRBarTests/CommandDispatcherTests.swift`, `Sources/PRBarTests/CLIParsingTests.swift`, `Sources/PRBarTests/FakeActions.swift`

- [ ] **Step 1: Write the failing tests.**

Append to `ConfigTests.cases`:

```swift
        TestCase("config: la terminal es Terminal por defecto; un comando propio vacío no se guarda") {
            let old = try JSONCoding.decoder.decode(AppConfig.self, from: Data(#"{"launchAtLogin": true}"#.utf8))
            try expectEqual(old.terminal, .terminal)
            try expectEqual(old.terminalCommand, nil)
            let unknown = try JSONCoding.decoder.decode(AppConfig.self, from: Data(#"{"terminal": "kitty"}"#.utf8))
            try expectEqual(unknown.terminal, .terminal)
            var config = AppConfig()
            config.setTerminal(.custom)
            config.setTerminalCommand("open -na Ghostty --args -e /bin/zsh -lc {command}")
            let back = try JSONCoding.decoder.decode(AppConfig.self, from: JSONCoding.encoder.encode(config))
            try expectEqual(back.terminal, .custom)
            try expectEqual(back.terminalCommand, "open -na Ghostty --args -e /bin/zsh -lc {command}")
            config.setTerminalCommand("   ")
            try expectEqual(config.terminalCommand, nil)
        },
```

In `Sources/PRBarTests/AppCommandTests.swift`, add to the round-trip `commands` array (next to `.setDiskWarning(gigabytes: 5),`):

```swift
                .setTerminal(terminal: .orca), .setTerminalCommand(command: "open -a Terminal {dir} {command}"),
```

In `Sources/PRBarTests/CommandDispatcherTests.swift`, add to `dispatchSamples` (after `(.setDiskWarning(gigabytes: 5), "setDiskWarning"),`):

```swift
    (.setTerminal(terminal: .warp), "setTerminal"),
    (.setTerminalCommand(command: "x {command}"), "setTerminalCommand"),
```

In `Sources/PRBarTests/CLIParsingTests.swift`, in `"cli parse: resources, cleanup y disk-warning"`, after the disk-warning lines add:

```swift
                try expectEqual(try parsed(["config", "set", "terminal", "iterm"]), .setTerminal(terminal: .iterm))
                try expectEqual(try parsed(["config", "set", "terminal", "custom"]), .setTerminal(terminal: .custom))
                try expect(rejects(["config", "set", "terminal", "kitty"]))
                try expectEqual(try parsed(["config", "set", "terminal-command", "open -na Ghostty --args -e /bin/zsh -lc {command}"]),
                                .setTerminalCommand(command: "open -na Ghostty --args -e /bin/zsh -lc {command}"))
```

In `Sources/PRBarTests/FakeActions.swift`, after `func configSetDiskWarning…`:

```swift
    func configSetTerminal(_ terminal: TerminalChoice) throws { try record("setTerminal \(terminal.rawValue)") }
    func configSetTerminalCommand(_ command: String) throws { try record("setTerminalCommand \(command)") }
```

- [ ] **Step 2: Run and see them fail**

Run: `swift run PRBarTests "config:"`
Expected: build errors (`AppConfig` has no member `terminal`, `AppCommand` has no member `setTerminal`).

- [ ] **Step 3: `AppConfig`.** In `Sources/PRBarCore/Config.swift`, in `AppConfig`:

Add after `remote`:

```swift
    /// Where "Terminal" opens Claude's session of a PR (Settings › General, spec T.6).
    public var terminal: TerminalChoice = .terminal
    /// Only for `custom`: `{dir}` is the PR's folder, `{command}` runs Claude.
    public var terminalCommand: String?
```

Add `case terminal, terminalCommand` to `CodingKeys` (after `case alwaysShowInDock`), and at the end of `init(from:)`:

```swift
        terminal = (try? c.decodeIfPresent(TerminalChoice.self, forKey: .terminal)) ?? .terminal
        terminalCommand = (try? c.decodeIfPresent(String.self, forKey: .terminalCommand)) ?? nil
```

In the extension `// MARK: - Mutaciones usadas por la UI de Configuración`, after `setTestCommand`:

```swift
    public mutating func setTerminal(_ choice: TerminalChoice) {
        terminal = choice
    }

    /// Vacío o solo espacios = nil.
    public mutating func setTerminalCommand(_ command: String?) {
        terminalCommand = Self.nonBlank(command)
    }
```

- [ ] **Step 4: `AppCommand`.** In `Sources/PRBarWire/AppCommand.swift`:

After `case setDiskWarning(gigabytes: Int?)` add:

```swift
    /// Settings › General › Terminal (spec T.6).
    case setTerminal(terminal: TerminalChoice)
    /// The Custom terminal's command, with `{dir}` and `{command}`.
    case setTerminalCommand(command: String)
```

In `Name`, after `case setAlwaysShowInDock` add `case setTerminal, setTerminalCommand`. In `name`, after `case .setDiskWarning: .setDiskWarning` add:

```swift
        case .setTerminal: .setTerminal
        case .setTerminalCommand: .setTerminalCommand
```

- [ ] **Step 5: Actions and dispatch.** In `Sources/PRBarCore/CommandActions.swift`, add to `ConfigActions` after `configSetAlwaysShowInDock`:

```swift
    func configSetTerminal(_ terminal: TerminalChoice) throws
    /// Fails if the command has no `{command}`.
    func configSetTerminalCommand(_ command: String) throws
```

In `Sources/PRBarCore/CommandDispatcher.swift`, after the `.setDiskWarning` case:

```swift
        case .setTerminal(let terminal):
            try actions.configSetTerminal(terminal)
            return .ok
        case .setTerminalCommand(let command):
            try actions.configSetTerminalCommand(command)
            return .ok
```

In `Sources/PRBarRemoteKit/RemotePolicy.swift`, in the `.denied` list add `.setTerminal, .setTerminalCommand,` right after `.setLaunchAtLogin, .setAlwaysShowInDock,`.

In `Sources/PRBarRemoteFixtures/FixtureActions.swift`, after `configSetDiskWarning`:

```swift
    public func configSetTerminal(_ terminal: TerminalChoice) throws {}
    public func configSetTerminalCommand(_ command: String) throws {}
```

- [ ] **Step 6: The app.** Create `Sources/PRBar/AppModel+Sessions.swift`:

```swift
import AppKit
import Foundation
import PRBarCore

/// Claude's sessions in a terminal (spec T): the kept folders, what "Terminal" offers and opening it.
extension AppModel {
    // MARK: Settings (spec T.6)

    func configSetTerminal(_ terminal: TerminalChoice) throws {
        try applyConfig { $0.setTerminal(terminal) }
    }

    func configSetTerminalCommand(_ command: String) throws {
        guard command.contains("{command}") else {
            throw CommandFailure(.invalidUsage, "The command needs {command}: it’s where Claude runs. {dir} is the PR’s folder.")
        }
        try applyConfig { $0.setTerminalCommand(command) }
    }
}
```

- [ ] **Step 7: The CLI.** In `Sources/PRBarCLIKit/ConfigCommands.swift`:

Add to `ConfigKey`:

```swift
    case terminal = "terminal"
    case terminalCommand = "terminal-command"
```

Replace `ConfigSet`'s `discussion:` with:

```swift
        discussion: "refresh-interval 1|2|5|10 (minutes) · launch-at-login on|off · always-show-in-dock on|off · update-interval 0|6|12|24|168 (hours; 0 = manual only) · disk-warning 1…100|off (GB) · terminal terminal|iterm|warp|ghostty|orca|custom · terminal-command \"<command with {dir} and {command}>\"")
```

Add to the `switch key` in `appCommand(confirmed:)`:

```swift
        case .terminal:
            guard let choice = TerminalChoice(rawValue: value) else {
                throw ValidationError("terminal takes terminal, iterm, warp, ghostty, orca or custom.")
            }
            return .setTerminal(terminal: choice)
        case .terminalCommand:
            return .setTerminalCommand(command: value)
```

In `Sources/PRBarCLIKit/CLIRouter.swift`, replace the `config set` row with:

```swift
        .init("config set", [.setRefreshInterval, .setLaunchAtLogin, .setUpdateInterval, .setDiskWarning, .setAlwaysShowInDock,
                             .setTerminal, .setTerminalCommand],
              ["config", "set", "refresh-interval", "2"], ["config", "set", "launch-at-login", "off"],
              ["config", "set", "always-show-in-dock", "on"],
              ["config", "set", "update-interval", "24"], ["config", "set", "disk-warning", "off"],
              ["config", "set", "terminal", "ghostty"], ["config", "set", "terminal-command", "open -a Terminal {command}"]),
```

- [ ] **Step 8: Run the tests**

Run: `swift run PRBarTests "config"`, `swift run PRBarTests "app command"`, `swift run PRBarTests "dispatcher"`, `swift run PRBarTests "cli parse"`, `swift run PRBarTests "remote policy"`, `swift run PRBarTests "paridad"` (CLI parity), `swift run PRBarTests "web vectors"`
Expected: all pass (`web vectors` still matches: the new names are denied, so the phone list is unchanged). `swift build --product PRBar` and `swift build --product PRBarCLI` succeed.

- [ ] **Step 9: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources
git -C /Users/federico/Documents/PRBar-wt-term commit -m "Terminal settings in config and prbar config set terminal"
```

---

### Task 9: Settings › General › Terminal picker

**Files:**
- Create: `Sources/PRBar/Settings/TerminalApps.swift`
- Modify: `Sources/PRBar/Settings/GeneralTab.swift`
- Modify: `Sources/PRBarTests/UIActionInventory.swift`

- [ ] **Step 1: Write the failing parity check.** Add to `UIActionInventory.entries`, after the `"Settings/GeneralTab.swift", "Stepper"` row:

```swift
        .init("Settings/GeneralTab.swift", "Picker", "Terminal", 1, .cli(["config set"])),   // terminal
        .init("Settings/GeneralTab.swift", "TextField", "Command", 1, .cli(["config set"])),   // terminal-command (Custom…)
```

- [ ] **Step 2: Run and see it fail**

Run: `swift run PRBarTests "paridad UI"`
Expected: FAIL listing `Settings/GeneralTab.swift|Picker|Terminal` and `Settings/GeneralTab.swift|TextField|Command` as inventoried but not found in the code (and, from Task 11 on, other pending entries).

- [ ] **Step 3: Create `Sources/PRBar/Settings/TerminalApps.swift`:**

```swift
import AppKit
import PRBarCore

/// The terminals installed on this Mac (by bundle id, spec T.6). Terminal is always there; Custom always offered.
@MainActor
enum TerminalApps {
    static func isInstalled(_ choice: TerminalChoice) -> Bool {
        switch choice {
        case .terminal, .custom: true
        case .iterm, .warp, .ghostty, .orca:
            TerminalLauncher.bundleIDs[choice].map { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } ?? false
        }
    }

    /// What the picker lists: the installed ones, Custom, and the saved one even if it was uninstalled (so it shows).
    static func offered(current: TerminalChoice) -> [TerminalChoice] {
        TerminalChoice.allCases.filter { isInstalled($0) || $0 == current }
    }

    static func menuTitle(_ choice: TerminalChoice) -> String {
        choice == .custom ? "Custom…" : choice.displayName
    }
}
```

- [ ] **Step 4: The section.** In `Sources/PRBar/Settings/GeneralTab.swift`, insert this `Section` right after the Tools section (before the Notifications one):

```swift
            Section {
                Picker("Terminal", selection: Binding(
                    get: { configStore.config.terminal },
                    set: { choice in model.updateConfig(refresh: false) { $0.setTerminal(choice) } }
                )) {
                    ForEach(TerminalApps.offered(current: configStore.config.terminal), id: \.self) { choice in
                        Text(TerminalApps.menuTitle(choice)).tag(choice)
                    }
                }
                if configStore.config.terminal == .custom {
                    TextField("Command", text: Binding(
                        get: { configStore.config.terminalCommand ?? "" },
                        set: { text in model.updateConfig(refresh: false) { $0.setTerminalCommand(text) } }
                    ), prompt: Text("open -na Ghostty --args -e /bin/zsh -lc {command}"))
                    // The same check `TerminalOpener` runs before launching (empty, no {command}, quoted placeholder).
                    if let problem = customCommandProblem(configStore.config.terminalCommand) {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Claude Sessions")
            } footer: {
                Text(configStore.config.terminal == .custom
                     ? "{dir} is the PR’s folder, {command} runs Claude. PRBar quotes both: don’t put them in quotes. PRBar runs the command in the background, so it should open the terminal and return."
                     : "Where the Terminal button opens Claude’s session of a PR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

and, in the same view:

```swift
    /// What `TerminalLauncher.validateCustomCommand` says about the Custom command (nil = fine).
    private func customCommandProblem(_ command: String?) -> String? {
        do {
            try TerminalLauncher.validateCustomCommand(command ?? "")
            return nil
        } catch {
            return error.localizedDescription
        }
    }
```

- [ ] **Step 5: Build and check parity for these two**

Run: `swift build --product PRBar` then `swift run PRBarTests "paridad UI"`
Expected: build succeeds; the two GeneralTab entries no longer appear in the failure (the test still fails only if other tasks' controls are pending; after this task alone it passes).

- [ ] **Step 6: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources/PRBar/Settings/TerminalApps.swift Sources/PRBar/Settings/GeneralTab.swift Sources/PRBarTests/UIActionInventory.swift
git -C /Users/federico/Documents/PRBar-wt-term commit -m "Settings: choose the terminal for Claude sessions"
```

---

### Task 10: `AppModel` — retention, offered sessions, busy check, opening

**Files:**
- Modify: `Sources/PRBarCore/ClaudeSessions.swift` (`SessionOffer`)
- Modify: `Sources/PRBar/AppModel.swift`
- Modify: `Sources/PRBar/AppModel+Sessions.swift`
- Modify: `Sources/PRBar/AppModel+Resources.swift`
- Modify: `Sources/PRBar/AppModel+Runners.swift`
- Modify: `Sources/PRBar/Snapshots/SnapshotMode.swift`
- Test: `Sources/PRBarTests/ClaudeSessionsTests.swift`

- [ ] **Step 1: Write the failing tests** for the pure part. Append to `ClaudeSessionsTests.cases`:

```swift
        TestCase("sesiones: se ofrecen las de las carpetas conservadas del PR, Review → Fixes → CI fix, en orden") {
            func ref(_ id: String, _ label: String, _ kind: ClaudeSessionRef.Kind, _ dir: String, _ minutes: Double) -> ClaudeSessionRef {
                ClaudeSessionRef(id: id, label: label, kind: kind, directory: dir, runner: nil, startedAt: t0.addingTimeInterval(minutes * 60))
            }
            let stage2 = ref("b", "Review · stage 2", .review, "/wt/review", 5)
            let stage1 = ref("a", "Review · stage 1", .review, "/wt/review", 1)
            let ci = ref("c", "CI fix", .ciFix, "/wt/respond", 20)
            let fix = ref("d", "Fix 1: x", .fix, "/wt/respond", 10)
            let elsewhere = ref("e", "Review · stage 1", .review, "/wt/other", 30)
            func entry(_ job: RetainedWorktree.Job, _ dir: String, _ sessions: [ClaudeSessionRef], prID: String = "o/r#7",
                       superseded: Bool = false) -> RetainedWorktree {
                RetainedWorktree(prID: prID, account: "me", repo: RepoRef(owner: "o", name: "r"), number: 7, job: job, recordID: UUID(),
                                 location: WorktreeLocation(directory: dir, runner: nil, repository: "/repos/r", refs: []),
                                 sessions: sessions, retainedAt: t0, superseded: superseded)
            }
            let retained = [entry(.respond, "/wt/respond", [ci, fix]), entry(.review, "/wt/review", [stage2, stage1, elsewhere]),
                            entry(.review, "/wt/old", [ref("f", "Review · stage 1", .review, "/wt/old", 0)], superseded: true),
                            entry(.review, "/wt/8", [ref("g", "Review · stage 1", .review, "/wt/8", 0)], prID: "o/r#8")]
            let offered = SessionOffer.offered(prID: "o/r#7", retained: retained)
            try expectEqual(offered.map(\.id), ["a", "b", "d", "c"])
            try expectEqual(SessionOffer.groups(offered).map(\.title), ["Review", "Fixes", "CI fix"])
            try expectEqual(SessionOffer.mostRecent(offered)?.id, "c")
            try expectEqual(SessionOffer.ofRecord(retained[1].recordID, retained: retained).map(\.id), ["a", "b"])
            try expectEqual(SessionOffer.ofRecord(retained[2].recordID, retained: retained), [])

            try expectEqual(try SessionOffer.pick(offered, job: nil, run: nil).id, "c")
            try expectEqual(try SessionOffer.pick(offered, job: .review, run: nil).id, "b")
            try expectEqual(try SessionOffer.pick(offered, job: nil, run: 1).id, "a")
            try expectEqual((try await expectThrows { _ = try SessionOffer.pick(offered, job: nil, run: 9) } as? CommandFailure)?.code, .notFound)
            try expectEqual((try await expectThrows { _ = try SessionOffer.pick([], job: nil, run: nil) } as? CommandFailure)?.code, .invalidState)
            try expectEqual((try await expectThrows { _ = try SessionOffer.pick(offered, job: .respond, run: 1) } as? CommandFailure)?.code, .invalidUsage)

            try expectEqual(SessionOffer.help(count: 0, busy: false, terminal: "iTerm"), "No Claude session for this PR yet")
            try expectEqual(SessionOffer.help(count: 2, busy: true, terminal: "iTerm"), "Claude is working on it")
            try expectEqual(SessionOffer.help(count: 1, busy: false, terminal: "iTerm"), "Open Claude’s session in iTerm")

            let info = SessionOffer.info(offered, busy: ["d"])
            try expectEqual(info.map(\.number), [1, 2, 3, 4])
            try expectEqual(info.map(\.kind), ["review", "review", "fix", "ci-fix"])
            try expectEqual(info.map(\.busy), [false, false, true, false])
            try expectEqual(Set(info.map(\.machine)), ["this Mac"])
        },
```

(`ClaudeSessionInfo` is added to `PRBarWire` in this task too, Step 3.)

- [ ] **Step 2: Run and see it fail**

Run: `swift run PRBarTests "sesiones: se ofrecen"`
Expected: build error `cannot find 'SessionOffer' in scope`.

- [ ] **Step 3: `ClaudeSessionInfo` and `SessionJob`.** In `Sources/PRBarWire/AppCommandTypes.swift`, after `TerminalChoice`:

```swift
/// `prbar session open --job` (spec T.4).
public enum SessionJob: String, Codable, CaseIterable, Sendable {
    case review, respond
    case ciFix = "ci-fix"
}
```

In `Sources/PRBarWire/CommandResults.swift`, at the end:

```swift
// MARK: - Sesiones de Claude (spec T.4)

/// One of the PR's Claude sessions PRBar offers (`prbar session list`).
public struct ClaudeSessionInfo: Codable, Equatable, Sendable {
    /// From 1, in the order of `prbar session list` (what `--run` takes).
    public var number: Int
    public var label: String
    /// `review`, `fix` or `ci-fix`.
    public var kind: String
    /// `this Mac` or the runner's name.
    public var machine: String
    public var directory: String
    public var startedAt: Date
    public var sessionID: String
    /// PRBar is running something in that folder: it can't be opened now.
    public var busy: Bool

    public init(number: Int, label: String, kind: String, machine: String, directory: String, startedAt: Date,
                sessionID: String, busy: Bool) {
        self.number = number
        self.label = label
        self.kind = kind
        self.machine = machine
        self.directory = directory
        self.startedAt = startedAt
        self.sessionID = sessionID
        self.busy = busy
    }
}
```

- [ ] **Step 4: `SessionOffer`.** Append to `Sources/PRBarCore/ClaudeSessions.swift`:

```swift
/// What "Terminal" offers (spec T.1/T.4), without side effects.
public enum SessionOffer {
    public struct Group: Equatable, Sendable, Identifiable {
        public let title: String
        public let sessions: [ClaudeSessionRef]
        public var id: String { title }
    }

    static let kindOrder: [ClaudeSessionRef.Kind] = [.review, .fix, .ciFix]

    /// The sessions of the PR's kept, current folders that ran in those folders: Review first, then Fixes, then
    /// CI fix, each in the order they ran.
    public static func offered(prID: String, retained: [RetainedWorktree]) -> [ClaudeSessionRef] {
        sorted(retained.filter { $0.prID == prID && !$0.superseded }.flatMap(sessions(of:)))
    }

    /// The sessions of one History record, if its folder is still kept.
    public static func ofRecord(_ recordID: UUID, retained: [RetainedWorktree]) -> [ClaudeSessionRef] {
        sorted(retained.filter { $0.recordID == recordID && !$0.superseded }.flatMap(sessions(of:)))
    }

    static func sessions(of entry: RetainedWorktree) -> [ClaudeSessionRef] {
        entry.sessions.filter { $0.directory == entry.location.directory }
    }

    static func sorted(_ sessions: [ClaudeSessionRef]) -> [ClaudeSessionRef] {
        sessions.sorted { a, b in
            let (ka, kb) = (kindOrder.firstIndex(of: a.kind) ?? 0, kindOrder.firstIndex(of: b.kind) ?? 0)
            return ka != kb ? ka < kb : a.startedAt < b.startedAt
        }
    }

    public static func groups(_ sessions: [ClaudeSessionRef]) -> [Group] {
        let titles: [ClaudeSessionRef.Kind: String] = [.review: "Review", .fix: "Fixes", .ciFix: "CI fix"]
        return kindOrder.compactMap { kind in
            let matching = sessions.filter { $0.kind == kind }
            return matching.isEmpty ? nil : Group(title: titles[kind] ?? kind.rawValue, sessions: matching)
        }
    }

    public static func mostRecent(_ sessions: [ClaudeSessionRef]) -> ClaudeSessionRef? {
        sessions.max { $0.startedAt < $1.startedAt }
    }

    /// `prbar session open`: `run` is the number of `prbar session list`; `job` alone takes its most recent; neither,
    /// the most recent of all.
    public static func pick(_ sessions: [ClaudeSessionRef], job: SessionJob?, run: Int?) throws -> ClaudeSessionRef {
        guard !sessions.isEmpty else { throw CommandFailure(.invalidState, "No Claude session for this PR yet.") }
        if let run {
            guard sessions.indices.contains(run - 1) else {
                throw CommandFailure(.notFound, "There’s no session \(run). See prbar session list.")
            }
            let session = sessions[run - 1]
            if let job, !matches(session, job) {
                throw CommandFailure(.invalidUsage, "Session \(run) isn’t from \(job.rawValue).")
            }
            return session
        }
        let candidates = job.map { job in sessions.filter { matches($0, job) } } ?? sessions
        guard let session = mostRecent(candidates) else {
            throw CommandFailure(.invalidState, "No Claude session of \(job?.rawValue ?? "this PR") yet.")
        }
        return session
    }

    static func matches(_ session: ClaudeSessionRef, _ job: SessionJob) -> Bool {
        switch job {
        case .review: session.kind == .review
        case .respond: session.kind == .fix
        case .ciFix: session.kind == .ciFix
        }
    }

    /// The button's help (spec T.4).
    public static func help(count: Int, busy: Bool, terminal: String) -> String {
        if count == 0 { return "No Claude session for this PR yet" }
        if busy { return "Claude is working on it" }
        return "Open Claude’s session in \(terminal)"
    }

    /// `busy`: the ids of the sessions whose folder PRBar is working in.
    public static func info(_ sessions: [ClaudeSessionRef], busy: Set<String>) -> [ClaudeSessionInfo] {
        sessions.enumerated().map { index, session in
            let kind = switch session.kind {
            case .review: "review"
            case .fix: "fix"
            case .ciFix: "ci-fix"
            }
            return ClaudeSessionInfo(number: index + 1, label: session.label, kind: kind, machine: session.runner ?? "this Mac",
                                     directory: session.directory, startedAt: session.startedAt, sessionID: session.id,
                                     busy: busy.contains(session.id))
        }
    }
}
```

- [ ] **Step 5: Run the pure test**

Run: `swift run PRBarTests "sesiones:"`
Expected: 5/5 passed.

- [ ] **Step 6: Stored state in `AppModel`.** In `Sources/PRBar/AppModel.swift`:

In `AppModelServices`, after `remoteAccess`:

```swift
    /// `nil`: `retained-worktrees.json` in Application Support (spec T.3).
    var retainedWorktrees: RetainedWorktreeStore? = nil
```

In `AppModel`, next to `respondHistory`:

```swift
    /// The folders kept for "Open in Terminal" (spec T.3), saved in `retainedStore`.
    @Published private(set) var retainedWorktrees: [RetainedWorktree] = []
    let retainedStore: RetainedWorktreeStore
    /// The merged/closed check of kept folders in flight (one at a time).
    var retainedPrune: Task<Void, Never>?
    /// When each PR that left the list was last asked about (`RetainedWorktreeRules.stateCheckInterval`).
    var retainedCheckedAt: [String: Date] = [:]
```

In `init(services:startsServices:)`, next to where `respondHistory` is assigned:

```swift
        self.retainedStore = services.retainedWorktrees ?? RetainedWorktreeStore()
        self.retainedWorktrees = retainedStore.load()
```

Change the `respond` lazy var's `RespondQueue(…)` to pass `onRetain`:

```swift
    private(set) lazy var respond = RespondQueue(
        pipeline: respondPipeline ?? LiveRespondPipeline(
            runner: runner, tokens: accounts, api: api, history: respondHistory,
            context: { [weak self] account, repo in self?.jobContext(account: account, repo: repo) ?? .closed }
        ),
        history: respondHistory,
        onEvent: { [weak self] prID, phase in self?.respondEvent(prID: prID, phase: phase) },
        onRetain: { [weak self] record in self?.retainRespond(record) }
    )
```

In the `mergePruneObserver` sink, after `self?.updateMergeSessions(snapshot)` add:

```swift
            self?.pruneRetainedWorktrees(snapshot)
```

In `reviewFinished`, success branch, after building `record`:

```swift
            if let location = draft.retainedLocation {
                retain(RetainedWorktree(prID: item.id, account: item.account, repo: item.pr.repo, number: item.pr.number,
                                        job: .review, recordID: draft.id, location: location, sessions: draft.sessions,
                                        retainedAt: Date()))
            }
```

In `startOrphanCleanup()`, compute the kept local folders before the `Task.detached` and pass them:

```swift
        let kept = Set(retainedWorktrees.filter { $0.location.runner == nil }.map(\.location.directory))
        orphanCleanup = Task.detached(priority: .utility) {
            for (localPath, worktreeDir) in respondOrphans {
                await resolver.cleanupOrphans(localPath: localPath, worktreeDir: worktreeDir, keeping: kept)
            }
            // Después: borra las refs `refs/prbar/*` que queden y las carpetas de contexto (`*.respond-context`).
            await manager.cleanupOrphans(localPaths: localPaths, keeping: kept)
            await legacy.cleanupOrphans(localPaths: localPaths, keeping: kept)
        }
        retrySupersededRetained()
```

- [ ] **Step 7: Remote orphan cleanup keeps them.** In `Sources/PRBar/AppModel+Runners.swift`, in `startRemoteOrphanCleanup()`, before `Task.detached`:

```swift
        let retained = retainedWorktrees
```

and replace `await placement.workspaces.cleanupOrphans()` with:

```swift
                            let kept = Set(retained.filter { $0.location.runner == destination.name }.map(\.location.directory))
                            await placement.workspaces.cleanupOrphans(keeping: kept)
```

- [ ] **Step 8: Clean Up protects and forgets them.** In `Sources/PRBar/AppModel+Resources.swift`, in `cleanup(olderThanDays:confirmed:paths:)`, replace the `DiskCleanupExecutor(…)` with:

```swift
        let executor = DiskCleanupExecutor(runner: runner, gitPath: git,
                                           worktreeRoots: [AppPaths.worktreesDir, AppPaths.legacyWorktreesDir],
                                           repos: diskScanInput().respondDirs,
                                           retained: retainedWorktrees.filter { $0.location.runner == nil }.map(\.location.directory),
                                           isUpdateInProgress: { await MainActor.run { session.isInstalling } })
```

and after the `AppLog.write("Clean Up freed …")` line:

```swift
        let removed = Set(result.removed.map(CanonicalPath.of))
        forgetRetained(retainedWorktrees.filter { removed.contains(CanonicalPath.of($0.location.directory)) }, keeping: [])
```

- [ ] **Step 9: Snapshot mode.** In `Sources/PRBar/Snapshots/SnapshotMode.swift`, in the `AppModelServices(…)` call, replace the last argument line `usageLedger: ledger` with:

```swift
            usageLedger: ledger,
            // Nothing outside the snapshot folder (spec T.3's file included).
            retainedWorktrees: RetainedWorktreeStore(fileURL: dir.appendingPathComponent("retained-worktrees.json"))
```

(`remoteAccess` keeps its default; `retainedWorktrees` comes after it in `AppModelServices`, so the labeled argument order stays valid.)

- [ ] **Step 10: Retention, pruning, offering and opening.** Append to `Sources/PRBar/AppModel+Sessions.swift`, inside the `extension AppModel`:

```swift
    // MARK: Kept folders (spec T.3)

    /// `entry` becomes the kept folder of its (PR, job); the older one goes unless a process works inside.
    func retain(_ entry: RetainedWorktree) {
        let (entries, replaced) = RetainedWorktreeRules.retain(entry, in: retainedWorktrees)
        setRetained(entries)
        guard !replaced.isEmpty else { return }
        let cleaner = retainedCleaner()
        Task { [weak self] in
            let left = await cleaner.removeUnlessBusy(replaced)
            self?.forgetRetained(replaced, keeping: left)
        }
    }

    /// A pushed Respond or Fix CI (`RespondQueue.onRetain`). The queue already released it (`RespondPipelineRunning
    /// .release(draft:)`: no longer in use, Mac-side copy of a runner's fixes gone); dismissing it doesn't delete it.
    func retainRespond(_ record: RespondRecord) {
        let draft = record.draft
        let location = WorktreeLocation(directory: draft.worktree.path, runner: draft.runner, repository: draft.worktree.localPath,
                                        refs: draft.worktree.ref.map { [$0] } ?? [])
        retain(RetainedWorktree(prID: draft.prID, account: draft.account, repo: draft.repo, number: draft.number, job: .respond,
                                recordID: draft.id, location: location, sessions: record.sessions ?? [], retainedAt: Date()))
    }

    /// Drops `removed` from the list and puts back `left` (folders still on disk, marked superseded).
    func forgetRetained(_ removed: [RetainedWorktree], keeping left: [RetainedWorktree]) {
        let removedDirectories = Set(removed.map(\.location.directory))
        var entries = retainedWorktrees.filter { !removedDirectories.contains($0.location.directory) }
        for entry in left where !entries.contains(where: { $0.location.directory == entry.location.directory }) {
            entries.append(entry)
        }
        setRetained(entries)
    }

    private func setRetained(_ entries: [RetainedWorktree]) {
        retainedWorktrees = entries
        do {
            try retainedStore.save(entries)
        } catch {
            AppLog.write("Retained worktrees: couldn't save: \(error)")
        }
    }

    /// The PRs that left the list: GitHub says whether they were merged or closed (spec T.3.1), at most hourly per PR.
    func pruneRetainedWorktrees(_ snapshot: Snapshot) {
        guard retainedPrune == nil else { return }
        let now = Date()
        let due = RetainedWorktreeRules.needsStateCheck(retainedWorktrees, listed: Set(snapshot.items.map(\.id)),
                                                        fetchedScopes: snapshot.fetchedScopes, checkedAt: retainedCheckedAt, now: now)
        guard !due.isEmpty else { return }
        for entry in due { retainedCheckedAt[entry.prID] = now }
        let api = self.api
        let tokens = self.accounts
        let cleaner = retainedCleaner()
        retainedPrune = Task { [weak self] in
            var states: [String: PRDetails.State] = [:]
            for entry in due where states[entry.prID] == nil {
                guard let token = try? await tokens.token(for: entry.account),
                      let details = try? await api.pullRequestDetails(repo: entry.repo, number: entry.number, token: token),
                      let state = details.state else { continue }
                states[entry.prID] = state
            }
            let closed = RetainedWorktreeRules.closedOnes(due, states: states)
            let left = await cleaner.removeUnlessBusy(closed)
            self?.forgetRetained(closed, keeping: left)
            self?.retainedPrune = nil
        }
    }

    /// At launch: superseded folders whose process ended go now.
    func retrySupersededRetained() {
        let superseded = retainedWorktrees.filter(\.superseded)
        guard !superseded.isEmpty else { return }
        let cleaner = retainedCleaner()
        Task { [weak self] in
            let left = await cleaner.removeUnlessBusy(superseded)
            self?.forgetRetained(superseded, keeping: left)
        }
    }

    /// `lsof` on this Mac or on the runner; removal with the same mechanism as each job's own cleanup.
    func retainedCleaner() -> RetainedWorktreeCleaner {
        let runner = self.runner
        let git = tools.git
        let runners = self.runners
        let settings = configStore.config.runners
        return RetainedWorktreeCleaner(
            isBusy: { location in
                guard let name = location.runner else {
                    guard let result = try? await runner.run(ProcessCwd.lsofPath, ProcessCwd.lsofArguments, environment: nil,
                                                             currentDirectory: nil, timeout: 30) else { return true }
                    return ProcessCwd.anyInside([location.directory, CanonicalPath.of(location.directory)], lsofOutput: result.stdout)
                }
                guard let destination = settings.destination(named: name),
                      let placement = try? await runners.placement(for: destination),
                      let script = try? ProcessCwd.remoteScript(resolving: [location.directory]),
                      let result = try? await placement.host.runScript(script, timeout: 30),
                      result.status == 0 else { return true }
                return ProcessCwd.anyInside([location.directory], remoteOutput: result.stdout)
            },
            // Never lose work (T.3): a folder with uncommitted changes or unpushed commits stays, `superseded`, for
            // Clean Up (which skips it while the work is there). Diff-only folders aren't git worktrees.
            unpushedWork: { location in
                guard location.repository != nil else { return nil }
                guard let name = location.runner else {
                    guard let git else { return "couldn't be checked with git" }
                    return await WorktreeResolver(runner: runner, gitPath: git).unpushedWork(location.directory)
                }
                guard let destination = settings.destination(named: name),
                      let placement = try? await runners.placement(for: destination) else { return "\(name) isn’t reachable" }
                return await placement.workspaces.unpushedWork(location.directory)
            },
            remove: { entry in
                let location = entry.location
                if let name = location.runner {
                    guard let destination = settings.destination(named: name),
                          let placement = try? await runners.placement(for: destination) else {
                        AppLog.write("Retained worktree: \(name) isn’t reachable; \(location.directory) stays on it.")
                        return
                    }
                    switch entry.job {
                    case .review: await placement.workspaces.cleanup(location.reviewWorkspace, localPath: location.repository)
                    case .respond: await placement.workspaces.cleanupRespond(location.respondWorktree)
                    }
                    return
                }
                guard let git else { return }
                switch entry.job {
                case .review:
                    await WorktreeManager(runner: runner, gitPath: git).cleanup(location.reviewWorkspace, localPath: location.repository)
                case .respond:
                    await WorktreeResolver(runner: runner, gitPath: git).cleanup(location.respondWorktree)
                }
            })
    }

    // MARK: Sessions (spec T.1, T.4)

    /// What the PR's Terminal button offers.
    func offeredSessions(prID: String) -> [ClaudeSessionRef] {
        SessionOffer.offered(prID: prID, retained: retainedWorktrees)
    }

    /// PRBar is running something in that folder (a job, its tests or a chat turn): the button waits.
    func isSessionBusy(_ session: ClaudeSessionRef) -> Bool {
        if session.runner == nil, WorkspaceRegistry.shared.contains(session.directory) { return true }
        guard let record = respond.records.values.first(where: { $0.draft.worktree.path == session.directory }) else { return false }
        let prID = record.draft.prID
        return respond.phases[prID]?.isActive == true || respond.chatting.contains(prID) || respond.runningTests.contains(prID)
    }

    /// Opens `session` in Settings › General's terminal. Throws `CommandFailure` or `TerminalLaunchError`.
    func openClaudeSession(_ session: ClaudeSessionRef) async throws {
        guard !isSessionBusy(session) else {
            throw CommandFailure(.invalidState, "Claude is working on it: PRBar is running something in \(session.directory).")
        }
        let config = configStore.config
        guard TerminalApps.isInstalled(config.terminal) else { throw TerminalLaunchError.notInstalled(config.terminal.displayName) }
        let request = try await terminalRequest(for: session)
        try await TerminalOpener(runner: runner).open(request, choice: config.terminal, customCommand: config.terminalCommand)
    }

    private func terminalRequest(for session: ClaudeSessionRef) async throws -> TerminalRequest {
        let entry = retainedWorktrees.first { $0.sessions.contains(session) }
        let title = "\(entry?.prID ?? "PR") · \(session.label)"
        guard let runnerName = session.runner else {
            guard let claude = tools.claude else { throw PRBarError.toolNotFound("claude") }
            return TerminalRequest(command: try ClaudeSessionCommand.local(session: session, claudePath: claude),
                                   directory: session.directory, title: title)
        }
        guard let destination = configStore.config.runners.destination(named: runnerName) else {
            throw CommandFailure(.invalidState, "The runner \(runnerName) isn’t set up any more (Settings › Claude › Run On).")
        }
        let placement = try await runners.placement(for: destination)
        let command = try ClaudeSessionCommand.remote(session: session, destination: destination, claudePath: placement.claudePath)
        // On this Mac, the repo's local folder: where the terminal starts and Orca's worktree (spec T.5).
        let localFolder = entry.flatMap { localPath(account: $0.account, repo: $0.repo) }
        return TerminalRequest(command: command, directory: localFolder, title: title)
    }

    /// The buttons and the menu item: errors in an alert with "Open Settings" (spec T.5).
    func openClaudeSessionFromUI(_ session: ClaudeSessionRef) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await openClaudeSession(session)
            } catch {
                ConfirmAlert.present(title: "Couldn’t open Claude’s session", message: error.localizedDescription, action: "Open Settings") { [weak self] in
                    self?.openSettings(tab: .general)
                }
            }
        }
    }
```

- [ ] **Step 11: Build**

Run: `swift build --product PRBar`
Expected: success. Then `swift run PRBarTests "sesiones:"` and `swift run PRBarTests "cleanup:"` pass.

- [ ] **Step 12: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources
git -C /Users/federico/Documents/PRBar-wt-term commit -m "AppModel: keep folders, offer and open Claude sessions"
```

---

### Task 11: Toolbar Terminal button, Pull Request menu ⌥⌘T, History "Open in Terminal"

**Files:**
- Create: `Sources/PRBar/Main/SessionTerminalButton.swift`
- Modify: `Sources/PRBar/Main/PRDetailView.swift`
- Modify: `Sources/PRBar/Main/MainWindow.swift`
- Modify: `Sources/PRBar/Components/WindowCommands.swift`
- Modify: `Sources/PRBar/AppMenu.swift`
- Modify: `Sources/PRBarCore/KeyboardShortcutList.swift`
- Modify: `Sources/PRBar/Review/HistoryDetailView.swift`, `Sources/PRBar/Respond/RespondHistoryDetailView.swift`, `Sources/PRBar/Review/HistoryPane.swift`
- Test: `Sources/PRBarTests/KeyboardShortcutListTests.swift`

> **Busy state (from the Task 10 review).** `AppModel.isSessionBusy` asks `WorkspaceRegistry.contains` (a `realpath`/`stat`
> per call), and `WorkspaceRegistry` isn't observable. Views must not call it in `body` on every render, nor expect the
> view to refresh when it changes. Derive "busy" from published state (`respond.phases`, `respond.chatting`,
> `respond.runningTests`, `reviews.phases`) and/or recompute it on a short timer or when those publishers change,
> keeping the result in view state.

- [ ] **Step 1: Write the failing test.** In `Sources/PRBarTests/KeyboardShortcutListTests.swift`, add `"⌥⌘T"` to the `expected` list (after `"⌥⌘I"`).

- [ ] **Step 2: Run and see it fail**

Run: `swift run PRBarTests "atajos"`
Expected: FAIL `falta ⌥⌘T`.

- [ ] **Step 3: Shortcut list.** In `Sources/PRBarCore/KeyboardShortcutList.swift`, after the `⌥⌘I` row:

```swift
            Shortcut(keys: "⌥⌘T", action: "Open Claude's session of the PR in your terminal"),
```

- [ ] **Step 4: Create `Sources/PRBar/Main/SessionTerminalButton.swift`:**

```swift
import PRBarCore
import SwiftUI

/// "Terminal" (spec T.4): Claude's session of the PR in the terminal of Settings › General. One session: a button;
/// several: a menu grouped as Review / Fixes / CI fix; none, or PRBar working in that folder: disabled, saying why.
/// History uses it as "Open in Terminal" with one record's sessions.
struct SessionTerminalButton: View {
    @ObservedObject var model: AppModel
    let sessions: [ClaudeSessionRef]
    var title = "Terminal"

    var body: some View {
        let busy = sessions.contains { model.isSessionBusy($0) }
        Group {
            if sessions.count > 1 {
                Menu {
                    ForEach(SessionOffer.groups(sessions)) { group in
                        Section(group.title) {
                            ForEach(group.sessions) { session in
                                Button(session.label) { model.openClaudeSessionFromUI(session) }
                            }
                        }
                    }
                } label: {
                    Label(title, systemImage: "terminal")
                }
            } else {
                Button(title, systemImage: "terminal") { if let session = sessions.first { model.openClaudeSessionFromUI(session) } }
            }
        }
        .disabled(sessions.isEmpty || busy)
        .help(SessionOffer.help(count: sessions.count, busy: busy, terminal: model.configStore.config.terminal.displayName))
    }
}
```

- [ ] **Step 5: Toolbar.** In `Sources/PRBar/Main/PRDetailView.swift`:

In `PRDetailToolbar`, add:

```swift
    /// To the left of Chat (spec T.4).
    static func terminalButton(model: AppModel, prID: String) -> some View {
        SessionTerminalButton(model: model, sessions: model.offeredSessions(prID: prID))
    }
```

In `content`'s `.toolbar { if ownsToolbar { … } }`, after the `.principal` item and before the chat item:

```swift
                        ToolbarItem(placement: .primaryAction) {
                            PRDetailToolbar.terminalButton(model: model, prID: prID)
                        }
```

In `PRDetailCommands.body`, after the `.windowCommand(.undoClaude, …) { … }` modifier:

```swift
            // Pull Request › Open Claude Session in Terminal (⌥⌘T): the most recent one (spec T.4).
            .windowCommand(.openClaudeSession, enabled: sessionToOpen != nil) {
                if let session = sessionToOpen { model.openClaudeSessionFromUI(session) }
            }
```

and add to `PRDetailCommands`:

```swift
    /// The most recent offered session, if PRBar isn't working in its folder.
    private var sessionToOpen: ClaudeSessionRef? {
        guard let latest = SessionOffer.mostRecent(model.offeredSessions(prID: prID)), !model.isSessionBusy(latest) else { return nil }
        return latest
    }
```

In `Sources/PRBar/Main/MainWindow.swift`, replace:

```swift
            if selectedTabs != nil && model.chatEnabled {
                PRDetailToolbar.chatButton(detail: detail)
            }
```

with:

```swift
            if let prID = selectedTabs?.0 {
                PRDetailToolbar.terminalButton(model: model, prID: prID)
            }
            if selectedTabs != nil && model.chatEnabled {
                PRDetailToolbar.chatButton(detail: detail)
            }
```

- [ ] **Step 6: Menu item.** In `Sources/PRBar/Components/WindowCommands.swift`:

Add to `WindowCommand`:

```swift
    /// ⌥⌘T: Claude's most recent session of the PR in the terminal (spec T.4).
    case openClaudeSession
```

Add to `WindowCommandCenter`, after `stopClaude(_:)`:

```swift
    @objc func openClaudeSession(_ sender: Any?) { perform(.openClaudeSession) }
```

and in `validateMenuItem`, after the `stopClaude` case:

```swift
        case #selector(openClaudeSession(_:)): return handler(.openClaudeSession)?.enabled ?? false
```

In `Sources/PRBar/AppMenu.swift`, in `pullRequestMenu()`, after the "Stop Claude" item:

```swift
        menu.addItem(item("Open Claude Session in Terminal", #selector(WindowCommandCenter.openClaudeSession(_:)), "t",
                          modifiers: [.command, .option], target: commands))
```

- [ ] **Step 7: History.** In `Sources/PRBar/Review/HistoryDetailView.swift`, add after `let reopen: () -> Void`:

```swift
    /// "Open in Terminal" (spec T.4): only when the record's folder is still kept.
    var terminal: SessionTerminalButton? = nil
```

and in `footer`, as the first line inside `HistoryDetailBar(logURL: logURL) {`:

```swift
            if let terminal { terminal }
```

In `Sources/PRBar/Respond/RespondHistoryDetailView.swift`, add after `let open: () -> Void`:

```swift
    /// "Open in Terminal" (spec T.4): only when the record's folder is still kept.
    var terminal: SessionTerminalButton? = nil
```

and in `footer`, as the first line inside `HistoryDetailBar(logURL: logURL) {`:

```swift
            if let terminal { terminal }
```

In `Sources/PRBar/Review/HistoryPane.swift`, change the two detail views to pass it:

```swift
            HistoryDetailView(
                record: record, canReopen: HistoryActions.canReopen(record, model: model, entries: entries.all),
                logURL: model.history.logURL(for: record.id),
                reopen: { model.reopenFromHistory(record.draft) },
                terminal: terminalButton(record.id)
            )
            .id(record.id)
        case .respond(let record)?:
            RespondHistoryDetailView(
                record: record, logURL: model.respondHistory.logURL(for: record.id),
                canOpen: HistoryActions.canOpen(record, respond: respond), open: { model.openRespond(prID: record.draft.prID) },
                terminal: terminalButton(record.id)
            )
            .id(record.id)
```

and add to that view (the struct whose `body` contains the `switch entries.entry(…)`):

```swift
    /// The record's sessions while its folder is kept; nil hides the button.
    private func terminalButton(_ recordID: UUID) -> SessionTerminalButton? {
        let sessions = SessionOffer.ofRecord(recordID, retained: model.retainedWorktrees)
        return sessions.isEmpty ? nil : SessionTerminalButton(model: model, sessions: sessions, title: "Open in Terminal")
    }
```

- [ ] **Step 8: Build and run**

Run: `swift build --product PRBar`, then `swift run PRBarTests "atajos"`
Expected: build succeeds; the shortcut test passes. (`paridad UI` now fails for the new controls until Task 14.)

- [ ] **Step 9: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources
git -C /Users/federico/Documents/PRBar-wt-term commit -m "Terminal button, Pull Request menu item and History Open in Terminal"
```

---

### Task 12: CLI `prbar session list|open`, IPC and docs

**Files:**
- Modify: `Sources/PRBarWire/AppCommand.swift`
- Modify: `Sources/PRBarCore/CommandActions.swift`
- Modify: `Sources/PRBarCore/CommandDispatcher.swift`
- Modify: `Sources/PRBarRemoteKit/RemotePolicy.swift`
- Modify: `Sources/PRBarRemoteFixtures/FixtureActions.swift`
- Create: `Sources/PRBarCLIKit/SessionCommands.swift`
- Modify: `Sources/PRBarCLIKit/PRBarCLIKit.swift`, `Sources/PRBarCLIKit/CLIRouter.swift`
- Modify: `Sources/PRBar/AppModel+Sessions.swift`
- Modify: `docs/cli.md`
- Test: `Sources/PRBarTests/FakeActions.swift`, `Sources/PRBarTests/AppCommandTests.swift`, `Sources/PRBarTests/CommandDispatcherTests.swift`, `Sources/PRBarTests/CLIParsingTests.swift`

- [ ] **Step 1: Write the failing tests.**

In `Sources/PRBarTests/AppCommandTests.swift`, add to the round-trip `commands` array:

```swift
                .sessionList(pr: "api#7"), .sessionOpen(pr: "api#7", job: .ciFix, run: 2), .sessionOpen(pr: "api#7", job: nil, run: nil),
```

In `Sources/PRBarTests/CommandDispatcherTests.swift`, add to `dispatchSamples`:

```swift
    (.sessionList(pr: "api#7"), "sessionList"),
    (.sessionOpen(pr: "api#7", job: .review, run: nil), "sessionOpen"),
```

and at the end of `arguments()`:

```swift
        _ = await run(.sessionOpen(pr: "api#7", job: .ciFix, run: 2), fake)
        try expectEqual(fake.calls.last, "sessionOpen api#7 ci-fix 2")
```

In `Sources/PRBarTests/CLIParsingTests.swift`, add a case to `CLIParsingTests.cases`:

```swift
            TestCase("cli parse: session list y open") {
                try expectEqual(try parsed(["session", "list", "api#7"]), .sessionList(pr: "api#7"))
                try expectEqual(try parsed(["session", "list", "api#7", "--json"]), .sessionList(pr: "api#7"))
                try expectEqual(try parsed(["session", "open", "api#7"]), .sessionOpen(pr: "api#7", job: nil, run: nil))
                try expectEqual(try parsed(["session", "open", "api#7", "--job", "ci-fix", "--run", "2"]),
                                .sessionOpen(pr: "api#7", job: .ciFix, run: 2))
                try expect(rejects(["session", "open", "api#7", "--job", "chat"]))
                try expect(rejects(["session", "open", "api#7", "--run", "0"]))
                try expect(rejects(["session", "list"]))
            },
```

In `Sources/PRBarTests/FakeActions.swift`, at the end of the file:

```swift
extension FakeActions: SessionActions {
    func sessionList(pr: String) throws -> [ClaudeSessionInfo] {
        try record("sessionList \(pr)")
        return []
    }

    func sessionOpen(pr: String, job: SessionJob?, run: Int?) async throws -> ClaudeSessionInfo {
        try record("sessionOpen \(pr) \(job?.rawValue ?? "-") \(run.map(String.init) ?? "-")")
        return ClaudeSessionInfo(number: 1, label: "Review · stage 1", kind: "review", machine: "this Mac", directory: "/wt/7",
                                 startedAt: t0, sessionID: "0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50", busy: false)
    }
}
```

- [ ] **Step 2: Run and see them fail**

Run: `swift run PRBarTests "session"`
Expected: build errors (`AppCommand` has no member `sessionList`; `SessionActions` not found).

- [ ] **Step 3: Commands.** In `Sources/PRBarWire/AppCommand.swift`, after the `// Recursos (spec I)` block's `case cleanup(…)`:

```swift
    // Sesiones de Claude en una terminal (spec T.4)
    /// The PR's sessions PRBar offers.
    case sessionList(pr: String)
    /// Opens one in the terminal of Settings: `run` = the number of `sessionList`; `job` = the most recent of that job;
    /// neither = the most recent.
    case sessionOpen(pr: String, job: SessionJob?, run: Int?)
```

In `Name` add `case sessionList, sessionOpen` (after `case setTerminal, setTerminalCommand`), and in `name`:

```swift
        case .sessionList: .sessionList
        case .sessionOpen: .sessionOpen
```

- [ ] **Step 4: Protocol and dispatch.** In `Sources/PRBarCore/CommandActions.swift`, before `PRBarActions`:

```swift
/// Claude's sessions in a terminal (spec T.4).
@MainActor
public protocol SessionActions: AnyObject {
    func sessionList(pr: String) throws -> [ClaudeSessionInfo]
    /// `invalidState` (exit 6) when there is none or PRBar is working in its folder.
    func sessionOpen(pr: String, job: SessionJob?, run: Int?) async throws -> ClaudeSessionInfo
}
```

and change the typealias to:

```swift
public typealias PRBarActions = StatusActions & ReviewActions & RespondActions & MergeActions & ConfigActions
    & SlackActions & ChatCommandActions & UpdateCommandActions & InstructionCommandActions & ResourceActions
    & RunnerActions & CIFixUsageActions & RemoteActions & SessionActions
```

In `Sources/PRBarCore/CommandDispatcher.swift`, after the `.setTerminalCommand` case:

```swift
        case .sessionList(let pr):
            return try encode(actions.sessionList(pr: pr))
        case .sessionOpen(let pr, let job, let run):
            return try encode(await actions.sessionOpen(pr: pr, job: job, run: run))
```

In `Sources/PRBarRemoteKit/RemotePolicy.swift`, add `.sessionList, .sessionOpen,` to the `.denied` list next to `.setTerminal, .setTerminalCommand,` with the comment `// Abre una terminal en la Mac (spec T.4).`

In `Sources/PRBarRemoteFixtures/FixtureActions.swift`, add:

```swift
    // MARK: SessionActions
    public func sessionList(pr: String) throws -> [ClaudeSessionInfo] { [] }
    public func sessionOpen(pr: String, job: SessionJob?, run: Int?) async throws -> ClaudeSessionInfo { throw missing("sessions") }
```

- [ ] **Step 5: App side.** Append to `Sources/PRBar/AppModel+Sessions.swift`:

```swift
// MARK: - SessionActions (CLI)

extension AppModel: SessionActions {
    func sessionList(pr: String) throws -> [ClaudeSessionInfo] {
        let id = try resolvePRID(pr)
        let sessions = offeredSessions(prID: id)
        return SessionOffer.info(sessions, busy: busyIDs(sessions))
    }

    func sessionOpen(pr: String, job: SessionJob?, run: Int?) async throws -> ClaudeSessionInfo {
        let id = try resolvePRID(pr)
        let sessions = offeredSessions(prID: id)
        let session = try SessionOffer.pick(sessions, job: job, run: run)
        do {
            try await openClaudeSession(session)
        } catch let failure as CommandFailure {
            throw failure
        } catch {
            throw CommandFailure(.failed, error.localizedDescription)
        }
        guard let info = SessionOffer.info(sessions, busy: busyIDs(sessions)).first(where: { $0.sessionID == session.id }) else {
            throw CommandFailure(.failed, "Opened, but the session isn’t listed any more.")
        }
        return info
    }

    private func busyIDs(_ sessions: [ClaudeSessionRef]) -> Set<String> {
        Set(sessions.filter { isSessionBusy($0) }.map(\.id))
    }
}
```

- [ ] **Step 6: CLI.** Create `Sources/PRBarCLIKit/SessionCommands.swift`:

```swift
import ArgumentParser
import Foundation
import PRBarCore

extension SessionJob: ExpressibleByArgument {}

/// `prbar session` (spec T.4): Claude's sessions of a PR, resumed in your terminal.
struct SessionGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session", abstract: "Claude’s sessions of a PR, resumed in your terminal.",
        discussion: "The sessions of the PR’s last review and of its last Respond or Fix CI (they share the branch’s folder) whose folder PRBar kept. They open with claude --resume in the terminal of Settings › General (prbar config set terminal).",
        subcommands: [SessionList.self, SessionOpen.self])
}

enum SessionRender {
    static func list(_ sessions: [ClaudeSessionInfo], _ output: Output) {
        guard !sessions.isEmpty else { return output.line("No Claude session for this PR yet.") }
        output.table(["#", "Session", "Kind", "Machine", "Folder", "Started"], sessions.map {
            ["\($0.number)", $0.label + ($0.busy ? " (Claude is working on it)" : ""), $0.kind, $0.machine, $0.directory,
             Render.date($0.startedAt)]
        })
    }
}

struct SessionList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The PR’s Claude sessions you can open.")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .sessionList(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { SessionRender.list(try result.decode(), output) }
}

struct SessionOpen: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open one in your terminal (without options, the most recent).",
        discussion: "Exit 6 if the PR has none or PRBar is working in its folder.")
    @Argument(help: prHelp) var pr: String
    @Option(help: "review, respond or ci-fix: that job’s most recent session.") var job: SessionJob?
    @Option(help: "The session’s number in prbar session list.") var run: Int?
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if let run, run < 1 { throw ValidationError("--run takes the session’s number in prbar session list (1 or more).") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .sessionOpen(pr: pr, job: job, run: run) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let session: ClaudeSessionInfo = try result.decode()
        output.line("Opened \(session.label) (\(session.machine)).")
    }
}
```

In `Sources/PRBarCLIKit/PRBarCLIKit.swift`, add `SessionGroup.self,` to `subcommands` after `ChatCommand.self,`.

In `Sources/PRBarCLIKit/CLIRouter.swift`, after the `chat` row:

```swift
        // Sesiones de Claude en una terminal (plan 22)
        .init("session list", [.sessionList], ["session", "list", "api#7"]),
        .init("session open", [.sessionOpen], ["session", "open", "api#7"], ["session", "open", "api#7", "--job", "ci-fix", "--run", "2"]),
```

- [ ] **Step 7: docs/cli.md.** In the Commands table, after the `prbar open …` row add:

```markdown
| `prbar session list <pr> [--json]` | Claude’s sessions of the PR you can open in a terminal: those of its last review (`Review · stage N`) and of its last Respond (`Fix N: <title>`) or Fix CI (`CI fix`) — they share the branch’s folder — whose folder PRBar kept, with their number, kind, machine (this Mac or the runner), folder and time. Marked “Claude is working on it” while PRBar runs something in that folder |
| `prbar session open <pr> [--job review\|respond\|ci-fix] [--run N]` | Resume one (`claude --resume`) in the terminal of Settings › General: `--run N` the number in `session list`, `--job` that job’s most recent, neither the most recent. Exit 6 if there’s none or PRBar is working in its folder; exit 1 with the terminal’s error if it couldn’t open |
```

and replace the `prbar config show` row with:

```markdown
| `prbar config show`, `prbar config set refresh-interval 1\|2\|5\|10`, `… launch-at-login on\|off`, `… always-show-in-dock on\|off` (keep the Dock icon without windows), `… update-interval 0\|6\|12\|24\|168` (hours; 0 = check manually only), `… disk-warning 1–100\|off` (GB; notify when PRBar uses more), `… terminal terminal\|iterm\|warp\|ghostty\|orca\|custom` (where Claude sessions open), `… terminal-command "<command>"` (Custom: `{dir}` is the PR’s folder, `{command}` runs Claude) | General |
```

- [ ] **Step 8: Run the tests**

Run: `swift run PRBarTests "session"`, `swift run PRBarTests "dispatcher"`, `swift run PRBarTests "app command"`, `swift run PRBarTests "cli parse"`, `swift run PRBarTests "paridad:"` (the CLI parity tests in `CLIParityTests.swift`), `swift run PRBarTests "remote policy"`, `swift run PRBarTests "web vectors"`
Expected: all pass. `swift build --product PRBarCLI` and `swift build --product PRBar` succeed.

- [ ] **Step 9: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources docs/cli.md
git -C /Users/federico/Documents/PRBar-wt-term commit -m "prbar session list and open"
```

---

### Task 13: RemotePolicy test and web sync

**Files:**
- Modify: `Sources/PRBarTests/RemotePolicyTests.swift`
- Modify: `web/src/protocol/commands.ts`

- [ ] **Step 1: Write the test.** Append to `RemotePolicyTests.cases`:

```swift
        TestCase("remote policy: las sesiones en una terminal y la elección de terminal no se ofrecen en el iPhone (spec T.4)") {
            for name in [AppCommand.Name.sessionList, .sessionOpen, .setTerminal, .setTerminalCommand] {
                try expect(RemotePolicy.classify(name) == .denied, "\(name)")
                try expect(!RemotePolicy.gatedNames.contains(name), "\(name)")
            }
            try expectEqual(RemotePolicy.decide(.sessionOpen(pr: "a/b#1", job: nil, run: nil)), .denied)
            try expectEqual(RemotePolicy.decide(.setTerminal(terminal: .iterm)), .denied)
        },
```

- [ ] **Step 2: Run it**

Run: `swift run PRBarTests "remote policy"`
Expected: pass (the classification was added in Tasks 8 and 12; this test pins it).

- [ ] **Step 3: Web.** The phone's command list (`PHONE_COMMANDS`, from `FIELDS`) and `GATED_NAMES`/`decidePolicy` only cover non-denied commands, so nothing changes in behavior. Pin it with a comment above `export const GATED_NAMES` in `web/src/protocol/commands.ts`:

```ts
// Mac-only (denied in RemotePolicy.swift, so never phone commands): sessionList, sessionOpen, setTerminal and
// setTerminalCommand open or choose a terminal on the Mac (spec T.4).
```

- [ ] **Step 4: Run the web unit tests**

Run: `cd /Users/federico/Documents/PRBar-wt-term/web && npx vitest run test/unit/protocol/commands.test.ts`
Expected: all pass. Also `swift run PRBarTests "web vectors"` passes.

- [ ] **Step 5: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources/PRBarTests/RemotePolicyTests.swift web/src/protocol/commands.ts
git -C /Users/federico/Documents/PRBar-wt-term commit -m "iPhone: Claude sessions in a terminal are Mac-only"
```

---

### Task 14: UI parity inventory

**Files:**
- Modify: `Sources/PRBarTests/UIActionInventory.swift`

- [ ] **Step 1: Run the parity test to see what is missing**

Run: `swift run PRBarTests "paridad UI"`
Expected: FAIL listing, as found in the code but not inventoried: `AppMenu.swift|MenuItem|Open Claude Session in Terminal`, `Main/SessionTerminalButton.swift|Button|terminal`, `Main/SessionTerminalButton.swift|Button|-`, `AppModel+Sessions.swift|ConfirmAlert|Couldn’t open Claude’s session`.

- [ ] **Step 2: Add the entries.** In `UIActionInventory.entries`:

After the `"AppMenu.swift", "MenuItem", "Stop Claude"` row:

```swift
        .init("AppMenu.swift", "MenuItem", "Open Claude Session in Terminal", 1, .cli(["session open"])),   // ⌥⌘T, the most recent
```

After the `"Main/PRDetailView.swift", "Button", "Open on GitHub"` row:

```swift
        // Terminal (toolbar) and History › Open in Terminal: one session is a button (labeled by its SF Symbol)…
        .init("Main/SessionTerminalButton.swift", "Button", "terminal", 1, .cli(["session open"])),
        // …several, a menu with one item per session (session list shows them).
        .init("Main/SessionTerminalButton.swift", "Button", "-", 1, .cli(["session open"])),
        .init("AppModel+Sessions.swift", "ConfirmAlert", "Couldn’t open Claude’s session", 1, .cli(["session open"])),   // "Open Settings"
```

If the failure message of Step 1 shows a different label or count for any of these keys (the scanner labels a control by the first string literal on its line), use exactly the key it prints.

- [ ] **Step 3: Run it**

Run: `swift run PRBarTests "paridad"`
Expected: all parity tests pass (UI and CLI).

- [ ] **Step 4: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add Sources/PRBarTests/UIActionInventory.swift
git -C /Users/federico/Documents/PRBar-wt-term commit -m "UI parity: Terminal button, menu item and History entry"
```

---

### Task 15: Manual QA checklist

**Files:**
- Create: `docs/qa/plan-22-checklist.md`

- [ ] **Step 1: Write the checklist**

```markdown
# Plan 22 — Claude session in a terminal: manual checklist

Build and install the branch (`Scripts/bundle.sh`, then open `build/PRBar.app`), with at least one repo that has a
local folder and, for the runner rows, a runner set up in Settings › Claude › Run On.

## Settings and config
- [ ] Settings › General › Claude Sessions › Terminal lists Terminal, the installed ones among iTerm, Warp, Ghostty and
      Orca, and Custom…; an uninstalled one isn't listed (unless it was the saved one).
- [ ] Custom… shows the Command field with the help "{dir} is the PR’s folder, {command} runs Claude. PRBar quotes both: don’t
      put them in quotes. PRBar runs the command in the background, so it should open the terminal and return."
- [ ] A Custom command with `"{command}"` or `'{dir}'` shows "Don’t put quotes around {dir} or {command}: PRBar quotes them."
      under the field, and the Terminal button shows the same alert.
- [ ] A Custom command that stays in the foreground (`/Applications/kitty.app/Contents/MacOS/kitty --directory {dir}
      /bin/zsh -lc {command}`, or `alacritty --working-directory {dir} -e /bin/zsh -lc {command}`) opens the session, and
      it is still alive more than 30 s later.
- [ ] `prbar config set terminal ghostty` changes the picker; `prbar config show` shows `"terminal": "ghostty"`.
- [ ] `prbar config set terminal-command "open -a Terminal"` fails (no `{command}`); with `{command}` it saves.
- [ ] An old `config.json` without these keys opens with Terminal.

## Review session
- [ ] Review a PR. When it finishes, the toolbar's Terminal button (left of Chat) is enabled; with the filter on there
      are two sessions: a menu with Review › Review · stage 1 / stage 2.
- [ ] For each installed terminal (Terminal, iTerm, Warp, Ghostty, Orca, Custom): choose it, open a review session.
      Claude Code opens interactive in the review's folder (`pwd` matches `prbar session list`), with the user's normal
      config (MCP, hooks, permissions), and the conversation continues where the review left it.
- [ ] After `/exit` the window stays open with a shell in the folder.
- [ ] Orca with a repo not added in Orca: alert "This folder isn’t in Orca. Add the repo in Orca or choose another
      terminal." with "Open Settings" (opens Settings › General).
- [ ] Orca with a repo whose local folder has a non-ASCII character (e.g. `~/Code/café`, added in Orca): the kept
      worktree under it opens in Orca (the `--worktree=path:…` selector matches; no "isn’t in Orca" alert).
- [ ] An uninstalled terminal saved in config (edit config.json): alert "<name> isn’t installed…".
- [ ] Publish the review: the folder is still there (`prbar session list <pr>` still lists the stages).
- [ ] Review the same PR again: the new review's sessions replace the old; the old folder is gone. Repeat with a
      `claude` (or `cd`) running inside the old folder: it stays (Activity shows it) and Clean Up removes it later.

## Fix sessions
- [ ] Respond to a PR of yours with two fixes, push. The Terminal menu shows Fixes › Fix 1: … and Fix 2: … (titles
      truncated to 50).
- [ ] Fix CI on a PR, push: the menu shows CI fix (and the Respond fixes are gone: same folder kind).
- [ ] While PRBar runs a new Respond/Fix CI on the PR (or tests, or a chat turn in that folder), the button is
      disabled with "Claude is working on it"; `prbar session open <pr>` exits 6.
- [ ] Commit and push from the terminal session in the kept folder: PRBar's next job on the PR uses a new folder and
      doesn't touch it.

## Runner
- [ ] With the repo set to run on a runner, review a PR. The session row says the runner's name (`prbar session list`).
- [ ] Open it in Terminal: `ssh -t` connects and `claude --resume` runs in the runner's folder.
- [ ] Open it in Orca: the terminal opens on the repo's local folder and runs the ssh command.

## Other entry points
- [ ] Pull Request › Open Claude Session in Terminal (⌥⌘T) opens the most recent session; disabled without sessions.
- [ ] Help › Keyboard Shortcuts lists ⌥⌘T.
- [ ] History › a review or Respond record with a kept folder shows Open in Terminal (a menu with several); an older
      record whose folder was replaced doesn't.
- [ ] `prbar session open <pr> --job review`, `--run 2`, `--job ci-fix` on a PR without Fix CI (exit 6).
- [ ] The iPhone app doesn't offer any of this; `sessionOpen` from the phone is denied.

## Cleanup
- [ ] Merge the PR: within a refresh or two (and at most an hour if it already left the list) the kept folders are
      gone, and `prbar session list` says "No Claude session for this PR yet.".
- [ ] Close a PR without merging: same.
- [ ] Leave uncommitted changes in a kept review folder of a merged PR whose removal was blocked by a process; Clean Up
      lists it as skipped ("has uncommitted changes").
- [ ] Restart PRBar: kept folders survive the startup orphan cleanup (also on the runner).
- [ ] Activity and `prbar resources` count kept folders under worktrees.
- [ ] `~/Library/Application Support/PRBar/terminal/` keeps no `.command` files older than a day after an opening.
```

- [ ] **Step 2: Commit**

```bash
git -C /Users/federico/Documents/PRBar-wt-term add docs/qa/plan-22-checklist.md
git -C /Users/federico/Documents/PRBar-wt-term commit -m "QA checklist for plan 22"
```

---

### Task 16: Full test run and snapshots

**Files:**
- Possibly modify: anything a failing test points at.

- [ ] **Step 1: Build every product**

Run: `swift build --product PRBar && swift build --product PRBarCLI && swift build --product PRBarTests`
Expected: no errors, no new warnings in the touched files.

- [ ] **Step 2: Run the whole suite** (10+ minutes)

Run: `swift run PRBarTests`
Expected: `N/N passed`. Fix any failure in the task it belongs to (re-read that task's code), commit the fix with a message naming it.

- [ ] **Step 3: Web unit tests**

Run: `cd /Users/federico/Documents/PRBar-wt-term/web && npm test`
Expected: pass.

- [ ] **Step 4: Snapshots.** The PR toolbar now has a (disabled) Terminal button and Settings › General a Claude Sessions section:

Run: `Scripts/snapshots.sh /tmp/prbar-plan22-snapshots light`
Expected: the PNGs render; check the PR window/main window toolbar (Terminal left of Chat, disabled with no sessions) and Settings › General. Only if the repo's `docs/screenshots` are kept in sync for these screens, regenerate them with `Scripts/snapshots.sh` (defaults) and commit:

```bash
git -C /Users/federico/Documents/PRBar-wt-term add docs/screenshots
git -C /Users/federico/Documents/PRBar-wt-term commit -m "Screenshots: Terminal button and terminal setting"
```

- [ ] **Step 5: Manual QA** with `docs/qa/plan-22-checklist.md`.

---

## Self-review

**Spec coverage**

| Spec | Where |
|---|---|
| Decisions 1–4 | Tasks 4–5 (sessions, kept folders), 7 (terminals), 10–12 (button, menu, CLI) |
| T.1 What is offered (last review and last Respond / Fix CI — one shared `respond` folder —, kept folder + id, labels, grouping, order) | Task 3 (labels, truncation to 50), Task 5 (one kept folder per (PR, review/respond); newer replaces), Task 10 (`SessionOffer.offered/groups/mostRecent`), Task 11 (menu) |
| T.2 Session id (`init` event, also on failure, `ClaudeSessionRef` fields, records, not for non-PR runs) | Task 2 (parser + `onSession`, failure test), Task 3 (`ClaudeSessionRef`, optional decoding), Task 4 (review stages, fixes, Fix CI, `ReviewFailure.sessions`); other runs (skills filter, runner checks, Instructions, chat) pass no `onSession`, so nothing is stored |
| T.3 Kept folders (retain on publish/push, `retained-worktrees.json`, merged/closed, replaced + lsof, Clean Up skips dirty/unpushed, Activity counts them, busy disables, new jobs use another folder) | Task 5 (store, rules, `ProcessCwd`, cleaner, release, orphan `keeping`, Clean Up `retained`, `onRetain`), Task 10 (wiring: retain, prune via GitHub state, superseded retry, Clean Up forget, `isSessionBusy`); Activity needs no change (released folders are no longer registered as in use, so the scanner counts them); new jobs already create new folders (`WorktreeManager.prepare`/`WorktreeResolver.prepare` use a new run id) |
| T.4 Toolbar button (left of Chat, one/several/none/busy, help texts), Pull Request menu ⌥⌘T, History, CLI list/open with exit 6, iPhone not offered | Task 10 (`SessionOffer.help`), Task 11 (button, menu, shortcut list, History), Task 12 (CLI + IPC + docs), Tasks 8/12/13 (RemotePolicy + web) |
| T.5 Command (local/ssh, quoting, UUID) and launcher (command file for Terminal/iTerm/Warp/Ghostty, Orca CLI + selector_not_found message, Custom, cleanup of `.command` files, errors → alert with Open Settings / CLI exit 1) | Task 1 (spec), Task 6, Task 7, Task 10 (`openClaudeSessionFromUI`), Task 12 (`CommandFailure(.failed)` → exit 1) |
| T.6 Settings picker (installed by bundle id, Terminal always, Custom… with help), config fields, old config → Terminal, `config set`, `config show` | Task 7 (`TerminalChoice`, bundle ids), Task 8 (config + CLI), Task 9 (picker) |
| T.7 Tests | ClaudeStream (Task 2), records (Task 3), kept folders incl. lsof and Clean Up (Task 5), ClaudeSessionCommand (Task 6), TerminalLauncher incl. Custom (Task 7), UI parity (Tasks 9, 14), manual checklist (Task 15) |

**Gaps found and fixed while writing**

- The review worktree is deleted as soon as Claude finishes (before publishing), so "retain on publish" was impossible as written: Task 5 retains it when the review succeeds and Task 1 records that in the spec (T.3 clarification).
- The startup orphan cleanups (local review/legacy roots, Respond worktrees and the runner's 12 h cleanup) would have deleted kept folders: `keeping:` parameters in Task 5, wired in Task 10.
- A released review folder would still be "in use" in `WorkspaceRegistry` (never in Activity's leftovers, never offered to Clean Up): `WorktreeManager.release` unregisters it.
- Clean Up deleted review worktrees without checking for work: `DiskCleanupExecutor(retained:)` adds the unpushed-work check for kept ones.
- New `AppCommand.Name` cases must be classified in `RemotePolicy` in the same task or the build breaks: done in Tasks 8 and 12, pinned by a test in Task 13.
- The runner's `claude` path isn't in `RespondDraft`: it is resolved when opening (`runners.placement(for:).claudePath`), so `ClaudeSessionRef` keeps exactly the spec's fields.
- Reading History on every render to offer sessions would be slow: `RetainedWorktree.sessions` carries them; History records still store them (spec T.2).
- A PR that leaves the list isn't necessarily merged/closed: GitHub is asked (`pullRequestDetails.state`), at most hourly per PR.
- Superseded (busy) folders stay listed as `superseded` so Clean Up still protects their work and they are retried at launch.
