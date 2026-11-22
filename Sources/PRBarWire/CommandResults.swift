import Foundation

// Resultados de los comandos (`result` de la respuesta y `data` de `--json`, ver docs/cli.md). Las claves son
// estables: agregar campos opcionales está bien; renombrar o quitar sube `JSONOutput.schemaVersion`.

// MARK: - Estado y PRs

public struct ToolInfo: Codable, Equatable, Sendable {
    public var name: String
    /// La ruta encontrada; `nil` = no se encontró.
    public var path: String?
    /// Hay una ruta elegida a mano (Settings › General).
    public var custom: Bool

    public init(name: String, path: String?, custom: Bool) {
        self.name = name
        self.path = path
        self.custom = custom
    }
}

public struct JobInfo: Codable, Equatable, Sendable {
    public var pr: String
    public var kind: String
    public var phase: String

    public init(pr: String, kind: String, phase: String) {
        self.pr = pr
        self.kind = kind
        self.phase = phase
    }
}

public struct StatusInfo: Codable, Equatable, Sendable {
    public var appVersion: String
    public var refreshing: Bool
    public var fetchedAt: Date?
    public var offline: Bool
    public var rateLimitedUntil: Date?
    public var badgeCount: Int
    /// Por `PRCategory.rawValue`.
    public var counts: [String: Int]
    public var issues: [String]
    public var slackIssues: [String]
    public var jobs: [JobInfo]
    public var accounts: [String]
    public var tools: [ToolInfo]
    /// Por qué no arranca ningún trabajo nuevo (se está instalando una actualización), si es el caso.
    public var blockedReason: String?
    /// La versión nueva que ofrece PRBar, si hay.
    public var updateAvailable: String?
    /// PRs accionables por pestaña (`PopoverTab.rawValue`). Opcional: una app vieja no lo manda.
    public var tabCounts: [String: Int]?
    /// PRs por sección del popover (`PopoverSection.rawValue`), con Other y Waiting for Review por separado.
    /// Opcional: una app vieja no lo manda.
    public var sectionCounts: [String: Int]?

    public init(appVersion: String, refreshing: Bool = false, fetchedAt: Date? = nil, offline: Bool = false,
                rateLimitedUntil: Date? = nil, badgeCount: Int = 0, counts: [String: Int] = [:], issues: [String] = [],
                slackIssues: [String] = [], jobs: [JobInfo] = [], accounts: [String] = [], tools: [ToolInfo] = [],
                blockedReason: String? = nil, updateAvailable: String? = nil, tabCounts: [String: Int]? = nil,
                sectionCounts: [String: Int]? = nil) {
        self.appVersion = appVersion
        self.refreshing = refreshing
        self.fetchedAt = fetchedAt
        self.offline = offline
        self.rateLimitedUntil = rateLimitedUntil
        self.badgeCount = badgeCount
        self.counts = counts
        self.issues = issues
        self.slackIssues = slackIssues
        self.jobs = jobs
        self.accounts = accounts
        self.tools = tools
        self.blockedReason = blockedReason
        self.updateAvailable = updateAvailable
        self.tabCounts = tabCounts
        self.sectionCounts = sectionCounts
    }
}

public struct PRInfo: Codable, Equatable, Sendable {
    public var id: String
    public var repo: String
    public var number: Int
    public var title: String
    public var url: URL
    public var author: String
    public var account: String
    public var category: String
    public var baseRef: String
    public var headRef: String
    public var isDraft: Bool
    public var ci: String
    public var additions: Int
    public var deletions: Int
    public var updatedAt: Date
    /// Fase del review de PRBar (`ReviewPhase.cliName`), si hay.
    public var review: String?
    /// Fase de Responder (`RespondPhase.cliName`), si hay.
    public var respond: String?
    /// Fase del merge (`MergePhase.cliName`), si hay.
    public var merge: String?
    /// El error del merge, si falló.
    public var mergeError: String?
    /// Pestaña y sección del popover (spec H). Opcionales: una app con protocolo 3 no las manda.
    public var tab: PopoverTab?
    public var section: PopoverSection?
    /// El nombre visible del autor en GitHub ("Laura Méndez"), si tiene uno (el iPhone lo muestra en vez del login).
    public var authorName: String?
    /// Cuántos revisores aprobaron (su último review es un approve); nil si ninguno.
    public var approvals: Int?
    /// Archivos que cambia el PR, si GitHub lo dijo en el último refresh.
    public var changedFiles: Int?

