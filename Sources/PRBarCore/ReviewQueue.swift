import Foundation

/// Estado de las reviews por PR, con una cola de a lo sumo `maxConcurrent` jobs en paralelo.
@MainActor
public final class ReviewQueue: ObservableObject {
    @Published public private(set) var phases: [String: ReviewPhase] = [:]   // por prID

    private let pipeline: ReviewPipelineRunning
    private let scheduler: JobScheduler<String>
    private let onFinished: @MainActor (ReviewRequest, Result<ReviewDraft, Error>) -> Void
    /// Id de la corrida vigente de cada PR (en cola o corriendo): las fases de una corrida vieja se ignoran.
    private var jobs: [String: UUID] = [:]

    public init(pipeline: ReviewPipelineRunning, maxConcurrent: Int = 2,
                onFinished: @escaping @MainActor (ReviewRequest, Result<ReviewDraft, Error>) -> Void) {
        self.pipeline = pipeline
        self.scheduler = JobScheduler(maxConcurrent: maxConcurrent)
        self.onFinished = onFinished
    }

    /// Ignora el pedido si ya hay un job activo o en cola para ese PR.
    public func enqueue(_ request: ReviewRequest) {
        let prID = request.item.id
        guard !scheduler.isActive(prID) else { return }
        let jobID = UUID()
        let pipeline = self.pipeline
        let draft = DraftSlot()
        jobs[prID] = jobID
        phases[prID] = .queued
        scheduler.enqueue(prID, onStart: { [weak self] in
            self?.phases[prID] = .preparing
        }, work: { [weak self] in
            draft.value = try await pipeline.run(request) { [weak self] phase in
                self?.update(prID, job: jobID, phase: phase)
            }
        }, onComplete: { [weak self] result in
            self?.finish(request, job: jobID, result: result.map { draft.value! })
        })
    }

    /// Cancela la Task (o lo saca de la cola); la fase se borra y el lugar queda libre en el acto.
    public func cancel(prID: String) {
        guard jobs.removeValue(forKey: prID) != nil else { return }
        phases[prID] = nil
        scheduler.cancel(prID)
    }

    /// Cancela todo (p. ej. al salir de la app): los jobs que corren y los que esperan en la cola.
    public func cancelAll() {
        for prID in jobs.keys { phases[prID] = nil }
        jobs.removeAll()
        scheduler.cancelAll()
    }

    public func markPublished(prID: String, url: URL) {
        guard phases[prID]?.isActive != true else { return }
        phases[prID] = .published(url)
    }

    /// Marca un error que impidió encolar (p. ej. falta `claude` o `git`). No pisa un job activo ni llama a `onFinished`.
    public func markFailed(prID: String, message: String) {
        guard phases[prID]?.isActive != true else { return }
        phases[prID] = .failed(message, logURL: nil)
    }

    /// Borra failed/ready/published (vuelve a idle). No toca jobs activos.
    public func dismiss(prID: String) {
        guard phases[prID]?.isActive == false else { return }
        phases[prID] = nil
    }

    /// `.ready(draft)`, para reabrir desde el historial. No pisa un job activo.
    public func restore(_ draft: ReviewDraft) {
        guard phases[draft.prID]?.isActive != true else { return }
        phases[draft.prID] = .ready(draft)
    }

    // MARK: - Privado

    private func isCurrent(_ prID: String, _ jobID: UUID) -> Bool { jobs[prID] == jobID }

    private func update(_ prID: String, job jobID: UUID, phase: ReviewPhase) {
        guard isCurrent(prID, jobID), phase.isActive else { return }
        phases[prID] = phase
    }

    /// El scheduler no llama a `onComplete` para una corrida cancelada, así que acá siempre es la vigente.
    private func finish(_ request: ReviewRequest, job jobID: UUID, result: Result<ReviewDraft, Error>) {
        let prID = request.item.id
        guard isCurrent(prID, jobID) else { return }
        jobs[prID] = nil
        switch result {
        case .success(let draft):
            phases[prID] = .ready(draft)
            onFinished(request, result)
        case .failure(let error) where error is CancellationError:
            phases[prID] = nil
        case .failure(let error):
            phases[prID] = .failed(error.localizedDescription, logURL: (error as? ReviewFailure)?.logURL)
            onFinished(request, result)
        }
    }
}

/// Donde `work` deja el draft para que `onComplete` lo lea. Se escribe una sola vez desde la Task del job
/// y se lee en el main actor después de que terminó, así que el lock solo cubre la publicación.
private final class DraftSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ReviewDraft?
    var value: ReviewDraft? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
