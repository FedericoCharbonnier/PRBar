import Foundation
import PRBarCore

/// `/tmp/prbar-<8 hex>/s.sock`: `sun_path` admite 104 bytes y `$TMPDIR` es demasiado largo.
func shortSocketURL() throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp/prbar-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("s.sock")
}

/// Borra la carpeta de `shortSocketURL()`.
func removeSocketDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

private func permissions(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private func echoServer(_ url: URL, allowedUID: uid_t = getuid(), events: [CommandEvent] = []) throws -> CommandServer {
    let server = CommandServer(socketURL: url, appVersion: "9.9.9", allowedUID: allowedUID) { command, sink in
        events.forEach(sink)
        return .success(.object(["echo": .string(command.name.rawValue)]))
    }
    try server.start()
    return server
}

/// La CLI bloquea su hilo: en los tests corre fuera del hilo principal.
private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached { try body() }.value
}

enum CommandServerTests {
    static let cases: [TestCase] = [
        TestCase("socket: carpeta 0700 y socket 0600") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = try echoServer(url)
            defer { server.stop() }
            try expectEqual(try permissions(url.deletingLastPathComponent()), 0o700)
            try expectEqual(try permissions(url), 0o600)
        },
        TestCase("socket: hello, pedido y respuesta") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = try echoServer(url)
            defer { server.stop() }
            let (version, result) = try await offMain { () -> (String, JSONValue) in
                let client = try CommandClient.connect(socketURL: url, clientVersion: "1.0.0")
                defer { client.close() }
                return (client.appVersion, try client.send(.refresh))
            }
            try expectEqual(version, "9.9.9")
            try expectEqual(result, .object(["echo": .string("refresh")]))
        },
        TestCase("socket: varios pedidos por la misma conexión y eventos antes de la respuesta") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = try echoServer(url, events: [.progress(message: "a"), .text(delta: "b")])
            defer { server.stop() }
            let (events, second) = try await offMain { () -> ([CommandEvent], JSONValue) in
                let client = try CommandClient.connect(socketURL: url, clientVersion: "1.0.0")
                defer { client.close() }
                var events: [CommandEvent] = []
                _ = try client.send(.status) { events.append($0) }
                return (events, try client.send(.quit))
            }
            try expectEqual(events, [.progress(message: "a"), .text(delta: "b")])
            try expectEqual(second, .object(["echo": .string("quit")]))
        },
        TestCase("socket: versión de protocolo distinta → protocolMismatch") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = try echoServer(url)
            defer { server.stop() }
            let error = try await expectThrows {
                _ = try await offMain { try CommandClient.connect(socketURL: url, clientVersion: "2.0.0", protocolVersion: 99) }
            }
            try expectEqual(error as? CommandFailure, .protocolMismatch(cli: "2.0.0", app: "9.9.9"))
        },
        TestCase("socket: otro usuario → unauthorized") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = try echoServer(url, allowedUID: getuid() + 1)
            defer { server.stop() }
            let error = try await expectThrows {
                _ = try await offMain { try CommandClient.connect(socketURL: url, clientVersion: "1.0.0") }
            }
            try expectEqual((error as? CommandFailure)?.code, .unauthorized)
        },
        TestCase("socket: sin app → ConnectError.unavailable") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let error = try await expectThrows {
                _ = try await offMain { try CommandClient.connect(socketURL: url, clientVersion: "1.0.0") }
            }
            guard case .unavailable? = error as? CommandClient.ConnectError else {
                throw TestFailure(description: "esperaba unavailable, fue \(error)")
            }
        },
        TestCase("socket: si el cliente se va, se cancela lo que esperaba") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let cancelled = Flag()
            let server = CommandServer(socketURL: url, appVersion: "9.9.9") { _, _ in
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                cancelled.set()
                return .failure(CommandFailure(.cancelled, "Canceled."))
            }
            try server.start()
            defer { server.stop() }
            let client = try await offMain { try CommandClient.connect(socketURL: url, clientVersion: "1.0.0") }
            let sending = Task.detached { _ = try? client.send(.reviewStart(pr: "a#1", wait: true)) }
            try await Task.sleep(for: .milliseconds(200))
            client.close()
            _ = await sending.value
            for _ in 0..<100 where !cancelled.isSet { try await Task.sleep(for: .milliseconds(20)) }
            try expect(cancelled.isSet)
        },
        TestCase("socket: stop borra el socket") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = try echoServer(url)
            server.stop()
            try expect(!FileManager.default.fileExists(atPath: url.path))
        },
    ]
}
