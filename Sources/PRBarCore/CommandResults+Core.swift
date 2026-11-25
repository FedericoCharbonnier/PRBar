import Foundation

// Conversiones de los modelos de Core a los resultados de los comandos (que viven en PRBarWire).

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

extension FindingInfo {
    /// `item` como lo da `ReviewEdits.items(of:)` (con el título editado).
    public init(number: Int, item: ReviewItem, edits: ReviewEdits) {
        self.init(number: number, id: item.id, severity: item.finding.severity, location: item.finding.location,
                  title: item.finding.title, body: edits.body(of: item), keptByFilter: item.keep,
                  filterReason: item.reason, included: edits.selected.contains(item.id), edited: edits.isEdited(item),
                  hiddenBy: item.hiddenBy)
    }
}

extension HistoryEntryInfo {
    public init(review record: ReviewRecord) {
        self.init(id: record.id, kind: .review, pr: record.draft.prID, repo: record.draft.repo.fullName,
                  number: record.draft.number, title: record.draft.title, status: record.status.rawValue,
                  startedAt: record.startedAt, finishedAt: record.finishedAt, usage: record.draft.totalUsage)
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
        let kind: HistoryKind = switch record.draft.mode {
        case .ciFix: .ciFix
        case .conflicts: .conflicts
        case .feedback: .respond
        }
        self.init(id: record.id, kind: kind, pr: record.draft.prID,
                  repo: record.draft.repo.fullName, number: record.draft.number, title: record.draft.title, status: status,
                  startedAt: record.startedAt, finishedAt: record.finishedAt, usage: record.totalUsage)
    }

    /// Un merge desde PRBar (spec G.4): `merged`, `failed` u `open` (no se mergeó).
    public init(merge record: MergeRecord) {
        self.init(id: record.id, kind: .merge, pr: record.prID, repo: record.repo.fullName, number: record.number,
                  title: record.title, status: record.status.rawValue, startedAt: record.startedAt,
                  finishedAt: record.finishedAt, usage: record.chat?.usage)
    }
}

extension HistoryDetail {
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

extension SkillInfo {
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

extension MergeInfo {
    public init(completion: MergeCompletion) {
        self.init(pr: completion.item.id, method: completion.method, mergedAt: completion.mergedAt, url: completion.item.pr.url)
    }
}

extension RuleProposalInfo {
    public init(number: Int?, proposal: RuleProposal) {
        self.init(number: number, id: proposal.id, scope: RuleInfo.scopeName(proposal.scope),
                  appliesTo: proposal.appliesTo.sorted(), text: proposal.text, status: proposal.status.rawValue)
    }
}

extension UpdateInfo {
    public init(installed: String, release: ReleaseInfo, skipped: Bool = false) {
        self.init(installed: installed, latest: release.version.description, title: release.title, notes: release.notes,
                  url: release.url, skipped: skipped)
    }
}

extension RuleInfo {
    public init(rule: Rule) {
        self.init(id: rule.id.uuidString, scope: Self.scopeName(rule.scope), appliesTo: rule.appliesTo.sorted(),
                  text: rule.text, source: rule.source.rawValue, enabled: rule.enabled, updatedAt: rule.updatedAt)
    }
}

extension RuleSuggestionInfo {
    public init(suggestion: RuleSuggestion) {
        self.init(id: suggestion.id, scope: RuleInfo.scopeName(suggestion.scope), category: suggestion.category.rawValue,
                  reason: suggestion.message, proposedText: suggestion.text)
    }
}

// MARK: - Conversiones que antes asignaban campo por campo (ahora delegan en el init memberwise de PRBarWire)

extension PRInfo {
    public init(item: ClassifiedPR, review: ReviewPhase?, respond: RespondPhase?, merge: MergePhase? = nil) {
        let pr = item.pr
        self.init(id: item.id, repo: pr.repo.fullName, number: pr.number, title: pr.title, url: pr.url, author: pr.author,
                  account: item.account, category: item.category.rawValue, baseRef: pr.baseRef, headRef: pr.headRef,
                  isDraft: pr.isDraft, ci: pr.ciState.rawValue, additions: pr.additions, deletions: pr.deletions,
                  updatedAt: pr.updatedAt, review: review?.cliName, respond: respond?.cliName, merge: merge?.cliName,
                  mergeError: merge?.message, tab: PopoverTabs.tab(of: item), section: PopoverTabs.section(of: item),
                  authorName: pr.authorName, approvals: pr.approvalCount > 0 ? pr.approvalCount : nil,
                  changedFiles: pr.changedFiles)
    }
}

extension PullRequest {
    /// Revisores (personas, no el autor) cuyo último review que cuenta es un approve. Un comentario después de aprobar
    /// no lo deshace (como en GitHub); un "changes requested" o un dismiss sí.
    public var approvalCount: Int {
        var latest: [String: PRReview] = [:]
        for review in reviews where !review.isBot && review.author != author
            && [.approved, .changesRequested, .dismissed].contains(review.state) {
            if let seen = latest[review.author], seen.submittedAt > review.submittedAt { continue }
            latest[review.author] = review
        }
        return latest.values.filter { $0.state == .approved }.count
    }
}

extension ReviewInfo {
    public init(prID: String, phase: ReviewPhase?, edits: ReviewEdits? = nil, outdated: Bool = false) {
        self.init(pr: prID, phase: phase?.cliName ?? "none", detail: phase?.cliDetail, outdated: outdated, findings: [])
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
            usage = draft.totalUsage
        default:
            break
        }
    }
}

extension RespondItemInfo {
    public init(number: Int, item: RespondItem, selection: RespondSelection, posted: URL?) {
        self.init(number: number, id: item.id, reviewer: item.feedback.reviewer, location: item.feedback.cliLocation,
                  outdated: item.feedback.isOutdated, thread: item.feedback.comments.map { "\($0.author): \($0.body)" },
                  commentURL: item.feedback.comments.last?.url, assessment: item.assessment, suggested: item.action.rawValue,
                  implement: selection.implement, fixPlan: selection.fixPlan, reply: selection.reply,
                  replyText: selection.replyText, postedURL: posted)
    }
}

extension RespondInfo {
    public init(prID: String, phase: RespondPhase?, record: RespondRecord?, selections: [String: RespondSelection],
                runningTests: Bool, testCommand: String?, logPath: String? = nil, pushBlockedByTests: Bool = false) {
        self.init(pr: prID, phase: phase?.cliName ?? "none", detail: phase?.cliDetail, runningTests: runningTests,
                  items: [], fixes: 0, replies: 0, commits: [], sensitiveChanges: [], pushed: false, pendingReplies: 0,
                  testCommand: testCommand, logPath: logPath, pushBlockedByTests: pushBlockedByTests)
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
            conflictSummaries = result.items.first?.conflictFiles
            outsideConflicts = result.outsideConflicts
        }
        pushed = record.pushed
        pendingReplies = RespondCounts.pendingReplies(record)
        errorMessage = record.errorMessage
        mode = draft.mode
        ciChecks = draft.ci?.checks
        totalChecks = draft.ci?.totalChecks
        // Sin el registro del merge automático: puede ser grande y solo lo usa la Mac (decisión C.9.16).
        conflicts = draft.conflicts.map { context in
            var context = context
            context.automaticMerge = nil
            return context
        }
        usage = record.totalUsage
        startedAt = record.startedAt
        testSummary = tests.flatMap { TestSummary.extract(from: $0.outputTail) }
    }
}

