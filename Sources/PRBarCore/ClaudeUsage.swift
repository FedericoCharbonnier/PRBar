import Foundation
import os

/// Lo que dice la línea `result` del `stream-json` sobre los tokens de una corrida (spec O.4.1).
public struct ClaudeTokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    /// `{"input_tokens": …, "output_tokens": …, "cache_creation_input_tokens": …, "cache_read_input_tokens": …}`;
    /// nil si no es un objeto o no trae ninguno de los cuatro.
    static func parse(_ value: Any?) -> ClaudeTokenUsage? {
        guard let object = value as? [String: Any] else { return nil }
        func int(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
        let values = [int("input_tokens"), int("output_tokens"), int("cache_creation_input_tokens"), int("cache_read_input_tokens")]
        guard values.contains(where: { $0 != nil }) else { return nil }
        return ClaudeTokenUsage(inputTokens: max(0, values[0] ?? 0), outputTokens: max(0, values[1] ?? 0),
                                cacheCreationTokens: max(0, values[2] ?? 0), cacheReadTokens: max(0, values[3] ?? 0))
    }
}

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

    /// Una corrida. Sin `tokens` ni `cost` es una corrida sin datos.
    public static func run(duration: TimeInterval, tokens: ClaudeTokenUsage?, cost: Double?) -> ClaudeUsage {
        let cost = cost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return ClaudeUsage(runs: 1, unknownRuns: tokens == nil && cost == nil ? 1 : 0, durationSeconds: max(0, duration),
                           inputTokens: tokens?.inputTokens ?? 0, outputTokens: tokens?.outputTokens ?? 0,
                           cacheCreationTokens: tokens?.cacheCreationTokens ?? 0, cacheReadTokens: tokens?.cacheReadTokens ?? 0,
                           costUSD: cost)
    }

    public static func + (lhs: ClaudeUsage, rhs: ClaudeUsage) -> ClaudeUsage {
        let cost: Double? = switch (lhs.costUSD, rhs.costUSD) {
        case (nil, nil): nil
        case let (a, b): (a ?? 0) + (b ?? 0)
        }
        return ClaudeUsage(runs: lhs.runs + rhs.runs, unknownRuns: lhs.unknownRuns + rhs.unknownRuns,
                           durationSeconds: lhs.durationSeconds + rhs.durationSeconds,
                           inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens,
                           cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
                           cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens, costUSD: cost)
    }

    public static func += (lhs: inout ClaudeUsage, rhs: ClaudeUsage) { lhs = lhs + rhs }

    /// Suma opcionales: nil + nil = nil (una entrada vieja del historial sigue sin datos).
    public static func sum(_ values: [ClaudeUsage?]) -> ClaudeUsage? {
        let present = values.compactMap { $0 }
        return present.isEmpty ? nil : present.reduce(.zero, +)
    }

    /// Alguna corrida trajo tokens o costo.
    public var hasData: Bool { runs > unknownRuns }
    public var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }

    private enum CodingKeys: String, CodingKey {
        case runs, unknownRuns, durationSeconds, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, costUSD
    }

    /// Tolerante: un campo que falta o está roto vale 0 (o nil el costo).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) -> Int { max(0, (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0) }
        runs = int(.runs)
        unknownRuns = min(int(.unknownRuns), runs)
        durationSeconds = max(0, (try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)) ?? 0)
        inputTokens = int(.inputTokens)
        outputTokens = int(.outputTokens)
        cacheCreationTokens = int(.cacheCreationTokens)
        cacheReadTokens = int(.cacheReadTokens)
        costUSD = (try? c.decodeIfPresent(Double.self, forKey: .costUSD)) ?? nil
    }
}

/// Junta el uso de las corridas de Claude de un trabajo o de un registro (spec O.4.1). Se pone con
/// `ClaudeUsageSink.current` (un `@TaskLocal`): `ClaudeRunner` le suma cada corrida, y cada sink se la pasa a su
/// padre, así un registro y el trabajo que lo contiene la cuentan los dos.
public final class ClaudeUsageSink: Sendable {
    @TaskLocal public static var current: ClaudeUsageSink?

    public let id: UUID
    public let parent: ClaudeUsageSink?
    private let state = OSAllocatedUnfairLock(initialState: ClaudeUsage.zero)

    public init(id: UUID = UUID(), parent: ClaudeUsageSink? = ClaudeUsageSink.current) {
        self.id = id
        self.parent = parent
    }

    public var total: ClaudeUsage { state.withLock { $0 } }

