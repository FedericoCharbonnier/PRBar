import Foundation

// El uso de Claude (spec O) que viaja en los resultados de los comandos; el registro (`UsageLedger`) queda en Core.

/// Duración, tokens y costo estimado de una o más corridas de `claude -p` (spec O). Se suma con `+`.
///
/// `costUSD` es la suma de lo que informó Claude Code (`total_cost_usd`); nil si ninguna corrida lo informó. Una corrida
/// sin línea `result` (Stop, timeout, crash, conexión caída) solo aporta su duración y cuenta en `unknownRuns`.
public struct ClaudeUsage: Codable, Equatable, Sendable {
    public var runs: Int
    /// Corridas sin datos de tokens ni costo.
    public var unknownRuns: Int
    public var durationSeconds: Double
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var costUSD: Double?

    public init(runs: Int = 0, unknownRuns: Int = 0, durationSeconds: Double = 0, inputTokens: Int = 0, outputTokens: Int = 0,
                cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0, costUSD: Double? = nil) {
        self.runs = runs
        self.unknownRuns = unknownRuns
        self.durationSeconds = durationSeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.costUSD = costUSD
    }

    public static let zero = ClaudeUsage()

    /// Caps for what is read (from `usage.json`, the history or Claude's output): a corrupted or hand-edited file with
    /// absurd values must not make the app trap when it adds them up (L1). Way above any real usage.
    public static let maxCount = 1_000_000_000_000
    public static let maxSeconds: Double = 1_000_000_000
    public static let maxCostUSD: Double = 1_000_000_000

    public static func clampedCount(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(maxCount) ? maxCount : Int(value)
    }

    public static func clampedCount(_ value: Int) -> Int { min(max(0, value), maxCount) }

    public static func clampedSeconds(_ value: Double) -> Double { value.isFinite ? min(max(0, value), maxSeconds) : 0 }

    public static func clampedCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, maxCostUSD)
    }

    /// `a + b` that stops at `Int.max` instead of trapping.
    public static func plus(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? .max : .min) : sum
    }

    public static func + (lhs: ClaudeUsage, rhs: ClaudeUsage) -> ClaudeUsage {
        let cost: Double? = switch (lhs.costUSD, rhs.costUSD) {
        case (nil, nil): nil
        case let (a, b): (a ?? 0) + (b ?? 0)
        }
        return ClaudeUsage(runs: plus(lhs.runs, rhs.runs), unknownRuns: plus(lhs.unknownRuns, rhs.unknownRuns),
                           durationSeconds: lhs.durationSeconds + rhs.durationSeconds,
                           inputTokens: plus(lhs.inputTokens, rhs.inputTokens), outputTokens: plus(lhs.outputTokens, rhs.outputTokens),
                           cacheCreationTokens: plus(lhs.cacheCreationTokens, rhs.cacheCreationTokens),
                           cacheReadTokens: plus(lhs.cacheReadTokens, rhs.cacheReadTokens), costUSD: cost)
    }

    public static func += (lhs: inout ClaudeUsage, rhs: ClaudeUsage) { lhs = lhs + rhs }

    /// Suma opcionales: nil + nil = nil (una entrada vieja del historial sigue sin datos).
    public static func sum(_ values: [ClaudeUsage?]) -> ClaudeUsage? {
        let present = values.compactMap { $0 }
        return present.isEmpty ? nil : present.reduce(.zero, +)
    }

    /// Alguna corrida trajo tokens o costo.
    public var hasData: Bool { runs > unknownRuns }
    public var totalTokens: Int { Self.plus(Self.plus(inputTokens, outputTokens), Self.plus(cacheCreationTokens, cacheReadTokens)) }

    private enum CodingKeys: String, CodingKey {
        case runs, unknownRuns, durationSeconds, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, costUSD
    }

    /// Tolerante: un campo que falta o está roto vale 0 (o nil el costo); los valores se acotan (`maxCount`…).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) -> Int { Self.clampedCount((try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0) }
        runs = int(.runs)
        unknownRuns = min(int(.unknownRuns), runs)
        durationSeconds = Self.clampedSeconds((try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)) ?? 0)
        inputTokens = int(.inputTokens)
        outputTokens = int(.outputTokens)
        cacheCreationTokens = int(.cacheCreationTokens)
        cacheReadTokens = int(.cacheReadTokens)
        costUSD = Self.clampedCost((try? c.decodeIfPresent(Double.self, forKey: .costUSD)) ?? nil)
    }
}

