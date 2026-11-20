import PRBarCore
import Foundation

// Provisorio: la conexión con el monitor, la limpieza y el umbral llegan en el commit siguiente (Plan 13, Task 9).
extension AppModel: ResourceActions {
    func resources() async -> ResourcesInfo {
        ResourcesInfo(usage: ResourceUsage(cpuPercent: 0, memoryBytes: 0, processes: [], sampledAt: Date()),
                      disk: DiskUsage(items: [], scannedAt: Date()))
    }

    func cleanupPreview(olderThanDays: Int?) async -> CleanupPlan { CleanupPlan(candidates: []) }

    func cleanup(olderThanDays: Int?, confirmed: Bool) async throws -> CleanupResult { CleanupResult() }

    func configSetDiskWarning(gigabytes: Int?) throws {
        throw CommandFailure(.failed, "Not available yet.")
    }
}
