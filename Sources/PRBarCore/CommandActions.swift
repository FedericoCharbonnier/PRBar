import Foundation

// Lo que la app sabe hacer, agrupado como sus pantallas. `AppModel` implementa los protocolos de `PRBarActions`
// (Tasks 11–12) llamando a los mismos métodos que usa la UI; `CommandDispatcher` traduce cada `AppCommand` a uno de
// estos métodos. Los métodos lanzan `CommandFailure` con el texto de la UI y el comando sugerido (spec C.6).
//
// El chat (`ChatCommandActions`), las actualizaciones (`UpdateCommandActions`) y las instrucciones/opciones/prompts
// (`InstructionCommandActions`) también los implementa `AppModel` (AppModel+Chat, +UpdateCommands, +InstructionCommands).

@MainActor
public protocol StatusActions: AnyObject {
    func status() async throws -> StatusInfo
    func listPRs(list: PRListFilter?, account: String?, tab: PopoverTab?) throws -> [PRInfo]
    func resolvePR(_ pr: String) throws -> PRLink
    func historyList(repo: String?, kind: HistoryKind?, limit: Int?, search: String?) -> [HistoryEntryInfo]
    func historyShow(id: String) throws -> HistoryDetail
    func historyReopen(id: String) throws
    func refresh() async
    func open(pr: String, target: OpenTarget) throws -> PRLink
    func openSettings(tab: SettingsTabName?)
    func openHistory(id: String?) throws
    func quit()
    /// Async: responde si el popover quedó realmente en pantalla después del clic.
    func openPopover(tab: PopoverTab?) async -> PopoverInfo
}

@MainActor
public protocol ReviewActions: AnyObject {
    func reviewStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> ReviewInfo
    func reviewShow(pr: String) throws -> ReviewInfo
    func reviewEdit(pr: String, finding: String, title: String?, body: String?) throws -> ReviewInfo
    func reviewSetIncluded(pr: String, findings: [String], all: Bool, included: Bool) throws -> ReviewInfo
    func reviewSetComment(pr: String, text: String) throws -> ReviewInfo
    func reviewPublish(pr: String, event: ReviewEvent, only: [String]?, withComments: Bool, allInBody: Bool) async throws -> PublishedReviewInfo
    func reviewCancel(pr: String) throws
    func reviewDismiss(pr: String) throws
}

