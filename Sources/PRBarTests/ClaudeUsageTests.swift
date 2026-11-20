import Foundation
import PRBarCore

private struct Answer: Decodable { let summary: String }
private let schema = #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}"#
private let usageLine = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"ok"},"total_cost_usd":0.25,"usage":{"input_tokens":1200,"output_tokens":340,"cache_creation_input_tokens":5000,"cache_read_input_tokens":80000}}"#
private let invalidLine = #"{"type":"result","subtype":"success","is_error":false,"result":"sin json","total_cost_usd":0.1,"usage":{"input_tokens":10,"output_tokens":5}}"#

private func runner(_ fake: FakeStreamingRunner) throws -> ClaudeRunner {
    ClaudeRunner(runner: fake, claudePath: "/usr/local/bin/claude", pluginDirs: [], environment: ["PATH": "/usr/bin"],
                 logURL: try temporaryDirectory().appendingPathComponent("claude.log"), redacting: [])
}

private func invocation(_ header: String = "=== stage 1 ===") -> ClaudeInvocation {
    ClaudeInvocation(prompt: "x", schema: schema, tools: ["Read"], workingDirectory: URL(fileURLWithPath: "/tmp/wt/u-1"),
                     timeout: 30, logHeader: header)
}

enum ClaudeUsageTests {
    static let cases: [TestCase] = [
        TestCase("usage: el parser lee usage y total_cost_usd de la línea result") {
            var parser = ClaudeStreamParser()
            _ = parser.consumeAll(usageLine)
            try expectEqual(parser.result?.costUSD, 0.25)
            try expectEqual(parser.result?.usage, ClaudeTokenUsage(inputTokens: 1200, outputTokens: 340,
                                                                   cacheCreationTokens: 5000, cacheReadTokens: 80000))
            var bare = ClaudeStreamParser()
            _ = bare.consumeAll(#"{"type":"result","is_error":false,"result":"x"}"#)
            try expectEqual(bare.result?.usage, nil)
            try expectEqual(bare.result?.costUSD, nil)
        },
        TestCase("usage: suma corridas; el costo es nil solo si ninguna lo trajo; las sin datos cuentan aparte") {
            let a = ClaudeUsage.run(duration: 10, tokens: ClaudeTokenUsage(inputTokens: 100, outputTokens: 10), cost: 0.5)
            let b = ClaudeUsage.run(duration: 5, tokens: nil, cost: nil)
            let total = a + b
            try expectEqual(total.runs, 2)
            try expectEqual(total.unknownRuns, 1)
            try expectEqual(total.durationSeconds, 15)
            try expectEqual(total.costUSD, 0.5)
            try expectEqual(total.totalTokens, 110)
            try expect(total.hasData)
            try expectEqual(b.costUSD, nil)
            try expect(!b.hasData)
            try expectEqual((b + b).costUSD, nil)
            try expectEqual(ClaudeUsage.sum([nil, nil]), nil)
            try expectEqual(ClaudeUsage.sum([nil, a])?.runs, 1)
            // Un costo negativo o no finito no se cree.
            try expectEqual(ClaudeUsage.run(duration: 1, tokens: nil, cost: -3).costUSD, nil)
        },
        TestCase("usage: decodificación tolerante (campos rotos o faltantes)") {
            let json = #"{"runs":3,"unknownRuns":9,"durationSeconds":"x","inputTokens":-4,"costUSD":1.5}"#
            let usage = try JSONDecoder().decode(ClaudeUsage.self, from: Data(json.utf8))
            try expectEqual(usage.runs, 3)
            try expectEqual(usage.unknownRuns, 3)
            try expectEqual(usage.durationSeconds, 0)
            try expectEqual(usage.inputTokens, 0)
            try expectEqual(usage.costUSD, 1.5)
            let empty = try JSONDecoder().decode(ClaudeUsage.self, from: Data("{}".utf8))
            try expectEqual(empty, .zero)
        },
        TestCase("usage: ClaudeRunner reporta cada intento (también el reintento) al sink del TaskLocal, con etapa") {
            var calls = 0
            let fake = FakeStreamingRunner { _, _, _ in
                calls += 1
                return ([calls == 1 ? invalidLine : usageLine], ok(""))
            }
            let sink = ClaudeUsageSink(parent: nil)
            let center = ClaudeUsageCenter.shared
            let entries = EntryLog()
            center.setObserver { entry in entries.append(entry) }
            defer { center.setObserver(nil) }
            _ = try await sink.measure { try await runner(fake).run(invocation(), as: Answer.self, onAgent: { _ in }) }
            let total = sink.total
            try expectEqual(total.runs, 2)
            try expect(abs((total.costUSD ?? 0) - 0.35) < 1e-9, "\(String(describing: total.costUSD))")
            try expectEqual(total.inputTokens, 1210)
            try expectEqual(total.cacheReadTokens, 80000)
            let mine = entries.all.filter { $0.jobID == sink.id }
            try expectEqual(mine.map(\.stage), ["review", "review"])
        },
        TestCase("usage: una corrida que muere sin línea result guarda solo la duración (sin datos)") {
            let fake = FakeStreamingRunner { _, _, _ in throw PRBarError.timedOut(command: "claude") }
            let sink = ClaudeUsageSink(parent: nil)
            _ = try await expectThrows {
                _ = try await sink.measure { try await runner(fake).run(invocation("=== fix thread:1 ==="), as: Answer.self, onAgent: { _ in }) }
            }
            try expectEqual(sink.total.runs, 1)
            try expectEqual(sink.total.unknownRuns, 1)
            try expectEqual(sink.total.costUSD, nil)
        },
        TestCase("usage: los sinks anidados suman en el padre; el de más afuera es la raíz") {
            let outer = ClaudeUsageSink(parent: nil)
            let inner = ClaudeUsageSink(parent: outer)
            inner.add(.run(duration: 2, tokens: nil, cost: 0.1))
            outer.add(.run(duration: 1, tokens: nil, cost: 0.2))
            try expectEqual(inner.total.runs, 1)
            try expectEqual(outer.total.runs, 2)
            try expect(inner.root === outer)
        },
        TestCase("usage: etapa a partir del encabezado del log") {
            try expectEqual(ClaudeUsageStage.name(fromLogHeader: "=== stage 1 (retry) ==="), "review")
            try expectEqual(ClaudeUsageStage.name(fromLogHeader: "=== stage 2 ==="), "filter")
            try expectEqual(ClaudeUsageStage.name(fromLogHeader: "=== feedback analysis ==="), "analysis")
            try expectEqual(ClaudeUsageStage.name(fromLogHeader: "=== fix thread:PRRT_1 ==="), "fix")
            try expectEqual(ClaudeUsageStage.name(fromLogHeader: "=== CI fix ==="), "CI fix")
            try expectEqual(ClaudeUsageStage.name(fromLogHeader: "=== chat 3 ==="), "chat")
            try expectEqual(ClaudeUsageStage.name(fromLogHeader: "=== instructions chat 2 ==="), "instructions chat")
            try expectEqual(ClaudeUsageStage.name(fromLogHeader: ""), "claude")
        },
        TestCase("usage: JobScheduler anota el trabajo vivo con su uso y lo saca al terminar") {
            let center = ClaudeUsageCenter()
            let scheduler = await JobScheduler<String>(maxConcurrent: 1, usageCenter: center)
            let gate = AsyncGate()
            let seen = EntryLog()
            let activity = ProcessActivity.review("acme/api#7")
            await MainActor.run {
                _ = scheduler.enqueue("k", activity: activity, onStart: {}, work: {
                    center.record(.run(duration: 3, tokens: ClaudeTokenUsage(inputTokens: 5), cost: 0.01), stage: "review")
                    seen.mark(root: ClaudeUsageSink.current?.root.id)
                    await gate.wait()
                }, onComplete: { _ in })
            }
            try await waitFor { center.liveUsage(for: activity)?.runs == 1 }
            try expectEqual(center.liveJobs().count, 1)
            try expectEqual(seen.root, center.liveJobs().keys.first)
            await gate.open()
            try await waitFor { center.liveJobs().isEmpty }
            try expectEqual(center.liveUsage(for: activity), nil)
        },
        TestCase("usage ledger: guarda, recorta a 400 días, tolera JSON roto (.bak) y entradas rotas") {
            let dir = try temporaryDirectory()
            let url = dir.appendingPathComponent("usage.json")
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let ledger = UsageLedger(url: url)
            ledger.append(ClaudeUsageEntry(date: now.addingTimeInterval(-401 * 86_400), jobID: nil, activity: nil, stage: "old",
                                           usage: .run(duration: 1, tokens: nil, cost: 1)), now: now)
            ledger.append(ClaudeUsageEntry(date: now, jobID: nil, activity: .review("o/r#1"), stage: "review",
                                           usage: .run(duration: 2, tokens: nil, cost: 0.5)), now: now)
            try expectEqual(ledger.entries().map(\.stage), ["review"])
            try expectEqual(UsageLedger(url: url).entries().map(\.stage), ["review"])
            // Una entrada rota se saltea; el resto queda.
            var text = try String(contentsOf: url, encoding: .utf8)
            text = text.replacingOccurrences(of: "\"entries\" : [", with: "\"entries\" : [{\"broken\": true},")
            try text.write(to: url, atomically: true, encoding: .utf8)
            try expectEqual(UsageLedger(url: url).entries().count, 1)
            try "{nope".write(to: url, atomically: true, encoding: .utf8)
            try expectEqual(UsageLedger(url: url).entries().count, 0)
            try expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
        },
        TestCase("usage summary: total del mes por tipo y tareas recientes (una por trabajo)") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let nov = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
            let oct = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!
            let job = UUID()
            let entries = [
                ClaudeUsageEntry(date: oct, jobID: nil, activity: .review("o/r#1"), stage: "review", usage: .run(duration: 1, tokens: nil, cost: 9)),
                ClaudeUsageEntry(date: nov, jobID: job, activity: .review("o/r#2"), stage: "review", usage: .run(duration: 60, tokens: ClaudeTokenUsage(inputTokens: 100), cost: 0.4)),
                ClaudeUsageEntry(date: nov.addingTimeInterval(30), jobID: job, activity: .review("o/r#2"), stage: "filter", usage: .run(duration: 30, tokens: nil, cost: 0.1)),
                ClaudeUsageEntry(date: nov.addingTimeInterval(90), jobID: nil, activity: .chat("o/r#2"), stage: "chat", usage: .run(duration: 5, tokens: nil, cost: nil)),
            ]
            let month = UsageSummary.month("2026-11", entries: entries, calendar: calendar)
            try expectEqual(month.usage.runs, 3)
            try expectEqual(month.usage.unknownRuns, 1)
            try expect(abs((month.usage.costUSD ?? 0) - 0.5) < 1e-9)
            try expectEqual(month.byKind["review"]?.runs, 2)
            try expectEqual(month.byKind["chat"]?.runs, 1)
            let tasks = UsageSummary.recentTasks(entries, limit: 2)
            try expectEqual(tasks.count, 2)
            try expectEqual(tasks[0].title, "Chat r#2")
            try expectEqual(tasks[1].id, job)
            try expectEqual(tasks[1].stages, ["review", "filter"])
            try expectEqual(tasks[1].usage.runs, 2)
            try expectEqual(UsageSummary.parseMonth("2026-11"), "2026-11")
            try expectEqual(UsageSummary.parseMonth("2026-13"), nil)
            try expectEqual(UsageSummary.parseMonth("26-11"), nil)
            try expectEqual(UsageSummary.monthKey(nov, calendar: calendar), "2026-11")
        },
        TestCase("usage format: costo, tokens, duración y resumen; sin datos → —") {
            try expectEqual(UsageFormat.cost(nil), "—")
            try expectEqual(UsageFormat.cost(.run(duration: 3, tokens: nil, cost: nil)), "—")
            try expectEqual(UsageFormat.cost(.run(duration: 3, tokens: nil, cost: 0.004)), "<$0.01")
            try expectEqual(UsageFormat.cost(.run(duration: 3, tokens: nil, cost: 1.234)), "$1.23")
            try expectEqual(UsageFormat.count(850), "850")
            try expectEqual(UsageFormat.count(92_100), "92.1k")
            try expectEqual(UsageFormat.count(1_250_000), "1.2M")
            try expectEqual(UsageFormat.duration(seconds: 45), "45s")
            try expectEqual(UsageFormat.duration(seconds: 192), "3m 12s")
            try expectEqual(UsageFormat.duration(seconds: 3900), "1h 05m")
            let mixed = ClaudeUsage.run(duration: 192, tokens: ClaudeTokenUsage(inputTokens: 90_000, outputTokens: 2_100), cost: 0.42)
                + .run(duration: 0, tokens: nil, cost: nil)
            try expectEqual(UsageFormat.summary(mixed), "3m 12s · 92.1k tokens · $0.42 (estimated) · 1 run without usage data")
            try expectEqual(UsageFormat.summary(.run(duration: 5, tokens: nil, cost: nil)), "5s · no usage data")
            try expectEqual(UsageFormat.summary(nil), "—")
        },
        TestCase("usage: registros viejos sin uso se leen con nil (\"—\")") {
            let draft = ReviewDraft(prID: "o/r#1", repo: RepoRef(owner: "o", name: "r"), number: 1, title: "t",
                                    url: URL(string: "https://github.com/o/r/pull/1")!, author: "a", headOid: "h", account: "me",
                                    summary: "s", items: [])
            var object = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(draft)) as! [String: Any]
            try expect(object["usage"] == nil)
            object["usage"] = "roto"
            let decoded = try JSONCoding.decoder.decode(ReviewDraft.self, from: JSONSerialization.data(withJSONObject: object))
            try expectEqual(decoded.usage, nil)
            try expectEqual(decoded.totalUsage, nil)
            let session = try JSONDecoder().decode(ChatSession.self, from: Data(#"{"id":"\#(UUID().uuidString)","prID":"x","kind":"review"}"#.utf8))
            try expectEqual(session.usage, nil)
        },
        TestCase("usage: el review guarda en su draft el uso de sus corridas") { @MainActor in
            let events = QueueEventLog()
            let pipeline = SpendingReviewPipeline()
            var finished: ReviewDraft?
            let queue = ReviewQueue(pipeline: pipeline) { _, result in
                finished = try? result.get()
                events.record(.finished("review"))
            }
            let pr = makePR(number: 4)
            queue.enqueue(ReviewRequest(item: ClassifiedPR(pr: pr, category: .toReview, account: "me"), localPath: nil, baseRef: pr.baseRef))
            try await events.wait(for: [.finished("review")])
            try expectEqual(finished?.usage?.runs, 2)
            try expect(abs((finished?.usage?.costUSD ?? 0) - 0.3) < 1e-9)
        },
    ]
}

final class EntryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ClaudeUsageEntry] = []
    private var _root: UUID?
    func append(_ entry: ClaudeUsageEntry) { lock.withLock { entries.append(entry) } }
    var all: [ClaudeUsageEntry] { lock.withLock { entries } }
    func mark(root: UUID?) { lock.withLock { _root = root } }
    var root: UUID? { lock.withLock { _root } }
}

/// Una puerta que un trabajo espera hasta que el test la abre.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Espera (hasta 5 s) a que `condition` se cumpla.
func waitFor(_ condition: @escaping () async -> Bool, file: StaticString = #fileID, line: UInt = #line) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw TestFailure(description: "\(file):\(line) condition never became true")
}

/// Un review que "gasta" dos corridas de Claude y termina enseguida.
private final class SpendingReviewPipeline: ReviewPipelineRunning, @unchecked Sendable {
    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        ClaudeUsageCenter.shared.record(.run(duration: 10, tokens: nil, cost: 0.1), stage: "review")
        ClaudeUsageCenter.shared.record(.run(duration: 5, tokens: nil, cost: 0.2), stage: "filter")
        let pr = request.item.pr
        return ReviewDraft(prID: pr.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url, author: pr.author,
                           headOid: pr.headOid, account: "me", summary: "s", items: [])
    }
}
