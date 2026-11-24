import ArgumentParser
import Foundation
import PRBarCore

// MARK: - config

struct ConfigGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "General settings.",
                                                    subcommands: [ConfigShow.self, ConfigSet.self])
}

struct ConfigShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "The whole configuration (config.json, no secrets).")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .configShow }

    func render(_ result: JSONValue, _ output: Output) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        output.line(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}

enum ConfigKey: String, ExpressibleByArgument, CaseIterable {
    case refreshInterval = "refresh-interval"
    case launchAtLogin = "launch-at-login"
    case alwaysShowInDock = "always-show-in-dock"
    case updateInterval = "update-interval"
    case diskWarning = "disk-warning"
    case terminal = "terminal"
    case terminalCommand = "terminal-command"
    case keepSessionFolders = "keep-session-folders"
}

struct ConfigSet: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Change a general setting.",
        discussion: "refresh-interval 1|2|5|10 (minutes) · launch-at-login on|off · always-show-in-dock on|off · update-interval 0|6|12|24|168 (hours; 0 = manual only) · disk-warning 1…100|off (GB) · terminal terminal|iterm|warp|ghostty|orca|custom · terminal-command \"<command with {command}, optionally {dir}>\" (only used after `config set terminal custom`; \"\" clears it) · keep-session-folders on|off (off: delete each job's folder when it ends)")
    @Argument(help: "The setting.") var key: ConfigKey
    @Argument(help: "Its value.") var value: String
    @OptionGroup var global: GlobalOptions

    func validate() throws { _ = try appCommand(confirmed: false) }

    func appCommand(confirmed: Bool) throws -> AppCommand {
        switch key {
        case .refreshInterval:
            guard let minutes = Int(value) else { throw ValidationError("refresh-interval takes minutes: 1, 2, 5 or 10.") }
            return .setRefreshInterval(minutes: minutes)
        case .launchAtLogin:
            guard let on = OnOff(rawValue: value) else { throw ValidationError("launch-at-login takes on or off.") }
            return .setLaunchAtLogin(enabled: on.isOn)
        case .alwaysShowInDock:
            guard let on = OnOff(rawValue: value) else { throw ValidationError("always-show-in-dock takes on or off.") }
            return .setAlwaysShowInDock(enabled: on.isOn)
        case .updateInterval:
            guard let hours = Int(value) else { throw ValidationError("update-interval takes hours: 0 (manual only), 6, 12, 24 or 168.") }
            return .setUpdateInterval(hours: hours)
        case .diskWarning:
            if value == "off" { return .setDiskWarning(gigabytes: nil) }
            guard let gigabytes = Int(value), ResourceSettings.gigabyteRange.contains(gigabytes) else {
                throw ValidationError("disk-warning takes gigabytes (1–100) or off.")
            }
            return .setDiskWarning(gigabytes: gigabytes)
        case .terminal:
            guard let choice = TerminalChoice(rawValue: value) else {
                throw ValidationError("terminal takes terminal, iterm, warp, ghostty, orca or custom.")
            }
            return .setTerminal(terminal: choice)
        case .terminalCommand:
            return .setTerminalCommand(command: value)
        case .keepSessionFolders:
            guard let on = OnOff(rawValue: value) else { throw ValidationError("keep-session-folders takes on or off.") }
            return .setKeepSessionFolders(enabled: on.isOn)
        }
    }

    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

// MARK: - account

struct AccountGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "account", abstract: "GitHub accounts (from gh).",
                                                    subcommands: [AccountList.self, AccountEnable.self, AccountDisable.self, AccountReload.self])
}

enum AccountRender {
    static func list(_ result: JSONValue, _ output: Output) throws {
        let accounts: [AccountInfo] = try result.decode()
        guard !accounts.isEmpty else {
            return output.line("No GitHub accounts in gh. Run `gh auth login --hostname github.com`, then `prbar account reload`.")
        }
        output.table(["Login", "Enabled", "gh"], accounts.map {
            [$0.login, Render.onOff($0.enabled), $0.inGh ? ($0.active ? "active" : "signed in") : "not signed in"]
        })
    }
}

struct AccountList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Accounts signed in to gh and whether PRBar uses them.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .accountList }
    func render(_ result: JSONValue, _ output: Output) throws { try AccountRender.list(result, output) }
}

