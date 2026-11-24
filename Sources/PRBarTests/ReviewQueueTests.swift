import Foundation
import PRBarCore

/// Lo que pasa en una prueba de la cola, visto desde el main actor.
enum QueueEvent: Hashable, Sendable {
    case started(String), cancelled(String), finished(String)
}

/// Registro de eventos con espera por señales (sin polling). El timeout es solo una red de seguridad
/// para que un test roto falle en vez de colgarse; ninguna aserción depende de él.
@MainActor
final class QueueEventLog {
    private(set) var seen: [QueueEvent] = []
    private var waiters: [UUID: (events: Set<QueueEvent>, continuation: CheckedContinuation<Void, Error>)] = [:]

    func record(_ event: QueueEvent) {
        seen.append(event)
        for (id, waiter) in waiters where waiter.events.isSubset(of: Set(seen)) {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    func wait(for events: Set<QueueEvent>, file: StaticString = #fileID, line: UInt = #line) async throws {
        if events.isSubset(of: Set(seen)) { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters[id] = (events, continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
                let missing = waiter.events.subtracting(self.seen)
                waiter.continuation.resume(throwing: TestFailure(description: "\(file):\(line) nunca llegó \(missing); vistos: \(self.seen)"))
            }
        }
    }

    func count(_ event: QueueEvent) -> Int { seen.filter { $0 == event }.count }
}

/// Pipeline falso: cada job queda suspendido hasta que el test lo completa a mano.
/// `run` no está aislado al main actor, así que dos jobs que corren a la vez entran en un orden
/// cualquiera: los tests comparan conjuntos salvo cuando la cola serializa los arranques.
final class FakePipeline: ReviewPipelineRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let events: QueueEventLog
    private var continuations: [String: CheckedContinuation<ReviewDraft, Error>] = [:]
    private var phaseSinks: [String: @MainActor @Sendable (ReviewPhase) -> Void] = [:]
    private var _started: [String] = []

    init(events: QueueEventLog) { self.events = events }

    /// Orden en que entraron a `run`.
    var started: [String] { lock.withLock { _started } }

    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        let prID = request.item.id
        let events = self.events
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    _started.append(prID)
                    phaseSinks[prID] = onPhase
                    continuations[prID] = continuation
                }
                // Se avisa después de registrar la continuación, así `complete` siempre la encuentra.
                Task { @MainActor in events.record(.started(prID)) }
            }
        } onCancel: {
            let continuation = lock.withLock { continuations.removeValue(forKey: prID) }
            continuation?.resume(throwing: CancellationError())
            Task { @MainActor in events.record(.cancelled(prID)) }
        }
    }

    @MainActor func send(_ phase: ReviewPhase, to prID: String) {
        let sink = lock.withLock { phaseSinks[prID] }
        sink?(phase)
    }

    func complete(_ prID: String, _ result: Result<ReviewDraft, Error>) {
        let continuation = lock.withLock { continuations.removeValue(forKey: prID) }
        continuation?.resume(with: result)
    }
}

/// Pipeline falso que no se entera de la cancelación: cada corrida queda colgada hasta que el test la
/// completa, y guarda su propio `onPhase`, para simular una corrida vieja que avisa tarde.
final class StubbornPipeline: ReviewPipelineRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [(sink: @MainActor @Sendable (ReviewPhase) -> Void, continuation: CheckedContinuation<ReviewDraft, Error>)] = []

    var count: Int { lock.withLock { runs.count } }

    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { runs.append((onPhase, continuation)) }
        }
    }

    @MainActor func send(_ phase: ReviewPhase, toRun index: Int) {
        let sink = lock.withLock { runs[index].sink }
        sink(phase)
    }

    func complete(run index: Int, _ result: Result<ReviewDraft, Error>) {
        let continuation = lock.withLock { runs[index].continuation }
        continuation.resume(with: result)
    }
}

private func request(_ number: Int) -> ReviewRequest {
    let pr = makePR(number: number)
    return ReviewRequest(item: ClassifiedPR(pr: pr, category: .toReview, account: "fede"), localPath: nil, baseRef: pr.baseRef)
}

private func prID(_ number: Int) -> String { request(number).item.id }
private func started(_ numbers: Int...) -> Set<QueueEvent> { Set(numbers.map { .started(prID($0)) }) }
private func finished(_ numbers: Int...) -> Set<QueueEvent> { Set(numbers.map { .finished(prID($0)) }) }

