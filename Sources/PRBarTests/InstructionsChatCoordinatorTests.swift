import Combine
import Foundation
import PRBarCore

private let session = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

final class FakeInstructionsBackend: InstructionsChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _inputs: [InstructionsTurnInput] = []
    private var _replies: [Result<InstructionsTurnOutput, Error>] = []
    private var _held = false

    var inputs: [InstructionsTurnInput] { lock.withLock { _inputs } }
    var held: Bool {
        get { lock.withLock { _held } }
        set { lock.withLock { _held = newValue } }
    }

    func reply(_ reply: String, _ actions: [RuleAction] = []) {
        lock.withLock { _replies.append(.success(InstructionsTurnOutput(reply: reply, actions: actions, claudeSessionID: session,
                                                                        rebuiltContext: false))) }
    }

    func send(_ input: InstructionsTurnInput,
              onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> InstructionsTurnOutput {
        lock.withLock { _inputs.append(input) }
        while held { try await Task.sleep(nanoseconds: 5_000_000) }
        try Task.checkCancellation()
        let next = lock.withLock { () -> Result<InstructionsTurnOutput, Error> in
            _replies.isEmpty ? .success(InstructionsTurnOutput(reply: "OK", actions: [], claudeSessionID: session, rebuiltContext: false))
                             : _replies.removeFirst()
        }
        return try next.get()
    }
}

@MainActor
private func make(_ dir: URL, backend: FakeInstructionsBackend) -> (InstructionsStore, InstructionsChatCoordinator) {
    let store = InstructionsStore(fileURL: dir.appendingPathComponent("instructions.json"))
    let chat = InstructionsChatCoordinator(store: store, backend: backend, scheduler: JobScheduler<String>(maxConcurrent: 2),
                                           repos: { ["acme/web-app"] })
    return (store, chat)
}

