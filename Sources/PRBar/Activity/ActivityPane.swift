import AppKit
import PRBarCore
import SwiftUI

/// Activity en la ventana principal (spec I y M.1 "Activity"), a todo el ancho: cuatro tiles (CPU, Memory, Disk,
/// Claude), las tareas de Claude con Stop o su estado, lo que costó Claude este mes y los worktrees con Clean Up.
struct ActivityPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: ResourceMonitor
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue
    @State private var deleteOld = false
    @State private var olderThanDays = 30
    @State private var cleaning = false
    @State private var lastResult: String?
    @State private var visibility = Visibility()

    init(model: AppModel, monitor: ResourceMonitor) {
        self.model = model
        self.monitor = monitor
        reviews = model.reviews
        respond = model.respond
    }

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
                claudeTasks
                claudeUsage
                worktrees
                recentTasksTable
                disk
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Muestrea solo mientras se la ve: no minimizada, no tapada ni en otro Space, y nunca después de cerrarla o de
        // pasar a otra sección (`onDisappear`; decisión I.1.7).
        .background(WindowAccessor { window in visibility.tracker(monitor).track(window) })
        .onDisappear { monitor.setVisible("activity", false) }
        // View › Refresh (⌘R) y el Refresh de la toolbar de la ventana (`MainWindow`).
        .windowCommand(.refresh, enabled: !monitor.scanningDisk) { monitor.refreshDisk(force: true) }
    }

    /// "CPU 3% · RAM 180 MB": el subtítulo de la ventana en Activity.
    static func subtitle(_ monitor: ResourceMonitor) -> String {
        guard let usage = monitor.usage else { return "" }
        return "CPU \(String(format: "%.0f%%", usage.cpuPercent)) · RAM \(ResourceFooter.memory(usage.memoryBytes))"
    }

    // MARK: Totales

    private var tiles: some View {
        HStack(spacing: 12) {
            StatTile(title: "CPU", symbol: "gauge.with.dots.needle.33percent",
                     value: monitor.usage.map { String(format: "%.0f%%", $0.cpuPercent) },
                     detail: "of one core")
            StatTile(title: "Memory", symbol: "memorychip",
                     value: monitor.usage.map { ResourceFooter.memory($0.memoryBytes) },
                     detail: monitor.usage.map { usage in
                         let others = usage.processes.filter { !$0.isApp }.count
                         return others == 0 ? "PRBar only" : "PRBar and \(others) process\(others == 1 ? "" : "es")"
                     })
            StatTile(title: "Disk", symbol: "internaldrive",
                     value: monitor.disk.map { ResourceFooter.bytes($0.total) },
                     detail: monitor.disk.map { _ in cleanableBytes > 0 ? "\(ResourceFooter.bytes(cleanableBytes)) can be cleaned" : "Nothing to clean up" })
            StatTile(title: "Claude", symbol: "sparkles", value: UsageFormat.cost(thisMonth.usage),
                     detail: "this month · estimated")
                .help(UsageFormat.note)
        }
    }

    // MARK: Claude (spec O)

    /// This month's Claude usage, from the ledger (refreshed when a run is recorded: `usageRevision`).
    private var thisMonth: UsageMonth {
        _ = model.usageRevision
        return model.usageLedger.month(UsageSummary.monthKey(Date()))
    }

    private var recentTasks: [UsageTask] {
        _ = model.usageRevision
        return model.usageLedger.recentTasks(limit: 8)
    }

    /// Reviews · Fixes (Respond, Fix CI y Resolve Conflicts) · Chat (chats, merge, instrucciones y lo demás), del mes.
    private var monthBreakdown: [(title: String, usage: ClaudeUsage?, color: Color)] {
        let byKind = thisMonth.byKind
        let fixes: [String] = [ProcessActivity.Kind.respond.rawValue, ProcessActivity.Kind.ciFix.rawValue,
                                ProcessActivity.Kind.conflicts.rawValue]
        let reviews = byKind[ProcessActivity.Kind.review.rawValue]
        let fix = ClaudeUsage.sum(fixes.map { byKind[$0] })
        let chat = ClaudeUsage.sum(byKind.filter { $0.key != ProcessActivity.Kind.review.rawValue && !fixes.contains($0.key) }.map(\.value))
        return [("Reviews", reviews, Theme.violet), ("Fixes", fix, Theme.orange), ("Chat", chat, Theme.accent)]
    }

    private var claudeUsage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude this month").font(.headline)
            let month = thisMonth.usage
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(UsageFormat.cost(month)).font(.title.weight(.semibold).monospacedDigit())
                    Text("estimated").foregroundStyle(.secondary)
                    Spacer()
                    Text(month.runs == 0 ? "No runs this month"
                         : "\(month.runs) run\(month.runs == 1 ? "" : "s") · \(UsageFormat.tokens(month)) tokens")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                let parts = monthBreakdown
                let total = parts.map { $0.usage?.costUSD ?? 0 }.reduce(0, +)
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        if total > 0 {
                            ForEach(parts, id: \.title) { part in
                                let share = (part.usage?.costUSD ?? 0) / total
                                if share > 0 {
                                    Rectangle().fill(part.color).frame(width: max(2, (geometry.size.width - 4) * share))
                                }
                            }
                        } else {
                            Rectangle().fill(Color.primary.opacity(0.08))
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(Capsule())
                .accessibilityHidden(true)
                HStack(spacing: 14) {
                    ForEach(parts, id: \.title) { part in
                        HStack(spacing: 5) {
                            Circle().fill(part.color).frame(width: 7, height: 7)
                            Text(part.title).foregroundStyle(.secondary)
                            Text(UsageFormat.cost(part.usage)).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Spacer()
                }
                .font(.callout)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
            .help(UsageFormat.note)
        }
    }

    /// Las últimas tareas de Claude con su tiempo, tokens y costo (debajo de los worktrees).
    private var recentTasksTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            let tasks = recentTasks
            VStack(spacing: 0) {
                usageHeader
                if tasks.isEmpty {
                    Divider()
                    Text("No Claude runs recorded yet.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8).padding(.horizontal, 10)
                }
                ForEach(tasks) { task in
                    Divider()
                    usageRow(task)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
            Text(UsageFormat.note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private static let usageColumns: [CGFloat] = [0, 90, 64, 72, 64]

    private var usageHeader: some View {
        HStack(spacing: 8) {
            Text("Recent tasks").frame(maxWidth: .infinity, alignment: .leading)
            Text("When").frame(width: Self.usageColumns[1], alignment: .trailing)
            Text("Time").frame(width: Self.usageColumns[2], alignment: .trailing)
            Text("Tokens").frame(width: Self.usageColumns[3], alignment: .trailing)
            Text("Cost").frame(width: Self.usageColumns[4], alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func usageRow(_ task: UsageTask) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.title).font(.body.weight(.semibold))
                    if let host = task.activity?.host {
                        Text("on \(host)").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.tint(Theme.blue)))
                    }
                }
                Text(task.stages.joined(separator: " · ")
                     + (task.usage.unknownRuns > 0 ? " · \(task.usage.unknownRuns) without usage data" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text(RelativeAge.short(from: task.finishedAt) + " ago").frame(width: Self.usageColumns[1], alignment: .trailing)
                Text(UsageFormat.duration(seconds: task.usage.durationSeconds)).frame(width: Self.usageColumns[2], alignment: .trailing)
                Text(UsageFormat.tokens(task.usage)).frame(width: Self.usageColumns[3], alignment: .trailing)
                Text(UsageFormat.cost(task.usage)).frame(width: Self.usageColumns[4], alignment: .trailing)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
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

    /// Una fila de "Claude tasks": un trabajo que corre (con su proceso) o una tarea lista sin proceso.
    struct ClaudeTaskLine: Identifiable {
        var id: String
        var task: String
        var host: String?
        var pr: String
        var worktree: String?
        var time: String
        var cost: String
        var activity: ProcessActivity?
        /// "Ready to push", "Review ready · 4 findings": una lista (sin Stop).
        var status: String?
        var prID: String?
        var tab: PRTab?
    }

    private func claudeTaskLines() -> [ClaudeTaskLine] {
        let running = Self.taskRows(monitor.usage).compactMap { row -> ClaudeTaskLine? in
            guard let activity = row.activity else { return nil }
            return ClaudeTaskLine(
                id: row.id, task: row.title, host: row.host, pr: activity.prID.map(ClaudeTasksSidebar.shortName) ?? "—",
                worktree: activity.prID.flatMap(worktree), time: row.startedAt.map { RelativeAge.short(from: $0) } ?? "—",
                cost: UsageFormat.cost(model.liveClaudeUsage(activity)), activity: activity, prID: activity.prID)
        }
        let busy = Set(running.compactMap(\.prID))
        let ready = model.claudeTaskRows().filter { !$0.isRunning && !busy.contains($0.prID) }.map { row in
            ClaudeTaskLine(
                id: "ready-\(row.id)", task: row.tab.title, pr: row.title,
                worktree: row.tab == .review ? nil : worktree(row.prID), time: "—", cost: UsageFormat.cost(readyUsage(row)),
                status: row.subtitle, prID: row.prID, tab: row.tab)
        }
        return running + ready
    }

    /// El worktree de la corrida de Respond / Fix CI del PR (las reviews usan uno temporal: "—").
    private func worktree(_ prID: String) -> String? {
        respond.records[prID].map { ($0.draft.worktree.path as NSString).lastPathComponent }
    }

    private func readyUsage(_ row: ClaudeTaskRow) -> ClaudeUsage? {
        if row.tab == .review, case .ready(let draft)? = reviews.phases[row.prID] { return draft.totalUsage }
        return respond.records[row.prID]?.totalUsage
    }

    private static let taskColumns: [CGFloat] = [0, 110, 170, 60, 64, 120]

    private var claudeTasks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude tasks").font(.headline)
            if monitor.usage == nil {
                ProgressView().controlSize(.small)
            } else {
                let lines = claudeTaskLines()
                VStack(spacing: 0) {
                    tableHeader(["Task", "PR", "Worktree", "Time", "Cost", ""], widths: Self.taskColumns)
                    ForEach(lines) { line in
                        Divider()
                        claudeTaskRow(line)
                    }
                    if lines.isEmpty {
                        Divider()
                        Text("Claude isn’t working on anything.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8).padding(.horizontal, 10)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    private func claudeTaskRow(_ line: ClaudeTaskLine) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if line.status == nil {
                    ProgressView().controlSize(.mini).tint(Theme.violet)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                }
                Text(line.task).font(.body.weight(.semibold)).lineLimit(1)
                if let host = line.host {
                    Text("on \(host)").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.tint(Theme.blue)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text(line.pr).font(.callout.monospaced()).lineLimit(1)
                    .frame(width: Self.taskColumns[1], alignment: .leading)
                Text(line.worktree ?? "—").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    .frame(width: Self.taskColumns[2], alignment: .leading)
                    .help(line.worktree ?? "")
                Text(line.time).frame(width: Self.taskColumns[3], alignment: .trailing)
                Text(line.cost).frame(width: Self.taskColumns[4], alignment: .trailing)
                    .help("Estimated cost of the Claude runs of this task that already finished")
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            Group {
                if let status = line.status {
                    Button(status.components(separatedBy: " · ").first ?? status) {
                        if let prID = line.prID { model.navigate(to: .pr(prID: prID, tab: line.tab)) }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .lineLimit(1)
                    .help("Open \(line.pr) in its tab")
                } else {
                    stopButton(line.activity)
                }
            }
            .frame(width: Self.taskColumns[5], alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }


    private func tableHeader(_ titles: [String], widths: [CGFloat], leading: Set<Int> = [1, 2]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                if index == 0 {
                    Text(title).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(title).frame(width: widths[index], alignment: leading.contains(index) ? .leading : .trailing)
                }
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
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

    /// Lo que no son worktrees (esos tienen su tabla).
    private func diskRows(_ usage: DiskUsage) -> [DiskRow] {
        let worktrees = usage.items.filter { $0.kind == .worktrees }
        return [
            DiskRow(title: "Worktrees", detail: Self.byRepo(worktrees), bytes: worktrees.map(\.bytes).reduce(0, +)),
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

    // MARK: Worktrees

    private static let worktreeColumns: [CGFloat] = [0, 130, 90, 80, 90]

    private var worktrees: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Worktrees").font(.headline)
                if monitor.scanningDisk { ProgressView().controlSize(.small) }
                Spacer()
                let finished = (monitor.disk?.items ?? []).filter { $0.kind == .worktrees && $0.state == .orphan }
                Button("Clean Up Finished…") { Task { await confirmCleanUp(onlyWorktrees: true) } }
                    .disabled(cleaning || finished.isEmpty)
                    .help("Delete the worktrees of runs that already finished")
            }
            if let usage = monitor.disk {
                let items = usage.items.filter { $0.kind == .worktrees }.sorted { $0.bytes > $1.bytes }
                VStack(spacing: 0) {
                    tableHeader(["Worktree", "Repo", "State", "Size", ""], widths: Self.worktreeColumns, leading: [1, 2])
                    ForEach(items) { item in
                        Divider()
                        worktreeRow(item)
                    }
                    if items.isEmpty {
                        Divider()
                        Text("No worktrees.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8).padding(.horizontal, 10)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func worktreeRow(_ item: DiskItem) -> some View {
        let finished = item.state == .orphan
        let kept = finished && item.keptForTerminal == true
        return HStack(spacing: 8) {
            Text((item.path as NSString).lastPathComponent)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.path)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text(item.repo ?? "—").lineLimit(1).frame(width: Self.worktreeColumns[1], alignment: .leading)
                Text(kept ? "Kept" : finished ? "Finished" : "In use")
                    .foregroundStyle(finished && !kept ? Theme.orangeText : .secondary)
                    .help(kept ? "Kept for Terminal: you can resume Claude’s session in it" : "")
                    .frame(width: Self.worktreeColumns[2], alignment: .leading)
                Text(ResourceFooter.bytes(item.bytes)).frame(width: Self.worktreeColumns[3], alignment: .trailing)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            Button("Clean Up") { confirmRemove(item) }
                .controlSize(.small)
                .disabled(!finished || cleaning)
                .help(finished ? "Delete this worktree" : "A job or unpushed fixes use it")
                .frame(width: Self.worktreeColumns[4], alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func confirmRemove(_ item: DiskItem) {
        ConfirmAlert.present(
            title: "Remove this worktree?",
            message: "PRBar will delete \(item.path) (\(ResourceFooter.bytes(item.bytes))).",
            action: "Clean Up"
        ) {
            Task { await runCleanUp(nil, paths: [item.path]) }
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

    /// `onlyWorktrees`: "Clean Up Finished…" de la tabla de worktrees (sin caché del updater ni archivos viejos).
    private func confirmCleanUp(onlyWorktrees: Bool = false) async {
        let days = deleteOld && !onlyWorktrees ? olderThanDays : nil
        cleaning = true
        var plan = await model.cleanupPreview(olderThanDays: days)
        cleaning = false
        if onlyWorktrees {
            let worktrees = Set((monitor.disk?.items ?? []).filter { $0.kind == .worktrees }.map(\.path))
            plan = plan.limited(to: plan.candidates.map(\.path).filter(worktrees.contains))
        }
        guard !plan.isEmpty else {
            lastResult = "Nothing to clean up."
            return
        }
        let list = plan.candidates.prefix(8).map { "• \($0.displayTitle) (\(ResourceFooter.bytes($0.bytes)))" }.joined(separator: "\n")
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