struct AccountEnable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Use this account.")
    @Argument var login: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .accountSetEnabled(login: login, enabled: true) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Enabled \(login).") }
}

struct AccountDisable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Stop using this account.")
    @Argument var login: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .accountSetEnabled(login: login, enabled: false) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Disabled \(login).") }
}

struct AccountReload: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reload", abstract: "Read the accounts from gh again (Reload Accounts).")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .accountReload }
    func render(_ result: JSONValue, _ output: Output) throws { try AccountRender.list(result, output) }
}

// MARK: - repo

struct RepoGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repo", abstract: "The repos PRBar follows (Settings › Repos).",
        subcommands: [RepoList.self, RepoAvailable.self, RepoAdd.self, RepoRemove.self, RepoSet.self, RepoBranches.self, RepoOpen.self])
}

enum RepoRender {
    static func one(_ repo: RepoInfo, _ output: Output) {
        output.line(output.paint("\(repo.id) (@\(repo.account))", .bold))
        Render.pairs([
            ("Base branches", repo.baseBranches.isEmpty ? "default branch" : repo.baseBranches.joined(separator: ", ")),
            ("People", repo.watchedUsers.isEmpty ? "none" : repo.watchedUsers.joined(separator: ", ")),
            ("Local folder", repo.localPath ?? "none (reviews use only the diff)"),
            ("Worktrees", repo.worktreeDir ?? "default (next to the local folder)"),
            ("Test command", repo.testCommand ?? "none"),
            ("Slack channel", repo.slackChannel ?? "no announcements"),
            ("Merge method", repo.mergeMethod?.rawValue ?? "default (GitHub’s)"),
            ("Ignored paths", repo.ignorePaths.isEmpty ? "none" : repo.ignorePaths.joined(separator: ", ")),
            ("Run Claude on", repo.runOn.map { $0 == "local" ? "this Mac" : $0 } ?? "default"),
        ], output)
    }
}

struct RepoList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The configured repos.")
    @Option(help: "Only this account.") var account: String?
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .repoList(account: account) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let repos: [RepoInfo] = try result.decode()
        guard !repos.isEmpty else { return output.line("No repos yet. Add one with `prbar repo add owner/repo`.") }
        output.table(["Repo", "Account", "Branches", "People", "Local folder", "Channel"], repos.map {
            [$0.id, $0.account, $0.baseBranches.isEmpty ? "default" : $0.baseBranches.joined(separator: ","),
             "\($0.watchedUsers.count)", $0.localPath ?? "—", $0.slackChannel ?? "—"]
        })
    }
}

struct RepoAvailable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "available", abstract: "Your GitHub repos that can be added (Add Repo…).")
    @Option(help: "The account (if several are enabled).") var account: String?
    @Flag(help: "Ask GitHub again.") var reload = false
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .repoAvailable(account: account, reload: reload) }
    func render(_ result: JSONValue, _ output: Output) throws { (try result.decode() as [String]).forEach { output.line($0) } }
}

struct RepoAdd: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Follow a repo.")
    @Argument(help: "owner/repo") var repo: String
    @Option(help: "The account (if several are enabled).") var account: String?
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .repoAdd(repo: repo, account: account) }
    func render(_ result: JSONValue, _ output: Output) throws { RepoRender.one(try result.decode(), output) }
}

struct RepoRemove: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Stop following a repo (its branches, people, folder and channel are lost).")
    @Argument(help: "owner/repo") var repo: String
    @Option(help: "The account.") var account: String?
    @OptionGroup var global: GlobalOptions
    var confirmationPolicy: ConfirmationPolicy { .interactiveOnly }
    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        "Remove \(repo)? Its PRs will stop showing up, and its branches, people, local folder, and Slack channel will be lost."
    }
    func appCommand(confirmed: Bool) -> AppCommand { .repoRemove(repo: repo, account: account) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Removed \(repo).") }
}