    /// El de más afuera (el del trabajo de `JobScheduler`, si hay).
    public var root: ClaudeUsageSink { parent?.root ?? self }

    public func add(_ usage: ClaudeUsage) {
        state.withLock { $0 += usage }
        parent?.add(usage)
    }

    /// Corre `body` con este sink como el actual.
    public func measure<T>(_ body: () async throws -> T) async rethrows -> T {
        try await Self.$current.withValue(self, operation: body)
    }
}

/// Una corrida de Claude en el libro de uso (`usage.json`).
public struct ClaudeUsageEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Cuando terminó.
    public var date: Date
    /// El trabajo de `JobScheduler` (una tarea de Activity); nil fuera de un trabajo.
    public var jobID: UUID?
    public var activity: ProcessActivity?
    /// "review", "filter", "analysis", "fix", "CI fix", "chat"…
    public var stage: String
    public var usage: ClaudeUsage

    public init(id: UUID = UUID(), date: Date, jobID: UUID?, activity: ProcessActivity?, stage: String, usage: ClaudeUsage) {
        self.id = id
        self.date = date
        self.jobID = jobID
        self.activity = activity
        self.stage = stage
        self.usage = usage
    }
}

/// Adonde van las corridas: los trabajos vivos (la columna Cost de "Running now") y el observador que pone la app
/// (el libro). Seguro entre hilos.
public final class ClaudeUsageCenter: Sendable {
    public static let shared = ClaudeUsageCenter()

    public struct LiveJob: Equatable, Sendable {
        public var activity: ProcessActivity?
        public var startedAt: Date
        public var usage: ClaudeUsage
    }

    private struct State {
        var observer: (@Sendable (ClaudeUsageEntry) -> Void)?
        var live: [UUID: LiveJob] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func setObserver(_ observer: (@Sendable (ClaudeUsageEntry) -> Void)?) {
        state.withLock { $0.observer = observer }
    }

    public func beginJob(_ id: UUID, activity: ProcessActivity?, at date: Date = Date()) {
        state.withLock { $0.live[id] = LiveJob(activity: activity, startedAt: date, usage: .zero) }
    }

    public func endJob(_ id: UUID) {
        state.withLock { _ = $0.live.removeValue(forKey: id) }
    }

    public func liveJobs() -> [UUID: LiveJob] { state.withLock { $0.live } }

    /// Lo ya terminado de los trabajos vivos de esa tarea; nil si no hay ninguno o ninguna corrida terminó.
    public func liveUsage(for activity: ProcessActivity) -> ClaudeUsage? {
        let usages = liveJobs().values.filter { $0.activity == activity }.map(\.usage)
        let total = usages.reduce(ClaudeUsage.zero, +)
        return total.runs == 0 ? nil : total
    }

    /// Una corrida terminó: se suma a los sinks del `@TaskLocal`, al trabajo vivo y se le avisa al observador.
    public func record(_ usage: ClaudeUsage, stage: String, sink: ClaudeUsageSink? = ClaudeUsageSink.current,
                       activity: ProcessActivity? = ProcessActivity.current, date: Date = Date()) {
        sink?.add(usage)
        let jobID = sink?.root.id
        let observer = state.withLock { state -> (@Sendable (ClaudeUsageEntry) -> Void)? in
            if let jobID, state.live[jobID] != nil { state.live[jobID]?.usage += usage }
            return state.observer
        }
        observer?(ClaudeUsageEntry(date: date, jobID: jobID, activity: activity, stage: stage, usage: usage))
    }
}

/// El nombre de la etapa a partir del encabezado del log de la corrida (`"=== stage 1 (retry) ==="` → `"review"`).
public enum ClaudeUsageStage {
    public static func name(fromLogHeader header: String) -> String {
        var text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("===") { text = String(text.dropFirst(3)) }
        if text.hasSuffix("===") { text = String(text.dropLast(3)) }
        text = text.replacingOccurrences(of: "(retry)", with: "").trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        if lower.hasPrefix("stage 1") || lower.hasPrefix("review") { return "review" }
        if lower.hasPrefix("stage 2") || lower.hasPrefix("filter") { return "filter" }
        if lower.hasPrefix("feedback analysis") { return "analysis" }
        if lower.hasPrefix("ci fix") { return "CI fix" }
        if lower.hasPrefix("fix") { return "fix" }
        if lower.hasPrefix("instructions chat") { return "instructions chat" }
        if lower.hasPrefix("chat") { return "chat" }
        return text.isEmpty ? "claude" : String(text.prefix(40))
    }
}

// MARK: - Libro (usage.json)

/// El libro de uso (spec O.4.2): `{"version":1,"entries":[…]}`, escrito solo por la app. Guarda 400 días (y a lo sumo
/// `maxEntries`). Un JSON roto se copia a `usage.json.bak` y se arranca vacío; una entrada rota se saltea.
public final class UsageLedger: Sendable {
    public static let retentionDays = 400
    public static let maxEntries = 50_000

