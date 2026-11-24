import Foundation

/// Estado de "Responder" por PR. Cada etapa (análisis, fixes, tests, publicación) es un job de `JobScheduler`:
/// a lo sumo `maxConcurrent` en paralelo entre todos los PRs, y uno por PR a la vez.
///
/// - El registro (`RespondRecord`) se guarda en `RespondHistory` en cada transición (ready, implementing,
///   readyToPush, tests, done, failed) y además después de cada respuesta publicada y del push: un reintento
///   nunca repite lo que ya salió.
/// - `onEvent` se llama con las fases a las que se llega al terminar un job: `ready`, `readyToPush` (también al
///   completar los tests), `done` y `failed`.
/// - Cancelar durante `implementing` mata a Claude; el pipeline deja el árbol limpio sin borrar los commits ya
///   hechos. Mientras eso termina la fase sigue en `implementing` y el PR no acepta otro job. Después pasa a
///   `failed("Cancelado: quedaron N commits sin pushear en <path>")` o, si no quedó ninguno, vuelve a `ready`.
/// - Un push o una publicación en curso no se cancelan con `cancel` (no se pueden deshacer a medias): solo
///   `cancelAll`, al salir de la app.
/// - El worktree de PRBar (y su ref) se borra al llegar a `done` y con `dismiss`; después de un fallo queda para
///   que el usuario lo revise (lo borra `dismiss`, o la limpieza del próximo arranque si no tiene trabajo sin pushear).
@MainActor
public final class RespondQueue: ObservableObject {
    @Published public private(set) var phases: [String: RespondPhase] = [:]   // por prID
    /// PRs con el `testCommand` corriendo (la fase sigue en `readyToPush`).
    @Published public private(set) var runningTests: Set<String> = []
    /// PRs whose push PRBar stopped because the tests failed (spec E.5): the window offers "Push Anyway".
    @Published public private(set) var pushBlockedByTests: Set<String> = []
    /// El registro vigente de cada PR, desde que terminó el análisis hasta `dismiss`.
    @Published public private(set) var records: [String: RespondRecord] = [:]
    /// PRs with a chat turn running (spec B.2): no job starts on them until it ends.
    @Published public private(set) var chatting: Set<String> = []
    /// What each PR's run is: answering feedback or a Fix CI (spec K). Set when it starts, until `dismiss`.
    @Published public private(set) var modes: [String: RespondMode] = [:]
    /// Fix CI: PRs whose push PRBar stopped because the failing checks pass now (spec K.6.6), with the reason. The
    /// window offers "Push Anyway".
    @Published public private(set) var pushBlockedByCI: [String: String] = [:]
    /// PRs whose implementation was canceled with commits or changes left in the worktree (`RespondCancellation`), or
    /// failed (it may have committed some fixes), until `dismiss`.
    @Published public private(set) var leftWork: Set<String> = []
    /// Cuándo empezó la corrida de cada PR y si la pidió un iPhone (grupo Claude de la ventana principal, spec M.4).
    @Published public private(set) var runs: [String: ClaudeRunInfo] = [:]
    /// Set only while `onEvent` hears the `readyToPush` of a push the CI stopped (the checks pass now).
    private var reportingCIBlock: String?
    public func isReportingCIBlock(_ prID: String) -> Bool { reportingCIBlock == prID }

    private enum Kind { case analyze, implement, tests, publish }

    private struct Job {
        let id: UUID
        let kind: Kind
        /// Fase a la que se vuelve si se cancela mientras espera en la cola.
        let previous: RespondPhase?
    }

    private let pipeline: RespondPipelineRunning
    private let history: RespondHistory
    private let scheduler: JobScheduler<String>
    private let onEvent: @MainActor (String, RespondPhase) -> Void
    /// A push finished (spec T.3): the worktree is kept for "Open in Terminal" instead of deleted. `nil` = delete it.
    private let onRetain: (@MainActor (RespondRecord) -> Void)?
    /// El job vigente de cada PR (en cola o corriendo): lo que avise una corrida vieja se ignora.
    private var jobs: [String: Job] = [:]
    /// Implementaciones canceladas que todavía están restaurando el árbol.
    private var cancelling: [String: UUID] = [:]

