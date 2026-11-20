import Foundation
import PRBarCore

/// `AppModel` de mentira: anota qué método se llamó (con los argumentos que importan) y devuelve algo mínimo.
@MainActor
final class FakeActions: StatusActions, ReviewActions, RespondActions, MergeActions, ConfigActions, SlackActions,
    ChatCommandActions, UpdateCommandActions, InstructionCommandActions {
    var calls: [String] = []
    /// Si no es nil, los métodos que pueden fallar la lanzan.
    var failure: Error?
    /// Eventos que mandan los comandos con `wait`.
    var waitEvents: [CommandEvent] = []
    /// Lo que devuelven `reviewShow` y `respondShow` (las preguntas de publicar, pushear y responder lo miran antes).
    var reviewPhase: ReviewPhase?
    var respondPhase: RespondPhase?
    /// Si no es nil, merge, publicar el review y las llamadas a Slack tardan esto (cancelable, como `URLSession`).
    var networkDelay: Duration?

    private func network() async throws {
        if let networkDelay { try await Task.sleep(for: networkDelay) }
    }

    private let link = PRLink(pr: "acme/api#1", url: URL(string: "https://github.com/acme/api/pull/1")!)

    private func record(_ call: String) throws {
        calls.append(call)
        if let failure { throw failure }
    }

    private func emit(_ events: CommandEventSink) { waitEvents.forEach(events) }

    // MARK: StatusActions
    func status() async throws -> StatusInfo { try record("status"); return StatusInfo(appVersion: "test") }
    func listPRs(list: PRListFilter?, account: String?) throws -> [PRInfo] {
        try record("listPRs \(list?.rawValue ?? "-") \(account ?? "-")"); return []
    }
    func resolvePR(_ pr: String) throws -> PRLink { try record("resolvePR \(pr)"); return link }
    func historyList(repo: String?, kind: HistoryKind?, limit: Int?, search: String?) -> [HistoryEntryInfo] {
        calls.append("historyList"); return []
    }
    func historyShow(id: String) throws -> HistoryDetail {
        try record("historyShow \(id)")
        return HistoryDetail(entry: HistoryEntryInfo(id: UUID(), kind: .review, pr: "acme/api#1", repo: "acme/api", number: 1,
                                                     title: "T", status: "ready", startedAt: t0), prURL: link.url)
    }
    func historyReopen(id: String) throws { try record("historyReopen \(id)") }
    func refresh() async { calls.append("refresh") }
    func open(pr: String, target: OpenTarget) throws -> PRLink { try record("open \(pr) \(target.rawValue)"); return link }
    func openSettings(tab: SettingsTabName?) { calls.append("openSettings \(tab?.rawValue ?? "-")") }
    func openHistory(id: String?) throws { try record("openHistory \(id ?? "-")") }
    func quit() { calls.append("quit") }

    // MARK: ReviewActions
    func reviewStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> ReviewInfo {
        try record("reviewStart \(pr) wait=\(wait)"); if wait { emit(events) }; return ReviewInfo(prID: pr, phase: nil)
    }
    func reviewShow(pr: String) throws -> ReviewInfo { try record("reviewShow \(pr)"); return ReviewInfo(prID: pr, phase: reviewPhase) }
    func reviewEdit(pr: String, finding: String, title: String?, body: String?) throws -> ReviewInfo {
        try record("reviewEdit \(pr) \(finding) title=\(title ?? "-") body=\(body ?? "-")"); return ReviewInfo(prID: pr, phase: nil)
    }
    func reviewSetIncluded(pr: String, findings: [String], all: Bool, included: Bool) throws -> ReviewInfo {
        try record("reviewSetIncluded \(pr) \(findings) all=\(all) included=\(included)"); return ReviewInfo(prID: pr, phase: nil)
    }
    func reviewSetComment(pr: String, text: String) throws -> ReviewInfo {
        try record("reviewSetComment \(pr) \(text)"); return ReviewInfo(prID: pr, phase: nil)
    }
    func reviewPublish(pr: String, event: ReviewEvent, only: [String]?, withComments: Bool, allInBody: Bool) async throws -> PublishedReviewInfo {
        try await network()
        try record("reviewPublish \(pr) \(event.rawValue) only=\(only ?? []) comments=\(withComments) body=\(allInBody)")
        return PublishedReviewInfo(pr: pr, url: link.url, action: "approve", comments: 0, publishedAt: t0)
    }
    func reviewCancel(pr: String) throws { try record("reviewCancel \(pr)") }
    func reviewDismiss(pr: String) throws { try record("reviewDismiss \(pr)") }

    // MARK: RespondActions
    private func respondInfo(_ pr: String) -> RespondInfo {
        RespondInfo(prID: pr, phase: respondPhase, record: nil, selections: [:], runningTests: false, testCommand: nil)
    }
    func respondStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        try record("respondStart \(pr) wait=\(wait)"); if wait { emit(events) }; return respondInfo(pr)
    }
    func respondShow(pr: String) throws -> RespondInfo { try record("respondShow \(pr)"); return respondInfo(pr) }
    func respondSelect(pr: String, items: [String], change: RespondSelectionChange) throws -> RespondInfo {
        try record("respondSelect \(pr) \(items) implement=\(change.implement.map(String.init) ?? "-") reply=\(change.reply.map(String.init) ?? "-") text=\(change.replyText ?? "-") plan=\(change.fixPlan ?? "-")")
        return respondInfo(pr)
    }
    func respondReset(pr: String) throws -> RespondInfo { try record("respondReset \(pr)"); return respondInfo(pr) }
    func respondImplement(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        try record("respondImplement \(pr) wait=\(wait)"); return respondInfo(pr)
    }
    func respondTest(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        try record("respondTest \(pr) wait=\(wait)"); return respondInfo(pr)
    }
    func respondDiff(pr: String) throws -> RespondDiff {
        try record("respondDiff \(pr)"); return RespondDiff(pr: pr, diffStat: "", diff: nil, truncated: false, sensitiveChanges: [])
    }
    func respondPush(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        try record("respondPush \(pr) wait=\(wait)"); return respondInfo(pr)
    }
    func respondPushAnyway(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        try record("respondPushAnyway \(pr) wait=\(wait)"); return respondInfo(pr)
    }
    func respondReplyOnly(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        try record("respondReplyOnly \(pr) wait=\(wait)"); return respondInfo(pr)
    }
    func respondCancel(pr: String) throws { try record("respondCancel \(pr)") }
    func respondDismiss(pr: String) throws { try record("respondDismiss \(pr)") }

    // MARK: MergeActions
    func merge(pr: String, method: MergeMethod?, expectedHeadOid: String) async throws -> MergeInfo {
        try await network()
        try record("merge \(pr) \(method?.rawValue ?? "default") head=\(expectedHeadOid)")
        return MergeInfo(pr: pr, method: method ?? .squash, mergedAt: t0, url: link.url)
    }
    func mergeDismiss(pr: String) throws { try record("mergeDismiss \(pr)") }
    func mergePreview(pr: String, method: MergeMethod?) throws -> MergePreviewInfo {
        try record("mergePreview \(pr) \(method?.rawValue ?? "default")")
        let state = PRMergeState(nodeID: "PR_1", mergeable: .mergeable, status: .unstable, commitCount: 3)
        let item = ClassifiedPR(pr: makePR(repo: RepoRef(owner: "acme", name: "api"), number: 1, author: "me",
                                           head: "c0ffee1234", merge: state), category: .readyToMerge, account: "me")
        let options = MergeOptions(availability: .enabled(note: "Some checks are failing"), methods: [.squash, .merge],
                                   defaultMethod: .squash)
        return MergePreviewInfo(item: item, method: method ?? .squash, options: options, deletesBranch: true, phase: nil)
    }

    // MARK: ConfigActions
    private let repoInfo = RepoInfo(config: RepoConfig(owner: "acme", name: "api"), account: "me")
    func configShow() -> AppConfig { calls.append("configShow"); return AppConfig() }
    func configSetRefreshInterval(minutes: Int) throws { try record("configSetRefreshInterval \(minutes)") }
    func configSetLaunchAtLogin(enabled: Bool) throws { try record("configSetLaunchAtLogin \(enabled)") }
    func configSetConfirmMerge(enabled: Bool) throws { try record("configSetConfirmMerge \(enabled)") }
    func accountList() -> [AccountInfo] { calls.append("accountList"); return [] }
    func accountSetEnabled(login: String, enabled: Bool) throws { try record("accountSetEnabled \(login) \(enabled)") }
    func accountReload() async throws -> [AccountInfo] { try record("accountReload"); return [] }
    func repoList(account: String?) throws -> [RepoInfo] { try record("repoList \(account ?? "-")"); return [] }
    func repoAvailable(account: String?, reload: Bool) async throws -> [String] { try record("repoAvailable reload=\(reload)"); return [] }
    func repoAdd(repo: String, account: String?) async throws -> RepoInfo { try record("repoAdd \(repo)"); return repoInfo }
    func repoRemove(repo: String, account: String?) throws { try record("repoRemove \(repo)") }
    func repoSet(repo: String, account: String?, changes: RepoChanges) async throws -> RepoInfo {
        try record("repoSet \(repo) path=\(changes.localPath?.value ?? "-") add=\(changes.addBranches)"); return repoInfo
    }
    func repoBranches(repo: String, account: String?, reload: Bool) async throws -> BranchesInfo {
        try record("repoBranches \(repo)"); return BranchesInfo(repo: repo, defaultBranch: "main", branches: [], selected: [])
    }
    func followList(repo: String?, account: String?) throws -> [FollowInfo] { try record("followList"); return [] }
    func followAdd(repo: String, users: [String], account: String?) async throws -> FollowInfo {
        try record("followAdd \(repo) \(users)"); return FollowInfo(repo: repo, account: "me", users: users)
    }
    func followRemove(repo: String, users: [String], account: String?) throws -> FollowInfo {
        try record("followRemove \(repo) \(users)"); return FollowInfo(repo: repo, account: "me", users: [])
    }
    func followSuggestions(repo: String, account: String?) async throws -> [UserSuggestionInfo] {
        try record("followSuggestions \(repo)"); return []
    }
    func notifyList() async -> NotificationsInfo {
        calls.append("notifyList"); return NotificationsInfo(settings: NotificationSettings(), deniedInMacOS: false)
    }
    func notifySet(kind: NotificationSettingName, enabled: Bool) throws { try record("notifySet \(kind.rawValue) \(enabled)") }
    func notifySetEnabled(enabled: Bool) throws { try record("notifySetEnabled \(enabled)") }
    func claudeShow() -> ClaudeSettings { calls.append("claudeShow"); return ClaudeSettings() }
    func claudeSet(changes: ClaudeChanges) throws -> ClaudeSettings {
        try record("claudeSet filter=\(changes.filterEnabled.map(String.init) ?? "-")"); return ClaudeSettings()
    }
    func claudeReset() throws -> ClaudeSettings { try record("claudeReset"); return ClaudeSettings() }
    func claudeSkillList() async -> [SkillInfo] { calls.append("claudeSkillList"); return [] }
    func toolsList() -> [ToolInfo] { calls.append("toolsList"); return [] }
    func toolsSet(tool: ToolName, path: String?) async throws -> [ToolInfo] {
        try record("toolsSet \(tool.rawValue) \(path ?? "auto")"); return []
    }

    // MARK: SlackActions
    private let check = SlackCheckInfo(user: "me", team: "Acme", provider: .userToken)
    func slackShow() -> SlackInfo {
        calls.append("slackShow")
        return SlackInfo(settings: SlackSettings(), connected: false, hasToken: false, needsUserToken: false, issues: [])
    }
    func slackSetEnabled(enabled: Bool) throws { try record("slackSetEnabled \(enabled)") }
    func slackSetProvider(provider: SlackProvider) throws { try record("slackSetProvider \(provider.rawValue)") }
    func slackTokenSet(token: String) async throws -> SlackCheckInfo { try await network(); try record("slackTokenSet \(token.count)"); return check }
    func slackTokenClear() throws { try record("slackTokenClear") }
    func slackSetToggle(toggle: SlackToggleName, enabled: Bool) throws { try record("slackSetToggle \(toggle.rawValue) \(enabled)") }
    func slackSetEmoji(kind: SlackEmojiKind, name: String) throws { try record("slackSetEmoji \(kind.rawValue) \(name)") }
    func slackSetSearchDays(days: Int) throws { try record("slackSetSearchDays \(days)") }
    func slackTemplateList() -> [TemplateInfo] { calls.append("slackTemplateList"); return [] }
    func slackTemplateSet(template: SlackTemplateName, text: String) throws { try record("slackTemplateSet \(template.rawValue)") }
    func slackTemplateReset(template: SlackTemplateName) throws { try record("slackTemplateReset \(template.rawValue)") }
    func slackCheck() async throws -> SlackCheckInfo { try record("slackCheck"); return check }
    func slackSelfTest() async throws -> [SelfTestStepInfo] { try await network(); try record("slackSelfTest"); return [] }
    func slackChannels(reload: Bool) async throws -> [ChannelInfo] { try record("slackChannels reload=\(reload)"); return [] }

    // MARK: ChatCommandActions
    private func chatInfo(_ pr: String, kind: String = "review") -> ChatInfo {
        ChatInfo(pr: pr, kind: kind, readOnly: false, running: false, lockReason: nil, messages: [])
    }
    func chatSend(pr: String, message: String, events: CommandEventSink) async throws -> ChatInfo {
        try record("chatSend \(pr) \(message)"); emit(events); return chatInfo(pr)
    }
    func chatShow(pr: String) throws -> ChatInfo { try record("chatShow \(pr)"); return chatInfo(pr) }
    func chatUndo(pr: String, confirmed: Bool) async throws -> ChatInfo { try record("chatUndo \(pr) \(confirmed)"); return chatInfo(pr) }
    func chatStop(pr: String) throws -> ChatInfo { try record("chatStop \(pr)"); return chatInfo(pr) }

    // MARK: UpdateCommandActions
    /// Lo que encuentra `updateCheck` (`nil` = al día).
    var updateLatest: String?
    func updateCheck() async throws -> UpdateInfo {
        try record("updateCheck"); return UpdateInfo(installed: "1.0.0", latest: updateLatest)
    }
    /// `updateInstall` manda `waitEvents` y se queda esperando (hasta que la conexión se corte), como la app que se
    /// reinicia.
    var updateInstallHangs = false
    func updateInstall(cancelJobs: Bool, events: @escaping CommandEventSink) async throws -> UpdateInfo {
        try record("updateInstall \(cancelJobs)")
        if updateInstallHangs {
            emit(events)
            try await Task.sleep(for: .seconds(30))
        }
        return UpdateInfo(installed: "1.0.0")
    }
    func updateCancel() throws { try record("updateCancel") }
    func updateSkip(version: String?) async throws -> UpdateInfo {
        try record("updateSkip \(version ?? "-")"); return UpdateInfo(installed: "1.0.0", skipped: true)
    }
    func configSetUpdateInterval(hours: Int) throws { try record("configSetUpdateInterval \(hours)") }

    // MARK: InstructionCommandActions
    private let rule = RuleInfo(id: "r1", scope: "global", appliesTo: [.review], text: "x", source: "manual", enabled: true,
                                updatedAt: t0)
    func rulesList(repo: String?) throws -> [RuleInfo] { try record("rulesList \(repo ?? "-")"); return [rule] }
    func rulesAdd(text: String, scope: RuleScope, appliesTo: [RuleStage]) throws -> RuleInfo {
        try record("rulesAdd \(RuleInfo.scopeName(scope)) \(appliesTo.map(\.rawValue)) \(text)"); return rule
    }
    func rulesEdit(id: String, text: String?, scope: RuleScope?, appliesTo: [RuleStage]?) throws -> RuleInfo {
        try record("rulesEdit \(id)"); return rule
    }
    func rulesRemove(id: String) throws { try record("rulesRemove \(id)") }
    func rulesSetEnabled(id: String, enabled: Bool) throws { try record("rulesSetEnabled \(id) \(enabled)") }
    func rulesChatSend(message: String, events: CommandEventSink) async throws -> ChatInfo {
        try record("rulesChatSend \(message)"); emit(events); return chatInfo("", kind: "instructions")
    }
    func rulesChatShow() -> ChatInfo { calls.append("rulesChatShow"); return chatInfo("", kind: "instructions") }
    func rulesChatUndo(confirmed: Bool) async throws -> ChatInfo {
        try record("rulesChatUndo \(confirmed)"); return chatInfo("", kind: "instructions")
    }
    func rulesChatStop() throws -> ChatInfo { try record("rulesChatStop"); return chatInfo("", kind: "instructions") }
    func rulesSuggestions() -> [RuleSuggestionInfo] { calls.append("rulesSuggestions"); return [] }
    func rulesSuggestionAct(id: String, action: SuggestionAction, text: String?) throws -> [RuleInfo] {
        try record("rulesSuggestionAct \(id) \(action.rawValue)"); return [rule]
    }
    func chatProposal(pr: String, number: Int, save: Bool, text: String?, scope: RuleScope?, appliesTo: [RuleStage]?) throws -> ChatInfo {
        try record("chatProposal \(pr) \(number) save=\(save)"); return chatInfo(pr)
    }
    func claudeReviewSet(changes: ReviewOptionChanges) throws -> ClaudeSettings { try record("claudeReviewSet"); return ClaudeSettings() }
    func claudeRespondSet(changes: RespondOptionChanges) throws -> ClaudeSettings { try record("claudeRespondSet"); return ClaudeSettings() }
    func claudeStageSet(stage: PromptStage, change: StageChange) throws -> ClaudeSettings {
        try record("claudeStageSet \(stage.rawValue)"); return ClaudeSettings()
    }
    func claudePromptShow(stage: PromptStage) -> PromptInfo {
        calls.append("claudePromptShow \(stage.rawValue)")
        return PromptInfo(stage: stage, text: "", isDefault: true, requiredVariables: [])
    }
    func claudePromptSet(stage: PromptStage, text: String) throws -> PromptInfo {
        try record("claudePromptSet \(stage.rawValue)"); return PromptInfo(stage: stage, text: text, isDefault: false, requiredVariables: [])
    }
    func claudePromptReset(stage: PromptStage) throws -> PromptInfo {
        try record("claudePromptReset \(stage.rawValue)"); return PromptInfo(stage: stage, text: "", isDefault: true, requiredVariables: [])
    }
}
