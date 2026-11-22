import CryptoKit
import Foundation

// La conexión con el relay (spec P.4), detrás de un protocolo: `WebSocketRelayLink` la real, `InMemoryRelay` en los
// tests. Quien la usa ya está autenticado cuando `connect()` vuelve.

public struct RelayReady: Equatable, Sendable {
    /// `online` u `offline`.
    public var mac: String
    public var since: Int

    public init(mac: String, since: Int) {
        self.mac = mac
        self.since = since
    }

    public var macOnline: Bool { mac == "online" }
}

/// El relay cerró la conexión (o no se pudo abrir).
public struct RelayClosed: Error, Equatable, Sendable {
    public var code: Int?
    public var reason: String

    public init(code: Int?, reason: String) {
        self.code = code
        self.reason = reason
    }
}

/// Con qué se presenta un cliente.
public enum RelayCredential: Sendable {
    /// La Mac (`client = "mac"`) o un teléfono (`client = deviceId`): firma Ed25519 del desafío.
    case signed(account: String, client: String, key: Curve25519.Signing.PrivateKey)
    /// Un teléfono emparejándose: `proof` = HMAC(`pairAuthKey`, `nonce`).
    case pairing(account: String, pairing: String, authKey: Data)

    /// La respuesta al `challenge`.
    public func auth(host: String, nonce: Data) throws -> RelayMessage {
        switch self {
        case .signed(let account, let client, let key):
            let sig = try key.signature(for: RelayAuth.message(host: host, account: account, client: client, nonce: nonce))
            return .auth(acct: account, client: client, sig: sig, pairing: nil, proof: nil)
        case .pairing(let account, let pairing, let authKey):
            return .auth(acct: account, client: "pair", sig: nil, pairing: pairing,
                         proof: PairingSecrets.proof(authKey: authKey, nonce: nonce))
        }
    }
}

public protocol RelayLink: AnyObject, Sendable {
    /// Conecta y se autentica. Falla con `RelayClosed` si el relay no la acepta.
    func connect() async throws -> RelayReady
    /// Encola un marco. El orden de llamada es el orden en el cable (el relay preserva FIFO por par).
    func send(_ message: RelayMessage) throws
    /// Los marcos que llegan después de `ready` (también los `pong`). Termina con `RelayClosed` cuando la conexión se
    /// cierra.
    var incoming: AsyncThrowingStream<RelayMessage, Error> { get }
    func close() async
}

public typealias RelayLinkFactory = @Sendable (RelayCredential) -> RelayLink

/// Cliente de WebSocket con `URLSessionWebSocketTask`. Subprotocolo `prbar-relay.v1`; solo `wss://`
/// salvo `allowInsecureTransportForTests`.
public final class WebSocketRelayLink: RelayLink, @unchecked Sendable {
    public static let subprotocol = "prbar-relay.v1"
    public static let maxFrame = 128 * 1024
    public static let defaultPingInterval: Duration = .seconds(20)

    private let host: String
    private let credential: RelayCredential
    private let allowInsecure: Bool
    private let session: URLSession
    /// `nil`: el link no manda `ping` solo (la Mac los manda desde `RemoteHost`, que además espera el `pong`).
    private let pingInterval: Duration?
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var outbound: AsyncStream<RelayMessage>.Continuation?
    private var workers: [Task<Void, Never>] = []
    private let incomingPair = AsyncThrowingStream<RelayMessage, Error>.makeStream(bufferingPolicy: .bufferingOldest(1_024))

    public var incoming: AsyncThrowingStream<RelayMessage, Error> { incomingPair.stream }

    /// `host`: `prbar.example.org` o `prbar.example.org:8443` (o `127.0.0.1:port` en los tests de integración).
    public init(host: String, credential: RelayCredential, allowInsecureTransportForTests: Bool = false,
                session: URLSession = .shared, pingInterval: Duration? = defaultPingInterval) {
        self.host = host
        self.credential = credential
        allowInsecure = allowInsecureTransportForTests
        self.session = session
        self.pingInterval = pingInterval
    }

