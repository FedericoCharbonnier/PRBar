import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

/// Un servidor con `FakeActions` y la CLI conectándose a él por un socket temporal.
@MainActor
private final class Harness {
    let url: URL
    let fake = FakeActions()
    let server: CommandServer

    init(url: URL? = nil) throws {
        self.url = try url ?? (try shortSocketURL())
        let fake = self.fake
        server = CommandServer(socketURL: self.url, appVersion: "9.9.9") { command, events in
            await CommandDispatcher.run(command, on: fake, events: events)
        }
        try server.start()
    }
}

private final class Captured: @unchecked Sendable {
    var out = ""
    var err = ""
}

/// Corre `arguments` como la CLI (fuera del hilo principal: la CLI bloquea y el servidor usa el main actor).
/// Devuelve el exit code (0 si no lanzó) y lo que escribió.
private func runCLI(_ arguments: [String], socket: URL, interactive: Bool = false,
                    answer: Bool = true) async throws -> (code: Int32, out: String, err: String) {
    let captured = Captured()
    let code = try await Task.detached { () -> Int32 in
        let command = try PRBarCommand.parseAsRoot(arguments)
        guard let remote = command as? any RemoteCommand else { throw TestFailure(description: "no remoto") }
        let terminal = interactive ? Terminal(stdinIsTTY: true, stdoutIsTTY: true, colors: false) : .plain
        let environment = CLIEnvironment(terminal: terminal, out: { captured.out += $0 }, err: { captured.err += $0 },
                                         connect: { try AppConnection.connect(socketURL: socket) }, ask: { _ in answer })
        do {
            try run(remote, environment)
            return 0
        } catch let exit as ExitCode {
            return exit.rawValue
        }
    }.value
    return (code, captured.out, captured.err)
}

private func runInstall<C: RemoteCommand>(_ command: C, _ environment: CLIEnvironment, timeout: TimeInterval) throws {
    try UpdateInstallRunner.run(command, environment: environment, timeout: timeout, poll: 0.1)
}

/// Abre el existencial para llamar al genérico.
private func run<C: RemoteCommand>(_ command: C, _ environment: CLIEnvironment) throws {
    try CLIRunner.run(command, environment: environment)
}

