import Foundation
import PRBarRemoteKit
import PRBarWire

/// The link to the Mac through the relay (spec P, R.3): RemoteKit's `RemoteClient` (relay login, Noise KK session,
/// requests with deadlines, presence proofs, topics, `chatDelta`, mailbox) behind the app's `RemoteTransport` seam.
///
/// The client is built from the keychain when the app connects, and rebuilt when the pairing changes (a new Mac, or
/// after a revoke and a new pairing). Every change of the client's status becomes a `LinkState`; while the app wants
/// to be connected (between `connect()` and `disconnect()`), a dropped relay connection is retried with a backoff and a
/// Mac that comes back online is reconnected right away. A relay close code is only ever a connection problem
/// (`relayRejected`, crypto review M3): keys are wiped only after an in-session `bye(revoked)` (`LinkState.revoked`).
public final class LiveTransport: RemoteTransport, Sendable {
    public typealias Session = @Sendable () -> (mac: PairedMac, keys: DeviceKeys)?
    public typealias ClientFactory = @Sendable (PairedMac, DeviceKeys) -> RemoteClient

    public let events: AsyncStream<TransportEvent>
    private let core: Core

    /// `session`: what the keychain holds now. `makeClient`: a `RemoteClient` for that pairing (the app uses
    /// `LiveTransport.clientFactory`). `retryDelay`: the wait before reconnect attempt `n` (1-based).
    /// `mailboxRevisions`: where the last mailbox revisions are kept across launches (the cache).
    public init(session: @escaping Session, makeClient: @escaping ClientFactory,
                retryDelay: @escaping @Sendable (Int) -> Duration = LiveTransport.standardRetryDelay,
                mailboxRevisions: (any MailboxRevisionStore)? = nil) {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .bufferingNewest(256))
        events = stream
        self.mailboxRevisions = mailboxRevisions
        core = Core(session: session, makeClient: makeClient, retryDelay: retryDelay, emit: { continuation.yield($0) })
    }

    private let mailboxRevisions: (any MailboxRevisionStore)?

    /// 1, 2, 4, 8, 16, then every 30 s.
    public static let standardRetryDelay: @Sendable (Int) -> Duration = { attempt in
        .seconds(min(30, 1 << min(max(attempt - 1, 0), 5)))
    }

    /// `RemoteClient`s that talk to the pairing's relay host over `WebSocketRelayLink`.
    public static func clientFactory(configuration: RemoteClient.Configuration,
                                     allowInsecureTransportForTests: Bool = false) -> ClientFactory {
        { mac, keys in
            RemoteClient(configuration: configuration, paired: mac, keys: keys,
                         linkFactory: WebSocketRelayLink.factory(host: mac.relayHost,
                                                                 allowInsecureTransportForTests: allowInsecureTransportForTests))
        }
    }

    // MARK: RemoteTransport

    public func connect() async { await core.connect() }
    public func disconnect() async { await core.disconnect() }
    public func subscribe(_ topics: [String]) async { await core.subscribe(topics) }

    public func send(_ command: AppCommand, presence: (any PresenceSigner)?,
                     events: (@Sendable (CommandEvent) -> Void)?) async throws -> JSONValue {
        guard let client = await core.client() else { throw RemoteError.notPaired }
        var final: CommandResponse?
        for try await response in try await client.send(command, presence: presence) {
            if let event = response.event { events?(event) } else { final = response }
        }
        guard let final else { throw RemoteError.sessionClosed }
        if let failure = final.error { throw failure }
        return final.result ?? .ok
    }

    public func fetchMailbox() async throws -> MailboxHome? {
        guard let client = await core.client() else { return nil }
        // The client only keeps revisions in memory: start from what was seen before this launch (review M2), so a
        // relay can't hand back an older blob it kept.
        if let mailboxRevisions {
            let saved = mailboxRevisions.loadMailboxRevisions()
            let current = await client.mailboxRevisions
            await client.restoreMailboxRevisions(current.merging(saved) { max($0, $1) })
        }
        let blobs = try await client.fetchMailbox()
        mailboxRevisions?.saveMailboxRevisions(await client.mailboxRevisions)
        guard let blob = blobs.filter({ $0.slot == Topic.home }).max(by: { $0.rev < $1.rev }), !blob.data.isEmpty else {
            return nil
        }
        // An empty slot is the Mac saying "nothing" (mailbox turned off, spec Q.4).
        let value = try CommandProtocol.decoder.decode(JSONValue.self, from: blob.data)
        return MailboxHome(rev: blob.rev, createdAt: blob.createdAt, data: value)
    }

    public func unpair() async { await core.unpair() }

    public func registerPush(_ registration: PushRegistration) async throws {
        guard let client = await core.client() else { throw RemoteError.notPaired }
        try await client.registerPushToken(registration.token, env: registration.environment.rawValue)
    }

    /// The client of the current pairing (tests).
    public var currentClient: RemoteClient? { get async { await core.client() } }

    // MARK: State

    private actor Core {
        let session: Session
        let makeClient: ClientFactory
        let retryDelay: @Sendable (Int) -> Duration
        let emit: @Sendable (TransportEvent) -> Void

        private var current: RemoteClient?
        private var deviceId: String?
        private var forwarders: [Task<Void, Never>] = []
        private var wanted = false
        private var attempts = 0
        private var retry: Task<Void, Never>?
        private var lastStatus: RemoteClientStatus?

        init(session: @escaping Session, makeClient: @escaping ClientFactory, retryDelay: @escaping @Sendable (Int) -> Duration,
             emit: @escaping @Sendable (TransportEvent) -> Void) {
            self.session = session
            self.makeClient = makeClient
            self.retryDelay = retryDelay
            self.emit = emit
        }

        /// The client for what the keychain holds now (a new one if the pairing changed).
        func client() -> RemoteClient? {
            guard let (mac, keys) = session() else {
                replace(with: nil, deviceId: nil)
                return nil
            }
            if let current, deviceId == mac.deviceId { return current }
            let client = makeClient(mac, keys)
            replace(with: client, deviceId: mac.deviceId)
            return client
        }

        private func replace(with client: RemoteClient?, deviceId: String?) {
            guard client !== current else { return }
            forwarders.forEach { $0.cancel() }
            forwarders = []
            let old = current
            current = client
            self.deviceId = deviceId
            lastStatus = nil
            if let old { Task { await old.disconnect() } }
            guard let client else { return }
            let emit = emit
            forwarders = [
                Task { for await update in client.states { emit(.state(update)) } },
                Task { for await delta in client.chatDeltas { emit(.chatDelta(pr: delta.pr, text: delta.text)) } },
                Task { [weak self] in
                    for await status in client.statusUpdates { await self?.statusChanged(status, of: client) }
                },
                // The Mac can turn Face ID on or off for this iPhone mid-session (review L2).
                Task { for await required in client.presencePolicyUpdates { emit(.presencePolicy(requirePresence: required)) } },
            ]
        }

        func connect() async {
            wanted = true
            retry?.cancel()
            retry = nil
            await attempt()
        }

        private func attempt() async {
            guard wanted, let client = client() else { return }
            do {
                try await client.connect()
            } catch {
                // Errors that change the status are reported by `statusChanged`; a handshake that went nowhere (a Mac
                // that doesn't answer, a timeout) leaves it at `connecting`: a connection problem, retried.
                guard current === client, await client.status == .connecting else { return }
                emit(.link(.relayUnreachable))
                scheduleRetry()
            }
        }

        func disconnect() async {
            wanted = false
            retry?.cancel()
            retry = nil
            await current?.disconnect()
        }

        func subscribe(_ topics: [String]) async {
            try? await client()?.subscribe(topics)
        }

        func unpair() async {
            wanted = false
            retry?.cancel()
            retry = nil
            await current?.unpair()
        }

        private func scheduleRetry() {
            guard wanted, retry == nil else { return }
            attempts += 1
            let delay = retryDelay(attempts)
            retry = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.retryNow()
            }
        }

        private func retryNow() async {
            retry = nil
            await attempt()
        }

        private func statusChanged(_ status: RemoteClientStatus, of client: RemoteClient) async {
            guard client === current else { return }
            let previous = lastStatus
            lastStatus = status
            switch status {
            case .unpaired:
                break
            case .disconnected:
                // The Mac came back (`presence` online), or the session died under a live relay link (a frame that
                // didn't authenticate, the Mac's `bye`, a rotation, a request that timed out, the Mac reconnecting
                // to the relay: review M3) while the app wants the link: reconnect (and resubscribe) now.
                guard wanted else { break }
                switch previous {
                case .macOffline?, .online?: await attempt()
                default: scheduleRetry()
                }
            case .connecting:
                emit(.link(.connecting))
            case .online:
                attempts = 0
                emit(.hello(macName: await client.macHello?.macName))
                emit(.presencePolicy(requirePresence: await client.presencePolicy.requirePresence))
                emit(.link(.online))
            case .macOffline(let since):
                emit(.link(.macOffline(since: since)))
            case .relayUnreachable, .relayRejected:
                let code = await client.lastRelayCloseCode
                if let code, (4000..<5000).contains(code) {
                    emit(.link(.relayRejected(closeCode: code)))
                } else {
                    emit(.link(.relayUnreachable))
                }
                scheduleRetry()
            case .revoked:
                wanted = false
                retry?.cancel()
                retry = nil
                emit(.link(.revoked))
            case .incompatible(let reason):
                emit(.link(.incompatible(reason)))
            }
        }
    }
}

