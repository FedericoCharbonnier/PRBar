#if os(macOS)
import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteFixtures
import PRBarRemoteKit
import PRBarRemoteMac
import PRBarWire
import Testing
@testable import PRBarMobileCore

/// The iPhone app's view models against a real Mac through a real relay, on this Mac (spec R.7, S): the Go relay on
/// 127.0.0.1 (`PRBAR_RELAY_BIN`, built by `Scripts/ios-e2e.sh`), a `RemoteAccessService` backed by `FixtureActions`,
/// and the phone's `LiveTransport` + `LivePairingService` with an in-memory keychain and a software presence key.
/// Never the deployed relay. Without the variable the suite is skipped.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRBAR_RELAY_BIN"] != nil, "PRBAR_RELAY_BIN not set"))
@MainActor
struct LiveRelayEndToEndTests {
    @Test func pairReviewApproveMergeChatAndRevoke() async throws {
        let mac = try await MacSide.start()
        defer { mac.stop() }
        let phone = Phone(relayHost: mac.relay.host)

        // Pair: QR → confirmation → SAS on both screens → Codes Match → the Mac waits for the phone's ack.
        try await phone.pair(with: mac)
        try await eventually("online") { phone.connection.state == .online }
        #expect(phone.connection.macName == "Integration Mac")
        #expect(phone.keychain.loadSession() != nil)

        // home arrives (with the data-gap fields filled on the Mac).
        try await eventually("home") { phone.store.home?.prs.count == 3 }
        let home = try #require(phone.store.home)
        #expect(home.displayName("truiz") == "Tomás Ruiz")
        #expect(home.findingCounts?[FixtureActions.reviewPR] == 2)
        #expect(home.prs.first { $0.id == FixtureActions.mergePR }?.approvals == 2)
        #expect(home.prs.first { $0.id == FixtureActions.reviewPR }?.changedFiles == 5)
        #expect(home.ci.first?.failedChecks == 2)
        let homeModel = HomeModel(connection: phone.connection, runner: phone.runner)
        #expect(homeModel.sections(.toReview).first?.rows.first?.authorName == "Tomás Ruiz")

        // Open the review (its topic), toggle a finding: the Mac changes and the topic comes back updated.
        let review = ReviewModel(pr: FixtureActions.reviewPR, connection: phone.connection, runner: phone.runner)
        await review.appear()
        try await eventually("review detail") { review.findings.count == 3 }
        let third = try #require(review.findings.first { $0.id == "f3" })
        #expect(!third.included)
        await review.setIncluded(third, true)
        #expect(mac.actions.included["f3"] == true)
        try await eventually("toggled finding in the topic") { review.findings.first { $0.id == "f3" }?.included == true }

        // Approve: gated, so the phone signs a presence proof bound to this session and request.
        review.decision = .approve
        await review.post()
        #expect(review.alert == nil)
        #expect(review.posted?.comments == 3)
        #expect(mac.actions.approved == [FixtureActions.reviewPR])
        #expect(phone.authorizer.reasons == ["Approve \(FixtureActions.reviewPR)"])

        // Merge with presence (and the Slack channel from the PR's topic).
        let merge = MergeModel(pr: FixtureActions.mergePR, connection: phone.connection, runner: phone.runner)
        await phone.connection.retain(Topic.pr(FixtureActions.mergePR))
        try await eventually("merge topic") { merge.slackChannel == "#api-reviews" }
        await merge.load()
        #expect(merge.preview?.headOid == FixtureActions.mergeHead)
        await merge.merge()
        #expect(merge.alert == nil)
        #expect(merge.merged?.pr == FixtureActions.mergePR)
        #expect(mac.actions.merged == [FixtureActions.mergePR])
        #expect(phone.authorizer.reasons.last == "Merge \(FixtureActions.mergePR)")

        // Chat: the reply streams once (the Mac's chatDelta for the phone's own send is ignored), then a chat that
        // goes on at the Mac shows up live.
        let chat = ChatModel(pr: FixtureActions.reviewPR, kind: .review, connection: phone.connection, runner: phone.runner)
        await chat.open()
        chat.draft = "Anything else worth flagging?"
        mac.actions.chatHold = .milliseconds(600)
        let sending = Task { await chat.send() }
        let reply = mac.actions.chatReply.joined()
        try await eventually("streamed reply") { chat.bubbles.last?.text == reply }
        try await Task.sleep(for: .milliseconds(200))
        // Mid-run: one Claude bubble with the streamed text, not a second one from the Mac's chatDelta.
        #expect(chat.isStreaming)
        #expect(chat.bubbles.filter { $0.role == .claude && !$0.text.isEmpty }.count == 1)
        await sending.value
        #expect(chat.alert == nil)
        #expect(chat.bubbles.last?.text == mac.actions.chatReply.joined())
        mac.service.chatDelta(pr: FixtureActions.reviewPR, text: "Also, from the Mac.")
        try await eventually("chatDelta") { chat.bubbles.last?.text == "Also, from the Mac." }

        // Revoke on the Mac: bye(revoked) inside the session → the phone forgets everything.
        let deviceId = try #require(phone.keychain.loadSession()?.mac.deviceId)
        _ = try await mac.service.revoke(deviceId)
        try await eventually("revoked") {
            if case .revoked = phone.connection.state { return true }
            return false
        }
        #expect(phone.keychain.loadSession() == nil)
        #expect(phone.store.home == nil)
    }

