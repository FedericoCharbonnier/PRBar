import AppKit
import PRBarCore
import SwiftUI

/// PRBar Activity (spec I): CPU, RAM y disco arriba; lo que corre ahora por tarea, con Stop; y el disco por categoría
/// (y por repo en los worktrees), con Clean Up.
struct ActivityWindow: View {
    static let size = NSSize(width: 720, height: 640)

    @ObservedObject var model: AppModel
    @ObservedObject var monitor: ResourceMonitor
    @State private var deleteOld = false
    @State private var olderThanDays = 30
    @State private var cleaning = false
    @State private var lastResult: String?
    @State private var visibility = Visibility()

    /// El `WindowVisibilityTracker` de la ventana, creado la primera vez.
    @MainActor
    final class Visibility {
        private var current: WindowVisibilityTracker?
        func tracker(_ monitor: ResourceMonitor) -> WindowVisibilityTracker {
            if let current { return current }
            let tracker = WindowVisibilityTracker { [weak monitor] in monitor?.setVisible("activity", $0) }
            current = tracker
            return tracker
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                tiles
                runningNow
                disk
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 600, minHeight: 480)
        // Muestrea solo mientras se la ve: no minimizada, no tapada ni en otro Space, y nunca después de cerrarla
        // (`WindowPresenter` guarda el contenido; decisión I.1.7).
        .background(WindowAccessor { window in visibility.tracker(monitor).track(window) })
        .onDisappear { monitor.setVisible("activity", false) }
        // Same unified toolbar as Review, Respond, Merge and History.
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { monitor.refreshDisk(force: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Measure the disk again (⌘R)")
                    .disabled(monitor.scanningDisk)
            }
        }
        // View › Refresh (⌘R).
        .windowCommand(.refresh, enabled: !monitor.scanningDisk) { monitor.refreshDisk(force: true) }
    }

    /// "CPU 3% · RAM 180 MB" under the title.
    private var subtitle: String {
        guard let usage = monitor.usage else { return "" }
        return "CPU \(String(format: "%.0f%%", usage.cpuPercent)) · RAM \(ResourceFooter.memory(usage.memoryBytes))"
    }

    // MARK: Totales

    private var tiles: some View {
        HStack(spacing: 12) {
            StatTile(title: "CPU", symbol: "gauge.with.dots.needle.33percent",
                     value: monitor.usage.map { String(format: "%.0f%%", $0.cpuPercent) },
                     detail: "of one core")
            StatTile(title: "RAM", symbol: "memorychip",
                     value: monitor.usage.map { ResourceFooter.memory($0.memoryBytes) },
                     detail: monitor.usage.map { usage in
                         let others = usage.processes.filter { !$0.isApp }.count
                         return others == 0 ? "PRBar only" : "PRBar and \(others) process\(others == 1 ? "" : "es")"
                     })
            StatTile(title: "Disk", symbol: "internaldrive",
                     value: monitor.disk.map { ResourceFooter.bytes($0.total) },
                     detail: monitor.disk.map { _ in cleanableBytes > 0 ? "\(ResourceFooter.bytes(cleanableBytes)) can be cleaned" : "Nothing to clean up" })
        }
    }

    // MARK: Ahora

    /// Una fila por tarea; la app y los procesos sin tarea van juntos en "PRBar".
    struct TaskRow: Identifiable {
        var activity: ProcessActivity?
        var processes: [ProcessUsage]
        var id: String {
            activity.map { "\($0.kind.rawValue)-\($0.prID ?? "")-\($0.host ?? "")-\($0.chatSessionID?.uuidString ?? "")" } ?? "app"
        }
        var title: String { activity?.title ?? "PRBar" }
        var host: String? { activity?.host }
        var cpu: Double { processes.map(\.cpuPercent).reduce(0, +) }
        var memory: UInt64 { processes.map(\.memoryBytes).reduce(0, +) }
        var startedAt: Date? { processes.compactMap(\.startedAt).min() }
        var names: String {
            let names = processes.filter { !$0.isApp }.map(\.name)
            var seen = Set<String>()
            return names.filter { seen.insert($0).inserted }.joined(separator: " · ")
        }
    }

