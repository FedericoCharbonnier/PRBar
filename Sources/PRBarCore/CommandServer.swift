import Darwin
import Foundation

/// El socket de la app (spec C.2). Cada conexión: `getpeereid` (solo el uid del usuario), `hello` con la versión
/// del protocolo y después pedidos `CommandRequest`, cada uno en su `Task`. Si el cliente se desconecta se cancelan
/// sus tareas (las esperas de `--wait` terminan; lo que no debe cortarse, como publicar, corre aparte).
public final class CommandServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AppCommand, @escaping CommandEventSink) async -> Result<JSONValue, CommandFailure>

    private let socketURL: URL
    private let appVersion: String
    private let allowedUID: uid_t
    private let handler: Handler
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: LineConnection] = [:]

    public init(socketURL: URL, appVersion: String, allowedUID: uid_t = getuid(), handler: @escaping Handler) {
        self.socketURL = socketURL
        self.appVersion = appVersion
        self.allowedUID = allowedUID
        self.handler = handler
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func start() throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.secure(directory)
        let fd = try UnixSocket.listen(path: socketURL.path)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "PRBar.CommandServer"))
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Darwin.close(fd) }
        locked {
            listenFD = fd
            acceptSource = source
        }
        source.resume()
    }

    /// La carpeta del socket tiene que ser del usuario y queda en 0700 (spec C.2).
    static func secure(_ directory: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        if let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value, owner != getuid() {
            throw SocketError(operation: "\(directory.path) belongs to another user", code: EPERM)
        }
        guard chmod(directory.path, 0o700) == 0 else { throw SocketError.last("chmod") }
    }

    public func stop() {
        let (source, open) = locked { () -> (DispatchSourceRead?, [LineConnection]) in
            let source = acceptSource
            let open = Array(connections.values)
            acceptSource = nil
            connections = [:]
            return (source, open)
        }
        source?.cancel()
        open.forEach { $0.close() }
        unlink(socketURL.path)
    }

    private func acceptPending() {
        let listening = locked { listenFD }
        while true {
            let fd = accept(listening, nil, nil)
            guard fd >= 0 else { return }
            // Los sockets aceptados heredan O_NONBLOCK: se leen bloqueando, cada uno en su hilo.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            UnixSocket.noSigPipe(fd)
            let connection = LineConnection(fd: fd)
            guard UnixSocket.peerUID(fd) == allowedUID else {
                let failure = CommandFailure(.unauthorized, "Only the user running PRBar can use its socket.")
                try? connection.write(CommandProtocol.line(CommandResponse.failure(id: 0, failure)))
                connection.close()
                continue
            }
            locked { connections[ObjectIdentifier(connection)] = connection }
            Thread.detachNewThread { [weak self] in self?.serve(connection) }
        }
    }

    private func serve(_ connection: LineConnection) {
        defer {
            _ = locked { connections.removeValue(forKey: ObjectIdentifier(connection)) }
            connection.close()
        }
        guard let first = connection.readLine(),
              let hello = try? CommandProtocol.decode(HelloMessage.self, line: first) else {
            let failure = CommandFailure(.invalidUsage, "Expected a hello message.")
            try? connection.write(CommandProtocol.line(CommandResponse.failure(id: 0, failure)))
            return
        }
        guard hello.hello.protocolVersion == CommandProtocol.version else {
            let failure = CommandFailure.protocolMismatch(cli: hello.hello.version, app: appVersion)
            try? connection.write(CommandProtocol.line(CommandResponse.failure(id: 0, failure)))
            return
        }
        let answer = HelloMessage(hello: Hello(protocolVersion: CommandProtocol.version, version: appVersion))
        guard (try? connection.write(CommandProtocol.line(answer))) != nil else { return }

        var tasks: [Task<Void, Never>] = []
        let handler = self.handler
        while let line = connection.readLine() {
            guard let request = try? CommandProtocol.decode(CommandRequest.self, line: line) else {
                let failure = CommandFailure(.invalidUsage, "Couldn't read the request.")
                try? connection.write(CommandProtocol.line(CommandResponse.failure(id: 0, failure)))
                continue
            }
            tasks.append(Task {
                let id = request.id
                let result = await handler(request.command) { event in
                    try? connection.write(CommandProtocol.line(CommandResponse.event(id: id, event)))
                }
                let response: CommandResponse = switch result {
                case .success(let value): .success(id: id, value)
                case .failure(let failure): .failure(id: id, failure)
                }
                try? connection.write(CommandProtocol.line(response))
            })
        }
        tasks.forEach { $0.cancel() }
    }
}

/// El lado de la CLI: conecta, saluda y manda comandos de a uno, bloqueando el hilo que lo llama.
public final class CommandClient {
    public enum ConnectError: Error, Equatable {
        /// No hay nadie escuchando (la app no está corriendo) o cortó la conexión.
        case unavailable(String)
    }

    private let connection: LineConnection
    public let appVersion: String
    private var nextID = 1

    private init(connection: LineConnection, appVersion: String) {
        self.connection = connection
        self.appVersion = appVersion
    }

    /// `protocolVersion` solo cambia en los tests.
    public static func connect(socketURL: URL, clientVersion: String,
                               protocolVersion: Int = CommandProtocol.version) throws -> CommandClient {
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: socketURL.path)
        } catch {
            throw ConnectError.unavailable(error.localizedDescription)
        }
        let connection = LineConnection(fd: fd)
        // Si la app ya contestó con un error (uid ajeno), escribir puede fallar: igual se lee su respuesta.
        try? connection.write(CommandProtocol.line(HelloMessage(hello: Hello(protocolVersion: protocolVersion,
                                                                            version: clientVersion))))
        guard let line = connection.readLine() else {
            connection.close()
            throw ConnectError.unavailable("PRBar closed the connection.")
        }
        if let hello = try? CommandProtocol.decode(HelloMessage.self, line: line) {
            return CommandClient(connection: connection, appVersion: hello.hello.version)
        }
        connection.close()
        if let response = try? CommandProtocol.decode(CommandResponse.self, line: line), let error = response.error {
            throw error
        }
        throw ConnectError.unavailable("Unexpected answer from PRBar.")
    }

    /// Manda `command` y espera la respuesta final; los eventos van a `onEvent`. Un error de la app se lanza como
    /// `CommandFailure`.
    public func send(_ command: AppCommand, onEvent: (CommandEvent) -> Void = { _ in }) throws -> JSONValue {
        let id = nextID
        nextID += 1
        do {
            try connection.write(CommandProtocol.line(CommandRequest(id: id, command: command)))
        } catch {
            throw ConnectError.unavailable(error.localizedDescription)
        }
        while let line = connection.readLine() {
            guard let response = try? CommandProtocol.decode(CommandResponse.self, line: line), response.id == id else {
                continue
            }
            if let event = response.event {
                onEvent(event)
                continue
            }
            if let error = response.error { throw error }
            return response.result ?? .null
        }
        throw ConnectError.unavailable("PRBar closed the connection.")
    }

    public func close() {
        connection.close()
    }
}
