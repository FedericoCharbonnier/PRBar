import Combine
import Foundation
import PRBarCore

// MARK: - Datos

private let sha1 = String(repeating: "1", count: 40)
private let startOid = String(repeating: "0", count: 40)

private func classified(_ number: Int) -> ClassifiedPR {
    ClassifiedPR(pr: makePR(number: number, author: "fede"), category: .myFeedback, account: "fede")
}

private func prID(_ number: Int) -> String { classified(number).id }

private func threadItem(_ id: String, databaseID: Int, body: String = "Cambiá esto.") -> FeedbackItem {
    FeedbackItem(
        id: id, kind: .thread, path: "README.md", line: 1, isOutdated: false,
        comments: [FeedbackComment(databaseID: databaseID, author: "ana", isBot: false, body: body, createdAt: t0,
                                   url: URL(string: "https://github.com/o/r/pull/7#discussion_r\(databaseID)")!)])
}

private func respondItem(_ feedback: FeedbackItem, action: FeedbackAction = .fixAndReply) -> RespondItem {
    RespondItem(feedback: feedback, assessment: "Tiene razón.", action: action, fixPlan: "plan", reply: "Gracias")
}

private func fakeDraft(_ number: Int, id: UUID, mode: RespondMode = .feedback) -> RespondDraft {
    let pr = makePR(number: number, author: "fede")
    return RespondDraft(
        id: id, prID: pr.id, repo: pr.repo, number: number, title: pr.title, url: pr.url, headRef: pr.headRef,
        account: "fede", worktree: ResolvedWorktree(path: "/wt/\(number)", origin: .dedicated, localPath: "/repos/r",
                                                    ref: "refs/prbar/respond-\(number)-0a1b2c3d"), startHeadOid: startOid,
        items: [respondItem(threadItem("thread:A", databaseID: 101)), respondItem(threadItem("thread:B", databaseID: 102))],
        language: PRLanguage(code: "es"), mode: mode)
}

private let bothSelected: [String: RespondSelection] = [
    "thread:A": RespondSelection(implement: true, fixPlan: "plan A", reply: true, replyText: ""),
    "thread:B": RespondSelection(implement: false, fixPlan: "", reply: true, replyText: "Lo dejo así."),
]

private let fixResult = RespondResult(items: [ItemResult(id: "thread:A", status: .committed, commit: sha1, summary: "ok")],
                                      diffStat: " README.md | 1 +", tests: nil)

/// `fixResult` with the fix's Claude session (spec T.2): a pushed run with sessions is kept for Terminal.
private let fixResultWithSession = RespondResult(
    items: [ItemResult(id: "thread:A", status: .committed, commit: sha1, summary: "ok",
                       session: ClaudeSessionStamp(id: "6f1c2d3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f", startedAt: t0))],
    diffStat: " README.md | 1 +", tests: nil)

private let postA = FakeFeedbackAPI.Post.reply(commentID: 101, body: "Arreglado en https://github.com/o/r/commit/\(sha1).")
private let postB = FakeFeedbackAPI.Post.reply(commentID: 102, body: "Lo dejo así.")

private struct Boom: Error, LocalizedError {
    var errorDescription: String? { "explotó" }
}

// MARK: - Pipeline falso

/// Análisis e implementación quedan suspendidos hasta que el test los completa. Las respuestas usan el
/// `RespondPublisher` real contra `FakeFeedbackAPI`.
final class FakeRespondPipeline: RespondPipelineRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let events: QueueEventLog
    let api: FakeFeedbackAPI
    private var analyses: [String: (id: UUID, sink: @MainActor @Sendable (RespondPhase) -> Void,
                                    continuation: CheckedContinuation<RespondDraft, Error>)] = [:]
    private var implementations: [String: (sink: @MainActor @Sendable (Int, Int) -> Void,
                                           continuation: CheckedContinuation<RespondResult, Error>)] = [:]
    private var cancelled: [String: CheckedContinuation<Void, Never>] = [:]
    private var _pushes: [String] = []
    private var _tests: [String] = []
    private var _cleanups: [UUID] = []
    var pushError: Error?
    var testsPass = false
    /// Commits que "quedan" si se cancela la implementación.
    var commitsLeftOnCancel = 0
    /// Si es true, la cancelación de una implementación espera a `finishCancel` (simula la restauración).
    var slowCancel = false
    /// Lo que lanza un análisis cancelado (p. ej. `jobNotStopped`: no se pudo confirmar que Claude paró en el host).
    var analyzeCancelError: Error?
    /// Lo que "gasta" cada análisis e implementación en Claude (spec O), anotado antes de esperar.
    var spend: ClaudeUsage?
    /// Se llama justo antes de que una implementación devuelva su resultado (fuera del main actor).
    var beforeImplementReturns: (@Sendable () -> Void)?

    init(events: QueueEventLog, api: FakeFeedbackAPI = FakeFeedbackAPI()) {
        self.events = events
        self.api = api
    }

    var pushes: [String] { lock.withLock { _pushes } }
    /// Los drafts cuyo worktree se pidió limpiar, en orden.
    var cleanups: [UUID] { lock.withLock { _cleanups } }
    private var _releases: [UUID] = []
    var releases: [UUID] { lock.withLock { _releases } }
    var tests: [String] { lock.withLock { _tests } }

    func logURL(for id: UUID) -> URL { URL(fileURLWithPath: "/nonexistent/\(id.uuidString).log") }

    /// Each job's step sink; not emptied on cancel (a test sends a late step from the old run).
    private var analysisSteps: [String: JobActivitySink] = [:]
    private var implementSteps: [String: JobActivitySink] = [:]

    func analyze(_ request: RespondRequest, draftID: UUID,
                 onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void) async throws -> RespondDraft {
        try await analyze(request, draftID: draftID, onPhase: onPhase, onActivity: { _ in })
    }

    func analyze(_ request: RespondRequest, draftID: UUID, onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void,
                 onActivity: @escaping JobActivitySink) async throws -> RespondDraft {
        let prID = request.item.id
        lock.withLock { analysisSteps[prID] = onActivity }
        let events = self.events
        if let spend = lock.withLock({ self.spend }) { ClaudeUsageCenter.shared.record(spend, stage: "analysis") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { analyses[prID] = (draftID, onPhase, continuation) }
                Task { @MainActor in events.record(.started("analyze:\(prID)")) }
            }
        } onCancel: {
            let entry = lock.withLock { analyses.removeValue(forKey: prID) }
            entry?.continuation.resume(throwing: lock.withLock { analyzeCancelError } ?? CancellationError())
        }
    }

    func implement(draft: RespondDraft, selections: [String: RespondSelection],
                   onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> RespondResult {
        try await implement(draft: draft, selections: selections, onProgress: onProgress, onActivity: { _ in })
    }

    func implement(draft: RespondDraft, selections: [String: RespondSelection],
                   onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void,
                   onActivity: @escaping JobActivitySink) async throws -> RespondResult {
        let prID = draft.prID
        lock.withLock { implementSteps[prID] = onActivity }
        let events = self.events
        if let spend = lock.withLock({ self.spend }) { ClaudeUsageCenter.shared.record(spend, stage: "fix") }
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock { implementations[prID] = (onProgress, continuation) }
                    Task { @MainActor in events.record(.started("implement:\(prID)")) }
                }
            } onCancel: {
                let entry = lock.withLock { implementations.removeValue(forKey: prID) }
                entry?.continuation.resume(throwing: CancellationError())
            }
            lock.withLock { beforeImplementReturns }?()
            return result
        } catch is CancellationError {
            if lock.withLock({ slowCancel }) {
                await withCheckedContinuation { continuation in
                    lock.withLock { cancelled[prID] = continuation }
                    Task { @MainActor in events.record(.cancelled(prID)) }
                }
            }
            throw RespondCancellation(unpushedCommits: lock.withLock { commitsLeftOnCancel }, path: draft.worktree.path)
        }
    }

    func runTests(draft: RespondDraft, testCommand: String) async -> TestRun {
        let passed = lock.withLock { () -> Bool in
            _tests.append(testCommand)
            return testsPass
        }
        return TestRun(command: testCommand, passed: passed, outputTail: passed ? "ok" : "1 failure")
    }

    func push(draft: RespondDraft, result: RespondResult) async throws {
        lock.withLock { _pushes.append(draft.headRef) }
        if let pushError = lock.withLock({ self.pushError }) { throw pushError }
    }

    func postReplies(draft: RespondDraft, selections: [String: RespondSelection], result: RespondResult?,
                     alreadyPosted: [String: PostedReply],
                     onPosted: @escaping @Sendable (String, PostedReply) async -> Void) async -> (posted: [String: PostedReply], error: Error?) {
        await RespondPublisher(runner: FakeProcessRunner { _, _ in ok("") }, gitPath: "/usr/bin/git", api: api)
            .postReplies(draft: draft, selections: selections, result: result, alreadyPosted: alreadyPosted,
                         token: "tok", onPosted: onPosted)
    }

    func release(draft: RespondDraft) async {
        lock.withLock { _releases.append(draft.id) }
    }

    func cleanup(draft: RespondDraft) async {
        lock.withLock { _cleanups.append(draft.id) }
    }

    // Control desde el test

    @MainActor func sendAnalysis(_ phase: RespondPhase, to prID: String) {
        let sink = lock.withLock { analyses[prID]?.sink }
        sink?(phase)
    }

    /// `mode`: el del draft que devuelve (por defecto feedback, que se queda en `ready`; con Fix CI o Resolve
    /// Conflicts la cola arranca la implementación sola).
    func completeAnalysis(_ number: Int, _ result: Result<Void, Error> = .success(()), mode: RespondMode = .feedback) {
        let key = prID(number)
        guard let entry = lock.withLock({ analyses.removeValue(forKey: key) }) else { return }
        entry.continuation.resume(with: result.map { fakeDraft(number, id: entry.id, mode: mode) })
    }

    @MainActor func sendProgress(_ done: Int, _ total: Int, to prID: String) {
        let sink = lock.withLock { implementations[prID]?.sink }
        sink?(done, total)
    }

    func completeImplementation(_ prID: String, _ result: Result<RespondResult, Error>) {
        let entry = lock.withLock { implementations.removeValue(forKey: prID) }
        entry?.continuation.resume(with: result)
    }

    func sendAnalysisActivity(_ activity: JobActivity, to prID: String) {
        let sink = lock.withLock { analysisSteps[prID] }
        sink?(activity)
    }

    func sendImplementActivity(_ activity: JobActivity, to prID: String) {
        let sink = lock.withLock { implementSteps[prID] }
        sink?(activity)
    }

    func finishCancel(_ prID: String) {
        let continuation = lock.withLock { cancelled.removeValue(forKey: prID) }
        continuation?.resume()
    }
}

// MARK: - Harness

private extension RespondPhase {
    var name: String {
        switch self {
        case .queued: "queued"
        case .preparing: "preparing"
        case .analyzing: "analyzing"
        case .ready: "ready"
        case .implementing: "implementing"
        case .readyToPush: "readyToPush"
        case .pushing: "pushing"
        case .done: "done"
        case .failed: "failed"
        }
    }
}

private func reached(_ number: Int, _ name: String) -> Set<QueueEvent> { [.finished("\(prID(number))|\(name)")] }

@MainActor
private final class Harness {
    let events = QueueEventLog()
    let pipeline: FakeRespondPipeline
    let history: RespondHistory
    let historyDir: URL
    var emitted: [(String, RespondPhase)] = []
    /// The drafts `RespondQueue` handed to `onRetain` (only with `retains: true`).
    var retained: [UUID] = []
    private(set) var queue: RespondQueue!

    /// Settings › Keep folders for Terminal.
    var keepsFolders = true

    init(maxConcurrent: Int = 2, retains: Bool = false) throws {
        pipeline = FakeRespondPipeline(events: events)
        historyDir = try temporaryDirectory()
        history = RespondHistory(historyDir: historyDir)
        queue = RespondQueue(pipeline: pipeline, history: history, maxConcurrent: maxConcurrent, onEvent: { [unowned self] prID, phase in
            self.emitted.append((prID, phase))
            self.events.record(.finished("\(prID)|\(phase.name)"))
        }, onRetain: retains ? { @MainActor [unowned self] (record: RespondRecord) -> Void in self.retained.append(record.id) } : nil,
           keepsFolders: { [unowned self] in self.keepsFolders })
    }

    func settle() async { try? await Task.sleep(nanoseconds: 20_000_000) }

    var emittedNames: [String] { emitted.map(\.1.name) }

    func draft(_ number: Int) throws -> RespondDraft {
        guard case .ready(let draft)? = queue.phases[prID(number)] else {
            throw TestFailure(description: "esperaba .ready, hay \(String(describing: queue.phases[prID(number)]))")
        }
        return draft
    }

    func saved(_ number: Int) throws -> RespondRecord {
        guard let id = queue.records[prID(number)]?.id, let record = history.record(id: id) else {
            throw TestFailure(description: "no hay registro guardado de #\(number)")
        }
        return record
    }

    /// analyze → ready.
    func toReady(_ number: Int) async throws {
        queue.analyze(classified(number), localPath: "/repos/r", worktreeDir: nil)
        try await events.wait(for: [.started("analyze:\(prID(number))")])
        pipeline.completeAnalysis(number)
        try await events.wait(for: reached(number, "ready"))
    }

    /// analyze(mode:) → implementación sola (Fix CI, Resolve Conflicts) → readyToPush → publish → done.
    func finishPushedRun(_ number: Int, mode: RespondMode, headOid: String = String(repeating: "d", count: 40)) async throws {
        queue.analyze(classified(number), localPath: "/repos/r", worktreeDir: nil, mode: mode)
        try await events.wait(for: [.started("analyze:\(prID(number))")])
        pipeline.completeAnalysis(number, mode: mode)
        try await events.wait(for: [.started("implement:\(prID(number))")])
        let result = RespondResult(items: [ItemResult(id: "thread:A", status: .committed, commit: headOid, summary: "ok")],
                                   diffStat: " README.md | 1 +", tests: nil, headOid: headOid)
        pipeline.completeImplementation(prID(number), .success(result))
        try await events.wait(for: reached(number, "readyToPush"))
        queue.publish(prID: prID(number))
        try await events.wait(for: reached(number, "done"))
    }

    /// ready → implementing → readyToPush.
    func toReadyToPush(_ number: Int, result: RespondResult = fixResult) async throws {
        try await toReady(number)
        queue.implement(prID: prID(number), selections: bothSelected)
        try await events.wait(for: [.started("implement:\(prID(number))")])
        pipeline.completeImplementation(prID(number), .success(result))
        try await events.wait(for: reached(number, "readyToPush"))
    }
}

// MARK: - Tests

