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
        TestCase("socket: un comando que la app no conoce → error con el id del pedido") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = try echoServer(url)
            defer { server.stop() }
            let raw = try RawSocket.connect(url)
            defer { raw.close() }
            raw.writeLine(helloLine(protocolVersion: CommandProtocol.version))
            _ = raw.readLine()
            raw.writeLine(#"{"id":7,"command":{"someFutureCommand":{"x":1}}}"#)
            guard let line = raw.readLine() else { throw TestFailure(description: "sin respuesta") }
            let response = try CommandProtocol.decode(CommandResponse.self, line: line)
            try expectEqual(response.id, 7)
            try expectEqual(response.error?.code, .protocolMismatch)
            try expect(response.error?.message.contains("PRBar 9.9.9 doesn’t know this command") == true, line)
        },
        TestCase("socket: una línea que ni tiene id → error con id 0 y la conexión sigue") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = try echoServer(url)
            defer { server.stop() }
            let raw = try RawSocket.connect(url)
            defer { raw.close() }
            raw.writeLine(helloLine(protocolVersion: CommandProtocol.version))
            _ = raw.readLine()
            raw.writeLine("not json")
            let response = try CommandProtocol.decode(CommandResponse.self, line: raw.readLine() ?? "")
            try expectEqual(response.id, 0)
            try expectEqual(response.error?.code, .invalidUsage)
            raw.writeLine(try CommandProtocol.line(CommandRequest(id: 1, command: .status)))
            let next = try CommandProtocol.decode(CommandResponse.self, line: raw.readLine() ?? "")
            try expectEqual(next.id, 1)
        },
        TestCase("socket: el cliente no se cuelga si la app contesta un error con id 0") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let listening = try RawSocket.listen(url)
            defer { close(listening) }
            let fake = Thread {
                let peer = RawSocket(fd: accept(listening, nil, nil))
                _ = peer.readLine()
                peer.writeLine(#"{"hello":{"protocolVersion":\#(CommandProtocol.version),"version":"0.1.0"}}"#)
                _ = peer.readLine()
                peer.writeLine(try! CommandProtocol.line(CommandResponse.failure(id: 0, CommandFailure(.invalidUsage, "Couldn’t read the request."))))
                _ = peer.waitForClose(timeout: 10)
                peer.close()
            }
            fake.start()
            let error = try await expectThrows {
                _ = try await offMain {
                    let client = try CommandClient.connect(socketURL: url, clientVersion: "1.0.0")
                    defer { client.close() }
                    return try client.send(.status)
                }
            }
            try expectEqual((error as? CommandFailure)?.message, "Couldn’t read the request.")
        },
        TestCase("socket: un cliente que no lee no traba al que manda eventos; después recibe todo el texto y la respuesta") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let chunk = String(repeating: "x", count: 32 * 1024)
            let count = 400
            let handlerSeconds = Box<Double>(0)
            let server = CommandServer(socketURL: url, appVersion: "9.9.9") { @MainActor _, sink in
                let start = Date()
                for _ in 0..<count {
                    sink(.text(delta: chunk))
                    sink(.progress(message: "working"))
                }
                handlerSeconds.value = Date().timeIntervalSince(start)
                return .success(.string("done"))
            }
            try server.start()
            defer { server.stop() }
            let raw = try RawSocket.connect(url)
            defer { raw.close() }
            raw.writeLine(helloLine(protocolVersion: CommandProtocol.version))
            _ = raw.readLine()
            raw.writeLine(try CommandProtocol.line(CommandRequest(id: 3, command: .status)))
            // 12 MB de texto sin leer nada: el handler termina igual.
            for _ in 0..<100 where handlerSeconds.value == 0 { try await Task.sleep(for: .milliseconds(20)) }
            try expect(handlerSeconds.value > 0 && handlerSeconds.value < 1, "handler: \(handlerSeconds.value) s")
            let (text, final) = try await offMain { () -> (Int, CommandResponse?) in
                var text = 0
                while let line = raw.readLine() {
                    let response = try CommandProtocol.decode(CommandResponse.self, line: line)
                    if case .text(let delta)? = response.event { text += delta.count }
                    if response.ok != nil { return (text, response) }
                }
                return (text, nil)
            }
            try expectEqual(text, count * chunk.count)
            try expectEqual(final?.result, .string("done"))
        },
        TestCase("socket: un cliente trabado más que el timeout se desconecta y se cancela su pedido") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let cancelled = Flag()
            let server = CommandServer(socketURL: url, appVersion: "9.9.9", limits: .init(sendTimeout: 0.3)) { _, sink in
                let chunk = String(repeating: "y", count: 64 * 1024)
                while !Task.isCancelled {
                    sink(.progress(message: chunk + "\(Date().timeIntervalSince1970)"))
                    try? await Task.sleep(for: .milliseconds(5))
                }
                cancelled.set()
                return .failure(CommandFailure(.cancelled, "Canceled."))
            }
            try server.start()
            defer { server.stop() }
            let raw = try RawSocket.connect(url)
            defer { raw.close() }
            raw.writeLine(helloLine(protocolVersion: CommandProtocol.version))
            _ = raw.readLine()
            raw.writeLine(try CommandProtocol.line(CommandRequest(id: 1, command: .status)))
            for _ in 0..<250 where !cancelled.isSet { try await Task.sleep(for: .milliseconds(20)) }
            try expect(cancelled.isSet, "el servidor no cortó al cliente trabado")
        },
        TestCase("socket: una segunda app no le saca el socket a la que está corriendo") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let first = try echoServer(url)
            defer { first.stop() }
            let second = CommandServer(socketURL: url, appVersion: "2.0.0") { _, _ in .success(.null) }
            let error = try await expectThrows { try second.start() }
            try expectEqual((error as? SocketError)?.code, EADDRINUSE)
            second.stop()
            let version = try await offMain { () -> String in
                let client = try CommandClient.connect(socketURL: url, clientVersion: "1.0.0")
                defer { client.close() }
                return client.appVersion
            }
            try expectEqual(version, "9.9.9")
        },
        TestCase("socket: un cliente que conecta y corta enseguida no mata a la app (SIGPIPE)") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = try echoServer(url)
            defer { server.stop() }
            for _ in 0..<5 { try RawSocket.connect(url).close() }
            try await Task.sleep(for: .milliseconds(300))
            let version = try await offMain { () -> String in
                let client = try CommandClient.connect(socketURL: url, clientVersion: "1.0.0")
                defer { client.close() }
                return client.appVersion
            }
            try expectEqual(version, "9.9.9")
        },
        TestCase("socket: un socket viejo sin nadie escuchando se reemplaza") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            close(try RawSocket.listen(url))
            try expect(FileManager.default.fileExists(atPath: url.path))
            let server = try echoServer(url)
            defer { server.stop() }
            let version = try await offMain { () -> String in
                let client = try CommandClient.connect(socketURL: url, clientVersion: "1.0.0")
                defer { client.close() }
                return client.appVersion
            }
            try expectEqual(version, "9.9.9")
        },
        TestCase("socket: stop no borra el socket de otra app que lo reemplazó") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let old = try echoServer(url)
            try FileManager.default.removeItem(at: url)
            let current = CommandServer(socketURL: url, appVersion: "2.0.0") { _, _ in .success(.null) }
            try current.start()
            defer { current.stop() }
            old.stop()
            try expect(FileManager.default.fileExists(atPath: url.path), "stop borró el socket de la otra app")
            let version = try await offMain { () -> String in
                let client = try CommandClient.connect(socketURL: url, clientVersion: "1.0.0")
                defer { client.close() }
                return client.appVersion
            }
            try expectEqual(version, "2.0.0")
        },
        TestCase("socket: sin hello en el plazo, la app corta la conexión") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = CommandServer(socketURL: url, appVersion: "9.9.9", limits: .init(helloTimeout: 0.3)) { _, _ in .success(.null) }
            try server.start()
            defer { server.stop() }
            let raw = try RawSocket.connect(url)
            defer { raw.close() }
            let closed = try await offMain { raw.waitForClose(timeout: 3) }
            try expect(closed, "la conexión sin hello sigue abierta")
        },
        TestCase("socket: después del hello no hay plazo para el próximo pedido") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = CommandServer(socketURL: url, appVersion: "9.9.9", limits: .init(helloTimeout: 0.2)) { _, _ in .success(.string("ok")) }
            try server.start()
            defer { server.stop() }
            let result = try await offMain { () -> JSONValue in
                let client = try CommandClient.connect(socketURL: url, clientVersion: "1.0.0")
                defer { client.close() }
                Thread.sleep(forTimeInterval: 0.6)
                return try client.send(.status)
            }
            try expectEqual(result, .string("ok"))
        },
        TestCase("socket: una línea más larga que el límite corta la conexión") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = try echoServer(url)
            defer { server.stop() }
            let raw = try RawSocket.connect(url)
            defer { raw.close() }
            raw.writeLine(helloLine(protocolVersion: CommandProtocol.version))
            _ = raw.readLine()
            let closed = try await offMain { () -> Bool in
                // 2 MB sin salto de línea (el límite de un pedido es 1 MB).
                raw.write(String(repeating: "a", count: 2 * 1024 * 1024))
                return raw.waitForClose(timeout: 5)
            }
            try expect(closed, "la app siguió leyendo una línea de más de 1 MB")
        },
        TestCase("socket: con el máximo de conexiones abiertas, la siguiente recibe un error") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = CommandServer(socketURL: url, appVersion: "9.9.9", limits: .init(maxConnections: 2)) { _, _ in .success(.null) }
            try server.start()
            defer { server.stop() }
            let open = try (0..<2).map { _ in try RawSocket.connect(url) }
            defer { open.forEach { $0.close() } }
            try await Task.sleep(for: .milliseconds(200))
            let error = try await expectThrows {
                _ = try await offMain { try CommandClient.connect(socketURL: url, clientVersion: "1.0.0") }
            }
            try expect((error as? CommandFailure)?.message.contains("Too many") == true, "\(error)")
        },
        TestCase("socket: la CLI no habla con un socket de otro usuario") {
            let url = try shortSocketURL()
            defer { removeSocketDirectory(url) }
            let server = try echoServer(url)
            defer { server.stop() }
            let error = try await expectThrows {
                _ = try await offMain { try CommandClient.connect(socketURL: url, clientVersion: "1.0.0", expectedUID: getuid() + 1) }
            }
            try expectEqual((error as? CommandFailure)?.code, .unauthorized)
        },
        TestCase("socket: una carpeta del socket de otro usuario no se usa (ni se le cambian permisos)") {
            // /tmp es de root: `secure` tiene que rechazarla antes de tocarla.
            let url = URL(fileURLWithPath: "/tmp/prbar-\(UUID().uuidString.prefix(8)).sock")
            let server = CommandServer(socketURL: url, appVersion: "9.9.9") { _, _ in .success(.null) }
            let error = try await expectThrows { try server.start() }
            try expectEqual((error as? SocketError)?.code, EPERM)
            try expect(!FileManager.default.fileExists(atPath: url.path))
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
