import Foundation

/// What the coordinator reads from the app on each turn (in the main actor).
public struct ChatContext: Sendable {
    public var pr: PullRequest?
    public var localPath: String?
    /// Respond: the fixes' result (nil before implementing).
    public var respondResult: RespondResult?
    /// Respond in `readyToPush`, not pushed: Claude may edit the worktree.
    public var canEditFiles: Bool
    /// The record's log: each `claude -p` of the chat is appended to it (spec B.7).
    public var logURL: URL
    /// All the user's rules (spec E.1); the chat sends the effective ones of its repo and stage.
    public var rules: [Rule]
    /// The user's own prompt for this chat (spec E.6); nil = the default.
    public var promptBody: String?
    /// Merge: what the window shows (spec G.4), for `pr.md` and the state; nil until it loads.
    public var mergeDetail: MergeDetail?

    public init(pr: PullRequest?, localPath: String?, respondResult: RespondResult?, canEditFiles: Bool, logURL: URL,
                rules: [Rule] = [], promptBody: String? = nil, mergeDetail: MergeDetail? = nil) {
        self.pr = pr
        self.localPath = localPath
        self.respondResult = respondResult
        self.canEditFiles = canEditFiles
        self.logURL = logURL
        self.rules = rules
        self.promptBody = promptBody
        self.mergeDetail = mergeDetail
    }
}

/// What the app does when the chat changes.
public struct ChatHooks {
    /// Save the session and the window's state (history or respond record).
    public var persist: @MainActor (ChatCoordinator) -> Void
    /// A turn (or an undo of files) started or ended.
    public var runningChanged: @MainActor (Bool) -> Void
    /// A turn committed files, or an undo reverted them: the fixes' result changed.
    public var resultChanged: @MainActor (RespondResult) -> Void
    /// Saves a proposal as a rule (`source = prChat`) and returns its id (spec E.3). Called only from `saveProposal`.
    public var saveRule: @MainActor (RuleProposal) throws -> UUID

    public init(persist: @escaping @MainActor (ChatCoordinator) -> Void = { _ in },
                runningChanged: @escaping @MainActor (Bool) -> Void = { _ in },
                resultChanged: @escaping @MainActor (RespondResult) -> Void = { _ in },
                saveRule: @escaping @MainActor (RuleProposal) throws -> UUID = { _ in throw RuleError.unavailable }) {
        self.persist = persist
        self.runningChanged = runningChanged
        self.resultChanged = resultChanged
        self.saveRule = saveRule
    }
}

private struct TurnResult: Sendable {
    let output: ChatTurnOutput
    let files: ChatFilesOutcome?
    let workspace: ChatWorkspace
    let canSetImplement: Bool
    /// What Claude was told it can do in this turn.
    let canEditFiles: Bool
    /// The window's state and the rules section this turn sent: Claude saw them only if the turn succeeded.
    let state: String
    let rulesText: String
}

/// The streaming part of a chat turn (`ChatCoordinator.stream`).
@MainActor
public final class ChatStream: ObservableObject {
    @Published public fileprivate(set) var partialText = ""
    @Published public fileprivate(set) var activity: String?

    public init() {}
}

/// The chat of one Review or Respond window (spec B): the conversation and the window's editable state, which the
/// window and Claude change alike. One turn at a time per PR and at most `maxConcurrentChats` in the app (the shared
/// `JobScheduler`). Claude's actions are applied to the current state with `ChatActions`; each message with changes
/// keeps a restore point, and only the last one not undone can be undone. The window sets `lockReason` while it
/// posts, implements, tests or pushes; `markReadOnly` freezes the conversation after posting or pushing.
@MainActor
public final class ChatCoordinator: ObservableObject {
    public static let maxConcurrentChats = 2
    public static let stoppedText = "Stopped."
    public static let unreadableText = "Claude’s answer couldn’t be read."
    public static let rebuiltNote = "Context rebuilt"
    /// The scheduler didn't take the turn: another chat of the same PR (Review or Respond) holds its slot.
    public static let busyText = "Another chat on this PR is running. Send the message again when it finishes."
    public static var highlightDuration: Duration = .seconds(3)