    public init(pipeline: RespondPipelineRunning, history: RespondHistory = RespondHistory(), maxConcurrent: Int = 2,
                onEvent: @escaping @MainActor (String, RespondPhase) -> Void,
                onRetain: (@MainActor (RespondRecord) -> Void)? = nil) {
        self.pipeline = pipeline
        self.history = history
        self.scheduler = JobScheduler(maxConcurrent: maxConcurrent)
        self.onEvent = onEvent
        self.onRetain = onRetain
    }

    /// PRs with work that isn't pushed: fixes ready to push (or whose push failed) and implementations canceled or
    /// failed with commits or changes left. Quitting or updating warns about them: the records live in memory only
    /// (the worktree stays on disk, `WorktreeResolver.cleanupOrphans` keeps it).
    public var unpushedWork: Set<String> {
        var prIDs = leftWork
        for (prID, record) in records where record.result != nil && !record.pushed {
            if case .done? = phases[prID] { continue }
            prIDs.insert(prID)
        }
        return prIDs
    }

    // MARK: - Acciones

    public func setChatRunning(_ running: Bool, prID: String) {
        if running { chatting.insert(prID) } else { chatting.remove(prID) }
    }

    /// A chat turn may start: nothing is running or queued on the PR (implementing, tests, pushing).
    public func canChat(prID: String) -> Bool {
        jobs[prID] == nil && cancelling[prID] == nil && !runningTests.contains(prID)
    }

    /// The decisions as the window and the chat left them, saved in the record of `draftID`.
    public func updateSelections(prID: String, draftID: UUID, selections: [String: RespondSelection]) {
        guard var record = records[prID], record.id == draftID, jobs[prID] == nil else { return }
        record.selections = selections
        records[prID] = record
        save(record)
    }

    /// A chat turn committed (or undid) changes in `readyToPush`: the diff the user reviews and what gets pushed change.
    public func replaceResult(prID: String, draftID: UUID, result: RespondResult) {
        guard case .readyToPush(let draft, _)? = phases[prID], draft.id == draftID, jobs[prID] == nil,
              var record = records[prID], record.id == draftID else { return }
        record.result = result
        records[prID] = record
        save(record)
        phases[prID] = .readyToPush(draft, result)
    }

    public func setChat(prID: String, draftID: UUID, chat: ChatSession) {
        guard var record = records[prID], record.id == draftID else { return }
        record.chat = chat
        records[prID] = record
        save(record)
    }

