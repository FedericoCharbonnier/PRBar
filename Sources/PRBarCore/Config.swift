import Foundation

public struct RepoConfig: Hashable, Codable, Sendable, Identifiable {
    public var owner: String
    public var name: String
    public var localPath: String?
    /// Vacío = la rama por defecto del repo.
    public var baseBranches: [String]
    public var slackChannelID: String?
    public var slackChannelName: String?
    public var slackEnabledAt: Date?
    /// Autores cuyos PRs de este repo aparecen en "Para revisar".
    public var watchedUsers: [String]
    /// Carpeta de los worktrees para responder feedback; nil = `<localPath>-worktrees`.
    public var worktreeDir: String?
    /// Comando de tests que corre PRBar después de cada fix; nil = no se corren tests.
    public var testCommand: String?
    /// Globs of files whose findings are hidden in this repo's reviews (spec E.5), on top of
    /// `ClaudeSettings.review.ignorePaths`.
    public var ignorePaths: [String]

    public init(
        owner: String, name: String, localPath: String? = nil, baseBranches: [String] = [],
        slackChannelID: String? = nil, slackChannelName: String? = nil, slackEnabledAt: Date? = nil,
        watchedUsers: [String] = [], worktreeDir: String? = nil, testCommand: String? = nil,
        ignorePaths: [String] = []
    ) {
        self.owner = owner
        self.name = name
        self.localPath = localPath
        self.baseBranches = baseBranches
        self.slackChannelID = slackChannelID
        self.slackChannelName = slackChannelName
        self.slackEnabledAt = slackEnabledAt
        self.watchedUsers = watchedUsers
        self.worktreeDir = worktreeDir
        self.testCommand = testCommand
        self.ignorePaths = ignorePaths
    }

    public var repo: RepoRef { RepoRef(owner: owner, name: name) }
    public var id: String { repo.fullName }

    enum CodingKeys: String, CodingKey {
        case owner, name, localPath, baseBranches, slackChannelID, slackChannelName, slackEnabledAt, watchedUsers
        case worktreeDir, testCommand, ignorePaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(String.self, forKey: .owner)
        name = try c.decode(String.self, forKey: .name)
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath)
        baseBranches = try c.decodeIfPresent([String].self, forKey: .baseBranches) ?? []
        slackChannelID = try c.decodeIfPresent(String.self, forKey: .slackChannelID)
        slackChannelName = try c.decodeIfPresent(String.self, forKey: .slackChannelName)
        slackEnabledAt = try c.decodeIfPresent(Date.self, forKey: .slackEnabledAt)
        watchedUsers = try c.decodeIfPresent([String].self, forKey: .watchedUsers) ?? []
        worktreeDir = try c.decodeIfPresent(String.self, forKey: .worktreeDir)
        testCommand = try c.decodeIfPresent(String.self, forKey: .testCommand)
        ignorePaths = (try? c.decodeIfPresent([String].self, forKey: .ignorePaths)) ?? []
    }
}

public struct AccountConfig: Hashable, Codable, Sendable, Identifiable {
    public var login: String
    public var enabled: Bool
    public var repos: [RepoConfig]

    public init(login: String, enabled: Bool = true, repos: [RepoConfig] = []) {
        self.login = login
        self.enabled = enabled
        self.repos = repos
    }

    public var id: String { login }

    /// `watchedUsers` a nivel cuenta es el formato viejo: solo se lee para migrarlo.
    enum CodingKeys: String, CodingKey { case login, enabled, watchedUsers, repos }

