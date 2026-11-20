import Foundation
import Testing
import PRBarRemoteKit
import PRBarWire
@testable import PRBarMobileCore

@MainActor @Suite struct RespondModelTests {
    let pr = "acme/web-app#475"

    func env(phase: String) async -> TestEnv {
        await TestEnv(details: [pr: Sample.detail475(phase: phase), "acme/web-app#488": Sample.detail488()])
    }

    @Test func startSelectAndImplement() async {
        let env = await env(phase: "ready")
        let model = RespondModel(pr: pr, mode: .feedback, connection: env.connection, runner: env.runner)
        await model.start()
        await model.toggle(model.items[0])
        await model.implement()
        #expect(env.transport.sentCommands == [
            .app(.respondStart(pr: pr, wait: false)),
            .app(.respondSelect(pr: pr, items: ["c1"], change: RespondSelectionChange(implement: false))),
            .app(.respondImplement(pr: pr, wait: false)),
        ])
        #expect(model.selectionSummary == "2 of 2 selected")
        #expect(model.headerStatus.text == "Changes requested by Laura Méndez")
    }

    @Test func stagesFollowThePhase() async {
        let env = await env(phase: "implementing")
        let model = RespondModel(pr: pr, mode: .feedback, connection: env.connection, runner: env.runner)
        #expect(model.stages.map(\.state) == [.done, .current, .pending])
        #expect(model.stages[1].detail == "Editing src/reports/export.ts")
        #expect(model.progressTitle == "Claude is fixing 2 comments")
        #expect(model.isRunning)
        #expect(!model.canPush)
    }

    @Test func diffIsParsedForTheDiffScreen() async {
        let env = await env(phase: "readyToPush")
        env.transport.respond(to: "respondDiff", with: Sample.diff475)
        let model = RespondModel(pr: pr, mode: .feedback, connection: env.connection, runner: env.runner)
        await model.loadDiff()
        #expect(env.transport.sentCommands == [.app(.respondDiff(pr: pr))])
        #expect(model.diffFiles.map(\.name) == ["export.ts", "export.test.ts"])
        #expect(model.selectedDiff?.additions == 9)
        #expect(model.headerStatus.text == "2 files · tests passing")
        #expect(model.stages.allSatisfy { $0.state == .done })
    }

    @Test func runTests() async {
        let env = await env(phase: "readyToPush")
        let model = RespondModel(pr: pr, mode: .feedback, connection: env.connection, runner: env.runner)
        await model.runTests()
        #expect(env.transport.sentCommands == [.app(.respondTest(pr: pr, wait: false))])
    }

    @Test func pushAsksForFaceID() async throws {
        let env = await env(phase: "readyToPush")
        let model = RespondModel(pr: pr, mode: .feedback, connection: env.connection, runner: env.runner)
        #expect(model.primaryTitle == "Push & Reply")
        #expect(model.canPush)
        await model.push()
        let sent = try #require(env.transport.sent.first)
        #expect(sent.command == .app(.respondPush(pr: pr, confirmed: true, wait: false)))
        try env.verify(sent)
        #expect(env.authorizer.reasons == ["Push acme/web-app#475"])
    }

    @Test func failedTestsPushAnywayAlsoWithFaceID() async throws {
        var detail = Sample.detail475(phase: "readyToPush")
        detail.respond?.pushBlockedByTests = true
        let env = await TestEnv(details: [pr: detail])
        let model = RespondModel(pr: pr, mode: .feedback, connection: env.connection, runner: env.runner)
        #expect(model.primaryTitle == "Push Anyway")
        await model.push()
        let sent = try #require(env.transport.sent.first)
        #expect(sent.command == .app(.respondPushAnyway(pr: pr, confirmed: true, wait: false)))
        try env.verify(sent)
    }

    @Test func replyOnlyGoesWithoutFaceID() async throws {
        var detail = Sample.detail475(phase: "readyToPush")
        let items = detail.respond!.items.map { var item = $0; item.implement = false; return item }
        detail.respond?.items = items
        let env = await TestEnv(details: [pr: detail])
        let model = RespondModel(pr: pr, mode: .feedback, connection: env.connection, runner: env.runner)
        #expect(model.isReplyOnly)
        #expect(!model.primaryNeedsFaceID)
        await model.push()
        let sent = try #require(env.transport.sent.first)
        #expect(sent.command == .app(.respondReplyOnly(pr: pr, confirmed: true, wait: false)))
        #expect(sent.presence == nil)
    }

    @Test func cancellingFaceIDDoesNotPush() async {
        let env = await env(phase: "readyToPush")
        env.authorizer.setFailure(.cancelled)
        let model = RespondModel(pr: pr, mode: .feedback, connection: env.connection, runner: env.runner)
        await model.push()
        #expect(env.transport.sent.isEmpty)
    }

    @Test func fixCIUsesCIFixAndTheChecks() async {
        let env = await env(phase: "analyzing")
        let model = RespondModel(pr: "acme/web-app#488", mode: .feedback, connection: env.connection, runner: env.runner)
        #expect(model.mode == .ciFix)
        #expect(model.title == "Fix CI")
        #expect(model.primaryTitle == "Push")
        #expect(model.checks.map(\.name) == ["unit-tests", "lint"])
        #expect(model.checksSummary == "2 of 9")
        #expect(model.headerStatus.text == "2 checks failed")
        await model.start()
        #expect(env.transport.sentCommands == [.ciFix(pr: "acme/web-app#488", wait: false)])
    }

    @Test func stopCancelsTheRun() async {
        let env = await env(phase: "implementing")
        let model = RespondModel(pr: pr, mode: .feedback, connection: env.connection, runner: env.runner)
        await model.stop()
        #expect(env.transport.sentCommands == [.app(.respondCancel(pr: pr))])
    }

    @Test func undoAsksToConfirmWhenThereAreManualEdits() async {
        let env = await env(phase: "readyToPush")
        env.transport.respond(to: "chatUndo") { command in
            if case .app(.chatUndo(_, false)) = command {
                throw CommandFailure(.confirmationRequired, "Undo will also discard your manual edits since then.")
            }
            return .ok
        }
        let model = RespondModel(pr: pr, mode: .feedback, connection: env.connection, runner: env.runner)
        await model.undo()
        #expect(model.undoConfirmation == "Undo will also discard your manual edits since then.")
        await model.confirmUndo()
        #expect(env.transport.sentCommands == [.app(.chatUndo(pr: pr, confirmed: false)),
                                                .app(.chatUndo(pr: pr, confirmed: true))])
        #expect(model.undoConfirmation == nil)
    }
}
