import ArgumentParser
import Foundation
import PRBarCore

/// `prbar rules …`: Settings › Instructions (spec E.1–E.4, E.7).
struct RulesGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules", abstract: "Rules Claude follows in your reviews and fixes (Settings › Instructions).",
        discussion: "Rules go in every Claude prompt in a delimited section; a PR’s content is never treated as instructions. Rule ids can be shortened to their first 4+ characters.",
        subcommands: [RulesList.self, RulesAdd.self, RulesEdit.self, RulesRemove.self, RulesEnable.self, RulesDisable.self,
                      RulesChat.self, RulesSuggestionsGroup.self, RulesProposalGroup.self])
}

enum RulesRender {
    static func stages(_ stages: [RuleStage]) -> String {
        stages.map { $0 == .respond ? "fixes" : "review" }.joined(separator: ", ")
    }

    static func list(_ rules: [RuleInfo], _ output: Output) {
        guard !rules.isEmpty else { return output.line("No rules. Add one with `prbar rules add \"…\"`.") }
        output.table(["ID", "Scope", "Applies to", "On", "Source", "Text"], rules.map {
            [String($0.id.prefix(8)).lowercased(), $0.scope, stages($0.appliesTo), Render.onOff($0.enabled), $0.source,
             Render.truncate($0.text, 60)]
        })
    }
}

/// `--review`/`--no-review` y `--fixes`/`--no-fixes` sobre las etapas que ya tiene (lo no nombrado queda igual).
public struct StageFlags: ParsableArguments {
    @Flag(inversion: .prefixedNo, help: "Applies to reviews.") var review: Bool?
    @Flag(inversion: .prefixedNo, help: "Applies to responses and fixes.") var fixes: Bool?

    public init() {}

    public var isEmpty: Bool { review == nil && fixes == nil }

    public func applied(to current: [RuleStage]) -> [RuleStage] {
        var stages = Set(current)
        if let review { if review { stages.insert(.review) } else { stages.remove(.review) } }
        if let fixes { if fixes { stages.insert(.respond) } else { stages.remove(.respond) } }
        return stages.sorted()
    }
}

struct RulesList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Your rules (with --repo, the ones that apply to that repo’s PRs).")
    @Option(help: "Only the rules for this repo’s PRs (owner/repo): its own and the global ones.") var repo: String?
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .rulesList(repo: repo) }
    func render(_ result: JSONValue, _ output: Output) throws { RulesRender.list(try result.decode(), output) }
}

struct RulesAdd: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a rule Claude follows in your reviews and fixes.")
    @Argument(help: "The rule.") var text: String
    @Option(help: "Only this repo (owner/repo); default: global.") var repo: String?
    @Flag(help: "Applies to reviews.") var review = false
    @Flag(help: "Applies to responses and fixes.") var fixes = false
    @OptionGroup var global: GlobalOptions

    /// Sin --review ni --fixes: las dos (como la fila "Add a rule…").
    var stages: [RuleStage] { review == fixes ? [.review, .respond] : review ? [.review] : [.respond] }

    func appCommand(confirmed: Bool) -> AppCommand {
        .rulesAdd(text: text, scope: repo.map { .repo($0) } ?? .global, appliesTo: stages)
    }

    func render(_ result: JSONValue, _ output: Output) throws { RulesRender.list([try result.decode()], output) }
}

struct RulesEdit: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Change a rule’s text, scope or stages.")
    @Argument(help: "The rule’s id (or its first 4+ characters).") var id: String
    @Option(help: "New text.") var text: String?
    @Option(help: "Move it to this repo (owner/repo).") var repo: String?
    @Flag(name: .customLong("global"), help: "Make it global.") var makeGlobal = false
    @OptionGroup var stageFlags: StageFlags
    @OptionGroup var global: GlobalOptions

    /// Las etapas finales (se completan en `prepare` con las que la regla ya tiene).
    var stages: [RuleStage]?

    var scope: RuleScope? { makeGlobal ? .global : repo.map { .repo($0) } }

    func validate() throws {
        if makeGlobal && repo != nil { throw ValidationError("Use --repo or --global, not both.") }
        guard text != nil || scope != nil || !stageFlags.isEmpty else { throw ValidationError("Nothing to change.") }
    }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard !stageFlags.isEmpty else { return }
        let rules: [RuleInfo] = try connection.run(.rulesList(repo: nil)).decode()
        let wanted = id.lowercased()
        let matches = rules.filter { $0.id.lowercased() == wanted || (wanted.count >= 4 && $0.id.lowercased().hasPrefix(wanted)) }
        guard matches.count == 1, let current = matches.first else {
            throw CommandFailure(matches.isEmpty ? .notFound : .invalidUsage,
                                 matches.isEmpty ? "There’s no rule \(id). Run `prbar rules list`." : "\(id) matches several rules: use more characters.")
        }
        stages = stageFlags.applied(to: current.appliesTo)
        if stages?.isEmpty == true { throw CommandFailure(.invalidUsage, "A rule applies to reviews, fixes or both.") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .rulesEdit(id: id, text: text, scope: scope, appliesTo: stages) }
    func render(_ result: JSONValue, _ output: Output) throws { RulesRender.list([try result.decode()], output) }
}