enum CLIIntegrationTests {
    static let cases: [TestCase] = [
        TestCase("integración: --json por el socket real") { try await jsonStatus() },
        TestCase("integración: show con Now: mientras corre y activity en --json") { try await nowLine() },
        TestCase("integración: publicar sin --yes y sin terminal → exit 4, sin llamar a la app") { try await needsYes() },
        TestCase("integración: review show con anteriores y recomendación; publish --recommended la usa y sigue pidiendo --yes") {
            try await recommended()
        },
        TestCase("integración: con terminal pregunta; si dice que no → 130") { try await asks() },
        TestCase("integración: errores de la app → exit codes") { try await errors() },
        TestCase("integración: sin app → exit 3") { try await noApp() },
        TestCase("integración: merge sin --yes y sin terminal → exit 4; --dismiss no pregunta") { try await mergeNeedsYes() },
        TestCase("integración: cleanup solo borra lo que mostró (las rutas de la vista previa)") { try await cleanupOnlyShown() },
        TestCase("integración: update --check sale con 10 si hay versión nueva, también con --json") { try await updateCheckExit() },
        TestCase("integración: runners test sale con 1 si hay problemas, también con --json; list muestra el estado") { try await runnersTestExit() },
        TestCase("integración: update espera a la versión nueva solo si la app se estaba reiniciando") { try await updateRelaunch() },
        TestCase("integración: chat --json sin mensaje en una terminal no se queda leyendo la terminal") { try await chatJSONWithoutMessage() },
        TestCase("integración: prbar ci y prbar usage (Fix CI y costo estimado, specs K y O)") { try await ciAndUsage() },
        TestCase("integración: prbar session list y open (spec T.4); sin sesión o con PRBar trabajando → exit 6") { try await sessions() },
        TestCase("chat: el mensaje sale de stdin solo si no es una terminal; no vacío") {
            let tty = Terminal(stdinIsTTY: true, stdoutIsTTY: false, colors: false)
            let error = try await expectThrows { _ = try ChatInput.readMessage(terminal: tty) { "never read" } }
            try expectEqual((error as? CommandFailure)?.code, .invalidUsage)
            try expectEqual(try ChatInput.readMessage(terminal: .plain) { "hola\n" }, "hola\n")
            let empty = try await expectThrows { _ = try ChatInput.readMessage(terminal: .plain) { " \n" } }
            try expectEqual((empty as? CommandFailure)?.code, .invalidUsage)
        },
        TestCase("version: distingue la app que no corre de la que corre con otro protocolo") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let missing = VersionReport.versions(cli: "1.0.0") { try AppConnection.connect(socketURL: url) }
            try expectEqual(VersionReport.lines(missing).last, "PRBar.app isn’t running")
            let listening = try RawSocket.listen(url)
            defer { close(listening) }
            let fake = Thread {
                let peer = RawSocket(fd: accept(listening, nil, nil))
                _ = peer.readLine()
                peer.writeLine(try! CommandProtocol.line(CommandResponse.failure(id: 0, .protocolMismatch(cli: "1.0.0", app: "0.9.0"))))
                peer.close()
            }
            fake.start()
            let mismatch = await Task.detached {
                VersionReport.versions(cli: "1.0.0") { try AppConnection.connect(socketURL: url) }
            }.value
            try expectEqual(mismatch.app, nil)
            let line = VersionReport.lines(mismatch).last ?? ""
            try expect(line.contains("is running but") && line.contains("PRBar 0.9.0"), line)
            let running = VersionReport.Versions(cli: "1.0.0", app: "1.0.0", error: nil)
            try expectEqual(VersionReport.lines(running), ["prbar 1.0.0", "PRBar.app 1.0.0 (running)"])
        },
        TestCase("chat: “Undo anyway?” solo en una terminal y sin --json") {
            let tty = Terminal(stdinIsTTY: true, stdoutIsTTY: true, colors: false)
            try expect(ChatInput.asksUndoAnyway(terminal: tty, json: false))
            try expect(!ChatInput.asksUndoAnyway(terminal: tty, json: true))
            try expect(!ChatInput.asksUndoAnyway(terminal: .plain, json: false))
        },
    ]

    @MainActor
    private static func chatJSONWithoutMessage() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        for arguments in [["chat", "acme/api#1", "--json"], ["rules", "chat", "--json"]] {
            let result = try await runCLI(arguments, socket: harness.url, interactive: true)
            try expectEqual(result.code, CLIExit.usage)
            try expect(result.err.contains("Pass the message"), result.err)
        }
        try expect(!harness.fake.calls.contains { $0.hasPrefix("chatSend") || $0.hasPrefix("rulesChatSend") }, "\(harness.fake.calls)")
    }

    /// Corre `prbar update --yes` con `UpdateInstallRunner` (lo que hace `run()`), con plazos cortos.
    private static func runUpdate(socket: URL, timeout: TimeInterval) async throws -> (code: Int32, out: String, err: String) {
        let captured = Captured()
        let code = try await Task.detached { () -> Int32 in
            guard let command = try PRBarCommand.parseAsRoot(["update", "--yes"]) as? any RemoteCommand else {
                throw TestFailure(description: "no remoto")
            }
            let environment = CLIEnvironment(terminal: .plain, out: { captured.out += $0 }, err: { captured.err += $0 },
                                             connect: { try AppConnection.connect(socketURL: socket) }, ask: { _ in true })
            do {
                try runInstall(command, environment, timeout: timeout)
                return 0
            } catch let exit as ExitCode {
                return exit.rawValue
            }
        }.value
        return (code, captured.out, captured.err)
    }

    @MainActor
    private static func updateRelaunch() async throws {
        // La app manda "Restarting PRBar", se va y vuelve con otra versión → espera y lo dice.
        var harness = try Harness()
        harness.fake.updateInstallHangs = true
        harness.fake.waitEvents = [.progress(message: UpdatePhase.relaunching.title)]
        let url = harness.url
        defer { removeSocketDirectory(url) }
        async let relaunched = runUpdate(socket: url, timeout: 5)
        try await Task.sleep(for: .milliseconds(400))
        harness.server.stop()
        try await Task.sleep(for: .milliseconds(300))
        let newer = CommandServer(socketURL: url, appVersion: "9.9.10") { _, _ in .success(.null) }
        try newer.start()
        let result = try await relaunched
        newer.stop()
        try expectEqual(result.code, 0)
        try expect(result.out.contains("PRBar 9.9.10 is running"), result.out + result.err)
        // Spec G.6: after "Restarting PRBar" the lost connection isn't an error.
        try expect(!result.err.contains("Lost the connection"), result.err)
        try expect(result.err.contains(UpdatePhase.relaunching.title), result.err)

        // Vuelve la misma versión: no se dice que se actualizó.
        harness = try Harness(url: url)
        harness.fake.updateInstallHangs = true
        harness.fake.waitEvents = [.progress(message: UpdatePhase.relaunching.title)]
        async let same = runUpdate(socket: url, timeout: 1)
        try await Task.sleep(for: .milliseconds(400))
        harness.server.stop()
        let sameVersion = CommandServer(socketURL: url, appVersion: "9.9.9") { _, _ in .success(.null) }
        try sameVersion.start()
        let sameResult = try await same
        sameVersion.stop()
        try expect(sameResult.code != 0, "salió con 0")
        try expect(!sameResult.out.contains("is running"), sameResult.out)
        try expect(sameResult.err.contains("still 9.9.9"), sameResult.err)

        // Se corta sin "Restarting PRBar": exit 3 enseguida, sin esperar.
        harness = try Harness(url: url)
        harness.fake.updateInstallHangs = true
        harness.fake.waitEvents = [.progress(message: UpdatePhase.building.title)]
        let start = Date()
        async let lost = runUpdate(socket: url, timeout: 5)
        try await Task.sleep(for: .milliseconds(400))
        harness.server.stop()
        let lostResult = try await lost
        try expectEqual(lostResult.code, CLIExit.appUnavailable)
        try expect(lostResult.err.contains("Lost the connection"), lostResult.err)
        try expect(Date().timeIntervalSince(start) < 3, "esperó \(Date().timeIntervalSince(start)) s")
    }

    @MainActor
    private static func updateCheckExit() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        let upToDate = try await runCLI(["update", "--check", "--json"], socket: harness.url)
        try expectEqual(upToDate.code, 0)
        harness.fake.updateLatest = "2.0.0"
        let text = try await runCLI(["update", "--check"], socket: harness.url)
        try expectEqual(text.code, CLIExit.updateAvailable)
        try expect(text.out.contains("2.0.0 is available"), text.out)
        let json = try await runCLI(["update", "--check", "--json"], socket: harness.url)
        try expectEqual(json.code, CLIExit.updateAvailable)
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.out.utf8))
        guard case .object(let data)? = decoded["data"] else { throw TestFailure(description: json.out) }
        try expectEqual(data["latest"], .string("2.0.0"))
    }

    @MainActor
    private static func sessions() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        let empty = try await runCLI(["session", "list", "api#7"], socket: harness.url)
        try expectEqual(empty.code, 0)
        try expect(empty.out.contains("No Claude session for this PR yet."), empty.out)
        harness.fake.sessions = [
            ClaudeSessionInfo(number: 1, label: "Review · stage 1", kind: "review", machine: "this Mac", directory: "/wt/7",
                              startedAt: t0, sessionID: "0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50", busy: false),
            ClaudeSessionInfo(number: 2, label: "CI fix", kind: "ci-fix", machine: "devbox", directory: "/srv/prbar/7",
                              startedAt: t0, sessionID: "1d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50", busy: true),
        ]
        let list = try await runCLI(["session", "list", "api#7"], socket: harness.url)
        try expectEqual(list.code, 0)
        try expect(list.out.contains("Review · stage 1") && list.out.contains("/wt/7"), list.out)
        try expect(list.out.contains("CI fix (Claude is working on it)") && list.out.contains("devbox"), list.out)
        let json = try await runCLI(["session", "list", "api#7", "--json"], socket: harness.url)
        try expect(json.out.contains("\"sessionID\" : \"1d5b2f4e") && json.out.contains("\"busy\" : true"), json.out)
        let open = try await runCLI(["session", "open", "api#7", "--job", "review"], socket: harness.url)
        try expectEqual(open.code, 0)
        try expect(open.out.contains("Opened Review · stage 1 (this Mac)."), open.out)
        try expectEqual(harness.fake.calls.last, "sessionOpen api#7 review -")
        harness.fake.failure = CommandFailure(.invalidState, "No Claude session for this PR yet.")
        let none = try await runCLI(["session", "open", "api#7"], socket: harness.url)
        try expectEqual(none.code, CLIExit.invalidState)
        try expect(none.err.contains("No Claude session for this PR yet."), none.err)
    }

    @MainActor
    private static func nowLine() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        harness.fake.reviewPhase = .reviewing(agents: 1)
        harness.fake.reviewActivity = JobActivity(kind: .claude, text: "Reading src/a.swift", startedAt: Date().addingTimeInterval(-12))
        let show = try await runCLI(["review", "show", "acme/api#1"], socket: harness.url)
        try expectEqual(show.code, 0)
        try expect(show.out.contains("Now: Reading src/a.swift (1"), show.out)
        let json = try await runCLI(["review", "show", "acme/api#1", "--json"], socket: harness.url)
        try expect(json.out.contains(#""activity""#) && json.out.contains(#""kind" : "claude""#), json.out)
        harness.fake.respondPhase = .analyzing(agents: 0)
        harness.fake.respondActivity = JobActivity(kind: .prbar, text: "Creating the worktree…", startedAt: Date())
        for command in [["respond", "show", "acme/web#2"], ["ci", "show", "acme/web#2"], ["conflicts", "show", "acme/web#2"]] {
            let result = try await runCLI(command, socket: harness.url)
            try expect(result.out.contains("Now: Creating the worktree… ("), "\(command): \(result.out)")
        }
        // Nothing running: no line.
        harness.fake.reviewActivity = nil
        let idle = try await runCLI(["review", "show", "acme/api#1"], socket: harness.url)
        try expect(!idle.out.contains("Now:"), idle.out)
    }

    @MainActor
    private static func ciAndUsage() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        let list = try await runCLI(["ci"], socket: harness.url)
        try expectEqual(list.code, 0)
        try expect(list.out.contains("acme/api#12") && list.out.contains("Add rate limiting"), list.out)
        let fix = try await runCLI(["ci", "fix", "api#12"], socket: harness.url)
        try expectEqual(fix.code, 0)
        try expect(fix.out.contains("Fix CI"), fix.out)
        let usage = try await runCLI(["usage", "--month", "2026-10"], socket: harness.url)
        try expectEqual(usage.code, 0)
        try expect(usage.out.contains("Claude in 2026-10: $0.42 estimated"), usage.out)
        try expect(usage.out.contains("Review api#7") && usage.out.contains("review, filter"), usage.out)
        try expect(usage.out.contains("may not be billed per token"), usage.out)
        let json = try await runCLI(["usage", "--json"], socket: harness.url)
        try expect(json.out.contains("\"costUSD\" : 0.42") && json.out.contains("may not be billed per token"), json.out)
        // `ci push` de algo que no es un Fix CI: no pushea (exit 6) y solo miró el estado.
        let push = try await runCLI(["ci", "push", "api#12"], socket: harness.url)
        try expectEqual(push.code, CLIExit.invalidState)
        try expect(push.err.contains("isn’t a Fix CI"), push.err)
        try expectEqual(harness.fake.calls, ["ciList", "ciFix api#12 wait=false", "usage 2026-10", "usage -", "respondShow api#12"])
        // Con --yes no hay pregunta: el pedido lleva el modo y la app no pushea una corrida que no sea Fix CI.
        _ = try await runCLI(["ci", "push", "api#12", "--yes"], socket: harness.url)
        try expectEqual(harness.fake.calls.last, "respondPush api#12 wait=false mode=ciFix")
        try expectEqual(RespondPushGate.modeCheck(expected: .ciFix, actual: .feedback, prID: "acme/api#12")?.message,
                        "acme/api#12 isn’t a Fix CI: use `prbar respond push acme/api#12`.")
        try expectEqual(RespondPushGate.modeCheck(expected: .feedback, actual: .ciFix, prID: "acme/api#12")?.code, .invalidState)
        try expect(RespondPushGate.modeCheck(expected: .ciFix, actual: .ciFix, prID: "acme/api#12") == nil)
        try expect(RespondPushGate.modeCheck(expected: nil, actual: .feedback, prID: "acme/api#12") == nil)
    }

    @MainActor
    private static func runnersTestExit() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        let ok = try await runCLI(["runners", "test", "devbox"], socket: harness.url)
        try expectEqual(ok.code, 0)
        try expect(ok.out.contains("Logged in:") && ok.out.contains("yes"), ok.out)
        try expect(ok.out.contains("2.1.318"), ok.out)
        let list = try await runCLI(["runners"], socket: harness.url)
        try expectEqual(list.code, 0)
        try expect(list.out.contains("devbox (default)"), list.out)
        try expect(list.out.contains("✓ Linux · claude 2.1.318 · logged in"), list.out)
        harness.fake.runnerProblems = ["Claude isn’t signed in on devbox: run `claude` there once to log in."]
        let failing = try await runCLI(["runners", "test", "devbox"], socket: harness.url)
        try expectEqual(failing.code, CLIExit.generalError)
        try expect(failing.out.contains("! Claude isn’t signed in on devbox"), failing.out)
        let json = try await runCLI(["runners", "test", "devbox", "--json"], socket: harness.url)
        try expectEqual(json.code, CLIExit.generalError)
        try expect(json.out.contains("Claude isn’t signed in"), json.out)
        let failingList = try await runCLI(["runners", "list"], socket: harness.url)
        try expect(failingList.out.contains("⚠ Claude isn’t signed in on devbox"), failingList.out)
    }

    @MainActor
    private static func jsonStatus() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        let result = try await runCLI(["status", "--json"], socket: harness.url)
        try expectEqual(result.code, 0)
        let json = try JSONDecoder().decode([String: JSONValue].self, from: Data(result.out.utf8))
        try expectEqual(json["schemaVersion"], .int(1))
        guard case .object(let data)? = json["data"] else { throw TestFailure(description: result.out) }
        try expectEqual(data["appVersion"], .string("test"))
        try expectEqual(harness.fake.calls, ["status"])
    }

    @MainActor
    private static func needsYes() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        harness.fake.reviewPhase = .ready(editDraft())
        let result = try await runCLI(["review", "publish", "acme/api#1", "--approve"], socket: harness.url)
        try expectEqual(result.code, 4)
        try expect(result.err.contains("--yes"), result.err)
        try expect(!harness.fake.calls.contains { $0.hasPrefix("reviewPublish") }, "\(harness.fake.calls)")
        let confirmed = try await runCLI(["review", "publish", "acme/api#1", "--approve", "--yes"], socket: harness.url)
        try expectEqual(confirmed.code, 0)
        try expect(harness.fake.calls.contains { $0.hasPrefix("reviewPublish acme/api#1 APPROVE") }, "\(harness.fake.calls)")
    }

    @MainActor
    private static func recommended() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        var draft = editDraft()
        draft.previous = [PreviousCommentStatus(id: "P1", recordID: UUID(), findingID: "f1", file: "src/a.ts", line: 3, text: "Validate it.",
                                                github: .open, outdated: false, status: .notFixed, note: "Still there.")]
        draft.reviewedSince = String(repeating: "a", count: 40)
        harness.fake.reviewPhase = .ready(draft)
        let show = try await runCLI(["review", "show", "acme/api#1", "--full"], socket: harness.url)
        try expectEqual(show.code, 0)
        try expect(show.out.contains("Previous comments"), show.out)
        try expect(show.out.contains("reviewed before at aaaaaaa · 0 fixed · 1 pending"), show.out)
        try expect(show.out.contains("Not fixed"), show.out)
        try expect(show.out.contains("Validate it."), show.out)
        try expect(show.out.contains("Recommended: Request Changes — 1 previous comment not fixed: src/a.ts:3; 2 new findings"), show.out)
        let unconfirmed = try await runCLI(["review", "publish", "acme/api#1", "--recommended"], socket: harness.url)
        try expectEqual(unconfirmed.code, 4)
        try expect(!harness.fake.calls.contains { $0.hasPrefix("reviewPublish") }, "\(harness.fake.calls)")
        let posted = try await runCLI(["review", "publish", "acme/api#1", "--recommended", "--yes"], socket: harness.url)
        try expectEqual(posted.code, 0)
        try expect(posted.out.contains("Recommended: Request Changes"), posted.out)
        try expect(harness.fake.calls.contains { $0.hasPrefix("reviewPublish acme/api#1 REQUEST_CHANGES") }, "\(harness.fake.calls)")
    }

    @MainActor
    private static func asks() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        harness.fake.respondPhase = .ready(cliRespondDraft())
        let declined = try await runCLI(["respond", "reply-only", "acme/web#2"], socket: harness.url, interactive: true, answer: false)
        try expectEqual(declined.code, 130)
        try expect(!harness.fake.calls.contains { $0.hasPrefix("respondReplyOnly") })
    }

    @MainActor
    private static func errors() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        harness.fake.failure = CommandFailure(.notFound, "acme/api#9 isn’t in PRBar’s list.")
        let notFound = try await runCLI(["review", "show", "acme/api#9"], socket: harness.url)
        try expectEqual(notFound.code, 5)
        try expect(notFound.err.contains("isn’t in PRBar’s list"), notFound.err)
        harness.fake.failure = CommandFailure(.invalidState, "No review ready.")
        let state = try await runCLI(["review", "show", "acme/api#9"], socket: harness.url)
        try expectEqual(state.code, 6)
    }

    @MainActor
    private static func cleanupOnlyShown() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        harness.fake.cleanupPlan = CleanupPlan(candidates: [
            CleanupCandidate(path: "/w/a", bytes: 1, kind: .workspace, clone: nil, title: "a"),
            CleanupCandidate(path: "/w/b", bytes: 2, kind: .workspace, clone: nil, title: "b"),
        ])
        let confirmed = try await runCLI(["cleanup", "--yes"], socket: harness.url)
        try expectEqual(confirmed.code, 0)
        try expect(harness.fake.calls.contains("cleanup 0 confirmed=true paths=/w/a,/w/b"), "\(harness.fake.calls)")
        let asked = try await runCLI(["cleanup", "--older-than", "30d"], socket: harness.url, interactive: true)
        try expectEqual(asked.code, 0)
        try expect(harness.fake.calls.contains("cleanup 30 confirmed=true paths=/w/a,/w/b"), "\(harness.fake.calls)")
        // Sin terminal ni --yes: sale con 4 sin imprimir la tabla de lo que no va a borrar (L17).
        let script = try await runCLI(["cleanup"], socket: harness.url)
        try expectEqual(script.code, 4)
        try expect(!script.out.contains("Delete"), script.out)
        // `runners remove` pregunta en la terminal como Settings; "no" no borra (L13).
        let declined = try await runCLI(["runners", "remove", "devbox"], socket: harness.url, interactive: true, answer: false)
        try expectEqual(declined.code, CLIExit.cancelled)
        try expect(!harness.fake.calls.contains("runnerRemove devbox"), "\(harness.fake.calls)")
        let removed = try await runCLI(["runners", "remove", "devbox"], socket: harness.url)
        try expectEqual(removed.code, 0)
        try expect(harness.fake.calls.contains("runnerRemove devbox"), "\(harness.fake.calls)")
    }

    @MainActor
    private static func mergeNeedsYes() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        let result = try await runCLI(["merge", "acme/api#4", "--method", "squash"], socket: harness.url)
        try expectEqual(result.code, 4)
        try expect(result.err.contains("Squash and Merge acme/api#1 at c0ffee1?") && result.err.contains("--yes"), result.err)
        try expect(!harness.fake.calls.contains { $0.hasPrefix("merge ") }, "\(harness.fake.calls)")
        // --yes: mergea el head de la vista previa (y lo dice), con el método que se mostró.
        let confirmed = try await runCLI(["merge", "acme/api#4", "--yes"], socket: harness.url)
        try expectEqual(confirmed.code, 0)
        try expect(harness.fake.calls.contains("merge acme/api#4 squash head=c0ffee1234"), "\(harness.fake.calls)")
        try expect(confirmed.err.contains("c0ffee1"), confirmed.err)
        // Con terminal muestra lo del diálogo antes de preguntar.
        let asked = try await runCLI(["merge", "acme/api#4"], socket: harness.url, interactive: true)
        try expectEqual(asked.code, 0)
        for text in ["PR 1", "feature/1 → develop", "3 commits", "c0ffee1", "Some checks are failing", "deletes"] {
            try expect(asked.out.contains(text), "falta \(text): \(asked.out)")
        }
        let preview = try await runCLI(["merge", "acme/api#4", "--preview"], socket: harness.url)
        try expectEqual(preview.code, 0)
        try expect(preview.out.contains("c0ffee1") && preview.out.contains("3 commits"), preview.out)
        let dismissed = try await runCLI(["merge", "acme/api#4", "--dismiss"], socket: harness.url)
        try expectEqual(dismissed.code, 0)
        try expect(harness.fake.calls.contains { $0.hasPrefix("mergeDismiss acme/api#4") }, "\(harness.fake.calls)")
        // Todavía no se puede: --preview muestra el resumen y el motivo (sale con 6); merge falla sin mergear.
        harness.fake.previewProblem = "This PR isn’t ready to merge"
        let blockedPreview = try await runCLI(["merge", "acme/api#4", "--preview"], socket: harness.url)
        try expectEqual(blockedPreview.code, 6)
        try expect(blockedPreview.out.contains("3 commits") && blockedPreview.out.contains("Can’t merge yet: This PR isn’t ready to merge"),
                   blockedPreview.out)
        let calls = harness.fake.calls.count
        let refused = try await runCLI(["merge", "acme/api#4", "--yes"], socket: harness.url)
        try expectEqual(refused.code, 6)
        try expect(refused.err.contains("This PR isn’t ready to merge"), refused.err)
        try expect(!harness.fake.calls.dropFirst(calls).contains { $0.hasPrefix("merge ") }, "\(harness.fake.calls)")
    }

    private static func noApp() async throws {
        let socket = try shortSocketURL()
        let result = try await runCLI(["status"], socket: socket)
        try expectEqual(result.code, 3)
    }
}
