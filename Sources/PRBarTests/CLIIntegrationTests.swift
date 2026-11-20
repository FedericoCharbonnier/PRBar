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

    init() throws {
        url = try shortSocketURL()
        let fake = self.fake
        server = CommandServer(socketURL: url, appVersion: "9.9.9") { command, events in
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
    ]

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
        try expect(result.err.contains("Squash and Merge acme/api#1?") && result.err.contains("--yes"), result.err)
        try expect(!harness.fake.calls.contains { $0.hasPrefix("merge") }, "\(harness.fake.calls)")
        let confirmed = try await runCLI(["merge", "acme/api#4", "--yes"], socket: harness.url)
        try expectEqual(confirmed.code, 0)
        try expect(harness.fake.calls.contains { $0.hasPrefix("merge acme/api#4") }, "\(harness.fake.calls)")
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
