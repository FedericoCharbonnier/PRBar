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

private func fakeDraft(_ number: Int, id: UUID) -> RespondDraft {
    let pr = makePR(number: number, author: "fede")
    return RespondDraft(
        id: id, prID: pr.id, repo: pr.repo, number: number, title: pr.title, url: pr.url, headRef: pr.headRef,
        account: "fede", worktree: ResolvedWorktree(path: "/wt/\(number)", origin: .dedicated, localPath: "/repos/r",
                                                    ref: "refs/prbar/respond-\(number)-0a1b2c3d"), startHeadOid: startOid,
        items: [respondItem(threadItem("thread:A", databaseID: 101)), respondItem(threadItem("thread:B", databaseID: 102))],
        language: PRLanguage(code: "es"))
}

private let bothSelected: [String: RespondSelection] = [
    "thread:A": RespondSelection(implement: true, fixPlan: "plan A", reply: true, replyText: ""),
    "thread:B": RespondSelection(implement: false, fixPlan: "", reply: true, replyText: "Lo dejo así."),
]

private let fixResult = RespondResult(items: [ItemResult(id: "thread:A", status: .committed, commit: sha1, summary: "ok")],
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

    init(events: QueueEventLog, api: FakeFeedbackAPI = FakeFeedbackAPI()) {
        self.events = events
        self.api = api
    }

    var pushes: [String] { lock.withLock { _pushes } }
    /// Los drafts cuyo worktree se pidió limpiar, en orden.
    var cleanups: [UUID] { lock.withLock { _cleanups } }
    var tests: [String] { lock.withLock { _tests } }

    func logURL(for id: UUID) -> URL { URL(fileURLWithPath: "/nonexistent/\(id.uuidString).log") }

    func analyze(_ request: RespondRequest, draftID: UUID,
                 onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void) async throws -> RespondDraft {
        let prID = request.item.id
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
        let prID = draft.prID
        let events = self.events
        if let spend = lock.withLock({ self.spend }) { ClaudeUsageCenter.shared.record(spend, stage: "fix") }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock { implementations[prID] = (onProgress, continuation) }
                    Task { @MainActor in events.record(.started("implement:\(prID)")) }
                }
            } onCancel: {
                let entry = lock.withLock { implementations.removeValue(forKey: prID) }
                entry?.continuation.resume(throwing: CancellationError())
            }
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

    func cleanup(draft: RespondDraft) async {
        lock.withLock { _cleanups.append(draft.id) }
    }

    // Control desde el test

    @MainActor func sendAnalysis(_ phase: RespondPhase, to prID: String) {
        let sink = lock.withLock { analyses[prID]?.sink }
        sink?(phase)
    }

    func completeAnalysis(_ number: Int, _ result: Result<Void, Error> = .success(())) {
        let key = prID(number)
        guard let entry = lock.withLock({ analyses.removeValue(forKey: key) }) else { return }
        entry.continuation.resume(with: result.map { fakeDraft(number, id: entry.id) })
    }

    @MainActor func sendProgress(_ done: Int, _ total: Int, to prID: String) {
        let sink = lock.withLock { implementations[prID]?.sink }
        sink?(done, total)
    }

    func completeImplementation(_ prID: String, _ result: Result<RespondResult, Error>) {
        let entry = lock.withLock { implementations.removeValue(forKey: prID) }
        entry?.continuation.resume(with: result)
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
    private(set) var queue: RespondQueue!

    init(maxConcurrent: Int = 2) throws {
        pipeline = FakeRespondPipeline(events: events)
        historyDir = try temporaryDirectory()
        history = RespondHistory(historyDir: historyDir)
        queue = RespondQueue(pipeline: pipeline, history: history, maxConcurrent: maxConcurrent) { [unowned self] prID, phase in
            self.emitted.append((prID, phase))
            self.events.record(.finished("\(prID)|\(phase.name)"))
        }
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

    /// ready → implementing → readyToPush.
    func toReadyToPush(_ number: Int) async throws {
        try await toReady(number)
        queue.implement(prID: prID(number), selections: bothSelected)
        try await events.wait(for: [.started("implement:\(prID(number))")])
        pipeline.completeImplementation(prID(number), .success(fixResult))
        try await events.wait(for: reached(number, "readyToPush"))
    }
}

// MARK: - Tests

enum RespondQueueTests {
    static let cases: [TestCase] = [
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

            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
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
    func nestedGitEntries(_ root: String) async throws -> [String] {
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

    static func make(claude: ScriptedClaude) throws -> E2E {
        let repo = try TempGitRepo.make()
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

private func append(_ text: String, to name: String, in cwd: URL) throws {
    let url = cwd.appendingPathComponent(name)
    let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    try Data((current + text).utf8).write(to: url)
}

enum RespondPipelineTests {
    static let cases: [TestCase] = [
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
    ]
}