    public let subject: ChatSubject
    @Published public private(set) var session: ChatSession
    /// Review: selection, edited texts, added findings and the general comment.
    @Published public var reviewEdits: ReviewEdits
    /// Respond: the decisions per comment.
    @Published public var selections: [String: RespondSelection]
    @Published public private(set) var isRunning = false
    /// What changes on every streamed chunk, in its own object: only the chat panel observes it, so the Review and
    /// Respond editors (which observe the coordinator) don't re-render while Claude writes.
    public let stream = ChatStream()
    /// The text Claude wrote so far in this turn (assistant `text` blocks).
    public private(set) var partialText: String {
        get { stream.partialText }
        set { if stream.partialText != newValue { stream.partialText = newValue } }
    }
    /// "Reading src/api/users.ts", "Stopping…"…
    public private(set) var activity: String? {
        get { stream.activity }
        set { if stream.activity != newValue { stream.activity = newValue } }
    }
    /// Ids of the findings or comments the last message changed (3 s).
    @Published public private(set) var highlighted: Set<String> = []
    /// Why no message can be sent now (posting, implementing…); set by the window.
    @Published public private(set) var lockReason: String?

    private let backend: ChatBackend
    private let scheduler: JobScheduler<String>
    private let context: @MainActor () -> ChatContext
    private let hooks: ChatHooks
    private var turnID: UUID?
    private var stopping: UUID?
    private var undoing = false
    /// `markReadOnly` llegó con un turno en curso: el workspace se borra cuando el turno termina de verdad.
    private var discardWhenIdle = false
    private var highlightToken: UUID?
    private var workspaceRoot: URL?

    public init(subject: ChatSubject, session: ChatSession, reviewEdits: ReviewEdits? = nil,
                selections: [String: RespondSelection] = [:], backend: ChatBackend, scheduler: JobScheduler<String>,
                context: @escaping @MainActor () -> ChatContext, hooks: ChatHooks = ChatHooks()) {
        self.subject = subject
        let recovered = session.recovered()
        self.session = recovered
        if case .review(let draft) = subject {
            self.reviewEdits = reviewEdits ?? ReviewEdits.initial(for: draft)
        } else {
            self.reviewEdits = ReviewEdits(selected: [])
        }
        self.selections = selections
        self.backend = backend
        self.scheduler = scheduler
        self.context = context
        self.hooks = hooks
        if recovered != session { hooks.persist(self) }
    }

    private var key: String { "chat-\(subject.prID)" }

    public var canSend: Bool { !isRunning && !session.readOnly && lockReason == nil }
    /// Undo is offered (on `session.undoableMessageID`) when nothing runs and the conversation isn't read only.
    public var canUndo: Bool { !isRunning && !session.readOnly }

    /// `#N` of a finding (Review) or the position of a comment (Respond).
    public func number(of id: String) -> Int? {
        switch subject {
        case .review(let draft): reviewEdits.number(of: id, in: draft)
        case .respond(let draft): draft.items.firstIndex { $0.id == id }.map { $0 + 1 }
        case .merge: nil
        }
    }

    public func setLock(_ reason: String?) {
        if lockReason != reason { lockReason = reason }
    }

    // MARK: Turnos

