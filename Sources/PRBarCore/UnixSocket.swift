import Darwin
import Foundation

public struct SocketError: Error, Equatable, LocalizedError {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }

    static func last(_ operation: String) -> SocketError {
        SocketError(operation: operation, code: errno)
    }

    public var errorDescription: String? {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

/// Dispositivo + inodo de un archivo: distingue el socket propio de uno que otra app creó en la misma ruta.
struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

/// Lo mínimo de sockets Unix (`AF_UNIX`, `SOCK_STREAM`) que usan `CommandServer` y `CommandClient`.
enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var result = sockaddr_un()
        result.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: result.sun_path)
        guard bytes.count < capacity else {
            throw SocketError(operation: "socket path too long (\(bytes.count) bytes)", code: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &result.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        result.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return result
    }

    /// Escucha en `path` con permisos 0600 (la carpeta ya es 0700, así que nadie más llega antes del `chmod`). Si
    /// hay un socket viejo sin nadie escuchando lo reemplaza; si otra app contesta en esa ruta, no se la saca
    /// (`EADDRINUSE`). Devuelve también la identidad del archivo creado, para que `stop` borre solo el suyo.
    static func listen(path: String) throws -> (fd: Int32, identity: FileIdentity?) {
        var addr = try address(path)
        if let live = try? connect(path: path) {
            close(live)
            throw SocketError(operation: "another PRBar is already listening on \(path)", code: EADDRINUSE)
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.last("socket") }
        // Las conexiones aceptadas lo heredan: un `setsockopt` sobre una cuyo cliente ya cerró falla (EINVAL) y
        // escribirle mataría a la app con SIGPIPE.
        noSigPipe(fd)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let error = SocketError.last("bind")
            close(fd)
            throw error
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            let error = SocketError.last("listen")
            close(fd)
            throw error
        }
        return (fd, FileIdentity(path: path))
    }

    static func connect(path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.last("socket") }
        // Antes de conectar: si la app corta enseguida (uid ajeno), después ya no se puede poner.
        noSigPipe(fd)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = SocketError.last("connect")
            close(fd)
            throw error
        }
        return fd
    }

    /// Escribir en un socket cerrado devuelve EPIPE en vez de matar el proceso.
    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// `SO_SNDTIMEO`: un `write` que no avanza en `seconds` falla (EAGAIN) en vez de bloquear para siempre (un
    /// cliente que dejó de leer no traba a la app). `SO_RCVTIMEO`: lo mismo para `read`. `0` = sin plazo.
    static func setTimeout(_ fd: Int32, _ option: Int32, seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// El uid del proceso del otro lado (spec C.2: solo el del usuario).
    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }
}

/// Un extremo del socket que lee y escribe líneas. `readLine` se llama desde un solo hilo; `write` y `close` son
/// seguros desde varios.
///
/// El fd vive mientras alguien lo usa: `close` lo marca cerrado y hace `shutdown` (despierta un `read`/`write`
/// bloqueado), pero el `close(2)` real lo hace el último `read`/`write` en curso al terminar. Después de `close`,
/// `write` lanza `EBADF` y `readLine` devuelve nil: nunca se escribe en un número de fd que el kernel ya le dio a
/// otra conexión o a un archivo.
final class LineConnection: @unchecked Sendable {
    /// Lo más largo que acepta la CLI de una respuesta (un diff, el historial).
    static let maxResponseLine = 16 * 1024 * 1024

    let fd: Int32
    /// Una línea más larga se considera un error y corta la conexión.
    private let maxLine: Int
    private var buffer = Data()
    /// Hasta dónde ya se buscó `\n` en `buffer`: una línea larga no se recorre de nuevo con cada pedazo.
    private var scanned = 0
    private let writeLock = NSLock()
    /// Protege `closed`, `users` y el `close(2)` del fd.
    private let stateLock = NSLock()
    private var closed = false
    /// Lecturas y escrituras en curso sobre `fd`.
    private var users = 0

