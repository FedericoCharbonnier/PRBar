import Foundation
import PRBarCore

private let claudeSession = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

private func reviewDraft(_ prID: String = "PR_1") -> ReviewDraft {
    ReviewDraft(prID: prID, repo: RepoRef(owner: "o", name: "r"), number: 7, title: "PR 7",
                url: URL(string: "https://github.com/o/r/pull/7")!, author: "ana", headOid: String(repeating: "a", count: 40),
                account: "me", summary: "S",
                items: [ReviewItem(finding: ReviewFinding(id: "f1", severity: .high, file: "src/a.ts", line: 1, title: "T1", body: "B1"),
                                   keep: true, reason: nil),
                        ReviewItem(finding: ReviewFinding(id: "f2", severity: .low, file: "src/a.ts", line: 2, title: "T2", body: "B2"),
                                   keep: true, reason: nil)])
}

private func respondDraft() -> RespondDraft {
    RespondDraft(prID: "PR_9", repo: RepoRef(owner: "o", name: "r"), number: 9, title: "PR 9",
                 url: URL(string: "https://github.com/o/r/pull/9")!, headRef: "f", account: "me",
                 worktree: ResolvedWorktree(path: "/tmp/wt/r-9", origin: .dedicated), startHeadOid: "",
                 items: [RespondItem(feedback: FeedbackItem(id: "thread:A", kind: .thread, path: "a.ts", line: 1, isOutdated: false,
                                                            comments: [FeedbackComment(databaseID: 1, author: "ana", isBot: false, body: "x",
                                                                                       createdAt: t0, url: URL(string: "https://github.com/o/r/pull/9")!)]),
                                     assessment: "ok", action: .reply, fixPlan: "", reply: "Old")])
}

private func output(_ reply: String = "OK", _ actions: [ChatAction] = []) -> ChatTurnOutput {
    ChatTurnOutput(reply: reply, actions: actions, claudeSessionID: claudeSession, rebuiltContext: false)
}