    public init(id: String, repo: String, number: Int, title: String, url: URL, author: String, account: String,
                category: String, baseRef: String, headRef: String, isDraft: Bool, ci: String, additions: Int,
                deletions: Int, updatedAt: Date, review: String? = nil, respond: String? = nil, merge: String? = nil,
                mergeError: String? = nil, tab: PopoverTab? = nil, section: PopoverSection? = nil,
                authorName: String? = nil, approvals: Int? = nil, changedFiles: Int? = nil) {
        self.id = id
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.account = account
        self.category = category
        self.baseRef = baseRef
        self.headRef = headRef
        self.isDraft = isDraft
        self.ci = ci
        self.additions = additions
        self.deletions = deletions
        self.updatedAt = updatedAt
        self.review = review
        self.respond = respond
        self.merge = merge
        self.mergeError = mergeError
        self.tab = tab
        self.section = section
        self.authorName = authorName
        self.approvals = approvals
        self.changedFiles = changedFiles
    }
}

public struct PRLink: Codable, Equatable, Sendable {
    public var pr: String
    public var url: URL

    public init(pr: String, url: URL) {
        self.pr = pr
        self.url = url
    }
}

// MARK: - Review

public struct FindingInfo: Codable, Equatable, Sendable {
    public var number: Int
    public var id: String
    public var severity: Severity
    public var location: String
    public var title: String
    public var body: String
    public var keptByFilter: Bool
    public var filterReason: String?
    public var included: Bool
    public var edited: Bool
    /// Lo ocultan las opciones del review ("Hidden by your settings", spec E.5): por qué.
    public var hiddenBy: String?

    public init(number: Int, id: String, severity: Severity, location: String, title: String, body: String,
                keptByFilter: Bool, filterReason: String?, included: Bool, edited: Bool, hiddenBy: String? = nil) {
        self.number = number
        self.id = id
        self.severity = severity
        self.location = location
        self.title = title
        self.body = body
        self.keptByFilter = keptByFilter
        self.filterReason = filterReason
        self.included = included
        self.edited = edited
        self.hiddenBy = hiddenBy
    }
}

public struct ReviewInfo: Codable, Equatable, Sendable {
    public var pr: String
    /// `ReviewPhase.cliName` o `"none"`.
    public var phase: String
    public var detail: String?
    public var title: String?
    public var summary: String?
    public var language: String?
    public var account: String?
    /// El PR recibió commits después del review: todo va al cuerpo de la review.
    public var outdated: Bool
    public var findings: [FindingInfo]
    public var generalComment: String?
    public var reviewURL: URL?
    public var logPath: String?
    /// Claude's usage for the review and its chat (spec O); nil if unknown.
    public var usage: ClaudeUsage?

    public init(pr: String, phase: String, detail: String? = nil, title: String? = nil, summary: String? = nil,
                language: String? = nil, account: String? = nil, outdated: Bool, findings: [FindingInfo],
                generalComment: String? = nil, reviewURL: URL? = nil, logPath: String? = nil, usage: ClaudeUsage? = nil) {
        self.pr = pr
        self.phase = phase
        self.detail = detail
        self.title = title
        self.summary = summary
        self.language = language
        self.account = account
        self.outdated = outdated
        self.findings = findings
        self.generalComment = generalComment
        self.reviewURL = reviewURL
        self.logPath = logPath
        self.usage = usage
    }
}

public struct PublishedReviewInfo: Codable, Equatable, Sendable {
    public var pr: String
    public var url: URL
    /// `ReviewRecord.Action.rawValue`: approve, requestChanges, comment.
    public var action: String
    public var comments: Int
    public var publishedAt: Date

    public init(pr: String, url: URL, action: String, comments: Int, publishedAt: Date) {
        self.pr = pr
        self.url = url
        self.action = action
        self.comments = comments
        self.publishedAt = publishedAt
    }
}

// MARK: - Respond

public struct RespondItemInfo: Codable, Equatable, Sendable {
    public var number: Int
    public var id: String
    public var reviewer: String
    public var location: String
    public var outdated: Bool
    /// "autor: texto" de cada comentario del hilo.
    public var thread: [String]
    public var commentURL: URL?
    public var assessment: String
    /// Lo que propuso Claude (`FeedbackAction.rawValue`).
    public var suggested: String
    public var implement: Bool
    public var fixPlan: String
    public var reply: Bool
    public var replyText: String
    public var postedURL: URL?

    public init(number: Int, id: String, reviewer: String, location: String, outdated: Bool, thread: [String],
                commentURL: URL? = nil, assessment: String, suggested: String, implement: Bool, fixPlan: String,
                reply: Bool, replyText: String, postedURL: URL? = nil) {
        self.number = number
        self.id = id
        self.reviewer = reviewer
        self.location = location
        self.outdated = outdated
        self.thread = thread
        self.commentURL = commentURL
        self.assessment = assessment
        self.suggested = suggested
        self.implement = implement
        self.fixPlan = fixPlan
        self.reply = reply
        self.replyText = replyText
        self.postedURL = postedURL
    }
}