private func draft(_ number: Int) -> ReviewDraft {
    let pr = makePR(number: number)
    return ReviewDraft(prID: pr.id, repo: pr.repo, number: number, title: pr.title, url: pr.url, author: pr.author,
                       headOid: pr.headOid, account: "fede", summary: "s", items: [])
}

private struct Boom: Error, LocalizedError {
    var errorDescription: String? { "explotó" }
}

@MainActor
private final class Harness {
    let events = QueueEventLog()
    let pipeline: FakePipeline
    var finished: [(String, Result<ReviewDraft, Error>)] = []
    private(set) var queue: ReviewQueue!

    init(maxConcurrent: Int = 2) {
        pipeline = FakePipeline(events: events)
        queue = ReviewQueue(pipeline: pipeline, maxConcurrent: maxConcurrent) { [unowned self] request, result in
            self.finished.append((request.item.id, result))
            self.events.record(.finished(request.item.id))
        }
    }

    /// Para aserciones negativas ("esto no pasó"): da tiempo a que una Task rezagada actúe.
    /// Si la cola tuviera el bug, el test fallaría casi siempre; nunca puede fallar por lentitud.
    func settle() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

private func isRunning(_ phase: ReviewPhase?) -> Bool {
    switch phase {
    case .preparing?, .reviewing?, .filtering?: true
    default: false
    }
}

private let fakeLog = URL(fileURLWithPath: "/tmp/prbar-review.log")

@MainActor
private func threeQueued() async throws -> Harness {
    let h = Harness()
    for n in 1...3 { h.queue.enqueue(request(n)) }
    try await h.events.wait(for: started(1, 2))
    return h
}

enum ReviewQueueTests {
    static let cases: [TestCase] = [
        TestCase("review queue: con 3 encolados y máximo 2 corren 2; al terminar uno arranca el tercero") { @MainActor in
            let h = try await threeQueued()
            try expect(isRunning(h.queue.phases[prID(1)]))
            try expect(isRunning(h.queue.phases[prID(2)]))
            try expectEqual(h.queue.phases[prID(3)], .queued)
            try expectEqual(Set(h.pipeline.started), [prID(1), prID(2)])
            h.pipeline.complete(prID(1), .success(draft(1)))
            try await h.events.wait(for: started(3))
            try expect(isRunning(h.queue.phases[prID(3)]))
        },
        TestCase("review queue: las fases de onPhase se reflejan en phases") { @MainActor in
            let h = Harness()
            h.queue.enqueue(request(1))
            try await h.events.wait(for: started(1))
            h.pipeline.send(.reviewing(agents: 3), to: prID(1))
            try expectEqual(h.queue.phases[prID(1)], .reviewing(agents: 3))
            h.pipeline.send(.filtering, to: prID(1))
            try expectEqual(h.queue.phases[prID(1)], .filtering)
        },
        TestCase("review queue: éxito deja .ready y llama a onFinished con success") { @MainActor in
            let h = Harness()
            h.queue.enqueue(request(1))
            try await h.events.wait(for: started(1))
            h.pipeline.complete(prID(1), .success(draft(1)))
            try await h.events.wait(for: finished(1))
            try expectEqual(h.queue.phases[prID(1)], .ready(draft(1)).withDraftID(of: h.queue.phases[prID(1)]))
            guard case .success(let d) = h.finished[0].1 else { throw TestFailure(description: "esperaba success") }
            try expectEqual(d.prID, prID(1))
        },
        TestCase("review queue: un error deja .failed con mensaje y log, y onFinished recibe failure") { @MainActor in
            let h = Harness()
            h.queue.enqueue(request(1))
            try await h.events.wait(for: started(1))
            h.pipeline.complete(prID(1), .failure(ReviewFailure(underlying: Boom(), logURL: fakeLog)))
            try await h.events.wait(for: finished(1))
            try expectEqual(h.queue.phases[prID(1)], .failed("explotó", logURL: fakeLog))
            guard case .failure = h.finished[0].1 else { throw TestFailure(description: "esperaba failure") }

            h.queue.enqueue(request(2))
            try await h.events.wait(for: started(2))
            h.pipeline.complete(prID(2), .failure(Boom()))
            try await h.events.wait(for: finished(2))
            try expectEqual(h.queue.phases[prID(2)], .failed("explotó", logURL: nil))
        },
        TestCase("review queue: cancel de un job corriendo borra la fase y libera el lugar") { @MainActor in
            let h = try await threeQueued()
            h.queue.cancel(prID: prID(1))
            // Libera el lugar en el acto, sin esperar a que la Task cancelada termine.
            try expectEqual(h.queue.phases[prID(1)], nil)
            try expect(isRunning(h.queue.phases[prID(3)]))
            try await h.events.wait(for: started(3).union([.cancelled(prID(1))]))
            await h.settle()
            try expectEqual(h.queue.phases[prID(1)], nil)
            try expect(h.finished.isEmpty, "onFinished no debe llamarse al cancelar")
        },
        TestCase("review queue: una corrida cancelada que avisa tarde no pisa la nueva del mismo PR") { @MainActor in
            let pipeline = StubbornPipeline()
            var finished: [String] = []
            let queue = ReviewQueue(pipeline: pipeline, maxConcurrent: 1) { request, _ in finished.append(request.item.id) }
            queue.enqueue(request(1))
            for _ in 0..<5_000 where pipeline.count < 1 { try? await Task.sleep(nanoseconds: 1_000_000) }
            queue.cancel(prID: prID(1))
            queue.enqueue(request(1))
            for _ in 0..<5_000 where pipeline.count < 2 { try? await Task.sleep(nanoseconds: 1_000_000) }
            try expectEqual(queue.phases[prID(1)], .preparing)
            pipeline.send(.filtering, toRun: 0)
            try expectEqual(queue.phases[prID(1)], .preparing)
            pipeline.complete(run: 0, .success(draft(1)))
            try? await Task.sleep(nanoseconds: 20_000_000)
            try expectEqual(queue.phases[prID(1)], .preparing)
            try expect(finished.isEmpty, "el aviso tardío no debe llegar")
            pipeline.send(.reviewing(agents: 2), toRun: 1)
            try expectEqual(queue.phases[prID(1)], .reviewing(agents: 2))
            pipeline.complete(run: 1, .success(draft(1)))
            for _ in 0..<5_000 where finished.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
            try expectEqual(finished, [prID(1)])
            guard case .ready? = queue.phases[prID(1)] else { throw TestFailure(description: "esperaba .ready") }
        },
        TestCase("review queue: si al cancelar no se pudo confirmar que Claude paró en el host, lo dice") { @MainActor in
            let pipeline = StubbornPipeline()
            let queue = ReviewQueue(pipeline: pipeline, maxConcurrent: 1) { _, _ in }
            let notStopped = ReviewFailure(underlying: RemoteRunnerError.jobNotStopped(host: "devbox"), logURL: fakeLog)
            queue.enqueue(request(1))
            for _ in 0..<5_000 where pipeline.count < 1 { try? await Task.sleep(nanoseconds: 1_000_000) }
            queue.cancel(prID: prID(1))
            try expectEqual(queue.phases[prID(1)], nil)
            pipeline.complete(run: 0, .failure(notStopped))
            for _ in 0..<5_000 where queue.phases[prID(1)] == nil { try? await Task.sleep(nanoseconds: 1_000_000) }
            guard case .failed(let message, let log)? = queue.phases[prID(1)] else {
                throw TestFailure(description: "\(String(describing: queue.phases[prID(1)]))")
            }
            try expect(message.contains("Claude may still be running on devbox; PRBar won’t touch that worktree"), message)
            try expectEqual(log, fakeLog)
            // Una corrida nueva del mismo PR no se pisa con el aviso de la vieja.
            queue.dismiss(prID: prID(1))
            queue.enqueue(request(1))
            for _ in 0..<5_000 where pipeline.count < 2 { try? await Task.sleep(nanoseconds: 1_000_000) }
            queue.cancel(prID: prID(1))
            queue.enqueue(request(1))
            for _ in 0..<5_000 where pipeline.count < 3 { try? await Task.sleep(nanoseconds: 1_000_000) }
            pipeline.complete(run: 1, .failure(notStopped))
            try? await Task.sleep(nanoseconds: 20_000_000)
            try expectEqual(queue.phases[prID(1)], .preparing)
        },
        TestCase("review queue: cancel de uno en cola lo saca de la cola") { @MainActor in
            let h = try await threeQueued()
            h.queue.cancel(prID: prID(3))
            try expectEqual(h.queue.phases[prID(3)], nil)
            h.pipeline.complete(prID(1), .success(draft(1)))
            try await h.events.wait(for: finished(1))
            await h.settle()
            try expectEqual(h.events.count(.started(prID(3))), 0)
            try expectEqual(Set(h.pipeline.started), [prID(1), prID(2)])
        },
        TestCase("review queue: cancelAll cancela los que corren y vacía la cola, sin arrancar otros") { @MainActor in
            let h = try await threeQueued()
            h.queue.cancelAll()
            for number in 1...3 { try expectEqual(h.queue.phases[prID(number)], nil) }
            try await h.events.wait(for: [.cancelled(prID(1)), .cancelled(prID(2))])
            await h.settle()
            try expectEqual(h.events.count(.started(prID(3))), 0)
            try expect(h.finished.isEmpty, "onFinished no debe llamarse al cancelar")
        },
        TestCase("review queue: encolar el mismo PR dos veces no duplica") { @MainActor in
            let h = Harness()
            h.queue.enqueue(request(1))
            h.queue.enqueue(request(1))
            h.queue.enqueue(request(2))
            h.queue.enqueue(request(3))
            h.queue.enqueue(request(3))
            try await h.events.wait(for: started(1, 2))
            h.pipeline.complete(prID(1), .success(draft(1)))
            try await h.events.wait(for: started(3))
            h.pipeline.complete(prID(2), .success(draft(2)))
            h.pipeline.complete(prID(3), .success(draft(3)))
            try await h.events.wait(for: finished(1, 2, 3))
            await h.settle()
            try expectEqual(h.pipeline.started.count, 3)
            try expectEqual(Set(h.pipeline.started), [prID(1), prID(2), prID(3)])
            try expectEqual(h.finished.count, 3)
        },
        TestCase("review queue: markPublished, dismiss y restore") { @MainActor in
            let h = Harness()
            let url = URL(string: "https://github.com/o/r/pull/1#pullrequestreview-1")!
            h.queue.restore(draft(1))
            try expectEqual(h.queue.phases[prID(1)], .ready(draft(1)).withDraftID(of: h.queue.phases[prID(1)]))
            h.queue.markPublished(prID: prID(1), url: url)
            try expectEqual(h.queue.phases[prID(1)], .published(url))
            h.queue.dismiss(prID: prID(1))
            try expectEqual(h.queue.phases[prID(1)], nil)
        },
        TestCase("review queue: la review publicada se descarta cuando el PR recibe otro commit") { @MainActor in
            let h = Harness()
            let url = URL(string: "https://github.com/o/r/pull/1#pullrequestreview-1")!
            h.queue.markPublished(prID: prID(1), url: url, headOid: "aaa")
            h.queue.dropOutdatedPublished(heads: [prID(1): "aaa"])
            try expectEqual(h.queue.phases[prID(1)], .published(url))
            h.queue.dropOutdatedPublished(heads: [:])
            try expectEqual(h.queue.phases[prID(1)], .published(url))
            h.queue.dropOutdatedPublished(heads: [prID(1): "bbb"])
            try expectEqual(h.queue.phases[prID(1)], nil)
            h.queue.markPublished(prID: prID(2), url: url)
            h.queue.dropOutdatedPublished(heads: [prID(2): "ccc"])
            try expectEqual(h.queue.phases[prID(2)], .published(url))
        },
        TestCase("review queue: markFailed marca el error sin pisar un job activo ni avisar") { @MainActor in
            let h = Harness()
            h.queue.markFailed(prID: prID(1), message: "No se encontró claude")
            try expectEqual(h.queue.phases[prID(1)], .failed("No se encontró claude", logURL: nil))
            try expectEqual(h.finished.count, 0)
            h.queue.dismiss(prID: prID(1))
            try expectEqual(h.queue.phases[prID(1)], nil)
            h.queue.enqueue(request(2))
            try await h.events.wait(for: started(2))
            h.queue.markFailed(prID: prID(2), message: "x")
            try expect(isRunning(h.queue.phases[prID(2)]), "no debe pisar un job activo")
            h.pipeline.complete(prID(2), .success(draft(2)))
            try await h.events.wait(for: finished(2))
            await h.settle()
        },
    ] + ReviewPipelineTests.cases
}

private extension ReviewPhase {
    /// Los drafts de los tests se crean con un `id` nuevo; se copia el del valor real para comparar el resto.
    func withDraftID(of other: ReviewPhase?) -> ReviewPhase {
        guard case .ready(var mine) = self, case .ready(let theirs)? = other else { return self }
        mine.id = theirs.id
        return .ready(mine)
    }
}

// MARK: - ReviewPipeline real

private let stageOneEmpty = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"Todo bien.","findings":[]}}"#
private let reviewSessionID = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
private let initLine = #"{"type":"system","subtype":"init","session_id":"1b4e28ba-2fa1-11d2-883f-0016d3cca427"}"#