extension RepoInfo {
    public init(config: RepoConfig, account: String) {
        self.init(id: config.id, account: account, localPath: config.localPath, worktreeDir: config.worktreeDir,
                  testCommand: config.testCommand, baseBranches: config.baseBranches, watchedUsers: config.watchedUsers,
                  slackChannel: config.slackChannelName ?? config.slackChannelID, ignorePaths: config.ignorePaths,
                  mergeMethod: config.mergeMethod, runOn: config.runOn?.cliValue)
    }
}

extension RunnerInfo {
    public init(destination: RunnerDestination, isDefault: Bool, lastCheck: RunnerHostInfo?) {
        self.init(name: destination.name, host: destination.endpoint.display, dir: destination.remoteDir,
                  fallback: destination.fallbackToLocal, isDefault: isDefault, lastCheck: lastCheck)
    }
}

extension NotificationsInfo {
    public init(settings: NotificationSettings, deniedInMacOS: Bool) {
        self.init(enabled: settings.enabled,
                  kinds: Dictionary(uniqueKeysWithValues: NotificationSettingName.allCases.map {
                      ($0.rawValue, settings[keyPath: $0.keyPath])
                  }),
                  deniedInMacOS: deniedInMacOS)
    }
}

extension SlackInfo {
    public init(settings: SlackSettings, connected: Bool, hasToken: Bool, needsUserToken: Bool, issues: [String]) {
        self.init(enabled: settings.enabled, provider: settings.provider, connected: connected, hasToken: hasToken,
                  needsUserToken: needsUserToken,
                  toggles: Dictionary(uniqueKeysWithValues: SlackToggleName.allCases.map {
                      ($0.rawValue, settings[keyPath: $0.toggle.keyPath])
                  }),
                  emojis: Dictionary(uniqueKeysWithValues: SlackEmojiKind.allCases.map { ($0.rawValue, settings[keyPath: $0.keyPath]) }),
                  searchDays: settings.effectiveSearchDays, issues: issues)
    }
}

extension SelfTestStepInfo {
    public init(step: SlackSelfTestStep) {
        let status = switch step.status {
        case .ok: "ok"
        case .failed: "failed"
        case .skipped: "skipped"
        }
        self.init(title: step.title, status: status, detail: step.detail)
    }
}

extension TemplateInfo {
    public init(name: SlackTemplateName, settings: SlackSettings) {
        let text = settings[keyPath: name.kind.keyPath]
        self.init(name: name.rawValue, text: text, isDefault: name.kind.isDefault(text), defaultText: name.kind.defaultTemplate,
                  variables: name.kind.variables.map(\.token))
    }
}

extension ChannelInfo {
    public init(channel: SlackChannel) {
        self.init(id: channel.id, name: channel.name, isPrivate: channel.isPrivate, isMember: channel.isMember)
    }
}

extension MergePreviewInfo {
    public init(item: ClassifiedPR, method: MergeMethod, options: MergeOptions, deletesBranch: Bool, phase: MergePhase?,
                detail: MergeDetail? = nil, detailError: String? = nil, problem: String? = nil) {
        let pr = item.pr
        self.init(pr: item.id, title: pr.title, url: pr.url, baseRef: pr.baseRef, headRef: pr.headRef, headOid: pr.headOid,
                  commitCount: pr.merge.commitCount, method: method, note: options.availability.note,
                  deletesBranch: deletesBranch, previousError: phase?.message, detail: detail, detailError: detailError,
                  problem: problem)
    }
}
