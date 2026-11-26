import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

enum CLISupportTests {
    static let cases: [TestCase] = [
        TestCase("cli: --wait manda una línea cuando cambia la fase o el paso; el mismo paso empezado de nuevo es otra línea") {
            var progress = WaitProgress()
            let reading = JobActivity(kind: .claude, text: "Reading a.swift", startedAt: t0)
            try expectEqual(progress.next(phase: "Reviewing…", activity: nil), "Reviewing…")
            try expectEqual(progress.next(phase: "Reviewing…", activity: nil), nil)
            try expectEqual(progress.next(phase: "Reviewing…", activity: reading), "Reviewing… · Reading a.swift")
            try expectEqual(progress.next(phase: "Reviewing…", activity: reading), nil)
            var again = reading
            again.startedAt = t0.addingTimeInterval(5)
            try expectEqual(progress.next(phase: "Reviewing…", activity: again), "Reviewing… · Reading a.swift")
            try expectEqual(progress.next(phase: "Filtering the findings…", activity: again), "Filtering the findings… · Reading a.swift")
            try expectEqual(progress.next(phase: "Filtering the findings…", activity: nil), "Filtering the findings…")
        },
        TestCase("cli: sin terminal no repite una línea de progreso idéntica seguida; en un terminal sí") {
            var err = ""
            let plain = Output(terminal: .plain, json: false, out: { _ in }, err: { err += $0 })
            plain.event(.progress(message: "Reviewing… · Reading a.swift"))
            plain.event(.progress(message: "Reviewing… · Reading a.swift"))
            plain.event(.progress(message: "Reviewing… · Reading b.swift"))
            try expectEqual(err, "Reviewing… · Reading a.swift\nReviewing… · Reading b.swift\n")
            var tty = ""
            let terminal = Output(terminal: Terminal(stdinIsTTY: true, stdoutIsTTY: true, colors: false), json: false,
                                  out: { _ in }, err: { tty += $0 })
            terminal.event(.progress(message: "x"))
            terminal.event(.progress(message: "x"))
            try expectEqual(tty, "x\nx\n")
        },
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
        TestCase("ctrl-c: si cancelar no contesta, sale con 130 al vencer el plazo") {
            let exits = ExitBox()
            let handler = InterruptHandler(cancel: .reviewCancel(pr: "a#1"), connect: {
                Thread.sleep(forTimeInterval: 5)
                throw AppUnavailable("slow")
            }, err: { _ in }, deadline: 0.2, terminate: { exits.append($0) }, installsSignalHandler: false)
            let start = Date()
            handler.interrupted()
            for _ in 0..<100 where exits.codes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            try expectEqual(exits.codes.first, CLIExit.cancelled)
            try expect(Date().timeIntervalSince(start) < 1, "tardó \(Date().timeIntervalSince(start)) s")
        },
        TestCase("ctrl-c: el segundo Ctrl-C sale enseguida") {
            let exits = ExitBox()
            let handler = InterruptHandler(cancel: .reviewCancel(pr: "a#1"), connect: {
                Thread.sleep(forTimeInterval: 5)
                throw AppUnavailable("slow")
            }, err: { _ in }, deadline: 10, terminate: { exits.append($0) }, installsSignalHandler: false)
            handler.interrupted()
            handler.interrupted()
            try expectEqual(exits.codes, [CLIExit.cancelled])
        },
        TestCase("ctrl-c: manda el cancel a la app y sale con 130") { try await interruptSendsCancel() },
    ]

    @MainActor
    private static func interruptSendsCancel() async throws {
        let url = try shortSocketURL()
        defer { removeSocketDirectory(url) }
        let fake = FakeActions()
        let server = CommandServer(socketURL: url, appVersion: "9.9.9") { command, events in
            await CommandDispatcher.run(command, on: fake, events: events)
        }
        try server.start()
        defer { server.stop() }
        let exits = ExitBox()
        let handler = InterruptHandler(cancel: .reviewCancel(pr: "a#1"), connect: { try AppConnection.connect(socketURL: url) },
                                       err: { _ in }, deadline: 5, terminate: { exits.append($0) }, installsSignalHandler: false)
        handler.interrupted()
        for _ in 0..<200 where exits.codes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try expectEqual(exits.codes, [CLIExit.cancelled])
        try expectEqual(fake.calls, ["reviewCancel a#1"])
    }

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

/// Los exit codes que pidió un `InterruptHandler` de prueba.
final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int32] = []

    func append(_ code: Int32) {
        lock.lock()
        stored.append(code)
        lock.unlock()
    }

    var codes: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
