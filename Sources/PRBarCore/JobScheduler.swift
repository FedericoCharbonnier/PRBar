import Foundation

/// Cola FIFO con máximo N trabajos en paralelo, cancelación y protección contra callbacks tardíos.
///
/// Cada corrida tiene su propio id: si se cancela una clave y se vuelve a encolar, la corrida vieja
/// (que puede seguir terminando en segundo plano) no puede liberar el lugar ni avisar por la nueva.
@MainActor
public final class JobScheduler<Key: Hashable & Sendable> {
    private struct Pending {
        let key: Key
        let onStart: @MainActor () -> Void
        let work: @Sendable () async throws -> Void
        let onComplete: @MainActor (Result<Void, Error>) -> Void
    }

    private struct Running {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let maxConcurrent: Int
    private var waiting: [Pending] = []
    private var running: [Key: Running] = [:]

    public init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Encola `work` si `key` no está activa ni en cola. `work` corre fuera del main actor.
    /// `onStart` se llama en el main actor cuando arranca; `onComplete` cuando termina (no se llama si se canceló).
    @discardableResult
    public func enqueue(_ key: Key,
                        onStart: @escaping @MainActor () -> Void,
                        work: @escaping @Sendable () async throws -> Void,
                        onComplete: @escaping @MainActor (Result<Void, Error>) -> Void) -> Bool {
        guard !isActive(key) else { return false }
        waiting.append(Pending(key: key, onStart: onStart, work: work, onComplete: onComplete))
        startNext()
        return true
    }

    /// Corriendo: cancela la Task y libera el lugar en el acto (arranca el siguiente). En cola: la saca.
    public func cancel(_ key: Key) {
        if let job = running.removeValue(forKey: key) {
            job.task.cancel()
            startNext()
        } else if let index = waiting.firstIndex(where: { $0.key == key }) {
            waiting.remove(at: index)
        }
    }

    /// Cancela todo: vacía la cola y cancela lo que corre, sin arrancar nada nuevo.
    public func cancelAll() {
        waiting.removeAll()
        let jobs = running.values
        running.removeAll()
        for job in jobs { job.task.cancel() }
    }

    /// Corriendo o en cola.
    public func isActive(_ key: Key) -> Bool { running[key] != nil || isQueued(key) }

    public func isQueued(_ key: Key) -> Bool { waiting.contains { $0.key == key } }

    // MARK: - Privado

    private func startNext() {
        while running.count < maxConcurrent, !waiting.isEmpty {
            start(waiting.removeFirst())
        }
    }

    private func start(_ job: Pending) {
        let key = job.key
        let id = UUID()
        let work = job.work
        let onComplete = job.onComplete
        let task = Task { [weak self] in
            let result: Result<Void, Error>
            do {
                try await work()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self?.finish(key, id: id, result: result, onComplete: onComplete)
        }
        running[key] = Running(id: id, task: task)
        job.onStart()
    }

    private func finish(_ key: Key, id: UUID, result: Result<Void, Error>,
                        onComplete: @MainActor (Result<Void, Error>) -> Void) {
        // Una corrida cancelada ya se sacó de `running` (y quizás la reemplazó otra): no toca nada.
        guard running[key]?.id == id else { return }
        running[key] = nil
        onComplete(result)
        startNext()
    }
}
