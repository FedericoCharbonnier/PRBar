import CryptoKit
import Foundation
import Testing
import PRBarRemoteKit
import PRBarWire
@testable import PRBarMobileCore

/// A relay connection that only says how `connect()` ends (the session itself is covered end to end).
private final class ScriptedLink: RelayLink, @unchecked Sendable {
    let result: Result<RelayReady, RelayClosed>
    let incoming: AsyncThrowingStream<RelayMessage, Error>
    private let continuation: AsyncThrowingStream<RelayMessage, Error>.Continuation

    init(_ result: Result<RelayReady, RelayClosed>) {
        self.result = result
        (incoming, continuation) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws -> RelayReady { try result.get() }
    func send(_ message: RelayMessage) throws {}
    func close() async { continuation.finish(throwing: RelayClosed(code: 1000, reason: "Closed")) }
}

@Suite struct LiveTransportTests {
    static let mac = PairedMac(accountId: "acct", deviceId: "dev", relayHost: "relay.example.com", macName: "Mac",
                               macStatic: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                               macSeal: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)

    static func transport(_ result: Result<RelayReady, RelayClosed>, paired: Bool = true) -> LiveTransport {
        let keys = DeviceKeys()
        return LiveTransport(session: { paired ? (mac, keys) : nil }, makeClient: { mac, keys in
            RemoteClient(configuration: .init(appVersion: "t", deviceName: "iPhone", model: "iPhone"), paired: mac,
                         keys: keys, linkFactory: { _ in ScriptedLink(result) })
        }, retryDelay: { _ in .seconds(60) })
    }

    static func links(_ transport: LiveTransport, until done: (LinkState) -> Bool) async -> [LinkState] {
        var seen: [LinkState] = []
        for await event in transport.events {
            guard case .link(let link) = event else { continue }
            seen.append(link)
            if done(link) { break }
        }
        return seen
    }

    @Test func aRelayCloseCodeIsRelayRejectedNotRevoked() async {
        let transport = Self.transport(.failure(RelayClosed(code: 4403, reason: "removed")))
        await transport.connect()
        let seen = await Self.links(transport) { $0 != .connecting }
        #expect(seen.last == .relayRejected(closeCode: 4403))
        #expect(!seen.contains(.revoked))
    }

    @Test func anUnreachableRelayIsAConnectionProblem() async {
        let transport = Self.transport(.failure(RelayClosed(code: nil, reason: "offline")))
        await transport.connect()
        let seen = await Self.links(transport) { $0 != .connecting }
        #expect(seen.last == .relayUnreachable)
    }

    @Test func aMacAwayIsOffline() async {
        let transport = Self.transport(.success(RelayReady(mac: "offline", since: 1_800_000_000)))
        await transport.connect()
        let seen = await Self.links(transport) { $0 != .connecting }
        #expect(seen.last == .macOffline(since: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test func withoutAPairingNothingIsSent() async throws {
        let transport = Self.transport(.failure(RelayClosed(code: nil, reason: "x")), paired: false)
        await #expect(throws: RemoteError.notPaired) { try await transport.send(.status, presence: nil, events: nil) }
        #expect(try await transport.fetchMailbox() == nil)
    }

    @Test func pairingErrorsBecomeTheScreensFailures() {
        #expect(LivePairingService.failure(RemoteError.pairingExpired) as? PairingFailure == .expired)
        #expect(LivePairingService.failure(RemoteError.pairingCancelled) as? PairingFailure == .cancelled)
        #expect(LivePairingService.failure(RemoteError.relayUnreachable) as? PairingFailure
                == .failed("Can’t reach the relay server."))
    }
}
