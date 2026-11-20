import Foundation

// Resultados de los comandos (`result` de la respuesta y `data` de `--json`, ver docs/cli.md). Las claves son
// estables: agregar campos opcionales está bien; renombrar o quitar sube `JSONOutput.schemaVersion`.

// MARK: - Fases

extension ReviewPhase {
    public var cliName: String {
        switch self {
        case .queued: "queued"
        case .preparing: "preparing"
        case .reviewing: "reviewing"
        case .filtering: "filtering"
        case .ready: "ready"
        case .failed: "failed"
        case .published: "published"
        }
    }

    public var cliDetail: String? {
        switch self {
        case .reviewing(let agents): agents == 1 ? "1 agent" : "\(agents) agents"
        case .failed(let message, _): message
        case .published(let url): url.absoluteString
        default: nil
        }
    }
}

extension RespondPhase {
    public var cliName: String {
        switch self {
        case .queued: "queued"
        case .preparing: "preparing"
        case .analyzing: "analyzing"
        case .ready: "ready"
        case .implementing: "implementing"
        case .readyToPush: "readyToPush"
        case .pushing: "pushing"
        case .done: "done"
        case .failed: "failed"
        }
    }

    public var cliDetail: String? {
        switch self {
        case .analyzing(let agents) where agents > 0: agents == 1 ? "1 agent" : "\(agents) agents"
        case .implementing(let done, let total): "\(done)/\(total)"
        case .failed(let message, _): message
        default: nil
        }
    }
}

extension MergePhase {
    public var cliName: String {
        switch self {
        case .merging: "merging"
        case .merged: "merged"
        case .failed: "failed"
        }
    }
}

