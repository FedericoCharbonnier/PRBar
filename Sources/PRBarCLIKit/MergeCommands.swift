import ArgumentParser
import Foundation
import PRBarCore

extension MergeMethod: ExpressibleByArgument {}

/// La confirmación de `prbar merge` y `prbar merge --preview`: lo mismo que muestra el diálogo de Merge.
enum MergePreviewRender {
    static func question(_ preview: MergePreviewInfo) -> String {
        "\(preview.method.actionTitle) \(preview.pr) at \(preview.headOid.prefix(7))?"
    }

    static func summary(_ preview: MergePreviewInfo, _ output: Output) {
        output.line(output.paint(preview.pr, .bold) + "  " + preview.title)
        var details = ["\(preview.headRef) → \(preview.baseRef)"]
        if let commits = preview.commitCount { details.append(commits == 1 ? "1 commit" : "\(commits) commits") }
        details.append("head \(preview.headOid.prefix(7))")
        output.line("  " + details.joined(separator: " · "))
        output.line("  \(preview.method.actionTitle)" + (preview.deletesBranch ? " · deletes \(preview.headRef) afterwards" : ""))
        if let note = preview.note { output.line("  " + output.paint("Note: \(note)", .yellow)) }
        if let error = preview.previousError { output.line("  " + output.paint("Last attempt failed: \(error)", .dim)) }
    }
}

/// `prbar merge <pr>`: el botón Merge de Ready to Merge (spec F.6). Muestra lo del diálogo y pregunta; sin terminal
/// exige `--yes`. Siempre mergea el head que mostró (o, con `--yes`, el que avisa en stderr): si alguien pushea
/// entretanto, la app no mergea.
struct MergeCommand: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge", abstract: "Merge a PR of yours that’s Ready to Merge (Merge / Merge With…).",
        discussion: "Uses the repo’s merge method unless you pass --method. Shows the PR (branches, commits, head) and asks; without a terminal it needs --yes. It only merges the head it showed. --preview shows it without merging; --dismiss clears a merge error from the row.")
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
}
