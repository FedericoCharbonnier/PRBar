import Darwin
import Foundation

/// Un socket Unix crudo para los tests del protocolo: manda líneas que `CommandClient` nunca mandaría, hace de
/// cliente que no lee o de servidor que contesta lo que el test quiera.
final class RawSocket: @unchecked Sendable {
    let fd: Int32
    private var buffer = Data()
    /// Hasta dónde ya se buscó `\n` en `buffer` (las líneas largas no se recorren de nuevo con cada pedazo).
    private var scanned = 0

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func connect(_ url: URL) throws -> RawSocket {
        var addr = address(url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw TestFailure(description: "connect \(url.path): \(String(cString: strerror(errno)))")
        }
        return RawSocket(fd: fd)
    }

    /// Escucha en `url` (sin borrar nada antes) y devuelve el fd de escucha.
    static func listen(_ url: URL) throws -> Int32 {
        var addr = address(url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw TestFailure(description: "listen \(url.path): \(String(cString: strerror(errno)))")
        }
        return fd
    }

    /// Lee hasta `timeout` segundos (`nil` si el otro lado cerró o se venció el plazo).
    func readLine(timeout: TimeInterval = 10) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                scanned = 0
                return String(decoding: line, as: UTF8.self)
            }
            scanned = buffer.count
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(remaining * 1000)) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    @discardableResult
    func write(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    func writeLine(_ line: String) {
        write(line + "\n")
    }

    /// `true` si el otro lado cerró la conexión antes de `timeout`.
    func waitForClose(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count <= 0 { return true }
        }
        return false
    }

    func close() {
        Darwin.close(fd)
    }
}

/// El hello de un cliente con la versión de protocolo actual.
func helloLine(protocolVersion: Int) -> String {
    #"{"hello":{"protocolVersion":\#(protocolVersion),"version":"1.0.0"}}"#
}
