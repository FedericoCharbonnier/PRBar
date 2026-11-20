import ArgumentParser
import Foundation
import PRBarCore

struct SlackGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slack", abstract: "Slack announcements and reactions (Settings › Slack).",
        subcommands: [SlackShow.self, SlackEnable.self, SlackDisable.self, SlackProviderCommand.self, SlackTokenGroup.self,
                      SlackSet.self, SlackEmoji.self, SlackSearchDays.self, SlackTemplateGroup.self, SlackCheck.self,
                      SlackTest.self, SlackChannels.self])
}

struct SlackShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Slack’s settings and connection (never the token).")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackShow }

    func render(_ result: JSONValue, _ output: Output) throws {
        let info: SlackInfo = try result.decode()
        Render.pairs([
            ("Slack", Render.onOff(info.enabled)),
            ("Connect with", info.provider == .claudeConnector ? "Claude’s Slack connector" : "Slack user token"),
            ("Connected", info.connected ? "yes" : "no"),
            ("Token saved", info.hasToken ? "yes" : "no"),
            ("Search days", "\(info.searchDays)"),
        ], output)
        output.table(["Toggle", "On"], SlackToggleName.allCases.map { [$0.rawValue, Render.onOff(info.toggles[$0.rawValue] ?? false)] })
        output.table(["Emoji", "Name"], SlackEmojiKind.allCases.map { [$0.rawValue, info.emojis[$0.rawValue] ?? ""] })
        if info.needsUserToken { output.line(output.paint("PRBar now posts as you: run `prbar slack token set`.", .red)) }
        for issue in info.issues { output.line(output.paint("! " + issue, .red)) }
    }
}

struct SlackEnable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Use Slack.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackSetEnabled(enabled: true) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Slack on.") }
}

struct SlackDisable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Stop using Slack.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackSetEnabled(enabled: false) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Slack off.") }
}

enum ProviderName: String, ExpressibleByArgument, CaseIterable {
    case connector, token

    var provider: SlackProvider { self == .connector ? .claudeConnector : .userToken }
}

struct SlackProviderCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "provider", abstract: "Connect with Claude’s Slack connector or a user token.")
    @Argument(help: "connector or token.") var provider: ProviderName
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackSetProvider(provider: provider.provider) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

struct SlackTokenGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "token", abstract: "The Slack user token (Keychain).",
                                                    subcommands: [SlackTokenSet.self, SlackTokenClear.self])
}

/// Cómo `prbar slack token set` lee el token (público para que los tests lo reemplacen). `true` = de stdin.
public enum SlackTokenInput {
    nonisolated(unsafe) public static var read: (Bool) throws -> String = { fromStdin in
        let raw: String?
        if fromStdin {
            raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        } else if isatty(STDIN_FILENO) == 1 {
            raw = Prompt.secret("Slack user token (xoxp-…): ")
        } else {
            throw CommandFailure(.invalidUsage, "Pass the token on stdin with --stdin.")
        }
        guard let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw CommandFailure(.invalidUsage, "No token.")
        }
        return token
    }

}

struct SlackTokenSet: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Save a User OAuth Token (xoxp-…) and test it (Save and Test).",
        discussion: "Asks for it without echo, or reads it from stdin with --stdin. It never goes on the command line.")
    @Flag(help: "Read the token from stdin.") var stdin = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) throws -> AppCommand { .slackTokenSet(token: try SlackTokenInput.read(stdin)) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let check: SlackCheckInfo = try result.decode()
        output.line("Saved. Connected as @\(check.user) on \(check.team).")
    }
}

struct SlackTokenClear: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Delete the token from Keychain (Delete Token…).")
    @OptionGroup var global: GlobalOptions
    var confirmationPolicy: ConfirmationPolicy { .interactiveOnly }
    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        "Delete the Slack token? PRBar stops posting in Slack until you save a new one."
    }
    func appCommand(confirmed: Bool) -> AppCommand { .slackTokenClear }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Token deleted.") }
}

struct SlackSet: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Turn an announcement or reaction on or off.",
        discussion: "announce, updated, merged (reply “Merged” when I merge from PRBar), react-start (👀), react-comment (💬), rounds (commented xN), react-approve")
    @Argument var toggle: SlackToggleName
    @Argument var value: OnOff
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackSetToggle(toggle: toggle, enabled: value.isOn) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