struct RepoSet: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change a repo’s settings.")
    @Argument(help: "owner/repo") var repo: String
    @Option(help: "The account.") var account: String?
    @Option(help: "Local folder (a clone of the repo), or none.") var path: String?
    @Option(help: "Folder for Respond’s worktrees, or default.") var worktrees: String?
    @Option(help: "Test command run on request after the fixes (\"\" = none).") var testCommand: String?
    @Option(help: "Base branches, comma-separated (\"\" = the default branch).") var branches: String?
    @Option(help: "Add a base branch.") var addBranch: [String] = []
    @Option(help: "Remove a base branch.") var removeBranch: [String] = []
    @Option(help: "Slack channel: #name, its ID, or none.") var channel: String?
    @Option(help: "How Merge merges this repo’s PRs: squash, merge, rebase, or default (GitHub’s).") var mergeMethod: String?
    @Option(help: "Hide findings in files matching this glob in this repo’s reviews (repeatable).") var ignore: [String] = []
    @Option(help: "Stop ignoring this glob (repeatable).") var unignore: [String] = []
    @Option(help: "Where Claude runs for this repo: local, a runner’s name, or default.") var runOn: String?
    @OptionGroup var global: GlobalOptions

    var changes: RepoChanges {
        RepoChanges(
            localPath: path.map { $0 == "none" ? .clear : .set(value: absolutePath($0)) },
            worktreeDir: worktrees.map { $0 == "default" ? .clear : .set(value: absolutePath($0)) },
            testCommand: testCommand.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? .clear : .set(value: $0) },
            baseBranches: branches.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } },
            addBranches: addBranch, removeBranches: removeBranch,
            channel: channel.map { $0 == "none" ? .clear : .set(value: $0) },
            addIgnore: ignore, removeIgnore: unignore,
            mergeMethod: mergeMethod.map { $0.lowercased() == "default" ? .clear : .set(value: $0.lowercased()) },
            runOn: runOn.map { $0 == "default" ? .clear : .set(value: $0) }
        )
    }

    func validate() throws {
        guard !changes.isEmpty else { throw ValidationError("Nothing to change. See `prbar repo set --help`.") }
        if let method = changes.mergeMethod?.value, MergeMethod(rawValue: method) == nil {
            throw ValidationError("--merge-method takes squash, merge, rebase or default.")
        }
        if let runOn { try RunnerValidation.target(runOn, allowDefault: true) }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .repoSet(repo: repo, account: account, changes: changes) }
    func render(_ result: JSONValue, _ output: Output) throws { RepoRender.one(try result.decode(), output) }
}

struct RepoBranches: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "branches", abstract: "The repo’s branches and which are base branches.")
    @Argument(help: "owner/repo") var repo: String
    @Option(help: "The account.") var account: String?
    @Flag(help: "Ask GitHub again.") var reload = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .repoBranches(repo: repo, account: account, reload: reload) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let info: BranchesInfo = try result.decode()
        for branch in info.branches {
            let mark = info.selected.contains(branch) ? "✓" : " "
            output.line("\(mark) \(branch)\(branch == info.defaultBranch ? " (default)" : "")")
        }
    }
}

struct RepoOpen: LocalCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open the repo on GitHub.")
    @Argument(help: "owner/repo") var repo: String

    func run() throws {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy(PRReference.isValidName) else {
            throw ValidationError("“\(repo)” isn’t a repo: use owner/repo.")
        }
        try LocalOpen.open("https://github.com/\(repo)")
    }
}

// MARK: - follow

struct FollowGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "follow", abstract: "People whose PRs show up in “To Review”, per repo.",
        subcommands: [FollowList.self, FollowAdd.self, FollowRemove.self, FollowSuggestions.self])
}

enum FollowRender {
    static func show(_ follows: [FollowInfo], _ output: Output) {
        for follow in follows {
            output.line("\(output.paint(follow.repo, .bold)): \(follow.users.isEmpty ? "nobody" : follow.users.joined(separator: ", "))")
        }
    }
}

struct FollowList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Who you follow in each repo.")
    @Argument(help: "owner/repo (default: all)") var repo: String?
    @Option(help: "The account.") var account: String?
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .followList(repo: repo, account: account) }
    func render(_ result: JSONValue, _ output: Output) throws { FollowRender.show(try result.decode(), output) }
}

struct FollowAdd: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Follow people in a repo (checked on GitHub).")
    @Argument(help: "owner/repo") var repo: String
    @Argument(help: "GitHub logins.") var users: [String]
    @Option(help: "The account.") var account: String?
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .followAdd(repo: repo, users: users, account: account) }
    func render(_ result: JSONValue, _ output: Output) throws { FollowRender.show([try result.decode()], output) }
}

