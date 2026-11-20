import ArgumentParser
import Foundation
import PRBarCore

/// `prbar ci` (spec K.5): Fix CI on your own PRs whose checks failed. Show, diff, test, push, cancel and dismiss are the
/// Respond commands (a Fix CI is a Respond run in CI mode).
struct CIGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ci", abstract: "Fix the failing CI of your PRs with Claude (Fix CI).",
        discussion: "Manual only: PRBar never starts a Fix CI on its own. The CI logs are read on this Mac and passed to Claude as untrusted text; nothing is pushed until you push.",
        subcommands: [CIList.self, CIFix.self, CIShow.self, CIDiff.self, CITest.self, CIPush.self, CICancel.self, CIDismiss.self],
        defaultSubcommand: CIList.self)
}

enum CIRender {
    static func list(_ entries: [CIListEntry], _ output: Output) {
        guard !entries.isEmpty else { return output.line("None of your PRs has failing CI.") }
        output.table(["PR", "Title", "Fix CI"], entries.map { entry in
            let state = entry.phase ?? (entry.respondInProgress ? "respond in progress" : entry.unavailableReason.map { _ in "unavailable" } ?? "—")
            return [entry.pr, Render.truncate(entry.title, 50), state]
        })
        for entry in entries {
            if let reason = entry.unavailableReason, entry.phase == nil { output.line(output.paint("\(entry.pr): \(reason)", .yellow)) }
        }
    }

    /// What `respond show` prints, for a Fix CI.
    static func info(_ info: RespondInfo, _ output: Output, full: Bool = false) {
        var header = "\(info.pr) · Fix CI · \(info.runningTests ? "running tests" : info.phase)"
        if let detail = info.detail, info.phase != "failed" { header += " (\(detail))" }
        output.line(output.paint(header, .bold))
        if info.phase == "failed", let detail = info.detail { output.line(output.paint(detail, .red)) }
        if let title = info.title { output.line(title) }
        var pairs: [(String, String)] = []
        if let account = info.account, let head = info.headRef { pairs.append(("Branch", "\(head) as @\(account)")) }
        if let worktree = info.worktree { pairs.append(("Worktree", worktree)) }
        if let log = info.logPath { pairs.append(("Log", log)) }
        if let usage = info.usage { pairs.append(("Claude", UsageFormat.summary(usage))) }
        Render.pairs(pairs, output)
        if let checks = info.ciChecks, !checks.isEmpty {
            output.line()
            output.table(["Failing check", "Conclusion", "Log"], checks.map { [$0.name, $0.conclusion, $0.hasLog ? "job log" : "summary only"] })
            if full {
                for item in info.items { item.thread.forEach { output.line(Render.indent($0)) } }
            }
        }
        if !info.commits.isEmpty {
            output.line()
            for commit in info.commits {
                let sha = commit.sha.map { String($0.prefix(7)) } ?? "—"
                output.line("\(sha) \(commit.status): \(commit.summary)")
            }
        }
        if let stat = info.diffStat, !stat.isEmpty { output.line(); output.line(stat) }
        if !info.sensitiveChanges.isEmpty {
            output.line(output.paint("Claude changed files that can run code: \(info.sensitiveChanges.joined(separator: ", ")). Review them before running tests or pushing.", .red, .bold))
        }
        if let tests = info.tests {
            output.line(tests.passed ? output.paint("Tests passed (\(tests.command)).", .green)
                                     : output.paint("Tests failed (\(tests.command)).", .yellow))
            if full, !tests.outputTail.isEmpty { output.line(Render.indent(tests.outputTail)) }
        }
        if info.pushBlockedByTests {
            output.line(output.paint("PRBar didn’t push because the tests failed. Push anyway: prbar ci push \(info.pr) --anyway", .yellow))
        }
        if let blocked = info.pushBlockedByCI {
            output.line(output.paint("\(blocked) Push anyway: prbar ci push \(info.pr) --anyway", .yellow))
        }
        if let error = info.errorMessage, info.phase != "failed" { output.line(output.paint(error, .red)) }
    }

    /// The push question (no replies in a Fix CI).
    static func pushQuestion(_ info: RespondInfo) -> String {
        let commits = info.commits.filter { $0.status == "committed" && $0.sha != nil }.count
        return "Push \(commits) commit\(commits == 1 ? "" : "s") to \(info.headRef ?? "?") as @\(info.account ?? "?")? PRBar checks the CI again first; no comment is posted."
    }
}

struct CIList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Your PRs with failing CI and their Fix CI (also: prbar ci).")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .ciList }
    func render(_ result: JSONValue, _ output: Output) throws { CIRender.list(try result.decode(), output) }
}

struct CIFix: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix", abstract: "Fix CI: read the failing checks and let Claude fix the code (nothing is pushed).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait for the fix and print it (Ctrl-C cancels it).") var wait = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .ciFix(pr: pr, wait: wait) }
    var cancelCommand: AppCommand? { wait ? .respondCancel(pr: pr) : nil }
    func render(_ result: JSONValue, _ output: Output) throws { CIRender.info(try result.decode(), output) }
}

