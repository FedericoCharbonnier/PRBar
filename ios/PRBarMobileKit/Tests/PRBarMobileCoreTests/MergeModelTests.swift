import Foundation
import Testing
import PRBarRemoteKit
import PRBarWire
@testable import PRBarMobileCore

@MainActor @Suite struct MergeModelTests {
    let pr = "acme/api#322"

    func env() async -> TestEnv {
        let env = await TestEnv()
        env.transport.respond(to: "mergePreview", with: Sample.mergePreview322)
        env.transport.respond(to: "merge", with: MergeInfo(pr: pr, method: .squash, mergedAt: Sample.now,
                                                           url: URL(string: "https://github.com/acme/api/pull/322")!))
        return env
    }

    @Test func previewFillsTheSummary() async {
        let env = await env()
        let model = MergeModel(pr: pr, connection: env.connection, runner: env.runner)
        await model.load()
        #expect(env.transport.sentCommands == [.app(.mergePreview(pr: pr, method: nil))])
        #expect(model.method == .squash)
        #expect(model.reviewers.map(\.name) == ["Laura Méndez", "Tomás Ruiz"])
        #expect(model.reviewers.allSatisfy { $0.approved })
        #expect(model.checksText == "✓ 9 passing")
        #expect(model.conversationsText == "None")
        #expect(model.filesText == "4 changed")
        #expect(model.methodNote(.squash) == "3 commits become one commit on main.")
        #expect(model.methodNote(.merge) == "Adds a merge commit and keeps all 3 commits.")
        #expect(model.methodNote(.rebase) == "Replays the 3 commits on top of main.")
    }

    @Test func mergeSendsTheHeadItShowedWithFaceID() async throws {
        let env = await env()
        let model = MergeModel(pr: pr, connection: env.connection, runner: env.runner)
        await model.load()
        model.method = .rebase
        await model.merge()
        let sent = try #require(env.transport.sent.last)
        #expect(sent.command == .app(.merge(pr: pr, method: .rebase, confirmed: true, expectedHeadOid: "9f3c2a1")))
        try env.verify(sent)
        #expect(env.authorizer.reasons == ["Merge acme/api#322"])
        #expect(model.merged != nil)
        #expect(model.mergedMessage == "api#322 was squashed into main.")
    }

    @Test func aMovedHeadShowsTheMessageAndReloads() async {
        let env = await env()
        env.transport.fail("merge", CommandFailure(.invalidState, "The PR changed since you looked at it."))
        let model = MergeModel(pr: pr, connection: env.connection, runner: env.runner)
        await model.load()
        await model.merge()
        #expect(model.alert == "The PR changed since you looked at it.")
        #expect(model.merged == nil)
        #expect(env.transport.sentCommands.filter { $0.name == "mergePreview" }.count == 2)
    }

    @Test func cancellingFaceIDMergesNothing() async {
        let env = await env()
        env.authorizer.setFailure(.cancelled)
        let model = MergeModel(pr: pr, connection: env.connection, runner: env.runner)
        await model.load()
        await model.merge()
        #expect(!env.transport.sentCommands.contains { $0.name == "merge" })
        #expect(model.alert == nil)
    }

    @Test func dismissTheError() async {
        let env = await env()
        let model = MergeModel(pr: pr, connection: env.connection, runner: env.runner)
        await model.dismissError()
        #expect(env.transport.sentCommands == [.app(.mergeDismiss(pr: pr))])
    }
}
