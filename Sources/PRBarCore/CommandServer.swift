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
    private let limits: Limits
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    /// El archivo del socket que creó este servidor (`stop` no borra el de otra app).
    private var socketIdentity: FileIdentity?
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: LineConnection] = [:]

    /// Lo que un cliente puede ocupar de la app.
    public struct Limits: Sendable {
        /// Cuánto puede trabarse una escritura (un cliente que no lee) antes de cortarlo.
        public var sendTimeout: TimeInterval
        /// Cuánto se espera el `hello` de una conexión nueva. Después no hay plazo (`prbar` puede esperar a `$EDITOR`).
        public var helloTimeout: TimeInterval
        /// Conexiones abiertas a la vez; la siguiente recibe un error.
        public var maxConnections: Int
        /// El largo máximo de un pedido (`prbar` nunca manda líneas grandes).
        public var maxLine: Int

        public init(sendTimeout: TimeInterval = 10, helloTimeout: TimeInterval = 5, maxConnections: Int = 32,
                    maxLine: Int = 1024 * 1024) {
            self.sendTimeout = sendTimeout
            self.helloTimeout = helloTimeout
            self.maxConnections = maxConnections
            self.maxLine = maxLine
        }
    }

    public init(socketURL: URL, appVersion: String, allowedUID: uid_t = getuid(), limits: Limits = Limits(),
                handler: @escaping Handler) {
        self.socketURL = socketURL
        self.appVersion = appVersion
        self.allowedUID = allowedUID
        self.limits = limits
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
        let (fd, identity) = try UnixSocket.listen(path: socketURL.path)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "PRBar.CommandServer"))
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Darwin.close(fd) }
        locked {
            listenFD = fd
            socketIdentity = identity
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
        let (source, open, identity) = locked { () -> (DispatchSourceRead?, [LineConnection], FileIdentity?) in
            let source = acceptSource
            let open = Array(connections.values)
            let identity = socketIdentity
            acceptSource = nil
            connections = [:]
            socketIdentity = nil
            return (source, open, identity)
        }
        source?.cancel()
        open.forEach { $0.close() }
        // Solo el socket propio: si otra app lo reemplazó, sigue siendo suyo.
        if let identity, FileIdentity(path: socketURL.path) == identity {
            unlink(socketURL.path)
        }
    }

    private func acceptPending() {
        let listening = locked { listenFD }
        while true {
            let fd = accept(listening, nil, nil)
            guard fd >= 0 else { return }
            // Los sockets aceptados heredan O_NONBLOCK: se leen bloqueando, cada uno en su hilo.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            UnixSocket.noSigPipe(fd)
            UnixSocket.setTimeout(fd, SO_SNDTIMEO, seconds: limits.sendTimeout)
            UnixSocket.setTimeout(fd, SO_RCVTIMEO, seconds: limits.helloTimeout)
            let connection = LineConnection(fd: fd, maxLine: limits.maxLine)
            let refusal: CommandFailure? = if UnixSocket.peerUID(fd) != allowedUID {
                CommandFailure(.unauthorized, "Only the user running PRBar can use its socket.")
            } else if locked({ connections.count }) >= limits.maxConnections {
                CommandFailure(.failed, "Too many prbar connections are open. Try again when some finish.")
            } else {
                nil
            }
            if let refusal {
                try? connection.write(CommandProtocol.line(CommandResponse.failure(id: 0, refusal)))
                connection.close()
                continue
            }
            locked { connections[ObjectIdentifier(connection)] = connection }
            Thread.detachNewThread { [weak self] in self?.serve(connection) }
        }
    }

    /// Solo el id de un pedido que no se pudo leer entero.
    private struct RequestID: Decodable {
        let id: Int
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
        UnixSocket.setTimeout(connection.fd, SO_RCVTIMEO, seconds: 0)

        var tasks: [Task<Void, Never>] = []
        let handler = self.handler
        // Los eventos y las respuestas salen por acá: el handler (main actor) nunca espera al cliente.
        let outbound = OutboundQueue(connection: connection)
        while let line = connection.readLine() {
            guard let request = try? CommandProtocol.decode(CommandRequest.self, line: line) else {
                // Con el id, el cliente recibe el error en vez de esperar para siempre (p. ej. un `prbar` más nuevo
                // que manda un comando que esta app no conoce).
                let response = if let id = try? CommandProtocol.decode(RequestID.self, line: line).id {
                    CommandResponse.failure(id: id, .unknownCommand(app: appVersion))
                } else {
                    CommandResponse.failure(id: 0, CommandFailure(.invalidUsage, "Couldn’t read the request."))
                }
                outbound.send(response)
                continue
            }
            tasks.append(Task {
                let id = request.id
                let result = await handler(request.command) { event in
                    outbound.send(event: event, id: id)
                }
                switch result {
                case .success(let value): outbound.send(.success(id: id, value))
                case .failure(let failure): outbound.send(.failure(id: id, failure))
                }
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

    /// `protocolVersion` y `expectedUID` solo cambian en los tests.
    public static func connect(socketURL: URL, clientVersion: String, protocolVersion: Int = CommandProtocol.version,
                               expectedUID: uid_t = getuid()) throws -> CommandClient {
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: socketURL.path)
        } catch {
            throw ConnectError.unavailable(error.localizedDescription)
        }
        // Un socket en una ruta compartida (`PRBAR_SOCKET` en /tmp) podría ser de otro usuario: no se le manda nada.
        guard UnixSocket.peerUID(fd) == expectedUID else {
            Darwin.close(fd)
            throw CommandFailure(.unauthorized, "The socket at \(socketURL.path) belongs to another user’s process.")
        }
        let connection = LineConnection(fd: fd, maxLine: LineConnection.maxResponseLine)
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
            guard let response = try? CommandProtocol.decode(CommandResponse.self, line: line) else { continue }
            // id 0 = la app no pudo leer el pedido: no va a llegar otra respuesta.
            if response.id == 0, let error = response.error { throw error }
            guard response.id == id else { continue }
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
