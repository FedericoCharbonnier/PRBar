import Foundation
import Testing
import PRBarRemoteKit
import PRBarWire
@testable import PRBarMobileCore

@MainActor @Suite struct ChatModelTests {
    let pr = "acme/api#317"

    @Test func openingShowsTheChat() async {
        let env = await TestEnv(details: [:])
        env.transport.respond(to: "chatShow", with: Sample.chatReview)
        let model = ChatModel(pr: pr, kind: .review, connection: env.connection, runner: env.runner)
        await model.open()
        #expect(env.transport.sentCommands == [.chatShow(pr: pr)])
        #expect(model.bubbles.count == 3)
        #expect(model.bubbles[1].change == ChatModel.Change(title: "Changed finding #3", detail: "Severity Medium → Low"))
        #expect(model.subtitle == "api#317 · Review")
        #expect(model.placeholder == "Message Claude")
    }

    @Test func sendingStreamsClaudesAnswer() async {
        let env = await TestEnv(details: [:])
        env.transport.script("chatSend", events: [.text(delta: "It only "), .progress(message: "Thinking"),
                                                  .text(delta: "touches refresh.")])
        env.transport.respond(to: "chatSend") { _ in .ok }
        let model = ChatModel(pr: pr, kind: .review, connection: env.connection, runner: env.runner)
        model.draft = "What does this change?"
        #expect(model.canSend)
        await model.send()
        #expect(env.transport.sentCommands == [.chatSend(pr: pr, message: "What does this change?")])
        #expect(model.bubbles.map(\.text) == ["What does this change?", "It only touches refresh."])
        #expect(model.draft.isEmpty)
        #expect(!model.isStreaming)
    }

    @Test func stopStopsClaude() async {
        let env = await TestEnv(details: [:])
        let model = ChatModel(pr: pr, kind: .review, connection: env.connection, runner: env.runner)
        await model.stop()
        #expect(env.transport.sentCommands == [.chatStop(pr: pr)])
    }

    @Test func undoConfirmsWhenThereAreManualEdits() async {
        let env = await TestEnv(details: [:])
        env.transport.respond(to: "chatUndo") { command in
            if case .chatUndo(_, false) = command {
                throw CommandFailure(.confirmationRequired, "Undo will also discard your manual edits since then.")
            }
            return .ok
        }
        let model = ChatModel(pr: pr, kind: .review, connection: env.connection, runner: env.runner)
        await model.undo()
        #expect(model.undoConfirmation == "Undo will also discard your manual edits since then.")
        await model.confirmUndo()
        #expect(env.transport.sentCommands.prefix(2) == [.chatUndo(pr: pr, confirmed: false),
                                                         .chatUndo(pr: pr, confirmed: true)])
    }

    @Test func aChatContinuedOnTheMacAppearsLive() async {
        let env = await TestEnv(details: [:])
        let model = ChatModel(pr: pr, kind: .review, connection: env.connection, runner: env.runner)
        await model.open()
        await env.connection.handle(.chatDelta(pr: pr, text: "Looking "))
        await env.connection.handle(.chatDelta(pr: pr, text: "now."))
        await env.connection.handle(.chatDelta(pr: "acme/other#1", text: "not this one"))
        #expect(model.bubbles.last?.text == "Looking now.")
        #expect(model.bubbles.last?.role == .claude)
    }

    @Test func mergeChatIsReadOnly() async {
        let env = await TestEnv()
        let model = ChatModel(pr: "acme/api#322", kind: .merge, connection: env.connection, runner: env.runner)
        #expect(model.isReadOnly)
        #expect(model.placeholder == "Ask about this PR")
        #expect(model.subtitle == "api#322 · Merge")
        #expect(ChatModel.readOnlyNotice == "Read-only. Claude can answer questions about this PR but won't change it.")
    }
}
