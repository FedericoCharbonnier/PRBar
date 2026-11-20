import ArgumentParser
import Foundation
import PRBarCore

extension MergeMethod: ExpressibleByArgument {}

/// La pregunta antes de mergear (pública para los tests).
public enum MergeQuestion {
    public static func text(pr: String, method: MergeMethod?) -> String {
        guard let method else { return "Merge \(pr) with the repo’s default method?" }
        return "\(method.actionTitle) \(pr)?"
    }
}

/// `prbar merge <pr>`: el botón Merge de Ready to Merge (spec F.6). Sin terminal exige `--yes`.
struct MergeCommand: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge", abstract: "Merge a PR of yours that’s Ready to Merge (Merge / Merge With…).",
        discussion: "Uses the repo’s merge method unless you pass --method. Asks for confirmation; without a terminal it needs --yes. --dismiss clears a merge error from the row.")
    @Argument(help: prHelp) var pr: String
    @Option(help: "squash, merge or rebase (default: the repo’s).") var method: MergeMethod?
    @Flag(help: "Dismiss the row’s merge error instead of merging.") var dismiss = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if dismiss && method != nil { throw ValidationError("--dismiss doesn’t go with --method.") }
    }

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        guard !dismiss else { return nil }
        let link: PRLink = try connection.run(.resolvePR(pr: pr)).decode()
        return MergeQuestion.text(pr: link.pr, method: method)
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        dismiss ? .mergeDismiss(pr: pr) : .merge(pr: pr, method: method, confirmed: confirmed)
    }

    func render(_ result: JSONValue, _ output: Output) throws {
        guard !dismiss else { return output.line("Dismissed the merge error of \(pr).") }
        let merged: MergeInfo = try result.decode()
        output.line("Merged \(merged.pr) (\(merged.method.rawValue)): \(merged.url.absoluteString)")
    }
}