    @discardableResult
    public func send(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty else { return false }
        let context = self.context()
        let state = currentState(context)
        let stateChanged = state != session.lastState
        // One fence per conversation (spec E.9), saved: a conversation from before it gets one now, and its rules
        // go again with the new markers (the section changes).
        if session.promptNonce == nil { session.promptNonce = PromptFence.random().nonce }
        let fence = PromptFence(nonce: session.promptNonce ?? PromptFence.random().nonce)
        let rules = RulesPrompt.fitting(RulesPrompt.effective(context.rules, repo: subject.repo, stage: subject.ruleStage)).kept
        let rulesText = RulesPrompt.section(rules, fence: fence)
        let rulesChanged = session.claudeSessionID != nil && rulesText != (session.lastRules ?? "")
        let transcript = session.messages
        let turn = session.messages.filter { $0.role == .user }.count + 1
        session.messages.append(ChatMessage(role: .user, text: text))
        session.pending = true
        hooks.persist(self)

        let id = UUID()
        turnID = id
        partialText = ""
        setRunning(true, activity: "Waiting for another chat to finish…")
        let request = ChatWorkspaceRequest(session: session, subject: subject, pr: context.pr, localPath: context.localPath,
                                           respondResult: context.respondResult, mergeDetail: context.mergeDetail)
        let backend = self.backend
        let subject = self.subject
        let claudeSessionID = session.claudeSessionID
        // Edit tools only where `FixImplementer.chatTurn` guards the turn: Respond with the fixes' result.
        let editingResult: RespondResult? = {
            guard case .respond = subject, context.canEditFiles else { return nil }
            return context.respondResult
        }()
        let canEdit = editingResult != nil
        let capabilitiesChanged = claudeSessionID != nil && session.canEditFiles != canEdit
        let relay = MainActorRelay<ClaudeStreamEvent> { [weak self] event in self?.handle(event, turn: id) }
        let outcome = JobOutcomeSlot<Result<TurnResult, Error>>()
        // Claude's usage for this turn (spec O): saved in the session even if the turn failed or was stopped.
        let usage = JobOutcomeSlot<ClaudeUsage>()
        // The turn ends only once the scheduler freed its slot (`onComplete`), or once a stopped turn's work really
        // ended (`onCancelledEnd`, in Respond after the files were restored): when `isRunning` goes false a new
        // message is always accepted.
        let ended: @MainActor (Result<Void, Error>) -> Void = { [weak self] _ in
            if let spent = usage.value, spent.runs > 0, let self { self.session.usage = (self.session.usage ?? .zero) + spent }
            self?.finishTurn(id, outcome.value ?? .failure(CancellationError()))
        }
        let accepted = scheduler.enqueue(key, activity: .chat(subject.prID, sessionID: session.id), onStart: { [weak self] in
            if self?.turnID == id { self?.activity = "Preparing the code…" }
        }, work: { [weak self] in
            let sink = ClaudeUsageSink()
            await sink.measure {
                do {
                    let workspace = try await backend.workspace(request)
                    await self?.workspaceReady(workspace, turn: id)
                    let input = ChatTurnInput(
                        kind: subject.kind, claudeSessionID: claudeSessionID,
                        bootstrap: ChatPrompts.bootstrap(subject: subject, files: workspace.files, isDiffOnly: workspace.isDiffOnly,
                                                         canEditFiles: canEdit, state: state, rules: rules,
                                                         body: context.promptBody, fence: fence),
                        message: text, stateIfChanged: stateChanged ? state : nil, transcript: transcript,
                        canEditFiles: canEdit, workingDirectory: workspace.directory,
                        additionalDirectories: [workspace.contextDirectory], turn: turn,
                        capabilitiesChanged: capabilitiesChanged, rulesIfChanged: rulesChanged ? rulesText : nil, fence: fence,
                        runner: workspace.runner)
                    if case .respond(let draft) = subject, let result = editingResult {
                        let (output, files) = try await backend.sendEditing(input, draft: draft, result: result,
                                                                            sessionID: request.session.id, logURL: context.logURL) { relay.send($0) }
                        outcome.value = .success(TurnResult(output: output, files: files, workspace: workspace, canSetImplement: false,
                                                            canEditFiles: true, state: state, rulesText: rulesText))
                    } else {
                        let output = try await backend.send(input, subject: subject, logURL: context.logURL) { relay.send($0) }
                        outcome.value = .success(TurnResult(output: output, files: nil, workspace: workspace,
                                                            canSetImplement: context.respondResult == nil, canEditFiles: false,
                                                            state: state, rulesText: rulesText))
                    }
                } catch {
                    outcome.value = .failure(error)
                }
            }
            usage.value = sink.total
            await relay.finish()
        }, onComplete: ended, onCancelledEnd: ended)
        if !accepted { finishTurn(id, .failure(ChatTurnNotStarted(errorDescription: Self.busyText))) }
        return true
    }

