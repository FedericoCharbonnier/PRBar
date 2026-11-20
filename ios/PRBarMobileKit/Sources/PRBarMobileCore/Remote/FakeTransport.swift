import Foundation
import PRBarRemoteKit
import PRBarWire

/// An in-memory `RemoteTransport` for tests, previews and the demo mode: programmable responses per command name, a
/// record of what was sent (with its presence proof, built by the Kit's `PresenceProof.make` exactly as the live
/// transport will), and manual emission of state, chat deltas and link changes.
public final class FakeTransport: RemoteTransport, @unchecked Sendable {
    public struct Sent: Equatable, Sendable {
        public var command: RemoteCommand
        public var reqId: UInt64
        public var presence: PresenceProof?
        public var commandBytes: Data
    }

    public typealias Responder = @Sendable (RemoteCommand) throws -> JSONValue

    /// The Noise handshake hash the fake session pretends to have (presence proofs are bound to it).
    public let sessionHash = Data(repeating: 0x5A, count: 32)

    private let lock = NSLock()
    private var responders: [String: Responder] = [:]
    private var scriptedEvents: [String: [CommandEvent]] = [:]
    private var _sent: [Sent] = []
    private var _subscriptions: [[String]] = []
    private var _connects = 0
    private var _disconnects = 0
    private var _unpaired = false
    private var nextReqId: UInt64 = 1
    private var _mailbox: RemoteStateUpdate?
    private var linkOnConnect: LinkState?
    private let continuation: AsyncStream<TransportEvent>.Continuation
    public let events: AsyncStream<TransportEvent>

    /// `linkOnConnect`: what `connect()` reports (nil = nothing, the test drives the link by hand).
    public init(linkOnConnect: LinkState? = .online) {
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.linkOnConnect = linkOnConnect
    }

    // MARK: Programming

    public func respond(to name: String, with responder: @escaping Responder) {
        lock.withLock { responders[name] = responder }
    }

    public func respond<T: Encodable & Sendable>(to name: String, with value: T) {
        let json = (try? JSONValue(encoding: value)) ?? .null
        respond(to: name) { _ in json }
    }

    public func fail(_ name: String, _ failure: CommandFailure) {
        respond(to: name) { _ in throw failure }
    }

    /// Events (`progress`, `text`) sent before the result of `name`.
    public func script(_ name: String, events: [CommandEvent]) {
        lock.withLock { scriptedEvents[name] = events }
    }

    public func setMailbox(_ update: RemoteStateUpdate?) {
        lock.withLock { _mailbox = update }
    }

    public func setLinkOnConnect(_ link: LinkState?) {
        lock.withLock { linkOnConnect = link }
    }

    public func emit(_ event: TransportEvent) {
        continuation.yield(event)
    }

    public func emitState<T: Encodable>(_ topic: String, rev: Int, _ value: T) throws {
        emit(.state(RemoteStateUpdate(topic: topic, rev: rev, data: try JSONValue(encoding: value))))
    }

    // MARK: Inspection

    public var sent: [Sent] { lock.withLock { _sent } }
    public var sentCommands: [RemoteCommand] { sent.map(\.command) }
    public var subscriptions: [[String]] { lock.withLock { _subscriptions } }
    public var connectCount: Int { lock.withLock { _connects } }
    public var disconnectCount: Int { lock.withLock { _disconnects } }
    public var didUnpair: Bool { lock.withLock { _unpaired } }

    // MARK: RemoteTransport

    public func connect() async {
        let link = lock.withLock { () -> LinkState? in
            _connects += 1
            return linkOnConnect
        }
        if let link { emit(.link(link)) }
    }

    public func disconnect() async {
        lock.withLock { _disconnects += 1 }
    }

    public func subscribe(_ topics: [String]) async {
        lock.withLock { _subscriptions.append(topics) }
    }

    public func send(_ command: RemoteCommand, presence: (any PresenceSigner)?,
                     events: (@Sendable (CommandEvent) -> Void)?) async throws -> JSONValue {
        let reqId = lock.withLock { () -> UInt64 in
            defer { nextReqId += 1 }
            return nextReqId
        }
        let bytes = try command.commandBytes()
        var proof: PresenceProof?
        if let presence {
            // A signer that throws (Face ID cancelled) means nothing goes out.
            proof = try await PresenceProof.make(signer: presence, sessionHash: sessionHash, reqId: reqId,
                                                 commandBytes: bytes)
        }
        let (responder, scripted) = lock.withLock { () -> (Responder?, [CommandEvent]) in
            _sent.append(Sent(command: command, reqId: reqId, presence: proof, commandBytes: bytes))
            return (responders[command.name], scriptedEvents[command.name] ?? [])
        }
        for event in scripted { events?(event) }
        return try responder?(command) ?? .ok
    }

    public func fetchMailbox() async throws -> RemoteStateUpdate? {
        lock.withLock { _mailbox }
    }

    public func unpair() async {
        lock.withLock { _unpaired = true }
    }
}