enum RespondQueueTests {
    static let cases: [TestCase] = [
        TestCase("respond queue: una corrida terminada con feedback posterior vuelve a idle; antes o sin feedback, no") { @MainActor in
            let h = try Harness()
            try await h.toReadyToPush(1)
            try expectEqual(h.queue.finishedRunsWithNewFeedback(latestFeedback: [prID(1): .distantFuture]), [])   // sin pushear
            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
            guard case .done(let record)? = h.queue.phases[prID(1)], let finished = record.finishedAt else {
                throw TestFailure(description: "esperaba .done con finishedAt")
            }
            try expectEqual(h.queue.finishedRunsWithNewFeedback(latestFeedback: [:]), [])
            try expectEqual(h.queue.finishedRunsWithNewFeedback(latestFeedback: [prID(1): finished.addingTimeInterval(-60)]), [])
            try expectEqual(h.queue.finishedRunsWithNewFeedback(latestFeedback: [prID(1): finished.addingTimeInterval(60)]), [prID(1)])
        },
        TestCase("respond queue: un Resolve Conflicts terminado se descarta al volver a tener conflictos") { @MainActor in
            let h = try Harness()
            try await h.finishPushedRun(1, mode: .conflicts)
            let pushed = try expectNotNil(h.queue.records[prID(1)]?.result?.headOid)
            try expectEqual(h.queue.conflictRunsToDrop(conflicting: [prID(1)], heads: [prID(1): pushed]), [])   // dato viejo de GitHub
            try expectEqual(h.queue.conflictRunsToDrop(conflicting: [], heads: [prID(1): pushed]), [])          // se vio sin conflictos
            try expectEqual(h.queue.conflictRunsToDrop(conflicting: [prID(1)], heads: [prID(1): pushed]), [prID(1)])
            // Otro head con conflictos también.
            try await h.finishPushedRun(2, mode: .conflicts)
            try expectEqual(h.queue.conflictRunsToDrop(conflicting: [prID(2)], heads: [prID(2): String(repeating: "e", count: 40)]), [prID(2)])
            // Un Fix CI terminado no aparece; descartar olvida que se vio sin conflictos.
            try await h.finishPushedRun(3, mode: .ciFix)
            try expectEqual(h.queue.conflictRunsToDrop(conflicting: [prID(3)], heads: [prID(3): "x"]), [])
            h.queue.dismiss(prID: prID(1))
            try expectEqual(h.queue.conflictRunsToDrop(conflicting: [prID(1)], heads: [:]), [])
        },
        TestCase("respond queue: transiciones felices y registro guardado en cada una") { @MainActor in
            let h = try Harness()
            h.queue.analyze(classified(1), localPath: "/repos/r", worktreeDir: nil)
            // Con lugar libre, el scheduler lo arranca en el acto.
            try expectEqual(h.queue.phases[prID(1)]?.name, "preparing")
            try await h.events.wait(for: [.started("analyze:\(prID(1))")])
            try expectEqual(h.queue.phases[prID(1)], .preparing)
            h.pipeline.sendAnalysis(.analyzing(agents: 2), to: prID(1))
            try expectEqual(h.queue.phases[prID(1)], .analyzing(agents: 2))
            h.pipeline.completeAnalysis(1)
            try await h.events.wait(for: reached(1, "ready"))
            let draft = try h.draft(1)
            try expectEqual(try h.saved(1).draft, draft)
            try expectEqual(try h.saved(1).result, nil)

            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            try expectEqual(h.queue.phases[prID(1)], .implementing(done: 0, total: 1))
            try expectEqual(try h.saved(1).selections, bothSelected)
            h.pipeline.sendProgress(1, 1, to: prID(1))
            try expectEqual(h.queue.phases[prID(1)], .implementing(done: 1, total: 1))
            h.pipeline.completeImplementation(prID(1), .success(fixResult))
            try await h.events.wait(for: reached(1, "readyToPush"))
            try expectEqual(h.queue.phases[prID(1)], .readyToPush(draft, fixResult))
            try expectEqual(try h.saved(1).result, fixResult)
            // "Ready to push": salir o actualizar avisa (H1).
            try expectEqual(h.queue.unpushedWork, [prID(1)])

            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
            try expectEqual(h.queue.unpushedWork, [])
            guard case .done(let record)? = h.queue.phases[prID(1)] else { throw TestFailure(description: "esperaba .done") }
            try expect(record.pushed)
            try expectEqual(Set(record.posted.keys), ["thread:A", "thread:B"])
            try expect(record.finishedAt != nil)
            try expectEqual(try h.saved(1).withoutDates, record.withoutDates)
            try expectEqual(h.pipeline.pushes, ["feature/1"])
            try expectEqual(h.pipeline.api.posts, [postA, postB])
            try expectEqual(h.emittedNames, ["ready", "readyToPush", "done"])
            // Al terminar se borra el worktree de PRBar y su ref.
            try await waitUntil { h.pipeline.cleanups == [draft.id] }
            h.queue.dismiss(prID: prID(1))
            try expectEqual(h.queue.phases[prID(1)], nil)
            try expectEqual(h.history.all().count, 1)
        },
        TestCase("respond queue: guarda cuándo empezó la corrida y si la pidió un iPhone") { @MainActor in
            try expect(CommandOrigin.phone(device: "d", mayRunRepoCode: true).isPhone && !CommandOrigin.mac.isPhone)
            let h = try Harness()
            let phone = CommandOrigin.phone(device: "d1", mayRunRepoCode: false)
            let before = Date()
            CommandOrigin.$current.withValue(phone) {
                h.queue.analyze(classified(7), localPath: "/repos/r", worktreeDir: nil)
            }
            let run = try expectSome(h.queue.runs[prID(7)])
            try expect(run.requestedOnPhone)
            try expect(run.startedAt >= before && run.startedAt <= Date())
            try await h.events.wait(for: [.started("analyze:\(prID(7))")])
            h.pipeline.completeAnalysis(7)
            try await h.events.wait(for: reached(7, "ready"))
            try expectEqual(h.queue.records[prID(7)]?.requestedOnPhone, true)
            try expectEqual(try h.saved(7).requestedOnPhone, true)
            // Desde la Mac: false en la corrida y nil en el registro.
            h.queue.analyze(classified(8), localPath: "/repos/r", worktreeDir: nil)
            try expectEqual(h.queue.runs[prID(8)]?.requestedOnPhone, false)
            try await h.events.wait(for: [.started("analyze:\(prID(8))")])
            h.pipeline.completeAnalysis(8)
            try await h.events.wait(for: reached(8, "ready"))
            try expectEqual(h.queue.records[prID(8)]?.requestedOnPhone, nil)
            h.queue.dismiss(prID: prID(7))
            try expectEqual(h.queue.runs[prID(7)], nil)
        },
        TestCase("respond queue: dismiss limpia el worktree; un fallo lo deja para revisarlo") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            let draft = try h.draft(1)
            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            h.pipeline.completeImplementation(prID(1), .failure(Boom()))
            try await h.events.wait(for: reached(1, "failed"))
            await h.settle()
            try expectEqual(h.pipeline.cleanups, [])
            h.queue.dismiss(prID: prID(1))
            try await waitUntil { h.pipeline.cleanups == [draft.id] }
            // Con un job corriendo, dismiss no hace nada (ni limpia).
            try await h.toReady(2)
            h.queue.implement(prID: prID(2), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(2))")])
            h.queue.dismiss(prID: prID(2))
            await h.settle()
            try expectEqual(h.pipeline.cleanups, [draft.id])
        },
        TestCase("respond queue: runTests solo en readyToPush y guarda el TestRun en el resultado y el registro") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            h.queue.runTests(prID: prID(1), testCommand: "make test")
            await h.settle()
            try expectEqual(h.pipeline.tests, [])
            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            h.pipeline.completeImplementation(prID(1), .success(fixResult))
            try await h.events.wait(for: reached(1, "readyToPush"))
            h.queue.runTests(prID: prID(1), testCommand: "   ")
            try expect(h.queue.runningTests.isEmpty)
            h.queue.runTests(prID: prID(1), testCommand: "make test")
            try expect(h.queue.runningTests.contains(prID(1)))
            while !h.queue.runningTests.isEmpty { await h.settle() }
            let run = TestRun(command: "make test", passed: false, outputTail: "1 failure")
            guard case .readyToPush(_, let result)? = h.queue.phases[prID(1)] else { throw TestFailure(description: "esperaba readyToPush") }
            try expectEqual(result.tests, run)
            try expectEqual(try h.saved(1).result?.tests, run)
            try expectEqual(h.pipeline.tests, ["make test"])
            try expectEqual(h.emittedNames, ["ready", "readyToPush", "readyToPush"])
        },
        TestCase("respond queue: un error del análisis deja failed y un registro con el error") { @MainActor in
            let h = try Harness()
            h.queue.analyze(classified(1), localPath: "/repos/r", worktreeDir: nil)
            try await h.events.wait(for: [.started("analyze:\(prID(1))")])
            h.pipeline.completeAnalysis(1, .failure(PRBarError.respond(RespondPipeline.noItemsMessage)))
            try await h.events.wait(for: reached(1, "failed"))
            try expectEqual(h.queue.phases[prID(1)], .failed("There are no unresolved comments", logURL: nil))
            try expectEqual(h.queue.records[prID(1)], nil)
            try expectEqual(h.history.all().map(\.errorMessage), ["There are no unresolved comments"])
        },
        TestCase("respond queue: push rechazado no publica respuestas y se puede reintentar") { @MainActor in
            let h = try Harness()
            try await h.toReadyToPush(1)
            h.pipeline.pushError = PRBarError.respond(RespondPublisher.rejectedMessage)
            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "failed"))
            try expectEqual(h.queue.phases[prID(1)], .failed(RespondPublisher.rejectedMessage, logURL: nil))
            try expectEqual(h.pipeline.api.posts, [])
            let saved = try h.saved(1)
            try expect(!saved.pushed)
            try expectEqual(saved.posted, [:])
            try expectEqual(saved.errorMessage, RespondPublisher.rejectedMessage)
            try expectEqual(h.queue.unpushedWork, [prID(1)])

            h.pipeline.pushError = nil
            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
            try expectEqual(h.pipeline.pushes.count, 2)
            try expectEqual(h.pipeline.api.posts, [postA, postB])
        },
        TestCase("respond queue: error parcial en las respuestas; el reintento no repushea y publica solo lo que faltaba") { @MainActor in
            let h = try Harness()
            try await h.toReadyToPush(1)
            let api = h.pipeline.api
            api.failPosts = [2]
            // Antes de cada post, lo que ya está guardado en disco: cada respuesta se persiste en el acto.
            let history = h.history
            let id = try h.draft1ID()
            let onDisk = Box<[Set<String>]>([])
            api.beforePost = { _ in onDisk.value.append(Set(history.record(id: id).map { Array($0.posted.keys) } ?? [])) }
            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "failed"))
            try expectEqual(onDisk.value, [[], ["thread:A"]])
            try expectEqual(api.posts, [postA])
            let saved = try h.saved(1)
            try expect(saved.pushed)
            try expectEqual(Set(saved.posted.keys), ["thread:A"])
            try expect(saved.errorMessage?.contains("502") == true, "\(String(describing: saved.errorMessage))")

            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
            try expectEqual(h.pipeline.pushes.count, 1)
            try expectEqual(api.posts, [postA, postB])
            try expectEqual(Set(try h.saved(1).posted.keys), ["thread:A", "thread:B"])
            try expectEqual(try h.saved(1).errorMessage, nil)
        },
        TestCase("respond queue: publishRepliesOnly va de ready a done sin push ni commits") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            h.queue.publish(prID: prID(1))   // sin fixes no hay publish
            await h.settle()
            try expectEqual(h.queue.phases[prID(1)]?.name, "ready")
            h.queue.publishRepliesOnly(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: reached(1, "done"))
            try expectEqual(h.pipeline.pushes, [])
            try expectEqual(h.pipeline.api.posts, [postB])
            guard case .done(let record)? = h.queue.phases[prID(1)] else { throw TestFailure(description: "esperaba .done") }
            try expect(!record.pushed)
            try expectEqual(record.selections, bothSelected)
            try expectEqual(try h.saved(1).withoutDates, record.withoutDates)
        },
        TestCase("respond queue: cancelar durante implementing espera la restauración y reporta los commits sin pushear") { @MainActor in
            let h = try Harness(maxConcurrent: 1)
            try await h.toReady(1)
            h.pipeline.slowCancel = true
            h.pipeline.commitsLeftOnCancel = 2
            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            h.queue.cancel(prID: prID(1))
            try await h.events.wait(for: [.cancelled(prID(1))])
            // Mientras restaura: sigue en implementing y el PR no acepta otro job (el lugar de la cola sí se libera).
            try expectEqual(h.queue.phases[prID(1)]?.name, "implementing")
            h.queue.analyze(classified(1), localPath: "/repos/r", worktreeDir: nil)
            h.queue.dismiss(prID: prID(1))
            try expectEqual(h.queue.phases[prID(1)]?.name, "implementing")
            h.queue.analyze(classified(2), localPath: "/repos/r", worktreeDir: nil)
            try await h.events.wait(for: [.started("analyze:\(prID(2))")])

            h.pipeline.finishCancel(prID(1))
            try await h.events.wait(for: reached(1, "failed"))
            let message = "Canceled: 2 unpushed commits were left in /wt/1."
            try expectEqual(h.queue.phases[prID(1)], .failed(message, logURL: nil))
            try expectEqual(try h.saved(1).errorMessage, message)
            try expectEqual(h.pipeline.pushes, [])
            try expectEqual(h.pipeline.api.posts, [])
            // Los commits que quedaron cuentan como trabajo sin pushear hasta descartarlo.
            try expectEqual(h.queue.unpushedWork, [prID(1)])
            h.queue.dismiss(prID: prID(1))
            try expectEqual(h.queue.unpushedWork, [])
        },
        TestCase("respond queue: analizar de nuevo borra el worktree anterior; con trabajo sin pushear no arranca (M5)") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            let first = try h.draft(1)
            // Desde ready: el worktree viejo se borra y arranca otro análisis.
            try expect(h.queue.analyze(classified(1), localPath: "/repos/r", worktreeDir: nil))
            try await waitUntil { h.pipeline.cleanups == [first.id] }
            try await h.events.wait(for: [.started("analyze:\(prID(1))")])
            h.pipeline.completeAnalysis(1)
            try await waitUntil { h.queue.phases[prID(1)]?.name == "ready" }
            let second = try h.draft(1)
            // Una implementación que falló puede haber dejado commits: no se reemplaza sin descartarla.
            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            h.pipeline.completeImplementation(prID(1), .failure(Boom()))
            try await waitUntil { h.queue.phases[prID(1)]?.name == "failed" }
            try expectEqual(h.queue.unpushedWork, [prID(1)])
            try expect(!h.queue.analyze(classified(1), localPath: "/repos/r", worktreeDir: nil))
            await h.settle()
            try expectEqual(h.pipeline.cleanups, [first.id])
            h.queue.dismiss(prID: prID(1))
            try await waitUntil { h.pipeline.cleanups == [first.id, second.id] }
            try expect(h.queue.analyze(classified(1), localPath: "/repos/r", worktreeDir: nil))
        },
        TestCase("respond queue: Cancel justo después de que la implementación terminó no la deja trabada en implementing") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            let queue = h.queue!
            // El Cancel llega en el main actor después de `implementEnded` (que no encontró nada que cancelar) y antes de
            // que el scheduler cierre el job: dos saltos al main actor encolados antes del de `implementEnded`.
            h.pipeline.beforeImplementReturns = {
                Task { @MainActor in Task { @MainActor in queue.cancel(prID: prID(1)) } }
            }
            queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            h.pipeline.completeImplementation(prID(1), .success(fixResult))
            try await waitUntil { h.queue.phases[prID(1)]?.name == "readyToPush" }
            // Ganó la implementación terminada: sus commits se muestran y cuentan como trabajo sin pushear.
            try expectEqual(h.queue.records[prID(1)]?.result, fixResult)
            try expectEqual(h.queue.unpushedWork, [prID(1)])
            try expect(h.queue.canChat(prID: prID(1)))
            h.queue.dismiss(prID: prID(1))
            try expectEqual(h.queue.phases[prID(1)], nil)
        },
        TestCase("respond queue: cancelar implementing sin commits vuelve a ready") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            let draft = try h.draft(1)
            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            h.queue.cancel(prID: prID(1))
            while h.emitted.count < 2 { await h.settle() }
            try expectEqual(h.queue.phases[prID(1)], .ready(draft))
            try expectEqual(h.emittedNames, ["ready", "ready"])
        },
        TestCase("respond queue: un error de la implementación deja failed y lo guarda") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            h.pipeline.completeImplementation(prID(1), .failure(Boom()))
            try await h.events.wait(for: reached(1, "failed"))
            try expectEqual(h.queue.phases[prID(1)], .failed("explotó", logURL: nil))
            try expectEqual(try h.saved(1).errorMessage, "explotó")
            h.queue.publish(prID: prID(1))   // sin resultado no hay push
            await h.settle()
            try expectEqual(h.pipeline.pushes, [])
        },
        TestCase("respond queue: con 3 análisis y máximo 2 corren 2; al terminar uno arranca el tercero") { @MainActor in
            let h = try Harness()
            for n in 1...3 { h.queue.analyze(classified(n), localPath: "/repos/r", worktreeDir: nil) }
            try await h.events.wait(for: [.started("analyze:\(prID(1))"), .started("analyze:\(prID(2))")])
            try expectEqual(h.queue.phases[prID(3)], .queued)
            await h.settle()
            try expectEqual(h.events.count(.started("analyze:\(prID(3))")), 0)
            h.pipeline.completeAnalysis(1)
            try await h.events.wait(for: [.started("analyze:\(prID(3))")])
            try expectEqual(h.queue.phases[prID(3)], .preparing)
        },
        TestCase("respond queue: cancelar un análisis en cola o corriendo vuelve a idle") { @MainActor in
            let h = try Harness(maxConcurrent: 1)
            h.queue.analyze(classified(1), localPath: "/repos/r", worktreeDir: nil)
            h.queue.analyze(classified(2), localPath: "/repos/r", worktreeDir: nil)
            try await h.events.wait(for: [.started("analyze:\(prID(1))")])
            h.queue.cancel(prID: prID(2))
            try expectEqual(h.queue.phases[prID(2)], nil)
            h.queue.cancel(prID: prID(1))
            try expectEqual(h.queue.phases[prID(1)], nil)
            h.queue.analyze(classified(1), localPath: "/repos/r", worktreeDir: nil)
            try await h.events.wait(for: [.started("analyze:\(prID(1))")])
            try expectEqual(h.emitted.count, 0)
        },
        TestCase("respond queue: un análisis remoto cancelado sin confirmar que Claude paró lo dice (sin carpeta local)") { @MainActor in
            let h = try Harness(maxConcurrent: 1)
            h.pipeline.analyzeCancelError = RemoteRunnerError.jobNotStopped(host: "devbox")
            h.queue.analyze(classified(1), localPath: nil, worktreeDir: nil)
            try await h.events.wait(for: [.started("analyze:\(prID(1))")])
            h.queue.cancel(prID: prID(1))
            try expectEqual(h.queue.phases[prID(1)], nil)
            try await waitUntil { h.queue.phases[prID(1)] != nil }
            guard case .failed(let message, _)? = h.queue.phases[prID(1)] else {
                throw TestFailure(description: "\(String(describing: h.queue.phases[prID(1)]))")
            }
            try expect(message.contains("Claude may still be running on devbox; PRBar won’t touch that worktree"), message)
            try expectEqual(h.emitted.count, 0)
        },
        TestCase("respond queue: con un turno de chat corriendo no arranca implementar ni publicar") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            h.queue.setChatRunning(true, prID: prID(1))
            try expect(h.queue.chatting.contains(prID(1)))
            h.queue.implement(prID: prID(1), selections: bothSelected)
            await h.settle()
            try expectEqual(h.queue.phases[prID(1)]?.name, "ready")
            h.queue.setChatRunning(false, prID: prID(1))
            try expect(h.queue.canChat(prID: prID(1)))
            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            try expect(!h.queue.canChat(prID: prID(1)))
        },
        TestCase("respond queue: replaceResult solo en readyToPush; guarda selecciones y chat en el registro") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            let draft = try h.draft(1)
            let edited = bothSelected.mapValues { var s = $0; s.replyText = "Editado"; return s }
            h.queue.updateSelections(prID: prID(1), draftID: draft.id, selections: edited)
            try expectEqual(try h.saved(1).selections, edited)
            h.queue.updateSelections(prID: prID(1), draftID: UUID(), selections: [:])
            try expectEqual(try h.saved(1).selections, edited)
            let other = RespondResult(items: [], diffStat: "x", tests: nil)
            h.queue.replaceResult(prID: prID(1), draftID: draft.id, result: other)
            try expectEqual(try h.saved(1).result, nil)

            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            h.pipeline.completeImplementation(prID(1), .success(fixResult))
            try await h.events.wait(for: reached(1, "readyToPush"))
            h.queue.replaceResult(prID: prID(1), draftID: draft.id, result: other)
            try expectEqual(h.queue.phases[prID(1)], .readyToPush(draft, other))
            try expectEqual(try h.saved(1).result, other)

            var chat = ChatSession(prID: prID(1), kind: .respond)
            chat.messages = [ChatMessage(role: .user, text: "hola", createdAt: t0)]
            h.queue.setChat(prID: prID(1), draftID: draft.id, chat: chat)
            try expectEqual(try h.saved(1).chat, chat)
            try expectEqual(h.queue.records[prID(1)]?.chat, chat)
        },
        TestCase("respond queue: guarda las sesiones de Claude de los fixes en el registro") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            let stamp = ClaudeSessionStamp(id: "6f1c2d3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f", startedAt: t0)
            let result = RespondResult(items: [ItemResult(id: "thread:A", status: .committed, commit: sha1, summary: "ok", session: stamp)],
                                       diffStat: " README.md | 1 +", tests: nil)
            h.pipeline.completeImplementation(prID(1), .success(result))
            try await h.events.wait(for: reached(1, "readyToPush"))
            let sessions = try h.saved(1).sessions ?? []
            try expectEqual(sessions.map(\.label), ["Fix 1: Cambiá esto."])
            try expectEqual(sessions.map(\.directory), ["/wt/1"])
            try expectEqual(sessions.map(\.kind), [.fix])
        },
        TestCase("respond queue: con onRetain, un push terminado conserva la carpeta en vez de borrarla") { @MainActor in
            let h = try Harness(retains: true)
            try await h.toReadyToPush(1, result: fixResultWithSession)
            let draft = try h.saved(1).draft
            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
            await h.settle()
            try expectEqual(h.retained, [draft.id])
            try expectEqual(h.pipeline.cleanups, [])
            // Se suelta: deja de contar como en uso (y en un runner, la copia de la Mac se va).
            try await waitUntil { h.pipeline.releases == [draft.id] }
        },
        TestCase("respond queue: descartar un push conservado no borra su carpeta") { @MainActor in
            let h = try Harness(retains: true)
            try await h.toReadyToPush(1, result: fixResultWithSession)
            let draft = try h.saved(1).draft
            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
            h.queue.dismiss(prID: prID(1))
            await h.settle()
            try expectEqual(h.retained, [draft.id])
            try expectEqual(h.pipeline.cleanups, [])
        },
        TestCase("respond queue: a pushed run without Claude sessions isn't kept: its folder is cleaned up as before") { @MainActor in
            let h = try Harness(retains: true)
            try await h.toReadyToPush(1)
            let draft = try h.saved(1).draft
            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
            try await waitUntil { h.pipeline.cleanups == [draft.id] }
            try expectEqual(h.retained, [])
            try expectEqual(h.pipeline.releases, [])
        },
        TestCase("respond queue: with Keep folders for Terminal off, a pushed run with sessions is cleaned up as before") { @MainActor in
            let h = try Harness(retains: true)
            h.keepsFolders = false
            try await h.toReadyToPush(1, result: fixResultWithSession)
            let draft = try h.saved(1).draft
            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
            try await waitUntil { h.pipeline.cleanups == [draft.id] }
            try expectEqual(h.retained, [])
            try expectEqual(h.pipeline.releases, [])
        },
        TestCase("respond queue: sin onRetain, descartar un push terminado sigue borrando") { @MainActor in
            let h = try Harness()
            try await h.toReadyToPush(1)
            let draft = try h.saved(1).draft
            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
            try await waitUntil { h.pipeline.cleanups == [draft.id] }
            try expectEqual(h.pipeline.releases, [])
        },
        TestCase("respond queue: activity sigue al análisis, sobrevive al cambio de fase y se borra en ready; cancelar (y cancelAll) la borra") { @MainActor in
            let h = try Harness()
            h.queue.analyze(classified(1), localPath: "/repos/r", worktreeDir: nil)
            try await h.events.wait(for: [.started("analyze:\(prID(1))")])
            h.pipeline.sendAnalysisActivity(.prbar(JobStep.creatingWorktree), to: prID(1))
            try await waitUntil { h.queue.activity[prID(1)]?.text == JobStep.creatingWorktree }
            h.pipeline.sendAnalysis(.analyzing(agents: 0), to: prID(1))
            try expectEqual(h.queue.activity[prID(1)]?.text, JobStep.creatingWorktree)
            h.pipeline.completeAnalysis(1)
            try await h.events.wait(for: reached(1, "ready"))
            try expectEqual(h.queue.activity[prID(1)], nil)

            h.queue.analyze(classified(2), localPath: "/repos/r", worktreeDir: nil)
            try await h.events.wait(for: [.started("analyze:\(prID(2))")])
            h.pipeline.sendAnalysisActivity(.claude("Reading a.swift"), to: prID(2))
            try await waitUntil { h.queue.activity[prID(2)] != nil }
            h.queue.cancel(prID: prID(2))
            try expectEqual(h.queue.activity[prID(2)], nil)
            h.pipeline.sendAnalysisActivity(.claude("Reading b.swift"), to: prID(2))   // the old run, late
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(h.queue.activity[prID(2)], nil)

            // cancelAll (quitting, an update): no step is left, and the late ones don't come back.
            h.queue.analyze(classified(3), localPath: "/repos/r", worktreeDir: nil)
            try await h.events.wait(for: [.started("analyze:\(prID(3))")])
            h.pipeline.sendAnalysisActivity(.claude("Reading a.swift"), to: prID(3))
            try await waitUntil { h.queue.activity[prID(3)] != nil }
            h.queue.cancelAll()
            try expectEqual(h.queue.activity, [:])
            h.pipeline.sendAnalysisActivity(.claude("Reading b.swift"), to: prID(3))
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(h.queue.activity, [:])
        },
        TestCase("respond queue: los fixes, los tests, el push y las respuestas dicen su paso; al terminar no queda ninguno") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            h.pipeline.sendImplementActivity(.prbar(JobStep.committing), to: prID(1))
            try await waitUntil { h.queue.activity[prID(1)]?.text == JobStep.committing }
            h.pipeline.completeImplementation(prID(1), .success(fixResult))
            try await h.events.wait(for: reached(1, "readyToPush"))
            try expectEqual(h.queue.activity[prID(1)], nil)

            var seen: [String] = []
            let observation = h.queue.activityFeed.$current.sink { current in
                if let text = current[prID(1)]?.text, seen.last != text { seen.append(text) }
            }
            defer { observation.cancel() }
            h.pipeline.testsPass = true
            try expect(h.queue.runTests(prID: prID(1), testCommand: "make test"))
            try await waitUntil { !h.queue.runningTests.contains(prID(1)) }
            let record = try expectSome(h.queue.records[prID(1)])
            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
            let replies = RespondCounts.pendingReplies(record) > 0 ? [JobStep.replying] : []
            try expectEqual(seen, [JobStep.runningTests, JobStep.pushing] + replies)
            try expectEqual(h.queue.activity[prID(1)], nil)
        },
    ] + RespondPipelineTests.cases
}