    /// Stops the turn: it's killed (process group) and the message ends as "Stopped." once the work really ends (in
    /// Respond, after the files were restored). A queued turn ends at once. An undo can't be stopped.
    public func stop() {
        guard let id = turnID, stopping == nil, !undoing else { return }
        stopping = id
        if scheduler.isQueued(key) {
            scheduler.cancel(key)
            finishTurn(id, .failure(CancellationError()))
            return
        }
        activity = "Stopping…"
        scheduler.cancel(key)
    }

    private func handle(_ event: ClaudeStreamEvent, turn id: UUID) {
        guard turnID == id, stopping != id else { return }
        switch event {
        case .text(let text):
            partialText = partialText.isEmpty ? text : partialText + "\n\n" + text
        case .toolUse:
            activity = ChatActivity.describe(event, root: workspaceRoot) ?? activity
        case .agentStarted(let total):
            activity = total > 0 ? "Running \(total) subagent\(total == 1 ? "" : "s")…" : "Claude is thinking…"
        }
    }

    private func workspaceReady(_ workspace: ChatWorkspace, turn id: UUID) {
        guard turnID == id else { return }
        workspaceRoot = workspace.directory
        session.worktreePath = workspace.directory.path
        session.worktreeRefs = workspace.refs
        session.runner = workspace.runner
    }

    private func finishTurn(_ id: UUID, _ outcome: Result<TurnResult, Error>) {
        guard turnID == id else { return }
        turnID = nil
        session.pending = false
        let stopped = stopping == id
        stopping = nil
        switch outcome {
        case .success(let turn):
            // Claude finished before the stop arrived: what it did is real (in Respond, maybe a commit).
            apply(turn)
        case .failure(let error):
            // Stopped on a host where PRBar couldn't confirm Claude stopped: say so, not just "Stopped." (spec J).
            let text = stopped && !RemoteUnstoppedJobs.isNotStopped(error) ? Self.stoppedText : Self.message(for: error)
            session.messages.append(ChatMessage(role: .error, text: text))
        }
        setRunning(false, activity: nil)
        hooks.persist(self)
    }

    private func apply(_ turn: TurnResult) {
        session.claudeSessionID = turn.output.claudeSessionID
        session.canEditFiles = turn.canEditFiles
        // Only now did Claude see them: a stopped or failed turn sends them again next time.
        session.lastState = turn.state
        session.lastRules = turn.rulesText
        var notes: [String] = []
        if turn.output.rebuiltContext { notes.append(Self.rebuiltNote) }
        if let note = turn.workspace.note, !session.messages.contains(where: { $0.notes.contains(note) }) {
            notes.append(note)
        }
        var changes: [ChatChange] = []
        var restore = ChatRestorePoint()
        switch subject {
        case .review(let draft):
            let applied = ChatActions.applyReview(turn.output.actions, to: reviewEdits, draft: draft,
                                                  diffFiles: turn.workspace.diffFiles)
            restore.reviewEdits = reviewEdits
            restore.reviewEditsAfter = applied.state
            reviewEdits = applied.state
            changes = applied.changes
            notes += applied.notes
        case .respond(let draft):
            let applied = ChatActions.applyRespond(turn.output.actions, to: selections, draft: draft,
                                                   canSetImplement: turn.canSetImplement)
            restore.selections = selections
            restore.selectionsAfter = applied.state
            selections = applied.state
            changes = applied.changes
            notes += applied.notes
            if let files = turn.files, !files.changedFiles.isEmpty {
                changes.append(.filesChanged(files.changedFiles))
                restore.files = files.snapshot
                if let result = files.result { hooks.resultChanged(result) }
            }
        case .merge:
            // Read only (spec G.4): nothing changes; only rule proposals become cards.
            notes += ChatActions.applyMerge(turn.output.actions)
        }
        let proposed = ChatActions.proposals(turn.output.actions, repo: subject.repo, stage: subject.ruleStage)
        notes += proposed.notes
        session.messages.append(ChatMessage(role: .assistant, text: turn.output.reply, changes: changes, notes: notes,
                                            restore: changes.isEmpty ? nil : restore, proposals: proposed.proposals))
        highlight(changes)
    }

