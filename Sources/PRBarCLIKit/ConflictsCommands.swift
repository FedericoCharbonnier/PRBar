import ArgumentParser
import Foundation
import PRBarCore

/// `prbar conflicts` (spec C.5): Resolve Conflicts on your own PRs. Show, diff, test, push, cancel and dismiss are the
/// Respond commands (a Resolve Conflicts is a Respond run in conflicts mode).
struct ConflictsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "conflicts", abstract: "Resolve your PRs’ conflicts with their base with Claude.",
        discussion: "Manual only. PRBar merges the PR’s base into its own worktree, Claude resolves the conflicts without a shell, and nothing is pushed until you push.",
        subcommands: [ConflictsList.self, ConflictsResolve.self, ConflictsShow.self, ConflictsDiff.self, ConflictsTest.self,
                      ConflictsPush.self, ConflictsCancel.self, ConflictsDismiss.self],
        defaultSubcommand: ConflictsList.self)
}

enum ConflictsRender {
    static func list(_ entries: [ConflictsListEntry], _ output: Output) {
        guard !entries.isEmpty else { return output.line("None of your PRs has conflicts.") }
        output.table(["PR", "Title", "Base", "Resolve Conflicts"], entries.map { entry in
            let state = entry.phase ?? entry.otherRun.map { $0 == .ciFix ? "Fix CI in progress" : "respond in progress" }
                ?? (entry.unavailableReason == nil ? "—" : "unavailable")
            return [entry.pr, Render.truncate(entry.title, 50), entry.baseRef, state]
        })
        for entry in entries where entry.phase == nil {
            if let reason = entry.unavailableReason { output.line(output.paint("\(entry.pr): \(reason)", .yellow)) }
        }
    }

    static func info(_ info: RespondInfo, _ output: Output, full: Bool = false) {
        var header = "\(info.pr) · Resolve Conflicts · \(info.runningTests ? "running tests" : info.phase)"
        if let detail = info.detail, info.phase != "failed" { header += " (\(detail))" }
        output.line(output.paint(header, .bold))
        if info.phase == "failed", let detail = info.detail { output.line(output.paint(detail, .red)) }
        if let title = info.title { output.line(title) }
        var pairs: [(String, String)] = []
        if let context = info.conflicts, let head = info.headRef { pairs.append(("Merge", "\(context.baseRef) into \(head)")) }
        if let worktree = info.worktree { pairs.append(("Worktree", worktree)) }
        if let log = info.logPath { pairs.append(("Log", log)) }
        if let usage = info.usage { pairs.append(("Claude", UsageFormat.summary(usage))) }
        Render.pairs(pairs, output)
        if let context = info.conflicts, !context.files.isEmpty {
            output.line()
            let summaries = Dictionary((info.conflictSummaries ?? []).map { ($0.path, $0.summary) }, uniquingKeysWith: { a, _ in a })
            output.table(["File", "Resolution"], context.files.map { file in
                [file.path, file.kind == .byHand ? "kept the PR’s version — resolve by hand (\(file.reason ?? "?"))"
                                                 : summaries[file.path] ?? "—"]
            })
        }
        if let outside = info.outsideConflicts, !outside.isEmpty {
            // Decisión C.9.16: lo que la resolución cambió fuera de los conflictos (el combined diff puede esconderlo).
            output.line()
            output.line(output.paint("Changed outside the conflicts: \(outside.joined(separator: ", ")). Review them before pushing.", .yellow, .bold))
        }
        if let oneSided = info.oneSidedResolutions, !oneSided.isEmpty {
            // Decisión C.9.18: resueltos con un lado entero (el combined diff tampoco los muestra).
            let base = info.conflicts?.baseRef ?? "the base"
            output.line()
            output.line(output.paint("Resolved by keeping one side whole: \(oneSided.map { $0.description(baseRef: base) }.joined(separator: ", ")). Review them before pushing.", .yellow, .bold))
        }
        if let stat = info.diffStat, !stat.isEmpty { output.line(); output.line(stat) }
        if !info.sensitiveChanges.isEmpty {
            output.line(output.paint("The resolution touches files that can run code: \(info.sensitiveChanges.joined(separator: ", ")). Review them before running tests or pushing.", .red, .bold))
        }
        if let tests = info.tests {
            output.line(tests.passed ? output.paint("Tests passed (\(tests.command)).", .green)
                                     : output.paint("Tests failed (\(tests.command)).", .yellow))
            if full, !tests.outputTail.isEmpty { output.line(Render.indent(tests.outputTail)) }
        }
        if info.pushBlockedByTests {
            output.line(output.paint("PRBar didn’t push because the tests failed. Push anyway: prbar conflicts push \(info.pr) --anyway", .yellow))
        }
        if let error = info.errorMessage, info.phase != "failed" { output.line(output.paint(error, .red)) }
    }

