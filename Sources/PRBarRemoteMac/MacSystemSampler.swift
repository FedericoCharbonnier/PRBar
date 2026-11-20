import Darwin
import Foundation
import PRBarCore

/// Los totales de la Mac para las tarjetas de Activity del iPhone (spec R.7): núcleos, memoria usada y total, y el
/// disco del volumen de arranque. Todo local (sysctl, Mach y el volumen), sin procesos ni red.
public enum MacSystemSampler {
    public static func sample(volume: URL = URL(fileURLWithPath: "/")) -> MacSystemInfo? {
        let total = ProcessInfo.processInfo.physicalMemory
        guard let disk = try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                              .volumeAvailableCapacityForImportantUsageKey]),
              let diskTotal = disk.volumeTotalCapacity, let diskFree = disk.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return MacSystemInfo(cores: ProcessInfo.processInfo.activeProcessorCount, memoryTotalBytes: total,
                             memoryUsedBytes: min(usedMemory() ?? 0, total), diskFreeBytes: diskFree,
                             diskTotalBytes: Int64(diskTotal))
    }

    /// Como "Memory Used" del Monitor de Actividad: activa + cableada + comprimida (sin lo que se puede descartar).
    static func usedMemory() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
            - min(UInt64(stats.purgeable_count), UInt64(stats.active_count))
        return pages * UInt64(vm_kernel_page_size)
    }
}