public struct CommitDTO: Codable, Equatable, Sendable {
    public var item: String
    public var status: String
    public var sha: String?
    public var summary: String

    public init(item: String, status: String, sha: String?, summary: String) {
        self.item = item
        self.status = status
        self.sha = sha
        self.summary = summary
    }
}

public struct TestInfo: Codable, Equatable, Sendable {
    public var command: String
    public var passed: Bool
    public var outputTail: String

    public init(command: String, passed: Bool, outputTail: String) {
        self.command = command
        self.passed = passed
        self.outputTail = outputTail
    }
}

public struct RespondInfo: Codable, Equatable, Sendable {
    public var pr: String
    /// `RespondPhase.cliName` o `"none"`.
    public var phase: String
    public var detail: String?
    public var runningTests: Bool
    public var title: String?
    public var account: String?
    public var headRef: String?
    public var worktree: String?
    public var language: String?
    public var items: [RespondItemInfo]
    /// Fixes y respuestas que saldrían con lo elegido.
    public var fixes: Int
    public var replies: Int
    public var commits: [CommitDTO]
    public var diffStat: String?
    public var sensitiveChanges: [String]
    public var tests: TestInfo?
    public var pushed: Bool
    public var pendingReplies: Int
    public var testCommand: String?
    public var errorMessage: String?
    public var logPath: String?
    /// Los tests de antes del push fallaron: no se pusheó ("Push Anyway" = `prbar respond push --anyway`).
    public var pushBlockedByTests: Bool
    /// `feedback` o `ciFix` (spec K); nil = `feedback`.
    public var mode: RespondMode?
    /// Fix CI: los checks que fallaron.
    public var ciChecks: [CICheckFailure]?
    /// Fix CI: por qué no se pusheó (los checks pasan ahora); "Push Anyway" = `prbar ci push --anyway`.
    public var pushBlockedByCI: String?
    /// Claude's usage for the run and its chat (spec O); nil if unknown.
    public var usage: ClaudeUsage?
    /// Cuándo arrancó la corrida (el cronómetro del iPhone).
    public var startedAt: Date?
    /// Fix CI: cuántos checks corrieron en el head que falló ("2 of 9").
    public var totalChecks: Int?
    /// El resumen de los últimos tests ("142 passed"), sacado de su salida.
    public var testSummary: String?
    /// El archivo que Claude está editando. Todavía no se llena (la cola de Responder no sigue las herramientas).
    public var currentFile: String?
    /// El worktree de PRBar tiene commits o cambios sin pushear (fixes listos, un push que falló, una implementación
    /// cancelada o fallida): descartar los borra. nil = no (o una app vieja).
    public var unpushedWork: Bool?

    public init(pr: String, phase: String, detail: String? = nil, runningTests: Bool, title: String? = nil,
                account: String? = nil, headRef: String? = nil, worktree: String? = nil, language: String? = nil,
                items: [RespondItemInfo], fixes: Int, replies: Int, commits: [CommitDTO], diffStat: String? = nil,
                sensitiveChanges: [String], tests: TestInfo? = nil, pushed: Bool, pendingReplies: Int,
                testCommand: String? = nil, errorMessage: String? = nil, logPath: String? = nil,
                pushBlockedByTests: Bool, mode: RespondMode? = nil, ciChecks: [CICheckFailure]? = nil,
                pushBlockedByCI: String? = nil, usage: ClaudeUsage? = nil) {
        self.pr = pr
        self.phase = phase
        self.detail = detail
        self.runningTests = runningTests
        self.title = title
        self.account = account
        self.headRef = headRef
        self.worktree = worktree
        self.language = language
        self.items = items
        self.fixes = fixes
        self.replies = replies
        self.commits = commits
        self.diffStat = diffStat
        self.sensitiveChanges = sensitiveChanges
        self.tests = tests
        self.pushed = pushed
        self.pendingReplies = pendingReplies
        self.testCommand = testCommand
        self.errorMessage = errorMessage
        self.logPath = logPath
        self.pushBlockedByTests = pushBlockedByTests
        self.mode = mode
        self.ciChecks = ciChecks
        self.pushBlockedByCI = pushBlockedByCI
        self.usage = usage
    }
}

public struct RespondDiff: Codable, Equatable, Sendable {
    public var pr: String
    public var diffStat: String
    /// El diff completo (`startHeadOid..HEAD`); `nil` en resultados viejos.
    public var diff: String?
    public var truncated: Bool
    public var sensitiveChanges: [String]

