import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

enum CLISupportTests {
    static let cases: [TestCase] = [
        TestCase("cli soporte: exit codes del spec C.5") {
            try expectEqual(CLIExit.code(for: CommandFailure(.invalidUsage, "")), 2)
            try expectEqual(CLIExit.code(for: CommandFailure(.protocolMismatch, "")), 3)
            try expectEqual(CLIExit.code(for: CommandFailure(.confirmationRequired, "")), 4)
            try expectEqual(CLIExit.code(for: CommandFailure(.notFound, "")), 5)
            try expectEqual(CLIExit.code(for: CommandFailure(.invalidState, "")), 6)
            try expectEqual(CLIExit.code(for: CommandFailure(.cancelled, "")), 130)
            try expectEqual(CLIExit.code(for: CommandFailure(.failed, "")), 1)
        },
        TestCase("cli soporte: color solo en terminal y sin NO_COLOR") {
            try expect(Terminal.colorsEnabled(isTTY: true, environment: [:]))
            try expect(!Terminal.colorsEnabled(isTTY: false, environment: [:]))
            try expect(!Terminal.colorsEnabled(isTTY: true, environment: ["NO_COLOR": "1"]))
            try expect(!Terminal.colorsEnabled(isTTY: true, environment: ["TERM": "dumb"]))
        },
        TestCase("cli soporte: tablas alineadas") {
            try expectEqual(Table.render(headers: ["PR", "Title"], rows: [["a/b#1", "Fix"], ["a/b#10", "Add"]]),
                            ["PR      Title", "a/b#1   Fix", "a/b#10  Add"])
        },
        TestCase("cli soporte: --json con schemaVersion y data") {
            let data = try JSONOutput.encode(JSONValue.object(["a": .int(1)]))
            let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
            try expectEqual(decoded["schemaVersion"], .int(1))
            try expectEqual(decoded["data"], .object(["a": .int(1)]))
        },
        TestCase("cli soporte: Output sin color y errores a stderr") {
            var out = "", err = ""
            let output = Output(terminal: .plain, json: false, out: { out += $0 }, err: { err += $0 })
            output.line(output.paint("hi", .bold))
            output.error("boom")
            output.event(.progress(message: "Reviewing…"))
            output.event(.text(delta: "abc"))
            try expectEqual(out, "hi\nabc")
            try expectEqual(err, "Error: boom\nReviewing…\n")
        },
        TestCase("cli soporte: lista con casillas") {
            var list = CheckboxList(rows: [.init(label: "a", checked: true), .init(label: "b", checked: false)])
            try expectEqual(CheckboxList.key(from: [0x1B, 0x5B, 0x42]), .down)
            try expectEqual(CheckboxList.key(from: [0x20]), .toggle)
            try expectEqual(CheckboxList.key(from: [0x0D]), .done)
            try expectEqual(CheckboxList.key(from: [0x03]), .cancel)
            try expectEqual(list.handle(.down), .keepGoing)
            try expectEqual(list.handle(.toggle), .keepGoing)
            try expectEqual(list.rows.map(\.checked), [true, true])
            try expectEqual(list.handle(.selectNone), .keepGoing)
            try expectEqual(list.rows.map(\.checked), [false, false])
            try expectEqual(list.handle(.edit), .edit(1))
            try expectEqual(list.handle(.down), .keepGoing)
            try expectEqual(list.cursor, 1)
            try expectEqual(list.render(colors: false), "  [ ] a\n› [ ] b\n")
            try expectEqual(list.handle(.done), .done)
        },
        TestCase("cli soporte: encuentra el PRBar.app que contiene a prbar") {
            let root = try temporaryDirectory()
            let helpers = root.appendingPathComponent("Apps/PRBar.app/Contents/Helpers", isDirectory: true)
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            let binary = helpers.appendingPathComponent("prbar")
            try Data().write(to: binary)
            let link = root.appendingPathComponent("bin-prbar")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
            let found = AppLauncher.appBundle(executable: link, home: root)
            try expectEqual(found?.resolvingSymlinksInPath().path,
                            root.appendingPathComponent("Apps/PRBar.app").resolvingSymlinksInPath().path)
            try expectEqual(AppLauncher.appBundle(executable: root.appendingPathComponent("loose"), home: root), nil)
        },
        TestCase("cli soporte: versión del bundle que contiene a prbar, resolviendo el link") {
            let root = try temporaryDirectory()
            let helpers = root.appendingPathComponent("PRBar.app/Contents/Helpers", isDirectory: true)
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.4.0"],
                                                           format: .xml, options: 0)
            try plist.write(to: root.appendingPathComponent("PRBar.app/Contents/Info.plist"))
            let binary = helpers.appendingPathComponent("prbar")
            try Data().write(to: binary)
            let link = root.appendingPathComponent("prbar-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
            try expectEqual(AppVersion.forExecutable(link), "1.4.0")
            try expectEqual(AppVersion.forExecutable(root.appendingPathComponent("loose")), PRBarCore.version)
        },
        TestCase("cli runner: status, --json y errores contra un servidor de prueba") { try await runnerAgainstServer() },
    ]