    static func taskRows(_ usage: ResourceUsage?) -> [TaskRow] {
        let processes = usage?.processes ?? []
        let app = processes.filter { $0.isApp || $0.activity == nil }
        let tasks = Dictionary(grouping: processes.filter { !$0.isApp && $0.activity != nil }, by: { $0.activity! })
            .map { TaskRow(activity: $0.key, processes: $0.value) }
            .sorted { $0.title < $1.title }
        return (app.isEmpty ? [] : [TaskRow(activity: nil, processes: app)]) + tasks
    }

    private var runningNow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Running now").font(.headline)
            if monitor.usage == nil {
                ProgressView().controlSize(.small)
            } else {
                let rows = Self.taskRows(monitor.usage)
                VStack(spacing: 0) {
                    tableHeader(["Task", "CPU", "RAM", "Time", ""])
                    ForEach(rows) { row in
                        Divider()
                        taskRow(row)
                    }
                    if rows.allSatisfy({ $0.activity == nil }) {
                        Divider()
                        Text("No reviews, chats or updates are running.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8).padding(.horizontal, 10)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    private static let columns: [CGFloat] = [0, 56, 84, 60, 64]

    private func tableHeader(_ titles: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                if index == 0 {
                    Text(title).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(title).frame(width: Self.columns[index], alignment: .trailing)
                }
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func taskRow(_ row: TaskRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.body.weight(row.activity == nil ? .regular : .semibold))
                    if let host = row.host {
                        Text("on \(host)").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.tint(Theme.blue)))
                    }
                }
                if !row.names.isEmpty {
                    Text(row.names).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if row.host == nil {
                    Text(String(format: "%.0f%%", row.cpu)).frame(width: Self.columns[1], alignment: .trailing)
                    Text(ResourceFooter.memory(row.memory)).frame(width: Self.columns[2], alignment: .trailing)
                } else {
                    Text("—").frame(width: Self.columns[1], alignment: .trailing)
                    Text("—").frame(width: Self.columns[2], alignment: .trailing)
                }
                Text(row.startedAt.map { RelativeAge.short(from: $0) } ?? "—").frame(width: Self.columns[3], alignment: .trailing)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            stopButton(row.activity).frame(width: Self.columns[4], alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func stopButton(_ activity: ProcessActivity?) -> some View {
        if let activity, let stop = model.stopAction(for: activity) {
            Button("Stop", action: stop).controlSize(.small)
        } else if activity?.kind == .update {
            Button("Stop") {}.controlSize(.small).disabled(true).help("Can’t stop while PRBar is being replaced")
        } else {
            Color.clear.frame(height: 1)
        }
    }

    // MARK: Disco

    /// Lo que Clean Up borraría sin los archivos viejos (huérfanos y caché del updater).
    private var cleanableBytes: Int64 {
        guard let disk = monitor.disk else { return 0 }
        return DiskCleanup.plan(usage: disk, oldFiles: [], updateInProgress: model.updates.session.isInstalling).totalBytes
    }

    private struct DiskRow: Identifiable {
        var title: String
        var note: String?
        var detail: String?
        var bytes: Int64
        var id: String { title }
    }

    static func byRepo(_ items: [DiskItem]) -> String? {
        guard !items.isEmpty else { return nil }
        let groups = Dictionary(grouping: items, by: { $0.repo ?? "Other" })
            .map { (repo: $0.key, bytes: $0.value.map(\.bytes).reduce(0, +)) }
            .sorted { $0.bytes > $1.bytes }
        return groups.map { "\($0.repo) \(ResourceFooter.bytes($0.bytes))" }.joined(separator: " · ")
    }

    private func diskRows(_ usage: DiskUsage) -> [DiskRow] {
        let worktrees = usage.items.filter { $0.kind == .worktrees }
        let active = worktrees.filter { $0.state != .orphan }
        let orphans = worktrees.filter { $0.state == .orphan }
        return [
            DiskRow(title: "Active worktrees", detail: Self.byRepo(active), bytes: active.map(\.bytes).reduce(0, +)),
            DiskRow(title: "Orphaned worktrees", note: orphans.isEmpty ? nil : "(can be cleaned)", detail: Self.byRepo(orphans),
                    bytes: orphans.map(\.bytes).reduce(0, +)),
            DiskRow(title: "Update clone and builds", bytes: usage.bytes(.updater)),
            DiskRow(title: "Logs and history", bytes: usage.bytes(.history) + usage.bytes(.logs)),
            DiskRow(title: "Settings and state", bytes: usage.bytes(.appData)),
        ]
    }

    private var disk: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Disk").font(.headline)
                if monitor.scanningDisk { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let usage = monitor.disk {
                VStack(spacing: 0) {
                    ForEach(Array(diskRows(usage).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        diskRow(row)
                    }
                    Divider()
                    HStack {
                        Text("Total").font(.body.weight(.semibold))
                        Spacer()
                        Text(ResourceFooter.bytes(usage.total)).font(.body.weight(.semibold).monospacedDigit())
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
                cleanUp
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func diskRow(_ row: DiskRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.title)
                    if let note = row.note { Text(note).foregroundStyle(Theme.orangeText) }
                }
                if let detail = row.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text(ResourceFooter.bytes(row.bytes)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// "Clean Up… (frees 460 MB)": lo que se sabe sin buscar archivos viejos (la confirmación trae el total exacto).
    private var cleanUpTitle: String {
        cleanableBytes > 0 ? "Clean Up… (frees \(ResourceFooter.bytes(cleanableBytes)))" : "Clean Up…"
    }

    private var cleanUp: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Also delete history and logs older than", isOn: $deleteOld)
                Stepper("\(olderThanDays) days", value: $olderThanDays, in: 1...365).disabled(!deleteOld)
                Spacer()
                Button(cleanUpTitle) {
                    Task { await confirmCleanUp() }
                }
                .disabled(cleaning || (cleanableBytes == 0 && !deleteOld))
            }
            Text("Clean Up never touches worktrees with a job running or fixes not pushed yet.")
                .font(.caption).foregroundStyle(.secondary)
            if let lastResult {
                Text(lastResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func confirmCleanUp() async {
        let days = deleteOld ? olderThanDays : nil
        cleaning = true
        let plan = await model.cleanupPreview(olderThanDays: days)
        cleaning = false
        guard !plan.isEmpty else {
            lastResult = "Nothing to clean up."
            return
        }
        let list = plan.candidates.prefix(8).map { "• \($0.title) (\(ResourceFooter.bytes($0.bytes)))" }.joined(separator: "\n")
        let more = plan.candidates.count > 8 ? "\n…and \(plan.candidates.count - 8) more" : ""
        ConfirmAlert.present(
            title: "Free \(ResourceFooter.bytes(plan.totalBytes))?",
            message: "PRBar will delete:\n\(list)\(more)\n\nWorktrees with a job running or fixes not pushed yet are never touched.",
            action: "Clean Up"
        ) {
            Task { await runCleanUp(days, paths: plan.candidates.map(\.path)) }
        }
    }

    private func runCleanUp(_ days: Int?, paths: [String]) async {
        cleaning = true
        defer { cleaning = false }
        do {
            lastResult = Self.resultText(try await model.cleanup(olderThanDays: days, confirmed: true, paths: paths))
        } catch {
            lastResult = (error as? CommandFailure)?.message ?? error.localizedDescription
        }
    }

    static func resultText(_ result: CleanupResult) -> String {
        if result.removed.isEmpty && result.skipped.isEmpty && result.failed.isEmpty { return "Nothing to clean up." }
        var lines = ["Freed \(ResourceFooter.bytes(result.freedBytes))."]
        lines += result.skipped.map { "Skipped \($0)" }
        lines += result.failed.map { "Couldn’t delete \($0)" }
        return lines.joined(separator: "\n")
    }
}

/// Uno de los tres totales de arriba de PRBar Activity.
private struct StatTile: View {
    let title: String
    let symbol: String
    let value: String?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value ?? "–").font(.title2.weight(.semibold).monospacedDigit())
            Text(detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .combine)
    }
}
