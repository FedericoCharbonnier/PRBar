import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

/// `prbar remote` (spec Q.3).
enum RemoteCLITests {
    @MainActor
    private final class Server {
        let url: URL
        let fake = FakeActions()
        let server: CommandServer

        init() throws {
            url = try shortSocketURL()
            let fake = fake
            server = CommandServer(socketURL: url, appVersion: "9.9.9") { command, events in
                await CommandDispatcher.run(command, on: fake, events: events)
            }
            try server.start()
        }
    }

    private final class Captured: @unchecked Sendable {
        var out = ""
        var err = ""
        var questions: [String] = []
    }

    private static func runRemote<C: RemoteCommand>(_ command: C, _ environment: CLIEnvironment) throws {
        try CLIRunner.run(command, environment: environment)
    }

    private static func cli(_ arguments: [String], socket: URL, interactive: Bool, answer: Bool) async throws
        -> (code: Int32, out: String, err: String, questions: [String]) {
        let captured = Captured()
        let code = try await Task.detached { () -> Int32 in
            guard let command = try PRBarCommand.parseAsRoot(arguments) as? any RemoteCommand else {
                throw TestFailure(description: "no remoto")
            }
            let terminal = interactive ? Terminal(stdinIsTTY: true, stdoutIsTTY: true, colors: false) : .plain
            let environment = CLIEnvironment(terminal: terminal, out: { captured.out += $0 }, err: { captured.err += $0 },
                                             connect: { try AppConnection.connect(socketURL: socket) },
                                             ask: { captured.questions.append($0); return answer })
            do {
                try runRemote(command, environment)
                return 0
            } catch let exit as ExitCode {
                return exit.rawValue
            }
        }.value
        return (code, captured.out, captured.err, captured.questions)
    }

    private static func parse(_ arguments: [String]) throws -> AppCommand {
        guard let command = try PRBarCommand.parseAsRoot(arguments) as? any RemoteCommand else {
            throw TestFailure(description: "\(arguments) no es remoto")
        }
        return try command.appCommand(confirmed: arguments.contains("--yes"))
    }