private extension RespondRecord {
    /// El JSON guarda las fechas sin fracciones de segundo: se comparan aparte.
    var withoutDates: RespondRecord {
        var copy = self
        copy.startedAt = t0
        copy.finishedAt = copy.finishedAt.map { _ in t0 }
        return copy
    }
}

private extension Harness {
    func draft1ID() throws -> UUID {
        guard let id = queue.records[prID(1)]?.id else { throw TestFailure(description: "sin registro") }
        return id
    }
}

// MARK: - RespondPipeline real (git temporal, Claude y GitHub falsos)

private let gitEnvironment = [
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "PRBar Tests", "GIT_AUTHOR_EMAIL": "tests@prbar.invalid",
    "GIT_COMMITTER_NAME": "PRBar Tests", "GIT_COMMITTER_EMAIL": "tests@prbar.invalid",
]

private func pluginCache(in root: URL) throws -> URL {
    let cache = root.appendingPathComponent("plugins", isDirectory: true)
    for name in ["pr-review-toolkit", "superpowers"] {
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("official/\(name)/1.0/.claude-plugin"),
                                                withIntermediateDirectories: true)
    }
    return cache
}

private func structured(_ object: [String: Any]) -> String {
    let line: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "result": "", "structured_output": object]
    return String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self)
}

private func analysisLine(_ ids: [String]) -> String {
    structured(["items": ids.map { ["id": $0, "assessment": "Tiene razón.", "action": "fixAndReply",
                                    "fixPlan": "Arreglalo", "reply": "Gracias"] }])
}

private func fixLine(_ message: String) -> String {
    structured(["status": "done", "summary": "Hecho.", "commitMessage": message])
}