    public init(pr: String, diffStat: String, diff: String?, truncated: Bool, sensitiveChanges: [String]) {
        self.pr = pr
        self.diffStat = diffStat
        self.diff = diff
        self.truncated = truncated
        self.sensitiveChanges = sensitiveChanges
    }
}

// MARK: - Historial

public struct HistoryEntryInfo: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: HistoryKind
    public var pr: String
    public var repo: String
    public var number: Int
    public var title: String
    public var status: String
    public var startedAt: Date
    public var finishedAt: Date?
    /// Claude's usage for the whole job and its chat (spec O); nil in older records ("—").
    public var usage: ClaudeUsage?

    public init(id: UUID, kind: HistoryKind, pr: String, repo: String, number: Int, title: String, status: String,
                startedAt: Date, finishedAt: Date? = nil, usage: ClaudeUsage? = nil) {
        self.id = id
        self.kind = kind
        self.pr = pr
        self.repo = repo
        self.number = number
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.usage = usage
    }

    /// `prbar history`: filters by repo, kind (a Fix CI is `.ciFix`, never `.respond`; spec K.6.8) and search, newest
    /// first, at most `limit` (50 by default).
    public static func listing(_ entries: [HistoryEntryInfo], repo: String?, kind: HistoryKind?, limit: Int?,
                               search: String?) -> [HistoryEntryInfo] {
        let filtered = entries
            .filter { kind == nil || $0.kind == kind }
            .filter { entry in repo.map { entry.repo.caseInsensitiveCompare($0) == .orderedSame } ?? true }
            .filter { $0.matches(search ?? "") }
            .sorted { $0.startedAt > $1.startedAt }
        return Array(filtered.prefix(max(limit ?? 50, 1)))
    }

    /// Búsqueda de la ventana de Historial: título, repo o número ("482" o "#482"). `query` ya en minúsculas.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        if title.lowercased().contains(query) || repo.lowercased().contains(query) { return true }
        let number = query.hasPrefix("#") ? String(query.dropFirst()) : query
        return !number.isEmpty && String(self.number).hasPrefix(number)
            || pr.lowercased().contains(query)
    }
}

public struct PostedReplyInfo: Codable, Equatable, Sendable {
    public var item: String
    public var location: String
    public var url: URL

    public init(item: String, location: String, url: URL) {
        self.item = item
        self.location = location
        self.url = url
    }
}

public struct HistoryDetail: Codable, Equatable, Sendable {
    public var entry: HistoryEntryInfo
    public var prURL: URL
    public var summary: String?
    public var errorMessage: String?
    /// Review: cada hallazgo; `included` = se publicó, con el texto publicado.
    public var findings: [FindingInfo]
    public var generalComment: String?
    public var action: String?
    public var reviewURL: URL?
    public var replies: [PostedReplyInfo]
    public var pushed: Bool
    public var logPath: String?
    /// "Open to Post" (`prbar history reopen`).
    public var canReopen: Bool
    /// "Show Response" (`prbar open <pr> --respond`).
    public var canOpen: Bool
    /// La conversación con Claude de ese review, análisis o merge (la sección "Chat" del historial), si hubo.
    public var chat: ChatInfo?
    /// Merge: el método y el head mergeado (o intentado).
    public var mergeMethod: MergeMethod?
    public var headOid: String?

    public init(entry: HistoryEntryInfo, prURL: URL, summary: String? = nil, errorMessage: String? = nil,
                findings: [FindingInfo] = [], generalComment: String? = nil, action: String? = nil, reviewURL: URL? = nil,
                replies: [PostedReplyInfo] = [], pushed: Bool = false, logPath: String? = nil, canReopen: Bool = false,
                canOpen: Bool = false, chat: ChatInfo? = nil, mergeMethod: MergeMethod? = nil, headOid: String? = nil) {
        self.entry = entry
        self.prURL = prURL
        self.summary = summary
        self.errorMessage = errorMessage
        self.findings = findings
        self.generalComment = generalComment
        self.action = action
        self.reviewURL = reviewURL
        self.replies = replies
        self.pushed = pushed
        self.logPath = logPath
        self.canReopen = canReopen
        self.canOpen = canOpen
        self.chat = chat
        self.mergeMethod = mergeMethod
        self.headOid = headOid
    }
}

// MARK: - Configuración

public struct AccountInfo: Codable, Equatable, Sendable {
    public var login: String
    public var enabled: Bool
    /// Hay sesión de `gh` para esta cuenta.
    public var inGh: Bool
    /// Es la cuenta activa de `gh`.
    public var active: Bool

