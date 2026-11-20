import AppKit
import PRBarCore

// MARK: - Ayudas

extension AppModel {
    /// Guarda un cambio de configuración como lo hace Settings; si no se pudo guardar, error para la CLI (la UI lo
    /// muestra en el banner de Settings). `slack: true` vuelve a planificar Slack (como la pestaña Slack).
    func applyConfig(refresh: Bool = false, slack: Bool = false, _ mutate: (inout AppConfig) -> Void) throws {
        if slack {
            updateSlackConfig(mutate)
        } else {
            updateConfig(refresh: refresh, mutate)
        }
        if let settingsError { throw CommandFailure(.failed, settingsError) }
    }

    /// La cuenta de un comando: la pedida (tiene que estar encendida), la que tiene configurado `repo`, o la única
    /// encendida.
    func commandAccount(_ login: String?, repo: String? = nil) throws -> String {
        let enabled = configStore.config.accounts.filter(\.enabled)
        if let login {
            guard let account = enabled.first(where: { $0.login.caseInsensitiveCompare(login) == .orderedSame }) else {
                throw CommandFailure(.notFound, "There’s no enabled account \(login). Run `prbar account list`.")
            }
            return account.login
        }
        if let repo {
            let owners = enabled.filter { $0.repos.contains { $0.id.caseInsensitiveCompare(repo) == .orderedSame } }
            if owners.count == 1 { return owners[0].login }
            if owners.count > 1 {
                throw CommandFailure(.invalidUsage, "\(repo) is configured in \(owners.map(\.login).joined(separator: " and ")): use --account.")
            }
        }
        guard enabled.count == 1 else {
            if enabled.isEmpty {
                throw CommandFailure(.invalidState, "No account is enabled. Run `prbar account enable <login>`.")
            }
            throw CommandFailure(.invalidUsage, "Several accounts are enabled (\(enabled.map(\.login).joined(separator: ", "))): use --account.")
        }
        return enabled[0].login
    }

    func configuredRepo(_ repo: String, account: String?) throws -> (login: String, repo: RepoConfig) {
        _ = try Self.parseRepo(repo)
        let login = try commandAccount(account, repo: repo)
        guard let config = configStore.config.accounts.first(where: { $0.login == login })?
            .repos.first(where: { $0.id.caseInsensitiveCompare(repo) == .orderedSame }) else {
            throw CommandFailure(.notFound, "\(repo) isn’t configured for @\(login). Run `prbar repo add \(repo)`.")
        }
        return (login, config)
    }

    static func parseRepo(_ text: String) throws -> RepoRef {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy(PRReference.isValidName) else {
            throw CommandFailure(.invalidUsage, "“\(text)” isn’t a repo: use owner/repo.")
        }
        return RepoRef(owner: parts[0], name: parts[1])
    }

    /// `~` y rutas relativas (la CLI ya manda rutas absolutas; esto es por si otro cliente no).
    static func expandPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    private func repoInfo(login: String, repoID: String) throws -> RepoInfo {
        guard let config = configStore.config.accounts.first(where: { $0.login == login })?.repos.first(where: { $0.id == repoID }) else {
            throw CommandFailure(.notFound, "\(repoID) isn’t configured for @\(login).")
        }
        return RepoInfo(config: config, account: login)
    }

    /// Un canal de Slack por id o por nombre (`#nombre` o `nombre`), como el selector de la pestaña Repos.
    private func slackChannel(_ text: String) async throws -> SlackChannel {
        guard configStore.config.slack.enabled, slack.isConnected else {
            throw CommandFailure(.invalidState, "Turn on Slack and connect it first (`prbar slack enable`, `prbar slack check`).")
        }
        let channels = try await slack.channels(reload: false).channels
        let name = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if let channel = channels.first(where: { $0.id == text }) ?? channels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return channel
        }
        throw CommandFailure(.notFound, "There’s no channel \(text). Run `prbar slack channels`.")
    }
}

// MARK: - Configuración

extension AppModel: ConfigActions {
    func configShow() -> AppConfig {
        configStore.config
    }

    func configSetRefreshInterval(minutes: Int) throws {
        // Los mismos valores que ofrece Settings › General.
        guard [1, 2, 5, 10].contains(minutes) else {
            throw CommandFailure(.invalidUsage, "The refresh interval is 1, 2, 5 or 10 minutes.")
        }
        try applyConfig { $0.refreshIntervalMinutes = minutes }
    }

