import Foundation

/// What a chat turn needs. The coordinator builds it in the main actor (state, transcript) and the backend fills
/// in the workspace.
public struct ChatTurnInput: Sendable {
    public var kind: ChatSession.Kind
    /// The conversation to continue (`--resume`); nil = the first turn.
    public var claudeSessionID: UUID?
    /// `ChatPrompts.bootstrap` with the current state: the first turn, or the rebuilt one.
    public var bootstrap: String
    public var message: String
    /// For `--resume` turns: the state if it changed since Claude last saw it.
    public var stateIfChanged: String?
    /// The earlier messages, for the rebuilt prompt.
    public var transcript: [ChatMessage]
    /// Respond after implementing: Edit and Write in the worktree.
    public var canEditFiles: Bool
    public var workingDirectory: URL
    public var additionalDirectories: [URL]
    /// The number of the user's message (1, 2…), for the log header.
    public var turn: Int

    public init(kind: ChatSession.Kind, claudeSessionID: UUID?, bootstrap: String, message: String, stateIfChanged: String?,
                transcript: [ChatMessage], canEditFiles: Bool, workingDirectory: URL, additionalDirectories: [URL], turn: Int) {
        self.kind = kind
        self.claudeSessionID = claudeSessionID
        self.bootstrap = bootstrap
        self.message = message
        self.stateIfChanged = stateIfChanged
        self.transcript = transcript
        self.canEditFiles = canEditFiles
        self.workingDirectory = workingDirectory
        self.additionalDirectories = additionalDirectories
        self.turn = turn
    }
}

public struct ChatTurnOutput: Equatable, Sendable {
    public var reply: String
    public var actions: [ChatAction]
    /// The conversation that answered (a new one if the context was rebuilt).
    public var claudeSessionID: UUID
    /// `--resume` failed and the conversation was started again with a transcript ("Context rebuilt").
    public var rebuiltContext: Bool

    public init(reply: String, actions: [ChatAction], claudeSessionID: UUID, rebuiltContext: Bool) {
        self.reply = reply
        self.actions = actions
        self.claudeSessionID = claudeSessionID
        self.rebuiltContext = rebuiltContext
    }
}

/// One chat turn with `claude -p` (spec B.4): the same isolation as the review (`ClaudeRunner`), the tools of the
/// chat's kind, `--session-id` on the first turn and `--resume` after it. If `--resume` fails (the CLI exits with
/// an error and no result: the session doesn't exist or it rejects it), the turn runs again in a new session with
/// the first turn's prompt and the transcript.
public struct ChatEngine: Sendable {
    public static let timeout: TimeInterval = 10 * 60
    /// Review, and Respond before implementing: read only.
    public static let readTools = ["Read", "Grep", "Glob", "Skill", "Agent"]
    /// Respond after implementing: the same as a fix (spec §14.6). Never Bash.
    public static let editTools = FixImplementer.tools

    private let claude: ClaudeRunner
    private let newSessionID: @Sendable () -> UUID

    public init(claude: ClaudeRunner, newSessionID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.claude = claude
        self.newSessionID = newSessionID
    }

    public func send(_ input: ChatTurnInput,
                     onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ChatTurnOutput {
        if let existing = input.claudeSessionID {
            do {
                let output = try await run(input, session: .resume(existing),
                                           prompt: ChatPrompts.followUp(message: input.message, state: input.stateIfChanged),
                                           onEvent: onEvent)
                return ChatTurnOutput(reply: output.reply, actions: output.actions, claudeSessionID: existing, rebuiltContext: false)
            } catch let error as PRBarError {
                guard case .commandFailed = error, !Task.isCancelled else { throw error }
                claude.appendLog("--- couldn't resume the conversation (\(error.localizedDescription)); rebuilding it ---\n")
            }
            let id = newSessionID()
            let prompt = ChatPrompts.rebuilt(bootstrap: input.bootstrap, transcript: input.transcript)
                + "\n\n" + ChatPrompts.message(input.message)
            let output = try await run(input, session: .start(id), prompt: prompt, onEvent: onEvent)
            return ChatTurnOutput(reply: output.reply, actions: output.actions, claudeSessionID: id, rebuiltContext: true)
        }
        let id = newSessionID()
        let output = try await run(input, session: .start(id),
                                   prompt: input.bootstrap + "\n\n" + ChatPrompts.message(input.message), onEvent: onEvent)
        return ChatTurnOutput(reply: output.reply, actions: output.actions, claudeSessionID: id, rebuiltContext: false)
    }

    static func invocation(_ input: ChatTurnInput, session: ClaudeSessionFlag, prompt: String) -> ClaudeInvocation {
        ClaudeInvocation(
            prompt: prompt, schema: ChatSchemas.turn, tools: input.canEditFiles ? editTools : readTools,
            workingDirectory: input.workingDirectory, additionalDirectories: input.additionalDirectories,
            timeout: timeout, logHeader: "=== chat \(input.turn) ===", session: session)
    }

    private func run(_ input: ChatTurnInput, session: ClaudeSessionFlag, prompt: String,
                     onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ChatOutput {
        try await claude.run(Self.invocation(input, session: session, prompt: prompt), as: ChatOutput.self, onEvent: onEvent)
    }
}