/// Caché de plugins falsa (`<cache>/<marketplace>/<plugin>/<versión>`) con los plugins de los skills por defecto.
private func pluginCache(in root: URL) throws -> URL {
    let cache = root.appendingPathComponent("plugins", isDirectory: true)
    for name in ["pr-review-toolkit", "superpowers"] {
        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("official/\(name)/1.0/.claude-plugin"), withIntermediateDirectories: true
        )
    }
    return cache
}

private func pipeline(git: FakeProcessRunner, claude: FakeStreamingRunner, root: URL, logs: URL,
                      tokens: FakeTokens = FakeTokens(), plugins: URL? = nil, api: FakeAPI = FakeAPI(),
                      settings: ClaudeSettings = ClaudeSettings()) throws -> ReviewPipeline {
    ReviewPipeline(
        processRunner: git, streamingRunner: claude, tokens: tokens, api: api,
        gitPath: "/usr/bin/git", ghPath: "/usr/local/bin/gh", claudePath: "/usr/local/bin/claude", worktreeRoot: root,
        pluginCacheDirectory: try plugins ?? pluginCache(in: logs), settings: settings,
        logURLProvider: { logs.appendingPathComponent("\($0.uuidString).log") }
    )
}

private func diffOnlyRequest(_ number: Int) -> ReviewRequest {
    let pr = makePR(number: number, head: "deadbeef")
    return ReviewRequest(item: ClassifiedPR(pr: pr, category: .toReview, account: "fede"), localPath: nil, baseRef: pr.baseRef)
}