    func configSetLaunchAtLogin(enabled: Bool) throws {
        setLaunchAtLogin(enabled)
        if let settingsError { throw CommandFailure(.failed, settingsError) }
    }


    func accountList() -> [AccountInfo] {
        let configured = configStore.config.accounts
        var infos = ghAccounts.map { account in
            AccountInfo(login: account.login,
                        enabled: configured.first { $0.login == account.login }?.enabled ?? false,
                        inGh: true, active: account.isActive)
        }
        for account in configured where !ghAccounts.contains(where: { $0.login == account.login }) {
            infos.append(AccountInfo(login: account.login, enabled: account.enabled, inGh: false, active: false))
        }
        return infos
    }

    func accountSetEnabled(login: String, enabled: Bool) throws {
        guard let account = ghAccounts.first(where: { $0.login.caseInsensitiveCompare(login) == .orderedSame }) else {
            throw CommandFailure(.notFound, "\(login) isn’t signed in to gh. Run `gh auth login --hostname github.com`, then `prbar account reload`.")
        }
        try applyConfig(refresh: true) { $0.setAccountEnabled(account.login, enabled) }
    }

    func accountReload() async throws -> [AccountInfo] {
        await reloadAccounts()
        if let accountsError { throw CommandFailure(.failed, accountsError) }
        return accountList()
    }

    func repoList(account: String?) throws -> [RepoInfo] {
        let logins = try account.map { [try commandAccount($0)] } ?? configStore.config.accounts.filter(\.enabled).map(\.login)
        return configStore.config.accounts
            .filter { logins.contains($0.login) }
            .flatMap { account in account.repos.map { RepoInfo(config: $0, account: account.login) } }
    }

    func repoAvailable(account: String?, reload: Bool) async throws -> [String] {
        let login = try commandAccount(account)
        await catalog.loadRepos(for: login, force: reload)
        let entry = catalog.repos(for: login)
        if case .failed(let message) = entry.state { throw CommandFailure(.failed, message) }
        return entry.value.map(\.fullName).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func repoAdd(repo: String, account: String?) async throws -> RepoInfo {
        _ = try Self.parseRepo(repo)
        let login = try commandAccount(account)
        if configStore.config.accounts.first(where: { $0.login == login })?.repos
            .contains(where: { $0.id.caseInsensitiveCompare(repo) == .orderedSame }) == true {
            throw CommandFailure(.invalidState, "\(repo) is already configured for @\(login).")
        }
        // Como "Add Repo…": solo repos que la cuenta ve en GitHub, con el nombre exacto.
        let available = try await repoAvailable(account: login, reload: false)
        guard let fullName = available.first(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) else {
            throw CommandFailure(.notFound, "@\(login) can’t see \(repo) on GitHub. Run `prbar repo available` to list them.")
        }
        let ref = try Self.parseRepo(fullName)
        try applyConfig(refresh: true) { $0.addRepo(ref, to: login) }
        return try repoInfo(login: login, repoID: ref.fullName)
    }

    func repoRemove(repo: String, account: String?) throws {
        let (login, config) = try configuredRepo(repo, account: account)
        try applyConfig(refresh: true) { $0.removeRepo(config.id, from: login) }
    }

    func repoSet(repo: String, account: String?, changes: RepoChanges) async throws -> RepoInfo {
        let (login, current) = try configuredRepo(repo, account: account)
        guard !changes.isEmpty else { throw CommandFailure(.invalidUsage, "Nothing to change. See `prbar repo set --help`.") }
        // Primero se valida todo; si algo falla no se guarda nada.
        var localPath: String??
        if let change = changes.localPath {
            switch change {
            case .clear:
                localPath = .some(nil)
            case .set(let raw):
                let path = Self.expandPath(raw)
                if let error = await validateRepoPath(path, repo: current.repo) { throw CommandFailure(.invalidUsage, error) }
                localPath = .some(path)
            }
        }
        var channel: SlackChannel??
        if let change = changes.channel {
            switch change {
            case .clear: channel = .some(nil)
            case .set(let raw): channel = .some(try await slackChannel(raw))
            }
        }
        var mergeMethod: MergeMethod??
        if let change = changes.mergeMethod {
            switch change {
            case .clear:
                mergeMethod = .some(nil)
            case .set(let name):
                guard let method = MergeMethod(rawValue: name.lowercased()) else {
                    throw CommandFailure(.invalidUsage, "Unknown merge method \(name): use squash, merge, rebase or default.")
                }
                mergeMethod = .some(method)
            }
        }
        let addIgnore = ReviewOptions.normalizePatterns(changes.addIgnore)
        let removeIgnore = ReviewOptions.normalizePatterns(changes.removeIgnore)
        if changes.addIgnore.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            || changes.removeIgnore.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw CommandFailure(.invalidUsage, "An ignore pattern can’t be empty.")
        }
        if let unknown = removeIgnore.first(where: { !current.ignorePaths.contains($0) }) {
            throw CommandFailure(.notFound, "\(unknown) isn’t ignored in \(current.id). Run `prbar repo list`.")
        }
        let changesIgnore = !addIgnore.isEmpty || !removeIgnore.isEmpty
        var ignorePaths = current.ignorePaths + addIgnore
        ignorePaths.removeAll { removeIgnore.contains($0) }
        var branches = changes.baseBranches ?? current.baseBranches
        for branch in changes.addBranches where !branches.contains(branch) { branches.append(branch) }
        branches.removeAll { changes.removeBranches.contains($0) }

        // Como en Settings › Repos, los globs ignorados y el método de merge no refrescan: solo cambian los reviews
        // que vienen y lo que la fila calcula de la config.
        try applyConfig(refresh: changes.changesBranches || localPath != nil) { config in
            if let localPath { config.setLocalPath(localPath, repoID: current.id, login: login) }
            if let change = changes.worktreeDir {
                config.setWorktreeDir(change.value.map(Self.expandPath), repoID: current.id, login: login)
            }
            if let change = changes.testCommand { config.setTestCommand(change.value, repoID: current.id, login: login) }
            if changes.changesBranches { config.setBaseBranches(branches, repoID: current.id, login: login) }
            if let channel {
                config.setSlackChannel(id: channel?.id, name: channel?.name, repoID: current.id, login: login)
            }
            if changesIgnore { config.setIgnorePaths(ignorePaths, repoID: current.id, login: login) }
            if let mergeMethod { config.setMergeMethod(mergeMethod, repoID: current.id, login: login) }
        }
        if channel != nil { reprocessSlack() }
        return try repoInfo(login: login, repoID: current.id)
    }