    static let cases: [TestCase] = [
        TestCase("remote cli: cada subcomando arma su AppCommand") {
            EnrollTokenInput.read = { stdin in stdin ? "tok-from-stdin" : "" }
            try expectEqual(try parse(["remote", "status", "--json"]), .remoteStatus)
            try expectEqual(try parse(["remote"]), .remoteStatus)
            try expectEqual(try parse(["remote", "enable", "--relay", "relay.example.com", "--enroll-token-stdin"]),
                            .remoteEnable(relay: "relay.example.com", enrollToken: "tok-from-stdin"))
            try expectEqual(try parse(["remote", "enable"]),
                            .remoteEnable(relay: RemoteSettings.defaultRelayHost, enrollToken: ""))
            try expectEqual(try parse(["remote", "disable"]), .remoteDisable)
            try expectEqual(try parse(["remote", "devices"]), .remoteDevices)
            try expectEqual(try parse(["remote", "devices", "--require-face-id", "dev1", "off"]),
                            .remoteSetPresenceRequirement(device: "dev1", enabled: false))
            try expectEqual(try parse(["remote", "revoke", "dev1", "--yes"]), .remoteRevoke(device: "dev1", confirmed: true))
            try expectEqual(try parse(["remote", "keep-awake", "on"]), .remoteSetKeepAwake(enabled: true))
            try expectEqual(try parse(["remote", "mailbox", "off"]), .remoteSetMailbox(enabled: false))
            try expectEqual(try parse(["remote", "reset", "--yes"]), .remoteReset(confirmed: true))
            try expectEqual(try parse(["remote", "app-link", "set", "https://testflight.apple.com/join/X"]),
                            .remoteSetAppLink(url: "https://testflight.apple.com/join/X"))
            try expectEqual(try parse(["remote", "app-link", "clear"]), .remoteSetAppLink(url: nil))
            do {
                _ = try PRBarCommand.parseAsRoot(["remote", "devices", "--require-face-id", "dev1"])
                throw TestFailure(description: "aceptó --require-face-id sin on|off")
            } catch is TestFailure { throw TestFailure(description: "aceptó --require-face-id sin on|off") } catch {}
        },
        TestCase("remote cli: el QR en medios bloques, con zona silenciosa") {
            // 2×2 con zona silenciosa de 1: se dibuja lo claro (la zona y los módulos claros); un módulo oscuro es un
            // hueco en su mitad del carácter.
            let lines = QRRender.halfBlocks(matrix: [[true, false], [false, true]], quietZone: 1)
            try expectEqual(lines, ["█▀██", "██▄█"])
            let inverted = QRRender.halfBlocks(matrix: [[true, false], [false, true]], quietZone: 1, inverted: true)
            try expectEqual(inverted, [" ▄  ", "  ▀ "])
            let text = "prbar://pair?v=1&r=prbar.example.com&a=abcdefghijklmnopqrstuvwxyz&p=abcdefghijklmnop&k=xyz&m=abc&n=Mac"
            guard let matrix = QRCodeMatrix.make(text) else { throw TestFailure(description: "sin QR") }
            try expect(matrix.count >= 21 && (matrix.count - 21) % 4 == 0, "\(matrix.count)")
            try expect(matrix.allSatisfy { $0.count == matrix.count })
            try expect(QRCodeMatrixProbe.finders(matrix))
            let rendered = QRRender.halfBlocks(matrix: matrix)
            try expectEqual(rendered.count, (matrix.count + 4 + 1) / 2)
            try expect(rendered.allSatisfy { $0.count == matrix.count + 4 })
            // Arriba de todo, la zona silenciosa: dos filas claras = una línea llena.
            try expectEqual(rendered[0], String(repeating: "█", count: matrix.count + 4))
        },
        TestCase("remote cli: pair sin terminal sale con 2") {
            let server = try await Server()
            defer { removeSocketDirectory(server.url) }
            let result = try await cli(["remote", "pair"], socket: server.url, interactive: false, answer: true)
            try expectEqual(result.code, 2)
            try expect(result.err.contains("Pairing needs a terminal to show the QR code."), result.err)
            let calls = await server.fake.calls
            try expectEqual(calls, [])
        },
        TestCase("remote cli: pair muestra el QR, espera, pregunta por el código y confirma (o cancela)") {
            let server = try await Server()
            defer { removeSocketDirectory(server.url) }
            let yes = try await cli(["remote", "pair"], socket: server.url, interactive: true, answer: true)
            try expectEqual(yes.code, 0)
            try expect(yes.out.contains("█"), "sin QR")
            try expect(yes.out.contains("prbar://pair?v=1"), "sin el link de respaldo")
            try expect(yes.out.contains("Waiting for your iPhone… (expires in "), yes.out)
            try expectEqual(yes.questions, ["Does your iPhone show 123 456?"])
            try expect(yes.out.contains("Paired Federico’s iPhone."), yes.out)
            var calls = await server.fake.calls
            try expectEqual(calls, ["remotePairStart", "remotePairWait p1", "remotePairConfirm p1 true"])
            await MainActor.run { server.fake.calls = [] }
            let no = try await cli(["remote", "pair"], socket: server.url, interactive: true, answer: false)
            try expectEqual(no.code, CLIExit.cancelled)
            calls = await server.fake.calls
            try expectEqual(calls, ["remotePairStart", "remotePairWait p1", "remotePairConfirm p1 false"])
        },
        TestCase("remote cli: status, devices y revoke por el socket") {
            let server = try await Server()
            defer { removeSocketDirectory(server.url) }
            let status = try await cli(["remote", "status"], socket: server.url, interactive: false, answer: true)
            try expect(status.out.contains("Connected to relay.example.com · 1 iPhone online"), status.out)
            let devices = try await cli(["remote", "devices"], socket: server.url, interactive: false, answer: true)
            try expect(devices.out.contains("Federico’s iPhone") && devices.out.contains("required"), devices.out)
            let unconfirmed = try await cli(["remote", "revoke", "dev1"], socket: server.url, interactive: false, answer: true)
            try expectEqual(unconfirmed.code, CLIExit.confirmationRequired)
            let revoked = try await cli(["remote", "revoke", "dev1", "--yes"], socket: server.url, interactive: false, answer: true)
            try expect(revoked.out.contains("Revoked Federico’s iPhone."), revoked.out)
        },
    ]
}

/// Los tres patrones de posición donde van.
enum QRCodeMatrixProbe {
    static func finders(_ rows: [[Bool]]) -> Bool {
        func finder(_ top: Int, _ left: Int) -> Bool {
            (0..<7).allSatisfy { y in
                (0..<7).allSatisfy { x in
                    let ring = max(abs(y - 3), abs(x - 3))
                    return rows[top + y][left + x] == (ring == 3 || ring <= 1)
                }
            }
        }
        let n = rows.count
        return finder(0, 0) && finder(0, n - 7) && finder(n - 7, 0) && !finder(n - 7, n - 7)
    }
}
