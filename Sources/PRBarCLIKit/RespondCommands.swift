import ArgumentParser
import Foundation
import PRBarCore

struct RespondGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "respond", abstract: "Respond to the feedback on your PRs with Claude.",
        discussion: "prbar respond <pr> analyzes the unresolved comments. Comments are numbered like in PRBar’s Respond tab.",
        subcommands: [RespondStart.self, RespondShow.self, RespondSelect.self, RespondImplement.self, RespondTest.self,
                      RespondDiffCommand.self, RespondPush.self, RespondReplyOnly.self, RespondCancel.self, RespondDismiss.self],
        defaultSubcommand: RespondStart.self)
}

enum RespondRender {
    static func info(_ info: RespondInfo, _ output: Output, full: Bool = false) {
        if info.mode == .ciFix { return CIRender.info(info, output, full: full) }
        if info.mode == .conflicts { return ConflictsRender.info(info, output, full: full) }
        var header = "\(info.pr) · \(info.runningTests ? "running tests" : info.phase)"
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
        guard !info.items.isEmpty else { return }
        output.line()
        output.line("\(info.fixes) fix\(info.fixes == 1 ? "" : "es") · \(info.replies) repl\(info.replies == 1 ? "y" : "ies") in \(info.language ?? "English")")
        output.table(["#", "Fix", "Reply", "Reviewer", "Location", "Claude"], info.items.map { item in
            ["\(item.number)", item.implement ? "✓" : "·", item.postedURL != nil ? "posted" : item.reply ? "✓" : "·",
             item.reviewer, item.location + (item.outdated ? " (outdated)" : ""), Render.truncate(item.assessment, 50)]
        })
        if full {
            for item in info.items {
                output.line()
                output.line(output.paint("#\(item.number) \(item.reviewer) · \(item.location) · \(item.id)", .bold))
                item.thread.forEach { output.line(Render.indent($0)) }
                if let url = item.commentURL { output.line("    \(url.absoluteString)") }
                output.line(output.paint("Claude: \(item.assessment)", .violet))
                if item.implement { output.line("Fix plan: \(item.fixPlan)") }
                if item.reply { output.line("Reply: \(item.replyText.isEmpty ? "(only “Fixed in …”)" : item.replyText)") }
                if let url = item.postedURL { output.line("Posted: \(url.absoluteString)") }
            }
        }
        if !info.commits.isEmpty {
            output.line()
            output.table(["Commit", "Status", "Comment", "Summary"], info.commits.map {
                [String(($0.sha ?? "").prefix(7)), $0.status, $0.item, Render.truncate($0.summary, 60)]
            })
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
            output.line(output.paint("PRBar didn’t push because the tests failed. Push anyway: prbar respond push \(info.pr) --anyway", .yellow))
        }
        if let error = info.errorMessage, info.phase != "failed" { output.line(output.paint(error, .red)) }
    }
}

/// Las preguntas de confirmación, con los mismos textos que la ventana (públicas para los tests).
public enum RespondQuestion {
    public static func push(_ info: RespondInfo) -> String {
        let commits = info.commits.filter { $0.status == "committed" && $0.sha != nil }.count
        let pending = info.pendingReplies
        let account = info.account ?? "?"
        let replies = pending == 1 ? "1 reply" : "\(pending) replies"
        if info.pushed { return "Post \(pending == 1 ? "1 pending reply" : "\(pending) pending replies") as @\(account)?" }
        if commits == 0 { return "Post \(replies) as @\(account)?" }
        return "Push \(commits) commit\(commits == 1 ? "" : "s") to \(info.headRef ?? "?") and post \(replies) as @\(account)?"
    }

    public static func replyOnly(_ info: RespondInfo) -> String {
        "Post \(info.replies == 1 ? "1 reply" : "\(info.replies) replies") to \(info.pr) as @\(info.account ?? "?")? Nothing is pushed."
    }
}