    public init(login: String, enabled: Bool, inGh: Bool, active: Bool) {
        self.login = login
        self.enabled = enabled
        self.inGh = inGh
        self.active = active
    }
}

public struct RepoInfo: Codable, Equatable, Sendable {
    public var id: String
    public var account: String
    public var localPath: String?
    public var worktreeDir: String?
    public var testCommand: String?
    public var baseBranches: [String]
    public var watchedUsers: [String]
    public var slackChannel: String?
    public var ignorePaths: [String]
    /// `nil` = el de GitHub.
    public var mergeMethod: MergeMethod?
    /// `local`, el nombre de un destino SSH, o `nil` = "Default" (spec J.1).
    public var runOn: String?

    public init(id: String, account: String, localPath: String? = nil, worktreeDir: String? = nil,
                testCommand: String? = nil, baseBranches: [String], watchedUsers: [String], slackChannel: String? = nil,
                ignorePaths: [String], mergeMethod: MergeMethod? = nil, runOn: String? = nil) {
        self.id = id
        self.account = account
        self.localPath = localPath
        self.worktreeDir = worktreeDir
        self.testCommand = testCommand
        self.baseBranches = baseBranches
        self.watchedUsers = watchedUsers
        self.slackChannel = slackChannel
        self.ignorePaths = ignorePaths
        self.mergeMethod = mergeMethod
        self.runOn = runOn
    }
}

/// `prbar runners list|add|set|test` (Settings › Claude › Run On).
public struct RunnerInfo: Codable, Equatable, Sendable {
    public var name: String
    /// `user@host:port` tal como se escribió.
    public var host: String
    public var dir: String
    public var fallback: Bool
    public var isDefault: Bool
    /// La última verificación (`nil` = todavía no se verificó en esta sesión).
    public var lastCheck: RunnerHostInfo?

    public init(name: String, host: String, dir: String, fallback: Bool, isDefault: Bool,
                lastCheck: RunnerHostInfo? = nil) {
        self.name = name
        self.host = host
        self.dir = dir
        self.fallback = fallback
        self.isDefault = isDefault
        self.lastCheck = lastCheck
    }
}

public struct BranchesInfo: Codable, Equatable, Sendable {
    public var repo: String
    public var defaultBranch: String?
    public var branches: [String]
    /// Las ramas base elegidas (vacío = la rama por defecto).
    public var selected: [String]

    public init(repo: String, defaultBranch: String?, branches: [String], selected: [String]) {
        self.repo = repo
        self.defaultBranch = defaultBranch
        self.branches = branches
        self.selected = selected
    }
}

public struct FollowInfo: Codable, Equatable, Sendable {
    public var repo: String
    public var account: String
    public var users: [String]

    public init(repo: String, account: String, users: [String]) {
        self.repo = repo
        self.account = account
        self.users = users
    }
}

public struct UserSuggestionInfo: Codable, Equatable, Sendable {
    public var login: String
    public var name: String?
    public var openPRs: Int

    public init(login: String, name: String?, openPRs: Int) {
        self.login = login
        self.name = name
        self.openPRs = openPRs
    }
}

public struct NotificationsInfo: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Por `NotificationSettingName.rawValue`.
    public var kinds: [String: Bool]
    /// Las notificaciones de PRBar están apagadas en Ajustes del Sistema.
    public var deniedInMacOS: Bool

    public init(enabled: Bool, kinds: [String: Bool], deniedInMacOS: Bool) {
        self.enabled = enabled
        self.kinds = kinds
        self.deniedInMacOS = deniedInMacOS
    }
}

public struct SkillInfo: Codable, Equatable, Sendable {
    public var id: String
    /// `plugin:<nombre>` o `user`.
    public var source: String
    public var description: String?
    public var available: Bool
    public var reason: String?

    public init(id: String, source: String, description: String?, available: Bool, reason: String?) {
        self.id = id
        self.source = source
        self.description = description
        self.available = available
        self.reason = reason
    }
}

// MARK: - Slack

public struct SlackInfo: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var provider: SlackProvider
    public var connected: Bool
    public var hasToken: Bool
    public var needsUserToken: Bool
    /// Por `SlackToggleName.rawValue`.
    public var toggles: [String: Bool]
    /// Por `SlackEmojiKind.rawValue`.
    public var emojis: [String: String]
    public var searchDays: Int
    public var issues: [String]

    public init(enabled: Bool, provider: SlackProvider, connected: Bool, hasToken: Bool, needsUserToken: Bool,
                toggles: [String: Bool], emojis: [String: String], searchDays: Int, issues: [String]) {
        self.enabled = enabled
        self.provider = provider
        self.connected = connected
        self.hasToken = hasToken
        self.needsUserToken = needsUserToken
        self.toggles = toggles
        self.emojis = emojis
        self.searchDays = searchDays
        self.issues = issues
    }
}