    static func pushQuestion(_ info: RespondInfo) -> String {
        let base = info.conflicts?.baseRef ?? "the base"
        var question = "Push the merge of \(base) into \(info.headRef ?? "?") as @\(info.account ?? "?")? PRBar checks the PR on GitHub first; no comment is posted."
        let byHand = info.conflicts?.byHandFiles.map(\.path) ?? []
        if !byHand.isEmpty { question += " PRBar kept the PR’s version of \(byHand.joined(separator: ", ")): resolve them by hand." }
        if let outside = info.outsideConflicts, !outside.isEmpty {
            question += " The resolution also changes files outside the conflicts: \(outside.joined(separator: ", "))."
        }
        if let oneSided = info.oneSidedResolutions, !oneSided.isEmpty {
            question += " Resolved by keeping one side whole: \(oneSided.map { $0.description(baseRef: base) }.joined(separator: ", "))."
        }
        return question + " " + RespondCopy.staleApprovalWarning
    }
}

struct ConflictsList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Your PRs with conflicts and their Resolve Conflicts (also: prbar conflicts).")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .conflictsList }
    func render(_ result: JSONValue, _ output: Output) throws { ConflictsRender.list(try result.decode(), output) }
}

struct ConflictsResolve: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve", abstract: "Merge the PR’s base in PRBar’s worktree and let Claude resolve the conflicts (nothing is pushed).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait for the resolution and print it (Ctrl-C cancels it).") var wait = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .conflictsResolve(pr: pr, wait: wait) }
    var cancelCommand: AppCommand? { wait ? .respondCancel(pr: pr) : nil }
    func render(_ result: JSONValue, _ output: Output) throws { ConflictsRender.info(try result.decode(), output) }
}

struct ConflictsShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "The files in conflict and how Claude resolved each one.")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Also print the test output.") var full = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondShow(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { ConflictsRender.info(try result.decode(), output, full: full) }
}

struct ConflictsDiff: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "diff", abstract: "The resolution’s combined diff (only what differs from both sides).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Only the summary (files and lines).") var stat = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondDiff(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { try RespondDiffCommand.render(result, stat: stat, output) }
}

struct ConflictsTest: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "test", abstract: "Run the repo’s test command in the worktree (look at `prbar conflicts diff` first).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait for the tests (Ctrl-C cancels).") var wait = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondTest(pr: pr, wait: wait) }
    var cancelCommand: AppCommand? { wait ? .respondCancel(pr: pr) : nil }
    func render(_ result: JSONValue, _ output: Output) throws { ConflictsRender.info(try result.decode(), output, full: true) }
}

struct ConflictsPush: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "push", abstract: "Push the merge from this Mac (no comment is posted).",
        discussion: "PRBar first checks on GitHub that the PR is open, still at the commit it merged into and with the same base. Runs your pre-push hooks. Asks for confirmation; without a terminal it needs --yes.")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait until it’s pushed.") var wait = false
    @Flag(help: "Push even though the tests failed (Push Anyway).") var anyway = false
    @OptionGroup var global: GlobalOptions

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        let info: RespondInfo = try connection.run(.respondShow(pr: pr)).decode()
        guard info.mode == .conflicts else {
            throw CommandFailure(.invalidState, "\(info.pr) isn’t a Resolve Conflicts run: use `prbar \(info.mode == .ciFix ? "ci" : "respond") push \(info.pr)`.")
        }
        if anyway && !info.pushBlockedByTests {
            throw CommandFailure(.invalidState, "Nothing is blocked: use `prbar conflicts push \(info.pr)`.")
        }
        guard info.phase == "readyToPush" || info.phase == "failed" else {
            throw CommandFailure(.invalidState, "\(info.pr) has no resolution ready to push (\(info.phase)).")
        }
        if output.terminal.isInteractive && !output.json, let stat = info.diffStat, !stat.isEmpty { output.line(stat) }
        return (anyway ? "Pushing anyway. " : "") + ConflictsRender.pushQuestion(info)
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        // Con el modo: con --yes no hay `confirmation()`, y la app no pushea otra cosa (decisión C.9.9).
        anyway ? .respondPushAnyway(pr: pr, confirmed: confirmed, wait: wait, mode: .conflicts)
            : .respondPush(pr: pr, confirmed: confirmed, wait: wait, mode: .conflicts)
    }
    func render(_ result: JSONValue, _ output: Output) throws { ConflictsRender.info(try result.decode(), output) }
}

struct ConflictsCancel: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "cancel", abstract: "Cancel the Resolve Conflicts that’s running (not a push).")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondCancel(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Canceled.") }
}

struct ConflictsDismiss: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "dismiss", abstract: "Dismiss the resolution and delete PRBar’s worktree (it stays in History).")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        try RespondDiscardQuestion.ask(pr: pr, connection)
    }
    func appCommand(confirmed: Bool) -> AppCommand { .respondDismiss(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Dismissed.") }
}
