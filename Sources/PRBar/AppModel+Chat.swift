import Foundation
import PRBarCore

/// `prbar chat …` (spec C.4): el mismo coordinador del chat que el panel de la ventana de Review o Respond.
extension AppModel: ChatCommandActions {
    /// El coordinador del chat del PR: el del review listo (PR ajeno) o el del análisis de Respond (PR propio).
    func chatCoordinator(_ prID: String) throws -> ChatCoordinator {
        if case .ready(let draft)? = reviews.phases[prID] { return reviewChat(for: draft) }
        if let record = respond.records[prID] {
            let chat = respondChat(for: record.draft)
            syncRespondChatState(prID, chat)
            return chat
        }
        throw CommandFailure(.invalidState, "There’s no ready review or Respond analysis of \(prID) to chat about. Run `prbar review \(prID)` or `prbar respond \(prID)`.")
    }

    /// Lo que la ventana de Respond le pone al chat (`chatLock`, `isFinished`), también sin la ventana abierta.
    private func syncRespondChatState(_ prID: String, _ chat: ChatCoordinator) {
        let finished: Bool
        if case .done? = respond.phases[prID] { finished = true } else { finished = respond.records[prID]?.pushed == true }
        if finished { chat.markReadOnly() }
        let lock: String? = switch respond.phases[prID] {
        case .queued?, .preparing?, .analyzing?: "Wait for the analysis to finish."
        case .implementing?: "Claude is implementing the fixes."
        case .pushing?: "Pushing and posting the replies…"
        default: respond.runningTests.contains(prID) ? "The tests are running." : nil
        }
        chat.setLock(lock)
    }

    func chatInfo(_ prID: String, _ chat: ChatCoordinator, streamed: Bool = false) -> ChatInfo {
        ChatInfo(pr: prID, kind: chat.session.kind.rawValue, messages: chat.session.messages,
                 undoableMessageID: chat.session.undoableMessageID, canUndo: chat.canUndo, readOnly: chat.session.readOnly,
                 running: chat.isRunning, lockReason: chat.lockReason, streamed: streamed, number: chat.number(of:))
    }

    func chatSend(pr: String, message: String, events: CommandEventSink) async throws -> ChatInfo {
        let id = try resolvePRID(pr)
        guard chatEnabled else { throw CommandFailure(.invalidState, "The chat is off. Turn it on with `prbar claude set --chat on`.") }
        if let reason = chatUnavailableReason { throw CommandFailure(.invalidState, reason) }
        let chat = try chatCoordinator(id)
        if chat.session.readOnly {
            throw CommandFailure(.invalidState, "This conversation is read only (the review was posted or the fixes pushed).")
        }
        if chat.isRunning { throw CommandFailure(.invalidState, "Claude is still answering. Wait, or stop it with `prbar chat \(id) --stop`.") }
        if let reason = chat.lockReason { throw CommandFailure(.invalidState, reason) }
        guard chat.send(message) else { throw CommandFailure(.invalidUsage, "Write a message.") }
        let streamed = try await streamTurn(isRunning: { chat.isRunning }, partial: { chat.partialText },
                                            activity: { chat.activity }, events: events)
        return chatInfo(id, chat, streamed: streamed)
    }

    /// Manda el texto parcial y la actividad del turno como eventos hasta que termina. `true` si mandó texto.
    func streamTurn(isRunning: () -> Bool, partial: () -> String, activity: () -> String?,
                    events: CommandEventSink) async throws -> Bool {
        var streamed = ""
        var lastActivity: String?
        while isRunning() {
            let text = partial()
            if text.count > streamed.count, text.hasPrefix(streamed) {
                events(.text(delta: String(text.dropFirst(streamed.count))))
                streamed = text
            }
            if activity() != lastActivity {
                lastActivity = activity()
                if let lastActivity { events(.progress(message: lastActivity)) }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return !streamed.isEmpty
    }

    func chatShow(pr: String) throws -> ChatInfo {
        let id = try resolvePRID(pr)
        return chatInfo(id, try chatCoordinator(id))
    }

    func chatUndo(pr: String, confirmed: Bool) async throws -> ChatInfo {
        let id = try resolvePRID(pr)
        let chat = try chatCoordinator(id)
        guard chat.canUndo, let message = chat.session.undoableMessageID else {
            throw CommandFailure(.invalidState, "There’s nothing to undo.")
        }
        if !confirmed, await chat.undoDiscardsLaterEdits(message) {
            throw CommandFailure(.confirmationRequired, "Undo will also discard your manual edits since then.")
        }
        chat.undo(message)
        // En Respond, deshacer archivos corre como un job más.
        while chat.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        return chatInfo(id, chat)
    }

    func chatStop(pr: String) throws -> ChatInfo {
        let id = try resolvePRID(pr)
        let chat = try chatCoordinator(id)
        guard chat.isRunning else { throw CommandFailure(.invalidState, "Claude isn’t answering anything in \(id).") }
        chat.stop()
        return chatInfo(id, chat)
    }
}