public struct SlackCheckInfo: Codable, Equatable, Sendable {
    public var user: String
    public var team: String
    public var provider: SlackProvider

    public init(user: String, team: String, provider: SlackProvider) {
        self.user = user
        self.team = team
        self.provider = provider
    }
}

public struct SelfTestStepInfo: Codable, Equatable, Sendable {
    public var title: String
    /// ok, failed o skipped.
    public var status: String
    public var detail: String

    public init(title: String, status: String, detail: String) {
        self.title = title
        self.status = status
        self.detail = detail
    }
}

public struct TemplateInfo: Codable, Equatable, Sendable {
    public var name: String
    public var text: String
    public var isDefault: Bool
    public var defaultText: String
    public var variables: [String]

    public init(name: String, text: String, isDefault: Bool, defaultText: String, variables: [String]) {
        self.name = name
        self.text = text
        self.isDefault = isDefault
        self.defaultText = defaultText
        self.variables = variables
    }
}

public struct ChannelInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isPrivate: Bool
    public var isMember: Bool

    public init(id: String, name: String, isPrivate: Bool, isMember: Bool) {
        self.id = id
        self.name = name
        self.isPrivate = isPrivate
        self.isMember = isMember
    }
}

// MARK: - Ready to Merge

public struct MergeInfo: Codable, Equatable, Sendable {
    public var pr: String
    public var method: MergeMethod
    public var mergedAt: Date
    public var url: URL

    public init(pr: String, method: MergeMethod, mergedAt: Date, url: URL) {
        self.pr = pr
        self.method = method
        self.mergedAt = mergedAt
        self.url = url
    }
}

/// Lo que muestra la confirmación de `prbar merge` (lo mismo que el diálogo de Merge) y `prbar merge --preview`.
public struct MergePreviewInfo: Codable, Equatable, Sendable {
    public var pr: String
    public var title: String
    public var url: URL
    public var baseRef: String
    public var headRef: String
    /// El head que se va a mergear: `prbar merge` lo manda de vuelta y la app no mergea otro.
    public var headOid: String
    public var commitCount: Int?
    /// El método elegido (o el por defecto del repo).
    public var method: MergeMethod
    /// La nota del diálogo (p. ej. checks que fallan, en `UNSTABLE`).
    public var note: String?
    public var deletesBranch: Bool
    /// El error de un intento anterior (la fila), que mergear ahora descarta.
    public var previousError: String?
    /// El resumen del PR (spec G.5): descripción, reviews, checks, conversaciones y archivos. `nil` si no se pudo traer.
    public var detail: MergeDetail?
    /// Por qué no está `detail`.
    public var detailError: String?
    /// Por qué todavía no se puede mergear (`MergeFlow.previewCheck`); `nil` = se puede. Una app vieja no lo manda: en
    /// ese caso la vista previa de un PR que no se puede mergear es un error.
    public var problem: String?

    public init(pr: String, title: String, url: URL, baseRef: String, headRef: String, headOid: String,
                commitCount: Int? = nil, method: MergeMethod, note: String? = nil, deletesBranch: Bool,
                previousError: String? = nil, detail: MergeDetail? = nil, detailError: String? = nil,
                problem: String? = nil) {
        self.pr = pr
        self.title = title
        self.url = url
        self.baseRef = baseRef
        self.headRef = headRef
        self.headOid = headOid
        self.commitCount = commitCount
        self.method = method
        self.note = note
        self.deletesBranch = deletesBranch
        self.previousError = previousError
        self.detail = detail
        self.detailError = detailError
        self.problem = problem
    }
}

// MARK: - Chat

/// Una tarjeta "Save as rule" de un mensaje del chat (spec E.3).
public struct RuleProposalInfo: Codable, Equatable, Sendable {
    /// Desde 1 entre las pendientes de la conversación (`prbar rules proposal save <pr> <n>`); `nil` si ya se guardó
    /// o se descartó.
    public var number: Int?
    public var id: UUID
    /// `global` o `owner/repo`.
    public var scope: String
    public var appliesTo: [RuleStage]
    public var text: String
    /// pending, saved o dismissed.
    public var status: String

    public init(number: Int?, id: UUID, scope: String, appliesTo: [RuleStage], text: String, status: String) {
        self.number = number
        self.id = id
        self.scope = scope
        self.appliesTo = appliesTo
        self.text = text
        self.status = status
    }
}

