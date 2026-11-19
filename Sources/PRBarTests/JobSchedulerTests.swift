import Foundation
import PRBarCore

/// Trabajos falsos que quedan suspendidos hasta que el test los completa a mano.
/// Una misma clave puede correr más de una vez (cancelar y volver a encolar), así que cada corrida
/// guarda su propia continuación en orden. `ignoresCancellation` simula un trabajo que no se entera
/// de la cancelación y termina tarde, para probar la protección contra callbacks tardíos.
final class FakeJobs: @unchecked Sendable {
    private let lock = NSLock()
    private let events: QueueEventLog
    private let ignoresCancellation: Bool
    private var continuations: [String: [CheckedContinuation<Void, Error>]] = [:]
    private var _started: [String] = []

    init(events: QueueEventLog, ignoresCancellation: Bool = false) {
        self.events = events
        self.ignoresCancellation = ignoresCancellation
    }

    /// Orden en que arrancaron los trabajos.
    var started: [String] { lock.withLock { _started } }

    func work(_ key: String) -> @Sendable () async throws -> Void {
        { [self] in try await self.run(key) }
    }

    private func run(_ key: String) async throws {
        let events = self.events
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    _started.append(key)
                    continuations[key, default: []].append(continuation)
                }
                Task { @MainActor in events.record(.started(key)) }
            }
        } onCancel: { [self] in
            if !ignoresCancellation {
                let continuation = lock.withLock { continuations[key]?.popLast() }
                continuation?.resume(throwing: CancellationError())
            }
            Task { @MainActor in events.record(.cancelled(key)) }
        }
    }

    /// Completa la corrida más vieja todavía pendiente de `key`.
    func complete(_ key: String, _ result: Result<Void, Error> = .success(())) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard var pending = continuations[key], !pending.isEmpty else { return nil }
            let first = pending.removeFirst()
            continuations[key] = pending
            return first
        }
        continuation?.resume(with: result)
    }
}

@MainActor
private final class SchedulerHarness {
    let events = QueueEventLog()
    let jobs: FakeJobs
    let scheduler: JobScheduler<String>
    var starts: [String] = []
    var completions: [(String, Result<Void, Error>)] = []
    /// `onCancelledEnd`: runs cancelled while running whose work really ended.
    var cancelledEnds: [(String, Result<Void, Error>)] = []

    init(maxConcurrent: Int = 2, ignoresCancellation: Bool = false) {
        jobs = FakeJobs(events: events, ignoresCancellation: ignoresCancellation)
        scheduler = JobScheduler(maxConcurrent: maxConcurrent)
    }

    @discardableResult
    func enqueue(_ key: String) -> Bool {
        scheduler.enqueue(key, onStart: { [unowned self] in
            self.starts.append(key)
        }, work: jobs.work(key), onComplete: { [unowned self] result in
            self.completions.append((key, result))
            self.events.record(.finished(key))
        }, onCancelledEnd: { [unowned self] result in
            self.cancelledEnds.append((key, result))
        })
    }