    /// `CLIRunner` de punta a punta por un socket real, con `FakeActions` detrás del dispatcher.
    @MainActor
    private static func runnerAgainstServer() async throws {
        let url = try shortSocketURL()
        defer { removeSocketDirectory(url) }
        let fake = FakeActions()
        let server = CommandServer(socketURL: url, appVersion: "9.9.9") { command, events in
            await CommandDispatcher.run(command, on: fake, events: events)
        }
        try server.start()
        defer { server.stop() }

        func run(_ arguments: [String]) async throws -> (out: String, err: String, exit: Int32) {
            try await Task.detached {
                let box = OutputBox()
                let environment = CLIEnvironment(
                    terminal: .plain, out: { box.append(out: $0) }, err: { box.append(err: $0) },
                    connect: { try AppConnection.connect(socketURL: url) }, ask: { _ in false }
                )
                guard let command = try PRBarCommand.parseAsRoot(arguments) as? any RemoteCommand else {
                    throw TestFailure(description: "\(arguments) no es un comando remoto")
                }
                var exit: Int32 = 0
                do {
                    try CLIRunner.run(command, environment: environment)
                } catch let code as ExitCode {
                    exit = code.rawValue
                }
                return (box.out, box.err, exit)
            }.value
        }

        let text = try await run(["status"])
        try expectEqual(text.exit, 0)
        try expect(text.out.hasPrefix("PRBar test"), text.out)
        try expect(text.out.contains("Ready to Merge"), text.out)
        try expectEqual(text.err, "")

        let json = try await run(["status", "--json"])
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.out.utf8))
        try expectEqual(decoded["schemaVersion"], .int(1))
        guard case .object(let data)? = decoded["data"] else { throw TestFailure(description: json.out) }
        try expectEqual(data["appVersion"], .string("test"))

        fake.failure = CommandFailure(.invalidState, "PRBar hasn’t loaded the PRs yet.")
        let failed = try await run(["status"])
        try expectEqual(failed.exit, CLIExit.invalidState)
        try expectEqual(failed.out, "")
        try expectEqual(failed.err, "Error: PRBar hasn’t loaded the PRs yet.\n")
    }
}

/// Junta lo que la CLI escribe en stdout y stderr (desde otro hilo).
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = ""
    private var stderr = ""

    func append(out text: String) {
        lock.lock()
        stdout += text
        lock.unlock()
    }

    func append(err text: String) {
        lock.lock()
        stderr += text
        lock.unlock()
    }

    var out: String {
        lock.lock()
        defer { lock.unlock() }
        return stdout
    }

    var err: String {
        lock.lock()
        defer { lock.unlock() }
        return stderr
    }
}