struct CIShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "The failing checks, Claude’s fix and its commits.")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Also print the CI output Claude saw and the test output.") var full = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondShow(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { CIRender.info(try result.decode(), output, full: full) }
}

struct CIDiff: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "diff", abstract: "The full diff of the fix (what would be pushed).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Only the summary (files and lines).") var stat = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondDiff(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { try RespondDiffCommand.render(result, stat: stat, output) }
}

struct CITest: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "test", abstract: "Run the repo’s test command in the worktree (look at `prbar ci diff` first).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait for the tests (Ctrl-C cancels).") var wait = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondTest(pr: pr, wait: wait) }
    var cancelCommand: AppCommand? { wait ? .respondCancel(pr: pr) : nil }
    func render(_ result: JSONValue, _ output: Output) throws { CIRender.info(try result.decode(), output, full: true) }
}

struct CIPush: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "push", abstract: "Push the fix from this Mac (no comment is posted).",
        discussion: "PRBar first checks on GitHub that the PR’s head is still the one that failed and that its CI still isn’t green. Runs your pre-push hooks. Asks for confirmation; without a terminal it needs --yes.")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait until it’s pushed.") var wait = false
    @Flag(help: "Push even though the tests failed or the failing checks pass now (Push Anyway).") var anyway = false
    @OptionGroup var global: GlobalOptions

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        let info: RespondInfo = try connection.run(.respondShow(pr: pr)).decode()
        guard info.mode == .ciFix else {
            throw CommandFailure(.invalidState, "\(info.pr) isn’t a Fix CI: use `prbar respond push \(info.pr)`.")
        }
        if anyway && !info.pushBlockedByTests && info.pushBlockedByCI == nil {
            throw CommandFailure(.invalidState, "Nothing is blocked: use `prbar ci push \(info.pr)`.")
        }
        guard info.phase == "readyToPush" || info.phase == "failed" else {
            throw CommandFailure(.invalidState, "\(info.pr) has no fix ready to push (\(info.phase)).")
        }
        if output.terminal.isInteractive && !output.json {
            if let stat = info.diffStat, !stat.isEmpty { output.line(stat) }
            if !info.sensitiveChanges.isEmpty {
                output.line(output.paint("Claude changed files that can run code: \(info.sensitiveChanges.joined(separator: ", "))", .red, .bold))
            }
        }
        return (anyway ? "Pushing anyway. " : "") + CIRender.pushQuestion(info)
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        anyway ? .respondPushAnyway(pr: pr, confirmed: confirmed, wait: wait) : .respondPush(pr: pr, confirmed: confirmed, wait: wait)
    }
    func render(_ result: JSONValue, _ output: Output) throws { CIRender.info(try result.decode(), output) }
}

struct CICancel: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "cancel", abstract: "Cancel the Fix CI that’s running (not a push).")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondCancel(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Canceled.") }
}

struct CIDismiss: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "dismiss", abstract: "Dismiss the fix and delete PRBar’s worktree (it stays in History).")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondDismiss(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Dismissed.") }
}

/// `prbar usage` (spec O.3).
struct UsageCommand: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "usage", abstract: "Claude’s time, tokens and estimated cost per task, this month or another.",
        discussion: UsageFormat.note)
    @Option(help: "The month, as YYYY-MM (default: this month).") var month: String?
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if let month, UsageSummary.parseMonth(month) == nil { throw ValidationError("--month must be YYYY-MM, e.g. 2026-11.") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .usage(month: month.flatMap(UsageSummary.parseMonth)) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let info: UsageInfo = try result.decode()
        let usage = info.month.usage
        output.line(output.paint("Claude in \(info.month.month): \(UsageFormat.cost(usage)) estimated", .bold))
        guard usage.runs > 0 else {
            output.line("No Claude runs recorded.")
            output.line(output.paint(info.note, .dim))
            return
        }
        var pairs = [("Runs", "\(usage.runs)"), ("Time", UsageFormat.duration(seconds: usage.durationSeconds))]
        if usage.hasData { pairs.append(("Tokens", UsageFormat.tokenBreakdown(usage))) }
        if usage.unknownRuns > 0 { pairs.append(("Without data", "\(usage.unknownRuns) run\(usage.unknownRuns == 1 ? "" : "s")")) }
        Render.pairs(pairs, output)
        if info.month.byKind.count > 1 {
            output.line()
            output.table(["Kind", "Runs", "Tokens", "Cost"], info.month.byKind.sorted { $0.key < $1.key }.map {
                [$0.key, "\($0.value.runs)", UsageFormat.tokens($0.value), UsageFormat.cost($0.value)]
            })
        }
        if !info.tasks.isEmpty {
            output.line()
            output.table(["Task", "Stages", "When", "Time", "Tokens", "Cost"], info.tasks.map { task in
                [task.title, task.stages.joined(separator: ", "), Render.date(task.finishedAt),
                 UsageFormat.duration(seconds: task.usage.durationSeconds), UsageFormat.tokens(task.usage), UsageFormat.cost(task.usage)]
            })
        }
        output.line()
        output.line(output.paint(info.note, .dim))
    }
}
