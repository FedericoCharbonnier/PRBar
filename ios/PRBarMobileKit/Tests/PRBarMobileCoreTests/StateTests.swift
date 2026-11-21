import Foundation
import Testing
import PRBarRemoteKit
import PRBarWire
@testable import PRBarMobileCore

@Suite struct CacheTests {
    @Test func writesHomeAndPRsAndWipes() throws {
        let cache = Cache(directory: tempDirectory())
        try cache.saveHome(Sample.home, rev: 7, at: Sample.now)
        try cache.savePR(Sample.detail317, id: "acme/api#317", rev: 3, at: Sample.now)
        #expect(cache.loadHome()?.rev == 7)
        #expect(cache.loadHome()?.value == Sample.home)
        #expect(cache.loadPR("acme/api#317")?.value == Sample.detail317)
        let file = cache.directory.appendingPathComponent("pr").appendingPathComponent(Cache.fileName(forPR: "acme/api#317"))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(Cache.fileName(forPR: "acme/api#317").count == 64 + 5)
        try cache.wipe()
        #expect(cache.loadHome() == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
    }

    @Test func keepsTheMostRecentPRs() throws {
        let cache = Cache(directory: tempDirectory(), maxPRs: 3)
        for n in 1...5 {
            var detail = Sample.detail317
            detail.pr?.id = "acme/api#\(n)"
            try cache.savePR(detail, id: detail.pr!.id, rev: n, at: Sample.now.addingTimeInterval(Double(n)))
        }
        #expect(cache.cachedPRCount == 3)
        #expect(cache.loadPR("acme/api#1") == nil)
        #expect(cache.loadPR("acme/api#2") == nil)
        #expect(cache.loadPR("acme/api#5") != nil)
        try cache.wipe()
    }

    @Test func protectsFilesUntilFirstUnlockOnIOS() {
        #if os(iOS)
        #expect(Cache.writingOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        #endif
        #expect(Cache.writingOptions.contains(.atomic))
    }
}

@MainActor @Suite struct AppStoreTests {
    func update(_ rev: Int, title: String) throws -> RemoteStateUpdate {
        var home = Sample.home
        home.prs[0].title = title
        return RemoteStateUpdate(topic: Topic.home, rev: rev, data: try JSONValue(encoding: home))
    }

    @Test func appliesNewerHomeAndIgnoresOlder() throws {
        let store = AppStore(cache: nil, now: { Sample.now })
        #expect(store.apply(try update(5, title: "five")))
        #expect(!store.apply(try update(4, title: "four")))
        #expect(!store.apply(try update(5, title: "five again")))
        #expect(store.home?.prs[0].title == "five")
        #expect(store.lastUpdated == Sample.now)
    }

    @Test func aNewSessionStartsRevisionsOver() throws {
        let store = AppStore(cache: nil, now: { Sample.now })
        store.apply(try update(9, title: "old session"))
        store.beginSession()
        #expect(store.apply(try update(1, title: "new session")))
        #expect(store.home?.prs[0].title == "new session")
    }

    func mailbox(_ rev: Int, title: String, written: Date) throws -> MailboxHome {
        var home = Sample.home
        home.prs[0].title = title
        return MailboxHome(rev: rev, createdAt: written, data: try JSONValue(encoding: home))
    }

    @Test func mailboxOnlyWhenNewerThanTheCache() throws {
        let cache = Cache(directory: tempDirectory())
        defer { try? cache.wipe() }
        try cache.saveHome(Sample.home, rev: 10, at: Sample.now.addingTimeInterval(-600))
        let store = AppStore(cache: cache, now: { Sample.now })
        #expect(store.home == Sample.home)
        // Written before the cached home: older, even with a higher revision.
        #expect(!store.applyMailbox(try mailbox(1_800_000_000_000, title: "older", written: Sample.now.addingTimeInterval(-900))))
        #expect(store.applyMailbox(try mailbox(1_800_000_000_100, title: "newer", written: Sample.now.addingTimeInterval(-60))))
        #expect(store.home?.prs[0].title == "newer")
        // "Last updated" is when the Mac wrote it, not now.
        #expect(store.lastUpdated == Sample.now.addingTimeInterval(-60))
        #expect(cache.loadHome()?.savedAt == Sample.now.addingTimeInterval(-60))
        #expect(cache.loadMailboxRevisions()[Topic.home] == 1_800_000_000_100)
    }