private func clonedRequest(_ number: Int) -> ReviewRequest {
    let pr = makePR(number: number, head: "deadbeef")
    return ReviewRequest(item: ClassifiedPR(pr: pr, category: .toReview, account: "fede"), localPath: "/repos/r", baseRef: pr.baseRef)
}

/// La limpieza borró las dos refs de la corrida (el fake no crea la carpeta del worktree, así que no hay
/// `worktree remove`).
private func cleanedUp(_ git: FakeProcessRunner) -> Bool {
    let deleted = git.calls.filter { $0.arguments.contains("update-ref") }.compactMap(\.arguments.last)
    return deleted.contains { $0.hasPrefix("refs/prbar/pr-") } && deleted.contains { $0.hasPrefix("refs/prbar/base-") }
}

enum ReviewPipelineTests {
    static let cases: [TestCase] = [
        TestCase("review pipeline: éxito arma el draft con headOid, account y url, y conserva la carpeta sin su contexto") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let git = gitFake()
            let claude = FakeStreamingRunner { _, _, _ in ([initLine, stageOneEmpty], ok("")) }
            let phases = Box<[ReviewPhase]>([])
            let req = clonedRequest(9)
            let draft = try await pipeline(git: git, claude: claude, root: root.appendingPathComponent("wt"), logs: root)
                .run(req) { phases.value.append($0) }
            // El commit revisado es el que se trajo con el fetch, no el del snapshot ("deadbeef").
            try expectEqual(draft.headOid, fetchedSHA)
            try expectEqual(draft.account, "fede")
            try expectEqual(draft.url, req.item.pr.url)
            try expectEqual(draft.prID, req.item.id)
            try expectEqual(draft.summary, "Todo bien.")
            try expectEqual(phases.value, [.preparing, .reviewing(agents: 0)])
            try expectEqual(claude.calls[0].environment?["GH_TOKEN"], nil)
            let args = claude.calls[0].arguments
            try expectEqual(args.filter { $0 == "--plugin-dir" }.count, 2)
            try expect(args.contains(root.appendingPathComponent("plugins/official/superpowers/1.0").path), "\(args)")
            // Spec T.3: la carpeta y sus refs quedan para "Open in Terminal"; el contexto (pr.diff, pr.md) no.
            try expect(!cleanedUp(git))
            let kept = try expectSome(draft.retainedLocation)
            try expectEqual(kept.repository, "/repos/r")
            try expectEqual(kept.runner, nil)
            try expectEqual(kept.refs.count, 2)
            try expect(!FileManager.default.fileExists(atPath: kept.directory + ".context"))
            try expect(!WorkspaceRegistry.shared.contains(kept.directory))
            // El log usa el id del draft.
            try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(draft.id.uuidString).log").path))
        },
        TestCase("review pipeline: without a Claude session the folder is cleaned up as before (nothing to resume)") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let git = gitFake()
            let claude = FakeStreamingRunner { _, _, _ in ([stageOneEmpty], ok("")) }
            let draft = try await pipeline(git: git, claude: claude, root: root.appendingPathComponent("wt"), logs: root)
                .run(clonedRequest(9)) { _ in }
            try expectEqual(draft.sessions.count, 0)
            try expectEqual(draft.retainedLocation, nil)
            try expect(cleanedUp(git))
        },
        TestCase("review pipeline: fetches the description, puts it in pr.md and reviews in the PR's language") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            var api = FakeAPI()
            api.details = .success(PRDetails(
                title: "Validar email",
                body: "<!-- template -->\nEste PR agrega la validación del email en el formulario de registro y muestra un error claro.",
                headOid: nil))
            let seenMetadata = Box<String?>(nil)
            let claude = FakeStreamingRunner { _, args, _ in
                if let dir = args.firstIndex(of: "--add-dir").map({ args[$0 + 1] }) {
                    seenMetadata.value = try? String(contentsOfFile: dir + "/pr.md", encoding: .utf8)
                }
                return ([stageOneEmpty], ok(""))
            }
            let draft = try await pipeline(git: gitFake(), claude: claude, root: root.appendingPathComponent("wt"), logs: root, api: api)
                .run(clonedRequest(9)) { _ in }
            try expectEqual(draft.language, PRLanguage(code: "es"))
            try expectEqual(api.detailsTokens.value, ["tok-fede"])
            try expect(seenMetadata.value?.contains("agrega la validación del email") == true, seenMetadata.value ?? "nil")
            let args = claude.calls[0].arguments
            let prompt = args[args.firstIndex(of: "-p")! + 1]
            try expect(prompt.contains("written in Spanish (language code \"es\")"), prompt)
        },
        TestCase("review pipeline: if the description can't be fetched, it still reviews (language from the title)") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            var api = FakeAPI()
            api.details = .failure(.http(status: 502, message: "Bad Gateway"))
            let claude = FakeStreamingRunner { _, _, _ in ([stageOneEmpty], ok("")) }
            let draft = try await pipeline(git: gitFake(), claude: claude, root: root.appendingPathComponent("wt"), logs: root, api: api)
                .run(clonedRequest(9)) { _ in }
            try expectEqual(draft.language, .english)
            try expectEqual(claude.calls.count, 1)
        },
        TestCase("review pipeline: si Claude falla, limpia y lanza ReviewFailure con el log") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let git = gitFake()
            let claude = FakeStreamingRunner { _, _, _ in ([], fail("boom", status: 3)) }
            let error = try await expectThrows {
                _ = try await pipeline(git: git, claude: claude, root: root.appendingPathComponent("wt"), logs: root)
                    .run(clonedRequest(9)) { _ in }
            }
            guard let failure = error as? ReviewFailure else { throw TestFailure(description: "error inesperado: \(error)") }
            try expectEqual(failure.underlying as? PRBarError, .commandFailed(command: "claude", status: 3, stderr: "boom"))
            try expect(failure.logURL?.path.hasPrefix(root.path) == true)
            try expect(failure.errorDescription?.contains("boom") == true)
            try expect(cleanedUp(git))
        },
        TestCase("review pipeline: al cancelar, la limpieza corre fuera de la tarea cancelada y se relanza CancellationError") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let cleanupSawCancel = Box<Bool?>(nil)
            let git = gitFake { _, args in
                if args.contains("update-ref") { cleanupSawCancel.value = Task.isCancelled }
                return ok("")
            }
            let claude = FakeStreamingRunner { _, _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
            let p = try pipeline(git: git, claude: claude, root: root.appendingPathComponent("wt"), logs: root)
            let error = try await expectThrows {
                _ = try await Task { try await p.run(clonedRequest(9)) { _ in } }.value
            }
            try expect(error is CancellationError, "error inesperado: \(error)")
            try expect(cleanedUp(git))
            try expectEqual(cleanupSawCancel.value, false)
        },
        TestCase("review pipeline: si falla el token no prepara worktree") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let git = gitFake()
            let claude = FakeStreamingRunner { _, _, _ in ([stageOneEmpty], ok("")) }
            let p = try pipeline(git: git, claude: claude, root: root, logs: root, tokens: FakeTokens(failing: ["fede"]))
            let error = try await expectThrows { _ = try await p.run(clonedRequest(9)) { _ in } }
            try expectEqual((error as? ReviewFailure)?.underlying as? PRBarError, .unauthorized)
            try expectEqual((error as? ReviewFailure)?.logURL, nil)
            try expectEqual(git.calls.count, 0)
            try expectEqual(claude.calls.count, 0)
        },
        TestCase("review pipeline: escribe pr.diff con el git diff antes de correr Claude") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let git = gitFake { _, args in args.contains("diff") ? ok("+cambio\n") : ok("") }
            let seen = Box<String?>(nil)
            let claude = FakeStreamingRunner { _, args, cwd in
                let context = URL(fileURLWithPath: args[args.firstIndex(of: "--add-dir")! + 1])
                seen.value = try? String(contentsOf: context.appendingPathComponent("pr.diff"), encoding: .utf8)
                try expect(cwd != nil && context.deletingLastPathComponent() == cwd!.deletingLastPathComponent())
                return ([stageOneEmpty], ok(""))
            }
            _ = try await pipeline(git: git, claude: claude, root: root.appendingPathComponent("wt"), logs: root)
                .run(clonedRequest(9)) { _ in }
            try expectEqual(seen.value, "+cambio\n")
            try expect(git.calls.contains { call in
                call.arguments.contains { $0.hasPrefix("refs/prbar/base-9-") && $0.hasSuffix("...HEAD") }
            })
            // La limpieza borra también la carpeta de contexto.
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("wt").path), [])
        },
        TestCase("review pipeline: si falla el diff, limpia y no corre Claude") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let git = gitFake { _, args in args.contains("diff") ? fail("fatal: bad revision", status: 128) : ok("") }
            let claude = FakeStreamingRunner { _, _, _ in ([stageOneEmpty], ok("")) }
            let error = try await expectThrows {
                _ = try await pipeline(git: git, claude: claude, root: root.appendingPathComponent("wt"), logs: root)
                    .run(clonedRequest(9)) { _ in }
            }
            guard let failure = error as? ReviewFailure,
                  case .commandFailed(_, 128, "fatal: bad revision")? = failure.underlying as? PRBarError else {
                throw TestFailure(description: "error inesperado: \(error)")
            }
            try expectEqual(claude.calls.count, 0)
            try expect(cleanedUp(git))
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("wt").path), [])
        },
        TestCase("review pipeline: modo solo diff baja el diff con gh y el token, y Claude no lo recibe") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = gitFake { _, _ in ok("+desde gh\n") }
            let claude = FakeStreamingRunner { _, _, _ in ([stageOneEmpty], ok("")) }
            let draft = try await pipeline(git: runner, claude: claude, root: root.appendingPathComponent("wt"), logs: root)
                .run(diffOnlyRequest(9)) { _ in }
            try expectEqual(draft.headOid, fetchedSHA)
            try expectEqual(runner.calls.map(\.executable), ["/usr/local/bin/gh", "/usr/local/bin/gh"])
            try expectEqual(runner.calls.map { $0.arguments[1] }, ["view", "diff"])
            try expectEqual(runner.calls.map { $0.environment?["GH_TOKEN"] }, ["tok-fede", "tok-fede"])
            try expectEqual(claude.calls[0].environment?["GH_TOKEN"], nil)
        },
        TestCase("review pipeline: si falta un plugin falla con un error claro sin preparar nada") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let git = gitFake()
            let claude = FakeStreamingRunner { _, _, _ in ([stageOneEmpty], ok("")) }
            let empty = root.appendingPathComponent("no-plugins")
            let error = try await expectThrows {
                _ = try await pipeline(git: git, claude: claude, root: root.appendingPathComponent("wt"), logs: root, plugins: empty)
                    .run(clonedRequest(9)) { _ in }
            }
            try expectEqual((error as? ReviewFailure)?.underlying as? PRBarError, .claudePluginMissing(plugin: "pr-review-toolkit", skill: "pr-review-toolkit:review-pr"))
            try expectEqual(git.calls.count, 0)
            try expectEqual(claude.calls.count, 0)
        },
        TestCase("review pipeline: with the filter off only the review skill's plugin is loaded and Claude runs once") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let findings = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"s","findings":[{"id":"f1","severity":"high","file":"a.swift","line":3,"title":"t","body":"b"}]}}"#
            let claude = FakeStreamingRunner { _, _, _ in ([findings], ok("")) }
            var settings = ClaudeSettings()
            settings.filterEnabled = false
            settings.model = .sonnet
            let draft = try await pipeline(git: gitFake(), claude: claude, root: root.appendingPathComponent("wt"), logs: root,
                                           settings: settings).run(clonedRequest(9)) { _ in }
            try expectEqual(claude.calls.count, 1)
            try expectEqual(draft.items.map(\.keep), [true])
            try expectEqual(draft.items.map(\.reason), ["Filter disabled"])
            let args = claude.calls[0].arguments
            try expectEqual(args.filter { $0 == "--plugin-dir" }.count, 1)
            try expect(args.contains(root.appendingPathComponent("plugins/official/pr-review-toolkit/1.0").path), "\(args)")
            try expectEqual(args[args.firstIndex(of: "--model")! + 1], "sonnet")
        },
        TestCase("review pipeline: a configured skill whose plugin isn't installed fails before preparing anything") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let git = gitFake()
            let claude = FakeStreamingRunner { _, _, _ in ([stageOneEmpty], ok("")) }
            var settings = ClaudeSettings()
            settings.filterSkill = "my-plugin:triage"
            let error = try await expectThrows {
                _ = try await pipeline(git: git, claude: claude, root: root.appendingPathComponent("wt"), logs: root, settings: settings)
                    .run(clonedRequest(9)) { _ in }
            }
            try expectEqual((error as? ReviewFailure)?.underlying as? PRBarError,
                            .claudePluginMissing(plugin: "my-plugin", skill: "my-plugin:triage"))
            try expectEqual(git.calls.count, 0)
            try expectEqual(claude.calls.count, 0)
        },
        TestCase("review pipeline: el token de la cuenta se tacha del log y del draft, y Claude recibe PATH") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let leaky = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"Vi tok-fede.","findings":[]}}"#
            let git = gitFake()
            let claude = FakeStreamingRunner { _, _, _ in ([leaky], ok("")) }
            let draft = try await pipeline(git: git, claude: claude, root: root.appendingPathComponent("wt"), logs: root)
                .run(clonedRequest(9)) { _ in }
            try expectEqual(draft.summary, "Vi ***.")
            let log = try String(contentsOf: root.appendingPathComponent("\(draft.id.uuidString).log"), encoding: .utf8)
            try expect(!log.contains("tok-fede"), log)
            try expectEqual(claude.calls[0].environment?["PATH"], "/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin")
        },
        TestCase("review pipeline: guarda la sesión de cada etapa (también si Claude falla)") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let claude = FakeStreamingRunner { _, _, _ in ([initLine, stageOneEmpty], ok("")) }
            let draft = try await pipeline(git: gitFake(), claude: claude, root: root.appendingPathComponent("wt"), logs: root)
                .run(clonedRequest(9)) { _ in }
            try expectEqual(draft.sessions.map(\.label), ["Review · stage 1"])
            try expectEqual(draft.sessions.map(\.id), [reviewSessionID])
            try expectEqual(draft.sessions.map(\.runner), [nil])
            try expect(draft.sessions[0].directory.hasPrefix(root.appendingPathComponent("wt").path), draft.sessions[0].directory)

            let crashed = FakeStreamingRunner { _, _, _ in ([initLine], fail("boom", status: 3)) }
            let error = try await expectThrows {
                _ = try await pipeline(git: gitFake(), claude: crashed, root: root.appendingPathComponent("wt2"), logs: root)
                    .run(clonedRequest(9)) { _ in }
            }
            try expectEqual((error as? ReviewFailure)?.sessions.map(\.id), [reviewSessionID])
        },
    ]
}
