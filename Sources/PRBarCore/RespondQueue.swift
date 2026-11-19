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
///   que el usuario lo revise (lo borra `dismiss` o la limpieza del próximo arranque).
@MainActor
public final class RespondQueue: ObservableObject {
    @Published public private(set) var phases: [String: RespondPhase] = [:]   // por prID
    /// PRs con el `testCommand` corriendo (la fase sigue en `readyToPush`).
    @Published public private(set) var runningTests: Set<String> = []
    /// El registro vigente de cada PR, desde que terminó el análisis hasta `dismiss`.
    @Published public private(set) var records: [String: RespondRecord] = [:]

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
    /// El job vigente de cada PR (en cola o corriendo): lo que avise una corrida vieja se ignora.
    private var jobs: [String: Job] = [:]
    /// Implementaciones canceladas que todavía están restaurando el árbol.
    private var cancelling: [String: UUID] = [:]

    public init(pipeline: RespondPipelineRunning, history: RespondHistory = RespondHistory(), maxConcurrent: Int = 2,
                onEvent: @escaping @MainActor (String, RespondPhase) -> Void) {
        self.pipeline = pipeline
        self.history = history
        self.scheduler = JobScheduler(maxConcurrent: maxConcurrent)
        self.onEvent = onEvent
    }

    // MARK: - Acciones

    /// → queued → preparing → analyzing → ready | failed. Se ignora si el PR tiene un job, o está en
    /// `implementing`/`readyToPush`/`pushing` (hay fixes sin publicar).
    public func analyze(_ item: ClassifiedPR, localPath: String, worktreeDir: String?) {
        let prID = item.id
        switch phases[prID] {
        case nil, .ready?, .failed?, .done?: break
        default: return
        }
        let request = RespondRequest(item: item, localPath: localPath, worktreeDir: worktreeDir)
        let draftID = UUID()
        let startedAt = Date()
        let pipeline = self.pipeline
        start(prID, kind: .analyze, phase: .queued, onStart: .preparing, work: { [weak self] jobID in
            try await pipeline.analyze(request, draftID: draftID) { [weak self] phase in
                self?.progress(prID, jobID, phase)
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let draft):
                let record = RespondRecord(draft: draft, startedAt: startedAt)
                self.records[prID] = record
                self.save(record)
                self.finish(prID, .ready(draft))
            case .failure(let error):
                // Sin draft: se guarda uno vacío para que el error quede en el historial (con el log, si lo hay).
                let pr = item.pr
                let empty = RespondDraft(
                    id: draftID, prID: prID, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url,
                    headRef: pr.headRef, account: item.account,
                    worktree: ResolvedWorktree(path: localPath, origin: .mainClone), startHeadOid: "", items: [])
                self.records[prID] = nil
                self.save(RespondRecord(draft: empty, startedAt: startedAt, finishedAt: Date(),
                                        errorMessage: error.localizedDescription))
                self.finish(prID, .failed(error.localizedDescription, logURL: self.existingLog(draftID)))
            }
        })
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
                  case .failure(let error): self.fail(prID, error)
                  }
              })
    }

    /// En `readyToPush`: corre el `testCommand` y guarda el `TestRun` en el resultado y en el registro. Lo que
    /// ejecuta lo escribió Claude: la UI lo llama solo cuando el usuario lo pide, después de ver el diff.
    public func runTests(prID: String, testCommand: String) {
        guard case .readyToPush(let draft, _)? = phases[prID], canStart(prID),
              !testCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
        })
    }

    /// readyToPush → pushing → done | failed. Desde `failed`, con fixes ya implementados, reintenta: no vuelve a
    /// pushear si ya se pusheó y solo publica las respuestas que faltan.
    public func publish(prID: String) {
        guard let record = records[prID], record.result != nil, canStart(prID) else { return }
        switch phases[prID] {
        case .readyToPush?, .failed?: break
        default: return
        }
        startPublish(prID, record: record, push: true)
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
        guard jobs[prID] == nil, cancelling[prID] == nil else { return }
        phases[prID] = nil
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
        jobs[prID] == nil && cancelling[prID] == nil && !scheduler.isActive(prID)
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
        jobs[prID] = Job(id: jobID, kind: kind, previous: previous ?? phases[prID])
        if let phase { phases[prID] = phase }
        scheduler.enqueue(prID, onStart: { [weak self] in
            if let onStart, self?.jobs[prID]?.id == jobID { self?.phases[prID] = onStart }
        }, work: {
            slot.value = try await work(jobID)
        }, onComplete: { [weak self] result in
            guard let self, self.jobs[prID]?.id == jobID else { return }
            self.jobs[prID] = nil
            completion(result.map { slot.value! })
        })
    }

    private func progress(_ prID: String, _ jobID: UUID, _ phase: RespondPhase) {
        guard jobs[prID]?.id == jobID, phase.isActive else { return }
        phases[prID] = phase
    }

    private func finish(_ prID: String, _ phase: RespondPhase) {
        phases[prID] = phase
        onEvent(prID, phase)
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
        records[prID]?.result = result
        records[prID]?.errorMessage = nil
        if let record = records[prID] { save(record) }
        finish(prID, .readyToPush(draft, result))
    }

    /// Solo hace algo si esta implementación se canceló (`cancel`/`cancelAll`): el scheduler ya no va a llamar a
    /// `completion`, así que acá se decide la fase final, cuando el pipeline ya dejó el árbol limpio.
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
            fail(prID, error)
        }
    }

    private func startPublish(_ prID: String, record: RespondRecord, push: Bool) {
        let pipeline = self.pipeline
        let draft = record.draft
        let draftID = draft.id
        start(prID, kind: .publish, phase: .queued, onStart: .pushing, work: { [weak self] _ in
            if push && !record.pushed, let result = record.result {
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
                self.cleanupWorktree(record.draft)
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
