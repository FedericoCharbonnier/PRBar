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
    case confirmMerge = "confirm-merge"
    case updateInterval = "update-interval"
}

struct ConfigSet: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Change a general setting.",
        discussion: "refresh-interval 1|2|5|10 (minutes) · launch-at-login on|off · confirm-merge on|off (Confirm before merging) · update-interval 0|6|12|24|168 (hours; 0 = manual only)")
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
        case .confirmMerge:
            guard let on = OnOff(rawValue: value) else { throw ValidationError("confirm-merge takes on or off.") }
            return .setConfirmMerge(enabled: on.isOn)
        case .updateInterval:
            guard let hours = Int(value) else { throw ValidationError("update-interval takes hours: 0 (manual only), 6, 12, 24 or 168.") }
            return .setUpdateInterval(hours: hours)
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
    @OptionGroup var global: GlobalOptions

    var changes: RepoChanges {
        RepoChanges(
            localPath: path.map { $0 == "none" ? .clear : .set(value: absolutePath($0)) },
            worktreeDir: worktrees.map { $0 == "default" ? .clear : .set(value: absolutePath($0)) },
            testCommand: testCommand.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? .clear : .set(value: $0) },
            baseBranches: branches.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } },
            addBranches: addBranch, removeBranches: removeBranch,
            channel: channel.map { $0 == "none" ? .clear : .set(value: $0) },
            mergeMethod: mergeMethod.map { $0.lowercased() == "default" ? .clear : .set(value: $0.lowercased()) }
        )
    }

    func validate() throws {
        guard !changes.isEmpty else { throw ValidationError("Nothing to change. See `prbar repo set --help`.") }
        if let method = changes.mergeMethod?.value, MergeMethod(rawValue: method) == nil {
            throw ValidationError("--merge-method takes squash, merge, rebase or default.")
        }
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
        commandName: "claude", abstract: "Skills and model of the reviews and responses (Settings › Claude).",
        subcommands: [ClaudeShow.self, ClaudeSet.self, ClaudeReset.self, ClaudeSkillsCommand.self])
}

enum ClaudeRender {
    static func settings(_ result: JSONValue, _ output: Output) throws {
        let settings: ClaudeSettings = try result.decode()
        Render.pairs([
            ("Review skill", settings.effectiveReviewSkill),
            ("Filter findings", Render.onOff(settings.filterEnabled)),
            ("Filter skill", settings.effectiveFilterSkill),
            ("Respond skill", settings.effectiveRespondSkill),
            ("Model", settings.model?.rawValue ?? "default"),
            ("Chat", Render.onOff(settings.chatEnabled)),
            ("Chat model", settings.chatModel?.rawValue ?? "same as review"),
        ], output)
    }
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
    @Option(help: "Chat with Claude in Review and Respond windows: on or off.") var chat: OnOff?
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
