import PRBarCore
import SwiftUI

/// `◔ CPU 12%  ▤ RAM 640 MB  ⑂ 3 worktrees  ✦ $4.20  ›` (spec I, M.3). Clic → Activity en la ventana principal.
struct ResourceFooter: View {
    @ObservedObject var monitor: ResourceMonitor
    /// Lo que costó Claude este mes ("$4.20").
    let monthCost: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                metric("gauge.with.dots.needle.33percent", "CPU", monitor.usage.map { String(format: "%.0f%%", $0.cpuPercent) })
                metric("memorychip", "RAM", monitor.usage.map { Self.memory($0.memoryBytes) })
                metric("arrow.triangle.branch", nil, worktrees.map { "\($0) \($0 == 1 ? "worktree" : "worktrees")" })
                metric("sparkles", nil, monthCost)
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
        .help("Activity: processes, worktrees, Claude’s cost and Clean Up")
        .accessibilityLabel(accessibility)
    }

    private func metric(_ symbol: String, _ title: String?, _ value: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text([title, value ?? "–"].compactMap { $0 }.joined(separator: " ")).lineLimit(1)
        }
    }

    /// Los worktrees en disco (`nil` hasta que se mida el disco).
    private var worktrees: Int? { monitor.disk.map { $0.items.filter { $0.kind == .worktrees }.count } }

    /// Disco: en unidades decimales, como Finder.
    static func bytes(_ value: Int64) -> String { ByteSize.file(value) }
    /// RAM: en unidades binarias, como Activity Monitor.
    static func memory(_ value: UInt64) -> String {
        ByteSize.memory(value)
    }

    private var accessibility: String {
        let cpu = monitor.usage.map { String(format: "%.0f percent", $0.cpuPercent) } ?? "unknown"
        let ram = monitor.usage.map { Self.memory($0.memoryBytes) } ?? "unknown"
        let worktrees = worktrees.map(String.init) ?? "unknown"
        return "Activity. CPU \(cpu), memory \(ram), \(worktrees) worktrees, Claude this month \(monthCost)"
    }
}
