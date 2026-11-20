import Foundation
import Observation
import PRBarWire

/// `chat:review`, `chat:respond`, `chat:merge` (design §chat): the same chat with Claude as the Mac's chat panel.
@MainActor @Observable
public final class ChatModel {
    public enum Kind: String, Sendable {
        case review, respond, merge

        public var title: String {
            switch self {
            case .review: "Review"
            case .respond: "Respond"
            case .merge: "Merge"
            }
        }
    }

    public struct Change: Equatable, Sendable {
        public var title: String
        public var detail: String?
    }

    public struct Bubble: Identifiable, Equatable, Sendable {
        public enum Role: Sendable { case me, claude }
        public var id: UUID
        public var role: Role
        public var text: String
        public var createdAt: Date
        public var change: Change?
        public var undoable: Bool
        public var undone: Bool
    }

    public let pr: String
    public let kind: Kind
    public let connection: RemoteConnection
    public private(set) var bubbles: [Bubble] = []
    public private(set) var isStreaming = false
    public var draft = ""
    public var alert: String?
    public var undoConfirmation: String?
    @ObservationIgnored private let runner: ActionRunner
    @ObservationIgnored private var remoteBubble: UUID?

    public init(pr: String, kind: Kind, connection: RemoteConnection, runner: ActionRunner) {
        self.pr = pr
        self.kind = kind
        self.connection = connection
        self.runner = runner
        if let chat = connection.store.detail(for: pr)?.chat { apply(chat) }
    }

    public var subtitle: String { "\(Format.shortRef(pr)) · \(kind.title)" }
    public var isReadOnly: Bool { kind == .merge }
    public var placeholder: String { kind == .merge ? "Ask about this PR" : "Message Claude" }
    public static let readOnlyNotice = "Read-only. Claude can answer questions about this PR but won't change it."
    public var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming && !connection.store.isStale
    }

    /// `chatShow` when the screen opens; also listens for a chat that someone continues on the Mac.
    public func open() async {
        connection.onChatDelta(pr: pr) { [weak self] text in self?.receiveRemote(text) }
        do {
            let chat = try await runner.run(.chatShow(pr: pr)).decoded(ChatInfo.self)
            apply(chat)
        } catch {
            alert = error.message
        }
    }

    public func close() {
        connection.removeChatHandler(pr: pr)
    }

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draft = ""
        bubbles.append(Bubble(id: UUID(), role: .me, text: text, createdAt: Date(), change: nil, undoable: false, undone: false))
        let replyID = UUID()
        bubbles.append(Bubble(id: replyID, role: .claude, text: "", createdAt: Date(), change: nil, undoable: false, undone: false))
        isStreaming = true
        defer { isStreaming = false }
        do {
            let result = try await runner.run(.chatSend(pr: pr, message: text)) { [weak self] event in
                if case .text(let delta) = event { self?.append(delta, to: replyID) }
            }
            if let chat = try? result.decode(ChatInfo.self) { apply(chat) }
        } catch {
            bubbles.removeAll { $0.id == replyID && $0.text.isEmpty }
            alert = error.message
        }
    }

    public func stop() async {
        do { try await runner.run(.chatStop(pr: pr)) } catch { alert = error.message }
    }

    /// An action card's Undo: asks the Mac; when there are manual edits since, it asks to confirm first.
    public func undo() async {
        do {
            try await runner.run(.chatUndo(pr: pr, confirmed: false))
            await refresh()
        } catch .needsConfirmation(let question) {
            undoConfirmation = question
        } catch {
            alert = error.message
        }
    }

    public func confirmUndo() async {
        undoConfirmation = nil
        do {
            try await runner.run(.chatUndo(pr: pr, confirmed: true))
            await refresh()
        } catch {
            alert = error.message
        }
    }

    /// "Typing" while Claude streams and nothing arrived yet.
    public var showsTyping: Bool { isStreaming && (bubbles.last?.text.isEmpty ?? false) }

    public var visibleBubbles: [Bubble] { bubbles.filter { !$0.text.isEmpty || $0.change != nil } }

    private func refresh() async {
        if let chat = try? await runner.run(.chatShow(pr: pr)).decoded(ChatInfo.self) { apply(chat) }
    }

    private func append(_ delta: String, to id: UUID) {
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        bubbles[index].text += delta
    }

    private func receiveRemote(_ text: String) {
        if let id = remoteBubble, bubbles.contains(where: { $0.id == id }) {
            append(text, to: id)
        } else {
            let id = UUID()
            remoteBubble = id
            bubbles.append(Bubble(id: id, role: .claude, text: text, createdAt: Date(), change: nil, undoable: false,
                                  undone: false))
        }
    }

    private func apply(_ chat: ChatInfo) {
        remoteBubble = nil
        bubbles = chat.messages.map { message in
            var change: Change?
            if let changes = message.changes, !changes.isEmpty {
                let lines = changes.split(separator: "\n", maxSplits: 1).map(String.init)
                change = Change(title: lines[0], detail: lines.count > 1 ? lines[1] : nil)
            }
            return Bubble(id: message.id, role: message.role == "user" ? .me : .claude, text: message.text,
                          createdAt: message.createdAt, change: change, undoable: message.undoable,
                          undone: message.undone)
        }
    }
}
