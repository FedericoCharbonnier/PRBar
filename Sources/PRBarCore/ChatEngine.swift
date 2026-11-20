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
    /// For `--resume` turns: `canEditFiles` isn't what Claude was told last, so the prompt says it again.
    public var capabilitiesChanged: Bool
    public var workingDirectory: URL
    public var additionalDirectories: [URL]
    /// The number of the user's message (1, 2…), for the log header.
    public var turn: Int
    /// For `--resume` turns: the user's rules section if it changed ("" = there are none now).
    public var rulesIfChanged: String?
    /// The conversation's markers (`ChatSession.promptNonce`, spec E.9): the user's message goes between them.
    public var fence: PromptFence

    public init(kind: ChatSession.Kind, claudeSessionID: UUID?, bootstrap: String, message: String, stateIfChanged: String?,
                transcript: [ChatMessage], canEditFiles: Bool, workingDirectory: URL, additionalDirectories: [URL], turn: Int,
                capabilitiesChanged: Bool = false, rulesIfChanged: String? = nil, fence: PromptFence) {
        self.kind = kind
        self.claudeSessionID = claudeSessionID
        self.bootstrap = bootstrap
        self.message = message
        self.stateIfChanged = stateIfChanged
        self.transcript = transcript
        self.canEditFiles = canEditFiles
        self.capabilitiesChanged = capabilitiesChanged
        self.workingDirectory = workingDirectory
        self.additionalDirectories = additionalDirectories
        self.turn = turn
        self.rulesIfChanged = rulesIfChanged
        self.fence = fence
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
/// chat's kind, `--session-id` on the first turn and `--resume` after it. If `--resume` fails because the session
/// doesn't exist (`isMissingSession`), the turn runs again in a new session with the first turn's prompt and the
/// transcript; any other error is thrown.
public struct ChatEngine: Sendable {
    /// The budget of one user message: every run of the turn (resume, retry, rebuild) shares it.
    public static let timeout: TimeInterval = 10 * 60
    /// Review, and Respond before implementing: read only.
    public static let readTools = ["Read", "Grep", "Glob", "Skill", "Agent"]
    /// Respond after implementing: the same as a fix (spec §14.6). Never Bash.
    public static let editTools = FixImplementer.tools

    private let claude: ClaudeRunner
    private let newSessionID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(claude: ClaudeRunner, newSessionID: @escaping @Sendable () -> UUID = { UUID() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.claude = claude
        self.newSessionID = newSessionID
        self.now = now
    }

    /// `canRebuild`: whether the turn may run again in a new session after `--resume` fails. An edit turn passes
    /// false once the worktree changed (the conversation must not continue on a half-edited tree).
    public func send(_ input: ChatTurnInput, canRebuild: @escaping @Sendable () async -> Bool = { true },
                     onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ChatTurnOutput {
        let deadline = now().addingTimeInterval(Self.timeout)
        if let existing = input.claudeSessionID {
            do {
                let output = try await run(input, deadline: deadline, session: .resume(existing),
                                           prompt: ChatPrompts.followUp(message: input.message, state: input.stateIfChanged,
                                                                       canEditFiles: input.capabilitiesChanged ? input.canEditFiles : nil,
                                                                       rules: input.rulesIfChanged, fence: input.fence),
                                           onEvent: onEvent)
                return ChatTurnOutput(reply: output.reply, actions: output.actions, claudeSessionID: existing, rebuiltContext: false)
            } catch {
                // Only the CLI's "session not found": anything else (auth, rate limit, network, a crash) would be a
                // second paid run and lose the conversation.
                guard Self.isMissingSession(error), !Task.isCancelled, await canRebuild() else { throw error }
                claude.appendLog("--- couldn't resume the conversation (\(error.localizedDescription)); rebuilding it ---\n")
            }
            let id = newSessionID()
            let prompt = ChatPrompts.rebuilt(bootstrap: input.bootstrap, transcript: input.transcript)
                + "\n\n" + ChatPrompts.message(input.message, fence: input.fence)
            let output = try await run(input, deadline: deadline, session: .start(id), prompt: prompt, onEvent: onEvent)
            return ChatTurnOutput(reply: output.reply, actions: output.actions, claudeSessionID: id, rebuiltContext: true)
        }
        let id = newSessionID()
        let output = try await run(input, deadline: deadline, session: .start(id),
                                   prompt: input.bootstrap + "\n\n" + ChatPrompts.message(input.message, fence: input.fence),
                                   onEvent: onEvent)
        return ChatTurnOutput(reply: output.reply, actions: output.actions, claudeSessionID: id, rebuiltContext: false)
    }

    /// What `claude -p --resume <id>` reports when the session doesn't exist (verified with the real CLI, 2.1.318:
    /// a `result` line with `is_error` and `errors`, exit 1, and the same text in stderr).
    static let missingSessionMessage = "No conversation found with session ID"

    static func isMissingSession(_ error: Error) -> Bool {
        switch error {
        case ClaudeError.failed(let message): message.contains(missingSessionMessage)
        case PRBarError.commandFailed(_, _, let stderr): stderr.contains(missingSessionMessage)
        default: false
        }
    }

    static func invocation(_ input: ChatTurnInput, session: ClaudeSessionFlag, prompt: String, deadline: Date? = nil) -> ClaudeInvocation {
        ClaudeInvocation(
            prompt: prompt, schema: ChatSchemas.turn, tools: input.kind == .respond && input.canEditFiles ? editTools : readTools,
            workingDirectory: input.workingDirectory, additionalDirectories: input.additionalDirectories,
            timeout: timeout, logHeader: "=== chat \(input.turn) ===", session: session, deadline: deadline)
    }

    private func run(_ input: ChatTurnInput, deadline: Date, session: ClaudeSessionFlag, prompt: String,
                     onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ChatOutput {
        try await claude.run(Self.invocation(input, session: session, prompt: prompt, deadline: deadline),
                             as: ChatOutput.self, onEvent: onEvent)
    }
}