/// "Claude" falso y cancelable: `handler` recibe (schema, prompt, cwd) y devuelve las líneas del stream. Graba los
/// argumentos y el entorno de cada llamada.
private final class ScriptedClaude: StreamingProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(arguments: [String], environment: [String: String]?)] = []
    var calls: [(arguments: [String], environment: [String: String]?)] { lock.withLock { recorded } }
    private let handler: @Sendable (String, String, URL) async throws -> [String]

    init(_ handler: @escaping @Sendable (String, String, URL) async throws -> [String]) {
        self.handler = handler
    }

    func runStreaming(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
                      timeout: TimeInterval?, onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        lock.withLock { recorded.append((arguments, environment)) }
        func value(_ flag: String) -> String { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } ?? "" }
        let lines = try await handler(value("--json-schema"), value("-p"), currentDirectory ?? URL(fileURLWithPath: "/"))
        lines.forEach(onStdoutLine)
        return ok(lines.joined(separator: "\n"))
    }
}

/// Un `WorkspaceFS` de mentira: sin `.git` anidados; anota dónde se los buscó.
private final class StubWorkspaceFS: WorkspaceFS, @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String] = []
    var nestedRoots: [String] { lock.withLock { roots } }
    var home: String { "/home/u" }
    func snapshot(_ root: String) async throws -> WorktreeIntegrity.Snapshot { WorktreeIntegrity.Snapshot(entries: [:]) }
    func nestedGits(_ root: String) async throws -> [WorktreeIntegrity.NestedGit] {
        lock.withLock { roots.append(root) }
        return []
    }
    func describe(_ paths: [String]) async throws -> [String: String] { [:] }
    func describeTrees(_ roots: [String]) async throws -> [String: String] { [:] }
    func modules(_ root: String) async throws -> (entries: [String: String], configs: [String]) { ([:], []) }
    func readText(_ path: String, limit: Int) async throws -> String? { nil }
    func removeCreatedFile(_ relative: String, in root: String) async throws {}
    func neutralizeSymlinks(_ relatives: [String], in root: String) async throws {}
    func temporaryFilePath(_ prefix: String) throws -> String { "/home/u/.prbar/tmp/\(prefix)-x" }
    func removeTemporaryFile(_ path: String) async {}
}

private struct E2E {
    let repo: TempGitRepo
    let api: FakeFeedbackAPI
    let pipeline: RespondPipeline
    let history: RespondHistory
    let worktreeRoot: URL
    let worktreeDir: URL

    static func make(claude: ScriptedClaude, baseSetup: (URL) throws -> Void = { _ in },
                     prSetup: (URL) throws -> Void = { _ in }) throws -> E2E {
        let repo = try TempGitRepo.make(baseSetup: baseSetup, prSetup: prSetup)
        let api = FakeFeedbackAPI(feedback: PRFeedback(
            headRefName: "feature", headRefOid: repo.prSHA, isCrossRepository: false, lastCommitAt: at(-10),
            threads: [threadItem("thread:A", databaseID: 101, body: "MARK-A: agregá chau"),
                      threadItem("thread:B", databaseID: 102, body: "MARK-B: agregá otro")],
            reviews: []))
        let history = RespondHistory(historyDir: repo.base.appendingPathComponent("history"))
        let worktreeRoot = repo.base.appendingPathComponent("prbar-worktrees", isDirectory: true)
        let pipeline = RespondPipeline(
            processRunner: SystemProcessRunner(), streamingRunner: claude, tokens: FakeTokens(), api: api,
            gitPath: TempGitRepo.git, claudePath: "/usr/local/bin/claude", worktreeRoot: worktreeRoot,
            pluginCacheDirectory: try pluginCache(in: repo.base), gitEnvironment: gitEnvironment,
            logURLProvider: { history.logURL(for: $0) }, originMatches: { _, _ in true })
        return E2E(repo: repo, api: api, pipeline: pipeline, history: history, worktreeRoot: worktreeRoot,
                   worktreeDir: repo.base.appendingPathComponent("wts", isDirectory: true))
    }

    var request: RespondRequest {
        RespondRequest(item: classified(7), localPath: repo.local.path, worktreeDir: worktreeDir.path)
    }