public struct ChatMessageInfo: Codable, Equatable, Sendable {
    public var id: UUID
    /// user, assistant o error.
    public var role: String
    public var text: String
    public var createdAt: Date
    /// "edited #2, added #4" (`nil` si no cambió nada).
    public var changes: String?
    public var undone: Bool
    public var notes: [String]
    /// Es el que ofrece "Undo".
    public var undoable: Bool
    public var proposals: [RuleProposalInfo]

    public init(id: UUID, role: String, text: String, createdAt: Date, changes: String?, undone: Bool, notes: [String],
                undoable: Bool, proposals: [RuleProposalInfo] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.changes = changes
        self.undone = undone
        self.notes = notes
        self.undoable = undoable
        self.proposals = proposals
    }
}

public struct ChatInfo: Codable, Equatable, Sendable {
    /// `owner/repo#N`; vacío en el chat de instrucciones.
    public var pr: String
    /// review, respond o instructions.
    public var kind: String
    public var readOnly: Bool
    public var running: Bool
    public var lockReason: String?
    public var messages: [ChatMessageInfo]
    /// La respuesta ya se mostró en streaming (`chat send`): la CLI no la repite.
    public var streamed: Bool

    public init(pr: String, kind: String, readOnly: Bool, running: Bool, lockReason: String?, messages: [ChatMessageInfo],
                streamed: Bool = false) {
        self.pr = pr
        self.kind = kind
        self.readOnly = readOnly
        self.running = running
        self.lockReason = lockReason
        self.messages = messages
        self.streamed = streamed
    }
}

// MARK: - Actualizaciones

public struct UpdateInfo: Codable, Equatable, Sendable {
    public var installed: String
    /// La versión nueva, si hay.
    public var latest: String?
    public var title: String?
    public var notes: String?
    public var url: URL?
    public var skipped: Bool
    /// PRs with Respond fixes that aren't pushed (the update restarts PRBar and forgets them); nil = none.
    public var unpushedFixes: Int?

    public init(installed: String, latest: String? = nil, title: String? = nil, notes: String? = nil, url: URL? = nil,
                skipped: Bool = false, unpushedFixes: Int? = nil) {
        self.installed = installed
        self.latest = latest
        self.title = title
        self.notes = notes
        self.url = url
        self.skipped = skipped
        self.unpushedFixes = unpushedFixes
    }

    public var isAvailable: Bool { latest != nil }
}

// MARK: - Instrucciones, opciones y prompts

public struct RuleInfo: Codable, Equatable, Sendable {
    public var id: String
    /// `global` o `owner/repo`.
    public var scope: String
    public var appliesTo: [RuleStage]
    public var text: String
    /// manual, settingsChat, prChat o suggestion.
    public var source: String
    public var enabled: Bool
    public var updatedAt: Date

    public init(id: String, scope: String, appliesTo: [RuleStage], text: String, source: String, enabled: Bool,
                updatedAt: Date) {
        self.id = id
        self.scope = scope
        self.appliesTo = appliesTo
        self.text = text
        self.source = source
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    public static func scopeName(_ scope: RuleScope) -> String {
        switch scope {
        case .global: "global"
        case .repo(let name): name
        }
    }
}

public struct RuleSuggestionInfo: Codable, Equatable, Sendable {
    public var id: String
    public var scope: String
    public var category: String
    /// "You usually discard style comments in acme/web-app."
    public var reason: String
    public var proposedText: String

    public init(id: String, scope: String, category: String, reason: String, proposedText: String) {
        self.id = id
        self.scope = scope
        self.category = category
        self.reason = reason
        self.proposedText = proposedText
    }
}

public struct PromptInfo: Codable, Equatable, Sendable {
    public var stage: PromptStage
    public var text: String
    public var isDefault: Bool
    /// Variables que tiene que usar (`{diff_path}`, …).
    public var requiredVariables: [String]

    public init(stage: PromptStage, text: String, isDefault: Bool, requiredVariables: [String]) {
        self.stage = stage
        self.text = text
        self.isDefault = isDefault
        self.requiredVariables = requiredVariables
    }
}

/// `prbar resources`.
public struct ResourcesInfo: Codable, Equatable, Sendable {
    public var usage: ResourceUsage
    public var disk: DiskUsage
    /// Claude's estimated usage this month (spec O.2); nil from an older app.
    public var claudeThisMonth: ClaudeUsage?

