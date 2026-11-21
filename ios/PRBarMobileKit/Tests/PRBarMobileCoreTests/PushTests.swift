import CryptoKit
import Foundation
import Testing
import UserNotifications
import PRBarRemoteKit
import PRBarWire
@testable import PRBarMobileCore

/// The notification service extension's logic (spec P.9, plan 19 Task 8): envelopes sealed here the way the Mac's
/// `RemoteHost.push` seals them.
@Suite struct PushOpenerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let macSeal = Curve25519.KeyAgreement.PrivateKey()
    let keys = StoredDeviceKeys.generate(presenceKey: Data())
    let mac: PairedMac
    let keychain: DeviceKeychain
    let seen = InMemorySeenPushes()

    init() throws {
        mac = PairedMac(accountId: "a2ljbhs5c3lzm3vsaxhxtdxw7m", deviceId: "d2ljbhs5c3lzm3vsaxhxtdxw7m",
                        relayHost: "relay.example.com", macName: "Diego's MacBook Pro",
                        macStatic: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                        macSeal: macSeal.publicKey.rawRepresentation)
        keychain = DeviceKeychain(backend: InMemoryKeychain(), accessGroup: "TEAMID.com.federico.prbar.ios.shared")
        try keychain.save(keys: keys)
        try keychain.save(mac: mac)
    }

    var opener: PushOpener {
        let now = now
        return PushOpener(keychain: keychain, seen: seen, now: { now })
    }

    func payload(id: UUID = UUID(), createdAt: Date? = nil, title: String = "Review ready · api#317",
                 deepLink: String = "prbar://pr/acme/api/317?screen=review", badge: Int? = 3) -> PushPayload {
        PushPayload(id: id, createdAt: createdAt ?? now.addingTimeInterval(-30), kind: "reviewFinished", title: title,
                    body: "4 comments to choose from", threadId: "acme/api#317", pr: "acme/api#317",
                    deepLink: deepLink, badge: badge)
    }

    func seal(_ payload: PushPayload, from sender: Curve25519.KeyAgreement.PrivateKey? = nil,
              account: String? = nil, device: String? = nil) throws -> [AnyHashable: Any] {
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keys.pushKey).publicKey
        let field = try payload.sealedForAPNs(from: sender ?? macSeal, to: recipient,
                                              info: SealedInfo.push(account: account ?? mac.accountId,
                                                                    device: device ?? mac.deviceId))
        return ["aps": ["alert": ["title": "PRBar", "body": "New activity on your Mac"], "mutable-content": 1],
                "e": field, "v": 1]
    }

    @Test func opensWhatTheMacSealed() throws {
        let sent = payload()
        let content = opener.content(userInfo: try seal(sent))
        #expect(content.title == "Review ready · api#317")
        #expect(content.body == "4 comments to choose from")
        #expect(content.threadIdentifier == "acme/api#317")
        #expect(content.badge == 3)
        #expect(content.deepLink == "prbar://pr/acme/api/317?screen=review")
        #expect(content.pr == "acme/api#317")
        #expect(content.categoryIdentifier == PushCategory.review)
    }

    @Test func brokenEnvelopesStayGeneric() throws {
        var info = try seal(payload())
        var field = Data(base64Encoded: info["e"] as! String)!
        field[field.count - 1] ^= 0x01
        info["e"] = field.base64EncodedString()
        #expect(opener.open(userInfo: info) == .failure(.undecryptable))
        #expect(opener.content(userInfo: info) == .generic)
        #expect(opener.open(userInfo: ["e": "not base64!"]) == .failure(.missingEnvelope))
        #expect(opener.open(userInfo: [:]) == .failure(.missingEnvelope))
        #expect(opener.open(userInfo: ["e": Data(count: 20).base64EncodedString()]) == .failure(.undecryptable))
    }

    @Test func anotherSenderOrAnotherDeviceDoesNotOpen() throws {
        let stranger = Curve25519.KeyAgreement.PrivateKey()
        #expect(opener.open(userInfo: try seal(payload(), from: stranger)) == .failure(.undecryptable))
        #expect(opener.open(userInfo: try seal(payload(), device: "another-device")) == .failure(.undecryptable))
        #expect(opener.open(userInfo: try seal(payload(), account: "another-account")) == .failure(.undecryptable))
    }

    @Test func pushesOlderThanADayOrFromTheFutureStayGeneric() throws {
        let old = payload(createdAt: now.addingTimeInterval(-25 * 3600))
        #expect(opener.open(userInfo: try seal(old)) == .failure(.stale))
        #expect(opener.content(userInfo: try seal(old)) == .generic)
        let future = payload(createdAt: now.addingTimeInterval(11 * 60))
        #expect(opener.open(userInfo: try seal(future)) == .failure(.stale))
        let almostADay = payload(createdAt: now.addingTimeInterval(-23 * 3600))
        #expect(throws: Never.self) { try opener.open(userInfo: try seal(almostADay)).get() }
    }

    @Test func aReplayedIdStaysGeneric() throws {
        let id = UUID()
        let first = try seal(payload(id: id))
        #expect(opener.content(userInfo: first).title == "Review ready · api#317")
        // The same push again, or a new envelope with the same id: the relay replaying.
        #expect(opener.open(userInfo: first) == .failure(.replayed))
        #expect(opener.content(userInfo: try seal(payload(id: id))) == .generic)
    }

    @Test func aRejectedPushDoesNotUseUpItsId() throws {
        let id = UUID()
        #expect(opener.open(userInfo: try seal(payload(id: id, createdAt: now.addingTimeInterval(-90_000)))) == .failure(.stale))
        #expect(throws: Never.self) { try opener.open(userInfo: try seal(payload(id: id))).get() }
    }

    @Test func withoutAPairingNothingOpens() throws {
        let info = try seal(payload())
        try keychain.wipe()
        #expect(opener.open(userInfo: info) == .failure(.notPaired))
        #expect(opener.content(userInfo: info) == .generic)
    }

    @Test func textIsCleanedAndPairLinksAreDropped() throws {
        let sneaky = payload(title: "Fix\u{202E}gnp.exe\nsecond line", deepLink: "prbar://pair?v=1&s=x", badge: -2)
        let content = opener.content(userInfo: try seal(sneaky))
        #expect(!content.title.contains("\u{202E}"))
        #expect(!content.title.contains("\n"))
        #expect(content.deepLink == nil)
        #expect(content.badge == 0)
        #expect(content.categoryIdentifier == PushCategory.generic)
    }

    @Test func seenFileKeepsTheLast200() throws {
        let url = tempDirectory().appendingPathComponent("seen.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = SeenPushFile(url: url)
        let ids = (0..<201).map { _ in UUID() }
        for id in ids { #expect(file.insert(id)) }
        #expect(!file.insert(ids[200]))
        // A new instance (the next extension process) reads the same file.
        let again = SeenPushFile(url: url)
        #expect(!again.insert(ids[1]))
        #expect(again.insert(ids[0]))  // the oldest fell out
    }
}

@Suite struct PushCategoryTests {
    @Test func categoryFollowsTheScreen() {
        #expect(PushCategory.identifier(for: DeepLink(URL(string: "prbar://pr/a/b/1?screen=merge")!)) == PushCategory.merge)
        #expect(PushCategory.identifier(for: DeepLink(URL(string: "prbar://pr/a/b/1?screen=respond")!)) == PushCategory.respond)
        #expect(PushCategory.identifier(for: DeepLink(URL(string: "prbar://pr/a/b/1")!)) == PushCategory.generic)
        #expect(PushCategory.identifier(for: .activity) == PushCategory.generic)
        #expect(PushCategory.identifier(for: nil) == PushCategory.generic)
        // Every action opens the app (no gated action runs from a notification), and every category is registered.
        let identifiers = PushCategory.all.map(\.identifier)
        #expect(Set(identifiers) == [PushCategory.generic, PushCategory.review, PushCategory.respond, PushCategory.merge])
    }

    @Test func actionsOpenTheRightScreen() {
        let link = "prbar://pr/acme/api/317?screen=review"
        #expect(PushCategory.link(forAction: "com.apple.UNNotificationDefaultActionIdentifier", deepLink: link)
                == .pr(id: "acme/api#317", screen: .review))
        #expect(PushCategory.link(forAction: "chat", deepLink: link) == .pr(id: "acme/api#317", screen: .chat))
        #expect(PushCategory.link(forAction: "merge", deepLink: "prbar://pr/acme/api/322?screen=merge")
                == .pr(id: "acme/api#322", screen: .merge))
        #expect(PushCategory.link(forAction: "open", deepLink: "prbar://activity") == .activity)
        // A push that stayed generic, or a pairing link, opens Home.
        #expect(PushCategory.link(forAction: "open", deepLink: nil) == .home)
        #expect(PushCategory.link(forAction: "open", deepLink: "prbar://pair?v=1") == .home)
    }

    @Test func homeAndActivityLinksParse() {
        #expect(DeepLink(URL(string: "prbar://home")!) == .home)
        #expect(DeepLink(URL(string: "prbar://activity")!) == .activity)
        #expect(DeepLink(URL(string: "prbar://pair?v=1")!)?.isNotificationTarget == false)
    }
}

