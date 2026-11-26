import ArgumentParser
import Foundation
import PRBarCore

struct ReviewGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review", abstract: "Review other people’s PRs with Claude.",
        discussion: "prbar review <pr> starts a review. Findings are numbered like in PRBar’s Review tab (#N).",
        subcommands: [ReviewStart.self, ReviewShow.self, ReviewEdit.self, ReviewInclude.self, ReviewExclude.self,
                      ReviewComment.self, ReviewPublish.self, ReviewCancel.self, ReviewDismiss.self],
        defaultSubcommand: ReviewStart.self)
}

enum ReviewRender {
    static func info(_ info: ReviewInfo, _ output: Output, full: Bool = false) {
        var header = "\(info.pr) · \(info.phase)"
        if let detail = info.detail, info.phase != "failed" { header += " (\(detail))" }
        output.line(output.paint(header, .bold))
        if info.phase == "failed", let detail = info.detail { output.line(output.paint(detail, .red)) }
        if let log = info.logPath { output.line("Log: \(log)") }
        if let url = info.reviewURL { output.line("Posted: \(url.absoluteString)") }
        guard info.phase == "ready" else { return }
        if let title = info.title { output.line(title) }
        if info.outdated { output.line(output.paint("The PR changed since the review: comments will go in the review body.", .yellow)) }
        if let usage = info.usage { output.line(output.paint("Claude: \(UsageFormat.summary(usage))", .dim)) }
        if let summary = info.summary, !summary.isEmpty { output.line(); output.line(summary) }
        if let previous = info.previous, !previous.isEmpty {
            output.line()
            let fixed = previous.filter { $0.status == .fixed }.count
            let since = info.reviewedSince.map { " at \($0.prefix(7))" } ?? ""
            output.line(output.paint("Previous comments", .bold) + " · reviewed before\(since) · \(fixed) fixed · \(previous.count - fixed) pending")
            output.table(["", "Status", "GitHub", "Location", "Note"], previous.map { comment in
                [comment.id, comment.status.title, github(comment), comment.location, Render.truncate(comment.note, 60)]
            })
            if full {
                for comment in previous {
                    output.line()
                    output.line(output.paint("\(comment.id) \(comment.location)", .bold))
                    output.line(Render.indent(comment.text))
                }
            }
        }
        output.line()
        let selected = info.findings.filter(\.included).count
        output.line("\(selected) of \(info.findings.count) selected · posting as @\(info.account ?? "?") in \(info.language ?? "English")")
        output.table(["#", "", "Severity", "Location", "Title"], info.findings.map { finding in
            ["\(finding.number)", finding.included ? "✓" : "·", finding.severity.rawValue, finding.location,
             Render.truncate(finding.title, 60) + (finding.edited ? " (edited)" : "") + (finding.keptByFilter ? "" : " [discarded by the filter]")
                + (finding.hiddenBy.map { " [hidden by your settings: \($0)]" } ?? "")]
        })
        if full {
            for finding in info.findings {
                output.line()
                output.line(output.paint("#\(finding.number) \(finding.title)", .bold))
                if let reason = finding.filterReason { output.line(output.paint("Filter: \(reason)", .dim)) }
                output.line(Render.indent(finding.body))
            }
        }
        if let general = info.generalComment { output.line(); output.line("General comment: \(general)") }
        if let recommended = info.recommendedAction {
            output.line()
            output.line("Recommended: \(recommended.event.title) — \(recommended.reason)")
        }
    }

    static func github(_ comment: PreviousCommentInfo) -> String {
        comment.github == .unknown ? "unknown" : comment.outdated ? "\(comment.github.rawValue), outdated" : comment.github.rawValue
    }
}

/// La pregunta antes de publicar (pública para los tests).
public enum ReviewQuestion {
    public static func text(event: ReviewEvent, pr: String, account: String, comments: Int, general: Bool) -> String {
        let verb = switch event {
        case .approve: "Approve \(pr)"
        case .requestChanges: "Request changes on \(pr)"
        case .comment: "Comment on \(pr)"
        }
        var parts: [String] = []
        if comments > 0 { parts.append(comments == 1 ? "1 comment" : "\(comments) comments") }
        if general { parts.append("a general comment") }
        let what = parts.isEmpty ? "without comments" : "with " + parts.joined(separator: " and ")
        return "\(verb) as @\(account) \(what)?"
    }
}

struct ReviewStart: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Review a PR with Claude (also: prbar review <pr>).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait until the review is ready and print it (Ctrl-C cancels the review).") var wait = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .reviewStart(pr: pr, wait: wait) }
    var cancelCommand: AppCommand? { wait ? .reviewCancel(pr: pr) : nil }
    func render(_ result: JSONValue, _ output: Output) throws { ReviewRender.info(try result.decode(), output) }
}

struct ReviewShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "The review’s findings, selection and texts.")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Also print each finding’s comment.") var full = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .reviewShow(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { ReviewRender.info(try result.decode(), output, full: full) }
}