struct FollowRemove: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Unfollow people in a repo.")
    @Argument(help: "owner/repo") var repo: String
    @Argument(help: "GitHub logins.") var users: [String]
    @Option(help: "The account.") var account: String?
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .followRemove(repo: repo, users: users, account: account) }
    func render(_ result: JSONValue, _ output: Output) throws { FollowRender.show([try result.decode()], output) }
}

struct FollowSuggestions: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "suggestions", abstract: "People you could follow (like Add User…).")
    @Argument(help: "owner/repo") var repo: String
    @Option(help: "The account.") var account: String?
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .followSuggestions(repo: repo, account: account) }
    func render(_ result: JSONValue, _ output: Output) throws {
        let users: [UserSuggestionInfo] = try result.decode()
        output.table(["Login", "Name", "Open PRs"], users.map { [$0.login, $0.name ?? "", "\($0.openPRs)"] })
    }
}

// MARK: - notify

struct NotifyGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify", abstract: "Notifications (Settings › General).",
        subcommands: [NotifyList.self, NotifySet.self, NotifyEnable.self, NotifyDisable.self, NotifySystemSettings.self])
}

struct NotifyList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Which notifications are on.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .notifyList }
    func render(_ result: JSONValue, _ output: Output) throws {
        let info: NotificationsInfo = try result.decode()
        output.line("Notifications: \(Render.onOff(info.enabled))")
        output.table(["Kind", "On"], NotificationSettingName.allCases.map { [$0.rawValue, Render.onOff(info.kinds[$0.rawValue] ?? false)] })
        if info.deniedInMacOS {
            output.line(output.paint("Notifications for PRBar are turned off in macOS: `prbar notify system-settings`.", .yellow))
        }
    }
}

struct NotifySet: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Turn one kind of notification on or off.")
    @Argument(help: "new-to-review, reviewed-updated, my-feedback, review-finished, approved-or-ci or ready-to-merge.") var kind: NotificationSettingName
    @Argument var value: OnOff
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .notifySet(kind: kind, enabled: value.isOn) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

struct NotifyEnable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Show notifications.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .notifySetEnabled(enabled: true) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Notifications on.") }
}

struct NotifyDisable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Don’t show notifications.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .notifySetEnabled(enabled: false) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Notifications off.") }
}

struct NotifySystemSettings: LocalCommand {
    static let configuration = CommandConfiguration(commandName: "system-settings", abstract: "Open macOS’s notification settings.")
    func run() throws { try LocalOpen.open("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
}

// MARK: - claude

struct ClaudeGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude", abstract: "Claude’s settings: stages, skills, prompts, review and fix options, model and chat (Settings › Claude).",
        subcommands: [ClaudeShow.self, ClaudeSet.self, ClaudeReset.self, ClaudeSkillsCommand.self, ClaudeReviewGroup.self,
                      ClaudeRespondGroup.self, ClaudeStage.self, ClaudePromptGroup.self])
}

enum ClaudeRender {
    /// Cómo corre una etapa: su skill o el prompt propio.
    static func stage(_ stage: PromptStage, _ settings: ClaudeSettings) -> String {
        if settings.usesCustomPrompt(stage) { return "custom prompt" + (settings.usesSkill(stage) ? " (uses \(settings.skill(for: stage) ?? "its skill"))" : "") }
        let skill = settings.skill(for: stage) ?? "no skill"
        if settings.stage(stage)?.mode == .prompt { return "\(skill) (custom prompt not valid yet: the default one runs)" }
        return skill
    }