@Suite struct PushNotificationProcessorTests {
    @Test func replacesTheGenericTextAndDropsTheEnvelope() {
        let incoming = UNMutableNotificationContent()
        incoming.title = "PRBar"
        incoming.body = "New activity on your Mac"
        incoming.threadIdentifier = "0123abcd"
        incoming.categoryIdentifier = "PR"
        incoming.userInfo = ["e": "c2VhbGVk", "v": 1]
        let push = PushContent(title: "Ready to merge · api#322", body: "Approved by 2, checks passing",
                               threadIdentifier: "acme/api#322", badge: 2,
                               deepLink: "prbar://pr/acme/api/322?screen=merge", pr: "acme/api#322",
                               categoryIdentifier: PushCategory.merge)
        let out = PushNotificationProcessor.apply(push, to: incoming)
        #expect(out.title == "Ready to merge · api#322")
        #expect(out.body == "Approved by 2, checks passing")
        #expect(out.threadIdentifier == "acme/api#322")
        #expect(out.badge == 2)
        #expect(out.categoryIdentifier == PushCategory.merge)
        #expect(out.userInfo["deepLink"] as? String == "prbar://pr/acme/api/322?screen=merge")
        #expect(out.userInfo["pr"] as? String == "acme/api#322")
        #expect(out.userInfo["e"] == nil)
    }