    private struct File: Codable {
        var version = 1
        var entries: [ClaudeUsageEntry]

        init(entries: [ClaudeUsageEntry]) { self.entries = entries }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            entries = (try c.decodeIfPresent(LossyArray<ClaudeUsageEntry>.self, forKey: .entries))?.elements ?? []
        }
    }

    private let url: URL
    private let state = OSAllocatedUnfairLock<[ClaudeUsageEntry]?>(initialState: nil)

    public init(url: URL = AppPaths.usageFile) {
        self.url = url
    }

    public func entries() -> [ClaudeUsageEntry] {
        state.withLock { cached in
            if let cached { return cached }
            let loaded = load()
            cached = loaded
            return loaded
        }
    }

    /// Agrega, recorta y guarda. Nunca lanza (un error se loguea).
    public func append(_ entry: ClaudeUsageEntry, now: Date = Date()) {
        state.withLock { cached in
            var entries = cached ?? load()
            entries.append(entry)
            entries = Self.pruned(entries, now: now)
            cached = entries
            save(entries)
        }
    }

    static func pruned(_ entries: [ClaudeUsageEntry], now: Date) -> [ClaudeUsageEntry] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let kept = entries.filter { $0.date >= cutoff }
        return kept.count > maxEntries ? Array(kept.suffix(maxEntries)) : kept
    }

    private func load() -> [ClaudeUsageEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONCoding.decoder.decode(File.self, from: data).entries
        } catch {
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            AppLog.write("Usage: \(url.lastPathComponent) couldn't be read (\(error)); starting empty, copy in \(backup.lastPathComponent)")
            return []
        }
    }

    private func save(_ entries: [ClaudeUsageEntry]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONCoding.encoder.encode(File(entries: entries)).write(to: url, options: .atomic)
        } catch {
            AppLog.write("Usage: couldn't save \(url.path): \(error)")
        }
    }
}

// MARK: - Resúmenes

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

public enum UsageSummary {
    /// `YYYY-MM` de `date` en el calendario local.
    public static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// `YYYY-MM` válido (mes 1–12) o nil.
    public static func parseMonth(_ text: String) -> String? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), year >= 2000, (1...12).contains(month) else { return nil }
        return String(format: "%04d-%02d", year, month)
    }

    public static func month(_ key: String, entries: [ClaudeUsageEntry], calendar: Calendar = .current) -> UsageMonth {
        let inMonth = entries.filter { monthKey($0.date, calendar: calendar) == key }
        var byKind: [String: ClaudeUsage] = [:]
        for entry in inMonth { byKind[entry.activity?.kind.rawValue ?? "other", default: .zero] += entry.usage }
        return UsageMonth(month: key, usage: inMonth.map(\.usage).reduce(.zero, +), byKind: byKind)
    }

    /// Las últimas `limit` tareas, de la más nueva a la más vieja: las corridas de un mismo trabajo van juntas.
    public static func recentTasks(_ entries: [ClaudeUsageEntry], limit: Int = 20) -> [UsageTask] {
        var tasks: [UUID: UsageTask] = [:]
        for entry in entries {
            let key = entry.jobID ?? entry.id
            if var task = tasks[key] {
                task.usage += entry.usage
                if !task.stages.contains(entry.stage) { task.stages.append(entry.stage) }
                task.startedAt = min(task.startedAt, entry.date.addingTimeInterval(-entry.usage.durationSeconds))
                task.finishedAt = max(task.finishedAt, entry.date)
                task.activity = task.activity ?? entry.activity
                tasks[key] = task
            } else {
                tasks[key] = UsageTask(id: key, activity: entry.activity, stages: [entry.stage],
                                       startedAt: entry.date.addingTimeInterval(-entry.usage.durationSeconds),
                                       finishedAt: entry.date, usage: entry.usage)
            }
        }
        return Array(tasks.values.sorted { $0.finishedAt > $1.finishedAt }.prefix(max(0, limit)))
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
        let total = Int(seconds.rounded())
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