    static func settings(_ result: JSONValue, _ output: Output) throws {
        let settings: ClaudeSettings = try result.decode()
        let review = settings.review
        let respond = settings.respond
        let categories = FindingCategory.allCases.map { "\($0.rawValue)=\(Render.onOff(review.isEnabled($0)))" }
        Render.pairs([
            ("Review", stage(.review, settings)),
            ("Filter findings", Render.onOff(settings.filterEnabled)),
            ("Filter", stage(.filter, settings)),
            ("Minimum severity", review.minSeverity.rawValue),
            ("Maximum findings", review.maxFindings.map(String.init) ?? "no limit"),
            ("Report", categories.joined(separator: " ")),
            ("Ignore paths", review.ignorePaths.isEmpty ? "none" : review.ignorePaths.joined(separator: ", ")),
            ("Tone", review.tone.rawValue),
            ("Analysis", stage(.analysis, settings)),
            ("Implementation", stage(.implementation, settings)),
            ("Run tests before pushing", Render.onOff(respond.runTestsBeforePush)),
            ("Commits", respond.commitMode == .single ? "single" : "per-comment"),
            ("Commit message", respond.commitMessageTemplate ?? "default"),
            ("Allow new tests", Render.onOff(respond.allowNewTests)),
            ("Allow new dependencies", Render.onOff(respond.allowNewDependencies)),
            ("Reply to fixed comments", respond.replyTemplate ?? "default (“Fixed in …”)"),
            ("Model", settings.model?.rawValue ?? "default"),
            ("Chat", Render.onOff(settings.chatEnabled)),
            ("Chat model", settings.chatModel?.rawValue ?? "same as review"),
            ("Modified prompts", PromptStage.allCases.filter { settings.customPrompt(for: $0) != nil }.map(\.cliName)
                .joined(separator: ", ").nonEmpty ?? "none"),
        ], output)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct ClaudeShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "The current Claude settings.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .claudeShow }
    func render(_ result: JSONValue, _ output: Output) throws { try ClaudeRender.settings(result, output) }
}

struct ClaudeSet: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change the skills, the model or the chat.")
    @Option(help: "plugin:skill or skill.") var reviewSkill: String?
    @Option(help: "on or off.") var filter: OnOff?
    @Option(help: "plugin:skill or skill.") var filterSkill: String?
    @Option(help: "plugin:skill or skill.") var respondSkill: String?
    @Option(help: "opus, sonnet, haiku or default.") var model: String?
    @Option(help: "Chat with Claude in the Review, Respond and Merge tabs: on or off.") var chat: OnOff?
    @Option(help: "Chat model: opus, sonnet, haiku or same (as the review).") var chatModel: String?
    @OptionGroup var global: GlobalOptions

    var changes: ClaudeChanges {
        ClaudeChanges(reviewSkill: reviewSkill, filterEnabled: filter?.isOn, filterSkill: filterSkill, respondSkill: respondSkill,
                      model: model.map { $0.lowercased() == "default" ? .clear : .set(value: $0) }, chatEnabled: chat?.isOn,
                      chatModel: chatModel.map { $0.lowercased() == "same" ? .clear : .set(value: $0) })
    }

    func validate() throws {
        guard !changes.isEmpty else { throw ValidationError("Nothing to change. See `prbar claude set --help`.") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .claudeSet(changes: changes) }
    func render(_ result: JSONValue, _ output: Output) throws { try ClaudeRender.settings(result, output) }
}

struct ClaudeReset: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Back to the default skills and model.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .claudeReset }
    func render(_ result: JSONValue, _ output: Output) throws { try ClaudeRender.settings(result, output) }
}

struct ClaudeSkillsCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "skills", abstract: "The installed skills PRBar can use.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .claudeSkills }
    func render(_ result: JSONValue, _ output: Output) throws {
        let skills: [SkillInfo] = try result.decode()
        output.table(["Skill", "Source", "Available", "Description"], skills.map {
            [$0.id, $0.source, $0.available ? "yes" : "no", Render.truncate($0.reason ?? $0.description ?? "", 60)]
        })
    }
}

// MARK: - tools

struct ToolsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tools", abstract: "Where gh, git and claude are (Settings › General).",
                                                    subcommands: [ToolsList.self, ToolsSet.self, ToolsReset.self])
}

enum ToolsRender {
    static func list(_ result: JSONValue, _ output: Output) throws {
        let tools: [ToolInfo] = try result.decode()
        output.table(["Tool", "Path", "Source"], tools.map { [$0.name, $0.path ?? "not found", $0.custom ? "custom" : "automatic"] })
    }
}

struct ToolsList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The paths PRBar uses.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .toolsList }
    func render(_ result: JSONValue, _ output: Output) throws { try ToolsRender.list(result, output) }
}

struct ToolsSet: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Use this copy of a tool (Choose…).")
    @Argument(help: "gh, git or claude.") var tool: ToolName
    @Argument(help: "The executable.") var path: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .toolsSet(tool: tool, path: absolutePath(path)) }
    func render(_ result: JSONValue, _ output: Output) throws { try ToolsRender.list(result, output) }
}