struct RespondStart: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Analyze the PR’s unresolved feedback (also: prbar respond <pr>).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait for the analysis and print it (Ctrl-C cancels it).") var wait = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondStart(pr: pr, wait: wait) }
    var cancelCommand: AppCommand? { wait ? .respondCancel(pr: pr) : nil }
    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output) }
}

struct RespondShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "The analysis, your choices and the fixes.")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Also print the threads, plans, replies and test output.") var full = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondShow(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output, full: full) }
}

enum SelectMode: String, EnumerableFlag {
    case implement, replyOnly, skip

    static func help(for value: SelectMode) -> ArgumentHelp? {
        switch value {
        case .implement: "Implement the fix (Reply stays as it is)."
        case .replyOnly: "Only reply, no fix."
        case .skip: "Neither fix nor reply."
        }
    }
}

struct RespondSelect: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "select", abstract: "Choose what to fix and what to reply to.")
    @Argument(help: prHelp) var pr: String
    @Argument(help: "Comments: numbers or ids (thread:…).") var items: [String] = []
    @Flag var mode: SelectMode?
    @Flag(help: "Don’t reply.") var noReply = false
    @Option(help: "The reply’s text (turns Reply on).") var reply: String?
    @Option(help: "The fix plan Claude follows.") var plan: String?
    @Flag(help: "Back to Claude’s suggestions for every comment.") var reset = false
    @OptionGroup var global: GlobalOptions

    private var change: RespondSelectionChange {
        var change = RespondSelectionChange(replyText: reply, fixPlan: plan)
        switch mode {
        case .implement?: change.implement = true
        case .replyOnly?: change.implement = false; change.reply = true
        case .skip?: change.implement = false; change.reply = false
        case nil: break
        }
        if noReply { change.reply = false }
        return change
    }

    func validate() throws {
        if reset {
            guard items.isEmpty, mode == nil, !noReply, reply == nil, plan == nil else {
                throw ValidationError("--reset goes alone.")
            }
            return
        }
        guard !items.isEmpty else { throw ValidationError("Name the comments (numbers or ids), or pass --reset.") }
        guard !change.isEmpty else { throw ValidationError("Pass --implement, --reply-only, --skip, --no-reply, --reply or --plan.") }
        if reply != nil && (mode == .skip || noReply) { throw ValidationError("--reply doesn’t go with --skip or --no-reply.") }
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        reset ? .respondReset(pr: pr) : .respondSelect(pr: pr, items: items, change: change)
    }

    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output) }
}

struct RespondImplement: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "implement", abstract: "Claude implements the chosen fixes (one commit each, nothing pushed).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait for the fixes (Ctrl-C cancels).") var wait = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondImplement(pr: pr, wait: wait) }
    var cancelCommand: AppCommand? { wait ? .respondCancel(pr: pr) : nil }
    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output) }
}

struct RespondTest: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "test", abstract: "Run the repo’s test command in the worktree (look at `prbar respond diff` first).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait for the tests (Ctrl-C cancels).") var wait = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondTest(pr: pr, wait: wait) }
    var cancelCommand: AppCommand? { wait ? .respondCancel(pr: pr) : nil }
    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output, full: true) }
}

struct RespondDiffCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "diff", abstract: "The full diff of the fixes (what would be pushed).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Only the summary (files and lines).") var stat = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondDiff(pr: pr) }

    func render(_ result: JSONValue, _ output: Output) throws { try Self.render(result, stat: stat, output) }

    static func render(_ result: JSONValue, stat: Bool, _ output: Output) throws {
        let diff: RespondDiff = try result.decode()
        if !diff.sensitiveChanges.isEmpty {
            output.line(output.paint("Files that can run code: \(diff.sensitiveChanges.joined(separator: ", "))", .red, .bold))
        }
        guard !stat, let text = diff.diff else { return output.line(diff.diffStat) }
        for line in TextLines.split(text, strippingCarriageReturns: true) {
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git") { output.line(output.paint(line, .bold)) }
            else if line.hasPrefix("@@") { output.line(output.paint(line, .cyan)) }
            else if line.hasPrefix("+") { output.line(output.paint(line, .green)) }
            else if line.hasPrefix("-") { output.line(output.paint(line, .red)) }
            else { output.line(line) }
        }
        if diff.truncated { output.line(output.paint(RespondCopy.diffTruncatedNote, .yellow)) }
    }
}