    public init(usage: ResourceUsage, disk: DiskUsage, claudeThisMonth: ClaudeUsage? = nil) {
        self.usage = usage
        self.disk = disk
        self.claudeThisMonth = claudeThisMonth
    }
}

// MARK: - Fix CI y uso de Claude (specs K y O)

/// Un PR mío con el CI fallido (`prbar ci list`).
public struct CIListEntry: Codable, Equatable, Sendable {
    public var pr: String
    public var title: String
    public var url: URL
    public var account: String
    /// La fase del Fix CI (`RespondPhase.cliName`), o nil si no hay ninguno.
    public var phase: String?
    /// Un Respond (no un Fix CI) ocupa el PR.
    public var respondInProgress: Bool
    /// Por qué no se puede arrancar ahora (sin carpeta local, una actualización en curso…).
    public var unavailableReason: String?
    /// Cuántos checks fallaron, si PRBar ya los leyó (un Fix CI); nil si todavía no se sabe.
    public var failedChecks: Int?

    public init(pr: String, title: String, url: URL, account: String, phase: String?, respondInProgress: Bool,
                unavailableReason: String?, failedChecks: Int? = nil) {
        self.pr = pr
        self.title = title
        self.url = url
        self.account = account
        self.phase = phase
        self.respondInProgress = respondInProgress
        self.unavailableReason = unavailableReason
        self.failedChecks = failedChecks
    }
}

/// `prbar usage` (spec O.3).
public struct UsageInfo: Codable, Equatable, Sendable {
    public var month: UsageMonth
    /// Las tareas recientes del mes, de la más nueva a la más vieja.
    public var tasks: [UsageTask]
    public var note: String

    public init(month: UsageMonth, tasks: [UsageTask], note: String = UsageFormat.note) {
        self.month = month
        self.tasks = tasks
        self.note = note
    }
}

// MARK: - Acceso desde el iPhone (spec Q)

/// `prbar remote status` y el encabezado de Settings › iPhone.
public struct RemoteStatusInfo: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var relayHost: String?
    /// `disabled`, `connecting`, `connected`, `offline` o `failed`.
    public var state: String
    /// "Offline — retrying in 30 s", el error de inscripción…
    public var detail: String?
    public var devices: Int
    public var devicesOnline: Int
    public var keepAwake: Bool
    /// La aserción que impide dormir está tomada ahora (en corriente).
    public var keepingAwake: Bool
    public var mailbox: Bool
    /// Los primeros 4 caracteres de la cuenta en el relay.
    public var accountPrefix: String?

    public init(enabled: Bool, relayHost: String?, state: String, detail: String? = nil, devices: Int, devicesOnline: Int,
                keepAwake: Bool, keepingAwake: Bool, mailbox: Bool, accountPrefix: String?) {
        self.enabled = enabled
        self.relayHost = relayHost
        self.state = state
        self.detail = detail
        self.devices = devices
        self.devicesOnline = devicesOnline
        self.keepAwake = keepAwake
        self.keepingAwake = keepingAwake
        self.mailbox = mailbox
        self.accountPrefix = accountPrefix
    }
}

/// Un iPhone emparejado (`prbar remote devices`).
public struct RemoteDeviceInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var model: String
    public var pairedAt: Date
    public var lastSeen: Date?
    public var online: Bool
    public var requirePresence: Bool
    /// `false` si el relay dijo que la suscripción de Web Push ya no sirve.
    public var notifications: Bool
    /// `false`: se emparejó sin passkey, así que lo que pide Face ID queda bloqueado (W.4.6). nil = una app vieja.
    public var faceIDSetUp: Bool?

    public init(id: String, name: String, model: String, pairedAt: Date, lastSeen: Date?, online: Bool,
                requirePresence: Bool, notifications: Bool) {
        self.id = id
        self.name = name
        self.model = model
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
        self.online = online
        self.requirePresence = requirePresence
        self.notifications = notifications
    }
}

/// Una ranura de emparejamiento (`prbar remote pair`): el QR y, cuando un teléfono se une, su código.
public struct RemotePairingInfo: Codable, Equatable, Sendable {
    public var pairing: String
    /// `https://<relay>/#pair?…` (secreto: vence a los 5 min y sirve una sola vez).
    public var qr: String
    public var expiresAt: Date
    /// "123 456" cuando un teléfono se unió.
    public var code: String?
    public var deviceName: String?
    public var model: String?

    public init(pairing: String, qr: String, expiresAt: Date, code: String? = nil, deviceName: String? = nil,
                model: String? = nil) {
        self.pairing = pairing
        self.qr = qr
        self.expiresAt = expiresAt
        self.code = code
        self.deviceName = deviceName
        self.model = model
    }
}

/// `remotePairConfirm`: el dispositivo nuevo, o nil si se canceló.
public struct RemotePairResult: Codable, Equatable, Sendable {
    public var device: RemoteDeviceInfo?

    public init(device: RemoteDeviceInfo?) {
        self.device = device
    }
}
