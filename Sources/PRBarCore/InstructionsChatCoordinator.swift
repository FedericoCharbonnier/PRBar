import Foundation

/// What the instructions chat needs that has side effects: one turn of Claude.
public protocol InstructionsChatBackend: Sendable {
    func send(_ input: InstructionsTurnInput,
              onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> InstructionsTurnOutput
}

/// The real backend: `InstructionsChatEngine` with no plugins and the chat's model; the token isn't involved (Claude
/// gets no tools and PRBar no data from GitHub).
public struct InstructionsChatService: InstructionsChatBackend {
    private let streamingRunner: StreamingProcessRunning
    private let claudePath: String
    private let model: ClaudeModel?
    private let logURL: URL
    private let workingDirectory: URL

    public init(streamingRunner: StreamingProcessRunning, claudePath: String, model: ClaudeModel?,
                logURL: URL = AppPaths.instructionsChatLog, workingDirectory: URL = AppPaths.instructionsChatDir) {
        self.streamingRunner = streamingRunner
        self.claudePath = claudePath
        self.model = model
        self.logURL = logURL
        self.workingDirectory = workingDirectory
    }

    public func send(_ input: InstructionsTurnInput,
                     onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> InstructionsTurnOutput {
        let claude = ClaudeRunner(runner: streamingRunner, claudePath: claudePath, pluginDirs: [],
                                  environment: ClaudeRunner.environment(toolPaths: [claudePath]), logURL: logURL,
                                  redacting: [], model: model)
        return try await InstructionsChatEngine(claude: claude, workingDirectory: workingDirectory).send(input, onEvent: onEvent)
    }
}

/// The instructions chat of Settings › Instructions (spec E.2): applies Claude's rule changes directly, highlights
/// them and offers Undo on the last message with changes. One turn at a time; it shares the app's chat limit.
@MainActor
public final class InstructionsChatCoordinator: ObservableObject {
    public static let key = "instructions-chat"

    @Published public private(set) var chat: InstructionsChat
    @Published public private(set) var isRunning = false
    @Published public private(set) var partialText = ""
    @Published public private(set) var activity: String?
    /// The ids (UUID strings) of the rules the last message changed, for 3 s.
    @Published public private(set) var highlighted: Set<String> = []

    private let store: InstructionsStore
    private let backend: InstructionsChatBackend
    private let scheduler: JobScheduler<String>
    private let repos: @MainActor () -> [String]
    private let promptBody: @MainActor () -> String?
    private var turnID: UUID?
    private var stopping: UUID?
    private var highlightToken: UUID?

    public init(store: InstructionsStore, backend: InstructionsChatBackend, scheduler: JobScheduler<String>,
                repos: @escaping @MainActor () -> [String], promptBody: @escaping @MainActor () -> String? = { nil }) {
        self.store = store
        self.backend = backend
        self.scheduler = scheduler
        self.repos = repos
        self.promptBody = promptBody
        let recovered = store.file.chat.recovered()
        chat = recovered
        if recovered != store.file.chat { persist() }
    }

    public var canSend: Bool { !isRunning }
    public var canUndo: Bool { !isRunning }

    @discardableResult
    public func send(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty else { return false }
        let repos = self.repos()
        let state = InstructionsPrompts.state(rules: store.rules, repos: repos)
        let stateChanged = state != chat.lastState
        let transcript = chat.messages
        let turn = chat.messages.filter { $0.role == .user }.count + 1
        chat.messages.append(ChatMessage(role: .user, text: text))
        chat.pending = true
        persist()

        let id = UUID()
        turnID = id
        partialText = ""
        setRunning(true, activity: "Waiting for another chat to finish…")
        let input = InstructionsTurnInput(
            claudeSessionID: chat.claudeSessionID,
            bootstrap: InstructionsPrompts.bootstrap(state: state, body: promptBody(), repos: repos),
            message: text, stateIfChanged: stateChanged ? state : nil, transcript: transcript, turn: turn)
        let backend = self.backend
        let relay = MainActorRelay<ClaudeStreamEvent> { [weak self] event in self?.handle(event, turn: id) }
        scheduler.enqueue(Self.key, onStart: { [weak self] in
            if self?.turnID == id { self?.activity = "Claude is thinking…" }
        }, work: { [weak self] in
            let outcome: Result<InstructionsTurnOutput, Error>
            do {
                outcome = .success(try await backend.send(input) { relay.send($0) })
            } catch {
                outcome = .failure(error)
            }
            await relay.finish()
            await self?.finishTurn(id, outcome, repos: repos, state: state)
        }, onComplete: { _ in })
        return true
    }

