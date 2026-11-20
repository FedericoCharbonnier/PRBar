import Foundation
import Observation
import PRBarRemoteKit
import PRBarWire

/// Something holding this iPhone's pairing secrets (the keychain): wiped on revoke and unpair.
public protocol CredentialWiping: Sendable {
    func wipe() throws
}

/// The connection's life cycle (spec R.3): connects in the foreground, leaves 30 s after going to the background (no
/// background connections: pushes cover that), and turns transport events into app state.
@MainActor @Observable
public final class RemoteConnection {
    public enum State: Equatable, Sendable {
        case unpaired
        case connecting
        case online
        case macOffline(since: Date?)
        case relayUnreachable
        /// The Mac removed this iPhone (an in-session, authenticated `bye(revoked)`). Keys and cache are gone.
        case revoked(macName: String?)
        case incompatible(RemoteHello.Incompatibility)
    }

    public private(set) var state: State
    public private(set) var macName: String?
    /// The Mac's `presencePolicy` for this device ("Require Face ID for merge, push, approve and tests").
    public private(set) var requirePresence = true

    public let transport: any RemoteTransport
    public let store: AppStore
    @ObservationIgnored private let credentials: (any CredentialWiping)?
    @ObservationIgnored private let backgroundGrace: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var topicCounts: [String: Int] = [:]
    @ObservationIgnored private var chatHandlers: [String: (String) -> Void] = [:]

    public init(transport: any RemoteTransport, store: AppStore, credentials: (any CredentialWiping)?,
                paired: Bool, macName: String?, backgroundGrace: Duration = .seconds(30),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.transport = transport
        self.store = store
        self.credentials = credentials
        self.macName = macName
        self.backgroundGrace = backgroundGrace
        self.sleep = sleep
        state = paired ? .connecting : .unpaired
    }

    /// Starts listening to the transport. Call once.
    public func start() {
        guard listener == nil else { return }
        let stream = transport.events
        listener = Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Life cycle

    public func enterForeground() async {
        backgroundTask?.cancel()
        backgroundTask = nil
        guard canConnect else { return }
        if state != .online { setState(.connecting) }
        await transport.connect()
    }

    public func enterBackground() {
        guard canConnect else { return }
        backgroundTask?.cancel()
        let transport = transport
        let sleep = sleep
        let grace = backgroundGrace
        backgroundTask = Task {
            do { try await sleep(grace) } catch { return }
            guard !Task.isCancelled else { return }
            await transport.disconnect()
        }
    }

    /// Waits for a scheduled background disconnect (tests).
    public func settleBackground() async {
        await backgroundTask?.value
    }

    /// Pairing finished: from now on the app connects.
    public func didPair(macName: String) {
        self.macName = macName
        setState(.connecting)
    }

    private var canConnect: Bool {
        switch state {
        case .unpaired, .revoked: false
        default: true
        }
    }

    // MARK: Topics

    /// Screens retain the topics they show; the set always includes `home`.
    public func retain(_ topic: String) async {
        topicCounts[topic, default: 0] += 1
        if topicCounts[topic] == 1 { await resubscribe() }
    }

    public func release(_ topic: String) async {
        guard let count = topicCounts[topic] else { return }
        if count <= 1 { topicCounts[topic] = nil } else { topicCounts[topic] = count - 1 }
        if topicCounts[topic] == nil { await resubscribe() }
    }

    public var topics: [String] { [Topic.home] + topicCounts.keys.filter { $0 != Topic.home }.sorted() }

    private func resubscribe() async {
        guard state == .online else { return }
        await transport.subscribe(topics)
    }

    // MARK: Chat deltas (a chat started on the Mac)

    public func onChatDelta(pr: String, _ handler: @escaping (String) -> Void) {
        chatHandlers[pr] = handler
    }

    public func removeChatHandler(pr: String) {
        chatHandlers[pr] = nil
    }

    // MARK: Unpair

    /// "Unpair this iPhone": tells the Mac, then forgets everything locally.
    public func unpair() async {
        await transport.unpair()
        await transport.disconnect()
        forget()
        setState(.unpaired)
    }

    private func forget() {
        try? credentials?.wipe()
        store.wipe()
        topicCounts = [:]
    }

    // MARK: Events

    func handle(_ event: TransportEvent) async {
        switch event {
        case .link(let link):
            await handle(link)
        case .hello(let name):
            if let name { macName = name }
        case .state(let update):
            store.apply(update)
        case .chatDelta(let pr, let text):
            chatHandlers[pr]?(text)
        case .presencePolicy(let required):
            requirePresence = required
        }
    }

    private func handle(_ link: LinkState) async {
        guard canConnect else { return }
        switch link {
        case .connecting:
            setState(.connecting)
        case .online:
            store.beginSession()
            setState(.online)
            await transport.subscribe(topics)
        case .macOffline(let since):
            setState(.macOffline(since: since))
            if let update = try? await transport.fetchMailbox() {
                store.applyMailbox(update)
            }
        case .relayUnreachable, .relayRejected:
            // A close code from the relay proves nothing (M3): show a connection problem with Try Again.
            setState(.relayUnreachable)
        case .revoked:
            forget()
            setState(.revoked(macName: macName))
        case .incompatible(let reason):
            setState(.incompatible(reason))
        }
    }

    private func setState(_ new: State) {
        state = new
        switch new {
        case .online: store.link = .online
        case .connecting, .unpaired: store.link = .connecting
        case .macOffline(let since): store.link = .macOffline(since: since)
        case .relayUnreachable: store.link = .relayUnreachable
        case .revoked: store.link = .revoked
        case .incompatible(let reason): store.link = .incompatible(reason)
        }
    }

    // MARK: Copy

    public static func message(for reason: RemoteHello.Incompatibility) -> String {
        switch reason {
        case .updateMac: "Update PRBar on your Mac"
        case .updateIPhone: "Update PRBar on this iPhone"
        }
    }
}