@MainActor
public protocol RespondActions: AnyObject {
    func respondStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo
    func respondShow(pr: String) throws -> RespondInfo
    func respondSelect(pr: String, items: [String], change: RespondSelectionChange) throws -> RespondInfo
    func respondReset(pr: String) throws -> RespondInfo
    func respondImplement(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo
    func respondTest(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo
    func respondDiff(pr: String) throws -> RespondDiff
    func respondPush(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo
    /// "Push Anyway": solo si el último push quedó frenado porque fallaron los tests de antes del push.
    func respondPushAnyway(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo
    func respondReplyOnly(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo
    func respondCancel(pr: String) throws
    func respondDismiss(pr: String) throws
}

/// Ready to Merge (spec F).
@MainActor
public protocol MergeActions: AnyObject {
    /// Mergea sin diálogo (la CLI ya confirmó). `method == nil` = el método por defecto del repo. Si el head del PR
    /// ya no es `expectedHeadOid` (el que se mostró), no mergea.
    func merge(pr: String, method: MergeMethod?, expectedHeadOid: String) async throws -> MergeInfo
    /// Lo que muestra la ventana de Merge (con el resumen del PR, spec G.5); falla igual que `merge` si no se puede
    /// mergear.
    func mergePreview(pr: String, method: MergeMethod?) async throws -> MergePreviewInfo
    func mergeDismiss(pr: String) throws
}

@MainActor
public protocol ConfigActions: AnyObject {
    func configShow() -> AppConfig
    func configSetRefreshInterval(minutes: Int) throws
    func configSetLaunchAtLogin(enabled: Bool) throws
    func accountList() -> [AccountInfo]
    func accountSetEnabled(login: String, enabled: Bool) throws
    func accountReload() async throws -> [AccountInfo]
    func repoList(account: String?) throws -> [RepoInfo]
    func repoAvailable(account: String?, reload: Bool) async throws -> [String]
    func repoAdd(repo: String, account: String?) async throws -> RepoInfo
    func repoRemove(repo: String, account: String?) throws
    func repoSet(repo: String, account: String?, changes: RepoChanges) async throws -> RepoInfo
    func repoBranches(repo: String, account: String?, reload: Bool) async throws -> BranchesInfo
    func followList(repo: String?, account: String?) throws -> [FollowInfo]
    func followAdd(repo: String, users: [String], account: String?) async throws -> FollowInfo
    func followRemove(repo: String, users: [String], account: String?) throws -> FollowInfo
    func followSuggestions(repo: String, account: String?) async throws -> [UserSuggestionInfo]
    func notifyList() async -> NotificationsInfo
    func notifySet(kind: NotificationSettingName, enabled: Bool) throws
    func notifySetEnabled(enabled: Bool) throws
    func claudeShow() -> ClaudeSettings
    func claudeSet(changes: ClaudeChanges) throws -> ClaudeSettings
    func claudeReset() throws -> ClaudeSettings
    func claudeSkillList() async -> [SkillInfo]
    func toolsList() -> [ToolInfo]
    func toolsSet(tool: ToolName, path: String?) async throws -> [ToolInfo]
}

@MainActor
public protocol SlackActions: AnyObject {
    func slackShow() -> SlackInfo
    func slackSetEnabled(enabled: Bool) throws
    func slackSetProvider(provider: SlackProvider) throws
    func slackTokenSet(token: String) async throws -> SlackCheckInfo
    func slackTokenClear() throws
    func slackSetToggle(toggle: SlackToggleName, enabled: Bool) throws
    func slackSetEmoji(kind: SlackEmojiKind, name: String) throws
    func slackSetSearchDays(days: Int) throws
    func slackTemplateList() -> [TemplateInfo]
    func slackTemplateSet(template: SlackTemplateName, text: String) throws
    func slackTemplateReset(template: SlackTemplateName) throws
    func slackCheck() async throws -> SlackCheckInfo
    func slackSelfTest() async throws -> [SelfTestStepInfo]
    func slackChannels(reload: Bool) async throws -> [ChannelInfo]
}

@MainActor
public protocol ChatCommandActions: AnyObject {
    func chatSend(pr: String, message: String, events: CommandEventSink) async throws -> ChatInfo
    func chatShow(pr: String) throws -> ChatInfo
    func chatUndo(pr: String, confirmed: Bool) async throws -> ChatInfo
    func chatStop(pr: String) throws -> ChatInfo
}

@MainActor
public protocol UpdateCommandActions: AnyObject {
    func updateCheck() async throws -> UpdateInfo
    /// `events` sigue la instalación, que corre en su propia tarea (la ventana o `prbar update --cancel` la cancelan).
    func updateInstall(cancelJobs: Bool, events: @escaping CommandEventSink) async throws -> UpdateInfo
    func updateCancel() throws
    func updateSkip(version: String?) async throws -> UpdateInfo
    func configSetUpdateInterval(hours: Int) throws
}

@MainActor
public protocol InstructionCommandActions: AnyObject {
    func rulesList(repo: String?) throws -> [RuleInfo]
    func rulesAdd(text: String, scope: RuleScope, appliesTo: [RuleStage]) throws -> RuleInfo
    func rulesEdit(id: String, text: String?, scope: RuleScope?, appliesTo: [RuleStage]?) throws -> RuleInfo
    func rulesRemove(id: String) throws
    func rulesSetEnabled(id: String, enabled: Bool) throws
    func rulesChatSend(message: String, events: CommandEventSink) async throws -> ChatInfo
    func rulesChatShow() -> ChatInfo
    func rulesChatUndo(confirmed: Bool) async throws -> ChatInfo
    func rulesChatStop() throws -> ChatInfo
    func rulesSuggestions() -> [RuleSuggestionInfo]
    func rulesSuggestionAct(id: String, action: SuggestionAction, text: String?) throws -> [RuleInfo]
    func chatProposal(pr: String, number: Int, save: Bool, text: String?, scope: RuleScope?, appliesTo: [RuleStage]?) throws -> ChatInfo
    func claudeReviewSet(changes: ReviewOptionChanges) throws -> ClaudeSettings
    func claudeRespondSet(changes: RespondOptionChanges) throws -> ClaudeSettings
    func claudeStageSet(stage: PromptStage, change: StageChange) throws -> ClaudeSettings
    func claudePromptShow(stage: PromptStage) -> PromptInfo
    func claudePromptSet(stage: PromptStage, text: String) throws -> PromptInfo
    func claudePromptReset(stage: PromptStage) throws -> PromptInfo
}

/// Lo que la app tiene que saber hacer para abrir el socket.
public typealias PRBarActions = StatusActions & ReviewActions & RespondActions & MergeActions & ConfigActions
    & SlackActions & ChatCommandActions & UpdateCommandActions & InstructionCommandActions