    /// Migración: los usuarios que antes se seguían en toda la cuenta pasan a cada repo de la cuenta
    /// que todavía no tiene lista propia. Si la cuenta no tiene repos no hay dónde ponerlos y se descartan.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        login = try c.decode(String.self, forKey: .login)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        repos = try c.decodeIfPresent([RepoConfig].self, forKey: .repos) ?? []
        let legacyUsers = try c.decodeIfPresent([String].self, forKey: .watchedUsers) ?? []
        if !legacyUsers.isEmpty {
            for index in repos.indices where repos[index].watchedUsers.isEmpty {
                repos[index].watchedUsers = legacyUsers
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(login, forKey: .login)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(repos, forKey: .repos)
    }

    /// `true` si `data` es un config.json con usuarios seguidos a nivel cuenta (formato viejo).
    static func hasLegacyWatchedUsers(_ data: Data) -> Bool {
        struct Probe: Decodable {
            struct Account: Decodable { let watchedUsers: [String]? }
            let accounts: [Account]?
        }
        let probe = try? JSONCoding.decoder.decode(Probe.self, from: data)
        return probe?.accounts?.contains { $0.watchedUsers != nil } ?? false
    }
}

public struct NotificationSettings: Hashable, Codable, Sendable {
    public var enabled = true
    public var newToReview = true
    public var reviewedPRUpdated = true
    public var myPRFeedback = true
    public var reviewFinished = true
    public var myPRApprovedOrCIFailed = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, newToReview, reviewedPRUpdated, myPRFeedback, reviewFinished, myPRApprovedOrCIFailed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        newToReview = try c.decodeIfPresent(Bool.self, forKey: .newToReview) ?? true
        reviewedPRUpdated = try c.decodeIfPresent(Bool.self, forKey: .reviewedPRUpdated) ?? true
        myPRFeedback = try c.decodeIfPresent(Bool.self, forKey: .myPRFeedback) ?? true
        reviewFinished = try c.decodeIfPresent(Bool.self, forKey: .reviewFinished) ?? true
        myPRApprovedOrCIFailed = try c.decodeIfPresent(Bool.self, forKey: .myPRApprovedOrCIFailed) ?? true
    }
}

public struct ToolPaths: Hashable, Codable, Sendable {
    public var gh: String?
    public var git: String?
    public var claude: String?

    public init(gh: String? = nil, git: String? = nil, claude: String? = nil) {
        self.gh = gh
        self.git = git
        self.claude = claude
    }
}

/// Cómo PRBar habla con Slack (spec §17.5). En los dos casos los mensajes y las reacciones salen como el usuario.
public enum SlackProvider: String, Codable, CaseIterable, Sendable {
    /// API Web de Slack directa, con el User OAuth Token (`xoxp-…`) del Llavero.
    case userToken
    /// El conector de Slack de la cuenta de Claude del usuario, vía `claude -p` (sin token en PRBar).
    case claudeConnector
}

public struct SlackSettings: Hashable, Codable, Sendable {
    public static let defaultNewPRTemplate = "{link}"
    public static let defaultUpdateTemplate = "Updated {link}"
    public static let defaultRoundTemplate = "commented x{n}"
    public static let defaultEyesEmoji = "eyes"
    public static let defaultCommentEmoji = "speech_balloon"
    public static let defaultApprovedEmoji = "approved"
    public static let defaultSearchDays = 30
    public static let searchDaysRange = 1...90

    public var enabled = false
    /// La elección guardada; `nil` = nunca se eligió (configs viejas o nuevas): ver `provider`.
    private var providerChoice: SlackProvider?
    /// Cómo se habla con Slack. Sin elección guardada, el conector de Claude (spec §17.5); al arrancar,
    /// `AppConfig.resolveDefaultSlackProvider(hasUserToken:)` fija `userToken` si ya hay un token en el Llavero.
    public var provider: SlackProvider {
        get { providerChoice ?? .claudeConnector }
        set { providerChoice = newValue }
    }
    /// Hay un provider guardado en config.json.
    public var providerChosen: Bool { providerChoice != nil }
    public var newPRTemplate = Self.defaultNewPRTemplate
    public var updateTemplate = Self.defaultUpdateTemplate
    /// Cuándo se encendió Slack o se guardó un token donde no había: solo se anuncian PRs posteriores.
    public var enabledAt: Date?

    // Mis PRs (spec §17.1).
    public var announceNewPRs = true
    public var postUpdated = true