    func repoBranches(repo: String, account: String?, reload: Bool) async throws -> BranchesInfo {
        let (login, config) = try configuredRepo(repo, account: account)
        await catalog.loadBranches(for: login, repo: config.repo, force: reload)
        let entry = catalog.branches(for: login, repo: config.repo)
        if case .failed(let message) = entry.state { throw CommandFailure(.failed, message) }
        return BranchesInfo(repo: config.id, defaultBranch: entry.value.defaultBranch, branches: entry.value.names,
                            selected: config.baseBranches)
    }

    func followList(repo: String?, account: String?) throws -> [FollowInfo] {
        if let repo {
            let (login, config) = try configuredRepo(repo, account: account)
            return [FollowInfo(repo: config.id, account: login, users: config.watchedUsers)]
        }
        return try repoList(account: account).map { FollowInfo(repo: $0.id, account: $0.account, users: $0.watchedUsers) }
    }

    func followAdd(repo: String, users: [String], account: String?) async throws -> FollowInfo {
        let (login, config) = try configuredRepo(repo, account: account)
        guard !users.isEmpty else { throw CommandFailure(.invalidUsage, "Name at least one GitHub user.") }
        // Como el campo "Add User…": cada login se valida contra GitHub y se guarda con su nombre exacto.
        let token = try await accounts.token(for: login)
        var logins: [String] = []
        for raw in users {
            let name = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            guard let user = try await api.user(login: name, token: token) else {
                throw CommandFailure(.notFound, "There’s no GitHub user named \(name).")
            }
            logins.append(user.login)
        }
        try applyConfig(refresh: true) { appConfig in
            for user in logins { appConfig.addWatchedUser(user, repoID: config.id, login: login) }
        }
        return try followList(repo: config.id, account: login)[0]
    }