struct RulesRemove: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Delete a rule (Delete Rule).")
    @Argument(help: "The rule’s id (or its first 4+ characters).") var id: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .rulesRemove(id: id) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Deleted.") }
}

struct RulesEnable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Turn a rule on.")
    @Argument(help: "The rule’s id (or its first 4+ characters).") var id: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .rulesSetEnabled(id: id, enabled: true) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Rule on.") }
}

struct RulesDisable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Turn a rule off (it’s kept).")
    @Argument(help: "The rule’s id (or its first 4+ characters).") var id: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .rulesSetEnabled(id: id, enabled: false) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Rule off.") }
}

/// El chat de Settings › Instructions: Claude solo cambia tus reglas, y se puede deshacer.
struct RulesChat: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat", abstract: "Ask Claude to add, change or remove rules (the Instructions chat).",
        discussion: "Without a message, in a terminal: an interactive chat (/undo, /show, /stop, /quit). Without a terminal the message is read from stdin.")
    @Argument(help: "The message.") var message: String?
    @Flag(help: "Undo the last change Claude made to your rules.") var undo = false
    @Flag(help: "Print the conversation.") var show = false
    @Flag(help: "Stop the answer that’s running.") var stop = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard [message != nil, undo, show, stop].filter({ $0 }).count <= 1 else {
            throw ValidationError("Use one of: a message, --undo, --show or --stop.")
        }
    }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard message == nil, !undo, !show, !stop else { return }
        message = try ChatInput.readMessage(terminal: output.terminal)
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        if undo { return .rulesChatUndo(confirmed: confirmed) }
        if show { return .rulesChatShow }
        if stop { return .rulesChatStop }
        return .rulesChatSend(message: message ?? "")
    }

    var cancelCommand: AppCommand? { message != nil ? .rulesChatStop : nil }

    func render(_ result: JSONValue, _ output: Output) throws {
        let info: ChatInfo = try result.decode()
        if show || undo { ChatRender.transcript(info, output) } else if stop { output.line("Stopped.") } else { ChatRender.reply(info, output) }
    }

    mutating func run() throws {
        let terminal = Terminal.current()
        if message == nil && !undo && !show && !stop && terminal.isInteractive && !global.json {
            return try ChatREPL.run(
                show: .rulesChatShow, send: { .rulesChatSend(message: $0) }, undo: { .rulesChatUndo(confirmed: $0) },
                stop: .rulesChatStop, hint: "Ask Claude to add, change or remove rules."
            )
        }
        do {
            try CLIRunner.run(self)
        } catch let exit as ExitCode where exit.rawValue == CLIExit.confirmationRequired && undo
                    && ChatInput.asksUndoAnyway(terminal: terminal, json: global.json) {
            guard Prompt.confirm("Undo anyway?") else { throw ExitCode(CLIExit.cancelled) }
            var confirmed = self
            confirmed.global.yes = true
            try CLIRunner.run(confirmed)
        }
    }
}

// MARK: - Sugerencias

struct RulesSuggestionsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "suggestions", abstract: "Rules PRBar suggests from what you discard (Create Rule / Not Now / Never).",
        subcommands: [RulesSuggestionsList.self, RulesSuggestionAccept.self, RulesSuggestionDismiss.self, RulesSuggestionNever.self],
        defaultSubcommand: RulesSuggestionsList.self)
}

