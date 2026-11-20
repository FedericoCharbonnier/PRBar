import Foundation
import Testing
import PRBarRemoteKit
import PRBarWire
@testable import PRBarMobileCore

@MainActor @Suite struct ReviewModelTests {
    let pr = "acme/api#317"

    func published(comments: Int = 3) -> PublishedReviewInfo {
        PublishedReviewInfo(pr: pr, url: URL(string: "https://github.com/acme/api/pull/317#review")!, action: "posted",
                            comments: comments, publishedAt: Sample.now)
    }

    @Test func subscribesToThePRTopicWhileVisible() async {
        let env = await TestEnv()
        let model = ReviewModel(pr: pr, connection: env.connection, runner: env.runner)
        await model.appear()
        #expect(env.transport.subscriptions.last == [Topic.home, "pr:acme/api#317"])
        await model.disappear()
        #expect(env.transport.subscriptions.last == [Topic.home])
    }

    @Test func reviewWithClaudeStartsWithoutWaiting() async {
        let env = await TestEnv(details: [:])
        let model = ReviewModel(pr: pr, connection: env.connection, runner: env.runner)
        #expect(model.review == nil)
        await model.startReview()
        #expect(env.transport.sentCommands == [.app(.reviewStart(pr: pr, wait: false))])
    }

    @Test func findingsAreNumberedLikeTheMacAndCountIncluded() async {
        let env = await TestEnv()
        let model = ReviewModel(pr: pr, connection: env.connection, runner: env.runner)
        #expect(model.findings.map(\.number) == [1, 2, 3, 4])
        #expect(model.includedSummary == "3 of 4 included")
        await model.setIncluded(model.findings[3], true)
        #expect(model.includedSummary == "4 of 4 included")
        #expect(env.transport.sentCommands == [.app(.reviewSetIncluded(pr: pr, findings: ["f4"], all: false, included: true))])
    }

    @Test func editAndGeneralComment() async {
        let env = await TestEnv()
        let model = ReviewModel(pr: pr, connection: env.connection, runner: env.runner)
        #expect(await model.saveEdit(model.findings[0], body: "Stop after the first 401."))
        await model.setGeneralComment("Nice work overall.")
        #expect(env.transport.sentCommands == [
            .app(.reviewEdit(pr: pr, finding: "f1", title: nil, body: "Stop after the first 401.")),
            .app(.reviewSetComment(pr: pr, text: "Nice work overall.")),
        ])
    }

    @Test(arguments: [ReviewModel.Decision.comment, .requestChanges])
    func commentAndRequestChangesPostWithoutFaceID(_ decision: ReviewModel.Decision) async throws {
        let env = await TestEnv()
        env.transport.respond(to: "reviewPublish", with: published())
        let model = ReviewModel(pr: pr, connection: env.connection, runner: env.runner)
        model.decision = decision
        await model.post()
        let sent = try #require(env.transport.sent.first)
        #expect(sent.command == .app(.reviewPublish(pr: pr, event: decision.event, only: nil, withComments: true,
                                                    allInBody: false, confirmed: true)))
        #expect(sent.presence == nil)
        #expect(env.authorizer.reasons.isEmpty)
        #expect(model.posted?.decision == decision)
    }

    @Test func approveSignsWithFaceIDAndPosts() async throws {
        let env = await TestEnv()
        env.transport.respond(to: "reviewPublish", with: published())
        let model = ReviewModel(pr: pr, connection: env.connection, runner: env.runner)
        model.decision = .approve
        await model.post()
        #expect(env.authorizer.reasons == ["Approve acme/api#317"])
        let sent = try #require(env.transport.sent.first)
        #expect(sent.command == .app(.reviewPublish(pr: pr, event: .approve, only: nil, withComments: true,
                                                    allInBody: false, confirmed: true)))
        try env.verify(sent)
        let posted = try #require(model.posted)
        #expect(posted.message(prRef: "api#317") == "Approved api#317 with 3 comments.")
        #expect(posted.macName == Sample.macName)
        #expect(posted.url.absoluteString.hasSuffix("#review"))
    }

    @Test func cancellingFaceIDSendsNothing() async {
        let env = await TestEnv()
        env.authorizer.setFailure(.cancelled)
        let model = ReviewModel(pr: pr, connection: env.connection, runner: env.runner)
        model.decision = .approve
        await model.post()
        #expect(env.transport.sent.isEmpty)
        #expect(model.posted == nil)
        #expect(model.alert == nil)
    }

    @Test func theMacRefusingWithoutPresenceShowsItsMessage() async {
        let env = await TestEnv()
        env.transport.fail("reviewPublish", CommandFailure(.unauthorized, RemotePolicy.presenceRequiredMessage))
        let model = ReviewModel(pr: pr, connection: env.connection, runner: env.runner)
        model.decision = .approve
        await model.post()
        #expect(model.alert == "Face ID is required for this on iPhone.")
    }

    @Test func anInvalidFaceIDKeyAsksToPairAgain() async {
        let env = await TestEnv()
        env.authorizer.setFailure(.keyInvalid)
        let model = ReviewModel(pr: pr, connection: env.connection, runner: env.runner)
        model.decision = .approve
        await model.post()
        #expect(model.needsRepair)
        #expect(env.transport.sent.isEmpty)
    }

    @Test func withoutTheRequirementApproveSkipsFaceID() async {
        let env = await TestEnv()
        await env.connection.handle(.presencePolicy(requirePresence: false))
        env.transport.respond(to: "reviewPublish", with: published())
        let model = ReviewModel(pr: pr, connection: env.connection, runner: env.runner)
        model.decision = .approve
        await model.post()
        #expect(env.authorizer.reasons.isEmpty)
        #expect(env.transport.sent.first?.presence == nil)
    }

    @Test func cancelAndDismiss() async {
        let env = await TestEnv()
        let model = ReviewModel(pr: pr, connection: env.connection, runner: env.runner)
        await model.cancelReview()
        await model.dismissReview()
        #expect(env.transport.sentCommands == [.app(.reviewCancel(pr: pr)), .app(.reviewDismiss(pr: pr))])
    }

    @Test func offlineCannotPost() async {
        let env = await TestEnv()
        await env.connection.handle(.link(.macOffline(since: nil)))
        let model = ReviewModel(pr: pr, connection: env.connection, runner: env.runner)
        #expect(!model.canPost)
    }
}