    // PRs de otros: reacciones a mis reviews (spec §17.2).
    public var reactOnReviewStart = true
    public var reactOnFirstComment = true
    public var postRoundMessages = true
    public var reactOnApprove = true
    /// Desde cuándo cuentan mis reviews para las reacciones (sin retroactividad). `nil` = todavía no se activó:
    /// no hay reacciones.
    public var reviewReactionsEnabledAt: Date?
    public var eyesEmoji = Self.defaultEyesEmoji
    public var commentEmoji = Self.defaultCommentEmoji
    public var approvedEmoji = Self.defaultApprovedEmoji
    public var roundTemplate = Self.defaultRoundTemplate
    /// Días hacia atrás en los que se busca el mensaje del PR en el canal.
    public var searchDays = Self.defaultSearchDays

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, newPRTemplate, updateTemplate, enabledAt
        case providerChoice = "provider"
        case announceNewPRs, postUpdated, reactOnReviewStart, reactOnFirstComment, postRoundMessages, reactOnApprove
        case reviewReactionsEnabledAt, eyesEmoji, commentEmoji, approvedEmoji, roundTemplate, searchDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        // Un valor desconocido (p. ej. de una versión más nueva) cuenta como no elegido.
        providerChoice = try? c.decodeIfPresent(SlackProvider.self, forKey: .providerChoice)
        enabledAt = try c.decodeIfPresent(Date.self, forKey: .enabledAt)
        newPRTemplate = try c.decodeIfPresent(String.self, forKey: .newPRTemplate) ?? Self.defaultNewPRTemplate
        updateTemplate = try c.decodeIfPresent(String.self, forKey: .updateTemplate) ?? Self.defaultUpdateTemplate
        announceNewPRs = try c.decodeIfPresent(Bool.self, forKey: .announceNewPRs) ?? true
        postUpdated = try c.decodeIfPresent(Bool.self, forKey: .postUpdated) ?? true
        reactOnReviewStart = try c.decodeIfPresent(Bool.self, forKey: .reactOnReviewStart) ?? true
        reactOnFirstComment = try c.decodeIfPresent(Bool.self, forKey: .reactOnFirstComment) ?? true
        postRoundMessages = try c.decodeIfPresent(Bool.self, forKey: .postRoundMessages) ?? true
        reactOnApprove = try c.decodeIfPresent(Bool.self, forKey: .reactOnApprove) ?? true
        reviewReactionsEnabledAt = try c.decodeIfPresent(Date.self, forKey: .reviewReactionsEnabledAt)
        eyesEmoji = try c.decodeIfPresent(String.self, forKey: .eyesEmoji) ?? Self.defaultEyesEmoji
        commentEmoji = try c.decodeIfPresent(String.self, forKey: .commentEmoji) ?? Self.defaultCommentEmoji
        approvedEmoji = try c.decodeIfPresent(String.self, forKey: .approvedEmoji) ?? Self.defaultApprovedEmoji
        roundTemplate = try c.decodeIfPresent(String.self, forKey: .roundTemplate) ?? Self.defaultRoundTemplate
        searchDays = try c.decodeIfPresent(Int.self, forKey: .searchDays) ?? Self.defaultSearchDays
    }

    /// Plantillas a usar al mandar: una vacía (o solo espacios) cae en la de por defecto, Slack no acepta texto vacío.
    public var effectiveNewPRTemplate: String { Self.nonEmpty(newPRTemplate) ?? Self.defaultNewPRTemplate }
    public var effectiveUpdateTemplate: String { Self.nonEmpty(updateTemplate) ?? Self.defaultUpdateTemplate }
    public var effectiveRoundTemplate: String { Self.nonEmpty(roundTemplate) ?? Self.defaultRoundTemplate }

    /// La plantilla guardada es igual a la de por defecto (`\.newPRTemplate`, `\.updateTemplate`, `\.roundTemplate`).
    public func isDefault(_ keyPath: KeyPath<SlackSettings, String>) -> Bool {
        guard let kind = SlackTemplateKind.allCases.first(where: { $0.keyPath == keyPath }) else { return false }
        return kind.isDefault(self[keyPath: keyPath])
    }

    /// Nombres de emoji listos para `reactions.add`.
    public var effectiveEyesEmoji: String { Self.normalizedEmoji(eyesEmoji) ?? Self.defaultEyesEmoji }
    public var effectiveCommentEmoji: String { Self.normalizedEmoji(commentEmoji) ?? Self.defaultCommentEmoji }
    public var effectiveApprovedEmoji: String { Self.normalizedEmoji(approvedEmoji) ?? Self.defaultApprovedEmoji }

    public var effectiveSearchDays: Int {
        min(max(searchDays, Self.searchDaysRange.lowerBound), Self.searchDaysRange.upperBound)
    }

    /// Alguna de las reacciones a mis reviews está activa.
    public var anyReviewReactionEnabled: Bool {
        reactOnReviewStart || reactOnFirstComment || postRoundMessages || reactOnApprove
    }

    /// `:Eyes:` → `eyes`: sin `:` alrededor, en minúsculas y solo `[a-z0-9_+'-]`. `nil` si no queda nada.
    public static func normalizedEmoji(_ raw: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_+'-")
        let name = String(raw.lowercased().filter { allowed.contains($0) })
        return name.isEmpty ? nil : name
    }

    static func nonEmpty(_ template: String) -> String? {
        template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : template
    }
}