/// Una tarea de Activity con su uso: un trabajo de `JobScheduler` (o una corrida suelta).
public struct UsageTask: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var activity: ProcessActivity?
    public var stages: [String]
    public var startedAt: Date
    public var finishedAt: Date
    public var usage: ClaudeUsage

    public init(id: UUID, activity: ProcessActivity?, stages: [String], startedAt: Date, finishedAt: Date, usage: ClaudeUsage) {
        self.id = id
        self.activity = activity
        self.stages = stages
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.usage = usage
    }

    public var title: String { activity?.title ?? "Claude" }
}

/// El total de un mes (spec O.2), por tipo de tarea.
public struct UsageMonth: Codable, Equatable, Sendable {
    /// `YYYY-MM`.
    public var month: String
    public var usage: ClaudeUsage
    /// Por `ProcessActivity.Kind` (`rawValue`; "other" fuera de una tarea).
    public var byKind: [String: ClaudeUsage]

    public init(month: String, usage: ClaudeUsage, byKind: [String: ClaudeUsage]) {
        self.month = month
        self.usage = usage
        self.byKind = byKind
    }
}

/// Cómo se muestra el uso en la app y en la CLI (spec O.2).
public enum UsageFormat {
    public static let note = "Estimated from what Claude Code reports. On a Claude subscription you may not be billed per token."

    /// "$0.42", "<$0.01", "$12.30"; "—" sin datos.
    public static func cost(_ usage: ClaudeUsage?) -> String {
        guard let usage, usage.hasData, let value = usage.costUSD else { return "—" }
        return cost(value)
    }

    public static func cost(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }

    /// "12.3k", "1.2M", "850"; "—" sin datos.
    public static func tokens(_ usage: ClaudeUsage?) -> String {
        guard let usage, usage.hasData else { return "—" }
        return count(usage.totalTokens)
    }

    public static func count(_ value: Int) -> String {
        switch value {
        case ..<1000: "\(value)"
        case ..<1_000_000: String(format: "%.1fk", Double(value) / 1000)
        default: String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }

    /// "45s", "3m 12s", "1h 05m"; "—" sin corridas.
    public static func duration(_ usage: ClaudeUsage?) -> String {
        guard let usage, usage.runs > 0 else { return "—" }
        return duration(seconds: usage.durationSeconds)
    }

    public static func duration(seconds: Double) -> String {
        let total = Int(ClaudeUsage.clampedSeconds(seconds).rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
    }

    /// "1.2k in · 340 out · 85.0k cache" (solo con datos).
    public static func tokenBreakdown(_ usage: ClaudeUsage) -> String {
        var parts = ["\(count(usage.inputTokens)) in", "\(count(usage.outputTokens)) out"]
        let cache = usage.cacheCreationTokens + usage.cacheReadTokens
        if cache > 0 { parts.append("\(count(cache)) cache") }
        return parts.joined(separator: " · ")
    }

    /// "3m 12s · 92.1k tokens · $0.42 (estimated)"; con corridas sin datos lo agrega. "—" sin corridas.
    public static func summary(_ usage: ClaudeUsage?) -> String {
        guard let usage, usage.runs > 0 else { return "—" }
        var parts = [duration(seconds: usage.durationSeconds)]
        if usage.hasData {
            parts.append("\(count(usage.totalTokens)) tokens")
            parts.append(usage.costUSD.map { "\(cost($0)) (estimated)" } ?? "cost unknown")
        } else {
            parts.append("no usage data")
        }
        if usage.unknownRuns > 0 && usage.hasData {
            parts.append("\(usage.unknownRuns) run\(usage.unknownRuns == 1 ? "" : "s") without usage data")
        }
        return parts.joined(separator: " · ")
    }
}
