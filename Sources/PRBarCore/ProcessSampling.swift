import Darwin
import Foundation

/// Lo que se lee de un proceso.
public struct ProcessStat: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    /// Tiempo de CPU acumulado (usuario + sistema), en nanosegundos.
    public var cpuNanos: UInt64
    /// `ri_phys_footprint` (la "Memory" de Activity Monitor).
    public var memoryBytes: UInt64
    public var startedAt: Date?

    public init(pid: Int32, name: String, cpuNanos: UInt64, memoryBytes: UInt64, startedAt: Date?) {
        self.pid = pid
        self.name = name
        self.cpuNanos = cpuNanos
        self.memoryBytes = memoryBytes
        self.startedAt = startedAt
    }
}

public protocol ProcessInfoProviding: Sendable {
    func children(of pid: Int32) -> [Int32]
    func stat(of pid: Int32) -> ProcessStat?
}

/// La app y sus descendientes: pid → pid del padre (0 para la raíz).
public enum ProcessTree {
    public static func descendants(of root: Int32, provider: ProcessInfoProviding, limit: Int = 2048) -> [Int32: Int32] {
        var parents: [Int32: Int32] = [root: 0]
        var queue = [root]
        while !queue.isEmpty, parents.count < limit {
            let pid = queue.removeFirst()
            for child in provider.children(of: pid) where child > 0 && parents[child] == nil {
                parents[child] = pid
                queue.append(child)
            }
        }
        return parents
    }
}

public struct ProcessSample: Sendable {
    public var date: Date
    public var parents: [Int32: Int32]
    public var stats: [Int32: ProcessStat]
}

public struct ProcessSampler: Sendable {
    let provider: ProcessInfoProviding
    let root: Int32

    public init(provider: ProcessInfoProviding, root: Int32 = getpid()) {
        self.provider = provider
        self.root = root
    }

    public func sample(at date: Date = Date()) -> ProcessSample {
        let parents = ProcessTree.descendants(of: root, provider: provider)
        var stats: [Int32: ProcessStat] = [:]
        for pid in parents.keys { stats[pid] = provider.stat(of: pid) }
        return ProcessSample(date: date, parents: parents, stats: stats)
    }
}

public struct ProcessUsage: Codable, Equatable, Sendable, Identifiable {
    public var pid: Int32
    public var name: String
    public var activity: ProcessActivity?
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var startedAt: Date?
    public var isApp: Bool

    public var id: Int32 { pid }
    /// Los trabajos remotos (Plan 14) se muestran "on <host>" y sin CPU/RAM locales.
    public var remoteHost: String? { activity?.host }
    public var label: String { isApp ? "PRBar" : "\(activity?.title ?? "PRBar") · \(name)" }
}

public struct ResourceUsage: Codable, Equatable, Sendable {
    /// % de un núcleo (como Activity Monitor; puede pasar 100).
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var processes: [ProcessUsage]
    public var sampledAt: Date

    public init(cpuPercent: Double, memoryBytes: UInt64, processes: [ProcessUsage], sampledAt: Date) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.processes = processes
        self.sampledAt = sampledAt
    }
}

public enum ResourceMeter {
    /// `previous == nil`: CPU 0 (no hay con qué comparar). Los procesos de un trabajo remoto no suman.
    public static func usage(previous: ProcessSample?, current: ProcessSample,
                             registered: [Int32: RegisteredProcess]) -> ResourceUsage {
        let elapsed = previous.map { current.date.timeIntervalSince($0.date) } ?? 0
        var rows: [ProcessUsage] = []
        for (pid, stat) in current.stats {
            let activity = activity(of: pid, parents: current.parents, registered: registered)
            var cpu = 0.0
            if let previous, elapsed > 0 {
                let before = previous.stats[pid].map(\.cpuNanos) ?? 0
                let delta = stat.cpuNanos >= before ? stat.cpuNanos - before : 0
                cpu = Double(delta) / (elapsed * 1_000_000_000) * 100
            }
            let remote = activity?.host != nil
            rows.append(ProcessUsage(pid: pid, name: stat.name, activity: activity, cpuPercent: remote ? 0 : cpu,
                                     memoryBytes: remote ? 0 : stat.memoryBytes, startedAt: stat.startedAt,
                                     isApp: current.parents[pid] == 0))
        }
        rows.sort { ($0.isApp ? 0 : 1, $0.activity?.title ?? "~", $0.pid) < ($1.isApp ? 0 : 1, $1.activity?.title ?? "~", $1.pid) }
        return ResourceUsage(cpuPercent: rows.map(\.cpuPercent).reduce(0, +), memoryBytes: rows.map(\.memoryBytes).reduce(0, +),
                             processes: rows, sampledAt: current.date)
    }

    /// La del propio proceso o la del ancestro anotado más cercano.
    static func activity(of pid: Int32, parents: [Int32: Int32], registered: [Int32: RegisteredProcess]) -> ProcessActivity? {
        var current = pid
        var steps = 0
        while current > 0, steps < 64 {
            if let activity = registered[current]?.activity { return activity }
            current = parents[current] ?? 0
            steps += 1
        }
        return nil
    }
}

/// `proc_listchildpids`, `proc_pid_rusage` y `proc_pidinfo` (sin `ps`). Los tiempos de `rusage_info` vienen en
/// unidades de `mach_absolute_time` (en Apple Silicon no son nanosegundos): se convierten con `mach_timebase_info`.
public struct LiveProcessInfoProvider: ProcessInfoProviding {
    public init() {}

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        let base = timebase
        guard base.denom != 0 else { return ticks }
        return ticks / UInt64(base.denom) * UInt64(base.numer) + ticks % UInt64(base.denom) * UInt64(base.numer) / UInt64(base.denom)
    }

    public func children(of pid: Int32) -> [Int32] {
        var capacity = 256
        while capacity <= 65_536 {
            var buffer = [Int32](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
            if count < 0 { return [] }
            if Int(count) < capacity { return buffer.prefix(Int(count)).filter { $0 > 0 } }
            capacity *= 2
        }
        return []
    }

    public func stat(of pid: Int32) -> ProcessStat? {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard status == 0 else { return nil }
        var name = [CChar](repeating: 0, count: 1024)
        let length = proc_name(pid, &name, UInt32(name.count))
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let started: Date? = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size
            ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
            : nil
        return ProcessStat(pid: pid, name: length > 0 ? String(cString: name) : "?",
                           cpuNanos: Self.nanoseconds(usage.ri_user_time &+ usage.ri_system_time),
                           memoryBytes: usage.ri_phys_footprint, startedAt: started)
    }
}