/// Interruptores de la pestaña Slack (spec §17.3).
public enum SlackToggle: CaseIterable, Sendable {
    case announceNewPRs, postUpdated, reactOnReviewStart, reactOnFirstComment, postRoundMessages, reactOnApprove

    public var keyPath: WritableKeyPath<SlackSettings, Bool> {
        switch self {
        case .announceNewPRs: \.announceNewPRs
        case .postUpdated: \.postUpdated
        case .reactOnReviewStart: \.reactOnReviewStart
        case .reactOnFirstComment: \.reactOnFirstComment
        case .postRoundMessages: \.postRoundMessages
        case .reactOnApprove: \.reactOnApprove
        }
    }

    var isReviewReaction: Bool {
        switch self {
        case .announceNewPRs, .postUpdated: false
        case .reactOnReviewStart, .reactOnFirstComment, .postRoundMessages, .reactOnApprove: true
        }
    }
}

/// The Claude model for review and respond runs (`--model`). `nil` in `ClaudeSettings` = the CLI's default.
public enum ClaudeModel: String, Codable, CaseIterable, Sendable {
    case opus, sonnet, haiku

    public var title: String {
        switch self {
        case .opus: "Opus"
        case .sonnet: "Sonnet"
        case .haiku: "Haiku"
        }
    }
}

/// Claude's settings (Settings → Claude): what the review reports and how the fixes are made (spec E.5), the stages'
/// skills or own prompts (E.6), the model and the chat. The defaults reproduce what PRBar always did. A skill is
/// `plugin:skill` (its plugin is loaded with `--plugin-dir`) or a bare name (a built-in or user skill: no plugin).
public struct ClaudeSettings: Hashable, Codable, Sendable {
    public static let defaultReviewSkill = "pr-review-toolkit:review-pr"
    public static let defaultFilterSkill = "superpowers:receiving-code-review"
    public static let defaultRespondSkill = "superpowers:receiving-code-review"

    /// The review: stage 1, the filter and what it reports.
    public var review = ReviewOptions()
    /// Respond to feedback: the analysis, the implementation and the fixes' options.
    public var respond = RespondOptions()
    /// `nil` = the CLI's default model (no `--model`).
    public var model: ClaudeModel?
    /// Chat with Claude in the Review and Respond windows (spec B.8).
    public var chatEnabled = true
    /// The chat's model. `nil` = the same as reviews (`model`).
    public var chatModel: ClaudeModel?
    /// The chats' own prompts (spec E.6).
    public var chatPrompts = ChatPromptSettings()

    public init() {}

    // MARK: Nombres de antes del Plan 9 (el código y los tests de antes los siguen usando)

    /// Review, stage 1.
    public var reviewSkill: String {
        get { review.stage1.skill ?? Self.defaultReviewSkill }
        set { review.stage1.skill = newValue }
    }

    /// Review, stage 2: off = every finding is kept.
    public var filterEnabled: Bool {
        get { review.filter.enabled }
        set { review.filter.enabled = newValue }
    }

    public var filterSkill: String {
        get { review.filter.skill ?? Self.defaultFilterSkill }
        set { review.filter.skill = newValue }
    }