    func git(_ dir: String, _ args: [String]) throws -> String {
        try TempGitRepo.run(URL(fileURLWithPath: dir), args).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// PR #7 cambia `README.md` (y lo que haga `prSetup`); después `main` también lo cambia (y lo que haga `baseChange`):
/// un conflicto de contenido en `README.md`. `doc.md` tiene un título subrayado con `=======` en los dos lados.
private func conflictingE2E(claude: ScriptedClaude, baseSetup: @escaping (URL) throws -> Void = { _ in },
                            prSetup: @escaping (URL) throws -> Void = { _ in },
                            baseChange: @escaping (URL) throws -> Void = { _ in }) throws -> (E2E, String) {
    let e = try E2E.make(claude: claude, baseSetup: { dir in
        try Data("Title\n=======\n".utf8).write(to: dir.appendingPathComponent("doc.md"))
        try baseSetup(dir)
    }, prSetup: { dir in
        try Data("hola PR\n".utf8).write(to: dir.appendingPathComponent("README.md"))
        try prSetup(dir)
    })
    let base = try e.repo.advanceBase { dir in
        try Data("hola base\n".utf8).write(to: dir.appendingPathComponent("README.md"))
        try baseChange(dir)
    }
    e.api.feedback = PRFeedback(headRefName: "feature", headRefOid: e.repo.prSHA, isCrossRepository: false, lastCommitAt: at(-10),
                                threads: [], reviews: [])
    e.api.details = PRDetails(title: "t", body: "Adds a greeting", headOid: e.repo.prSHA, state: .open, baseRef: "main")
    return (e, base)
}

private func conflictsLine(_ status: String = "done", files: [[String: String]] = [["path": "README.md", "summary": "Joined both lines."]]) -> String {
    structured(["status": status, "summary": "Kept both greetings.", "files": files])
}

private func append(_ text: String, to name: String, in cwd: URL) throws {
    let url = cwd.appendingPathComponent(name)
    let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    try Data((current + text).utf8).write(to: url)
}

enum RespondPipelineTests {
    static let cases: [TestCase] = [
        TestCase("resolve conflicts: prepara el merge sin Claude; lista los archivos de contenido y deja MERGE_HEAD en la base") {
            let claude = ScriptedClaude { _, _, _ in [] }
            let (e, base) = try conflictingE2E(claude: claude)
            defer { e.repo.remove() }
            // El repo del usuario pide diff3 y rerere: el merge de PRBar los ignora.
            try TempGitRepo.run(e.repo.local, ["config", "merge.conflictStyle", "diff3"])
            try TempGitRepo.run(e.repo.local, ["config", "rerere.enabled", "true"])
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            let draft = try await e.pipeline.analyze(request, draftID: UUID()) { _ in }
            try expectEqual(draft.mode, .conflicts)
            try expectEqual(draft.conflicts?.baseRef, "main")
            try expectEqual(draft.conflicts?.baseOid, base)
            try expectEqual(draft.conflicts?.contentFiles, ["README.md"])
            try expectEqual(draft.conflicts?.incomingCommits, 1)
            try expectEqual(draft.items.map(\.feedback.kind), [.mergeConflicts])
            try expect(draft.items[0].feedback.comments[1].body.contains("base change"))
            try expect(draft.items[0].feedback.comments[2].body.contains("+hola PR"))
            try expectEqual(try e.git(draft.worktree.path, ["rev-parse", "MERGE_HEAD"]), base)
            try expectEqual(try e.git(draft.worktree.path, ["rev-parse", "HEAD"]), e.repo.prSHA)
            // Estilo `merge` (sin `|||||||` de diff3) aunque el repo pida otro.
            let readme = try String(contentsOf: URL(fileURLWithPath: draft.worktree.path).appendingPathComponent("README.md"), encoding: .utf8)
            try expect(readme.contains("<<<<<<<") && !readme.contains("|||||||"), readme)
            try expect(!FileManager.default.fileExists(atPath: e.repo.local.appendingPathComponent(".git/rr-cache").path), "rerere corrió")
            try expectEqual(claude.calls.count, 0)
        },
        TestCase("resolve conflicts: los \"by hand\" quedan con la versión del PR (o sin el archivo) y fuera de conflicto") {
            let claude = ScriptedClaude { _, _, _ in [] }
            // kept.txt: el PR lo cambia y la base lo borra. gone.txt: el PR lo borra y la base lo cambia.
            let (e, _) = try conflictingE2E(claude: claude, baseSetup: { dir in
                try Data("v1\n".utf8).write(to: dir.appendingPathComponent("kept.txt"))
                try Data("v1\n".utf8).write(to: dir.appendingPathComponent("gone.txt"))
            }, prSetup: { dir in
                try Data("v2 PR\n".utf8).write(to: dir.appendingPathComponent("kept.txt"))
                try FileManager.default.removeItem(at: dir.appendingPathComponent("gone.txt"))
            }, baseChange: { dir in
                try FileManager.default.removeItem(at: dir.appendingPathComponent("kept.txt"))
                try Data("v3 base\n".utf8).write(to: dir.appendingPathComponent("gone.txt"))
            })
            defer { e.repo.remove() }
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            let draft = try await e.pipeline.analyze(request, draftID: UUID()) { _ in }
            try expectEqual(draft.conflicts?.contentFiles, ["README.md"])
            try expectEqual(draft.conflicts?.byHandFiles.map(\.path), ["gone.txt", "kept.txt"])
            try expectEqual(draft.conflicts?.byHandFiles.map(\.reason), ["deleted in the PR", "deleted in the base"])
            let unmerged = try e.git(draft.worktree.path, ["diff", "--name-only", "--diff-filter=U"])
            try expectEqual(unmerged, "README.md")
            let wt = URL(fileURLWithPath: draft.worktree.path)
            try expectEqual(try String(contentsOf: wt.appendingPathComponent("kept.txt"), encoding: .utf8), "v2 PR\n")
            try expect(!FileManager.default.fileExists(atPath: wt.appendingPathComponent("gone.txt").path), "gone.txt sigue")
            try expectEqual(try e.git(draft.worktree.path, ["ls-files", "--", "gone.txt"]), "")
        },
        TestCase("resolve conflicts: solo conflictos que no son de contenido → error, sin worktree ni refs") {
            let claude = ScriptedClaude { _, _, _ in [] }
            // El PR cambia old.txt y la base lo borra; README no choca (la base no lo toca en este caso).
            let e = try E2E.make(claude: claude, baseSetup: { try Data("v1\n".utf8).write(to: $0.appendingPathComponent("old.txt")) },
                                 prSetup: { try Data("v2\n".utf8).write(to: $0.appendingPathComponent("old.txt")) })
            defer { e.repo.remove() }
            try e.repo.advanceBase { try FileManager.default.removeItem(at: $0.appendingPathComponent("old.txt")) }
            e.api.details = PRDetails(title: "t", body: "", headOid: e.repo.prSHA, state: .open, baseRef: "main")
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            let error = try await expectThrows { _ = try await e.pipeline.analyze(request, draftID: UUID()) { _ in } }
            try expect("\(error.localizedDescription)".contains("old.txt"), error.localizedDescription)
            try expect("\(error.localizedDescription)".contains("by hand"), error.localizedDescription)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: e.worktreeDir.path)) ?? []
            try expect(left.isEmpty, "\(left)")
            try expectEqual(try e.repo.prbarRefs(), [])
        },
        TestCase("resolve conflicts: el head ya contiene la base, el PR se movió o es de un fork → error sin Claude") {
            let claude = ScriptedClaude { _, _, _ in [] }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            e.api.details = PRDetails(title: "t", body: "", headOid: e.repo.prSHA, state: .open, baseRef: "main")
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            let merged = try await expectThrows { _ = try await e.pipeline.analyze(request, draftID: UUID()) { _ in } }
            try expectEqual(merged as? PRBarError, .respond(RespondPipeline.alreadyContainsBaseMessage))
            e.api.feedback = PRFeedback(headRefName: "feature", headRefOid: String(repeating: "d", count: 40), isCrossRepository: false,
                                        lastCommitAt: at(0), threads: [], reviews: [])
            let moved = try await expectThrows { _ = try await e.pipeline.analyze(request, draftID: UUID()) { _ in } }
            try expect(moved.localizedDescription.contains("new commits"), moved.localizedDescription)
            e.api.feedback = PRFeedback(headRefName: "feature", headRefOid: e.repo.prSHA, isCrossRepository: true, lastCommitAt: at(0),
                                        threads: [], reviews: [])
            let fork = try await expectThrows { _ = try await e.pipeline.analyze(request, draftID: UUID()) { _ in } }
            try expectEqual(fork as? PRBarError, .respond(RespondPipeline.forkMessage))
            try expectEqual(claude.calls.count, 0)
            try expectEqual(try e.repo.prbarRefs(), [])
        },
        TestCase("resolve conflicts: Claude resuelve, merge de dos padres, diff = solo la resolución, un título ======= no cuenta") { @MainActor in
            let claude = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR y base\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                return [conflictsLine()]
            }
            let (e, base) = try conflictingE2E(claude: claude)
            defer { e.repo.remove() }
            let events = QueueEventLog()
            let queue = RespondQueue(pipeline: e.pipeline, history: e.history) { prID, phase in events.record(.finished("\(prID)|\(phase.name)")) }
            queue.analyze(classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            try expectEqual(queue.modes[prID(7)], .conflicts)
            try await events.wait(for: reached(7, "readyToPush"))
            guard case .readyToPush(let draft, let result)? = queue.phases[prID(7)] else { throw TestFailure(description: "sin readyToPush") }
            let head = try e.git(draft.worktree.path, ["rev-parse", "HEAD"])
            try expectEqual(try e.git(draft.worktree.path, ["rev-list", "--parents", "-n", "1", "HEAD"]), "\(head) \(e.repo.prSHA) \(base)")
            try expectEqual(try e.git(draft.worktree.path, ["log", "-1", "--format=%s"]), "Merge main into feature")
            try expectEqual(result.headOid, head)
            try expectEqual(result.commits?.map(\.sha), [head])
            try expect(result.diff?.contains("diff --cc README.md") == true, result.diff ?? "")
            try expect(result.diff?.contains("hola PR y base") == true, result.diff ?? "")
            try expect(result.diff?.contains("doc.md") == false, result.diff ?? "")
            try expectEqual(result.items.first?.conflictFiles, [ConflictFileSummary(path: "README.md", summary: "Joined both lines.")])
            try expectEqual(result.items.first?.status, .committed)
            try expectEqual(try e.git(draft.worktree.path, ["status", "--porcelain"]), "")
            let prompt = claude.calls[0].arguments[claude.calls[0].arguments.firstIndex(of: "-p")! + 1]
            try expect(prompt.contains("<<<PR_DESCRIPTION_") && prompt.contains("Adds a greeting"))
            try expect(prompt.contains("<<<BASE_COMMITS_") && prompt.contains("base change"))
        },
        TestCase("resolve conflicts: sin conflictos commitea el merge sin Claude y queda listo para pushear") { @MainActor in
            let claude = ScriptedClaude { _, _, _ in [] }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            let base = try e.repo.advanceBase { try Data("x\n".utf8).write(to: $0.appendingPathComponent("other.txt")) }
            e.api.details = PRDetails(title: "t", body: "", headOid: e.repo.prSHA, state: .open, baseRef: "main")
            let events = QueueEventLog()
            let queue = RespondQueue(pipeline: e.pipeline, history: e.history) { prID, phase in events.record(.finished("\(prID)|\(phase.name)")) }
            queue.analyze(classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            try await events.wait(for: reached(7, "readyToPush"))
            guard case .readyToPush(let draft, let result)? = queue.phases[prID(7)] else { throw TestFailure(description: "sin readyToPush") }
            try expectEqual(claude.calls.count, 0)
            try expectEqual(draft.conflicts?.files, [])
            try expectEqual(try e.git(draft.worktree.path, ["rev-parse", "HEAD^2"]), base)
            try expectEqual(result.diff, "")
            try expectEqual(result.commits?.count, 1)
        },
        TestCase("resolve conflicts: un marcador que deja Claude o un archivo a mano que toca frenan antes del commit") { @MainActor in
            // 1) Claude dice "done" pero no tocó README: quedan los marcadores.
            let lazy = ScriptedClaude { schema, _, _ in schema == RespondSchemas.conflicts ? [conflictsLine()] : [] }
            let (e1, _) = try conflictingE2E(claude: lazy)
            defer { e1.repo.remove() }
            let q1Events = QueueEventLog()
            let q1 = RespondQueue(pipeline: e1.pipeline, history: e1.history) { prID, phase in q1Events.record(.finished("\(prID)|\(phase.name)")) }
            q1.analyze(classified(7), localPath: e1.repo.local.path, worktreeDir: e1.worktreeDir.path, mode: .conflicts)
            try await q1Events.wait(for: reached(7, "failed"))
            if case .failed(let message, _)? = q1.phases[prID(7)] { try expect(message.contains("conflict markers in README.md"), message) }
            try expect(q1.unpushedWork.contains(prID(7)))
            // 2) Hay un archivo a mano (old.txt: el PR lo cambió, la base lo borró) y Claude lo edita.
            let meddling = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR y base\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                try Data("changed by Claude\n".utf8).write(to: cwd.appendingPathComponent("old.txt"))
                return [conflictsLine()]
            }
            let (e2, _) = try conflictingE2E(claude: meddling,
                                             baseSetup: { try Data("v1\n".utf8).write(to: $0.appendingPathComponent("old.txt")) },
                                             prSetup: { try Data("v2\n".utf8).write(to: $0.appendingPathComponent("old.txt")) },
                                             baseChange: { try FileManager.default.removeItem(at: $0.appendingPathComponent("old.txt")) })
            defer { e2.repo.remove() }
            let request = RespondRequest(item: classified(7), localPath: e2.repo.local.path, worktreeDir: e2.worktreeDir.path, mode: .conflicts)
            let draft = try await e2.pipeline.analyze(request, draftID: UUID()) { _ in }
            try expectEqual(draft.conflicts?.byHandFiles.map(\.path), ["old.txt"])
            try expectEqual(draft.conflicts?.byHandFiles.first?.reason, "deleted in the base")
            let error = try await expectThrows {
                _ = try await e2.pipeline.implement(draft: draft, selections: [draft.items[0].id: RespondSelection.defaults(for: draft.items[0])]) { _, _ in }
            }
            try expect(error.localizedDescription.contains("old.txt"), error.localizedDescription)
        },
        TestCase("resolve conflicts: los marcadores se buscan en archivos -diff (yarn.lock), con conflict-marker-size y sin color") { @MainActor in
            // La base y el PR cambian yarn.lock (`-diff`: git grep -I lo saltearía) y notes.md (marcadores de 32).
            let baseSetup: @Sendable (URL) throws -> Void = { dir in
                try Data("yarn.lock -diff\n*.md conflict-marker-size=32\n".utf8).write(to: dir.appendingPathComponent(".gitattributes"))
                try Data("v1\n".utf8).write(to: dir.appendingPathComponent("yarn.lock"))
                try Data("v1\n".utf8).write(to: dir.appendingPathComponent("notes.md"))
            }
            let prSetup: @Sendable (URL) throws -> Void = { dir in
                try Data("v2 PR\n".utf8).write(to: dir.appendingPathComponent("yarn.lock"))
                try Data("v2 PR\n".utf8).write(to: dir.appendingPathComponent("notes.md"))
            }
            let baseChange: @Sendable (URL) throws -> Void = { dir in
                try Data("v3 base\n".utf8).write(to: dir.appendingPathComponent("yarn.lock"))
                try Data("v3 base\n".utf8).write(to: dir.appendingPathComponent("notes.md"))
            }
            func run(_ claude: ScriptedClaude) async throws -> (E2E, RespondDraft, Result<RespondResult, Error>) {
                let (e, _) = try conflictingE2E(claude: claude, baseSetup: baseSetup, prSetup: prSetup, baseChange: baseChange)
                // La config del usuario pide color siempre: no puede ensuciar las rutas ni las cuentas de git grep.
                try TempGitRepo.run(e.repo.local, ["config", "color.ui", "always"])
                try TempGitRepo.run(e.repo.local, ["config", "color.grep", "always"])
                let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
                let draft = try await e.pipeline.analyze(request, draftID: UUID()) { _ in }
                do {
                    let result = try await e.pipeline.implement(draft: draft, selections: [draft.items[0].id: RespondSelection.defaults(for: draft.items[0])]) { _, _ in }
                    return (e, draft, .success(result))
                } catch {
                    return (e, draft, .failure(error))
                }
            }
            // 1) Claude solo resuelve README: quedan marcadores en yarn.lock y notes.md.
            let lazy = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR y base\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                return [conflictsLine()]
            }
            let (e1, draft1, outcome1) = try await run(lazy)
            defer { e1.repo.remove() }
            try expectEqual(draft1.conflicts?.contentFiles, ["README.md", "notes.md", "yarn.lock"])
            guard case .failure(let error) = outcome1 else { throw TestFailure(description: "commiteó con marcadores") }
            try expect(error.localizedDescription.contains("conflict markers in notes.md, yarn.lock"), error.localizedDescription)
            // 2) Claude resuelve todo: ni el título `=======` de doc.md ni el color cuentan como marcadores.
            let thorough = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                for name in ["README.md", "yarn.lock", "notes.md"] {
                    try Data("hola PR y base\n".utf8).write(to: cwd.appendingPathComponent(name))
                }
                return [conflictsLine()]
            }
            let (e2, _, outcome2) = try await run(thorough)
            defer { e2.repo.remove() }
            if case .failure(let error) = outcome2 { throw TestFailure(description: "falló: \(error.localizedDescription)") }
            // Resolve Conflicts le da a Claude solo leer y editar: sin Skill ni Agent.
            let tools = thorough.calls[0].arguments[thorough.calls[0].arguments.firstIndex(of: "--tools")! + 1]
            try expectEqual(tools, "Read,Grep,Glob,Edit,Write")
        },
        TestCase("resolve conflicts: binarios por atributos, directorio/archivo y archivos sueltos quedan a mano o frenan") { @MainActor in
            // data.bin (`binary`), lock.dat (`-merge`) y other.dat (`merge=binary`) chocan sin marcadores; `x` es un
            // archivo en el PR y una carpeta en la base.
            let baseSetup: @Sendable (URL) throws -> Void = { dir in
                try Data("data.bin binary\nlock.dat -merge\nother.dat merge=binary\n".utf8).write(to: dir.appendingPathComponent(".gitattributes"))
                for name in ["data.bin", "lock.dat", "other.dat"] { try Data("v1\n".utf8).write(to: dir.appendingPathComponent(name)) }
            }
            let prSetup: @Sendable (URL) throws -> Void = { dir in
                for name in ["data.bin", "lock.dat", "other.dat"] { try Data("v2 PR\n".utf8).write(to: dir.appendingPathComponent(name)) }
                try Data("pr\n".utf8).write(to: dir.appendingPathComponent("x"))
            }
            let baseChange: @Sendable (URL) throws -> Void = { dir in
                for name in ["data.bin", "lock.dat", "other.dat"] { try Data("v3 base\n".utf8).write(to: dir.appendingPathComponent(name)) }
                try FileManager.default.createDirectory(at: dir.appendingPathComponent("x"), withIntermediateDirectories: true)
                try Data("base\n".utf8).write(to: dir.appendingPathComponent("x/b.txt"))
            }
            let claude = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR y base\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                return [conflictsLine()]
            }
            let (e, _) = try conflictingE2E(claude: claude, baseSetup: baseSetup, prSetup: prSetup, baseChange: baseChange)
            defer { e.repo.remove() }
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            let draft = try await e.pipeline.analyze(request, draftID: UUID()) { _ in }
            try expectEqual(draft.conflicts?.contentFiles, ["README.md"])
            let byHand = draft.conflicts?.byHandFiles ?? []
            try expectEqual(byHand.filter { ["data.bin", "lock.dat", "other.dat"].contains($0.path) }.map(\.reason),
                            ["binary (attributes)", "binary (attributes)", "binary (attributes)"])
            try expect(byHand.contains { $0.path.hasPrefix("x~") && $0.reason == "directory/file conflict" }, "\(byHand)")
            // Un archivo que git no trackea y que ya estaba antes de Claude (lo que deja un merge) no entra en el commit.
            try Data("leftover\n".utf8).write(to: URL(fileURLWithPath: draft.worktree.path).appendingPathComponent("stray.txt"))
            let error = try await expectThrows {
                _ = try await e.pipeline.implement(draft: draft, selections: [draft.items[0].id: RespondSelection.defaults(for: draft.items[0])]) { _, _ in }
            }
            try expect(error.localizedDescription.contains("stray.txt"), error.localizedDescription)
            try expectEqual(try e.git(draft.worktree.path, ["rev-parse", "HEAD"]), e.repo.prSHA)
        },
        TestCase("resolve conflicts: el merge y el chat no firman aunque el repo pida firmar (los dos igual)") { @MainActor in
            let claude = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR y base\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                return [conflictsLine()]
            }
            let (e, _) = try conflictingE2E(claude: claude)
            defer { e.repo.remove() }
            // Firmar fallaría: `gpg.program` es `false`.
            try TempGitRepo.run(e.repo.local, ["config", "commit.gpgSign", "true"])
            try TempGitRepo.run(e.repo.local, ["config", "gpg.program", "false"])
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            let draft = try await e.pipeline.analyze(request, draftID: UUID()) { _ in }
            let result = try await e.pipeline.implement(draft: draft, selections: [draft.items[0].id: RespondSelection.defaults(for: draft.items[0])]) { _, _ in }
            try expectEqual(try e.git(draft.worktree.path, ["cat-file", "-p", "HEAD"]).contains("gpgsig"), false)
            let implementer = FixImplementer(
                claude: ClaudeRunner(runner: claude, claudePath: "/usr/local/bin/claude", pluginDirs: [], environment: [:],
                                     logURL: e.history.logURL(for: draft.id), redacting: []),
                runner: SystemProcessRunner(), gitPath: TempGitRepo.git, environment: gitEnvironment)
            _ = try await implementer.chatTurn(draft: draft, current: result, sessionID: UUID(), turn: 1) {
                try Data("hola PR, base y chat\n".utf8).write(to: URL(fileURLWithPath: draft.worktree.path).appendingPathComponent("README.md"))
            }
            try expectEqual(try e.git(draft.worktree.path, ["cat-file", "-p", "HEAD"]).contains("gpgsig"), false)
            try expectEqual(try e.git(draft.worktree.path, ["log", "-1", "--format=%s"]), "Merge main into feature")
        },
        TestCase("resolve conflicts: el chat rehace el merge (mismos padres), rechaza marcadores y Undo vuelve al anterior") { @MainActor in
            let claude = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR y base\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                return [conflictsLine()]
            }
            let (e, base) = try conflictingE2E(claude: claude)
            defer { e.repo.remove() }
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            let draft = try await e.pipeline.analyze(request, draftID: UUID()) { _ in }
            let result = try await e.pipeline.implement(draft: draft, selections: [draft.items[0].id: RespondSelection.defaults(for: draft.items[0])]) { _, _ in }
            let merge = try e.git(draft.worktree.path, ["rev-parse", "HEAD"])
            let implementer = FixImplementer(
                claude: ClaudeRunner(runner: claude, claudePath: "/usr/local/bin/claude", pluginDirs: [], environment: [:],
                                     logURL: e.history.logURL(for: draft.id), redacting: []),
                runner: SystemProcessRunner(), gitPath: TempGitRepo.git, environment: gitEnvironment)
            let readme = URL(fileURLWithPath: draft.worktree.path).appendingPathComponent("README.md")
            let (_, outcome) = try await implementer.chatTurn(draft: draft, current: result, sessionID: UUID(), turn: 1) {
                try Data("hola PR, base y chat\n".utf8).write(to: readme)
            }
            let rebuilt = try e.git(draft.worktree.path, ["rev-parse", "HEAD"])
            try expect(rebuilt != merge)
            try expectEqual(try e.git(draft.worktree.path, ["rev-list", "--parents", "-n", "1", "HEAD"]), "\(rebuilt) \(e.repo.prSHA) \(base)")
            try expectEqual(try e.git(draft.worktree.path, ["log", "-1", "--format=%s"]), "Merge main into feature")
            try expectEqual(outcome.result?.commits?.count, 1)
            try expect(outcome.result?.diff?.contains("hola PR, base y chat") == true)
            // Un turno que deja un marcador se rechaza y el árbol vuelve a como estaba.
            _ = try await expectThrows {
                _ = try await implementer.chatTurn(draft: draft, current: outcome.result!, sessionID: UUID(), turn: 2) {
                    try Data("<<<<<<< HEAD\na\n=======\nb\n>>>>>>> main\n".utf8).write(to: readme)
                }
            }
            try expectEqual(try e.git(draft.worktree.path, ["rev-parse", "HEAD"]), rebuilt)
            try expectEqual(try e.git(draft.worktree.path, ["status", "--porcelain"]), "")
            _ = try await implementer.undoChatTurn(draft: draft, snapshot: try expectNotNil(outcome.snapshot))
            try expectEqual(try e.git(draft.worktree.path, ["rev-parse", "HEAD"]), merge)
        },
        TestCase("resolve conflicts: lo que Claude cambia fuera de los conflictos (aunque vuelva a la versión del PR) se ve en el diff y en outsideConflicts") { @MainActor in
            // La base cambia shared.txt y el workflow sin chocar; el PR no los toca.
            let baseSetup: @Sendable (URL) throws -> Void = { dir in
                try Data("v1\n".utf8).write(to: dir.appendingPathComponent("shared.txt"))
                try FileManager.default.createDirectory(at: dir.appendingPathComponent(".github/workflows"), withIntermediateDirectories: true)
                try Data("on: push\n".utf8).write(to: dir.appendingPathComponent(".github/workflows/ci.yml"))
                try Data("bye\n".utf8).write(to: dir.appendingPathComponent("gone.txt"))
            }
            let baseChange: @Sendable (URL) throws -> Void = { dir in
                try Data("v2 base\n".utf8).write(to: dir.appendingPathComponent("shared.txt"))
                try Data("on: [push, pull_request]\n".utf8).write(to: dir.appendingPathComponent(".github/workflows/ci.yml"))
                try FileManager.default.removeItem(at: dir.appendingPathComponent("gone.txt"))
            }
            func run(_ claude: ScriptedClaude) async throws -> (E2E, RespondDraft, RespondResult) {
                let (e, _) = try conflictingE2E(claude: claude, baseSetup: baseSetup, baseChange: baseChange)
                let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
                let draft = try await e.pipeline.analyze(request, draftID: UUID()) { _ in }
                let result = try await e.pipeline.implement(draft: draft, selections: [draft.items[0].id: RespondSelection.defaults(for: draft.items[0])]) { _, _ in }
                return (e, draft, result)
            }
            // 1) Claude solo resuelve README: nada fuera de los conflictos.
            let clean = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR y base\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                return [conflictsLine()]
            }
            let (e1, draft1, result1) = try await run(clean)
            defer { e1.repo.remove() }
            try expectEqual(Set(draft1.conflicts?.automaticMerge?.map(\.path) ?? []), ["shared.txt", ".github/workflows/ci.yml", "gone.txt"])
            try expectEqual(result1.outsideConflicts, [])
            try expect(result1.diff?.contains("shared.txt") == false, result1.diff ?? "")
            try expectEqual(result1.sensitiveChanges, [])
            // Un turno del chat que devuelve shared.txt a la versión del PR: aparece.
            let implementer = FixImplementer(
                claude: ClaudeRunner(runner: clean, claudePath: "/usr/local/bin/claude", pluginDirs: [], environment: [:],
                                     logURL: e1.history.logURL(for: draft1.id), redacting: []),
                runner: SystemProcessRunner(), gitPath: TempGitRepo.git, environment: gitEnvironment)
            let (_, outcome) = try await implementer.chatTurn(draft: draft1, current: result1, sessionID: UUID(), turn: 1) {
                try Data("v1\n".utf8).write(to: URL(fileURLWithPath: draft1.worktree.path).appendingPathComponent("shared.txt"))
            }
            try expectEqual(outcome.result?.outsideConflicts, ["shared.txt"])
            try expect(outcome.result?.diff?.contains("diff --git a/shared.txt b/shared.txt\n") == true, outcome.result?.diff ?? "")
            // 2) Claude además revierte en silencio los cambios de la base en shared.txt y en el workflow, vuelve a
            // crear gone.txt (que la base borró) y agrega added.txt.
            let sneaky = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR y base\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                try Data("v1\n".utf8).write(to: cwd.appendingPathComponent("shared.txt"))
                try Data("on: push\n".utf8).write(to: cwd.appendingPathComponent(".github/workflows/ci.yml"))
                try Data("nuevo\n".utf8).write(to: cwd.appendingPathComponent("added.txt"))
                try Data("bye\n".utf8).write(to: cwd.appendingPathComponent("gone.txt"))
                return [conflictsLine()]
            }
            let (e2, draft2, result2) = try await run(sneaky)
            defer { e2.repo.remove() }
            // El combined diff solo no muestra los que quedaron iguales a un padre (added.txt sí: difiere de los dos).
            let combined = try e2.git(draft2.worktree.path, ["diff-tree", "--cc", "--no-commit-id", "-p", "HEAD"])
            try expect(!combined.contains("shared.txt") && !combined.contains("ci.yml") && !combined.contains("gone.txt"), combined)
            try expectEqual(result2.outsideConflicts, [".github/workflows/ci.yml", "added.txt", "gone.txt", "shared.txt"])
            let diff = result2.diff ?? ""
            try expect(diff.contains("diff --git a/shared.txt b/shared.txt\n"), diff)
            try expect(diff.contains("--- a/shared.txt\n+++ b/shared.txt\n"), diff)
            try expect(diff.contains("-v2 base\n+v1"), diff)
            try expect(diff.contains("-on: [push, pull_request]\n+on: push"), diff)
            try expect(diff.contains("diff --cc added.txt") && !diff.contains("diff --git a/added.txt"), diff)
            try expect(diff.contains("diff --git a/gone.txt b/gone.txt\nnew file mode 100644\nindex 0000000..b023018\n"), diff)
            try expect(diff.contains("--- /dev/null\n+++ b/gone.txt\n@@ -0,0 +1 @@\n+bye\n"), diff)
            try expect(result2.sensitiveChanges.contains(".github/workflows/ci.yml"), "\(result2.sensitiveChanges)")
            try expect(result2.diffStat.contains("added.txt"), result2.diffStat)
        },
        TestCase("resolve conflicts: un conflicto resuelto con un lado entero se ve (oneSidedResolutions), con su diff, stat, sensibles y dependencias") { @MainActor in
            // README (conflicto de conflictingE2E) queda como en el PR; package.json, como en la base.
            let baseSetup: @Sendable (URL) throws -> Void = { try Data(#"{"dependencies":{"a":"1"}}"#.utf8).write(to: $0.appendingPathComponent("package.json")) }
            let prSetup: @Sendable (URL) throws -> Void = { try Data(#"{"dependencies":{"a":"2"}}"#.utf8).write(to: $0.appendingPathComponent("package.json")) }
            let baseChange: @Sendable (URL) throws -> Void = { try Data(#"{"dependencies":{"a":"3"}}"#.utf8).write(to: $0.appendingPathComponent("package.json")) }
            let claude = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                try Data(#"{"dependencies":{"a":"3"}}"#.utf8).write(to: cwd.appendingPathComponent("package.json"))
                return [conflictsLine(files: [["path": "README.md", "summary": "Kept the PR's."], ["path": "package.json", "summary": "Took main's."]])]
            }
            let (e, _) = try conflictingE2E(claude: claude, baseSetup: baseSetup, prSetup: prSetup, baseChange: baseChange)
            defer { e.repo.remove() }
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            let draft = try await e.pipeline.analyze(request, draftID: UUID()) { _ in }
            try expectEqual(draft.conflicts?.contentFiles, ["README.md", "package.json"])
            let result = try await e.pipeline.implement(draft: draft, selections: [draft.items[0].id: RespondSelection.defaults(for: draft.items[0])]) { _, _ in }
            // El combined diff no los muestra: quedaron iguales a un padre.
            let combined = try e.git(draft.worktree.path, ["diff-tree", "--cc", "--no-commit-id", "-p", "HEAD"])
            try expectEqual(combined, "")
            try expectEqual(result.oneSidedResolutions, [OneSidedResolution(path: "README.md", kept: .pr),
                                                         OneSidedResolution(path: "package.json", kept: .base)])
            try expectEqual(result.outsideConflicts, [])
            let diff = result.diff ?? ""
            // README: lo que se descartó de la base; package.json: lo que se descartó del PR.
            try expect(diff.contains("diff --git a/README.md b/README.md\n"), diff)
            try expect(diff.contains("-hola base\n+hola PR"), diff)
            try expect(diff.contains("diff --git a/package.json b/package.json\n"), diff)
            try expect(diff.contains(#"-{"dependencies":{"a":"2"}}"#) && diff.contains(#"+{"dependencies":{"a":"3"}}"#), diff)
            try expect(result.diffStat.contains("README.md") && result.diffStat.contains("package.json"), result.diffStat)
            try expect(result.sensitiveChanges.contains("package.json"), "\(result.sensitiveChanges)")
            try expectEqual(result.dependencyChanges, ["package.json"])
            try expectEqual(OneSidedResolution(path: "README.md", kept: .pr).description(baseRef: "main"),
                            "README.md (kept the PR’s version, dropped main’s changes)")
            try expectEqual(OneSidedResolution(path: "package.json", kept: .base).description(baseRef: "main"),
                            "package.json (kept main’s version, dropped the PR’s changes)")
        },
        TestCase("resolve conflicts: pushea el merge con el PR re-verificado; con otro head o cerrado no pushea") { @MainActor in
            let claude = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR y base\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                return [conflictsLine()]
            }
            let (e, base) = try conflictingE2E(claude: claude)
            defer { e.repo.remove() }
            let events = QueueEventLog()
            let queue = RespondQueue(pipeline: e.pipeline, history: e.history) { prID, phase in events.record(.finished("\(prID)|\(phase.name)")) }
            queue.analyze(classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            try await events.wait(for: reached(7, "readyToPush"))
            guard case .readyToPush(_, let result)? = queue.phases[prID(7)] else { throw TestFailure(description: "sin readyToPush") }
            // Otro head en GitHub: no pushea.
            e.api.details = PRDetails(title: "t", body: "", headOid: String(repeating: "9", count: 40), state: .open, baseRef: "main")
            queue.publish(prID: prID(7))
            try await events.wait(for: reached(7, "failed"))
            if case .failed(let message, _)? = queue.phases[prID(7)] { try expect(message.contains("new commits"), message) }
            try expectEqual(try e.git(e.repo.origin.path, ["rev-parse", "refs/heads/feature"]), e.repo.prSHA)
            // Otra base: tampoco.
            e.api.details = PRDetails(title: "t", body: "", headOid: e.repo.prSHA, state: .open, baseRef: "develop")
            events.reset()
            queue.publish(prID: prID(7))
            try await events.wait(for: reached(7, "failed"))
            if case .failed(let message, _)? = queue.phases[prID(7)] { try expect(message.contains("base is now develop"), message) }
            // Cerrado: tampoco.
            e.api.details = PRDetails(title: "t", body: "", headOid: e.repo.prSHA, state: .closed, baseRef: "main")
            events.reset()
            queue.publish(prID: prID(7))
            try await events.wait(for: reached(7, "failed"))
            if case .failed(let message, _)? = queue.phases[prID(7)] { try expect(message.contains("isn’t open"), message) }
            try expectEqual(try e.git(e.repo.origin.path, ["rev-parse", "refs/heads/feature"]), e.repo.prSHA)
            // Con el head de siempre: pushea el merge, que contiene la base.
            e.api.details = PRDetails(title: "t", body: "", headOid: e.repo.prSHA, state: .open, baseRef: "main")
            queue.publish(prID: prID(7))
            try await events.wait(for: reached(7, "done"))
            let pushed = try e.git(e.repo.origin.path, ["rev-parse", "refs/heads/feature"])
            try expectEqual(pushed, result.headOid)
            try expectEqual(try e.git(e.repo.origin.path, ["rev-list", "--parents", "-n", "1", pushed]), "\(pushed) \(e.repo.prSHA) \(base)")
            try expect(e.api.posts.isEmpty)
        },
        TestCase("resolve conflicts: un push que llegó a GitHub sin quedar anotado se reintenta y termina (head = el merge)") { @MainActor in
            let claude = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR y base\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                return [conflictsLine()]
            }
            let (e, _) = try conflictingE2E(claude: claude)
            defer { e.repo.remove() }
            let events = QueueEventLog()
            let queue = RespondQueue(pipeline: e.pipeline, history: e.history) { prID, phase in events.record(.finished("\(prID)|\(phase.name)")) }
            queue.analyze(classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            try await events.wait(for: reached(7, "readyToPush"))
            guard case .readyToPush(let draft, let result)? = queue.phases[prID(7)], let merge = result.headOid else {
                throw TestFailure(description: "sin readyToPush")
            }
            // El push anterior llegó (la app se cerró antes de anotarlo): GitHub ya tiene el merge como head.
            try TempGitRepo.run(URL(fileURLWithPath: draft.worktree.path), ["push", "-q", "origin", "\(merge):refs/heads/feature"])
            e.api.details = PRDetails(title: "t", body: "", headOid: merge, state: .open, baseRef: "main")
            queue.publish(prID: prID(7))
            try await events.wait(for: reached(7, "done"))
            try expectEqual(try e.git(e.repo.origin.path, ["rev-parse", "refs/heads/feature"]), merge)
        },
        TestCase("fix ci: lee los checks en la Mac, prepara el worktree, implementa solo, no responde y pushea con el CI re-verificado") { @MainActor in
            let claude = ScriptedClaude { schema, prompt, cwd in
                guard schema == RespondSchemas.fix, prompt.contains("MARK-CI") else { return [] }
                try append("chau\n", to: "README.md", in: cwd)
                return [fixLine("Fix the README check")]
            }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            e.api.checks[e.repo.prSHA] = [ciRun("build", id: 5), ciRun("lint", id: 6, conclusion: "success")]
            e.api.jobLogs[5] = "2026-11-20T10:00:00Z MARK-CI: README needs chau\nerror: tok-fede leaked"
            e.api.details = PRDetails(title: "t", body: "", headOid: e.repo.prSHA, state: .open)
            let events = QueueEventLog()
            let queue = RespondQueue(pipeline: e.pipeline, history: e.history) { prID, phase in
                events.record(.finished("\(prID)|\(phase.name)"))
            }
            queue.analyze(classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .ciFix)
            try expectEqual(queue.modes[prID(7)], .ciFix)
            try await events.wait(for: reached(7, "readyToPush"))
            guard case .readyToPush(let draft, let result)? = queue.phases[prID(7)] else { throw TestFailure(description: "sin readyToPush") }
            try expectEqual(draft.mode, .ciFix)
            try expectEqual(draft.ci?.checks.map(\.name), ["build"])
            try expectEqual(draft.startHeadOid, e.repo.prSHA)
            try expectEqual(result.commits?.map(\.message), ["Fix the README check"])
            try expectEqual(claude.calls.count, 1)
            let prompt = claude.calls[0].arguments[claude.calls[0].arguments.firstIndex(of: "-p")! + 1]
            try expect(prompt.contains("<<<CI_LOG_"))
            try expect(!prompt.contains("tok-fede"))
            try expect(!prompt.contains("2026-11-20T10:00:00Z"))
            // Al pushear: mismo head en GitHub y el check sigue fallando.
            queue.publish(prID: prID(7))
            try await events.wait(for: reached(7, "done"))
            let head = try e.git(draft.worktree.path, ["rev-parse", "HEAD"])
            try expectEqual(try e.git(e.repo.origin.path, ["rev-parse", "refs/heads/feature"]), head)
            try expect(e.api.posts.isEmpty)
            try expectEqual(e.api.checkCalls, [e.repo.prSHA, e.repo.prSHA])
        },
        TestCase("fix ci: con los checks en verde no pushea (vuelve al diff con el aviso) salvo Push Anyway; un head nuevo nunca") { @MainActor in
            let claude = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.fix else { return [] }
                try append("chau\n", to: "README.md", in: cwd)
                return [fixLine("Fix it")]
            }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            e.api.checks[e.repo.prSHA] = [ciRun("build", id: 5)]
            e.api.details = PRDetails(title: "t", body: "", headOid: e.repo.prSHA, state: .open)
            let events = QueueEventLog()
            let queue = RespondQueue(pipeline: e.pipeline, history: e.history) { prID, phase in
                events.record(.finished("\(prID)|\(phase.name)"))
            }
            queue.analyze(classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .ciFix)
            try await events.wait(for: reached(7, "readyToPush"))
            // Alguien re-corrió el CI y pasó.
            e.api.checks[e.repo.prSHA] = [ciRun("build", id: 9, conclusion: "success")]
            queue.publish(prID: prID(7))
            try await waitUntil { queue.pushBlockedByCI[prID(7)] != nil }
            try await waitUntil { if case .readyToPush? = queue.phases[prID(7)] { return true } else { return false } }
            try expect(queue.pushBlockedByCI[prID(7)]!.contains("pass now"))
            // Back in readyToPush with a phase event (Activity, History and the notification hear of it).
            try await waitUntil { events.count(.finished("\(prID(7))|readyToPush")) == 2 }
            try expectEqual(try e.git(e.repo.origin.path, ["rev-parse", "refs/heads/feature"]), e.repo.prSHA)
            // Un head nuevo en GitHub: ni con Push Anyway.
            e.api.details = PRDetails(title: "t", body: "", headOid: String(repeating: "9", count: 40), state: .open)
            queue.publish(prID: prID(7), ignoringCI: true)
            try await events.wait(for: reached(7, "failed"))
            if case .failed(let message, _)? = queue.phases[prID(7)] { try expect(message.contains("new commits"), message) }
            try expectEqual(try e.git(e.repo.origin.path, ["rev-parse", "refs/heads/feature"]), e.repo.prSHA)
            // El push anterior llegó sin quedar anotado: GitHub ya tiene lo revisado y el reintento termina.
            guard let reviewed = queue.records[prID(7)]?.result?.headOid, let worktree = queue.records[prID(7)]?.draft.worktree.path else {
                throw TestFailure(description: "sin resultado")
            }
            try TempGitRepo.run(URL(fileURLWithPath: worktree), ["push", "-q", "origin", "\(reviewed):refs/heads/feature"])
            e.api.details = PRDetails(title: "t", body: "", headOid: reviewed, state: .open)
            events.reset()
            queue.publish(prID: prID(7))
            try await events.wait(for: reached(7, "done"))
        },
        TestCase("fix ci: sin checks fallidos o con el PR movido mientras leía el CI, falla sin worktree ni Claude") {
            let claude = ScriptedClaude { _, _, _ in [] }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .ciFix)
            e.api.checks[e.repo.prSHA] = [ciRun("build", id: 5, conclusion: "success")]
            let none = try await expectThrows { _ = try await e.pipeline.analyze(request, draftID: UUID()) { _ in } }
            try expectEqual(none as? PRBarError, .respond(RespondPipeline.noFailingChecksMessage))
            // GitHub dice otro head (el PR avanzó): el worktree que se armó no es el que falló.
            let other = String(repeating: "d", count: 40)
            e.api.feedback = PRFeedback(headRefName: "feature", headRefOid: other, isCrossRepository: false, lastCommitAt: at(0),
                                        threads: [], reviews: [])
            e.api.checks[other] = [ciRun("build", id: 5)]
            let moved = try await expectThrows { _ = try await e.pipeline.analyze(request, draftID: UUID()) { _ in } }
            try expect((moved as? PRBarError).map { "\($0.localizedDescription)" }?.contains("new commits") == true, "\(moved)")
            try expectEqual(claude.calls.count, 0)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: e.worktreeDir.path)) ?? []
            try expect(left.isEmpty, "\(left)")
        },
        TestCase("respond pipeline: sin ítems sin resolver falla sin tocar git ni Claude") {
            let claude = ScriptedClaude { _, _, _ in [] }
            let git = FakeProcessRunner { _, _ in ok("") }
            let api = FakeFeedbackAPI(feedback: PRFeedback(
                headRefName: "feature", headRefOid: "abc", isCrossRepository: false, lastCommitAt: at(0),
                threads: [FeedbackItem(id: "thread:R", kind: .thread, path: "a", line: 1, isOutdated: false, isResolved: true,
                                       comments: threadItem("thread:R", databaseID: 1).comments)],
                reviews: []))
            let pipeline = RespondPipeline(processRunner: git, streamingRunner: claude, tokens: FakeTokens(), api: api,
                                           gitPath: "/usr/bin/git", claudePath: "/usr/local/bin/claude",
                                           logURLProvider: { _ in URL(fileURLWithPath: "/tmp/x.log") })
            let error = try await expectThrows {
                _ = try await pipeline.analyze(RespondRequest(item: classified(7), localPath: "/repos/r", worktreeDir: nil),
                                               draftID: UUID()) { _ in }
            }
            try expectEqual(error as? PRBarError, .respond("There are no unresolved comments"))
            try expectEqual(git.calls.count, 0)
            try expectEqual(claude.calls.count, 0)
        },
        TestCase("respond pipeline: a respond skill whose plugin isn't installed fails without touching git or Claude") {
            let claude = ScriptedClaude { _, _, _ in [] }
            let git = FakeProcessRunner { _, _ in ok("") }
            let api = FakeFeedbackAPI(feedback: PRFeedback(
                headRefName: "feature", headRefOid: "abc", isCrossRepository: false, lastCommitAt: at(-10),
                threads: [threadItem("thread:A", databaseID: 101)], reviews: []))
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            var settings = ClaudeSettings()
            settings.respondSkill = "my-plugin:triage"
            let pipeline = RespondPipeline(processRunner: git, streamingRunner: claude, tokens: FakeTokens(), api: api,
                                           gitPath: "/usr/bin/git", claudePath: "/usr/local/bin/claude",
                                           pluginCacheDirectory: try pluginCache(in: root), settings: settings,
                                           logURLProvider: { _ in URL(fileURLWithPath: "/tmp/x.log") })
            let error = try await expectThrows {
                _ = try await pipeline.analyze(RespondRequest(item: classified(7), localPath: "/repos/r", worktreeDir: nil),
                                               draftID: UUID()) { _ in }
            }
            try expectEqual(error as? PRBarError, .claudePluginMissing(plugin: "my-plugin", skill: "my-plugin:triage"))
            try expectEqual(git.calls.count, 0)
            try expectEqual(claude.calls.count, 0)
        },
        TestCase("respond pipeline: la cancelación mira el worktree con el WorkspaceFS del trabajo; uno remoto sin él cuenta como cambiado") {
            let git = FakeProcessRunner { _, args in
                if args.contains("rev-list") { return ok("2\n") }
                return ok("")
            }
            func pipeline(_ fs: (any WorkspaceFS)?) -> RespondPipeline {
                if let fs {
                    return RespondPipeline(processRunner: git, streamingRunner: ScriptedClaude { _, _, _ in [] }, tokens: FakeTokens(),
                                           api: FakeFeedbackAPI(), gitPath: "/usr/bin/git", claudePath: "/usr/local/bin/claude",
                                           logURLProvider: { _ in URL(fileURLWithPath: "/tmp/x.log") }, workspaceFS: fs)
                }
                return RespondPipeline(processRunner: git, streamingRunner: ScriptedClaude { _, _, _ in [] }, tokens: FakeTokens(),
                                       api: FakeFeedbackAPI(), gitPath: "/usr/bin/git", claudePath: "/usr/local/bin/claude",
                                       logURLProvider: { _ in URL(fileURLWithPath: "/tmp/x.log") })
            }
            let worktree = ResolvedWorktree(path: "/home/u/.prbar/installs/x/work/r-7-respond-0a0b0c0d", origin: .dedicated)
            let remote = RespondDraft(prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "T",
                                      url: URL(string: "https://github.com/o/r/pull/7")!, headRef: "feature", account: "me",
                                      worktree: worktree, startHeadOid: String(repeating: "a", count: 40), items: [], runner: "devbox")
            // Sin el WorkspaceFS del host: ni git ni el disco de la Mac; no se sabe nada, cuenta como sucio.
            let unknown = await pipeline(nil).cancellation(of: remote)
            try expectEqual(unknown, RespondCancellation(unpushedCommits: nil, path: worktree.path, dirty: true))
            try expectEqual(git.calls.count, 0)
            // Con el del host: lo usa (sin .git anidados) y recién ahí corre git.
            let hostFS = StubWorkspaceFS()
            let known = await pipeline(hostFS).cancellation(of: remote)
            try expectEqual(known, RespondCancellation(unpushedCommits: 2, path: worktree.path, dirty: false))
            try expectEqual(hostFS.nestedRoots, [worktree.path])
        },
        TestCase("respond pipeline: un PR de fork falla sin tocar git ni Claude") {
            let claude = ScriptedClaude { _, _, _ in [] }
            let git = FakeProcessRunner { _, _ in ok("") }
            let api = FakeFeedbackAPI(feedback: PRFeedback(
                headRefName: "feature", headRefOid: "abc", isCrossRepository: true, lastCommitAt: at(-10),
                threads: [threadItem("thread:A", databaseID: 101)], reviews: []))
            let pipeline = RespondPipeline(processRunner: git, streamingRunner: claude, tokens: FakeTokens(), api: api,
                                           gitPath: "/usr/bin/git", claudePath: "/usr/local/bin/claude",
                                           logURLProvider: { _ in URL(fileURLWithPath: "/tmp/x.log") })
            let error = try await expectThrows {
                _ = try await pipeline.analyze(RespondRequest(item: classified(7), localPath: "/repos/r", worktreeDir: nil),
                                               draftID: UUID()) { _ in }
            }
            try expectEqual(error as? PRBarError, .respond("The PR comes from a fork: PRBar can't push to it"))
            try expectEqual(git.calls.count, 0)
            try expectEqual(claude.calls.count, 0)
        },
        TestCase("respond pipeline: release deja el worktree en disco y deja de contarlo como en uso") {
            let claude = ScriptedClaude { schema, _, _ in
                schema == RespondSchemas.analysis ? [analysisLine(["thread:A", "thread:B"])] : []
            }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            let draft = try await e.pipeline.analyze(e.request, draftID: UUID()) { _ in }
            try expect(WorkspaceRegistry.shared.contains(draft.worktree.path))
            await e.pipeline.release(draft: draft)
            try expect(!WorkspaceRegistry.shared.contains(draft.worktree.path))
            try expect(FileManager.default.fileExists(atPath: draft.worktree.path))
            try expect(try e.git(e.repo.local.path, ["worktree", "list", "--porcelain"]).contains(draft.worktree.path))
            await e.pipeline.cleanup(draft: draft)
        },
        TestCase("respond pipeline: de punta a punta con git real: análisis, fix, push al remoto y respuestas") { @MainActor in
            let claude = ScriptedClaude { schema, prompt, cwd in
                if schema == RespondSchemas.analysis { return [analysisLine(["thread:A", "thread:B"])] }
                guard prompt.contains("MARK-A") else { throw TestFailure(description: "fix inesperado") }
                try append("chau\n", to: "README.md", in: cwd)
                return [fixLine("Add farewell")]
            }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            let events = QueueEventLog()
            let queue = RespondQueue(pipeline: e.pipeline, history: e.history) { prID, phase in
                events.record(.finished("\(prID)|\(phase.name)"))
            }
            queue.analyze(classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path)
            try await events.wait(for: reached(7, "ready"))
            guard case .ready(let draft)? = queue.phases[prID(7)] else {
                throw TestFailure(description: "esperaba ready: \(String(describing: queue.phases[prID(7)]))")
            }
            try expectEqual(draft.worktree.origin, .dedicated)
            try expectEqual(draft.worktree.localPath, e.repo.local.path)
            try expect(draft.worktree.path.hasSuffix(e.worktreeDir.lastPathComponent + "/" + (draft.worktree.path as NSString).lastPathComponent) && WorktreeResolver.isRespondWorktreeName((draft.worktree.path as NSString).lastPathComponent), draft.worktree.path)
            let ref = try draft.worktree.ref ?? { throw TestFailure(description: "sin ref") }()
            try expect(ref.hasPrefix("refs/prbar/respond-7-"), ref)
            try expectEqual(draft.headRef, "feature")
            try expectEqual(draft.startHeadOid, e.repo.prSHA)
            // El clone del usuario sigue en main, sin rama local de la PR.
            try expectEqual(try e.git(e.repo.local.path, ["rev-parse", "--abbrev-ref", "HEAD"]), "main")
            try expectEqual(try e.git(e.repo.local.path, ["branch", "--list", "feature"]), "")
            try expectEqual(draft.items.map(\.id), ["thread:A", "thread:B"])
            // The fake's description is Spanish: the replies (and "Fixed in") go out in Spanish.
            try expectEqual(draft.language, PRLanguage(code: "es"))
            try expectEqual(e.api.detailsCalls, 1)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: e.worktreeRoot.path)) ?? []
            try expect(!leftovers.contains { $0.hasSuffix(".respond-context") }, "\(leftovers)")

            let selections: [String: RespondSelection] = [
                "thread:A": RespondSelection(implement: true, fixPlan: "Arreglalo", reply: true, replyText: "Gracias"),
                "thread:B": RespondSelection(implement: false, fixPlan: "", reply: false, replyText: ""),
            ]
            queue.implement(prID: prID(7), selections: selections)
            try await events.wait(for: reached(7, "readyToPush"))
            guard case .readyToPush(_, let result)? = queue.phases[prID(7)] else { throw TestFailure(description: "esperaba readyToPush") }
            let path = draft.worktree.path
            let head = try e.git(path, ["rev-parse", "HEAD"])
            try expectEqual(result.items.map(\.commit), [head])

            queue.publish(prID: prID(7))
            try await events.wait(for: reached(7, "done"))
            try expectEqual(try e.git(e.repo.origin.path, ["rev-parse", "refs/heads/feature"]), head)
            try expectEqual(e.api.posts, [.reply(commentID: 101, body: "Arreglado en https://github.com/o/r/commit/\(head). Gracias")])
            try expectEqual(e.api.tokens, ["tok-fede"])
            // Claude nunca ve el token, ni en el entorno ni en los argumentos. Solo carga el plugin del skill de responder.
            for call in claude.calls {
                try expectEqual(call.arguments.filter { $0 == "--plugin-dir" }.count, 1)
                try expect(call.arguments.contains { $0.hasSuffix("official/superpowers/1.0") }, "\(call.arguments)")
                try expect(!(call.environment ?? [:]).values.contains { $0.contains("tok-fede") })
                try expect(!call.arguments.contains { $0.contains("tok-fede") })
            }
            try expect(FileManager.default.fileExists(atPath: e.history.logURL(for: draft.id).path))
            try expectEqual(e.history.record(id: draft.id)?.pushed, true)
            // Terminado: se borran el worktree y la ref de PRBar.
            try await waitUntil { !FileManager.default.fileExists(atPath: path) }
            try await waitUntil { (try? e.git(e.repo.local.path, ["for-each-ref", ref])) == "" }
        },
        TestCase("respond pipeline: cancelar durante implementing con git real deja el árbol limpio y cuenta los commits") { @MainActor in
            let events = QueueEventLog()
            let claude = ScriptedClaude { schema, prompt, cwd in
                if schema == RespondSchemas.analysis { return [analysisLine(["thread:A", "thread:B"])] }
                if prompt.contains("MARK-A") {
                    try append("chau\n", to: "README.md", in: cwd)
                    return [fixLine("Add farewell")]
                }
                // B: deja cambios a medias y se cuelga hasta que lo cancelan.
                try append("a medias\n", to: "README.md", in: cwd)
                try Data("nuevo\n".utf8).write(to: cwd.appendingPathComponent("nuevo.txt"))
                Task { @MainActor in events.record(.started("claude:B")) }
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return []
            }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            let queue = RespondQueue(pipeline: e.pipeline, history: e.history) { prID, phase in
                events.record(.finished("\(prID)|\(phase.name)"))
            }
            queue.analyze(classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path)
            try await events.wait(for: reached(7, "ready"))
            guard case .ready(let draft)? = queue.phases[prID(7)] else { throw TestFailure(description: "esperaba ready") }
            let both = [
                "thread:A": RespondSelection(implement: true, fixPlan: "a", reply: true, replyText: ""),
                "thread:B": RespondSelection(implement: true, fixPlan: "b", reply: true, replyText: ""),
            ]
            queue.implement(prID: prID(7), selections: both)
            try await events.wait(for: [.started("claude:B")])
            queue.cancel(prID: prID(7))
            try await events.wait(for: reached(7, "failed"))
            let path = draft.worktree.path
            guard case .failed(let message, _)? = queue.phases[prID(7)] else { throw TestFailure(description: "esperaba failed") }
            try expectEqual(message, "Canceled: 1 unpushed commit was left in \(path).")
            try expectEqual(try e.git(path, ["status", "--porcelain", "--untracked-files=all"]), "")
            try expectEqual(try e.git(path, ["log", "-1", "--format=%s"]), "Add farewell")
            try expectEqual(try e.git(e.repo.origin.path, ["rev-parse", "refs/heads/feature"]), e.repo.prSHA)
            try expectEqual(e.api.posts, [])
            try expectEqual(e.history.record(id: draft.id)?.errorMessage, message)
            // Después de un fallo el worktree queda para revisarlo.
            try expect(FileManager.default.fileExists(atPath: path))
        },
        TestCase("respond queue: pushAfterTests corre los tests y, si pasan, pushea y responde") { @MainActor in
            let h = try Harness()
            h.pipeline.testsPass = true
            try await h.toReadyToPush(1)
            h.queue.pushAfterTests(prID: prID(1), testCommand: "make test")
            try expect(h.queue.runningTests.contains(prID(1)))
            try await h.events.wait(for: reached(1, "done"))
            try expectEqual(h.pipeline.tests, ["make test"])
            try expectEqual(h.pipeline.pushes.count, 1)
            try expectEqual(try h.saved(1).result?.tests?.passed, true)
            try expect(!h.queue.pushBlockedByTests.contains(prID(1)))
        },
        TestCase("respond queue: pushAfterTests dice si arrancó; con un turno del chat corriendo no arranca") { @MainActor in
            let h = try Harness()
            h.pipeline.testsPass = true
            try await h.toReadyToPush(1)
            h.queue.setChatRunning(true, prID: prID(1))
            try expect(!h.queue.pushAfterTests(prID: prID(1), testCommand: "make test"))
            try expect(!h.queue.runningTests.contains(prID(1)))
            try expect(!h.queue.runTests(prID: prID(1), testCommand: "make test"))
            h.queue.setChatRunning(false, prID: prID(1))
            try expect(!h.queue.pushAfterTests(prID: prID(1), testCommand: "  "))
            try expect(h.queue.pushAfterTests(prID: prID(1), testCommand: "make test"))
            try await h.events.wait(for: reached(1, "done"))
        },
        TestCase("respond queue: desde un iPhone sin Face ID implementar no corre tests y ni tests ni push arrancan (H1)") { @MainActor in
            let h = try Harness()
            h.pipeline.testsPass = true
            let phone = CommandOrigin.phone(device: "d1", mayRunRepoCode: false)
            // Implementar desde el teléfono llega a readyToPush sin correr nada.
            try await CommandOrigin.$current.withValue(phone) { try await h.toReadyToPush(1) }
            await h.settle()
            try expectEqual(h.pipeline.tests, [])
            CommandOrigin.$current.withValue(phone) {
                try? expect(!h.queue.runTests(prID: prID(1), testCommand: "make test"))
                try? expect(!h.queue.pushAfterTests(prID: prID(1), testCommand: "make test"))
                h.queue.publish(prID: prID(1))
                h.queue.publish(prID: prID(1), ignoringCI: true)
            }
            try expect(h.queue.runningTests.isEmpty)
            await h.settle()
            try expectEqual(h.pipeline.tests, [])
            try expectEqual(h.pipeline.pushes.count, 0)
            guard case .readyToPush? = h.queue.phases[prID(1)] else { throw TestFailure(description: "esperaba readyToPush") }
            // Con Face ID (o desde la Mac) sí, y el push de después de los tests no hereda el origen del teléfono.
            let signed = CommandOrigin.phone(device: "d1", mayRunRepoCode: true)
            let started = CommandOrigin.$current.withValue(signed) { h.queue.pushAfterTests(prID: prID(1), testCommand: "make test") }
            try expect(started)
            try await h.events.wait(for: reached(1, "done"))
            try expectEqual(h.pipeline.tests, ["make test"])
            try expectEqual(h.pipeline.pushes.count, 1)
        },
        TestCase("respond queue: si los tests fallan no pushea; Push Anyway pushea y limpia el bloqueo") { @MainActor in
            let h = try Harness()
            try await h.toReadyToPush(1)
            h.queue.pushAfterTests(prID: prID(1), testCommand: "make test")
            try await waitUntil { h.queue.pushBlockedByTests.contains(prID(1)) }
            try expect(h.queue.pushBlockedByTests.contains(prID(1)))
            try expectEqual(h.pipeline.pushes, [])
            try expectEqual(h.queue.phases[prID(1)]?.name, "readyToPush")
            try expectEqual(h.queue.records[prID(1)]?.result?.tests?.passed, false)
            h.queue.publish(prID: prID(1))
            try expect(!h.queue.pushBlockedByTests.contains(prID(1)))
            try await h.events.wait(for: reached(1, "done"))
            try expectEqual(h.pipeline.pushes.count, 1)
        },
        TestCase("respond queue: el uso de Claude del análisis y de los fixes se suma en el registro (spec O)") { @MainActor in
            let h = try Harness()
            h.pipeline.spend = .run(duration: 10, tokens: ClaudeTokenUsage(inputTokens: 100, outputTokens: 20), cost: 0.5)
            try await h.toReadyToPush(1)
            let record = try h.saved(1)
            try expectEqual(record.usage?.runs, 2)
            try expectEqual(record.usage?.costUSD, 1.0)
            try expectEqual(record.totalUsage?.inputTokens, 200)
        },
        TestCase("respond queue: un análisis fallido guarda su uso en el registro vacío del historial") { @MainActor in
            let h = try Harness()
            h.pipeline.spend = .run(duration: 4, tokens: nil, cost: 0.2)
            h.queue.analyze(classified(3), localPath: "/repos/r", worktreeDir: nil)
            try await h.events.wait(for: [.started("analyze:\(prID(3))")])
            h.pipeline.completeAnalysis(3, .failure(Boom()))
            try await h.events.wait(for: reached(3, "failed"))
            let saved = h.history.all().first { $0.draft.number == 3 }
            try expectEqual(saved?.usage?.costUSD, 0.2)
        },
        TestCase("respond queue: Fix CI no reemplaza un Respond abierto ni al revés (spec K.2.1)") { @MainActor in
            let h = try Harness()
            // Un análisis de feedback en `ready`: Fix CI no lo pisa.
            try await h.toReady(1)
            let draft = try h.draft(1)
            try expectEqual(h.queue.openRunConflict(prID: prID(1), starting: .ciFix), .feedback)
            try expectEqual(h.queue.openRunConflict(prID: prID(1), starting: .feedback), nil)
            h.queue.analyze(classified(1), localPath: "/repos/r", worktreeDir: nil, mode: .ciFix)
            await h.settle()
            try expectEqual(h.queue.phases[prID(1)], .ready(draft))
            try expectEqual(h.queue.mode(of: prID(1)), .feedback)
            // Un Fix CI que quedó en `ready`: Respond no lo pisa.
            h.queue.analyze(classified(2), localPath: "/repos/r", worktreeDir: nil, mode: .ciFix)
            try await h.events.wait(for: [.started("analyze:\(prID(2))")])
            // Mientras corre también cuenta como abierto.
            try expectEqual(h.queue.openRunConflict(prID: prID(2), starting: .feedback), .ciFix)
            h.pipeline.completeAnalysis(2)
            try await h.events.wait(for: reached(2, "ready"))
            let ciDraft = try h.draft(2)
            h.queue.analyze(classified(2), localPath: "/repos/r", worktreeDir: nil)
            await h.settle()
            try expectEqual(h.queue.phases[prID(2)], .ready(ciDraft))
            try expectEqual(h.queue.mode(of: prID(2)), .ciFix)
            // Descartado (o terminado), el otro modo puede arrancar.
            h.queue.dismiss(prID: prID(1))
            try expectEqual(h.queue.openRunConflict(prID: prID(1), starting: .ciFix), nil)
            h.queue.analyze(classified(1), localPath: "/repos/r", worktreeDir: nil, mode: .ciFix)
            try expectEqual(h.queue.modes[prID(1)], .ciFix)
        },
        TestCase("respond pipeline: los pasos de PRBar del análisis en orden, antes de los de Claude") {
            let claude = ScriptedClaude { schema, _, _ in schema == RespondSchemas.analysis ? [analysisLine(["thread:A", "thread:B"])] : [] }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            let activities = Box<[JobActivity]>([])
            _ = try await e.pipeline.analyze(e.request, draftID: UUID(), onPhase: { _ in }, onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.filter { $0.kind == .prbar }.map(\.text),
                            [JobStep.readingComments, JobStep.readingPR, JobStep.creatingWorktree, JobStep.writingContext])
            let firstClaude = try expectSome(activities.value.firstIndex { $0.kind == .claude })
            try expectEqual(activities.value[firstClaude].text, ClaudeActivityText.starting)
            try expectEqual(firstClaude, 4)
        },
        TestCase("fix ci: los pasos del análisis: el PR, los checks, los logs, el worktree y el contexto") {
            let claude = ScriptedClaude { _, _, _ in [] }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            e.api.checks[e.repo.prSHA] = [ciRun("build", id: 5)]
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .ciFix)
            let activities = Box<[JobActivity]>([])
            _ = try await e.pipeline.analyze(request, draftID: UUID(), onPhase: { _ in }, onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.map(\.text), [
                JobStep.readingPR, JobStep.readingFailingChecks, JobStep.downloadingCILogs, JobStep.creatingWorktree, JobStep.writingContext,
            ])
            // A check that isn't from Actions has no log to download: no step for it.
            let other = Box<[JobActivity]>([])
            e.api.checks[e.repo.prSHA] = [ciRun("lint", actions: false)]
            _ = try await e.pipeline.analyze(request, draftID: UUID(), onPhase: { _ in }, onActivity: { other.value.append($0) })
            try expect(!other.value.contains { $0.text == JobStep.downloadingCILogs }, "\(other.value.map(\.text))")
        },
        TestCase("resolve conflicts: los pasos: el PR, el worktree, fetch y merge de la base, el contexto") {
            let claude = ScriptedClaude { _, _, _ in [] }
            let (e, _) = try conflictingE2E(claude: claude)
            defer { e.repo.remove() }
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            let activities = Box<[JobActivity]>([])
            _ = try await e.pipeline.analyze(request, draftID: UUID(), onPhase: { _ in }, onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.map(\.text),
                            [JobStep.readingPR, JobStep.creatingWorktree, "Fetching main…", "Merging main…", JobStep.writingContext])
        },
        TestCase("respond pipeline: implementar: los pasos de Claude y 'Committing…' antes de cada commit") {
            let claude = ScriptedClaude { schema, _, cwd in
                if schema == RespondSchemas.analysis { return [analysisLine(["thread:A", "thread:B"])] }
                try append("chau\n", to: "README.md", in: cwd)
                return [fixLine("Add farewell")]
            }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            let draft = try await e.pipeline.analyze(e.request, draftID: UUID()) { _ in }
            let selections: [String: RespondSelection] = [
                "thread:A": RespondSelection(implement: true, fixPlan: "Arreglalo", reply: false, replyText: ""),
                "thread:B": RespondSelection(implement: false, fixPlan: "", reply: false, replyText: ""),
            ]
            let activities = Box<[JobActivity]>([])
            _ = try await e.pipeline.implement(draft: draft, selections: selections, onProgress: { _, _ in },
                                               onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.first?.text, ClaudeActivityText.starting)
            let prbar = activities.value.filter { $0.kind == .prbar }.map(\.text)
            // One per commit (and one more for the squash in single-commit mode).
            try expect(!prbar.isEmpty && prbar.allSatisfy { $0 == JobStep.committing }, "\(prbar)")
        },
        TestCase("resolve conflicts: implementar: Claude, después los marcadores y el commit del merge") {
            let claude = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR y base\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                return [conflictsLine()]
            }
            let (e, _) = try conflictingE2E(claude: claude)
            defer { e.repo.remove() }
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            let draft = try await e.pipeline.analyze(request, draftID: UUID()) { _ in }
            let selections = Dictionary(uniqueKeysWithValues: draft.items.map { ($0.id, RespondSelection.defaults(for: $0)) })
            let activities = Box<[JobActivity]>([])
            _ = try await e.pipeline.implement(draft: draft, selections: selections, onProgress: { _, _ in },
                                               onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.first?.text, ClaudeActivityText.starting)
            try expectEqual(activities.value.filter { $0.kind == .prbar }.map(\.text),
                            [JobStep.checkingConflictMarkers, JobStep.committingMerge])
        },
    ]
}