    @Test func genericKeepsTheRelayThreadAndShowsNothingElse() {
        let incoming = UNMutableNotificationContent()
        incoming.title = "PRBar"
        incoming.body = "New activity on your Mac"
        incoming.threadIdentifier = "0123abcd"
        incoming.userInfo = ["e": "c2VhbGVk", "v": 1, "deepLink": "prbar://pr/x/y/1"]
        let out = PushNotificationProcessor.generic(incoming)
        #expect(out.title == "PRBar")
        #expect(out.body == "New activity on your Mac")
        #expect(out.threadIdentifier == "0123abcd")
        #expect(out.badge == nil)
        #expect(out.userInfo["e"] == nil)
        #expect(out.userInfo["deepLink"] == nil)
    }
}

@MainActor @Suite struct PushRegistrationTests {
    @Test func tokenGoesToTheRelayNowAndOnEveryConnection() async {
        let env = await TestEnv(online: false)
        let registration = PushRegistration(deviceToken: Data([0x0a, 0xff, 0x10]), environment: .sandbox)
        #expect(registration.token == "0aff10")
        // Not connected yet: kept for later.
        await env.connection.setPushRegistration(registration)
        #expect(env.transport.pushTokens.isEmpty)
        await env.connection.handle(.link(.online))
        #expect(env.transport.pushTokens == [registration])
        // Connected: right away.
        let next = PushRegistration(token: "abcd", environment: .production)
        await env.connection.setPushRegistration(next)
        #expect(env.transport.pushTokens == [registration, next])
        // The relay link is up while the Mac sleeps: that counts too.
        await env.connection.handle(.link(.macOffline(since: nil)))
        #expect(env.transport.pushTokens == [registration, next, next])
    }
}