    public static func factory(host: String, allowInsecureTransportForTests: Bool = false,
                               pingInterval: Duration? = defaultPingInterval) -> RelayLinkFactory {
        { credential in
            WebSocketRelayLink(host: host, credential: credential,
                               allowInsecureTransportForTests: allowInsecureTransportForTests, pingInterval: pingInterval)
        }
    }

    public func connect() async throws -> RelayReady {
        let scheme = allowInsecure ? "ws" : "wss"
        guard PairingQR.isValidHost(host, allowIP: allowInsecure), let url = URL(string: "\(scheme)://\(host)/v1/ws") else {
            throw RelayClosed(code: nil, reason: "Invalid relay host")
        }
        let task = session.webSocketTask(with: url, protocols: [Self.subprotocol])
        task.maximumMessageSize = Self.maxFrame
        lock.withLock { self.task = task }
        task.resume()
        do {
            // El desafío llega primero; el nombre del host firmado es el público (sin el puerto de un entrypoint).
            guard case .challenge(let nonce, _) = try await receive(task) else {
                throw RelayClosed(code: nil, reason: "Expected a challenge")
            }
            let signedHost = host.split(separator: ":").first.map(String.init) ?? host
            try await task.send(.string(try credential.auth(host: signedHost, nonce: nonce).text()))
            guard case .ready(let mac, let since) = try await receive(task) else {
                throw RelayClosed(code: nil, reason: "Expected ready")
            }
            startWorkers(task)
            return RelayReady(mac: mac, since: since)
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            throw closeError(task, error)
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) async throws -> RelayMessage {
        switch try await task.receive() {
        case .string(let text):
            guard text.utf8.count <= Self.maxFrame else { throw RelayClosed(code: 4413, reason: "Frame too large") }
            return try RelayMessage.decode(text)
        case .data:
            throw RelayClosed(code: nil, reason: "Unexpected binary frame")
        @unknown default:
            throw RelayClosed(code: nil, reason: "Unexpected frame")
        }
    }

    private func closeError(_ task: URLSessionWebSocketTask, _ error: Error) -> Error {
        if let closed = error as? RelayClosed { return closed }
        let code = task.closeCode.rawValue
        let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? error.localizedDescription
        return RelayClosed(code: code == 0 ? nil : code, reason: reason)
    }

    private func startWorkers(_ task: URLSessionWebSocketTask) {
        let (stream, continuation) = AsyncStream<RelayMessage>.makeStream(bufferingPolicy: .bufferingOldest(4_096))
        let incoming = incomingPair.continuation
        let reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await self?.receive(task)
                    guard let message else { return }
                    incoming.yield(message)
                } catch {
                    incoming.finish(throwing: self?.closeError(task, error) ?? error)
                    return
                }
            }
        }
        // Un solo escritor: el orden de `send` es el orden en el cable.
        let writer = Task {
            for await message in stream {
                guard let text = try? message.text() else { continue }
                do {
                    try await task.send(.string(text))
                } catch {
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        let pingInterval = pingInterval
        let pinger = pingInterval.map { interval in
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    if Task.isCancelled { return }
                    continuation.yield(.ping)
                }
            }
        }
        lock.withLock {
            outbound = continuation
            workers = [reader, writer] + (pinger.map { [$0] } ?? [])
        }
    }

    public func send(_ message: RelayMessage) throws {
        let text = try message.text()
        guard text.utf8.count <= Self.maxFrame else { throw RelayClosed(code: 4413, reason: "Frame too large") }
        guard let outbound = lock.withLock({ self.outbound }) else { throw RelayClosed(code: nil, reason: "Not connected") }
        switch outbound.yield(message) {
        case .enqueued: return
        // Cola llena (relay que no lee): mejor cortar que perder un marco y desordenar la sesión.
        case .dropped: throw RelayClosed(code: nil, reason: "Send queue full")
        case .terminated: throw RelayClosed(code: nil, reason: "Not connected")
        @unknown default: throw RelayClosed(code: nil, reason: "Not connected")
        }
    }

    public func close() async {
        let (task, workers, outbound) = lock.withLock { (self.task, self.workers, self.outbound) }
        outbound?.finish()
        workers.forEach { $0.cancel() }
        task?.cancel(with: .normalClosure, reason: nil)
        incomingPair.continuation.finish(throwing: RelayClosed(code: 1000, reason: "Closed"))
    }
}
