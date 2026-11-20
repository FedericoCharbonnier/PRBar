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

    /// La sesión del PR, nueva si no había (el detalle se carga al abrir la ventana). `reusing`: el registro con que
    /// empieza una sesión nueva (por defecto, uno nuevo).
    @discardableResult
    func mergeSession(for item: ClassifiedPR, reusing existing: MergeRecord? = nil) -> MergeSession {
        if let session = mergeSessions[item.id] { return session }
        let record = existing ?? MergeRecord(item: item, startedAt: Date())
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

    /// Un merge hecho sin sesión (terminó mientras Retry le preguntaba a GitHub) completa el último intento fallido
    /// del PR en vez de dejar dos registros (Failed y Merged).
    private func recordMergeAttempt(_ item: ClassifiedPR, method: MergeMethod, status: MergeRecord.Status, error: String?,
                                    at date: Date) {
        let previous = status == .merged && mergeSessions[item.id] == nil ? mergeHistory.lastFailed(prID: item.id) : nil
        let session = mergeSession(for: item, reusing: previous)
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
        let alreadyOpen = WindowPresenter.shared.isOpen(id: windowID)
        WindowPresenter.shared.show(
            id: windowID, title: "Merge · \(item.pr.repo.name)#\(item.pr.number)", size: MergeWindow.size,
            options: WindowOptions(sharedFrameKey: "MergeWindowFrame", bridgesToolbar: true, toolbarStyle: .unified),
            contentID: session.record.id.uuidString
        ) {
            MergeWindow(model: self, session: session)
        }
        Task { await self.loadMergeWindow(session, alreadyOpen: alreadyOpen) }
    }

    /// La primera vez carga el resumen; reabierta refresca con el head fijo (spec G.8, `MergeWindowModel.opened`). Si
    /// la primera carga trae otro head que la lista, la lista está atrasada: se refresca una vez (así el snapshot no
    /// pone el banner con un head viejo). Un chat vacío que se abrió antes de cargar se rehace con el head cargado.
    private func loadMergeWindow(_ session: MergeSession, alreadyOpen: Bool) async {
        let firstLoad = session.window.shownHead == nil
        // Lo que lance la carga (p. ej. `gh auth token`) va en la fila "Merge <repo>#N" de PRBar Activity.
        await ProcessActivity.$current.withValue(.merge(session.prID)) { await session.window.opened(alreadyOpen: alreadyOpen) }
        rebuildMergeChatIfOutdated(session)
        if firstLoad, let shown = session.window.shownHead, let listed = currentItem(session.prID)?.pr.headOid, listed != shown {
            await prStore.refreshNow()
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

    /// "Reload" del banner: adopta el head nuevo y refresca la lista (un snapshot atrasado no vuelve a poner el
    /// banner). Un chat sin mensajes se rehace con ese head; uno con mensajes sigue (el panel avisa que Claude ve otro
    /// commit).
    func reloadMergeWindow(prID: String) async {
        guard let session = mergeSessions[prID] else { return }
        await session.window.reload()
        rebuildMergeChatIfOutdated(session)
        await prStore.refreshNow()
    }

    /// `MergeFlow.rebuildsChat`: el chat vacío que mira otro commit se descarta y se crea otro enseguida (el panel
    /// abierto no se queda sin chat). La sesión nueva tiene otro id: no comparte el worktree que se está borrando.
    private func rebuildMergeChatIfOutdated(_ session: MergeSession) {
        guard let chat = session.chat, case .merge(let target) = chat.subject,
              MergeFlow.rebuildsChat(chatHead: target.headOid, shownHead: session.window.shownHead,
                                     hasMessages: !chat.session.messages.isEmpty, isRunning: chat.isRunning) else { return }
        session.chat = nil
        session.record.chat = nil
        chat.discardWorkspace()
        _ = mergeChat(prID: session.prID)
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
        let window = session.window
        switch MergeFlow.windowMerge(current: current, options: mergeOptions(current), method: window.method,
                                     shownHead: window.shownHead, stale: window.isStale, blockedReason: jobsBlockedReason) {
        case .success(let request):
            Task { _ = await merge(request.item, method: request.method) }
        case .failure(let error):
            merges.reject(current.pinned(head: window.shownHead ?? current.pr.headOid), method: mergeWindowMethod(prID: prID),
                          error: error)
        }
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
                await ProcessActivity.$current.withValue(.merge(prID)) { await session.window.refresh() }
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
    /// Un intento que llegó a GitHub queda en el historial (`MergeRecord`, `MergeFlow.recordsAttempt`).
    @discardableResult
    func merge(_ item: ClassifiedPR, method: MergeMethod) async -> Result<MergeCompletion, MergeError> {
        let precheck: MergeError?
        if let current = currentItem(item.id) {
            precheck = MergePolicy.problem(current, method: method, options: mergeOptions(current))
        } else {
            precheck = .noLongerOpen
        }
        let result = await postings.track { await merges.merge(item, method: method, precheck: precheck) }
        if case .failure(let error) = result, MergeFlow.recordsAttempt(error) {
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
        resources.jobFinished()
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