/// Pairing through the relay (spec P.11): joins the QR's slot, runs Noise IKpsk2 with the keys the app generated,
/// shows the 6-digit code, and waits for the Mac's "Codes Match". RemoteKit acknowledges the Mac's result inside the
/// encrypted session (crypto review M1): the Mac stores this iPhone only once that acknowledgement arrives.
public final class LivePairingService: PairingService, @unchecked Sendable {
    private let configuration: RemoteClient.Configuration
    private let linkFactory: @Sendable (String) -> RelayLinkFactory
    private let lock = NSLock()
    private var client: RemoteClient?

    /// `linkFactory`: relay host → connections to it (`WebSocketRelayLink.factory`).
    public init(configuration: RemoteClient.Configuration,
                linkFactory: @escaping @Sendable (String) -> RelayLinkFactory = { WebSocketRelayLink.factory(host: $0) }) {
        self.configuration = configuration
        self.linkFactory = linkFactory
    }

    public func join(_ qr: PairingQR, keys: StoredDeviceKeys,
                     presencePublicKey: Data) -> AsyncThrowingStream<PairingProgress, Error> {
        let client = RemoteClient(configuration: configuration, linkFactory: linkFactory(qr.relayHost))
        lock.withLock { self.client = client }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.joining)
                    let code = try await client.startPairing(qr: qr, presenceKey: presencePublicKey,
                                                             keys: try keys.deviceKeys())
                    continuation.yield(.code(SAS.display(code)))
                    continuation.yield(.paired(try await client.finishPairing()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.failure(error))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await client.cancelPairing() }
            }
        }
    }

    public func cancel() async {
        let client = lock.withLock { () -> RemoteClient? in
            defer { self.client = nil }
            return self.client
        }
        await client?.cancelPairing()
    }

    static func failure(_ error: Error) -> Error {
        switch error {
        case RemoteError.pairingExpired: PairingFailure.expired
        case RemoteError.pairingCancelled: PairingFailure.cancelled
        case is CancellationError: error
        default: PairingFailure.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