    @Test func aRelayCloseCodeIsAConnectionProblemAndKeepsTheKeys() async throws {
        let mac = try await MacSide.start()
        defer { mac.stop() }
        let phone = Phone(relayHost: mac.relay.host)
        try await phone.pair(with: mac)
        try await eventually("online") { phone.connection.state == .online }
        let deviceId = try #require(phone.keychain.loadSession()?.mac.deviceId)

        // The relay drops the device without the Mac saying anything inside the session: it closes with 4403.
        try #require(mac.links.latestMac).send(.deviceRemove(device: deviceId))
        try await eventually("connection problem") { phone.connection.state == .relayUnreachable }
        let code = await phone.transport.currentClient?.lastRelayCloseCode
        #expect(code == 4403 || code == 4401)
        // Retries keep failing (the relay forgot the device), and nothing is ever wiped.
        try await Task.sleep(for: .seconds(1))
        #expect(phone.connection.state == .relayUnreachable)
        #expect(phone.keychain.loadSession()?.mac.deviceId == deviceId)
        #expect(phone.store.home != nil)
    }
}

// MARK: - The Mac

@MainActor
final class MacSide {
    let relay: RelayProcess
    let service: RemoteAccessService
    let actions: FixtureActions
    let links: LinkTap

    init(relay: RelayProcess, service: RemoteAccessService, actions: FixtureActions, links: LinkTap) {
        self.relay = relay
        self.service = service
        self.actions = actions
        self.links = links
    }

    static func start() async throws -> MacSide {
        let relay = try RelayProcess(binary: ProcessInfo.processInfo.environment["PRBAR_RELAY_BIN"]!)
        try await relay.waitUntilHealthy()
        let links = LinkTap()
        let env = RemoteServiceEnvironment(
            keys: RemoteKeyStore(secrets: MemorySecretStore()),
            devices: RemoteDeviceStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("prbar-e2e-\(UUID().uuidString)")),
            enroller: URLSessionRelayEnroller(allowInsecureForTests: true),
            linkFactory: { host in links.factory(WebSocketRelayLink.factory(host: host, allowInsecureTransportForTests: true)) },
            macName: "Integration Mac", appVersion: "1.9.0",
            tune: { config in
                config.backoff = { _ in .milliseconds(200) }
                config.pushTimeout = .seconds(5)
            },
            connectBackoff: { _ in .milliseconds(200) }, mailboxInterval: .seconds(3600),
            feedDebounce: .milliseconds(50), allowInsecureForTests: true)
        let service = RemoteAccessService(settings: MemoryRemoteSettingsStore(), environment: env)
        let actions = FixtureActions()
        service.actions = actions
        actions.onChange = { [weak service] in service?.stateChanged() }
        actions.onChatText = { [weak service] pr, text in service?.chatDelta(pr: pr, text: text) }
        _ = try await service.enable(relay: relay.host, enrollToken: relay.token)
        try await eventually("Mac connected") { service.state == .connected }
        return MacSide(relay: relay, service: service, actions: actions, links: links)
    }

    func stop() {
        let service = service
        Task { await service.stop() }
        relay.stop()
    }
}

/// Keeps the Mac's relay connection at hand, to make the relay drop a device without a `bye` (4403).
final class LinkTap: @unchecked Sendable {
    private let lock = NSLock()
    private var mac: RelayLink?

    var latestMac: RelayLink? { lock.withLock { mac } }