struct ReviewEdit: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Edit a finding’s title or comment.")
    @Argument(help: prHelp) var pr: String
    @Argument(help: "The finding’s number (#N) or id.") var finding: String
    @Option(help: "New title.") var title: String?
    @Option(help: "New comment (Markdown).") var body: String?
    @Option(help: "Read the comment from a file (- = stdin).") var bodyFile: String?
    @Flag(help: "Edit the comment in $EDITOR.") var editor = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard [body != nil, bodyFile != nil, editor].filter({ $0 }).count <= 1 else {
            throw ValidationError("Use only one of --body, --body-file and --editor.")
        }
        guard title != nil || body != nil || bodyFile != nil || editor else {
            throw ValidationError("Pass --title, --body, --body-file or --editor.")
        }
    }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        if let bodyFile {
            body = bodyFile == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                : try String(contentsOfFile: absolutePath(bodyFile), encoding: .utf8)
        } else if editor {
            let info: ReviewInfo = try connection.run(.reviewShow(pr: pr)).decode()
            guard let current = info.findings.first(where: { String($0.number) == finding || $0.id == finding }) else {
                throw CommandFailure(.notFound, "There’s no finding \(finding). Run `prbar review show \(pr)`.")
            }
            body = try Editor.edit(current.body)
        }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .reviewEdit(pr: pr, finding: finding, title: title, body: body) }
    func render(_ result: JSONValue, _ output: Output) throws { ReviewRender.info(try result.decode(), output) }
}

struct ReviewInclude: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "include", abstract: "Post these findings (checkbox on; --all = Select All).")
    @Argument(help: prHelp) var pr: String
    @Argument(help: "Findings: numbers (#N) or ids.") var findings: [String] = []
    @Flag(help: "Every finding the filter kept (Select All).") var all = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard all != !findings.isEmpty else { throw ValidationError("Name the findings or pass --all (not both).") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .reviewSetIncluded(pr: pr, findings: findings, all: all, included: true) }
    func render(_ result: JSONValue, _ output: Output) throws { ReviewRender.info(try result.decode(), output) }
}

struct ReviewExclude: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "exclude", abstract: "Don’t post these findings (checkbox off; --all = Select None).")
    @Argument(help: prHelp) var pr: String
    @Argument(help: "Findings: numbers (#N) or ids.") var findings: [String] = []
    @Flag(help: "All of them (Select None).") var all = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard all != !findings.isEmpty else { throw ValidationError("Name the findings or pass --all (not both).") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .reviewSetIncluded(pr: pr, findings: findings, all: all, included: false) }
    func render(_ result: JSONValue, _ output: Output) throws { ReviewRender.info(try result.decode(), output) }
}

struct ReviewComment: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "comment", abstract: "The review’s general comment (empty = none).")
    @Argument(help: prHelp) var pr: String
    @Option(help: "The text.") var text: String?
    @Flag(help: "Edit it in $EDITOR.") var editor = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard (text != nil) != editor else { throw ValidationError("Pass --text or --editor.") }
    }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard editor else { return }
        let info: ReviewInfo = try connection.run(.reviewShow(pr: pr)).decode()
        text = try Editor.edit(info.generalComment ?? "")
    }

    func appCommand(confirmed: Bool) -> AppCommand { .reviewSetComment(pr: pr, text: text ?? "") }
    func render(_ result: JSONValue, _ output: Output) throws { ReviewRender.info(try result.decode(), output) }
}

enum PublishEvent: String, EnumerableFlag {
    case comment, requestChanges, approve, recommended

    init(_ event: ReviewEvent) {
        switch event {
        case .comment: self = .comment
        case .requestChanges: self = .requestChanges
        case .approve: self = .approve
        }
    }

    /// nil for `--recommended` until `ReviewPublish.prepare` resolves it.
    var event: ReviewEvent? {
        switch self {
        case .comment: .comment
        case .requestChanges: .requestChanges
        case .approve: .approve
        case .recommended: nil
        }
    }

    static func help(for value: PublishEvent) -> ArgumentHelp? {
        value == .recommended ? "Use PRBar’s recommended decision for the current selection (see `prbar review show`)." : nil
    }
}