    /// Review M2: live revisions (1, 2, 3… per Mac session) and mailbox revisions (the Mac's clock) are separate; a
    /// live home is never rolled back by an older mailbox blob, and a blob older than 7 days is never shown.
    @Test func mailboxNeverRollsBackALiveHome() throws {
        let store = AppStore(cache: nil, now: { Sample.now })
        #expect(store.apply(try update(5, title: "live")))
        #expect(!store.applyMailbox(try mailbox(1_800_000_000_000, title: "six days old", written: Sample.now.addingTimeInterval(-6 * 86_400))))
        #expect(!store.applyMailbox(try mailbox(1_800_000_000_000, title: "from before", written: Sample.now.addingTimeInterval(-1))))
        #expect(store.home?.prs[0].title == "live")
        #expect(store.lastUpdated == Sample.now)
        let fresh = AppStore(cache: nil, now: { Sample.now })
        #expect(!fresh.applyMailbox(try mailbox(9, title: "eight days old", written: Sample.now.addingTimeInterval(-8 * 86_400))))
        #expect(fresh.home == nil)
    }

    /// After a relaunch the last mailbox revision still holds: a relay can't replay the blob it kept.
    @Test func mailboxRevisionSurvivesARelaunch() throws {
        let cache = Cache(directory: tempDirectory())
        defer { try? cache.wipe() }
        let first = AppStore(cache: cache, now: { Sample.now })
        #expect(first.applyMailbox(try mailbox(200, title: "new", written: Sample.now.addingTimeInterval(-30))))
        try cache.saveHome(Sample.home, rev: 1, at: Sample.now.addingTimeInterval(-3_600)) // e.g. an older write
        let relaunched = AppStore(cache: cache, now: { Sample.now })
        #expect(relaunched.mailboxRev == 200)
        #expect(!relaunched.applyMailbox(try mailbox(150, title: "replayed", written: Sample.now.addingTimeInterval(-20))))
        #expect(!relaunched.applyMailbox(try mailbox(200, title: "same", written: Sample.now.addingTimeInterval(-20))))
    }

    @Test func staleUnlessOnline() {
        let store = AppStore(cache: nil)
        #expect(store.isStale)
        store.link = .online
        #expect(!store.isStale)
        store.link = .macOffline(since: nil)
        #expect(store.isStale)
    }

    @Test func prDetailsAreCachedAndReadBackOffline() throws {
        let cache = Cache(directory: tempDirectory())
        defer { try? cache.wipe() }
        let store = AppStore(cache: cache, now: { Sample.now })
        store.apply(RemoteStateUpdate(topic: Topic.pr("acme/api#317"), rev: 1, data: try JSONValue(encoding: Sample.detail317)))
        let offline = AppStore(cache: cache, now: { Sample.now })
        #expect(offline.detail(for: "acme/api#317") == Sample.detail317)
    }
}

@MainActor @Suite struct ConnectionTests {
    @Test func foregroundConnectsThenGoesOnlineAndSubscribesHome() async {
        let env = await TestEnv(online: false, home: nil, details: [:])
        #expect(env.connection.state == .connecting)
        await env.connection.enterForeground()
        #expect(env.transport.connectCount == 1)
        await env.connection.handle(.link(.online))
        #expect(env.connection.state == .online)
        #expect(env.transport.subscriptions.last == [Topic.home])
        #expect(!env.store.isStale)
    }

    @Test func screensAddTheirTopics() async {
        let env = await TestEnv()
        await env.connection.retain(Topic.pr("acme/api#317"))
        #expect(env.transport.subscriptions.last == [Topic.home, "pr:acme/api#317"])
        await env.connection.retain(Topic.pr("acme/api#317"))
        await env.connection.release(Topic.pr("acme/api#317"))
        #expect(env.transport.subscriptions.last == [Topic.home, "pr:acme/api#317"])
        await env.connection.release(Topic.pr("acme/api#317"))
        #expect(env.transport.subscriptions.last == [Topic.home])
    }