extension FeedbackItem {
    /// `path:line`, `path` o "General comment" (como `RespondItemHeader`).
    public var cliLocation: String {
        guard let path else { return "General comment" }
        return line.map { "\(path):\($0)" } ?? path
    }
}

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

    public init(appVersion: String, refreshing: Bool = false, fetchedAt: Date? = nil, offline: Bool = false,
                rateLimitedUntil: Date? = nil, badgeCount: Int = 0, counts: [String: Int] = [:], issues: [String] = [],
                slackIssues: [String] = [], jobs: [JobInfo] = [], accounts: [String] = [], tools: [ToolInfo] = [],
                blockedReason: String? = nil, updateAvailable: String? = nil) {
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

    public init(item: ClassifiedPR, review: ReviewPhase?, respond: RespondPhase?, merge: MergePhase? = nil) {
        let pr = item.pr
        id = item.id
        repo = pr.repo.fullName
        number = pr.number
        title = pr.title
        url = pr.url
        author = pr.author
        account = item.account
        category = item.category.rawValue
        baseRef = pr.baseRef
        headRef = pr.headRef
        isDraft = pr.isDraft
        ci = pr.ciState.rawValue
        additions = pr.additions
        deletions = pr.deletions
        updatedAt = pr.updatedAt
        self.review = review?.cliName
        self.respond = respond?.cliName
        self.merge = merge?.cliName
        mergeError = merge?.message
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

    /// `item` como lo da `ReviewEdits.items(of:)` (con el título editado).
    public init(number: Int, item: ReviewItem, edits: ReviewEdits) {
        self.init(number: number, id: item.id, severity: item.finding.severity, location: item.finding.location,
                  title: item.finding.title, body: edits.body(of: item), keptByFilter: item.keep,
                  filterReason: item.reason, included: edits.selected.contains(item.id), edited: edits.isEdited(item),
                  hiddenBy: item.hiddenBy)
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

    public init(prID: String, phase: ReviewPhase?, edits: ReviewEdits? = nil, outdated: Bool = false) {
        pr = prID
        self.phase = phase?.cliName ?? "none"
        detail = phase?.cliDetail
        self.outdated = outdated
        findings = []
        switch phase {
        case .failed(_, let logURL)?:
            logPath = logURL?.path
        case .published(let url)?:
            reviewURL = url
        case .ready(let draft)?:
            let edits = edits ?? ReviewEdits.initial(for: draft)
            title = draft.title
            summary = draft.summary
            language = draft.language.displayName
            account = draft.account
            // #N = posición en `draft.items + edits.added` (plan 6), la misma de la ventana y del chat.
            findings = edits.items(of: draft).enumerated().map { FindingInfo(number: $0.offset + 1, item: $0.element, edits: edits) }
            generalComment = edits.generalComment.isEmpty ? nil : edits.generalComment
        default:
            break
        }
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

    public init(number: Int, item: RespondItem, selection: RespondSelection, posted: URL?) {
        self.number = number
        id = item.id
        reviewer = item.feedback.reviewer
        location = item.feedback.cliLocation
        outdated = item.feedback.isOutdated
        thread = item.feedback.comments.map { "\($0.author): \($0.body)" }
        commentURL = item.feedback.comments.last?.url
        assessment = item.assessment
        suggested = item.action.rawValue
        implement = selection.implement
        fixPlan = selection.fixPlan
        reply = selection.reply
        replyText = selection.replyText
        postedURL = posted
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

    public init(prID: String, phase: RespondPhase?, record: RespondRecord?, selections: [String: RespondSelection],
                runningTests: Bool, testCommand: String?, logPath: String? = nil, pushBlockedByTests: Bool = false) {
        pr = prID
        self.pushBlockedByTests = pushBlockedByTests
        self.phase = phase?.cliName ?? "none"
        detail = phase?.cliDetail
        self.runningTests = runningTests
        self.testCommand = testCommand
        self.logPath = logPath
        items = []
        fixes = 0
        replies = 0
        commits = []
        sensitiveChanges = []
        pushed = false
        pendingReplies = 0
        guard let record else { return }
        let draft = record.draft
        title = draft.title
        account = draft.account
        headRef = draft.headRef
        worktree = draft.worktree.path
        language = draft.language.displayName
        items = draft.items.enumerated().map { index, item in
            RespondItemInfo(number: index + 1, item: item,
                            selection: selections[item.id] ?? RespondSelection.defaults(for: item),
                            posted: record.posted[item.id]?.url)
        }
        fixes = RespondCounts.fixes(draft, selections)
        replies = RespondCounts.plannedReplies(draft, selections)
        if let result = record.result {
            commits = result.items.map { CommitDTO(item: $0.id, status: $0.status.rawValue, sha: $0.commit, summary: $0.summary) }
            diffStat = result.diffStat
            sensitiveChanges = result.sensitiveChanges
            tests = result.tests.map { TestInfo(command: $0.command, passed: $0.passed, outputTail: $0.outputTail) }
        }
        pushed = record.pushed
        pendingReplies = RespondCounts.pendingReplies(record)
        errorMessage = record.errorMessage
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

    public init(id: UUID, kind: HistoryKind, pr: String, repo: String, number: Int, title: String, status: String,
                startedAt: Date, finishedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.pr = pr
        self.repo = repo
        self.number = number
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public init(review record: ReviewRecord) {
        self.init(id: record.id, kind: .review, pr: record.draft.prID, repo: record.draft.repo.fullName,
                  number: record.draft.number, title: record.draft.title, status: record.status.rawValue,
                  startedAt: record.startedAt, finishedAt: record.finishedAt)
    }

    public init(respond record: RespondRecord) {
        let status = if record.errorMessage != nil {
            "failed"
        } else if record.pushed || !record.posted.isEmpty {
            "done"
        } else if record.result != nil {
            "readyToPush"
        } else {
            "ready"
        }
        self.init(id: record.id, kind: .respond, pr: record.draft.prID, repo: record.draft.repo.fullName,
                  number: record.draft.number, title: record.draft.title, status: status,
                  startedAt: record.startedAt, finishedAt: record.finishedAt)
    }

    /// Un merge desde PRBar (spec G.4): `merged`, `failed` u `open` (no se mergeó).
    public init(merge record: MergeRecord) {
        self.init(id: record.id, kind: .merge, pr: record.prID, repo: record.repo.fullName, number: record.number,
                  title: record.title, status: record.status.rawValue, startedAt: record.startedAt,
                  finishedAt: record.finishedAt)
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

    public init(review record: ReviewRecord, logPath: String?, canReopen: Bool) {
        let edits = record.draft.edits ?? ReviewEdits.initial(for: record.draft)
        let findings = edits.items(of: record.draft).enumerated().map { index, item -> FindingInfo in
            let finding = item.finding
            let published = record.published[item.id]
            return FindingInfo(number: index + 1, id: item.id, severity: finding.severity, location: finding.location,
                               title: finding.title, body: published ?? edits.body(of: item), keptByFilter: item.keep,
                               filterReason: item.reason, included: published != nil, edited: edits.isEdited(item),
                               hiddenBy: item.hiddenBy)
        }
        self.init(entry: HistoryEntryInfo(review: record), prURL: record.draft.url, summary: record.draft.summary,
                  errorMessage: record.errorMessage, findings: findings, generalComment: record.generalComment,
                  action: record.status == .published ? record.action.rawValue : nil, reviewURL: record.reviewURL,
                  logPath: logPath, canReopen: canReopen,
                  chat: record.draft.chat.flatMap { session in
                      session.messages.isEmpty ? nil
                          : ChatInfo(pr: record.draft.prID, session: session) { edits.number(of: $0, in: record.draft) }
                  })
    }

    public init(merge record: MergeRecord, logPath: String?) {
        self.init(entry: HistoryEntryInfo(merge: record), prURL: record.url, errorMessage: record.errorMessage, logPath: logPath,
                  chat: record.chat.flatMap { session in
                      session.messages.isEmpty ? nil : ChatInfo(pr: record.prID, session: session) { _ in nil }
                  },
                  mergeMethod: record.method, headOid: record.headOid)
    }

    public init(respond record: RespondRecord, logPath: String?, canOpen: Bool) {
        let replies = record.draft.items.compactMap { item in
            record.posted[item.id].map { PostedReplyInfo(item: item.id, location: item.feedback.cliLocation, url: $0.url) }
        }
        let draft = record.draft
        self.init(entry: HistoryEntryInfo(respond: record), prURL: draft.url, errorMessage: record.errorMessage,
                  replies: replies, pushed: record.pushed, logPath: logPath, canOpen: canOpen,
                  chat: record.chat.flatMap { session in
                      session.messages.isEmpty ? nil
                          : ChatInfo(pr: draft.prID, session: session) { id in draft.items.firstIndex { $0.id == id }.map { $0 + 1 } }
                  })
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

    public init(config: RepoConfig, account: String) {
        id = config.id
        self.account = account
        localPath = config.localPath
        worktreeDir = config.worktreeDir
        testCommand = config.testCommand
        baseBranches = config.baseBranches
        watchedUsers = config.watchedUsers
        slackChannel = config.slackChannelName ?? config.slackChannelID
        ignorePaths = config.ignorePaths
        mergeMethod = config.mergeMethod
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

    public init(settings: NotificationSettings, deniedInMacOS: Bool) {
        enabled = settings.enabled
        kinds = Dictionary(uniqueKeysWithValues: NotificationSettingName.allCases.map { ($0.rawValue, settings[keyPath: $0.keyPath]) })
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

    public init(entry: ClaudeSkillEntry) {
        let source = switch entry.source {
        case .plugin(let name, _): "plugin:\(name)"
        case .user: "user"
        }
        let reason: String? = switch entry.availability {
        case .available: nil
        case .checking: "Checking whether it loads in isolated runs…"
        case .unavailable(let reason): reason
        }
        self.init(id: entry.id, source: source, description: entry.description, available: entry.isAvailable, reason: reason)
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

    public init(settings: SlackSettings, connected: Bool, hasToken: Bool, needsUserToken: Bool, issues: [String]) {
        enabled = settings.enabled
        provider = settings.provider
        self.connected = connected
        self.hasToken = hasToken
        self.needsUserToken = needsUserToken
        toggles = Dictionary(uniqueKeysWithValues: SlackToggleName.allCases.map { ($0.rawValue, settings[keyPath: $0.toggle.keyPath]) })
        emojis = Dictionary(uniqueKeysWithValues: SlackEmojiKind.allCases.map { ($0.rawValue, settings[keyPath: $0.keyPath]) })
        searchDays = settings.effectiveSearchDays
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

    public init(step: SlackSelfTestStep) {
        title = step.title
        status = switch step.status {
        case .ok: "ok"
        case .failed: "failed"
        case .skipped: "skipped"
        }
        detail = step.detail
    }
}

public struct TemplateInfo: Codable, Equatable, Sendable {
    public var name: String
    public var text: String
    public var isDefault: Bool
    public var defaultText: String
    public var variables: [String]

    public init(name: SlackTemplateName, settings: SlackSettings) {
        self.name = name.rawValue
        text = settings[keyPath: name.kind.keyPath]
        isDefault = name.kind.isDefault(text)
        defaultText = name.kind.defaultTemplate
        variables = name.kind.variables.map(\.token)
    }
}

public struct ChannelInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isPrivate: Bool
    public var isMember: Bool

    public init(channel: SlackChannel) {
        id = channel.id
        name = channel.name
        isPrivate = channel.isPrivate
        isMember = channel.isMember
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

    public init(completion: MergeCompletion) {
        self.init(pr: completion.item.id, method: completion.method, mergedAt: completion.mergedAt, url: completion.item.pr.url)
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

    public init(item: ClassifiedPR, method: MergeMethod, options: MergeOptions, deletesBranch: Bool, phase: MergePhase?,
                detail: MergeDetail? = nil, detailError: String? = nil) {
        let pr = item.pr
        self.pr = item.id
        title = pr.title
        url = pr.url
        baseRef = pr.baseRef
        headRef = pr.headRef
        headOid = pr.headOid
        commitCount = pr.merge.commitCount
        self.method = method
        note = options.availability.note
        self.deletesBranch = deletesBranch
        previousError = phase?.message
        self.detail = detail
        self.detailError = detailError
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

    public init(number: Int?, proposal: RuleProposal) {
        self.init(number: number, id: proposal.id, scope: RuleInfo.scopeName(proposal.scope),
                  appliesTo: proposal.appliesTo.sorted(), text: proposal.text, status: proposal.status.rawValue)
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

extension ChatInfo {
    /// La conversación como la muestra el panel del chat: `number` da el `#N` de un hallazgo o comentario (para
    /// "edited #2"); las tarjetas "Save as rule" pendientes se numeran desde 1 en orden.
    public init(pr: String, kind: String, messages: [ChatMessage], undoableMessageID: UUID?, canUndo: Bool, readOnly: Bool,
                running: Bool, lockReason: String?, streamed: Bool = false, number: (String) -> Int?) {
        var pending = 0
        let infos = messages.map { message -> ChatMessageInfo in
            let proposals = message.proposals.map { proposal -> RuleProposalInfo in
                guard proposal.status == .pending else { return RuleProposalInfo(number: nil, proposal: proposal) }
                pending += 1
                return RuleProposalInfo(number: pending, proposal: proposal)
            }
            return ChatMessageInfo(id: message.id, role: message.role.rawValue, text: message.text, createdAt: message.createdAt,
                                   changes: message.changes.isEmpty ? nil : ChatActions.summary(message.changes, number: number),
                                   undone: message.undone, notes: message.notes,
                                   undoable: canUndo && message.id == undoableMessageID, proposals: proposals)
        }
        self.init(pr: pr, kind: kind, readOnly: readOnly, running: running, lockReason: lockReason, messages: infos,
                  streamed: streamed)
    }

    /// Una conversación guardada (historial): solo lectura.
    public init(pr: String, session: ChatSession, number: (String) -> Int?) {
        self.init(pr: pr, kind: session.kind.rawValue, messages: session.messages, undoableMessageID: nil, canUndo: false,
                  readOnly: true, running: false, lockReason: nil, number: number)
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

    public init(installed: String, latest: String? = nil, title: String? = nil, notes: String? = nil, url: URL? = nil,
                skipped: Bool = false) {
        self.installed = installed
        self.latest = latest
        self.title = title
        self.notes = notes
        self.url = url
        self.skipped = skipped
    }

    public init(installed: String, release: ReleaseInfo, skipped: Bool = false) {
        self.init(installed: installed, latest: release.version.description, title: release.title, notes: release.notes,
                  url: release.url, skipped: skipped)
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

    public init(id: String, scope: String, appliesTo: [RuleStage], text: String, source: String, enabled: Bool, updatedAt: Date) {
        self.id = id
        self.scope = scope
        self.appliesTo = appliesTo
        self.text = text
        self.source = source
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    public init(rule: Rule) {
        self.init(id: rule.id.uuidString, scope: Self.scopeName(rule.scope), appliesTo: rule.appliesTo.sorted(),
                  text: rule.text, source: rule.source.rawValue, enabled: rule.enabled, updatedAt: rule.updatedAt)
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

    public init(suggestion: RuleSuggestion) {
        self.init(id: suggestion.id, scope: RuleInfo.scopeName(suggestion.scope), category: suggestion.category.rawValue,
                  reason: suggestion.message, proposedText: suggestion.text)
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