    /// Respond to feedback: the analysis of the review comments.
    public var respondSkill: String {
        get { respond.analysis.skill ?? Self.defaultRespondSkill }
        set { respond.analysis.skill = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case review, respond, model, chatEnabled, chatModel, chatPrompts
        // Before Plan 9: only read, to migrate them.
        case reviewSkill, filterEnabled, filterSkill, respondSkill
    }

    /// Lenient: a missing key, a wrong type or an unknown model falls back to the default. The flat fields of
    /// before Plan 9 are moved into the structure, unless the structure is already there.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        review = (try? c.decodeIfPresent(ReviewOptions.self, forKey: .review)) ?? ReviewOptions()
        respond = (try? c.decodeIfPresent(RespondOptions.self, forKey: .respond)) ?? RespondOptions()
        model = (try? c.decodeIfPresent(ClaudeModel.self, forKey: .model)) ?? nil
        chatEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .chatEnabled)) ?? true
        chatModel = (try? c.decodeIfPresent(ClaudeModel.self, forKey: .chatModel)) ?? nil
        chatPrompts = (try? c.decodeIfPresent(ChatPromptSettings.self, forKey: .chatPrompts)) ?? ChatPromptSettings()
        if !c.contains(.review) {
            if let skill = try? c.decodeIfPresent(String.self, forKey: .reviewSkill) { review.stage1.skill = skill }
            if let on = try? c.decodeIfPresent(Bool.self, forKey: .filterEnabled) { review.filter.enabled = on }
            if let skill = try? c.decodeIfPresent(String.self, forKey: .filterSkill) { review.filter.skill = skill }
        }
        if !c.contains(.respond), let skill = try? c.decodeIfPresent(String.self, forKey: .respondSkill) {
            respond.analysis.skill = skill
        }
    }

    /// Only the structure: the flat fields of before aren't written again.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(review, forKey: .review)
        try c.encode(respond, forKey: .respond)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(chatEnabled, forKey: .chatEnabled)
        try c.encodeIfPresent(chatModel, forKey: .chatModel)
        try c.encode(chatPrompts, forKey: .chatPrompts)
    }

    /// `--model` of the chat's runs: `chatModel`, or the reviews' model.
    public var effectiveChatModel: ClaudeModel? { chatModel ?? model }

    /// The skills to use: trimmed; a blank or invalid one falls back to the default.
    public var effectiveReviewSkill: String { Self.effective(reviewSkill, default: Self.defaultReviewSkill) }
    public var effectiveFilterSkill: String { Self.effective(filterSkill, default: Self.defaultFilterSkill) }
    public var effectiveRespondSkill: String { Self.effective(respondSkill, default: Self.defaultRespondSkill) }
    /// The implementation's skill, if there's a valid one (by default there's none).
    public var effectiveImplementationSkill: String? { respond.implementation.validSkill }

    /// The skills whose plugins a review loads: each stage that uses its skill (spec E.6), the filter only if it's on.
    public var reviewSkills: [String] {
        var skills: [String] = []
        if usesSkill(.review) { skills.append(effectiveReviewSkill) }
        if review.filter.enabled && usesSkill(.filter) { skills.append(effectiveFilterSkill) }
        return skills
    }

    /// The skills a respond run loads (analysis and fixes).
    public var respondSkills: [String] {
        var skills: [String] = []
        if usesSkill(.analysis) { skills.append(effectiveRespondSkill) }
        if usesSkill(.implementation), let skill = effectiveImplementationSkill, !skills.contains(skill) {
            skills.append(skill)
        }
        return skills
    }

    /// `plugin:skill` or `skill`: each part is `[A-Za-z0-9._-]`, not empty and not starting with `.` (the plugin is a
    /// folder name; the whole name goes in the prompt between backticks).
    public static func isValidSkill(_ skill: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let parts = skill.split(separator: ":", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            !part.isEmpty && !part.hasPrefix(".") && part.allSatisfy { allowed.contains($0) }
        }
    }

    /// `pr-review-toolkit:review-pr` → `pr-review-toolkit`; a bare name has no plugin.
    public static func plugin(of skill: String) -> String? {
        guard let colon = skill.firstIndex(of: ":") else { return nil }
        return String(skill[..<colon])
    }

    static func effective(_ skill: String, default fallback: String) -> String {
        let trimmed = skill.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidSkill(trimmed) ? trimmed : fallback
    }
}