    func factory(_ base: @escaping RelayLinkFactory) -> RelayLinkFactory {
        { [self] credential in
            let link = base(credential)
            if case .signed(_, "mac", _) = credential { lock.withLock { mac = link } }
            return link
        }
    }
}

// MARK: - The phone

@MainActor
final class Phone {
    let keychain = DeviceKeychain(backend: InMemoryKeychain(), accessGroup: nil)
    let store = AppStore()
    let authorizer = SoftwarePresenceAuthorizer()
    let transport: LiveTransport
    let connection: RemoteConnection
    let runner: ActionRunner
    let pairing: PairingModel

    init(relayHost: String) {
        let configuration = RemoteClient.Configuration(appVersion: "0.1.0", deviceName: "Integration iPhone",
                                                       model: "iPhone 17 Pro", handshakeTimeout: .seconds(5),
                                                       requestTimeout: .seconds(20))
        let keychain = keychain
        transport = LiveTransport(session: { keychain.loadSession() },
                                  makeClient: LiveTransport.clientFactory(configuration: configuration,
                                                                          allowInsecureTransportForTests: true),
                                  retryDelay: { _ in .milliseconds(200) })
        let connection = RemoteConnection(transport: transport, store: store, credentials: keychain, paired: false,
                                          macName: nil)
        self.connection = connection
        runner = ActionRunner(connection: connection, authorizer: authorizer)
        let key = authorizer.key
        pairing = PairingModel(
            service: LivePairingService(configuration: configuration, linkFactory: {
                WebSocketRelayLink.factory(host: $0, allowInsecureTransportForTests: true)
            }),
            keychain: keychain, makePresenceKey: { (key.rawRepresentation, key.publicKey.x963Representation) },
            notifications: AllowNotifications(), allowInsecureRelayForTests: true) { mac in
                connection.didPair(macName: mac.macName)
                Task { await connection.enterForeground() }
            }
        connection.start()
    }

    /// The whole pairing as the user does it: scan, Pair, compare the codes, Codes Match on both sides.
    func pair(with mac: MacSide) async throws {
        let info = try await mac.service.pairStart()
        pairing.startScanning()
        pairing.scanned(info.qr)
        guard case .confirmLink(let name, _, nil) = pairing.step else {
            Issue.record("no confirmation screen: \(pairing.step)")
            return
        }
        #expect(name == "Integration Mac")
        pairing.confirmPairing()
        let joined = try await mac.service.pairWait(pairing: info.pairing, events: { _ in })
        try await eventually("code on the phone") {
            if case .confirmCode = self.pairing.step { return true }
            return false
        }
        #expect(joined.code == pairing.code)
        #expect(joined.deviceName == "Integration iPhone")
        pairing.codesMatch()
        let result = try await mac.service.pairConfirm(pairing: info.pairing, accepted: true)
        #expect(result.device != nil)
        try await eventually("paired") { self.pairing.step == .paired(macName: "Integration Mac") }
    }
}

struct AllowNotifications: NotificationPermission {
    func request() async -> Bool { true }
}

// MARK: - The relay

final class RelayProcess: @unchecked Sendable {
    let process = Process()
    let port = Int.random(in: 20_000...60_000)
    let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    let data = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-relay-\(UUID().uuidString)")

    /// The environment of `relay/deploy/prbar-relay.env.example`, for 127.0.0.1 and without APNs.
    init(binary: String) throws {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: binary)
        process.environment = [
            "RELAY_LISTEN": "127.0.0.1:\(port)", "RELAY_DATA": data.path, "RELAY_PUBLIC_HOST": "127.0.0.1",
            "RELAY_ENROLL_TOKEN": token, "RELAY_MAX_ACCOUNTS": "4", "RELAY_TEST_MODE": "1",
            "RELAY_TRUSTED_PROXIES": "none",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var host: String { "127.0.0.1:\(port)" }

    func waitUntilHealthy() async throws {
        let url = URL(string: "http://\(host)/healthz")!
        for _ in 0..<100 {
            if let (body, _) = try? await URLSession.shared.data(from: url), String(decoding: body, as: UTF8.self) == "ok" {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RelayDidNotStart()
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: data)
    }

    struct RelayDidNotStart: Error {}
}

struct TimedOut: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func eventually(_ what: String, _ seconds: Double = 15, _ condition: @MainActor () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw TimedOut(description: "timed out waiting for \(what)")
}
#endif
