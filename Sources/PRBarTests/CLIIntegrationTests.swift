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
        TestCase("integración: publicar sin --yes y sin terminal → exit 4, sin llamar a la app") { try await needsYes() },
        TestCase("integración: con terminal pregunta; si dice que no → 130") { try await asks() },
        TestCase("integración: errores de la app → exit codes") { try await errors() },
        TestCase("integración: sin app → exit 3") { try await noApp() },
        TestCase("integración: merge sin --yes y sin terminal → exit 4; --dismiss no pregunta") { try await mergeNeedsYes() },
        TestCase("integración: update --check sale con 10 si hay versión nueva, también con --json") { try await updateCheckExit() },
        TestCase("integración: update espera a la versión nueva solo si la app se estaba reiniciando") { try await updateRelaunch() },
        TestCase("integración: chat --json sin mensaje en una terminal no se queda leyendo la terminal") { try await chatJSONWithoutMessage() },
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
    }

    private static func noApp() async throws {
        let socket = try shortSocketURL()
        let result = try await runCLI(["status"], socket: socket)
        try expectEqual(result.code, 3)
    }
}