struct RespondPush: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "push", abstract: "Push the fixes and post the replies (or retry the pending replies).",
        discussion: "Runs your pre-push hooks in PRBar’s worktree. Asks for confirmation; without a terminal it needs --yes.")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait until it’s pushed and posted.") var wait = false
    @Flag(help: "Push even though the tests before the push failed (Push Anyway).") var anyway = false
    @OptionGroup var global: GlobalOptions

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        let info: RespondInfo = try connection.run(.respondShow(pr: pr)).decode()
        // La app no pushea otra clase de corrida con `mode: .feedback`: mejor decirlo antes de preguntar.
        if info.mode == .ciFix || info.mode == .conflicts {
            throw CommandFailure(.invalidState, "\(info.pr) isn’t a Respond run: use `prbar \(info.mode == .ciFix ? "ci" : "conflicts") push \(info.pr)`.")
        }
        if anyway && !info.pushBlockedByTests {
            throw CommandFailure(.invalidState, "Nothing is blocked by failed tests: use `prbar respond push \(info.pr)`.")
        }
        guard info.phase == "readyToPush" || info.phase == "failed" else {
            throw CommandFailure(.invalidState, "\(info.pr) has no fixes ready to push (\(info.phase)).")
        }
        if output.terminal.isInteractive && !output.json {
            if let stat = info.diffStat, !stat.isEmpty { output.line(stat) }
            if !info.sensitiveChanges.isEmpty {
                output.line(output.paint("Claude changed files that can run code: \(info.sensitiveChanges.joined(separator: ", "))", .red, .bold))
            }
            if let tests = info.tests { output.line(tests.passed ? "Tests passed." : output.paint("Tests failed.", .yellow)) }
        }
        return (anyway ? "The tests failed. " : "") + RespondQuestion.push(info)
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        anyway ? .respondPushAnyway(pr: pr, confirmed: confirmed, wait: wait, mode: .feedback)
            : .respondPush(pr: pr, confirmed: confirmed, wait: wait, mode: .feedback)
    }
    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output) }
}

struct RespondReplyOnly: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reply-only", abstract: "Post only the replies (no fixes, nothing pushed).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait until they’re posted.") var wait = false
    @OptionGroup var global: GlobalOptions

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        let info: RespondInfo = try connection.run(.respondShow(pr: pr)).decode()
        guard info.phase == "ready" || info.phase == "failed" else {
            throw CommandFailure(.invalidState, "\(info.pr) has no replies ready to post (\(info.phase)).")
        }
        return RespondQuestion.replyOnly(info)
    }

    func appCommand(confirmed: Bool) -> AppCommand { .respondReplyOnly(pr: pr, confirmed: confirmed, wait: wait) }
    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output) }
}

struct RespondCancel: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "cancel", abstract: "Cancel what’s running (analysis, fixes or tests; not a push).")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondCancel(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Canceled.") }
}

struct RespondDismiss: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "dismiss", abstract: "Dismiss the analysis and delete PRBar’s worktree (it stays in History).")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        try RespondDiscardQuestion.ask(pr: pr, connection)
    }
    func appCommand(confirmed: Bool) -> AppCommand { .respondDismiss(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Dismissed.") }
}

/// `respond dismiss` / `ci dismiss` con commits o cambios sin pushear en el worktree: pregunta (sin terminal, --yes).
enum RespondDiscardQuestion {
    static func ask(pr: String, _ connection: AppConnection) throws -> String? {
        // Si no se puede leer el estado, el dismiss mismo dice por qué no hay nada que descartar.
        guard let info: RespondInfo = try? connection.run(.respondShow(pr: pr)).decode(), info.unpushedWork == true else {
            return nil
        }
        return RespondDiscardCopy.message(worktree: info.worktree) + " Discard them?"
    }
}
