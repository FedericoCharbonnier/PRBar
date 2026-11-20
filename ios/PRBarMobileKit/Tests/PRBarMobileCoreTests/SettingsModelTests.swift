import Foundation
import Testing
import PRBarRemoteKit
import PRBarWire
@testable import PRBarMobileCore

@MainActor @Suite struct SettingsModelTests {
    func model(_ env: TestEnv, unpaired: @escaping @MainActor () -> Void = {}) -> SettingsModel {
        SettingsModel(connection: env.connection, runner: env.runner, appVersion: "0.1.0", onUnpaired: unpaired)
    }

    @Test func notificationSwitchesDriveTheMac() async {
        let env = await TestEnv()
        env.transport.respond(to: "notifyList", with: Sample.notifications)
        let settings = model(env)
        await settings.load()
        #expect(settings.toggles.map(\.title) == ["Review ready", "New PR to review", "Changes requested on my PRs",
                                                  "Ready to merge", "CI failed on my PRs"])
        #expect(settings.toggles.allSatisfy { $0.isOn })
        await settings.set(.readyToMerge, false)
        #expect(env.transport.sentCommands.last == .notifySet(kind: .readyToMerge, enabled: false))
        #expect(settings.toggles.first { $0.kind == .readyToMerge }?.isOn == false)
    }

    @Test func aFailedSwitchGoesBack() async {
        let env = await TestEnv()
        env.transport.respond(to: "notifyList", with: Sample.notifications)
        env.transport.fail("notifySet", CommandFailure(.failed, "Couldn't save."))
        let settings = model(env)
        await settings.load()
        await settings.set(.readyToMerge, false)
        #expect(settings.toggles.first { $0.kind == .readyToMerge }?.isOn == true)
        #expect(settings.alert == "Couldn't save.")
    }

    @Test func turningFaceIDOnNeedsNoFaceIDButOffDoes() async throws {
        let env = await TestEnv()
        let settings = model(env)
        await settings.setRequirePresence(true)
        #expect(env.transport.sent.last?.presence == nil)
        await settings.setRequirePresence(false)
        let sent = try #require(env.transport.sent.last)
        #expect(sent.command == .presenceRequirement(enabled: false))
        try env.verify(sent)
        #expect(env.authorizer.reasons == ["Turn off Face ID for merge, push and approve"])
    }

    @Test func unpairWipesAndGoesBackToPairing() async throws {
        let env = await TestEnv()
        try env.keychain.save(keys: .generate(presenceKey: Data()))
        var unpaired = false
        let settings = model(env) { unpaired = true }
        await settings.unpair()
        #expect(env.transport.didUnpair)
        #expect(env.keychainBackend.isEmpty)
        #expect(env.store.home == nil)
        #expect(env.connection.state == .unpaired)
        #expect(unpaired)
    }

    @Test func showsTheMacAndVersion() async {
        let env = await TestEnv()
        let settings = model(env)
        #expect(settings.macName == Sample.macName)
        #expect(settings.connectionText == "Connected · end-to-end encrypted")
        #expect(settings.appVersion == "0.1.0")
    }
}