public struct AppConfig: Hashable, Codable, Sendable {
    public var accounts: [AccountConfig] = []
    public var refreshIntervalMinutes = 2
    public var launchAtLogin = false
    public var notifications = NotificationSettings()
    public var toolPaths = ToolPaths()
    public var slack = SlackSettings()
    public var claude = ClaudeSettings()
    public var updates = UpdateSettings()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case accounts, refreshIntervalMinutes, launchAtLogin, notifications, toolPaths, slack, claude, updates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([AccountConfig].self, forKey: .accounts) ?? []
        refreshIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? 2
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        notifications = try c.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        toolPaths = try c.decodeIfPresent(ToolPaths.self, forKey: .toolPaths) ?? ToolPaths()
        slack = try c.decodeIfPresent(SlackSettings.self, forKey: .slack) ?? SlackSettings()
        claude = (try? c.decodeIfPresent(ClaudeSettings.self, forKey: .claude)) ?? ClaudeSettings()
        updates = (try? c.decodeIfPresent(UpdateSettings.self, forKey: .updates)) ?? UpdateSettings()
    }
}

// MARK: - Mutaciones usadas por la UI de Configuración

extension AppConfig {
    /// The config of `repo` in `account`. GitHub names don't distinguish case, so neither does this.
    public func repoConfig(account: String, repo: RepoRef) -> RepoConfig? {
        accounts.first { $0.login.caseInsensitiveCompare(account) == .orderedSame }?.repos.first {
            $0.owner.caseInsensitiveCompare(repo.owner) == .orderedSame && $0.name.caseInsensitiveCompare(repo.name) == .orderedSame
        }
    }

    public mutating func setAccountEnabled(_ login: String, _ enabled: Bool) {
        if let index = accounts.firstIndex(where: { $0.login == login }) {
            accounts[index].enabled = enabled
        } else if enabled {
            accounts.append(AccountConfig(login: login))
        }
    }

    public mutating func addRepo(_ repo: RepoRef, to login: String) {
        withAccount(login) { account in
            guard !account.repos.contains(where: { $0.id == repo.fullName }) else { return }
            account.repos.append(RepoConfig(owner: repo.owner, name: repo.name))
        }
    }

    public mutating func removeRepo(_ repoID: String, from login: String) {
        withAccount(login) { $0.repos.removeAll { $0.id == repoID } }
    }

    public mutating func setLocalPath(_ path: String?, repoID: String, login: String) {
        withRepo(repoID, login: login) { $0.localPath = path }
    }

    /// Vacío o solo espacios = nil (la carpeta por defecto).
    public mutating func setWorktreeDir(_ path: String?, repoID: String, login: String) {
        withRepo(repoID, login: login) { $0.worktreeDir = Self.nonBlank(path) }
    }

    /// Vacío o solo espacios = nil (sin tests).
    public mutating func setTestCommand(_ command: String?, repoID: String, login: String) {
        withRepo(repoID, login: login) { $0.testCommand = Self.nonBlank(command) }
    }