    // MARK: Deshacer

    /// Undoing `id` would also discard edits made after it: by hand in the window or, in Respond, in the worktree.
    public func undoDiscardsLaterEdits(_ id: UUID) async -> Bool {
        guard let restore = session.messages.first(where: { $0.id == id })?.restore else { return false }
        switch subject {
        case .review:
            // The id counter only grows (undo keeps it): it isn't an edit.
            return restore.reviewEditsAfter.map { after in
                var current = reviewEdits
                current.addedCount = after.addedCount
                return after != current
            } ?? false
        case .respond(let draft):
            if let after = restore.selectionsAfter, after != selections { return true }
            guard let files = restore.files else { return false }
            return await backend.filesChangedSince(draft: draft, snapshot: files)
        case .merge:
            return false
        }
    }

    /// Only the last message with changes not undone (spec B.6).
    public func undo(_ id: UUID) {
        guard id == session.undoableMessageID, !isRunning, !session.readOnly,
              let index = session.messages.firstIndex(where: { $0.id == id }),
              let restore = session.messages[index].restore else { return }
        switch subject {
        case .merge:
            return
        case .review:
            if var before = restore.reviewEdits {
                before.addedCount = max(before.addedCount, reviewEdits.addedCount)
                reviewEdits = before
            }
            finishUndo(index)
        case .respond(let draft):
            guard let files = restore.files else {
                if let before = restore.selections { selections = before }
                finishUndo(index)
                return
            }
            let context = self.context()
            guard context.canEditFiles else {
                session.messages.append(ChatMessage(role: .error, text: "The fixes can’t change now, so Claude’s file changes can’t be undone."))
                hooks.persist(self)
                return
            }
            let undoID = UUID()
            turnID = undoID
            undoing = true
            setRunning(true, activity: "Undoing…")
            let backend = self.backend
            let before = restore.selections
            let outcome = JobOutcomeSlot<Result<RespondResult, Error>>()
            // Like a turn: it ends once the scheduler freed its slot (an undo is only cancelled by `cancelAll`).
            let ended: @MainActor (Result<Void, Error>) -> Void = { [weak self] _ in
                self?.finishUndoFiles(undoID, index: index, selections: before, outcome.value ?? .failure(CancellationError()))
            }
            let accepted = scheduler.enqueue(key, activity: .chat(subject.prID, sessionID: session.id), onStart: {}, work: {
                do {
                    outcome.value = .success(try await backend.undoFiles(draft: draft, snapshot: files, logURL: context.logURL))
                } catch {
                    outcome.value = .failure(error)
                }
            }, onComplete: ended, onCancelledEnd: ended)
            if !accepted {
                finishUndoFiles(undoID, index: index, selections: before,
                                .failure(ChatTurnNotStarted(errorDescription: Self.busyText)))
            }
        }
    }

    private func finishUndoFiles(_ id: UUID, index: Int, selections before: [String: RespondSelection]?,
                                 _ outcome: Result<RespondResult, Error>) {
        guard turnID == id else { return }
        turnID = nil
        undoing = false
        setRunning(false, activity: nil)
        switch outcome {
        case .success(let result):
            if let before { selections = before }
            hooks.resultChanged(result)
            finishUndo(index)
        case .failure(let error):
            session.messages.append(ChatMessage(role: .error, text: Self.message(for: error)))
            hooks.persist(self)
        }
    }

