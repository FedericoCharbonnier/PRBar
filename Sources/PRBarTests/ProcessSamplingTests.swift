import Foundation
import PRBarCore

/// Árbol y contadores escritos a mano.
final class FakeProcessInfo: ProcessInfoProviding, @unchecked Sendable {
    private let lock = NSLock()
    var children: [Int32: [Int32]] = [:]
    var stats: [Int32: ProcessStat] = [:]
    private(set) var statCalls = 0

    func children(of pid: Int32) -> [Int32] { lock.withLock { children[pid] ?? [] } }
    func stat(of pid: Int32) -> ProcessStat? { lock.withLock { statCalls += 1; return stats[pid] } }
    func set(_ pid: Int32, cpu: UInt64, memory: UInt64, name: String = "x") {
        lock.withLock { stats[pid] = ProcessStat(pid: pid, name: name, cpuNanos: cpu, memoryBytes: memory, startedAt: t0) }
    }
}

enum ProcessSamplingTests {
    static let cases: [TestCase] = [
        TestCase("sampling: el árbol junta hijos y nietos sin repetir ni colgarse con un ciclo") {
            let info = FakeProcessInfo()
            info.children = [1: [2, 3], 2: [4], 4: [2]]   // 4 → 2: un ciclo (pid reusado)
            let tree = ProcessTree.descendants(of: 1, provider: info)
            try expectEqual(Set(tree.keys), [1, 2, 3, 4])
            try expectEqual(tree[4], 2)
            try expectEqual(tree[1], 0)
        },
        TestCase("sampling: CPU = delta de tiempo de CPU sobre el tiempo entre muestras, sumado; RAM sumada") {
            let info = FakeProcessInfo()
            info.children = [1: [2]]
            info.set(1, cpu: 1_000_000_000, memory: 100, name: "PRBar")
            info.set(2, cpu: 2_000_000_000, memory: 300, name: "claude")
            let sampler = ProcessSampler(provider: info, root: 1)
            let first = sampler.sample(at: t0)
            info.set(1, cpu: 1_100_000_000, memory: 120, name: "PRBar")      // +0,1 s en 2 s = 5 %
            info.set(2, cpu: 3_000_000_000, memory: 500, name: "claude")     // +1 s en 2 s = 50 %
            let second = sampler.sample(at: t0.addingTimeInterval(2))
            let registered = [Int32(2): RegisteredProcess(pid: 2, executable: "claude", activity: .review("acme/api#317"), startedAt: t0)]
            let usage = ResourceMeter.usage(previous: first, current: second, registered: registered)
            try expect(abs(usage.cpuPercent - 55) < 0.001, "cpu \(usage.cpuPercent)")
            try expectEqual(usage.memoryBytes, 620)
            let claude = usage.processes.first { $0.pid == 2 }
            try expectEqual(claude?.label, "Review api#317 · claude")
            try expectEqual(usage.processes.first { $0.pid == 1 }?.label, "PRBar")
        },
        TestCase("sampling: un nieto hereda la tarea del ancestro anotado; uno sin tarea es PRBar · nombre") {
            let info = FakeProcessInfo()
            info.children = [1: [2, 5], 2: [3]]
            for pid: Int32 in [1, 2, 3, 5] { info.set(pid, cpu: 0, memory: 1, name: pid == 5 ? "git" : "node") }
            let sample = ProcessSampler(provider: info, root: 1).sample(at: t0)
            let registered = [Int32(2): RegisteredProcess(pid: 2, executable: "claude", activity: .respond("acme/web#2"), startedAt: t0)]
            let usage = ResourceMeter.usage(previous: nil, current: sample, registered: registered)
            try expectEqual(usage.processes.first { $0.pid == 3 }?.activity, .respond("acme/web#2"))
            try expectEqual(usage.processes.first { $0.pid == 5 }?.label, "PRBar · git")
        },
        TestCase("sampling: un proceso que nació entre muestras aporta todo su tiempo; uno remoto no suma") {
            let info = FakeProcessInfo()
            info.children = [1: []]
            info.set(1, cpu: 0, memory: 10)
            let sampler = ProcessSampler(provider: info, root: 1)
            let first = sampler.sample(at: t0)
            info.children = [1: [7, 8]]
            info.set(7, cpu: 500_000_000, memory: 40, name: "git")
            info.set(8, cpu: 900_000_000, memory: 30, name: "ssh")
            let second = sampler.sample(at: t0.addingTimeInterval(1))
            let registered = [Int32(8): RegisteredProcess(pid: 8, executable: "ssh", activity: ProcessActivity.review("acme/api#1").on(host: "devbox"), startedAt: t0)]
            let usage = ResourceMeter.usage(previous: first, current: second, registered: registered)
            try expect(abs(usage.cpuPercent - 50) < 0.001, "cpu \(usage.cpuPercent)")
            try expectEqual(usage.memoryBytes, 50)
            let remote = usage.processes.first { $0.pid == 8 }
            try expectEqual(remote?.remoteHost, "devbox")
            try expectEqual(remote?.cpuPercent, 0)
        },
        TestCase("sampling: libproc ve a un hijo de verdad con su nombre, CPU y memoria") {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["5"]
            try child.run()
            defer { child.terminate() }
            let provider = LiveProcessInfoProvider()
            let children = provider.children(of: getpid())
            try expect(children.contains(child.processIdentifier), "hijos: \(children)")
            let stat = provider.stat(of: child.processIdentifier)
            try expectEqual(stat?.name, "sleep")
            try expect((stat?.memoryBytes ?? 0) > 0)
            try expect(stat?.startedAt != nil)
            let me = provider.stat(of: getpid())
            try expect((me?.cpuNanos ?? 0) > 0)
            try expectEqual(provider.stat(of: 999_999), nil)
        },
    ]
}