    /// Normalized: trimmed, without empty patterns or repeats.
    public mutating func setIgnorePaths(_ patterns: [String], repoID: String, login: String) {
        withRepo(repoID, login: login) { $0.ignorePaths = ReviewOptions.normalizePatterns(patterns) }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Encender Slack guarda `now` como `slack.enabledAt`: al reactivarlo no se anuncia lo acumulado.
    public mutating func setSlackEnabled(_ enabled: Bool, now: Date = Date()) {
        if enabled && !slack.enabled {
            slack.enabledAt = now
            activateReviewReactionsIfNeeded(now: now)
        }
        slack.enabled = enabled
    }

    /// Se guardó un token donde no había: igual que encender Slack, solo cuentan PRs desde `now`.
    public mutating func slackTokenAdded(now: Date = Date()) {
        slack.enabledAt = now
        activateReviewReactionsIfNeeded(now: now)
    }

    /// Cambia cómo se conecta PRBar a Slack. Es una credencial nueva: igual que guardar un token, solo cuentan PRs
    /// desde `now` (así no se anuncia lo acumulado mientras no había conexión).
    public mutating func setSlackProvider(_ provider: SlackProvider, now: Date = Date()) {
        let changed = slack.provider != provider
        slack.provider = provider
        if changed { slackTokenAdded(now: now) }
    }

    /// Sin provider guardado: si ya hay un token de usuario en el Llavero (comprobado solo por atributos) se queda
    /// con `userToken`; si no, con el conector de Claude. Se guarda para que no cambie después. No corta el backlog
    /// (la conexión no cambió). Devuelve `true` si cambió algo (quien llama guarda la config).
    @discardableResult
    public mutating func resolveDefaultSlackProvider(hasUserToken: Bool) -> Bool {
        guard !slack.providerChosen else { return false }
        slack.provider = hasUserToken ? .userToken : .claudeConnector
        return true
    }

    /// Cambia un interruptor de Slack. Encender una reacción a reviews cuando no había ninguna activa guarda `now`
    /// como `reviewReactionsEnabledAt`: las reviews anteriores no cuentan (spec §17.2, punto 5). Con alguna ya
    /// activa la fecha no cambia, así no se reinicia la numeración de rondas.
    public mutating func setSlackToggle(_ toggle: SlackToggle, _ on: Bool, now: Date = Date()) {
        let wasActive = slack.anyReviewReactionEnabled
        slack[keyPath: toggle.keyPath] = on
        if toggle.isReviewReaction && on && (!wasActive || slack.reviewReactionsEnabledAt == nil) {
            slack.reviewReactionsEnabledAt = now
        }
    }

    /// Configs que vienen de antes de Plan 5 traen las reacciones encendidas por defecto pero sin fecha de inicio:
    /// arrancan en `now`. Devuelve `true` si cambió algo (quien llama guarda la config).
    @discardableResult
    public mutating func activateReviewReactionsIfNeeded(now: Date = Date()) -> Bool {
        guard slack.reviewReactionsEnabledAt == nil, slack.anyReviewReactionEnabled else { return false }
        slack.reviewReactionsEnabledAt = now
        return true
    }

    /// Elegir un canal distinto guarda `now` como `slackEnabledAt` (spec §15.1): solo se anuncian
    /// PRs posteriores. Volver a elegir el mismo canal no cambia nada; `id == nil` quita el canal.
    public mutating func setSlackChannel(id: String?, name: String?, repoID: String, login: String, now: Date = Date()) {
        withRepo(repoID, login: login) { repo in
            guard repo.slackChannelID != id else { return }
            repo.slackChannelID = id
            repo.slackChannelName = id == nil ? nil : name
            repo.slackEnabledAt = id == nil ? nil : now
        }
    }

    public mutating func toggleBaseBranch(_ branch: String, repoID: String, login: String) {
        withRepo(repoID, login: login) { repo in
            if let index = repo.baseBranches.firstIndex(of: branch) {
                repo.baseBranches.remove(at: index)
            } else {
                repo.baseBranches.append(branch)
            }
        }
    }

    public mutating func addWatchedUser(_ user: String, repoID: String, login: String) {
        withRepo(repoID, login: login) { repo in
            guard !repo.watchedUsers.contains(where: { $0.lowercased() == user.lowercased() }) else { return }
            repo.watchedUsers.append(user)
        }
    }

    public mutating func removeWatchedUser(_ user: String, repoID: String, login: String) {
        withRepo(repoID, login: login) { $0.watchedUsers.removeAll { $0.lowercased() == user.lowercased() } }
    }

    private mutating func withAccount(_ login: String, _ body: (inout AccountConfig) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.login == login }) else { return }
        body(&accounts[index])
    }

    private mutating func withRepo(_ repoID: String, login: String, _ body: (inout RepoConfig) -> Void) {
        withAccount(login) { account in
            guard let index = account.repos.firstIndex(where: { $0.id == repoID }) else { return }
            body(&account.repos[index])
        }
    }
}