    func settle() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

private func started(_ keys: String...) -> Set<QueueEvent> { Set(keys.map { .started($0) }) }
private func finished(_ keys: String...) -> Set<QueueEvent> { Set(keys.map { .finished($0) }) }

private struct Kaboom: Error {}

/// Síncrona a propósito: `Thread.isMainThread` no se puede leer desde un contexto async.
private func onMainThread() -> Bool { Thread.isMainThread }

enum JobSchedulerTests {
    static let cases: [TestCase] = [
        TestCase("job scheduler: con 3 encolados y máximo 2 corren 2; al terminar uno arranca el tercero") { @MainActor in
            let h = SchedulerHarness()
            for key in ["a", "b", "c"] { try expect(h.enqueue(key)) }
            // onStart se llama en el acto, en orden FIFO.
            try expectEqual(h.starts, ["a", "b"])
            try expect(h.scheduler.isActive("a") && !h.scheduler.isQueued("a"))
            try expect(h.scheduler.isActive("c") && h.scheduler.isQueued("c"))
            try await h.events.wait(for: started("a", "b"))
            try expectEqual(Set(h.jobs.started), ["a", "b"])
            h.jobs.complete("a")
            try await h.events.wait(for: started("c").union(finished("a")))
            try expectEqual(h.starts, ["a", "b", "c"])
            try expect(!h.scheduler.isActive("a"))
            try expect(h.scheduler.isActive("c") && !h.scheduler.isQueued("c"))
        },
        TestCase("job scheduler: arranca en orden FIFO cuando corre de a uno") { @MainActor in
            let h = SchedulerHarness(maxConcurrent: 1)
            for key in ["a", "b", "c"] { h.enqueue(key) }
            try await h.events.wait(for: started("a"))
            try expect(h.scheduler.isQueued("b") && h.scheduler.isQueued("c"))
            h.jobs.complete("a")
            try await h.events.wait(for: started("b"))
            try expect(h.scheduler.isQueued("c"))
            h.jobs.complete("b")
            try await h.events.wait(for: started("c"))
            try expectEqual(h.jobs.started, ["a", "b", "c"])
            try expectEqual(h.starts, ["a", "b", "c"])
        },
        TestCase("job scheduler: al liberarse un lugar arranca el primero de la cola, no el último") { @MainActor in
            let h = SchedulerHarness()
            for key in ["a", "b", "c", "d"] { h.enqueue(key) }
            try await h.events.wait(for: started("a", "b"))
            h.jobs.complete("b")
            try await h.events.wait(for: started("c"))
            try expect(h.scheduler.isQueued("d"))
            try expectEqual(Array(h.jobs.started.suffix(1)), ["c"])
        },
        TestCase("job scheduler: maxConcurrent menor que 1 corre de a uno") { @MainActor in
            let h = SchedulerHarness(maxConcurrent: 0)
            h.enqueue("a")
            h.enqueue("b")
            try expectEqual(h.starts, ["a"])
            try expect(h.scheduler.isQueued("b"))
            try await h.events.wait(for: started("a"))
            h.jobs.complete("a")
            try await h.events.wait(for: started("b"))
        },
        TestCase("job scheduler: onComplete recibe el resultado, éxito o error") { @MainActor in
            let h = SchedulerHarness()
            h.enqueue("a")
            h.enqueue("b")
            try await h.events.wait(for: started("a", "b"))
            h.jobs.complete("a")
            h.jobs.complete("b", .failure(Kaboom()))
            try await h.events.wait(for: finished("a", "b"))
            let results = Dictionary(uniqueKeysWithValues: h.completions.map { ($0.0, $0.1) })
            guard case .success? = results["a"] else { throw TestFailure(description: "esperaba success") }
            guard case .failure(let error)? = results["b"] else { throw TestFailure(description: "esperaba failure") }
            try expect(error is Kaboom)
            try expect(!h.scheduler.isActive("a") && !h.scheduler.isActive("b"))
        },
        TestCase("job scheduler: el trabajo corre fuera del main actor") { @MainActor in
            let scheduler = JobScheduler<String>(maxConcurrent: 1)
            let events = QueueEventLog()
            let onMain = Box<Bool?>(nil)
            scheduler.enqueue("a", onStart: {}, work: {
                onMain.value = onMainThread()
            }, onComplete: { _ in events.record(.finished("a")) })
            try await events.wait(for: [.finished("a")])
            try expectEqual(onMain.value, false)
        },
        TestCase("job scheduler: cancel de un trabajo corriendo libera el lugar en el acto y no llama a onComplete") { @MainActor in
            let h = SchedulerHarness()
            for key in ["a", "b", "c"] { h.enqueue(key) }
            try await h.events.wait(for: started("a", "b"))
            h.scheduler.cancel("a")
            try expect(!h.scheduler.isActive("a"))
            try expectEqual(h.starts, ["a", "b", "c"])
            try expect(h.scheduler.isActive("c") && !h.scheduler.isQueued("c"))
            try await h.events.wait(for: started("c").union([.cancelled("a")]))
            await h.settle()
            try expect(h.completions.isEmpty, "onComplete no debe llamarse al cancelar")
        },
        TestCase("job scheduler: onCancelledEnd avisa cuando un trabajo cancelado corriendo termina de verdad") { @MainActor in
            let h = SchedulerHarness(ignoresCancellation: true)
            for key in ["a", "b", "c"] { h.enqueue(key) }
            try await h.events.wait(for: started("a", "b"))
            h.scheduler.cancel("a")
            h.scheduler.cancel("c")   // en cola: su trabajo nunca corre, no hay nada que avisar
            try await h.events.wait(for: [.cancelled("a")])
            await h.settle()
            try expect(h.cancelledEnds.isEmpty, "el trabajo de \"a\" todavía no terminó")
            h.jobs.complete("a", .failure(Kaboom()))
            try await waitUntil { !h.cancelledEnds.isEmpty }
            try expectEqual(h.cancelledEnds.map(\.0), ["a"])
            if case .success = h.cancelledEnds[0].1 { throw TestFailure(description: "esperaba el error del trabajo") }
            try expect(h.completions.isEmpty, "onComplete no debe llamarse al cancelar")
            // cancelAll también avisa a los que corrían.
            h.scheduler.cancelAll()
            h.jobs.complete("b")
            try await waitUntil { h.cancelledEnds.count == 2 }
            try expectEqual(h.cancelledEnds.map(\.0), ["a", "b"])
            try expect(h.completions.isEmpty)
        },
        TestCase("job scheduler: cancel de uno en cola lo saca de la cola") { @MainActor in
            let h = SchedulerHarness()
            for key in ["a", "b", "c"] { h.enqueue(key) }
            try await h.events.wait(for: started("a", "b"))
            h.scheduler.cancel("c")
            try expect(!h.scheduler.isActive("c"))
            h.jobs.complete("a")
            try await h.events.wait(for: finished("a"))
            await h.settle()
            try expectEqual(h.events.count(.started("c")), 0)
            try expectEqual(h.starts, ["a", "b"])
        },
        TestCase("job scheduler: cancel de una clave desconocida no hace nada") { @MainActor in
            let h = SchedulerHarness()
            h.enqueue("a")
            h.scheduler.cancel("zzz")
            try expect(h.scheduler.isActive("a"))
            try await h.events.wait(for: started("a"))
            h.jobs.complete("a")
            try await h.events.wait(for: finished("a"))
        },
        TestCase("job scheduler: cancelAll cancela los que corren y vacía la cola, sin arrancar otros") { @MainActor in
            let h = SchedulerHarness()
            for key in ["a", "b", "c"] { h.enqueue(key) }
            try await h.events.wait(for: started("a", "b"))
            h.scheduler.cancelAll()
            for key in ["a", "b", "c"] { try expect(!h.scheduler.isActive(key)) }
            try await h.events.wait(for: [.cancelled("a"), .cancelled("b")])
            await h.settle()
            try expectEqual(h.events.count(.started("c")), 0)
            try expectEqual(h.starts, ["a", "b"])
            try expect(h.completions.isEmpty, "onComplete no debe llamarse al cancelar")
        },
        TestCase("job scheduler: encolar la misma clave dos veces no duplica") { @MainActor in
            let h = SchedulerHarness()
            try expect(h.enqueue("a"))
            try expect(!h.enqueue("a"), "corriendo")
            try expect(h.enqueue("b"))
            try expect(h.enqueue("c"))
            try expect(!h.enqueue("c"), "en cola")
            try await h.events.wait(for: started("a", "b"))
            h.jobs.complete("a")
            try await h.events.wait(for: started("c"))
            h.jobs.complete("b")
            h.jobs.complete("c")
            try await h.events.wait(for: finished("a", "b", "c"))
            await h.settle()
            try expectEqual(h.jobs.started.count, 3)
            try expectEqual(h.completions.count, 3)
            // Una vez terminada, la clave se puede volver a encolar.
            try expect(h.enqueue("a"))
            try await h.events.wait(for: [.started("a")])
            h.jobs.complete("a")
        },
        TestCase("job scheduler: un trabajo cancelado que termina tarde no pisa la nueva corrida de la misma clave") { @MainActor in
            let h = SchedulerHarness(maxConcurrent: 1, ignoresCancellation: true)
            h.enqueue("a")
            try await h.events.wait(for: started("a"))
            h.scheduler.cancel("a")
            try await h.events.wait(for: [.cancelled("a")])
            // Se vuelve a encolar: corre una segunda vez mientras la primera sigue colgada.
            try expect(h.enqueue("a"))
            h.enqueue("b")
            try await h.events.wait(for: [.started("a")])
            for _ in 0..<5_000 where h.jobs.started.count < 2 { try? await Task.sleep(nanoseconds: 1_000_000) }
            try expectEqual(h.jobs.started.count, 2)
            // La primera corrida termina tarde (con éxito): no debe avisar, ni liberar el lugar, ni arrancar "b".
            h.jobs.complete("a")
            await h.settle()
            try expect(h.completions.isEmpty, "el callback tardío no debe llegar")
            try expectEqual(h.cancelledEnds.map(\.0), ["a"])
            try expect(h.scheduler.isActive("a") && !h.scheduler.isQueued("a"))
            try expect(h.scheduler.isQueued("b"))
            try expectEqual(h.events.count(.started("b")), 0)
            // La segunda corrida sí cuenta.
            h.jobs.complete("a")
            try await h.events.wait(for: finished("a").union(started("b")))
            try expectEqual(h.completions.count, 1)
            h.jobs.complete("b")
            try await h.events.wait(for: finished("b"))
        },
    ]
}
