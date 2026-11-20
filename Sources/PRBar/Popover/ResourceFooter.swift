import PRBarCore
import SwiftUI

/// `◔ CPU 12%  ▤ RAM 640 MB  ⛁ Disk 2.3 GB  ›` (spec I). Clic → PRBar Activity.
struct ResourceFooter: View {
    @ObservedObject var monitor: ResourceMonitor
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                metric("gauge.with.dots.needle.33percent", "CPU", monitor.usage.map { String(format: "%.0f%%", $0.cpuPercent) })
                metric("memorychip", "RAM", monitor.usage.map { Self.memory($0.memoryBytes) })
                metric("internaldrive", "Disk", monitor.disk.map { Self.bytes($0.total) })
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 0)
        .help("PRBar Activity: processes, disk and Clean Up")
        .accessibilityLabel(accessibility)
    }

    private func metric(_ symbol: String, _ title: String, _ value: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text("\(title) \(value ?? "–")")
        }
    }

    /// Disco: en unidades decimales, como Finder.
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    /// RAM: en unidades binarias, como Activity Monitor.
    static func memory(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private var accessibility: String {
        let cpu = monitor.usage.map { String(format: "%.0f percent", $0.cpuPercent) } ?? "unknown"
        let ram = monitor.usage.map { Self.memory($0.memoryBytes) } ?? "unknown"
        let disk = monitor.disk.map { Self.bytes($0.total) } ?? "unknown"
        return "PRBar Activity. CPU \(cpu), memory \(ram), disk \(disk)"
    }
}