    private func finishUndo(_ index: Int) {
        session.messages[index].undone = true
        highlight(session.messages[index].changes)
        hooks.persist(self)
    }

    // MARK: Reglas propuestas

    /// Spec E.3: saves a pending proposal as a rule, with the user's edits, only when they press Save. Returns the
    /// error to show, or nil. It works on a read-only conversation too: a rule doesn't touch the PR.
    @discardableResult
    public func saveProposal(_ proposalID: UUID, in messageID: UUID, text: String, scope: RuleScope,
                             appliesTo: Set<RuleStage>) -> String? {
        guard let m = session.messages.firstIndex(where: { $0.id == messageID }),
              let p = session.messages[m].proposals.firstIndex(where: { $0.id == proposalID }),
              session.messages[m].proposals[p].status == .pending else { return nil }
        var proposal = session.messages[m].proposals[p]
        proposal.text = text
        proposal.scope = scope
        proposal.appliesTo = appliesTo
        do {
            proposal.ruleID = try hooks.saveRule(proposal)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        proposal.status = .saved
        session.messages[m].proposals[p] = proposal
        hooks.persist(self)
        return nil
    }

    public func dismissProposal(_ proposalID: UUID, in messageID: UUID) {
        guard let m = session.messages.firstIndex(where: { $0.id == messageID }),
              let p = session.messages[m].proposals.firstIndex(where: { $0.id == proposalID }),
              session.messages[m].proposals[p].status == .pending else { return }
        session.messages[m].proposals[p].status = .dismissed
        hooks.persist(self)
    }

    // MARK: Fin

    /// After posting or pushing: the conversation stays, read only, and its workspace is deleted.
    /// The conversation ends (posted, pushed, merged…): it's saved read only and its workspace deleted. A running turn
    /// is stopped first and the workspace goes once it really ended (Claude may be reading the worktree).
    public func markReadOnly() {
        guard !session.readOnly else { return }
        session.readOnly = true
        hooks.persist(self)
        if turnID != nil {
            discardWhenIdle = true
            stop()
        } else {
            discardWorkspace()
        }
    }

    /// Its review or respond goes away (discarded, replaced by a new run): a running turn is stopped first and the
    /// workspace deleted once it really ended (Claude may still be in the worktree).
    public func discard() {
        if turnID != nil {
            discardWhenIdle = true
            stop()
        } else {
            discardWorkspace()
        }
    }

    /// Deletes the chat's worktree (Review) or context and snapshot refs (Respond), in the background.
    public func discardWorkspace() {
        let backend = self.backend
        let session = self.session
        let subject = self.subject
        let localPath = context().localPath
        Task.detached(priority: .utility) {
            await backend.cleanup(session: session, subject: subject, localPath: localPath)
        }
    }

    // MARK: Privado

    private func currentState(_ context: ChatContext) -> String {
        switch subject {
        case .review(let draft): ChatPrompts.reviewState(draft: draft, edits: reviewEdits)
        case .respond(let draft): ChatPrompts.respondState(draft: draft, selections: selections, result: context.respondResult)
        case .merge(let target): ChatPrompts.mergeState(target: target, detail: context.mergeDetail)
        }
    }

    private func setRunning(_ running: Bool, activity: String?) {
        isRunning = running
        self.activity = activity
        if !running { partialText = "" }
        hooks.runningChanged(running)
        if !running, discardWhenIdle {
            discardWhenIdle = false
            discardWorkspace()
        }
    }

    private func highlight(_ changes: [ChatChange]) {
        let ids = Set(changes.compactMap(\.highlightID))
        guard !ids.isEmpty else { return }
        highlighted = ids
        let token = UUID()
        highlightToken = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.highlightDuration)
            guard let self, self.highlightToken == token else { return }
            self.highlighted = []
        }
    }

    static func message(for error: Error) -> String {
        if let claude = error as? ClaudeError {
            switch claude {
            case .invalidOutput, .noResult: return unreadableText
            case .failed: break
            }
        }
        if error is CancellationError { return stoppedText }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
