import ArgumentParser
import Foundation
import PRBarCore

extension MergeMethod: ExpressibleByArgument {}

/// La confirmación de `prbar merge` y `prbar merge --preview`: lo mismo que muestra la ventana de Merge (spec G.5).
public enum MergePreviewRender {
    public static func question(_ preview: MergePreviewInfo) -> String {
        "\(preview.method.actionTitle) \(preview.pr) at \(preview.headOid.prefix(7))?"
    }

    public static func summary(_ preview: MergePreviewInfo, _ output: Output) {
        output.line(output.paint(preview.pr, .bold) + "  " + preview.title)
        var details = ["\(preview.headRef) → \(preview.baseRef)"]
        if let commits = preview.commitCount { details.append(commits == 1 ? "1 commit" : "\(commits) commits") }
        details.append("head \(preview.headOid.prefix(7))")
        output.line("  " + details.joined(separator: " · "))
        output.line("  \(preview.method.actionTitle)" + (preview.deletesBranch ? " · deletes \(preview.headRef) afterwards" : ""))
        if let problem = preview.problem { output.line("  " + output.paint("Can’t merge yet: \(problem)", .red)) }
        if let note = preview.note { output.line("  " + output.paint("Note: \(note)", .yellow)) }
        if let error = preview.previousError { output.line("  " + output.paint("Last attempt failed: \(error)", .dim)) }
        if let detail = preview.detail {
            prSummary(detail, output)
        } else if let error = preview.detailError {
            output.line("  " + output.paint(error, .yellow))
        }
    }

    /// Lo que muestra la ventana de Merge (spec G.5): descripción, reviews, checks, conversaciones sin resolver y archivos.
    static let maxDescriptionLines = 12

    public static func prSummary(_ detail: MergeDetail, _ output: Output) {
        if let note = detail.incompleteNote {
            output.line()
            output.line(output.paint(note, .yellow))
        }
        output.line()
        output.line(output.paint("Description", .bold))
        let body = detail.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            output.line("  " + output.paint("(no description)", .dim))
        } else {
            let lines = body.components(separatedBy: .newlines)
            for line in lines.prefix(maxDescriptionLines) { output.line("  " + line) }
            if lines.count > maxDescriptionLines {
                output.line("  " + output.paint("… \(lines.count - maxDescriptionLines) more lines (--json has all)", .dim))
            }
        }

        output.line()
        output.line(output.paint("Reviews", .bold) + reviewDecision(detail.reviewDecision, output))
        if detail.reviews.isEmpty { output.line("  " + output.paint("No reviews yet", .dim)) }
        for review in detail.reviews {
            let style: Style = switch review.state {
            case .approved: .green
            case .changesRequested: .red
            case .commented, .dismissed: .dim
            }
            output.line("  \(review.author) · " + output.paint(review.state.title, style))
        }
        if !detail.pendingReviewers.isEmpty {
            output.line("  Waiting for: " + detail.pendingReviewers.joined(separator: ", "))
        }

        output.line()
        output.line(output.paint("Checks: ", .bold) + detail.checksSummary)
        for check in detail.checks where check.state != .passed && check.state != .skipped {
            let style: Style = check.state == .failed ? (check.isRequired ? .red : .yellow) : .dim
            output.line("  " + output.paint("\(check.state.title.lowercased())", style) + "  \(check.name)"
                + (check.isRequired ? " (required)" : "") + (check.url.map { "  \($0.absoluteString)" } ?? ""))
        }
        if detail.moreChecks > 0 { output.line("  and \(detail.moreChecks) more on GitHub") }

        output.line()
        output.line(output.paint(detail.conversationsSummary, detail.conversationsNeedAttention ? .yellow : .dim))

        output.line()
        output.line(output.paint("Files (\(detail.changedFiles))", .bold) + "  +\(detail.additions) −\(detail.deletions)")
        for file in detail.files {
            output.line("  \(file.change.letter) \(file.path)  +\(file.additions) −\(file.deletions)")
        }
        if detail.moreFiles > 0 { output.line("  and \(detail.moreFiles) more on GitHub") }
    }

    private static func reviewDecision(_ decision: ReviewDecision, _ output: Output) -> String {
        switch decision {
        case .approved: "  " + output.paint("Approved", .green)
        case .changesRequested: "  " + output.paint("Changes requested", .red)
        case .reviewRequired: "  " + output.paint("Review required", .yellow)
        case .none: ""
        }
    }
}

/// `prbar merge <pr>`: el botón Merge de Ready to Merge (spec F.6). Muestra lo del diálogo y pregunta; sin terminal
/// exige `--yes`. Siempre mergea el head que mostró (o, con `--yes`, el que avisa en stderr): si alguien pushea
/// entretanto, la app no mergea.
struct MergeCommand: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge", abstract: "Merge a PR of yours that’s Ready to Merge (Merge / Merge With…).",
        discussion: "Uses the repo’s merge method unless you pass --method. Shows the PR’s summary (description, reviews, checks, unresolved conversations, files) and asks; without a terminal it needs --yes. It only merges the head it showed. --preview shows it without merging (--json has all of it); --dismiss clears a merge error from the row. `prbar open <pr> --merge` opens its Merge tab in PRBar’s window.")
    @Argument(help: prHelp) var pr: String
    @Option(help: "squash, merge or rebase (default: the repo’s).") var method: MergeMethod?
    @Flag(help: "Only show what would be merged.") var preview = false
    @Flag(help: "Dismiss the row’s merge error instead of merging.") var dismiss = false
    @OptionGroup var global: GlobalOptions

    /// La vista previa que se mostró (`prepare`): de ahí salen el head confirmado y el método.
    var shown: MergePreviewInfo?

    func validate() throws {
        if dismiss && method != nil { throw ValidationError("--dismiss doesn’t go with --method.") }
        if dismiss && preview { throw ValidationError("Use only one of --dismiss and --preview.") }
    }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard !dismiss, !preview else { return }
        let info: MergePreviewInfo = try connection.run(.mergePreview(pr: pr, method: method)).decode()
        if let problem = info.problem { throw CommandFailure(.invalidState, problem) }
        shown = info
        if global.yes { output.note("Merging \(info.pr) at \(info.headOid.prefix(7)) (\(info.method.actionTitle))…") }
    }

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        guard let shown else { return nil }
        if output.terminal.isInteractive && !output.json { MergePreviewRender.summary(shown, output) }
        return MergePreviewRender.question(shown)
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        if dismiss { return .mergeDismiss(pr: pr) }
        if preview { return .mergePreview(pr: pr, method: method) }
        return .merge(pr: pr, method: method ?? shown?.method, confirmed: confirmed, expectedHeadOid: shown?.headOid ?? "")
    }

    func render(_ result: JSONValue, _ output: Output) throws {
        if dismiss { return output.line("Dismissed the merge error of \(pr).") }
        if preview { return MergePreviewRender.summary(try result.decode(), output) }
        let merged: MergeInfo = try result.decode()
        output.line("Merged \(merged.pr) (\(merged.method.rawValue)): \(merged.url.absoluteString)")
    }

    /// `--preview` de un PR que todavía no se puede mergear muestra el resumen y sale con 6 (como antes, sin resumen).
    func exitCode(for result: JSONValue) throws -> Int32 {
        guard preview, (try? result.decode() as MergePreviewInfo)?.problem != nil else { return CLIExit.ok }
        return CLIExit.invalidState
    }
}
