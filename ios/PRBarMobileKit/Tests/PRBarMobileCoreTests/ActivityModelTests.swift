import Foundation
import Testing
import PRBarRemoteKit
import PRBarWire
@testable import PRBarMobileCore

@MainActor @Suite struct ActivityModelTests {
    func model(_ env: TestEnv) -> ActivityModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        return ActivityModel(connection: env.connection, runner: env.runner, now: { Sample.now }, calendar: calendar)
    }

    @Test func subscribesOnlyWhileVisible() async {
        let env = await TestEnv()
        let activity = model(env)
        await activity.appear()
        #expect(env.transport.subscriptions.last == [Topic.home, Topic.activity])
        await activity.disappear()
        #expect(env.transport.subscriptions.last == [Topic.home])
    }

    @Test func tilesRunningJobsAndCost() async throws {
        let env = await TestEnv()
        try env.transport.emitState(Topic.activity, rev: 1, Sample.activity)
        env.store.apply(RemoteStateUpdate(topic: Topic.activity, rev: 1, data: try JSONValue(encoding: Sample.activity)))
        let activity = model(env)
        #expect(activity.tiles.map(\.value) == ["38%", "11.2 GB", "212 GB"])
        #expect(activity.tiles.map(\.caption) == ["12 cores", "of 16 GB", "free of 512"])
        #expect(activity.running.map(\.title) == ["Reviewing api#317", "Fixing CI on web-app#488"])
        #expect(activity.running.map(\.subtitle) == ["2 agents · 4:12 · ~$0.38", "Running tests · 2:03 · ~$0.21"])
        #expect(activity.monthTotal == "$48.20")
        #expect(activity.monthCaption == "estimated · November")
        #expect(activity.costRows.map(\.title) == ["Reviews", "Fixes", "Chat"])
        #expect(activity.costRows.map(\.count) == ["31", "12", "46 msgs"])
        #expect(activity.costRows.map(\.cost) == ["$29.10", "$14.60", "$4.50"])
    }

    @Test func stopCancelsTheRightJob() async throws {
        let env = await TestEnv()
        env.store.apply(RemoteStateUpdate(topic: Topic.activity, rev: 1, data: try JSONValue(encoding: Sample.activity)))
        let activity = model(env)
        for task in activity.running { await activity.stop(task) }
        #expect(env.transport.sentCommands == [.app(.reviewCancel(pr: "acme/api#317")),
                                                .app(.respondCancel(pr: "acme/web-app#488"))])
    }
}
