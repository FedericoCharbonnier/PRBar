import AppKit
import PRBarCore
import SwiftUI

/// Una sesión de merge de un PR (spec G, plan 11 decisión 7): el registro del historial, el estado de la ventana (el
/// detalle y el head fijo) y el chat. Se crea al abrir la ventana, al mergear desde la CLI o al chatear; termina después
/// de un merge, o cuando el PR sale de la lista sin la ventana abierta.
@MainActor
final class MergeSession: ObservableObject {
    let window: MergeWindowModel
    var record: MergeRecord
    /// El chat de la ventana; se crea la primera vez que se lo usa (`AppModel.mergeChat`).
    @Published var chat: ChatCoordinator?

    init(window: MergeWindowModel, record: MergeRecord) {
        self.window = window
        self.record = record
    }

    var prID: String { record.prID }
}

/// Ready to Merge (spec F) con la ventana de Merge (spec G). La UI (fila, menú contextual, ventana, notificación) y la
/// CLI pasan por acá.
extension AppModel {
    /// Métodos permitidos, método por defecto y si se puede mergear ahora.
    func mergeOptions(_ item: ClassifiedPR) -> MergeOptions {
        MergePolicy.options(for: item, snapshot: prStore.snapshot, config: configStore.config)
    }

    func currentItem(_ prID: String) -> ClassifiedPR? {
        prStore.snapshot?.items.first { $0.id == prID }
    }

    static func mergeWindowID(_ prID: String) -> String { "merge-\(prID)" }

    // MARK: Sesiones

    /// La sesión del PR, nueva si no había (el detalle se carga al abrir la ventana).
    @discardableResult
    func mergeSession(for item: ClassifiedPR) -> MergeSession {
        if let session = mergeSessions[item.id] { return session }
        let record = MergeRecord(item: item, startedAt: Date())
        let api = self.api
        let accounts = self.accounts
        let window = MergeWindowModel(prID: item.id, recordID: record.id) {
            let token = try await accounts.token(for: record.account)
            return try await api.mergeDetail(repo: record.repo, number: record.number, token: token)
        }
        let session = MergeSession(window: window, record: record)
        mergeSessions[item.id] = session
        return session
    }

    /// Con cada snapshot: una ventana cuyo PR tiene otro head muestra el banner (spec G.3); las sesiones de PRs que ya
    /// no están, sin ventana abierta ni merge en curso, terminan.
    func updateMergeSessions(_ snapshot: Snapshot) {
        for (prID, session) in mergeSessions {
            if let item = snapshot.items.first(where: { $0.id == prID }) {
                session.window.noteHead(item.pr.headOid)
            } else if !WindowPresenter.shared.isOpen(id: Self.mergeWindowID(prID)), merges.phases[prID]?.isActive != true {
                endMergeSession(prID)
            }
        }
    }

    /// Termina la sesión: el chat queda de solo lectura (se guarda y se borra su worktree).
    func endMergeSession(_ prID: String) {
        guard let session = mergeSessions.removeValue(forKey: prID) else { return }
        session.chat?.markReadOnly()
        saveMergeRecord(session)
    }

    /// Guarda el registro si hay algo que guardar: un mensaje del chat o un intento de merge.
    func saveMergeRecord(_ session: MergeSession) {
        if let chat = session.chat { session.record.chat = chat.session }
        guard session.record.status != .open || session.record.chat?.messages.isEmpty == false else { return }
        do {
            try mergeHistory.save(session.record)
        } catch {
            AppLog.write("History: couldn't save the merge of \(session.prID): \(error)")
        }
        historyRevision += 1
    }

    private func recordMergeAttempt(_ item: ClassifiedPR, method: MergeMethod, status: MergeRecord.Status, error: String?,
                                    at date: Date) {
        let session = mergeSession(for: item)
        session.record.method = method
        session.record.headOid = item.pr.headOid
        session.record.status = status
        session.record.errorMessage = error
        session.record.finishedAt = date
        saveMergeRecord(session)
    }

    // MARK: Ventana

    /// "Merge…" de la fila y del menú contextual, la notificación y `prbar open --merge`: abre la ventana (spec G.1). Un
    /// PR ya mergeado no hace nada; el resto (también uno que todavía no se puede mergear) abre la ventana, que dice
    /// por qué.
    func requestMerge(_ item: ClassifiedPR) {
        guard MergeFlow.request(phase: merges.phases[item.id]) == .open else { return }
        openMergeWindow(item)
    }