struct ToolsReset: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Find the tool automatically again (Use Automatic).")
    @Argument(help: "gh, git or claude.") var tool: ToolName
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .toolsSet(tool: tool, path: nil) }
    func render(_ result: JSONValue, _ output: Output) throws { try ToolsRender.list(result, output) }
}

// MARK: - claude review / respond / stage / prompt (spec E.5–E.7)

struct ClaudeReviewGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "review", abstract: "What the review reports.",
                                                    subcommands: [ClaudeReviewSet.self])
}

struct ClaudeReviewSet: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Change what the review reports (Settings › Claude › What the review reports).",
        discussion: "Categories: \(FindingCategory.allCases.map(\.rawValue).joined(separator: ", ")). What these settings hide goes to “Hidden by your settings” in the Review tab (`prbar review include` still includes it).")
    @Option(help: "low (everything), medium or high.") var minSeverity: Severity?
    @Option(help: "At most this many findings (1–50), or none.") var maxFindings: String?
    @Option(help: "Hide findings in files matching this glob (repeatable).") var ignore: [String] = []
    @Option(help: "Stop ignoring this glob (repeatable).") var unignore: [String] = []
    @Option(help: "A category on or off, e.g. style=off (repeatable).") var category: [String] = []
    @Option(help: "direct, friendly or with-suggestions.") var tone: ToneArgument?
    @OptionGroup var global: GlobalOptions

    var categories: [String: Bool] {
        get throws {
            var result: [String: Bool] = [:]
            for item in category {
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, let value = OnOff(rawValue: parts[1].lowercased()) else {
                    throw ValidationError("--category takes name=on or name=off (e.g. style=off).")
                }
                result[parts[0].lowercased()] = value.isOn
            }
            return result
        }
    }

    var changes: ReviewOptionChanges {
        get throws {
            ReviewOptionChanges(minSeverity: minSeverity,
                                maxFindings: maxFindings.map { $0.lowercased() == "none" ? .clear : .set(value: $0) },
                                addIgnore: ignore, removeIgnore: unignore, categories: try categories, tone: tone?.tone)
        }
    }

    func validate() throws {
        guard try !changes.isEmpty else { throw ValidationError("Nothing to change. See `prbar claude review set --help`.") }
    }

    func appCommand(confirmed: Bool) throws -> AppCommand { .claudeReviewSet(changes: try changes) }
    func render(_ result: JSONValue, _ output: Output) throws { try ClaudeRender.settings(result, output) }
}

struct ClaudeRespondGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "respond", abstract: "How the fixes are made.",
                                                    subcommands: [ClaudeRespondSet.self])
}

struct ClaudeRespondSet: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Change how the fixes are made (Settings › Claude › Fixes).",
        discussion: "Commit message variables: {n} {pr} {title} {comment}. Reply variables: {commit} {summary} {pr} {title} {comment}.")
    @Option(help: "Run the repo’s test command before pushing and don’t push if it fails: on or off.") var testsBeforePush: OnOff?
    @Option(help: "per-comment (one commit per comment) or single.") var commitMode: CommitModeArgument?
    @Option(help: "The commit message template, or default.") var commitTemplate: String?
    @Option(help: "Allow Claude to add tests: on or off.") var allowTests: OnOff?
    @Option(help: "Allow Claude to add dependencies: on or off.") var allowDeps: OnOff?
    @Option(help: "The reply to fixed comments, or default (“Fixed in …”).") var replyTemplate: String?
    @OptionGroup var global: GlobalOptions

    var changes: RespondOptionChanges {
        RespondOptionChanges(runTestsBeforePush: testsBeforePush?.isOn, commitMode: commitMode?.mode,
                             commitMessageTemplate: commitTemplate.map { $0.lowercased() == "default" ? .clear : .set(value: $0) },
                             allowNewTests: allowTests?.isOn, allowNewDependencies: allowDeps?.isOn,
                             replyTemplate: replyTemplate.map { $0.lowercased() == "default" ? .clear : .set(value: $0) })
    }

    func validate() throws {
        guard !changes.isEmpty else { throw ValidationError("Nothing to change. See `prbar claude respond set --help`.") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .claudeRespondSet(changes: changes) }
    func render(_ result: JSONValue, _ output: Output) throws { try ClaudeRender.settings(result, output) }
}

