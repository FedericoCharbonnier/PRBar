import CryptoKit
import Foundation
import PRBarMobileCore
import PRBarRemoteKit
import PRBarWire

/// The app on a `FakeTransport` with the design's sample data: previews, snapshots, and the build that runs before
/// the relay transport is wired (spec R.7).
extension PhoneApp {
    public static func demo(paired: Bool = true, online: Bool = true, now: @escaping () -> Date = Date.init) -> PhoneApp {
        let transport = FakeTransport(linkOnConnect: online ? .online : .macOffline(since: Sample.now.addingTimeInterval(-86 * 60)))
        programDemo(transport)
        let store = AppStore(home: Sample.home, details: Sample.details, activity: Sample.activity,
                             link: online ? .online : .macOffline(since: nil), lastUpdated: online ? Date() : Sample.now.addingTimeInterval(-86 * 60))
        let keychain = DeviceKeychain(backend: InMemoryKeychain(), accessGroup: nil)
        let connection = RemoteConnection(transport: transport, store: store, credentials: keychain, paired: paired,
                                          macName: Sample.macName)
        let mac = StoredPairedMac(accountId: RemoteIDs.newAccountId(), deviceId: RemoteIDs.newDeviceId(),
                                  relayHost: "relay.example.com", macName: Sample.macName, macStatic: Data(count: 32),
                                  macSealKey: Data(count: 32), pairedAt: Date())
        let pairing = demoPairing(mac: mac)
        let app = PhoneApp(connection: connection, authorizer: SoftwarePresenceAuthorizer(), keychain: keychain,
                           pairingService: pairing,
                           makePresenceKey: {
                               let key = P256.Signing.PrivateKey()
                               return (key.rawRepresentation, key.publicKey.x963Representation)
                           },
                           notifications: DemoNotifications(), appVersion: "0.1.0 (demo)", now: now)
        connection.start()
        if paired && online { transport.emit(.link(.online)) }
        if !online { transport.emit(.link(.macOffline(since: Sample.now.addingTimeInterval(-86 * 60)))) }
        return app
    }

    /// Pairing that "joins", shows 482 913, and pairs once the codes are confirmed.
    public static func demoPairing(mac: StoredPairedMac) -> FakePairingService {
        FakePairingService(script: [.success(.joining), .success(.code("482 913")), .success(.paired(mac))],
                           delayBeforeLast: .seconds(6))
    }

    /// Answers every command the screens send with the sample data.
    public static func programDemo(_ transport: FakeTransport) {
        transport.respond(to: "reviewPublish") { command in
            guard case .app(.reviewPublish(let pr, _, _, _, _, _)) = command else { return .ok }
            return try JSONValue(encoding: PublishedReviewInfo(pr: pr, url: URL(string: "https://github.com/acme/api/pull/317")!,
                                                               action: "posted", comments: 3, publishedAt: Date()))
        }
        transport.respond(to: "respondDiff", with: Sample.diff475)
        transport.respond(to: "mergePreview", with: Sample.mergePreview322)
        transport.respond(to: "merge", with: MergeInfo(pr: "acme/api#322", method: .squash, mergedAt: Date(),
                                                       url: URL(string: "https://github.com/acme/api/pull/322")!))
        transport.respond(to: "notifyList", with: Sample.notifications)
        transport.respond(to: "chatShow") { command in
            guard case .app(.chatShow(let pr)) = command else { return .ok }
            let chat = Sample.details[pr]?.chat ?? ChatInfo(pr: pr, kind: "review", readOnly: false, running: false,
                                                             lockReason: nil, messages: [])
            return try JSONValue(encoding: chat)
        }
        transport.script("chatSend", events: ["Looking ", "at the ", "diff… ", "It only touches the session refresh path."]
            .map { CommandEvent.text(delta: $0) })
    }
}

public struct DemoNotifications: NotificationPermission {
    public init() {}

    public func request() async -> Bool { true }
}
