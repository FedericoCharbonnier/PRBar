import Foundation
import Observation
import PRBarWire

/// `activity` (design §activity): the Mac's load, running jobs with Stop, and Claude's cost this month. The topic is
/// subscribed only while the screen is visible (the Mac recomputes it every 5 s while someone listens).
@MainActor @Observable
public final class ActivityModel {
    public struct Tile: Identifiable, Equatable, Sendable {
        public enum Tone: Sendable { case green, orange, accent }
        public var id: String { title }
        public var symbol: String
        public var title: String
        public var value: String
        public var caption: String?
        public var fraction: Double
        public var tone: Tone
    }

    public struct Task: Identifiable, Equatable, Sendable {
        public var id: String { pr + kind }
        public var pr: String
        public var kind: String
        public var title: String
        public var subtitle: String
    }

    public struct CostRow: Identifiable, Equatable, Sendable {
        public enum Tone: Sendable { case violet, accent, tertiary }
        public var id: String { title }
        public var title: String
        public var count: String
        public var cost: String
        public var fraction: Double
        public var tone: Tone
    }

    public let connection: RemoteConnection
    public var alert: String?
    @ObservationIgnored private let runner: ActionRunner
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar

    public init(connection: RemoteConnection, runner: ActionRunner, now: @escaping () -> Date = Date.init,
                calendar: Calendar = .current) {
        self.connection = connection
        self.runner = runner
        self.now = now
        self.calendar = calendar
    }

    public func appear() async { await connection.retain(Topic.activity) }
    public func disappear() async { await connection.release(Topic.activity) }

    public var activity: RemoteActivity? { connection.store.activity }
    public var isOffline: Bool { connection.store.isStale }

    public var tiles: [Tile] {
        guard let activity else { return [] }
        let usage = activity.resources.usage
        let system = activity.system
        let memory = system?.memoryUsedBytes ?? usage.memoryBytes
        let disk = system.map { Int64($0.diskFreeBytes) } ?? activity.resources.disk.total
        return [
            Tile(symbol: "cpu", title: "CPU", value: "\(Int(usage.cpuPercent.rounded()))%",
                 caption: system.map { "\($0.cores) cores" }, fraction: min(usage.cpuPercent / 100, 1), tone: .green),
            Tile(symbol: "memorychip", title: "Memory", value: Format.bytes(Int64(memory)),
                 caption: system.map { "of \(Format.bytes(Int64($0.memoryTotalBytes)))" },
                 fraction: system.map { Double($0.memoryUsedBytes) / Double(max($0.memoryTotalBytes, 1)) } ?? 0,
                 tone: .orange),
            Tile(symbol: "internaldrive", title: "Disk", value: Format.bytes(disk),
                 caption: system.map { "free of \(Format.bytes($0.diskTotalBytes).replacingOccurrences(of: " GB", with: ""))" },
                 fraction: system.map { 1 - Double($0.diskFreeBytes) / Double(max($0.diskTotalBytes, 1)) } ?? 0,
                 tone: .accent),
        ]
    }

    public var running: [Task] {
        if let jobs = activity?.running {
            return jobs.map { job in
                var parts = [job.detail, Format.clock(now().timeIntervalSince(job.startedAt))]
                if let cost = job.costUSD { parts.append("~" + Format.money(cost)) }
                return Task(pr: job.pr, kind: job.kind, title: job.title, subtitle: parts.joined(separator: " · "))
            }
        }
        return (connection.store.home?.status.jobs ?? []).map { job in
            let verb = job.kind == "review" ? "Reviewing" : "Responding on"
            return Task(pr: job.pr, kind: job.kind, title: "\(verb) \(Format.shortRef(job.pr))", subtitle: job.phase)
        }
    }

    public func stop(_ task: Task) async {
        let command: AppCommand = task.kind == "review" ? .reviewCancel(pr: task.pr) : .respondCancel(pr: task.pr)
        do { try await runner.run(command) } catch { alert = error.message }
    }

    // MARK: Claude this month

    public var monthTotal: String? {
        activity?.usage?.month.usage.costUSD.map(Format.money)
    }

    public var monthCaption: String {
        guard let key = activity?.usage?.month.month else { return "estimated" }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return "estimated" }
        let name = calendar.standaloneMonthSymbols[(parts[1] - 1) % 12]
        return "estimated · \(name)"
    }

    public var costRows: [CostRow] {
        guard let month = activity?.usage?.month else { return [] }
        let total = max(month.usage.costUSD ?? 0, 0.0001)
        func row(_ key: String, _ title: String, _ tone: CostRow.Tone, messages: Bool = false) -> CostRow? {
            guard let usage = month.byKind[key] else { return nil }
            let count = messages ? "\(usage.messages ?? usage.runs) msgs" : "\(usage.runs)"
            return CostRow(title: title, count: count, cost: Format.money(usage.costUSD ?? 0),
                           fraction: (usage.costUSD ?? 0) / total, tone: tone)
        }
        return [row("review", "Reviews", .violet), row("respond", "Fixes", .accent),
                row("chat", "Chat", .tertiary, messages: true)].compactMap { $0 }
    }
}