    /// → queued → preparing → analyzing → ready | failed. Se ignora si el PR tiene un job, o está en
    /// `implementing`/`readyToPush`/`pushing`, o la corrida anterior dejó trabajo sin pushear (`unpushedWork`: hay que
    /// descartarla antes). La corrida anterior (lista o fallida) se reemplaza: su worktree se borra como con `dismiss`.
    /// Devuelve si arrancó.
    /// `localPath == nil`: solo un repo que corre en un host (el análisis arma su worktree allá).
    /// `mode == .ciFix` (spec K): reads the failing checks and, once the worktree is ready, implements the fix on its own.
    @discardableResult
    public func analyze(_ item: ClassifiedPR, localPath: String?, worktreeDir: String?, mode: RespondMode = .feedback) -> Bool {
        let prID = item.id
        switch phases[prID] {
        case nil, .ready?, .failed?, .done?: break
        default: return false
        }
        guard canStart(prID), openRunConflict(prID: prID, starting: mode) == nil, !unpushedWork.contains(prID) else { return false }
        // El worktree de la corrida anterior (la de `done` ya se borró) no se vuelve a usar (M5).
        if let old = records[prID] {
            if case .done? = phases[prID] {} else { cleanupWorktree(old.draft) }
            records[prID] = nil
        }
        modes[prID] = mode
        pushBlockedByCI[prID] = nil
        let request = RespondRequest(item: item, localPath: localPath, worktreeDir: worktreeDir, mode: mode)
        let draftID = UUID()
        let startedAt = Date()
        // El puente remoto llama dentro de `CommandOrigin.$current.withValue`; se lee acá, antes del job.
        let onPhone = CommandOrigin.current.isPhone
        runs[prID] = ClaudeRunInfo(startedAt: startedAt, requestedOnPhone: onPhone)
        let pipeline = self.pipeline
        start(prID, kind: .analyze, phase: .queued, onStart: .preparing, work: { [weak self] jobID in
            do {
                return try await pipeline.analyze(request, draftID: draftID) { [weak self] phase in
                    self?.progress(prID, jobID, phase)
                }
            } catch {
                if RemoteUnstoppedJobs.isNotStopped(error) { await self?.analyzeNotStopped(prID, draftID, error) }
                throw error
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let draft):
                let record = RespondRecord(draft: draft, startedAt: startedAt,
                                           usage: self.jobUsage[prID].flatMap { $0.runs > 0 ? $0 : nil },
                                           requestedOnPhone: onPhone ? true : nil)
                self.records[prID] = record
                self.save(record)
                self.finish(prID, .ready(draft))
                // Fix CI has nothing to choose: the fix starts at once (spec K.6.3). If it can't, it stays in `ready`.
                if draft.isCIFix { self.implementCI(prID: prID) }
            case .failure(let error):
                // Sin draft: se guarda uno vacío para que el error quede en el historial (con el log, si lo hay).
                let pr = item.pr
                let empty = RespondDraft(
                    id: draftID, prID: prID, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url,
                    headRef: pr.headRef, account: item.account,
                    worktree: ResolvedWorktree(path: localPath ?? "", origin: .mainClone), startHeadOid: "", items: [])
                self.records[prID] = nil
                self.save(RespondRecord(draft: empty, startedAt: startedAt, finishedAt: Date(),
                                        errorMessage: error.localizedDescription,
                                        usage: self.jobUsage[prID].flatMap { $0.runs > 0 ? $0 : nil },
                                        requestedOnPhone: onPhone ? true : nil))
                self.finish(prID, .failed(error.localizedDescription, logURL: self.existingLog(draftID)))
            }
        })
        return true
    }

    /// Fix CI: implements its only item with the default selection (never a reply).
    @discardableResult
    public func implementCI(prID: String) -> Bool {
        guard case .ready(let draft)? = phases[prID], draft.isCIFix else { return false }
        let selections = Dictionary(uniqueKeysWithValues: draft.items.map { ($0.id, RespondSelection.defaults(for: $0)) })
        implement(prID: prID, selections: selections)
        return jobs[prID] != nil
    }

    public func mode(of prID: String) -> RespondMode { modes[prID] ?? records[prID]?.draft.mode ?? .feedback }

    /// Spec K.2.1: the PR's slot holds one open run (any phase but `done`). Starting the other kind (Fix CI over a
    /// feedback analysis or the reverse) would silently replace it and lose its decisions, so it has to be dismissed
    /// first. Returns the open run's mode when it differs from `mode`; nil = `mode` can start (or replace a run of its
    /// own kind, as before).
    public func openRunConflict(prID: String, starting mode: RespondMode) -> RespondMode? {
        switch phases[prID] {
        case nil, .done?: return nil
        default:
            let open = self.mode(of: prID)
            return open == mode ? nil : open
        }
    }

    /// ready → implementing(d, t) → readyToPush | failed.
    public func implement(prID: String, selections: [String: RespondSelection]) {
        guard case .ready(let draft)? = phases[prID], var record = records[prID], record.draft.id == draft.id,
              canStart(prID) else { return }
        record.selections = selections
        record.errorMessage = nil
        records[prID] = record
        save(record)
        let total = draft.items.filter { selections[$0.id]?.implement == true }.count
        let pipeline = self.pipeline
        start(prID, kind: .implement, phase: .queued, previous: .ready(draft), onStart: .implementing(done: 0, total: total),
              work: { [weak self] jobID in
                  let outcome: Result<RespondResult, Error>
                  do {
                      outcome = .success(try await pipeline.implement(draft: draft, selections: selections) { [weak self] done, total in
                          self?.progress(prID, jobID, .implementing(done: done, total: total))
                      })
                  } catch {
                      outcome = .failure(error)
                  }
                  await self?.implementEnded(prID, jobID, draft: draft, outcome: outcome)
                  return try outcome.get()
              }, completion: { [weak self] result in
                  guard let self else { return }
                  switch result {
                  case .success(let result): self.reachReadyToPush(prID, draft: draft, result: result)
                  case .failure(let error): self.failImplementation(prID, error)
                  }
              })
    }

    /// En `readyToPush`: corre el `testCommand` y guarda el `TestRun` en el resultado y en el registro. Lo que
    /// ejecuta lo escribió Claude: la UI lo llama solo cuando el usuario lo pide, después de ver el diff.
    /// Returns whether they started (not if something else runs on the PR, or the command is empty).
    /// Never from an iPhone without a fresh Face ID proof (`CommandOrigin`, decision H1): what runs was written by Claude.
    @discardableResult
    public func runTests(prID: String, testCommand: String) -> Bool {
        guard CommandOrigin.mayRunRepoCode else { return false }
        return startTests(prID: prID, testCommand: testCommand, afterwards: nil)
    }

    /// "Run tests before pushing" (spec E.5): runs the tests and, if they pass, pushes and replies (like `publish`).
    /// If they fail it stays in `readyToPush` with the failed run and the PR in `pushBlockedByTests`. Returns whether
    /// the tests started: false if the PR isn't in `readyToPush`, something else runs on it (a chat turn, another job)
    /// or the command is empty; the caller tells the user.
    @discardableResult
    public func pushAfterTests(prID: String, testCommand: String) -> Bool {
        guard CommandOrigin.mayRunRepoCode else { return false }
        return startTests(prID: prID, testCommand: testCommand) { [weak self] run in
            guard let self else { return }
            if run.passed {
                // The push was already allowed when the tests were asked for (the completion runs as the Mac's job).
                self.startPush(prID: prID, ignoringCI: false)
            } else {
                self.pushBlockedByTests.insert(prID)
            }
        }
    }

    private func startTests(prID: String, testCommand: String, afterwards: (@MainActor (TestRun) -> Void)?) -> Bool {
        guard case .readyToPush(let draft, _)? = phases[prID], canStart(prID),
              !testCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        pushBlockedByTests.remove(prID)
        runningTests.insert(prID)
        let pipeline = self.pipeline
        start(prID, kind: .tests, phase: nil, work: { _ in
            await pipeline.runTests(draft: draft, testCommand: testCommand)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.runningTests.remove(prID)
            guard case .success(let run) = result, case .readyToPush(let current, var stored)? = self.phases[prID],
                  current.id == draft.id else { return }
            stored.tests = run
            self.records[prID]?.result = stored
            if let record = self.records[prID] { self.save(record) }
            self.finish(prID, .readyToPush(current, stored))
            afterwards?(run)
        })
        return true
    }

    /// readyToPush → pushing → done | failed. Desde `failed`, con fixes ya implementados, reintenta: no vuelve a
    /// pushear si ya se pusheó y solo publica las respuestas que faltan.
    /// `ignoringCI`: Fix CI's "Push Anyway" when its failing checks pass now (spec K.6.6).
    /// A push runs the user's git hooks (a `pre-push` from a `core.hooksPath` inside the repo runs what Claude may have
    /// written): never from an iPhone without a fresh Face ID proof (`CommandOrigin`, decision H1).
    public func publish(prID: String, ignoringCI: Bool = false) {
        guard CommandOrigin.mayRunRepoCode else { return }
        startPush(prID: prID, ignoringCI: ignoringCI)
    }

    private func startPush(prID: String, ignoringCI: Bool) {
        pushBlockedByTests.remove(prID)
        guard let record = records[prID], record.result != nil, canStart(prID) else { return }
        switch phases[prID] {
        case .readyToPush?, .failed?: break
        default: return
        }
        pushBlockedByCI[prID] = nil
        startPublish(prID, record: record, push: true, ignoringCI: ignoringCI)
    }

    /// ready → pushing → done | failed, sin fixes (no hay push). Desde `failed` reintenta las que faltan.
    public func publishRepliesOnly(prID: String, selections: [String: RespondSelection]) {
        guard var record = records[prID], record.result == nil, canStart(prID) else { return }
        switch phases[prID] {
        case .ready?, .failed?: break
        default: return
        }
        record.selections = selections
        records[prID] = record
        save(record)
        startPublish(prID, record: record, push: false)
    }

    /// En cola: se saca y se vuelve a la fase anterior. Analizando: se corta y vuelve a idle. Implementando: ver
    /// la documentación de la clase. Tests: se cortan (el resultado queda como estaba). Publicando: no hace nada.
    public func cancel(prID: String) {
        guard let job = jobs[prID] else { return }
        if scheduler.isQueued(prID) {
            jobs[prID] = nil
            scheduler.cancel(prID)
            phases[prID] = job.previous
            if job.kind == .tests { runningTests.remove(prID) }
            return
        }
        switch job.kind {
        case .publish:
            return
        case .analyze:
            phases[prID] = nil
        case .implement:
            cancelling[prID] = job.id
        case .tests:
            runningTests.remove(prID)
        }
        jobs[prID] = nil
        scheduler.cancel(prID)
    }

    /// Cancela todo (al salir de la app), incluidas las publicaciones en curso.
    public func cancelAll() {
        for (prID, job) in jobs {
            if scheduler.isQueued(prID) {
                phases[prID] = job.previous
                continue
            }
            switch job.kind {
            case .analyze: phases[prID] = nil
            case .implement: cancelling[prID] = job.id
            case .tests: break
            case .publish:
                let message = "Posting was canceled. Check the PR before retrying."
                if var record = records[prID] {
                    record.errorMessage = message
                    records[prID] = record
                    save(record)
                }
                phases[prID] = .failed(message, logURL: nil)
            }
        }
        runningTests.removeAll()
        jobs.removeAll()
        scheduler.cancelAll()
    }

    /// Vuelve a idle, olvida el registro (queda en el historial) y borra el worktree de PRBar. No toca un PR con
    /// un job.
    public func dismiss(prID: String) {
        pushBlockedByTests.remove(prID)
        guard jobs[prID] == nil, cancelling[prID] == nil else { return }
        pushBlockedByCI[prID] = nil
        modes[prID] = nil
        phases[prID] = nil
        runs[prID] = nil
        leftWork.remove(prID)
        if let record = records[prID] { cleanupWorktree(record.draft) }
        records[prID] = nil
    }

    /// En segundo plano: el worktree no se vuelve a usar.
    private func cleanupWorktree(_ draft: RespondDraft) {
        let pipeline = self.pipeline
        Task.detached(priority: .utility) { await pipeline.cleanup(draft: draft) }
    }

    // MARK: - Jobs

    private func canStart(_ prID: String) -> Bool {
        jobs[prID] == nil && cancelling[prID] == nil && !scheduler.isActive(prID) && !chatting.contains(prID)
    }

    /// Encola `work` como el job vigente de `prID`. `phase` se pone al encolar y `onStart` al arrancar.
    /// `completion` solo se llama si el job sigue siendo el vigente (no se canceló).
    private func start<T: Sendable>(
        _ prID: String, kind: Kind, phase: RespondPhase?, previous: RespondPhase? = nil, onStart: RespondPhase? = nil,
        work: @escaping @Sendable (UUID) async throws -> T,
        completion: @escaping @MainActor (Result<T, Error>) -> Void
    ) {
        guard canStart(prID) else { return }
        let jobID = UUID()
        let slot = Slot<T>()
        let usage = Slot<ClaudeUsage>()
        jobs[prID] = Job(id: jobID, kind: kind, previous: previous ?? phases[prID])
        if let phase { phases[prID] = phase }
        scheduler.enqueue(prID, activity: activity(prID), onStart: { [weak self] in
            if let onStart, self?.jobs[prID]?.id == jobID { self?.phases[prID] = onStart }
        }, work: {
            // Claude's usage for this job goes to the record (spec O.4.4), also when it fails or is canceled.
            let sink = ClaudeUsageSink()
            defer { usage.value = sink.total }
            slot.value = try await sink.measure { try await work(jobID) }
        }, onComplete: { [weak self] result in
            guard let self, self.jobs[prID]?.id == jobID else { return }
            self.jobs[prID] = nil
            // Saved before `completion`, so the record the phase event announces already has it. An analysis makes
            // a new record: its `completion` puts the usage there (`jobUsage`).
            if kind == .analyze {
                self.jobUsage[prID] = usage.value
            } else {
                self.addUsage(prID, usage.value)
            }
            completion(result.map { slot.value! })
            self.jobUsage[prID] = nil
        }, onCancelledEnd: { [weak self] result in
            guard let self else { return }
            if kind != .analyze { self.addUsage(prID, usage.value) }
            // An implementation canceled after `implementEnded` ran (it found nothing to cancel, so it didn't resolve
            // the phase) and before the scheduler closed the job: the finished implementation wins, or the PR would
            // stay in `implementing` with `cancelling` set (no dismiss, no new job) and its commits uncounted.
            if kind == .implement, self.cancelling[prID] == jobID {
                self.cancelling[prID] = nil
                completion(result.map { slot.value! })
            }
        })
    }

    /// Lo que gastó en Claude el job que acaba de terminar, mientras corre su `completion` (un análisis fallido lo
    /// guarda en su registro vacío).
    private var jobUsage: [String: ClaudeUsage] = [:]

    /// Suma el uso de un job al registro vigente del PR y lo guarda.
    private func addUsage(_ prID: String, _ usage: ClaudeUsage?) {
        guard let usage, usage.runs > 0, var record = records[prID] else { return }
        record.usage = (record.usage ?? .zero) + usage
        records[prID] = record
        save(record)
    }

    /// La tarea de Activity del PR.
    private func activity(_ prID: String) -> ProcessActivity { mode(of: prID) == .ciFix ? .ciFix(prID) : .respond(prID) }

    private func progress(_ prID: String, _ jobID: UUID, _ phase: RespondPhase) {
        guard jobs[prID]?.id == jobID, phase.isActive else { return }
        phases[prID] = phase
    }

    private func finish(_ prID: String, _ phase: RespondPhase) {
        phases[prID] = phase
        onEvent(prID, phase)
    }

    /// Un análisis cancelado cuyo Claude no se pudo confirmar parado en el host: en vez de volver a idle sin decir
    /// nada, la fila lo explica (el worktree queda allá; spec J). Solo si nada nuevo arrancó en ese PR.
    private func analyzeNotStopped(_ prID: String, _ draftID: UUID, _ error: Error) {
        guard jobs[prID] == nil, phases[prID] == nil else { return }
        phases[prID] = .failed(error.localizedDescription, logURL: existingLog(draftID))
    }

    /// Una implementación que falló o se canceló puede haber dejado commits o cambios en el worktree: salvo que la
    /// cancelación diga que no quedó nada, cuenta como trabajo sin pushear hasta `dismiss`.
    private func failImplementation(_ prID: String, _ error: Error) {
        if let cancellation = error as? RespondCancellation, !cancellation.dirty, cancellation.unpushedCommits == 0 {
            // Nada que cuidar.
        } else {
            leftWork.insert(prID)
        }
        fail(prID, error)
    }

    private func fail(_ prID: String, _ error: Error) {
        let message = error.localizedDescription
        var logURL: URL?
        if var record = records[prID] {
            record.errorMessage = message
            records[prID] = record
            save(record)
            logURL = existingLog(record.id)
        }
        finish(prID, .failed(message, logURL: logURL))
    }

    private func reachReadyToPush(_ prID: String, draft: RespondDraft, result: RespondResult) {
        leftWork.remove(prID)
        records[prID]?.result = result
        records[prID]?.errorMessage = nil
        // Claude's sessions of the fixes (spec T.2). A test run or a chat turn brings no new ones: they stay.
        let sessions = ClaudeSessionRef.fixes(draft: draft, items: result.items)
        if !sessions.isEmpty { records[prID]?.sessions = sessions }
        if let record = records[prID] { save(record) }
        finish(prID, .readyToPush(draft, result))
    }

    /// Solo hace algo si esta implementación se canceló (`cancel`/`cancelAll`): el scheduler ya no va a llamar a
    /// `completion`, así que acá se decide la fase final, cuando el pipeline ya dejó el árbol limpio. Un Cancel que
    /// llega después de esto (y antes de que el scheduler cierre el job) lo resuelve `onCancelledEnd` en `start`.
    private func implementEnded(_ prID: String, _ jobID: UUID, draft: RespondDraft, outcome: Result<RespondResult, Error>) {
        guard cancelling[prID] == jobID else { return }
        cancelling[prID] = nil
        switch outcome {
        case .success(let result):
            // Terminó antes de enterarse de la cancelación: los commits están, se muestran.
            reachReadyToPush(prID, draft: draft, result: result)
        case .failure(let cancellation as RespondCancellation) where cancellation.unpushedCommits == 0 && !cancellation.dirty:
            if let record = records[prID] { save(record) }
            finish(prID, .ready(draft))
        case .failure(let error):
            failImplementation(prID, error)
        }
    }

    private func startPublish(_ prID: String, record: RespondRecord, push: Bool, ignoringCI: Bool = false) {
        let pipeline = self.pipeline
        let draft = record.draft
        let draftID = draft.id
        let previous = phases[prID]
        start(prID, kind: .publish, phase: .queued, onStart: .pushing, work: { [weak self] _ in
            if push && !record.pushed, let result = record.result {
                if draft.isCIFix { try await pipeline.checkCIBeforePush(draft: draft, ignoringPassingChecks: ignoringCI) }
                try await pipeline.push(draft: draft, result: result)
                await self?.markPushed(prID, draftID)
            }
            let (posted, error) = await pipeline.postReplies(
                draft: draft, selections: record.selections, result: record.result, alreadyPosted: record.posted
            ) { [weak self] id, reply in
                await self?.markPosted(prID, draftID, id: id, reply: reply)
            }
            if let error { throw error }
            return posted
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                guard var record = self.records[prID] else { return }
                record.errorMessage = nil
                record.finishedAt = Date()
                self.records[prID] = record
                self.save(record)
                self.finish(prID, .done(record))
                if record.pushed, let onRetain = self.onRetain {
                    onRetain(record)
                } else {
                    self.cleanupWorktree(record.draft)
                }
            case .failure(let error as CIPassingNow):
                // Nothing was pushed: back to the diff, with "Push Anyway" (spec K.6.6).
                // Through `finish`, like any other end of a job: the app updates Activity and History and notifies
                // (`isReportingCIBlock` tells this event from a later one, such as a test run's).
                self.pushBlockedByCI[prID] = error.localizedDescription
                self.reportingCIBlock = prID
                defer { self.reportingCIBlock = nil }
                if case .readyToPush? = previous, let previous { self.finish(prID, previous) } else if let result = record.result {
                    self.finish(prID, .readyToPush(draft, result))
                }
            case .failure(let error):
                self.fail(prID, error)
            }
        })
    }

    private func markPushed(_ prID: String, _ draftID: UUID) {
        guard var record = records[prID], record.id == draftID else { return }
        record.pushed = true
        records[prID] = record
        save(record)
    }

    /// Se guarda en el acto, aunque el job ya no sea el vigente: lo publicado ya está en GitHub.
    private func markPosted(_ prID: String, _ draftID: UUID, id: String, reply: PostedReply) {
        guard var record = records[prID], record.id == draftID else { return }
        record.posted[id] = reply
        records[prID] = record
        save(record)
    }

    // MARK: - Historial

    private func save(_ record: RespondRecord) {
        do {
            try history.save(record)
        } catch {
            AppLog.write("History: couldn't save respond \(record.draft.repo.fullName)#\(record.draft.number): \(error)")
        }
    }

    private func existingLog(_ id: UUID) -> URL? {
        let url = pipeline.logURL(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Donde `work` deja su valor para que `completion` lo lea en el main actor después de que terminó.
private final class Slot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