enum InstructionsChatCoordinatorTests {
    static let cases: [TestCase] = [
        TestCase("instructions coordinator: aplica las acciones, resalta, guarda y deshace") { @MainActor in
            let dir = try temporaryDirectory()
            let backend = FakeInstructionsBackend()
            let (store, chat) = make(dir, backend: backend)
            backend.reply("Added a global rule.", [RuleAction(type: "addRule", appliesTo: ["review"], text: "No style comments.")])
            try expect(chat.send("no comentes estilo"))
            try await waitUntil { !chat.isRunning }
            try expectEqual(store.rules.map(\.text), ["No style comments."])
            try expectEqual(store.rules[0].source, .settingsChat)
            let message = chat.chat.messages[1]
            try expectEqual(message.changes, [.ruleAdded(id: store.rules[0].id.uuidString)])
            try expectEqual(chat.highlighted, [store.rules[0].id.uuidString])
            try expectEqual(chat.chat.claudeSessionID, session)
            try expectEqual(store.file.chat.messages.count, 2)
            try expect(backend.inputs[0].bootstrap.contains("acme/web-app"))
            try expect(!chat.undoDiscardsLaterEdits(message.id))
            try store.setRuleEnabled(store.rules[0].id, false)
            try expect(chat.undoDiscardsLaterEdits(message.id))
            try expectEqual(chat.undo(message.id), nil)
            try expectEqual(store.rules, [])
            try expect(chat.chat.messages[1].undone)
        },
        TestCase("instructions coordinator: acciones inválidas quedan como notas; el estado se reenvía solo si cambió") { @MainActor in
            let dir = try temporaryDirectory()
            let backend = FakeInstructionsBackend()
            let (store, chat) = make(dir, backend: backend)
            backend.reply("Hm.", [RuleAction(type: "addRule", scope: "repo", repo: "evil/x", text: "x")])
            chat.send("a")
            try await waitUntil { !chat.isRunning }
            try expectEqual(chat.chat.messages[1].notes.count, 1)
            try expectEqual(store.rules, [])
            chat.send("b")
            try await waitUntil { !chat.isRunning }
            try expectEqual(backend.inputs[1].claudeSessionID, session)
            try expectEqual(backend.inputs[1].stateIfChanged, nil)
            try store.addRule("By hand.", scope: .global, appliesTo: [.review], source: .manual)
            chat.send("c")
            try await waitUntil { !chat.isRunning }
            try expect(backend.inputs[2].stateIfChanged?.contains("By hand.") == true)
        },
        TestCase("instructions coordinator: Stop deja Stopped.; un turno pendiente vuelve como Interrupted") { @MainActor in
            let dir = try temporaryDirectory()
            let backend = FakeInstructionsBackend()
            backend.held = true
            let (_, chat) = make(dir, backend: backend)
            chat.send("long")
            try await waitUntil { backend.inputs.count == 1 }
            chat.stop()
            try await waitUntil { !chat.isRunning }
            try expectEqual(chat.chat.messages.last?.text, ChatCoordinator.stoppedText)
            var pending = InstructionsChat()
            pending.messages = [ChatMessage(role: .user, text: "q")]
            pending.pending = true
            let other = try temporaryDirectory()
            let store = InstructionsStore(fileURL: other.appendingPathComponent("instructions.json"))
            try store.saveChat(pending)
            let reopened = InstructionsChatCoordinator(store: store, backend: backend, scheduler: JobScheduler<String>(maxConcurrent: 2),
                                                       repos: { [] })
            try expectEqual(reopened.chat.messages.last?.text, ChatSession.interruptedText)
            try expectEqual(store.file.chat.pending, false)
        },
        TestCase("instructions coordinator: cuando un turno deja de correr, el scheduler ya liberó su lugar") { @MainActor in
            let dir = try temporaryDirectory()
            let backend = FakeInstructionsBackend()
            let scheduler = JobScheduler<String>(maxConcurrent: 2)
            let store = InstructionsStore(fileURL: dir.appendingPathComponent("instructions.json"))
            let chat = InstructionsChatCoordinator(store: store, backend: backend, scheduler: scheduler, repos: { [] })
            // `@Published` publishes in willSet: this runs at the exact moment the chat stops counting as running,
            // when a send would already be accepted.
            var slotBusyWhenStopped: [Bool] = []
            let observer = chat.$isRunning.dropFirst().filter { !$0 }.sink { _ in
                slotBusyWhenStopped.append(scheduler.isActive(InstructionsChatCoordinator.key))
            }
            defer { observer.cancel() }
            try expect(chat.send("a"))
            try await waitUntil { !slotBusyWhenStopped.isEmpty }
            try expectEqual(slotBusyWhenStopped, [false])
            // And so a message sent right away isn't dropped.
            try await waitUntil { !chat.isRunning }
            try expect(chat.send("b"))
            try await waitUntil { !chat.isRunning }
            try expectEqual(backend.inputs.map(\.message), ["a", "b"])
            try expect(!chat.chat.pending)
        },
        TestCase("instructions coordinator: si el scheduler no acepta el turno, el mensaje queda con un error (no pendiente)") { @MainActor in
            let dir = try temporaryDirectory()
            let backend = FakeInstructionsBackend()
            backend.held = true
            let scheduler = JobScheduler<String>(maxConcurrent: 2)
            // Something else holds the chat's key (two coordinators never coexist in the app, but the rule holds).
            let other = InstructionsChatCoordinator(store: InstructionsStore(fileURL: dir.appendingPathComponent("a.json")),
                                                    backend: backend, scheduler: scheduler, repos: { [] })
            let store = InstructionsStore(fileURL: dir.appendingPathComponent("b.json"))
            let chat = InstructionsChatCoordinator(store: store, backend: backend, scheduler: scheduler, repos: { [] })
            other.send("long")
            try await waitUntil { backend.inputs.count == 1 }
            try expect(chat.send("meanwhile"))
            try expect(!chat.isRunning)
            try expect(chat.canSend)
            try expect(!chat.chat.pending)
            try expectEqual(chat.chat.messages.map(\.role), [.user, .error])
            try expectEqual(chat.chat.messages.last?.text, InstructionsChatCoordinator.busyText)
            try expectEqual(store.file.chat.pending, false)
            backend.held = false
            try await waitUntil { !other.isRunning }
        },
        TestCase("instructions coordinator: los tokens del mensaje se tachan antes de mandarlo, guardarlo o loguearlo") { @MainActor in
            let dir = try temporaryDirectory()
            let backend = FakeInstructionsBackend()
            let (store, chat) = make(dir, backend: backend)
            chat.send("never log ghp_abcdefghijklmnopqrstuvwxyz0123 please")
            try await waitUntil { !chat.isRunning }
            try expectEqual(backend.inputs[0].message, "never log *** please")
            try expectEqual(chat.chat.messages[0].text, "never log *** please")
            try expectEqual(store.file.chat.messages[0].text, "never log *** please")
        },
        TestCase("instructions coordinator: un turno detenido o fallido no da el estado por visto") { @MainActor in
            let dir = try temporaryDirectory()
            let backend = FakeInstructionsBackend()
            let (store, chat) = make(dir, backend: backend)
            chat.send("a")
            try await waitUntil { !chat.isRunning }
            try store.addRule("New rule.", scope: .global, appliesTo: [.review], source: .manual)
            // Stopped while queued: the scheduler is busy with another chat.
            let busy = JobScheduler<String>(maxConcurrent: 1)
            busy.enqueue("other", onStart: {}, work: { try await Task.sleep(nanoseconds: 2_000_000_000) }, onComplete: { _ in })
            let queued = InstructionsChatCoordinator(store: store, backend: backend, scheduler: busy, repos: { ["acme/web-app"] })
            queued.send("b")
            queued.stop()
            try await waitUntil { !queued.isRunning }
            try expectEqual(queued.chat.messages.last?.text, ChatCoordinator.stoppedText)
            busy.cancel("other")
            queued.send("c")
            try await waitUntil { !queued.isRunning }
            try expect(backend.inputs.last?.stateIfChanged?.contains("New rule.") == true)
            // Stopped while running.
            try store.addRule("Another.", scope: .global, appliesTo: [.review], source: .manual)
            backend.held = true
            queued.send("d")
            try await waitUntil { backend.inputs.count == 3 }
            queued.stop()
            try await waitUntil { !queued.isRunning }
            backend.held = false
            queued.send("e")
            try await waitUntil { !queued.isRunning }
            try expect(backend.inputs.last?.stateIfChanged?.contains("Another.") == true)
        },
    ]
}