    func openMergeWindow(_ item: ClassifiedPR) {
        let session = mergeSession(for: item)
        let windowID = Self.mergeWindowID(item.id)
        WindowPresenter.shared.show(
            id: windowID, title: "Merge · \(item.pr.repo.name)#\(item.pr.number)", size: MergeWindow.size,
            options: WindowOptions(sharedFrameKey: "MergeWindowFrame", bridgesToolbar: true, toolbarStyle: .unified),
            contentID: session.record.id.uuidString
        ) {
            MergeWindow(model: self, session: session)
        }
        if session.window.detail == nil, !session.window.isLoading {
            Task { await session.window.load() }
        }
    }

    /// Click en "is ready to merge": la ventana si el PR sigue en la lista; si no, el PR en el navegador.
    func openMergeFromNotification(prID: String) {
        if let item = currentItem(prID) {
            requestMerge(item)
        } else if let url = PRReference.githubURL(prID: prID) {
            NSWorkspace.shared.open(url)
        }
    }

    /// ⌘R de la ventana: el detalle (con el mismo head lo reemplaza; con otro, el banner) y la lista.
    func refreshMergeWindow(prID: String) async {
        guard let session = mergeSessions[prID] else { return }
        await session.window.refresh()
        await prStore.refreshNow()
    }

    /// "Reload" del banner: adopta el head nuevo. Un chat sin mensajes se rehace con ese head; uno con mensajes sigue (el
    /// panel avisa que Claude ve otro commit).
    func reloadMergeWindow(prID: String) async {
        guard let session = mergeSessions[prID] else { return }
        await session.window.reload()
        if let chat = session.chat, chat.session.messages.isEmpty, !chat.isRunning,
           case .merge(let target) = chat.subject, target.headOid != session.window.shownHead {
            session.chat = nil
            chat.discardWorkspace()
        }
    }

    /// Por qué el botón Merge de la ventana está deshabilitado (`nil` = se puede).
    func mergeWindowProblem(prID: String) -> String? {
        guard let session = mergeSessions[prID] else { return nil }
        let current = currentItem(prID)
        return MergeFlow.windowProblem(
            current: current, options: current.map(mergeOptions), method: session.window.method,
            shownHead: session.window.shownHead, stale: session.window.isStale, blockedReason: jobsBlockedReason)
    }

    /// El método que muestra el popup: el elegido o el por defecto del repo.
    func mergeWindowMethod(prID: String) -> MergeMethod? {
        guard let session = mergeSessions[prID] else { return nil }
        return session.window.method ?? currentItem(prID).flatMap { mergeOptions($0).defaultMethod }
    }

    /// El botón de la ventana: mergea **el head que muestra la ventana** (spec G.3), con el método del popup. Si no se
    /// puede, la ventana y la fila muestran por qué (F.8.19).
    func mergeFromWindow(prID: String) {
        guard let session = mergeSessions[prID], let current = currentItem(prID) else { return }
        session.window.noteHead(current.pr.headOid)
        let method = mergeWindowMethod(prID: prID)
        let pinned = current.pinned(head: session.window.shownHead ?? current.pr.headOid)
        if let problem = mergeWindowProblem(prID: prID) {
            merges.reject(pinned, method: method, error: jobsBlockedReason == nil ? .unavailable(problem) : .blocked(problem))
            return
        }
        guard let method else { return }
        Task { _ = await merge(pinned, method: method) }
    }

    /// Retry de la ventana (spec G.2 con F.8.11/F.8.20): refresca la lista y la ventana y decide con `MergeFlow.retry`:
    /// si el PR cambió (head distinto, o el error fue `headChanged`) solo limpia el error y la ventana queda con el
    /// banner; si es el mismo head, vuelve a mergear lo que muestra la ventana; si ya no está en la lista, le pregunta a
    /// GitHub si se mergeó.
    func retryMergeInWindow(prID: String) {
        guard let failure = merges.failure(prID: prID) else { return }
        merges.dismiss(prID: prID)
        Task {
            await prStore.refreshNow()
            if let session = mergeSessions[prID] {
                await session.window.refresh()
                session.window.noteHead(currentItem(prID)?.pr.headOid)
            }
            switch MergeFlow.retry(failure, current: currentItem(prID)) {
            case .request(_, let method):
                if let method { mergeSessions[prID]?.window.method = method }
                mergeFromWindow(prID: prID)
            case .changed:
                break
            case .missing:
                await merges.resolveMissing(failure)
            }
        }
    }

    func dismissMergeError(prID: String) {
        merges.dismiss(prID: prID)
    }

    // MARK: Merge

