import ArgumentParser
import Foundation
import PRBarCore

enum Bytes {
    static func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal) }
    static func text(_ bytes: UInt64) -> String { text(Int64(clamping: bytes)) }
}

struct ResourcesCommand: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "resources", abstract: "CPU, memory and disk PRBar is using (the popover’s footer and PRBar Activity).")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .resources }

    func render(_ result: JSONValue, _ output: Output) throws {
        let info: ResourcesInfo = try result.decode()
        output.line(output.paint(String(format: "CPU %.0f%%  ·  RAM %@  ·  Disk %@", info.usage.cpuPercent,
                                        Bytes.text(info.usage.memoryBytes), Bytes.text(info.disk.total)), .bold))
        output.line()
        output.table(["Process", "PID", "CPU", "RAM", "Running"], info.usage.processes.map { process in
            let cpu = process.remoteHost.map { "on \($0)" } ?? String(format: "%.0f%%", process.cpuPercent)
            let ram = process.remoteHost == nil ? Bytes.text(process.memoryBytes) : "—"
            return [process.label, String(process.pid), cpu, ram, process.startedAt.map { RelativeAge.short(from: $0) } ?? "—"]
        })
        output.line()
        output.table(["Disk", "Size"], DiskCategoryKind.allCases.map { [$0.title, Bytes.text(info.disk.bytes($0))] })
        if let claude = info.claudeThisMonth {
            output.line()
            output.line("Claude this month: \(UsageFormat.summary(claude)) — see `prbar usage`")
        }
        let orphans = info.disk.items.filter { $0.state == .orphan }
        if !orphans.isEmpty {
            output.line(output.paint("\(orphans.count) leftover worktree\(orphans.count == 1 ? "" : "s") (\(Bytes.text(orphans.map(\.bytes).reduce(0, +)))). Run `prbar cleanup`.", .yellow))
        }
    }
}

/// `30d` o `30`: días (1…3650).
struct DayCount: ExpressibleByArgument {
    let days: Int

    init?(argument: String) {
        let digits = argument.hasSuffix("d") ? String(argument.dropLast()) : argument
        guard let days = Int(digits), (1...3650).contains(days) else { return nil }
        self.days = days
    }
}

struct CleanupCommand: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup", abstract: "Delete leftover worktrees and the updater’s builds (Clean Up in PRBar Activity).",
        discussion: "Never touches running jobs or worktrees with unpushed fixes. Without a terminal it needs --yes.")
    @Option(help: "Also delete history and logs older than this (e.g. 30d).") var olderThan: DayCount?
    @Flag(help: "Only show what would be deleted.") var preview = false
    @OptionGroup var global: GlobalOptions

    /// La vista previa (`prepare`, también con `--yes`): la app solo borra lo que está acá y sigue en su plan nuevo.
    var shown: CleanupPlan?

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard !preview else { return }
        shown = try connection.run(.cleanupPreview(olderThanDays: olderThan?.days)).decode()
    }

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        guard let plan = shown, !plan.isEmpty else { return nil }
        // Sin terminal (y sin --yes) sale con 4 enseguida: la tabla solo cuando se va a preguntar (L17).
        if output.terminal.isInteractive && !output.json {
            output.table(["Delete", "Size"], plan.candidates.map { [$0.title, Bytes.text($0.bytes)] })
        }
        return "Delete \(plan.candidates.count) item\(plan.candidates.count == 1 ? "" : "s") and free \(Bytes.text(plan.totalBytes))?"
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        preview ? .cleanupPreview(olderThanDays: olderThan?.days)
            : .cleanup(olderThanDays: olderThan?.days, confirmed: confirmed, paths: shown?.candidates.map(\.path))
    }

    func render(_ result: JSONValue, _ output: Output) throws {
        if preview {
            let plan: CleanupPlan = try result.decode()
            guard !plan.isEmpty else { return output.line("Nothing to clean up.") }
            output.table(["Delete", "Size"], plan.candidates.map { [$0.title, Bytes.text($0.bytes)] })
            return output.line("Would free \(Bytes.text(plan.totalBytes)).")
        }
        let done: CleanupResult = try result.decode()
        if done.removed.isEmpty && done.skipped.isEmpty && done.failed.isEmpty { return output.line("Nothing to clean up.") }
        output.line("Freed \(Bytes.text(done.freedBytes)) (\(done.removed.count) item\(done.removed.count == 1 ? "" : "s")).")
        for skipped in done.skipped { output.line(output.paint("Skipped \(skipped)", .yellow)) }
        for failed in done.failed { output.line(output.paint("Couldn’t delete \(failed)", .red)) }
    }
}
