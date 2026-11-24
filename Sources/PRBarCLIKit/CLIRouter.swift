import ArgumentParser
import PRBarCore

/// Un comando de la CLI (su ruta, p. ej. `review publish`), qué `AppCommand` produce (vacío = local, no necesita la
/// app) y ejemplos de argumentos que el test de paridad parsea.
public struct CLICommandSpec: Sendable {
    public let path: String
    public let produces: [AppCommand.Name]
    public let samples: [[String]]
    /// Lo que el comando manda antes de su comando final (`remote pair`: abrir la ranura y esperar al teléfono).
    public let prepares: [AppCommand.Name]

    init(_ path: String, _ produces: [AppCommand.Name], _ samples: [String]...) {
        self.path = path
        self.produces = produces
        self.samples = samples
        prepares = []
    }

    init(_ path: String, _ produces: [AppCommand.Name], prepares: [AppCommand.Name], _ samples: [String]...) {
        self.path = path
        self.produces = produces
        self.samples = samples
        self.prepares = prepares
    }
}

/// La tabla de la paridad (spec C.7). Agregar un caso a `AppCommand` obliga a agregar acá el comando que lo produce;
/// agregar un subcomando obliga a agregarlo acá.
public enum CLIRouter {
    public static let commands: [CLICommandSpec] = [
        // Estado, historial, ventanas y app
        .init("status", [.status], ["status"]),
        .init("prs", [.listPRs], ["prs", "--list", "mine"], ["prs", "--tab", "to-review"]),
        .init("refresh", [.refresh], ["refresh"]),
        .init("resources", [.resources], ["resources"]),
        .init("cleanup", [.cleanup, .cleanupPreview], ["cleanup", "--older-than", "30d", "--yes"], ["cleanup", "--preview"]),
        .init("open", [.open, .resolvePR], ["open", "api#1", "--posted"], ["open", "api#1", "--copy"],
              ["open", "api#1", "--merge"]),
        .init("history list", [.history], ["history", "--kind", "respond"], ["history", "list"], ["history", "--kind", "ci-fix"]),
        .init("history show", [.historyShow], ["history", "show", "1a2b3c4d"]),
        .init("history reopen", [.historyReopen], ["history", "reopen", "1a2b3c4d"]),
        .init("app start", [], ["app", "start"]),
        .init("app quit", [.quit], ["app", "quit"]),
        .init("app popover", [.openPopover], ["app", "popover", "--tab", "mine"]),
        .init("app settings", [.openSettings], ["app", "settings", "claude"]),
        .init("app history", [.openHistory], ["app", "history"]),
        .init("app logs", [], ["app", "logs", "--slack"], ["app", "logs", "--update"], ["app", "logs", "--instructions"]),
        .init("version", [], ["version"]),
        .init("doctor", [], ["doctor"]),
        .init("completion", [], ["completion", "fish"]),
        // Review
        .init("review start", [.reviewStart], ["review", "api#1", "--wait"]),
        .init("review show", [.reviewShow], ["review", "show", "api#1"]),
        .init("review edit", [.reviewEdit], ["review", "edit", "api#1", "1", "--title", "T"]),
        .init("review include", [.reviewSetIncluded], ["review", "include", "api#1", "1"]),
        .init("review exclude", [.reviewSetIncluded], ["review", "exclude", "api#1", "--all"]),
        .init("review comment", [.reviewSetComment], ["review", "comment", "api#1", "--text", "LGTM"]),
        .init("review publish", [.reviewPublish], ["review", "publish", "api#1", "--comment", "--yes"]),
        .init("review cancel", [.reviewCancel], ["review", "cancel", "api#1"]),
        .init("review dismiss", [.reviewDismiss], ["review", "dismiss", "api#1"]),
        // Respond
        .init("respond start", [.respondStart], ["respond", "web#2"]),
        .init("respond show", [.respondShow], ["respond", "show", "web#2"]),
        .init("respond select", [.respondSelect, .respondReset],
              ["respond", "select", "web#2", "1", "--skip"], ["respond", "select", "web#2", "--reset"]),
        .init("respond implement", [.respondImplement], ["respond", "implement", "web#2"]),
        .init("respond test", [.respondTest], ["respond", "test", "web#2"]),
        .init("respond diff", [.respondDiff], ["respond", "diff", "web#2"]),
        .init("respond push", [.respondPush, .respondPushAnyway],
              ["respond", "push", "web#2", "--yes"], ["respond", "push", "web#2", "--anyway", "--yes"]),
        .init("respond reply-only", [.respondReplyOnly], ["respond", "reply-only", "web#2", "--yes"]),
        .init("respond cancel", [.respondCancel], ["respond", "cancel", "web#2"]),
        .init("respond dismiss", [.respondDismiss], ["respond", "dismiss", "web#2"]),
        // Fix CI (spec K): show, diff, test, push, cancel y dismiss son los de Respond.
        .init("ci list", [.ciList], ["ci"], ["ci", "list"]),
        .init("ci fix", [.ciFix], ["ci", "fix", "web#2"], ["ci", "fix", "web#2", "--wait"]),
        .init("ci show", [.respondShow], ["ci", "show", "web#2", "--full"]),
        .init("ci diff", [.respondDiff], ["ci", "diff", "web#2", "--stat"]),
        .init("ci test", [.respondTest], ["ci", "test", "web#2"]),
        .init("ci push", [.respondPush, .respondPushAnyway],
              ["ci", "push", "web#2", "--yes"], ["ci", "push", "web#2", "--anyway", "--yes"]),
        .init("ci cancel", [.respondCancel], ["ci", "cancel", "web#2"]),
        .init("ci dismiss", [.respondDismiss], ["ci", "dismiss", "web#2"]),
        // Uso de Claude (spec O)
        .init("usage", [.usage], ["usage"], ["usage", "--month", "2026-10"]),
        // Acceso desde el iPhone (spec Q.3)
        .init("remote status", [.remoteStatus], ["remote"], ["remote", "status", "--json"]),
        .init("remote enable", [.remoteEnable], ["remote", "enable", "--relay", "relay.example.com", "--enroll-token-stdin"]),
        .init("remote disable", [.remoteDisable], ["remote", "disable"]),
        .init("remote pair", [.remotePairConfirm], prepares: [.remotePairStart, .remotePairWait], ["remote", "pair"]),
        .init("remote devices", [.remoteDevices, .remoteSetPresenceRequirement],
              ["remote", "devices", "--json"], ["remote", "devices", "--require-face-id", "dev1", "off"]),
        .init("remote revoke", [.remoteRevoke], ["remote", "revoke", "dev1", "--yes"]),
        .init("remote keep-awake", [.remoteSetKeepAwake], ["remote", "keep-awake", "on"]),
        .init("remote mailbox", [.remoteSetMailbox], ["remote", "mailbox", "off"]),
        .init("remote reset", [.remoteReset], ["remote", "reset", "--yes"]),
        // Chat (plan 6)
        .init("chat", [.chatSend, .chatShow, .chatUndo, .chatStop],
              ["chat", "api#1", "hi"], ["chat", "api#1", "--show"], ["chat", "api#1", "--undo"], ["chat", "api#1", "--stop"]),
        // Sesiones de Claude en una terminal (plan 22)
        .init("session list", [.sessionList], ["session", "list", "api#7"]),
        .init("session open", [.sessionOpen], ["session", "open", "api#7"], ["session", "open", "api#7", "--job", "ci-fix", "--run", "2"]),
        // Actualizaciones (plan 8)
        .init("update", [.updateCheck, .updateInstall, .updateCancel, .updateSkip],
              ["update", "--check"], ["update", "--yes"], ["update", "--cancel"], ["update", "--skip"]),
        // Ready to Merge (plan 10)
        .init("merge", [.merge, .mergePreview, .mergeDismiss], ["merge", "api#4", "--method", "squash", "--yes"],
              ["merge", "api#4", "--preview"], ["merge", "api#4", "--dismiss"]),
        // Configuración
        .init("config show", [.configShow], ["config", "show"]),
        .init("config set", [.setRefreshInterval, .setLaunchAtLogin, .setUpdateInterval, .setDiskWarning, .setAlwaysShowInDock,
                             .setTerminal, .setTerminalCommand],
              ["config", "set", "refresh-interval", "2"], ["config", "set", "launch-at-login", "off"],
              ["config", "set", "always-show-in-dock", "on"],
              ["config", "set", "update-interval", "24"], ["config", "set", "disk-warning", "off"],
              ["config", "set", "terminal", "ghostty"], ["config", "set", "terminal-command", "open -a Terminal {command}"]),
        .init("account list", [.accountList], ["account", "list"]),
        .init("account enable", [.accountSetEnabled], ["account", "enable", "me"]),
        .init("account disable", [.accountSetEnabled], ["account", "disable", "me"]),
        .init("account reload", [.accountReload], ["account", "reload"]),
        .init("repo list", [.repoList], ["repo", "list"]),
        .init("repo available", [.repoAvailable], ["repo", "available"]),
        .init("repo add", [.repoAdd], ["repo", "add", "acme/api"]),
        .init("repo remove", [.repoRemove], ["repo", "remove", "acme/api"]),
        .init("repo set", [.repoSet], ["repo", "set", "acme/api", "--test-command", "make test"],
              ["repo", "set", "acme/api", "--merge-method", "default"], ["repo", "set", "acme/api", "--ignore", "dist/**"],
              ["repo", "set", "acme/api", "--run-on", "devbox"]),
        .init("repo branches", [.repoBranches], ["repo", "branches", "acme/api"]),
        .init("repo open", [], ["repo", "open", "acme/api"]),
        .init("follow list", [.followList], ["follow", "list"]),
        .init("follow add", [.followAdd], ["follow", "add", "acme/api", "ana"]),
        .init("follow remove", [.followRemove], ["follow", "remove", "acme/api", "ana"]),
        .init("follow suggestions", [.followSuggestions], ["follow", "suggestions", "acme/api"]),
        .init("notify list", [.notifyList], ["notify", "list"]),
        .init("notify set", [.notifySet], ["notify", "set", "review-finished", "off"]),
        .init("notify enable", [.notifySetEnabled], ["notify", "enable"]),
        .init("notify disable", [.notifySetEnabled], ["notify", "disable"]),
        .init("notify system-settings", [], ["notify", "system-settings"]),
        .init("claude show", [.claudeShow], ["claude", "show"]),
        .init("claude set", [.claudeSet], ["claude", "set", "--filter", "on"], ["claude", "set", "--chat", "on"]),
        .init("claude reset", [.claudeReset], ["claude", "reset"]),
        .init("claude skills", [.claudeSkills], ["claude", "skills"]),
        .init("claude review set", [.claudeReviewSet], ["claude", "review", "set", "--min-severity", "medium"]),
        .init("claude respond set", [.claudeRespondSet], ["claude", "respond", "set", "--commit-mode", "single"]),
        .init("claude stage", [.claudeStageSet], ["claude", "stage", "filter", "--default"], ["claude", "stage", "review", "--skill", "a:b"]),
        .init("claude prompt show", [.claudePromptShow], ["claude", "prompt", "show", "chat-review"]),
        .init("claude prompt edit", [.claudePromptSet], ["claude", "prompt", "edit", "filter"]),
        .init("claude prompt reset", [.claudePromptReset], ["claude", "prompt", "reset", "analysis"]),
        // Instrucciones (plan 9)
        .init("rules list", [.rulesList], ["rules", "list"], ["rules", "list", "--repo", "acme/api"]),
        .init("rules add", [.rulesAdd], ["rules", "add", "No style comments", "--review"]),
        .init("rules edit", [.rulesEdit], ["rules", "edit", "1a2b", "--text", "x"]),
        .init("rules remove", [.rulesRemove], ["rules", "remove", "1a2b"]),
        .init("rules enable", [.rulesSetEnabled], ["rules", "enable", "1a2b"]),
        .init("rules disable", [.rulesSetEnabled], ["rules", "disable", "1a2b"]),
        .init("rules chat", [.rulesChatSend, .rulesChatShow, .rulesChatUndo, .rulesChatStop],
              ["rules", "chat", "forget the console.log one"], ["rules", "chat", "--show"], ["rules", "chat", "--undo"],
              ["rules", "chat", "--stop"]),
        .init("rules suggestions list", [.rulesSuggestions], ["rules", "suggestions"], ["rules", "suggestions", "list"]),
        .init("rules suggestions accept", [.rulesSuggestionAct], ["rules", "suggestions", "accept", "s1", "--text", "T"]),
        .init("rules suggestions dismiss", [.rulesSuggestionAct], ["rules", "suggestions", "dismiss", "s1"]),
        .init("rules suggestions never", [.rulesSuggestionAct], ["rules", "suggestions", "never", "s1"]),
        .init("rules proposal save", [.chatProposal], ["rules", "proposal", "save", "api#1", "1", "--text", "T"]),
        .init("rules proposal dismiss", [.chatProposal], ["rules", "proposal", "dismiss", "api#1", "1"]),
        .init("tools list", [.toolsList], ["tools", "list"]),
        .init("tools set", [.toolsSet], ["tools", "set", "git", "/usr/bin/git"]),
        .init("tools reset", [.toolsSet], ["tools", "reset", "git"]),
        // Dónde corre Claude (plan 14)
        .init("runners list", [.runnersList], ["runners", "list"], ["runners"]),
        .init("runners add", [.runnerAdd], ["runners", "add", "fede@devbox:2222", "--no-fallback"]),
        .init("runners set", [.runnerSet], ["runners", "set", "devbox", "--fallback", "off"]),
        .init("runners remove", [.runnerRemove], ["runners", "remove", "devbox"]),
        .init("runners test", [.runnerTest], ["runners", "test", "devbox"]),
        .init("runners default", [.runnerDefault], ["runners", "default", "local"]),
        // Slack
        .init("slack show", [.slackShow], ["slack", "show"]),
        .init("slack enable", [.slackSetEnabled], ["slack", "enable"]),
        .init("slack disable", [.slackSetEnabled], ["slack", "disable"]),
        .init("slack provider", [.slackSetProvider], ["slack", "provider", "token"]),
        .init("slack token set", [.slackTokenSet], ["slack", "token", "set", "--stdin"]),
        .init("slack token clear", [.slackTokenClear], ["slack", "token", "clear"]),
        .init("slack set", [.slackSetToggle], ["slack", "set", "announce", "off"], ["slack", "set", "merged", "on"]),
        .init("slack emoji", [.slackSetEmoji], ["slack", "emoji", "approved", "white_check_mark"]),
        .init("slack search-days", [.slackSetSearchDays], ["slack", "search-days", "14"]),
        .init("slack template list", [.slackTemplateList], ["slack", "template", "list"]),
        .init("slack template show", [.slackTemplateList], ["slack", "template", "show", "round"]),
        .init("slack template set", [.slackTemplateSet], ["slack", "template", "set", "new-pr", "{link}"]),
        .init("slack template reset", [.slackTemplateReset], ["slack", "template", "reset", "new-pr"]),
        .init("slack check", [.slackCheck], ["slack", "check"]),
        .init("slack test", [.slackSelfTest], ["slack", "test", "--yes"]),
        .init("slack channels", [.slackChannels], ["slack", "channels"]),
    ]

    /// Todas las rutas que existen (para el inventario de la UI, Task 21).
    public static var allPaths: Set<String> { Set(commands.map(\.path)) }

    /// Las rutas de los subcomandos hoja de `PRBarCommand` (los que corren algo).
    public static func leafPaths() -> [String] {
        func walk(_ type: ParsableCommand.Type, prefix: [String]) -> [String] {
            let subcommands = type.configuration.subcommands
            guard !subcommands.isEmpty else { return [prefix.joined(separator: " ")] }
            return subcommands.flatMap { walk($0, prefix: prefix + [$0.configuration.commandName ?? "?"]) }
        }
        return PRBarCommand.configuration.subcommands.flatMap { walk($0, prefix: [$0.configuration.commandName ?? "?"]) }
    }
}