/// Backend en memoria. `held` deja los turnos colgados (cancelables) hasta que se lo pone en false.
final class FakeChatBackend: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _inputs: [ChatTurnInput] = []
    private var _replies: [Result<ChatTurnOutput, Error>] = []
    private var _held = false
    private var _editing = 0
    private var _undos: [String] = []
    private var _cleanups: [UUID] = []
    var files = ChatFilesOutcome(changedFiles: [], snapshot: nil, result: nil)
    var undoResult = RespondResult(items: [], diffStat: "before", tests: nil)
    var changedSince = false
    var note: String?

    var inputs: [ChatTurnInput] { lock.withLock { _inputs } }
    var editing: Int { lock.withLock { _editing } }
    var undos: [String] { lock.withLock { _undos } }
    var cleanups: [UUID] { lock.withLock { _cleanups } }
    var held: Bool {
        get { lock.withLock { _held } }
        set { lock.withLock { _held = newValue } }
    }

    func reply(_ results: Result<ChatTurnOutput, Error>...) { lock.withLock { _replies += results } }

    func workspace(_ request: ChatWorkspaceRequest) async throws -> ChatWorkspace {
        ChatWorkspace(directory: URL(fileURLWithPath: "/tmp/wt/chat"), contextDirectory: URL(fileURLWithPath: "/tmp/wt/chat.context"),
                      files: ChatContextFiles(diff: URL(fileURLWithPath: "/tmp/wt/chat.context/pr.diff")), diffFiles: ["src/a.ts"],
                      isDiffOnly: false, refs: ["refs/prbar/pr-7-0a1b2c3d"], note: note)
    }

    func send(_ input: ChatTurnInput, subject: ChatSubject, logURL: URL,
              onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ChatTurnOutput {
        lock.withLock { _inputs.append(input) }
        onEvent(.toolUse(name: "Read", detail: "/tmp/wt/chat/src/a.ts"))
        while held { try await Task.sleep(nanoseconds: 5_000_000) }
        try Task.checkCancellation()
        let next: Result<ChatTurnOutput, Error> = lock.withLock { _replies.isEmpty ? .success(output()) : _replies.removeFirst() }
        return try next.get()
    }

    func sendEditing(_ input: ChatTurnInput, draft: RespondDraft, result: RespondResult, sessionID: UUID, logURL: URL,
                     onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> (ChatTurnOutput, ChatFilesOutcome) {
        lock.withLock { _editing += 1 }
        return (try await send(input, subject: .respond(draft), logURL: logURL, onEvent: onEvent), files)
    }

    func undoFiles(draft: RespondDraft, snapshot: ChatFileSnapshot, logURL: URL) async throws -> RespondResult {
        lock.withLock { _undos.append(snapshot.ref) }
        return undoResult
    }

    func filesChangedSince(draft: RespondDraft, snapshot: ChatFileSnapshot) async -> Bool { changedSince }

    func cleanup(session: ChatSession, subject: ChatSubject, localPath: String?) async {
        lock.withLock { _cleanups.append(session.id) }
    }
}

@MainActor
private final class Harness {
    let backend = FakeChatBackend()
    let scheduler = JobScheduler<String>(maxConcurrent: ChatCoordinator.maxConcurrentChats)
    var context = ChatContext(pr: nil, localPath: nil, respondResult: nil, canEditFiles: false,
                              logURL: URL(fileURLWithPath: "/tmp/chat.log"))
    var persisted = 0
    var running: [Bool] = []
    var results: [RespondResult] = []
    var savedRules: [RuleProposal] = []

    private var hooks: ChatHooks {
        ChatHooks(persist: { [unowned self] _ in self.persisted += 1 },
                  runningChanged: { [unowned self] in self.running.append($0) },
                  resultChanged: { [unowned self] in self.results.append($0) },
                  saveRule: { [unowned self] proposal in
                      self.savedRules.append(proposal)
                      return UUID()
                  })
    }

    func review(_ draft: ReviewDraft = reviewDraft(), session: ChatSession? = nil) -> ChatCoordinator {
        ChatCoordinator(subject: .review(draft), session: session ?? ChatSession(prID: draft.prID, kind: .review),
                        backend: backend, scheduler: scheduler, context: { [unowned self] in self.context }, hooks: hooks)
    }

    func respond(_ draft: RespondDraft = respondDraft()) -> ChatCoordinator {
        let selections = Dictionary(uniqueKeysWithValues: draft.items.map { ($0.id, RespondSelection.defaults(for: $0)) })
        return ChatCoordinator(subject: .respond(draft), session: ChatSession(prID: draft.prID, kind: .respond),
                               selections: selections, backend: backend, scheduler: scheduler,
                               context: { [unowned self] in self.context }, hooks: hooks)
    }

    func finish(_ chat: ChatCoordinator) async throws {
        try await waitUntil { !chat.isRunning }
    }
}

enum ChatCoordinatorTests {
    static let cases: [TestCase] = [
        TestCase("chat coordinator: el primer mensaje de Review aplica las acciones, resalta y guarda") { @MainActor in
            let h = Harness()
            let chat = h.review()
            h.backend.reply(.success(output("Renamed #1.", [ChatAction(type: "editFinding", id: "f1", title: "Better")])))
            try expect(chat.send("  Rename #1  "))
            try expect(chat.isRunning)
            try expect(!chat.canSend)
            try await h.finish(chat)
            let input = h.backend.inputs[0]
            try expectEqual(input.claudeSessionID, nil)
            try expectEqual(input.message, "Rename #1")
            try expectEqual(input.turn, 1)
            try expectEqual(input.canEditFiles, false)
            try expect(input.bootstrap.contains("Current state of the window"))
            try expectEqual(input.workingDirectory.path, "/tmp/wt/chat")
            try expectEqual(input.additionalDirectories, [URL(fileURLWithPath: "/tmp/wt/chat.context")])
            try expectEqual(chat.reviewEdits.titles["f1"], "Better")
            try expectEqual(chat.session.messages.map(\.role), [.user, .assistant])
            let answer = chat.session.messages[1]
            try expectEqual(answer.text, "Renamed #1.")
            try expectEqual(answer.changes, [.findingEdited(id: "f1")])
            try expectEqual(answer.restore?.reviewEdits, ReviewEdits.initial(for: reviewDraft()))
            try expectEqual(chat.highlighted, ["f1"])
            try expectEqual(chat.session.claudeSessionID, claudeSession)
            try expectEqual(chat.session.pending, false)
            try expectEqual(chat.session.worktreePath, "/tmp/wt/chat")
            try expectEqual(chat.session.worktreeRefs, ["refs/prbar/pr-7-0a1b2c3d"])
            try expectEqual(h.running, [true, false])
            try expect(h.persisted >= 2)
            try expect(chat.canSend)
        },
        TestCase("chat coordinator: los turnos siguientes retoman la sesión y mandan el estado solo si cambió") { @MainActor in
            let h = Harness()
            let chat = h.review()
            chat.send("a")
            try await h.finish(chat)
            chat.send("b")
            try await h.finish(chat)
            try expectEqual(h.backend.inputs[1].claudeSessionID, claudeSession)
            try expectEqual(h.backend.inputs[1].stateIfChanged, nil)
            try expectEqual(h.backend.inputs[1].transcript.count, 2)
            try expectEqual(h.backend.inputs[1].turn, 2)
            chat.reviewEdits.generalComment = "Edited by hand"
            chat.send("c")
            try await h.finish(chat)
            try expect(h.backend.inputs[2].stateIfChanged?.contains("Edited by hand") == true)
        },
        TestCase("chat coordinator: acciones inválidas quedan como notas; un error deja un mensaje de error") { @MainActor in
            let h = Harness()
            let chat = h.review()
            h.backend.reply(.success(output("Added.", [ChatAction(type: "addFinding", title: "t", body: "b", severity: "low", file: "zzz.ts")])),
                            .failure(ClaudeError.invalidOutput("no json")))
            chat.send("add one")
            try await h.finish(chat)
            try expectEqual(chat.session.messages[1].changes, [])
            try expectEqual(chat.session.messages[1].notes.count, 1)
            try expectEqual(chat.session.undoableMessageID, nil)
            let before = chat.reviewEdits
            chat.send("again")
            try await h.finish(chat)
            try expectEqual(chat.session.messages.last?.role, .error)
            try expectEqual(chat.session.messages.last?.text, ChatCoordinator.unreadableText)
            try expectEqual(chat.reviewEdits, before)
        },
        TestCase("chat coordinator: un id de finding agregado no se reusa después de deshacerlo") { @MainActor in
            let h = Harness()
            let chat = h.review()
            let add = ChatAction(type: "addFinding", title: "t", body: "b", severity: "low", file: "src/a.ts")
            h.backend.reply(.success(output("Added.", [add])), .success(output("Added again.", [add])))
            chat.send("add one")
            try await h.finish(chat)
            try expectEqual(chat.reviewEdits.added.map(\.id), ["c1"])
            chat.undo(chat.session.messages[1].id)
            try expectEqual(chat.reviewEdits.added.map(\.id), [])
            chat.send("add it again")
            try await h.finish(chat)
            try expectEqual(chat.reviewEdits.added.map(\.id), ["c2"])
        },
        TestCase("chat coordinator: deshacer un agregado no hace que el turno anterior parezca editado a mano") { @MainActor in
            let h = Harness()
            let chat = h.review()
            let add = ChatAction(type: "addFinding", title: "t", body: "b", severity: "low", file: "src/a.ts")
            h.backend.reply(.success(output("Set.", [ChatAction(type: "setGeneralComment", text: "Hi")])), .success(output("Added.", [add])))
            chat.send("say hi")
            try await h.finish(chat)
            chat.send("add one")
            try await h.finish(chat)
            chat.undo(chat.session.messages[3].id)
            let dirty = await chat.undoDiscardsLaterEdits(chat.session.messages[1].id)
            try expect(!dirty)
        },
        TestCase("chat coordinator: Undo de Review va en orden inverso y avisa si hubo ediciones a mano") { @MainActor in
            let h = Harness()
            let chat = h.review()
            h.backend.reply(.success(output("Excluded.", [ChatAction(type: "setIncluded", id: "f1", included: false)])),
                            .success(output("Set.", [ChatAction(type: "setGeneralComment", text: "Hi")])))
            chat.send("exclude #1")
            try await h.finish(chat)
            chat.send("say hi")
            try await h.finish(chat)
            let first = chat.session.messages[1].id
            let second = chat.session.messages[3].id
            try expectEqual(chat.session.undoableMessageID, second)
            let clean = await chat.undoDiscardsLaterEdits(second)
            try expect(!clean)
            chat.reviewEdits.generalComment = "Hi!!"
            let dirty = await chat.undoDiscardsLaterEdits(second)
            try expect(dirty)
            chat.undo(first)
            try expect(!chat.reviewEdits.selected.contains("f1"))
            chat.undo(second)
            try expectEqual(chat.reviewEdits.generalComment, "")
            try expect(chat.session.messages[3].undone)
            try expectEqual(chat.session.undoableMessageID, first)
            chat.undo(first)
            try expect(chat.reviewEdits.selected.contains("f1"))
            try expectEqual(chat.session.undoableMessageID, nil)
        },
        TestCase("chat coordinator: Respond con archivos usa sendEditing, avisa el resultado y lo deshace") { @MainActor in
            let h = Harness()
            let r0 = RespondResult(items: [], diffStat: "r0", tests: nil)
            let r1 = RespondResult(items: [], diffStat: "r1", tests: nil)
            h.context.canEditFiles = true
            h.context.respondResult = r0
            h.backend.files = ChatFilesOutcome(
                changedFiles: ["a.ts"],
                snapshot: ChatFileSnapshot(ref: "refs/prbar/chat-x-1", tree: "t", headBefore: "h0", headAfter: "h1", resultBefore: r0),
                result: r1)
            h.backend.undoResult = r0
            let chat = h.respond()
            h.backend.reply(.success(output("Done.", [ChatAction(type: "draftReply", body: "Thanks", commentID: "thread:A")])))
            chat.send("change the code and reply")
            try await h.finish(chat)
            try expectEqual(h.backend.editing, 1)
            try expectEqual(h.backend.inputs[0].canEditFiles, true)
            try expectEqual(h.results, [r1])
            try expectEqual(chat.selections["thread:A"]?.replyText, "Thanks")
            let message = chat.session.messages[1]
            try expectEqual(message.changes, [.replyDrafted(commentID: "thread:A"), .filesChanged(["a.ts"])])
            h.backend.changedSince = true
            let dirty = await chat.undoDiscardsLaterEdits(message.id)
            try expect(dirty)
            chat.undo(message.id)
            try await h.finish(chat)
            try expectEqual(h.backend.undos, ["refs/prbar/chat-x-1"])
            try expectEqual(h.results, [r1, r0])
            try expectEqual(chat.selections["thread:A"]?.replyText, "Old")
            try expect(chat.session.messages[1].undone)
        },
        TestCase("chat coordinator: Respond que empezó de solo lectura avisa a Claude cuando ya puede editar") { @MainActor in
            let h = Harness()
            let chat = h.respond()
            chat.send("before implementing")
            try await h.finish(chat)
            try expectEqual(h.backend.inputs[0].capabilitiesChanged, false)
            try expectEqual(chat.session.canEditFiles, false)
            h.context.canEditFiles = true
            h.context.respondResult = RespondResult(items: [], diffStat: "", tests: nil)
            chat.send("now change the code")
            try await h.finish(chat)
            try expectEqual(h.backend.editing, 1)
            try expectEqual(h.backend.inputs[1].capabilitiesChanged, true)
            try expectEqual(chat.session.canEditFiles, true)
            chat.send("again")
            try await h.finish(chat)
            try expectEqual(h.backend.inputs[2].capabilitiesChanged, false)
        },
        TestCase("chat coordinator: Stop corta el turno y deja Stopped.") { @MainActor in
            let h = Harness()
            h.backend.held = true
            let chat = h.review()
            chat.send("long question")
            try await waitUntil { h.backend.inputs.count == 1 }
            chat.stop()
            try expectEqual(chat.activity, "Stopping…")
            try await h.finish(chat)
            try expectEqual(chat.session.messages.last?.text, ChatCoordinator.stoppedText)
            try expectEqual(chat.session.pending, false)
            try expect(chat.canSend)
        },
        TestCase("chat coordinator: como mucho 2 chats a la vez en toda la app") { @MainActor in
            let h = Harness()
            h.backend.held = true
            let chats = [h.review(reviewDraft("PR_1")), h.review(reviewDraft("PR_2")), h.review(reviewDraft("PR_3"))]
            for chat in chats { chat.send("hi") }
            try await waitUntil { h.backend.inputs.count == 2 }
            try await Task.sleep(nanoseconds: 50_000_000)
            try expectEqual(h.backend.inputs.count, 2)
            try expect(chats.allSatisfy(\.isRunning))
            h.backend.held = false
            for chat in chats { try await h.finish(chat) }
            try expectEqual(h.backend.inputs.count, 3)
        },
        TestCase("chat coordinator: un turno pendiente se recupera como Interrupted; bloqueado o de solo lectura no envía") { @MainActor in
            let h = Harness()
            var session = ChatSession(prID: "PR_1", kind: .review)
            session.messages = [ChatMessage(role: .user, text: "q")]
            session.pending = true
            let chat = h.review(session: session)
            try expectEqual(chat.session.messages.last?.text, ChatSession.interruptedText)
            try expectEqual(h.persisted, 1)
            chat.setLock("Posting the review…")
            try expect(!chat.send("hi"))
            chat.setLock(nil)
            chat.markReadOnly()
            try expect(!chat.send("hi"))
            try expect(chat.session.readOnly)
            try await waitUntil { h.backend.cleanups == [session.id] }
        },
        TestCase("chat coordinator: reglas y prompt propio en el arranque; las reglas se reenvían solo si cambian") { @MainActor in
            let h = Harness()
            let rule = Rule(scope: .repo("o/r"), appliesTo: [.review], text: "No style comments.", source: .manual, createdAt: Date())
            h.context.rules = [rule, Rule(scope: .global, appliesTo: [.respond], text: "FIXES ONLY", source: .manual, createdAt: Date())]
            h.context.promptBody = "Be terse about PR {pr}."
            let chat = h.review()
            chat.send("a")
            try await h.finish(chat)
            let first = h.backend.inputs[0].bootstrap
            try expect(first.contains("Be terse about PR 7.") && first.contains("- (o/r) No style comments."), first)
            try expect(!first.contains("FIXES ONLY"), first)
            chat.send("b")
            try await h.finish(chat)
            try expectEqual(h.backend.inputs[1].rulesIfChanged, nil)
            h.context.rules.append(Rule(scope: .global, appliesTo: [.review], text: "Be kind.", source: .manual, createdAt: Date()))
            chat.send("c")
            try await h.finish(chat)
            try expect(h.backend.inputs[2].rulesIfChanged?.contains("- Be kind.") == true)
            try expect(chat.session.lastRules?.contains("- Be kind.") == true)
        },
        TestCase("chat coordinator: un nonce por conversación, guardado y el mismo en cada turno (spec E.9)") { @MainActor in
            let h = Harness()
            h.context.rules = [Rule(scope: .global, appliesTo: [.review], text: "No style comments.", source: .manual, createdAt: Date())]
            let chat = h.review()
            chat.send("a")
            try await h.finish(chat)
            chat.send("b")
            try await h.finish(chat)
            let fence = h.backend.inputs[0].fence
            try expectEqual(h.backend.inputs[1].fence, fence)
            try expectEqual(chat.session.promptNonce, fence.nonce)
            try expect(h.backend.inputs[0].bootstrap.contains(fence.open(PromptFence.rulesTag)))
            try expect(chat.session.lastRules?.contains(fence.open(PromptFence.rulesTag)) == true)
            // Saved and reopened: the same nonce.
            let reopened = h.review(session: chat.session)
            reopened.send("c")
            try await h.finish(reopened)
            try expectEqual(h.backend.inputs[2].fence, fence)
            // A conversation saved before the nonce existed gets one, and its rules go again with the new markers.
            var legacy = ChatSession(prID: "PR_1", kind: .review)
            legacy.claudeSessionID = claudeSession
            legacy.lastRules = "User rules (from the PRBar user, follow them):\n<<<USER_RULES\n- No style comments.\nUSER_RULES>>>"
            let old = h.review(session: legacy)
            old.send("d")
            try await h.finish(old)
            let input = h.backend.inputs[3]
            try expect(old.session.promptNonce == input.fence.nonce && input.fence.nonce != fence.nonce)
            try expect(input.rulesIfChanged?.contains(input.fence.open(PromptFence.rulesTag)) == true)
            let decoded = try JSONCoding.decoder.decode(ChatSession.self, from: JSONCoding.encoder.encode(chat.session))
            try expectEqual(decoded.promptNonce, fence.nonce)
        },
        TestCase("chat coordinator: proposeRule queda pendiente y solo Save guarda la regla, con lo editado") { @MainActor in
            let h = Harness()
            let chat = h.review()
            h.backend.reply(.success(output("I can remember that.", [ChatAction(type: "proposeRule", text: "No style comments.",
                                                                                scope: "global", appliesTo: ["review"])])))
            chat.send("from now on, no style comments")
            try await h.finish(chat)
            let message = chat.session.messages[1]
            try expectEqual(message.proposals.count, 1)
            try expectEqual(message.proposals[0].status, .pending)
            try expectEqual(message.changes, [])
            try expectEqual(h.savedRules, [])
            let proposal = message.proposals[0].id
            let error = chat.saveProposal(proposal, in: message.id, text: "No style or format comments.",
                                          scope: .repo("o/r"), appliesTo: [.review, .respond])
            try expectEqual(error, nil)
            try expectEqual(h.savedRules.map(\.text), ["No style or format comments."])
            try expectEqual(h.savedRules[0].scope, .repo("o/r"))
            try expectEqual(chat.session.messages[1].proposals[0].status, .saved)
            try expect(chat.session.messages[1].proposals[0].ruleID != nil)
            _ = chat.saveProposal(proposal, in: message.id, text: "again", scope: .global, appliesTo: [.review])
            try expectEqual(h.savedRules.count, 1)
        },
        TestCase("chat coordinator: Dismiss no guarda nada") { @MainActor in
            let h = Harness()
            let chat = h.review()
            h.backend.reply(.success(output("Noted.", [ChatAction(type: "proposeRule", text: "x")])))
            chat.send("remember x")
            try await h.finish(chat)
            let message = chat.session.messages[1]
            chat.dismissProposal(message.proposals[0].id, in: message.id)
            try expectEqual(chat.session.messages[1].proposals[0].status, .dismissed)
            try expectEqual(h.savedRules, [])
        },
    ]
}