    func followRemove(repo: String, users: [String], account: String?) throws -> FollowInfo {
        let (login, config) = try configuredRepo(repo, account: account)
        let names = users.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) }
        if let unknown = names.first(where: { name in !config.watchedUsers.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }) {
            throw CommandFailure(.notFound, "\(unknown) isn’t followed in \(config.id). Run `prbar follow list \(config.id)`.")
        }
        try applyConfig(refresh: true) { appConfig in
            for user in names { appConfig.removeWatchedUser(user, repoID: config.id, login: login) }
        }
        return try followList(repo: config.id, account: login)[0]
    }

    func followSuggestions(repo: String, account: String?) async throws -> [UserSuggestionInfo] {
        let (login, config) = try configuredRepo(repo, account: account)
        await catalog.loadAssignableUsers(for: login, repo: config.repo)
        let entry = catalog.assignableUsers(for: login, repo: config.repo)
        if case .failed(let message) = entry.state { throw CommandFailure(.failed, message) }
        let prs = prStore.snapshot?.items.map(\.pr).filter { $0.repo == config.repo } ?? []
        return UserSuggestion.build(assignable: entry.value, snapshotPRs: prs, me: login, watched: config.watchedUsers)
            .map { UserSuggestionInfo(login: $0.user.login, name: $0.user.name, openPRs: $0.openPRs) }
    }

    func notifyList() async -> NotificationsInfo {
        await refreshNotificationPermission()
        return NotificationsInfo(settings: configStore.config.notifications, deniedInMacOS: notificationsDenied)
    }

    func notifySet(kind: NotificationSettingName, enabled: Bool) throws {
        try applyConfig { $0.notifications[keyPath: kind.keyPath] = enabled }
    }

    func notifySetEnabled(enabled: Bool) throws {
        try applyConfig { $0.notifications.enabled = enabled }
    }

    func claudeShow() -> ClaudeSettings {
        configStore.config.claude
    }

    func claudeSet(changes: ClaudeChanges) throws -> ClaudeSettings {
        guard !changes.isEmpty else { throw CommandFailure(.invalidUsage, "Nothing to change. See `prbar claude set --help`.") }
        for skill in [changes.reviewSkill, changes.filterSkill, changes.respondSkill].compactMap({ $0 })
        where !ClaudeSettings.isValidSkill(skill) {
            throw CommandFailure(.invalidUsage, "“\(skill)” isn’t a valid skill: use plugin:skill or skill. See `prbar claude skills`.")
        }
        var model: ClaudeModel??
        if let change = changes.model {
            switch change {
            case .clear:
                model = .some(nil)
            case .set(let name):
                guard let parsed = ClaudeModel(rawValue: name.lowercased()) else {
                    throw CommandFailure(.invalidUsage, "Unknown model \(name): use opus, sonnet, haiku or default.")
                }
                model = .some(parsed)
            }
        }
        // El modelo del chat: `.clear` = el mismo del review.
        var chatModel: ClaudeModel??
        if let change = changes.chatModel {
            switch change {
            case .clear:
                chatModel = .some(nil)
            case .set(let name):
                guard let parsed = ClaudeModel(rawValue: name.lowercased()) else {
                    throw CommandFailure(.invalidUsage, "Unknown chat model \(name): use opus, sonnet, haiku or same.")
                }
                chatModel = .some(parsed)
            }
        }
        try applyConfig { config in
            if let skill = changes.reviewSkill { config.claude.reviewSkill = skill }
            if let on = changes.filterEnabled { config.claude.filterEnabled = on }
            if let skill = changes.filterSkill { config.claude.filterSkill = skill }
            if let skill = changes.respondSkill { config.claude.respondSkill = skill }
            if let model { config.claude.model = model }
            if let on = changes.chatEnabled { config.claude.chatEnabled = on }
            if let chatModel { config.claude.chatModel = chatModel }
        }
        return configStore.config.claude
    }

    func claudeReset() throws -> ClaudeSettings {
        try applyConfig { $0.claude = ClaudeSettings() }
        return configStore.config.claude
    }

    func claudeSkillList() async -> [SkillInfo] {
        await claudeSkills.refresh(claudePath: tools.claude, toolsResolved: toolsResolved, settings: configStore.config.claude)
        return claudeSkills.entries.map(SkillInfo.init(entry:))
    }

    func toolsSet(tool: ToolName, path: String?) async throws -> [ToolInfo] {
        await setToolPath(path.map(Self.expandPath) ?? "", for: tool.keyPath)
        let list = toolsList()
        if path != nil, list.first(where: { $0.name == tool.rawValue })?.path == nil {
            throw CommandFailure(.failed, "\(tool.rawValue) not found at this path. `prbar tools reset \(tool.rawValue)` goes back to the automatic one.")
        }
        return list
    }
}

