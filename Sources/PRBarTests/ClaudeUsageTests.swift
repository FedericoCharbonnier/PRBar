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