struct RulesSuggestionsList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The current suggestions (also: prbar rules suggestions).")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .rulesSuggestions }

    func render(_ result: JSONValue, _ output: Output) throws {
        let suggestions: [RuleSuggestionInfo] = try result.decode()
        guard !suggestions.isEmpty else { return output.line("No suggestions.") }
        for suggestion in suggestions {
            output.line(output.paint("\(suggestion.id) · \(suggestion.scope) · \(suggestion.category)", .bold))
            output.line(Render.indent(suggestion.reason.replacingOccurrences(of: "**", with: "")))
            output.line(Render.indent("Rule: \(suggestion.proposedText)"))
        }
    }
}

struct RulesSuggestionAccept: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "accept", abstract: "Create the suggested rule (Create Rule).")
    @Argument(help: "The suggestion’s id.") var id: String
    @Option(help: "The rule’s text, instead of the suggested one.") var text: String?
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .rulesSuggestionAct(id: id, action: .accept, text: text) }
    func render(_ result: JSONValue, _ output: Output) throws { RulesRender.list(try result.decode(), output) }
}

struct RulesSuggestionDismiss: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "dismiss", abstract: "Hide it for 30 days (Not Now).")
    @Argument(help: "The suggestion’s id.") var id: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .rulesSuggestionAct(id: id, action: .dismiss, text: nil) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Hidden for 30 days.") }
}

struct RulesSuggestionNever: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "never", abstract: "Never suggest it again (Never).")
    @Argument(help: "The suggestion’s id.") var id: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .rulesSuggestionAct(id: id, action: .never, text: nil) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("It won’t be suggested again.") }
}

// MARK: - Tarjetas "Save as rule" del chat del PR

struct RulesProposalGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proposal", abstract: "Rules Claude proposed in a PR’s chat (the “Save as rule” cards).",
        discussion: "The cards are numbered from 1 among the pending ones (`prbar chat <pr> --show`).",
        subcommands: [RulesProposalSave.self, RulesProposalDismiss.self])
}

struct RulesProposalSave: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "save", abstract: "Save a proposed rule (Save), optionally edited.")
    @Argument(help: prHelp) var pr: String
    @Argument(help: "The card’s number.") var number: Int
    @Option(help: "The rule’s text, instead of the proposed one.") var text: String?
    @Flag(name: .customLong("global"), help: "Make it global.") var makeGlobal = false
    @Flag(name: .customLong("this-repo"), help: "Only for this PR’s repo.") var thisRepo = false
    @OptionGroup var stageFlags: StageFlags
    @OptionGroup var global: GlobalOptions

    var scope: RuleScope?
    var stages: [RuleStage]?

    func validate() throws {
        if makeGlobal && thisRepo { throw ValidationError("Use --global or --this-repo, not both.") }
    }

    /// El repo y las etapas que propuso Claude, para aplicar --this-repo y --review/--fixes.
    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard thisRepo || !stageFlags.isEmpty else {
            scope = makeGlobal ? .global : nil
            return
        }
        let chat: ChatInfo = try connection.run(.chatShow(pr: pr)).decode()
        guard let proposal = chat.messages.flatMap(\.proposals).first(where: { $0.number == number }) else {
            throw CommandFailure(.notFound, "There’s no pending rule #\(number) in \(chat.pr)’s chat. Run `prbar chat \(chat.pr) --show`.")
        }
        if makeGlobal {
            scope = .global
        } else if thisRepo {
            guard let repo = chat.pr.split(separator: "#").first, repo.contains("/") else {
                throw CommandFailure(.failed, "Couldn’t read the PR’s repo.")
            }
            scope = .repo(String(repo))
        }
        if !stageFlags.isEmpty {
            stages = stageFlags.applied(to: proposal.appliesTo)
            if stages?.isEmpty == true { throw CommandFailure(.invalidUsage, "A rule applies to reviews, fixes or both.") }
        }
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        .chatProposal(pr: pr, number: number, save: true, text: text, scope: scope ?? (makeGlobal ? .global : nil), appliesTo: stages)
    }

    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved as a rule (`prbar rules list`).") }
}

struct RulesProposalDismiss: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "dismiss", abstract: "Dismiss a proposed rule (Dismiss).")
    @Argument(help: prHelp) var pr: String
    @Argument(help: "The card’s number.") var number: Int
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .chatProposal(pr: pr, number: number, save: false, text: nil) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Dismissed.") }
}
