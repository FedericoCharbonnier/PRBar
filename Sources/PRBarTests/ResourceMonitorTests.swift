import Foundation
import PRBarCore

private func monitor(_ info: FakeProcessInfo, scans: ScanCounter, interval: Duration = .milliseconds(20)) async -> ResourceMonitor {
    await MainActor.run {
        ResourceMonitor(sampler: ProcessSampler(provider: info, root: 1), registry: ProcessRegistry(), interval: interval,
                        diskScan: { scans.bump(); return DiskUsage(items: [], scannedAt: Date()) })
    }
}

/// Un reloj que el test mueve.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

enum ResourceMonitorTests {
    static let cases: [TestCase] = [
        TestCase("resources: no muestrea si no hay nada abierto; sí mientras algo está abierto; para al cerrarse") {
            let info = FakeProcessInfo()
            info.children = [1: []]
            info.set(1, cpu: 0, memory: 1)
            let scans = ScanCounter()
            let monitor = await monitor(info, scans: scans)
            try await Task.sleep(for: .milliseconds(100))
            let idleCalls = info.statCalls
            try expectEqual(idleCalls, 0)
            await MainActor.run { monitor.setVisible("popover", true) }
            try await Task.sleep(for: .milliseconds(150))
            let sampling = await MainActor.run { monitor.isSampling }
            try expect(sampling)
            let open = info.statCalls
            try expect(open >= 3, "llamadas \(open)")
            await MainActor.run { monitor.setVisible("activity", true); monitor.setVisible("popover", false) }
            let stillSampling = await MainActor.run { monitor.isSampling }
            try expect(stillSampling)
            await MainActor.run { monitor.setVisible("activity", false) }
            let stopped = await MainActor.run { monitor.isSampling }
            try expect(!stopped)
            let atStop = info.statCalls
            try await Task.sleep(for: .milliseconds(100))
            let later = info.statCalls
            try expect(later - atStop <= 1, "siguió muestreando: \(atStop) → \(later)")
        },
        TestCase("resources: el disco se calcula al abrir, a lo sumo cada 60 s, y otra vez al terminar un trabajo") {
            let info = FakeProcessInfo()
            info.children = [1: []]
            info.set(1, cpu: 0, memory: 1)
            let scans = ScanCounter()
            let monitor = await monitor(info, scans: scans, interval: .seconds(5))
            await MainActor.run { monitor.setVisible("popover", true) }
            try await Task.sleep(for: .milliseconds(100))
            await MainActor.run { monitor.setVisible("popover", false); monitor.setVisible("popover", true) }
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(scans.count, 1)
            await MainActor.run { monitor.jobFinished() }
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(scans.count, 2)
            await MainActor.run { monitor.setVisible("popover", false); monitor.jobFinished() }
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(scans.count, 2)
        },
        TestCase("resources: con umbral de disco, al terminar un trabajo escanea en segundo plano aunque no haya nada abierto, a lo sumo cada 20 min") {
            let scans = ScanCounter()
            let clock = TestClock()
            let warning = ScanCounter()   // 0 = sin umbral
            let monitor = await MainActor.run {
                let monitor = ResourceMonitor(sampler: ProcessSampler(provider: FakeProcessInfo(), root: 1), registry: ProcessRegistry(),
                                              diskScan: { scans.bump(); return DiskUsage(items: [], scannedAt: clock.now) },
                                              now: { clock.now })
                monitor.backgroundDiskScans = { warning.count > 0 }
                return monitor
            }
            await MainActor.run { monitor.jobFinished() }
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(scans.count, 0)   // sin umbral: nada
            warning.bump()
            await MainActor.run { monitor.jobFinished() }
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(scans.count, 1)
            clock.advance(10 * 60)
            await MainActor.run { monitor.jobFinished() }
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(scans.count, 1)
            clock.advance(11 * 60)
            await MainActor.run { monitor.jobFinished() }
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(scans.count, 2)
        },
        TestCase("resources: un trabajo que termina durante un escaneo pide otro al terminar") {
            let scans = ScanCounter()
            let monitor = await MainActor.run {
                ResourceMonitor(sampler: ProcessSampler(provider: FakeProcessInfo(), root: 1), registry: ProcessRegistry(), interval: .seconds(5),
                                diskScan: {
                                    scans.bump()
                                    try? await Task.sleep(for: .milliseconds(150))
                                    return DiskUsage(items: [], scannedAt: Date())
                                })
            }
            await MainActor.run { monitor.setVisible("activity", true) }
            try await Task.sleep(for: .milliseconds(50))
            await MainActor.run { monitor.jobFinished() }   // mientras escanea
            try await Task.sleep(for: .milliseconds(450))
            try expectEqual(scans.count, 2)
            await MainActor.run { monitor.setVisible("activity", false) }
        },
        TestCase("resources: con datos de captura no muestrea ni escanea") {
            let info = FakeProcessInfo()
            info.children = [1: []]
            info.set(1, cpu: 0, memory: 1)
            let scans = ScanCounter()
            let monitor = await monitor(info, scans: scans)
            let usage = ResourceUsage(cpuPercent: 12, memoryBytes: 640, processes: [], sampledAt: t0)
            await MainActor.run {
                monitor.applySnapshotState(usage: usage, disk: DiskUsage(items: [], scannedAt: t0))
                monitor.setVisible("popover", true)
                monitor.refreshDisk(force: true)
            }
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(info.statCalls, 0)
            try expectEqual(scans.count, 0)
            let shown = await MainActor.run { monitor.usage }
            try expectEqual(shown, usage)
        },
        TestCase("resources: el umbral avisa una vez al cruzarlo hacia arriba") {
            var crossing = DiskWarningState()
            let gb: Int64 = 1_000_000_000
            try expectEqual(crossing.update(total: 4 * gb, limitGB: 5), false)
            try expectEqual(crossing.update(total: 6 * gb, limitGB: 5), true)
            try expectEqual(crossing.update(total: 7 * gb, limitGB: 5), false)
            try expectEqual(crossing.update(total: 3 * gb, limitGB: 5), false)
            try expectEqual(crossing.update(total: 6 * gb, limitGB: 5), true)
            try expectEqual(crossing.update(total: 60 * gb, limitGB: nil), false)
        },
    ]
}