    init(fd: Int32, maxLine: Int) {
        self.fd = fd
        self.maxLine = maxLine
    }

    var isClosed: Bool { stateLock.withLock { closed } }

    /// Reserva el fd para una operación; false si ya se cerró.
    private func acquire() -> Bool {
        stateLock.withLock {
            guard !closed else { return false }
            users += 1
            return true
        }
    }

    /// Termina una operación; si se cerró mientras tanto y era la última, cierra el fd.
    private func release() {
        stateLock.withLock {
            users -= 1
            if closed && users == 0 { Darwin.close(fd) }
        }
    }

    /// La próxima línea (sin `\n`), o `nil` si el otro extremo cerró (o se cerró este).
    func readLine() -> String? {
        while true {
            if let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                defer {
                    buffer.removeSubrange(buffer.startIndex...newline)
                    scanned = 0
                }
                return String(decoding: line, as: UTF8.self)
            }
            scanned = buffer.count
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            guard acquire() else { return nil }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            let readErrno = errno
            release()
            if count < 0 && readErrno == EINTR { continue }
            // 0 = el otro lado cerró; -1 = error o `SO_RCVTIMEO` vencido (sin hello a tiempo).
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
            guard buffer.count <= maxLine else { return nil }
        }
    }

    func write(_ line: String) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard acquire() else { throw SocketError(operation: "write", code: EBADF) }
        defer { release() }
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if written < 0 {
                if errno == EINTR { continue }
                throw SocketError.last("write")
            }
            offset += written
        }
    }

    func close() {
        stateLock.withLock {
            guard !closed else { return }
            closed = true
            shutdown(fd, SHUT_RDWR)
            if users == 0 { Darwin.close(fd) }
        }
    }
}

/// Lo que la app le manda a un cliente, sin bloquear a quien lo manda (el main actor): un hilo aparte escribe en
/// orden. Si el cliente lee más lento de lo que llegan los eventos, se juntan: el texto del chat se concatena, el
/// progreso se queda con el último y, pasado `maxPending`, el progreso nuevo se descarta. Las respuestas finales
/// siempre se mandan. Si una escritura falla (cliente ido o trabado más que el `SO_SNDTIMEO`), cierra la conexión.
final class OutboundQueue: @unchecked Sendable {
    static let maxPending = 256

    private enum Pending {
        case event(id: Int, CommandEvent)
        case response(CommandResponse)

        var line: String? {
            switch self {
            case .event(let id, let event): try? CommandProtocol.line(CommandResponse.event(id: id, event))
            case .response(let response): try? CommandProtocol.line(response)
            }
        }
    }

    private let connection: LineConnection
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var draining = false
    private var failed = false
    private let queue = DispatchQueue(label: "PRBar.CommandServer.outbound")

    init(connection: LineConnection) {
        self.connection = connection
    }

    func send(event: CommandEvent, id: Int) {
        enqueue { pending in
            if case .event(let lastID, let last)? = pending.last, lastID == id {
                switch (last, event) {
                case (.text(let a), .text(let b)):
                    pending[pending.count - 1] = .event(id: id, .text(delta: a + b))
                    return
                case (.progress, .progress):
                    pending[pending.count - 1] = .event(id: id, event)
                    return
                default: break
                }
            }
            if case .progress = event, pending.count >= Self.maxPending { return }
            pending.append(.event(id: id, event))
        }
    }

    func send(_ response: CommandResponse) {
        enqueue { $0.append(.response(response)) }
    }

    private func enqueue(_ change: (inout [Pending]) -> Void) {
        lock.lock()
        guard !failed else { return lock.unlock() }
        change(&pending)
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty, !failed else {
                draining = false
                lock.unlock()
                return
            }
            let next = pending.removeFirst()
            lock.unlock()
            guard let line = next.line else { continue }
            do {
                try connection.write(line)
            } catch {
                lock.lock()
                failed = true
                pending = []
                draining = false
                lock.unlock()
                connection.close()
                return
            }
        }
    }
}