    @Test func macOfflineLoadsTheMailbox() async throws {
        let env = await TestEnv(home: nil, details: [:])
        let written = Sample.now.addingTimeInterval(-300)
        env.transport.setMailbox(MailboxHome(rev: 3, createdAt: written, data: try JSONValue(encoding: Sample.home)))
        let since = Sample.now.addingTimeInterval(-600)
        await env.connection.handle(.link(.macOffline(since: since)))
        #expect(env.connection.state == .macOffline(since: since))
        #expect(env.store.isStale)
        #expect(env.store.home == Sample.home)
        #expect(env.store.lastUpdated == written)
    }

    @Test func revokedWipesKeysAndCache() async throws {
        let cache = Cache(directory: tempDirectory())
        let env = await TestEnv(cache: cache)
        try env.keychain.save(keys: .generate(presenceKey: Data()))
        #expect(cache.loadHome() != nil)
        await env.connection.handle(.link(.revoked))
        #expect(env.connection.state == .revoked(macName: Sample.macName))
        #expect(env.keychainBackend.isEmpty)
        #expect(env.store.home == nil)
        #expect(cache.loadHome() == nil)
        // Nothing reconnects a revoked phone.
        await env.connection.enterForeground()
        #expect(env.transport.connectCount == 0)
    }

    @Test(arguments: [4401, 4403, 4409])
    func relayCloseCodesAreAConnectionProblemNotARevocation(_ code: Int) async throws {
        let cache = Cache(directory: tempDirectory())
        defer { try? cache.wipe() }
        let env = await TestEnv(cache: cache)
        try env.keychain.save(keys: .generate(presenceKey: Data()))
        await env.connection.handle(.link(.relayRejected(closeCode: code)))
        #expect(env.connection.state == .relayUnreachable)
        #expect(!env.keychainBackend.isEmpty)
        #expect(env.store.home == Sample.home)
        #expect(cache.loadHome() != nil)
        let home = HomeModel(connection: env.connection, runner: env.runner, now: { Sample.now })
        #expect(home.isOffline)
        #expect(home.offlineTitle == "Can't connect to Diego's MacBook Pro")
        // Try Again reconnects.
        await home.tryAgain()
        #expect(env.transport.connectCount == 1)
    }

    @Test func incompatibleSaysWhatToUpdate() async {
        let env = await TestEnv()
        await env.connection.handle(.link(.incompatible(.updateMac)))
        #expect(env.connection.state == .incompatible(.updateMac))
        #expect(RemoteConnection.message(for: .updateMac) == "Update PRBar on your Mac")
        #expect(RemoteConnection.message(for: .updateIPhone) == "Update PRBar on this iPhone")
    }

    @Test func backgroundDisconnectsAfterTheGracePeriod() async {
        let env = await TestEnv()
        env.connection.enterBackground()
        await env.connection.settleBackground()
        #expect(env.transport.disconnectCount == 1)
    }

    @Test func comingBackCancelsThePendingDisconnect() async {
        let transport = FakeTransport()
        let store = AppStore(cache: nil)
        let connection = RemoteConnection(transport: transport, store: store, credentials: nil, paired: true,
                                          macName: Sample.macName, sleep: { try await Task.sleep(for: $0) })
        connection.enterBackground()
        await connection.enterForeground()
        await connection.settleBackground()
        #expect(transport.disconnectCount == 0)
        #expect(transport.connectCount == 1)
    }

    @Test func helloAndPolicyUpdateTheConnection() async {
        let env = await TestEnv()
        await env.connection.handle(.hello(macName: "Studio"))
        await env.connection.handle(.presencePolicy(requirePresence: false))
        #expect(env.connection.macName == "Studio")
        #expect(!env.connection.requirePresence)
    }

    @Test func unpairTellsTheMacAndForgets() async throws {
        let env = await TestEnv()
        try env.keychain.save(keys: .generate(presenceKey: Data()))
        await env.connection.unpair()
        #expect(env.transport.didUnpair)
        #expect(env.keychainBackend.isEmpty)
        #expect(env.connection.state == .unpaired)
        #expect(env.store.home == nil)
    }

    @Test func listensToTheTransportStream() async throws {
        let env = await TestEnv(online: false, home: nil, details: [:])
        env.connection.start()
        env.transport.emit(.link(.online))
        try env.transport.emitState(Topic.home, rev: 1, Sample.home)
        for _ in 0..<100 where env.store.home == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(env.connection.state == .online)
        #expect(env.store.home == Sample.home)
        env.connection.stop()
    }
}