    /// Stops the turn (kills Claude); a queued one ends at once. Nothing was applied yet: no undo is needed.
    public func stop() {
        guard let id = turnID, stopping == nil else { return }
        stopping = id
        if scheduler.isQueued(Self.key) {
            scheduler.cancel(Self.key)
            finishTurn(id, .failure(CancellationError()), repos: [], state: nil)
            return
        }
        activity = "Stopping…"
        scheduler.cancel(Self.key)
    }

    /// Undoing would also discard edits made to the rules after that message.
    public func undoDiscardsLaterEdits(_ id: UUID) -> Bool {
        guard let after = chat.messages.first(where: { $0.id == id })?.restore?.rulesAfter else { return false }
        return after != store.rules
    }

    /// Only the last message with changes not undone. Returns the error to show, or nil.
    @discardableResult
    public func undo(_ id: UUID) -> String? {
        guard id == chat.undoableMessageID, !isRunning,
              let index = chat.messages.firstIndex(where: { $0.id == id }),
              let before = chat.messages[index].restore?.rules else { return nil }
        do {
            try store.replaceRules(before)
        } catch {
            return error.localizedDescription
        }
        chat.messages[index].undone = true
        highlight(chat.messages[index].changes)
        persist()
        return nil
    }

    // MARK: Privado

    private func handle(_ event: ClaudeStreamEvent, turn id: UUID) {
        guard turnID == id, stopping != id else { return }
        switch event {
        case .text(let text): partialText = partialText.isEmpty ? text : partialText + "\n\n" + text
        case .toolUse: break
        case .agentStarted: activity = "Claude is thinking…"
        }
    }

    /// `state`: what the turn sent; it counts as seen (`lastState`) only if the turn succeeded.
    private func finishTurn(_ id: UUID, _ outcome: Result<InstructionsTurnOutput, Error>, repos: [String], state: String?) {
        guard turnID == id else { return }
        turnID = nil
        chat.pending = false
        let stopped = stopping == id
        stopping = nil
        switch outcome {
        case .success(let output):
            chat.claudeSessionID = output.claudeSessionID
            if let state { chat.lastState = state }
            let before = store.rules
            let applied = RuleActions.apply(output.actions, to: before, repos: repos)
            var notes = applied.notes
            if output.rebuiltContext { notes.insert(ChatCoordinator.rebuiltNote, at: 0) }
            var changes: [ChatChange] = []
            var restore: ChatRestorePoint?
            if !applied.changes.isEmpty {
                do {
                    try store.replaceRules(applied.state)
                    changes = applied.changes
                    restore = ChatRestorePoint(rules: before, rulesAfter: applied.state)
                } catch {
                    notes.append("Couldn’t save the rules: \(error.localizedDescription)")
                }
            }
            chat.messages.append(ChatMessage(role: .assistant, text: output.reply, changes: changes, notes: notes, restore: restore))
            highlight(changes)
        case .failure(let error):
            chat.messages.append(ChatMessage(role: .error, text: stopped ? ChatCoordinator.stoppedText : ChatCoordinator.message(for: error)))
        }
        setRunning(false, activity: nil)
        persist()
    }

    private func setRunning(_ running: Bool, activity: String?) {
        isRunning = running
        self.activity = activity
        if !running { partialText = "" }
    }

    private func highlight(_ changes: [ChatChange]) {
        let ids = Set(changes.compactMap(\.highlightID))
        guard !ids.isEmpty else { return }
        highlighted = ids
        let token = UUID()
        highlightToken = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: ChatCoordinator.highlightDuration)
            guard let self, self.highlightToken == token else { return }
            self.highlighted = []
        }
    }

    private func persist() {
        chat.trim()
        do {
            try store.saveChat(chat)
        } catch {
            AppLog.write("Instructions: couldn't save the chat: \(error)")
        }
    }
}
