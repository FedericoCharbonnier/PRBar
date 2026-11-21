import Foundation
import PRBarRemoteKit
import PRBarWire

/// The link to the Mac as the phone sees it (spec R.3).
public enum LinkState: Equatable, Sendable {
    case connecting
    case online
    /// The relay says the Mac is not connected (asleep, off, or PRBar quit).
    case macOffline(since: Date?)
    case relayUnreachable
    /// The relay closed the socket with a code (4401, 4403, 4409, …). The relay is untrusted, so this is only ever a
    /// connection problem: it never deletes keys or unpairs (crypto review M3).
    case relayRejected(closeCode: Int)
    /// The Mac itself said so inside the encrypted session (`bye` with reason `revoked`, authenticated by Noise).
    /// The only remote event that deletes this iPhone's keys; the other is the user tapping Unpair.
    case revoked
    case incompatible(RemoteHello.Incompatibility)
}

/// What a transport pushes to the app besides command responses.
public enum TransportEvent: Equatable, Sendable {
    case link(LinkState)
    /// The Mac's `hello` (its name for the pill and Settings).
    case hello(macName: String?)
    case state(RemoteStateUpdate)
    case chatDelta(pr: String, text: String)
    case presencePolicy(requirePresence: Bool)
}

/// An APNs device token and the APNs environment it belongs to (`sandbox` for development-signed builds).
public struct PushRegistration: Equatable, Sendable {
    public enum Environment: String, Sendable { case sandbox, production }

    /// Lowercase hex, as the relay expects it.
    public var token: String
    public var environment: Environment

    public init(token: String, environment: Environment) {
        self.token = token
        self.environment = environment
    }

    public init(deviceToken: Data, environment: Environment) {
        self.init(token: deviceToken.map { String(format: "%02x", $0) }.joined(), environment: environment)
    }
}

/// The mailbox's `home` (spec P.9), opened: its mailbox revision (separate from the live `state` revisions, which count
/// per Mac session) and when the Mac wrote it (what "Last updated" shows; review M2).
public struct MailboxHome: Equatable, Sendable {
    public var rev: Int
    public var createdAt: Date
    public var data: JSONValue

    public init(rev: Int, createdAt: Date, data: JSONValue) {
        self.rev = rev
        self.createdAt = createdAt
        self.data = data
    }
}

/// Where the last mailbox revisions seen are kept across launches (the cache), so a relay can't replay an older blob
/// after the app restarts (review M2).
public protocol MailboxRevisionStore: Sendable {
    func loadMailboxRevisions() -> [String: Int]
    func saveMailboxRevisions(_ revisions: [String: Int])
}

/// How the phone talks to its Mac (spec R.3). `LiveTransport` (on `RemoteClient`, plan 17) implements it over the
/// relay; `FakeTransport` implements it for tests, previews and the demo mode.
///
/// Presence (spec P.8): the transport reserves the request id and knows the Noise `sessionHash`, so it builds the
/// `PresenceProof` itself by asking `presence` to sign `PresenceMessage.bytes(…)` right before sending. A signer that
/// throws (Face ID cancelled, key invalid) means nothing is sent.
public protocol RemoteTransport: AnyObject, Sendable {
    func connect() async
    func disconnect() async
    /// Replaces the subscribed topic set (`sub`).
    func subscribe(_ topics: [String]) async
    func send(_ command: AppCommand, presence: (any PresenceSigner)?,
              events: (@Sendable (CommandEvent) -> Void)?) async throws -> JSONValue
    /// The latest mailbox `home` blob, already opened (HPKE) and at most 7 days old, when the Mac is offline.
    func fetchMailbox() async throws -> MailboxHome?
    /// "Unpair this iPhone" (`unpair` frame).
    func unpair() async
    /// This iPhone's APNs token, for the relay (`apns` frame, spec P.4/P.9): the relay is the one that talks to Apple,
    /// with the Mac's encrypted payload. Needs the relay connection (the Mac may be offline).
    func registerPush(_ registration: PushRegistration) async throws
    var events: AsyncStream<TransportEvent> { get }
}

public extension RemoteTransport {
    func send(_ command: AppCommand) async throws -> JSONValue {
        try await send(command, presence: nil, events: nil)
    }
}