struct ReviewPublish: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish", abstract: "Post the review to GitHub.",
        discussion: "In a terminal, without --only, you choose the comments in a list (space, e = edit in $EDITOR, ↩) and confirm. Without a terminal it needs --yes. --recommended uses PRBar’s recommended decision for the current selection (no list).")
    @Argument(help: prHelp) var pr: String
    @Flag var event: PublishEvent
    @Option(help: "Post only these findings (numbers or ids, comma-separated) instead of the selection.") var only: String?
    @Flag(help: "Post only the verdict (Approve Without Comments).") var noComments = false
    @Flag(help: "Put every comment in the review body (if GitHub rejected the inline ones).") var allInBody = false
    /// Set by `prepare` when it resolved `--recommended`: the list isn't shown (the recommendation is for the selection as
    /// it is, decision 14).
    @Flag(help: .private) var resolvedRecommendation = false
    @OptionGroup var global: GlobalOptions

    private var onlyList: [String]? {
        only.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }

    func validate() throws {
        if event == .recommended && (only != nil || noComments) {
            throw ValidationError("--recommended doesn’t go with --only or --no-comments: it uses the current selection.")
        }
        if noComments && event != .approve { throw ValidationError("--no-comments only goes with --approve.") }
        if noComments && only != nil { throw ValidationError("--no-comments and --only don’t go together.") }
    }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard event == .recommended else { return }
        let info: ReviewInfo = try connection.run(.reviewShow(pr: pr)).decode()
        guard info.phase == "ready" else {
            throw CommandFailure(.invalidState, "There’s no review ready to post for \(info.pr). Run `prbar review \(info.pr)` first.")
        }
        guard let recommended = info.recommendedAction else {
            throw CommandFailure(.invalidState, "PRBar has no recommended decision for \(info.pr). Use --comment, --request-changes or --approve.")
        }
        event = PublishEvent(recommended.event)
        resolvedRecommendation = true
        if !output.json { output.line("Recommended: \(recommended.event.title) — \(recommended.reason)") }
    }

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        var info: ReviewInfo = try connection.run(.reviewShow(pr: pr)).decode()
        guard info.phase == "ready" else {
            throw CommandFailure(.invalidState, "There’s no review ready to post for \(info.pr). Run `prbar review \(info.pr)` first.")
        }
        if output.terminal.isInteractive, !output.json, only == nil, !noComments, !resolvedRecommendation {
            guard let chosen = try ReviewPicker.run(info: info, connection: connection, output: output) else {
                throw CommandFailure(.cancelled, "Canceled.")
            }
            info = chosen
        }
        let comments = noComments ? 0 : onlyList?.count ?? info.findings.filter(\.included).count
        let general = !noComments && !(info.generalComment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let chosen = event.event else { throw CommandFailure(.invalidUsage, "PRBar couldn’t resolve the recommended decision.") }
        return ReviewQuestion.text(event: chosen, pr: info.pr, account: info.account ?? "?", comments: comments, general: general)
    }

    func appCommand(confirmed: Bool) throws -> AppCommand {
        guard let chosen = event.event else {
            throw CommandFailure(.invalidUsage, "PRBar couldn’t resolve the recommended decision.")
        }
        return .reviewPublish(pr: pr, event: chosen, only: onlyList, withComments: !noComments, allInBody: allInBody, confirmed: confirmed)
    }

    func render(_ result: JSONValue, _ output: Output) throws {
        let posted: PublishedReviewInfo = try result.decode()
        output.line("Posted (\(posted.action), \(posted.comments) comment\(posted.comments == 1 ? "" : "s")): \(posted.url.absoluteString)")
    }
}

/// La lista con casillas de `review publish` en la terminal. Lo que se elige y edita se aplica en la app
/// (`include`/`exclude`/`edit`), así la ventana muestra lo mismo.
enum ReviewPicker {
    static func label(_ finding: FindingInfo) -> String {
        "#\(finding.number) \(finding.severity.rawValue) \(finding.location) — \(Render.truncate(finding.title, 60))\(finding.edited ? " (edited)" : "")"
    }

    static func run(info: ReviewInfo, connection: AppConnection, output: Output) throws -> ReviewInfo? {
        var current = info
        let list = CheckboxList(rows: info.findings.map { .init(label: label($0), checked: $0.included) })
        let title = "Choose the comments to post — space: toggle · e: edit · a/n: all/none · ↩: done · q: cancel"
        let final = try CheckboxPicker.run(title: title, list: list, output: output) { index in
            let finding = current.findings[index]
            let edited = try Editor.edit(finding.body)
            guard edited != finding.body else { return nil }
            current = try connection.run(.reviewEdit(pr: info.pr, finding: String(finding.number), title: nil, body: edited)).decode()
            return label(current.findings[index])
        }
        guard let final else { return nil }
        let numbers = current.findings.map { String($0.number) }
        let include = final.rows.indices.filter { final.rows[$0].checked }.map { numbers[$0] }
        let exclude = final.rows.indices.filter { !final.rows[$0].checked }.map { numbers[$0] }
        if !include.isEmpty {
            current = try connection.run(.reviewSetIncluded(pr: info.pr, findings: include, all: false, included: true)).decode()
        }
        if !exclude.isEmpty {
            current = try connection.run(.reviewSetIncluded(pr: info.pr, findings: exclude, all: false, included: false)).decode()
        }
        return current
    }
}

struct ReviewCancel: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "cancel", abstract: "Cancel a running review.")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .reviewCancel(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Canceled the review of \(pr).") }
}

struct ReviewDismiss: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "dismiss", abstract: "Dismiss a finished review (it stays in History).")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .reviewDismiss(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Dismissed the review of \(pr).") }
}