    /// Mergea sin preguntar (la ventana ya mostró el PR, o la CLI confirmó). Usa el `headOid` de `item` (la ventana
    /// pasa el head que mostró): si alguien pusheó después, GitHub lo rechaza (`MergeError.headChanged`). Antes vuelve a
    /// mirar el PR en el snapshot actual: si ya no está en Ready to Merge, el botón estaría deshabilitado o el repo no
    /// permite `method`, no lo manda (`MergeError.unavailable`; `.noLongerOpen` si ya no está en la lista). Cuenta en
    /// `postings`: una actualización espera a que termine; mientras se instala una, no empieza (`MergeError.blocked`).
    /// El intento queda en el historial (`MergeRecord`).
    @discardableResult
    func merge(_ item: ClassifiedPR, method: MergeMethod) async -> Result<MergeCompletion, MergeError> {
        let precheck: MergeError?
        if let current = currentItem(item.id) {
            precheck = MergePolicy.problem(current, method: method, options: mergeOptions(current))
        } else {
            precheck = .noLongerOpen
        }
        let result = await postings.track { await merges.merge(item, method: method, precheck: precheck) }
        if case .failure(let error) = result, error != .alreadyInProgress, error != .alreadyMerged {
            recordMergeAttempt(item, method: method, status: .failed, error: error.localizedDescription, at: Date())
        }
        return result
    }

    /// Settings › Repos: `nil` = el método por defecto de GitHub.
    func setMergeMethod(_ method: MergeMethod?, repoID: String, login: String) {
        updateConfig(refresh: false) { $0.setMergeMethod(method, repoID: repoID, login: login) }
    }

    /// Lo llama `MergeQueue` después de un merge (también uno que `resolveMissing` encontró hecho): el historial,
    /// "Merged" en Slack y, a los 2 s ("Merged ✓" en la fila y en la ventana), se cierra la ventana, termina la sesión y
    /// un refresco saca la fila.
    func mergeFinished(_ completion: MergeCompletion) {
        let item = completion.item
        recordMergeAttempt(item, method: completion.method, status: .merged, error: nil, at: completion.mergedAt)
        mergeSessions[item.id]?.chat?.markReadOnly()
        let config = configStore.config
        let slack = self.slack
        let postings = self.postings
        // Se guarda ahora, dentro del `postings.track` del merge: una actualización o un cierre justo después no lo
        // pierden. Publicarlo puede esperar al Task (o al próximo ciclo).
        if slack.queueMergedReply(item.pr, method: completion.method, config: config) {
            Task { await postings.track { await slack.postQueued(config: config) } }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            WindowPresenter.shared.close(id: Self.mergeWindowID(item.id))
            self.endMergeSession(item.id)
            // Espera un refresco en curso (pudo empezar antes del merge) y refresca de nuevo; el snapshot nuevo
            // descarta la fase "Merged" (`mergePruneObserver`).
            await self.prStore.refreshNow()
        }
    }

    // MARK: Chat

    /// El chat de la ventana de Merge (spec G.4): solo lectura, sobre el head que muestra la ventana. `nil` si el PR ya
    /// no está en la lista.
    func mergeChat(prID: String) -> ChatCoordinator? {
        if let chat = mergeSessions[prID]?.chat { return chat }
        guard let item = currentItem(prID) else { return nil }
        let session = mergeSession(for: item)
        let record = session.record
        let target = MergeChatTarget(recordID: record.id, item: item, headOid: session.window.shownHead ?? item.pr.headOid)
        let logURL = mergeHistory.logURL(for: record.id)
        let chat = ChatCoordinator(
            subject: .merge(target), session: record.chat ?? ChatSession(prID: prID, kind: .merge),
            backend: chatBackend, scheduler: chatScheduler,
            context: { [weak self, weak session] in
                ChatContext(pr: self?.currentItem(prID)?.pr, localPath: self?.localPath(account: item.account, repo: item.pr.repo),
                            respondResult: nil, canEditFiles: false, logURL: logURL, rules: self?.instructions.rules ?? [],
                            promptBody: self?.configStore.config.claude.chatPromptBody(.mergeChat),
                            mergeDetail: session?.window.detail)
            },
            hooks: ChatHooks(persist: { [weak self, weak session] _ in
                                 guard let self, let session else { return }
                                 self.saveMergeRecord(session)
                             },
                             saveRule: { [weak self] proposal in
                                 guard let self else { throw RuleError.unavailable }
                                 return try self.saveProposedRule(proposal)
                             })
        )
        session.chat = chat
        return chat
    }
}