// MARK: - Slack

extension AppModel: SlackActions {
    func slackShow() -> SlackInfo {
        SlackInfo(settings: configStore.config.slack, connected: slack.isConnected, hasToken: slack.hasToken,
                  needsUserToken: slack.needsUserToken, issues: slack.issues.map(\.message))
    }

    func slackSetEnabled(enabled: Bool) throws {
        setSlackEnabled(enabled)
        if let settingsError { throw CommandFailure(.failed, settingsError) }
    }

    func slackSetProvider(provider: SlackProvider) throws {
        setSlackProvider(provider)
        if let settingsError { throw CommandFailure(.failed, settingsError) }
    }

    /// "Save and Test".
    func slackTokenSet(token: String) async throws -> SlackCheckInfo {
        do {
            try saveSlackToken(token)
        } catch {
            throw CommandFailure(.invalidUsage, error.localizedDescription)
        }
        return try await slackCheck()
    }

    /// "Delete Token…".
    func slackTokenClear() throws {
        guard slack.hasToken else { throw CommandFailure(.invalidState, "There’s no Slack token saved.") }
        try saveSlackToken(nil)
    }

    func slackSetToggle(toggle: SlackToggleName, enabled: Bool) throws {
        setSlackToggle(toggle.toggle, enabled)
        if let settingsError { throw CommandFailure(.failed, settingsError) }
    }

    func slackSetEmoji(kind: SlackEmojiKind, name: String) throws {
        guard SlackSettings.normalizedEmoji(name) != nil else {
            throw CommandFailure(.invalidUsage, "“\(name)” isn’t an emoji name (letters, numbers, _ + ' -, without colons).")
        }
        try applyConfig(slack: true) { $0.slack[keyPath: kind.keyPath] = name }
    }

    func slackSetSearchDays(days: Int) throws {
        // Lo que permite el stepper de la pestaña Slack.
        guard (7...90).contains(days) else { throw CommandFailure(.invalidUsage, "Search 7 to 90 days.") }
        try applyConfig(slack: true) { $0.slack.searchDays = days }
    }

    func slackTemplateList() -> [TemplateInfo] {
        SlackTemplateName.allCases.map { TemplateInfo(name: $0, settings: configStore.config.slack) }
    }

    func slackTemplateSet(template: SlackTemplateName, text: String) throws {
        try applyConfig(slack: true) { $0.slack[keyPath: template.kind.keyPath] = text }
    }

    func slackTemplateReset(template: SlackTemplateName) throws {
        try applyConfig(slack: true) { $0.slack[keyPath: template.kind.keyPath] = template.kind.defaultTemplate }
    }

    /// "Test Connection".
    func slackCheck() async throws -> SlackCheckInfo {
        let provider = configStore.config.slack.provider
        if provider == .userToken && !slack.hasToken {
            throw CommandFailure(.invalidState, "There’s no Slack token. Run `prbar slack token set`.")
        }
        let identity = try await slack.testConnection()
        return SlackCheckInfo(user: identity.user, team: identity.team, provider: provider)
    }

    /// "Send Test to My DM…".
    func slackSelfTest() async throws -> [SelfTestStepInfo] {
        if configStore.config.slack.provider == .userToken && !slack.hasToken {
            throw CommandFailure(.invalidState, "There’s no Slack token. Run `prbar slack token set`.")
        }
        return await slack.sendSelfTest(logURL: AppPaths.slackConnectorLog).map(SelfTestStepInfo.init(step:))
    }

    func slackChannels(reload: Bool) async throws -> [ChannelInfo] {
        guard configStore.config.slack.enabled, slack.isConnected else {
            throw CommandFailure(.invalidState, "Turn on Slack and connect it first (`prbar slack enable`).")
        }
        return try await slack.channels(reload: reload).channels.map(ChannelInfo.init(channel:))
    }
}