struct ClaudeStage: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "stage", abstract: "Run a stage with a skill, your own prompt, or the defaults (Skill / Custom Prompt).",
        discussion: "Stages: review, filter, analysis, implementation. `--skill none` only for the implementation. Editing a prompt never changes Claude’s tools, permissions or output format.")
    @Argument(help: "review, filter, analysis or implementation.") var stage: PromptStage
    @Option(help: "Use this skill (plugin:skill or skill).") var skill: String?
    @Option(help: "Use the prompt in this file (- = stdin).") var promptFile: String?
    @Flag(name: .customLong("default"), help: "Back to the default skill and prompt.") var useDefault = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard [skill != nil, promptFile != nil, useDefault].filter({ $0 }).count == 1 else {
            throw ValidationError("Pass one of --skill, --prompt-file and --default.")
        }
        guard stage.hasSkill else {
            throw ValidationError("Chat prompts have no skill: use `prbar claude prompt edit \(stage.cliName)`.")
        }
    }

    func appCommand(confirmed: Bool) throws -> AppCommand {
        if let skill { return .claudeStageSet(stage: stage, change: .skill(name: skill)) }
        if let promptFile { return .claudeStageSet(stage: stage, change: .prompt(text: try readText(promptFile))) }
        return .claudeStageSet(stage: stage, change: .useDefault)
    }

    func render(_ result: JSONValue, _ output: Output) throws { try ClaudeRender.settings(result, output) }
}

/// Un archivo de la línea de comandos (`-` = stdin).
func readText(_ path: String) throws -> String {
    if path == "-" { return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
    do {
        return try String(contentsOfFile: absolutePath(path), encoding: .utf8)
    } catch {
        throw CommandFailure(.notFound, "Couldn’t read \(path).")
    }
}

struct ClaudePromptGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prompt", abstract: "The stages’ editable prompts (Settings › Claude › Prompts).",
        discussion: "Stages: \(PromptStage.allCases.map(\.cliName).joined(separator: ", ")). PRBar always adds its fixed part around your prompt.",
        subcommands: [ClaudePromptShow.self, ClaudePromptEdit.self, ClaudePromptReset.self])
}

enum PromptRender {
    static func show(_ result: JSONValue, _ output: Output) throws {
        let info: PromptInfo = try result.decode()
        output.line(output.paint("\(info.stage.title) prompt\(info.isDefault ? " (default)" : " (modified)")", .bold))
        if !info.requiredVariables.isEmpty {
            output.line(output.paint("Must use: \(info.requiredVariables.map { "{\($0)}" }.joined(separator: " "))", .dim))
        }
        output.line(info.text)
    }
}

struct ClaudePromptShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print a stage’s prompt (yours or the default).")
    @Argument(help: "The stage.") var stage: PromptStage
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .claudePromptShow(stage: stage) }
    func render(_ result: JSONValue, _ output: Output) throws { try PromptRender.show(result, output) }
}

struct ClaudePromptEdit: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit", abstract: "Edit a stage’s prompt in $EDITOR, or set it from a file (Edit Prompt… › Save).",
        discussion: "A stage with a skill switches to “Custom Prompt”; use {skill} to keep using its skill. A prompt without the stage’s required variables is rejected.")
    @Argument(help: "The stage.") var stage: PromptStage
    @Option(help: "Read the prompt from this file (- = stdin) instead of opening $EDITOR.") var file: String?
    @OptionGroup var global: GlobalOptions

    var text: String?

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        if let file {
            text = try readText(file)
            return
        }
        let current: PromptInfo = try connection.run(.claudePromptShow(stage: stage)).decode()
        let edited = try Editor.edit(current.text)
        guard edited != current.text else { throw CommandFailure(.cancelled, "No changes.") }
        text = edited
    }

    func appCommand(confirmed: Bool) -> AppCommand { .claudePromptSet(stage: stage, text: text ?? "") }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved the \(stage.cliName) prompt.") }
}

struct ClaudePromptReset: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Back to the default prompt (Reset to Default).")
    @Argument(help: "The stage.") var stage: PromptStage
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .claudePromptReset(stage: stage) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("The \(stage.cliName) prompt is the default again.") }
}