struct SlackEmoji: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "emoji", abstract: "The emoji of a reaction (name without colons).")
    @Argument(help: "eyes, comment or approved.") var kind: SlackEmojiKind
    @Argument(help: "The emoji’s name in your workspace.") var name: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackSetEmoji(kind: kind, name: name) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

struct SlackSearchDays: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "search-days", abstract: "How many days back to look for the PR’s message (7–90).")
    @Argument var days: Int
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackSetSearchDays(days: days) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

struct SlackTemplateGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template", abstract: "Message templates (new-pr, update, round, merged).",
                                                    subcommands: [SlackTemplateList.self, SlackTemplateShow.self, SlackTemplateSet.self, SlackTemplateReset.self])
}

struct SlackTemplateList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The message templates.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackTemplateList }
    func render(_ result: JSONValue, _ output: Output) throws {
        let templates: [TemplateInfo] = try result.decode()
        output.table(["Name", "Text", "Default"], templates.map { [$0.name, Render.truncate($0.text, 60), $0.isDefault ? "yes" : "no"] })
    }
}

struct SlackTemplateShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "One template and its variables.")
    @Argument var name: SlackTemplateName
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackTemplateList }
    func render(_ result: JSONValue, _ output: Output) throws {
        let templates: [TemplateInfo] = try result.decode()
        guard let template = templates.first(where: { $0.name == name.rawValue }) else { return }
        output.line(template.text)
        output.line(output.paint("Variables: \(template.variables.joined(separator: " ")) · default: \(template.defaultText)", .dim))
    }
}

struct SlackTemplateSet: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change a template.")
    @Argument var name: SlackTemplateName
    @Argument(help: "The text (or --editor).") var text: String?
    @Flag(help: "Edit it in $EDITOR.") var editor = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard (text != nil) != editor else { throw ValidationError("Pass the text or --editor.") }
    }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard editor else { return }
        let templates: [TemplateInfo] = try connection.run(.slackTemplateList).decode()
        text = try Editor.edit(templates.first { $0.name == name.rawValue }?.text ?? "", suffix: ".txt")
            .trimmingCharacters(in: .newlines)
    }

    func appCommand(confirmed: Bool) -> AppCommand { .slackTemplateSet(template: name, text: text ?? "") }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

struct SlackTemplateReset: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Back to the default template.")
    @Argument var name: SlackTemplateName
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackTemplateReset(template: name) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Reset.") }
}

struct SlackCheck: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "check", abstract: "Test the connection (Test Connection).")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackCheck }
    func render(_ result: JSONValue, _ output: Output) throws {
        let check: SlackCheckInfo = try result.decode()
        output.line(check.provider == .claudeConnector ? "Connected as @\(check.user) via Claude"
                                                       : "Connected as @\(check.user) on \(check.team)")
    }
}

struct SlackTest: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "test", abstract: "Send a test message to your own DM (Send Test to My DM…).",
        discussion: "Posts one message, reacts, replies in its thread and reads it back. Needs --yes without a terminal.")
    @OptionGroup var global: GlobalOptions
    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? { "Send a test to your Slack DM?" }
    func appCommand(confirmed: Bool) -> AppCommand { .slackSelfTest(confirmed: confirmed) }
    func render(_ result: JSONValue, _ output: Output) throws {
        let steps: [SelfTestStepInfo] = try result.decode()
        for step in steps {
            let mark = step.status == "ok" ? output.paint("✓", .green) : step.status == "failed" ? output.paint("✗", .red) : "–"
            output.line("\(mark) \(step.title): \(step.detail)")
        }
    }
}

struct SlackChannels: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "channels", abstract: "The channels you can pick for a repo.")
    @Flag(help: "Ask Slack again (Reload Channels).") var reload = false
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackChannels(reload: reload) }
    func render(_ result: JSONValue, _ output: Output) throws {
        let channels: [ChannelInfo] = try result.decode()
        output.table(["Channel", "ID", "Private", "Member"], channels.map {
            ["#\($0.name)", $0.id, $0.isPrivate ? "yes" : "no", $0.isMember ? "yes" : "no"]
        })
    }
}
