import Foundation

/// Una acción de PRBar, tal como la manda `prbar` (spec C.2). Cada caso corresponde a un método de los protocolos
/// `*Actions` (`CommandDispatcher`) y a uno o más comandos de la CLI (`CLIRouter`). `<pr>` va tal cual lo escribió
/// el usuario: lo resuelve la app (`PRReference`).
///
/// Cubre también el chat (plan 6), las actualizaciones (plan 8), las instrucciones/opciones/prompts (plan 9) y
/// Ready to Merge (plan 10), aunque sus subcomandos de la CLI lleguen después.
public enum AppCommand: Codable, Equatable, Sendable {
    // Estado
    case status
    case listPRs(list: PRListFilter?, account: String?, tab: PopoverTab? = nil)
    case resolvePR(pr: String)
    case history(repo: String?, kind: HistoryKind?, limit: Int?, search: String?)
    case historyShow(id: String)
    case historyReopen(id: String)
    case refresh
    // Ventanas / app
    case open(pr: String, target: OpenTarget)
    case openSettings(tab: SettingsTabName?)
    case openHistory(id: String?)
    case quit
    /// Abre el popover (spec H.2), en `tab` si viene (y la deja elegida).
    case openPopover(tab: PopoverTab?)
    // Review (PR ajeno)
    case reviewStart(pr: String, wait: Bool)
    case reviewShow(pr: String)
    case reviewEdit(pr: String, finding: String, title: String?, body: String?)
    case reviewSetIncluded(pr: String, findings: [String], all: Bool, included: Bool)
    case reviewSetComment(pr: String, text: String)
    case reviewPublish(pr: String, event: ReviewEvent, only: [String]?, withComments: Bool, allInBody: Bool, confirmed: Bool)
    case reviewCancel(pr: String)
    case reviewDismiss(pr: String)
    // Respond (mi PR)
    case respondStart(pr: String, wait: Bool)
    case respondShow(pr: String)
    case respondSelect(pr: String, items: [String], change: RespondSelectionChange)
    case respondReset(pr: String)
    case respondImplement(pr: String, wait: Bool)
    case respondTest(pr: String, wait: Bool)
    case respondDiff(pr: String)
    case respondPush(pr: String, confirmed: Bool, wait: Bool)
    /// "Push Anyway": los tests de antes del push fallaron y el usuario pushea igual (spec E.5).
    case respondPushAnyway(pr: String, confirmed: Bool, wait: Bool)
    case respondReplyOnly(pr: String, confirmed: Bool, wait: Bool)
    case respondCancel(pr: String)
    case respondDismiss(pr: String)
    // Ready to Merge (spec F)
    /// `method == nil` = el método por defecto del repo. Mergea sin diálogo: la CLI ya confirmó (`--yes`).
    /// `expectedHeadOid`: el head que la CLI mostró (`mergePreview`); si el PR cambió, la app no mergea.
    case merge(pr: String, method: MergeMethod?, confirmed: Bool, expectedHeadOid: String)
    /// Lo que muestra el diálogo de Merge (título, ramas, commits, head, nota), sin mergear.
    case mergePreview(pr: String, method: MergeMethod?)
    /// Dismiss del error de merge de la fila.
    case mergeDismiss(pr: String)
    // Recursos (spec I)
    /// CPU, RAM, disco por categoría y procesos (`prbar resources`).
    case resources
    /// Lo que borraría Clean Up, sin borrar. `olderThanDays`: también historial y logs más viejos.
    case cleanupPreview(olderThanDays: Int?)
    /// Clean Up. Con algo para borrar exige `confirmed` (lo verifica la app). `paths`: las rutas de la vista previa que
    /// se confirmó; la app solo borra las que sigan en su plan nuevo (nil = todo el plan nuevo).
    case cleanup(olderThanDays: Int?, confirmed: Bool, paths: [String]? = nil)
    // Configuración
    case configShow
    case setRefreshInterval(minutes: Int)
    case setLaunchAtLogin(enabled: Bool)
    /// Settings › General › umbral de disco; nil = apagado.
    case setDiskWarning(gigabytes: Int?)
    case accountList
    case accountSetEnabled(login: String, enabled: Bool)
    case accountReload
    case repoList(account: String?)
    case repoAvailable(account: String?, reload: Bool)
    case repoAdd(repo: String, account: String?)
    case repoRemove(repo: String, account: String?)
    case repoSet(repo: String, account: String?, changes: RepoChanges)
    case repoBranches(repo: String, account: String?, reload: Bool)
    case followList(repo: String?, account: String?)
    case followAdd(repo: String, users: [String], account: String?)
    case followRemove(repo: String, users: [String], account: String?)
    case followSuggestions(repo: String, account: String?)
    case notifyList
    case notifySet(kind: NotificationSettingName, enabled: Bool)
    case notifySetEnabled(enabled: Bool)
    case claudeShow
    case claudeSet(changes: ClaudeChanges)
    case claudeReset
    case claudeSkills
    case toolsList
    case toolsSet(tool: ToolName, path: String?)
    // Slack
    case slackShow
    case slackSetEnabled(enabled: Bool)
    case slackSetProvider(provider: SlackProvider)
    case slackTokenSet(token: String)
    case slackTokenClear
    case slackSetToggle(toggle: SlackToggleName, enabled: Bool)
    case slackSetEmoji(kind: SlackEmojiKind, name: String)
    case slackSetSearchDays(days: Int)
    case slackTemplateList
    case slackTemplateSet(template: SlackTemplateName, text: String)
    case slackTemplateReset(template: SlackTemplateName)
    case slackCheck
    case slackSelfTest(confirmed: Bool)
    case slackChannels(reload: Bool)
    // Chat (spec B, C.4)
    case chatSend(pr: String, message: String)
    case chatShow(pr: String)
    /// `confirmed`: deshacer aunque se pierdan ediciones manuales posteriores (B.6).
    case chatUndo(pr: String, confirmed: Bool)
    case chatStop(pr: String)
    // Actualizaciones (spec D.4)
    case updateCheck
    /// "Update" (o "Cancel Jobs and Update" con `cancelJobs`). Reinicia la app.
    case updateInstall(confirmed: Bool, cancelJobs: Bool)
    case updateCancel
    /// "Skip This Version"; `nil` = la que se ofrece ahora.
    case updateSkip(version: String?)
    /// Settings › General › Updates: 0 = solo a mano.
    case setUpdateInterval(hours: Int)
    // Instrucciones, opciones y prompts (spec E.7)
    case rulesList(repo: String?)
    case rulesAdd(text: String, scope: RuleScope, appliesTo: [RuleStage])
    /// `id`: el id completo o un prefijo único. `nil` = no se toca.
    case rulesEdit(id: String, text: String?, scope: RuleScope?, appliesTo: [RuleStage]?)
    case rulesRemove(id: String)
    case rulesSetEnabled(id: String, enabled: Bool)
    case rulesChatSend(message: String)
    case rulesChatShow
    case rulesChatUndo(confirmed: Bool)
    case rulesChatStop
    case rulesSuggestions
    case rulesSuggestionAct(id: String, action: SuggestionAction, text: String?)
    /// La tarjeta "Save as rule" número `number` (desde 1, entre las pendientes del chat del PR). Al guardar, `text`,
    /// `scope` y `appliesTo` reemplazan lo propuesto (como editar la tarjeta); `nil` = lo propuesto.
    case chatProposal(pr: String, number: Int, save: Bool, text: String?, scope: RuleScope? = nil, appliesTo: [RuleStage]? = nil)
    case claudeReviewSet(changes: ReviewOptionChanges)
    case claudeRespondSet(changes: RespondOptionChanges)
    case claudeStageSet(stage: PromptStage, change: StageChange)
    case claudePromptShow(stage: PromptStage)
    case claudePromptSet(stage: PromptStage, text: String)
    case claudePromptReset(stage: PromptStage)
    // Dónde corre Claude (spec J)
    case runnersList
    /// `host`: alias de ~/.ssh/config o `user@host[:port]`; `name`: por defecto el host; `dir`: por defecto `~/.prbar`.
    case runnerAdd(host: String, name: String?, dir: String?, fallback: Bool)
    /// `nil` = no se toca.
    case runnerSet(name: String, dir: String?, fallback: Bool?)
    case runnerRemove(name: String)
    /// "Test Connection" (incluye el login de Claude).
    case runnerTest(name: String)
    /// `local` o el nombre de un destino.
    case runnerDefault(target: String)

    /// Lo que cambia algo en GitHub o Slack con una sola llamada: si la CLI se va a mitad (Ctrl-C), la llamada sigue
    /// hasta el final (cortarla dejaría el merge, el review o el token en un estado desconocido). Lo demás se cancela
    /// con la conexión (las esperas de `--wait`, el chat).
    public var runsToCompletion: Bool {
        switch self {
        case .merge, .reviewPublish, .slackSelfTest, .slackTokenSet: true
        default: false
        }
    }

    /// Un nombre por caso, sin argumentos: lo recorre el test de paridad y es lo único que se loguea (nunca los
    /// argumentos: `slackTokenSet` lleva un token).
    public enum Name: String, Codable, CaseIterable, Sendable {
        case status, listPRs, resolvePR, history, historyShow, historyReopen, refresh, open, openSettings, openHistory
        case quit, reviewStart, reviewShow, reviewEdit, reviewSetIncluded, reviewSetComment, reviewPublish, reviewCancel
        case reviewDismiss, respondStart, respondShow, respondSelect, respondReset, respondImplement, respondTest
        case respondDiff, respondPush, respondPushAnyway, respondReplyOnly, respondCancel, respondDismiss, merge
        case mergePreview, mergeDismiss, configShow, setRefreshInterval, setLaunchAtLogin, accountList
        case accountSetEnabled, accountReload, repoList, repoAvailable, repoAdd, repoRemove, repoSet, repoBranches
        case followList, followAdd, followRemove, followSuggestions, notifyList, notifySet, notifySetEnabled, claudeShow
        case claudeSet, claudeReset, claudeSkills, toolsList, toolsSet, slackShow, slackSetEnabled, slackSetProvider
        case slackTokenSet, slackTokenClear, slackSetToggle, slackSetEmoji, slackSetSearchDays, slackTemplateList
        case slackTemplateSet, slackTemplateReset, slackCheck, slackSelfTest, slackChannels, chatSend, chatShow, chatUndo
        case chatStop, updateCheck, updateInstall, updateCancel, updateSkip, setUpdateInterval, rulesList, rulesAdd
        case rulesEdit, rulesRemove, rulesSetEnabled, rulesChatSend, rulesChatShow, rulesChatUndo, rulesChatStop
        case rulesSuggestions, rulesSuggestionAct, chatProposal, claudeReviewSet, claudeRespondSet, claudeStageSet
        case claudePromptShow, claudePromptSet, claudePromptReset
        case openPopover
        case resources, cleanupPreview, cleanup, setDiskWarning
        case runnersList, runnerAdd, runnerSet, runnerRemove, runnerTest, runnerDefault
    }

    public var name: Name {
        switch self {
        case .status: .status
        case .listPRs: .listPRs
        case .resolvePR: .resolvePR
        case .history: .history
        case .historyShow: .historyShow
        case .historyReopen: .historyReopen
        case .refresh: .refresh
        case .open: .open
        case .openSettings: .openSettings
        case .openHistory: .openHistory
        case .quit: .quit
        case .openPopover: .openPopover
        case .reviewStart: .reviewStart
        case .reviewShow: .reviewShow
        case .reviewEdit: .reviewEdit
        case .reviewSetIncluded: .reviewSetIncluded
        case .reviewSetComment: .reviewSetComment
        case .reviewPublish: .reviewPublish
        case .reviewCancel: .reviewCancel
        case .reviewDismiss: .reviewDismiss
        case .respondStart: .respondStart
        case .respondShow: .respondShow
        case .respondSelect: .respondSelect
        case .respondReset: .respondReset
        case .respondImplement: .respondImplement
        case .respondTest: .respondTest
        case .respondDiff: .respondDiff
        case .respondPush: .respondPush
        case .respondPushAnyway: .respondPushAnyway
        case .respondReplyOnly: .respondReplyOnly
        case .respondCancel: .respondCancel
        case .respondDismiss: .respondDismiss
        case .merge: .merge
        case .mergePreview: .mergePreview
        case .mergeDismiss: .mergeDismiss
        case .configShow: .configShow
        case .setRefreshInterval: .setRefreshInterval
        case .setLaunchAtLogin: .setLaunchAtLogin
        case .accountList: .accountList
        case .accountSetEnabled: .accountSetEnabled
        case .accountReload: .accountReload
        case .repoList: .repoList
        case .repoAvailable: .repoAvailable
        case .repoAdd: .repoAdd
        case .repoRemove: .repoRemove
        case .repoSet: .repoSet
        case .repoBranches: .repoBranches
        case .followList: .followList
        case .followAdd: .followAdd
        case .followRemove: .followRemove
        case .followSuggestions: .followSuggestions
        case .notifyList: .notifyList
        case .notifySet: .notifySet
        case .notifySetEnabled: .notifySetEnabled
        case .claudeShow: .claudeShow
        case .claudeSet: .claudeSet
        case .claudeReset: .claudeReset
        case .claudeSkills: .claudeSkills
        case .toolsList: .toolsList
        case .toolsSet: .toolsSet
        case .slackShow: .slackShow
        case .slackSetEnabled: .slackSetEnabled
        case .slackSetProvider: .slackSetProvider
        case .slackTokenSet: .slackTokenSet
        case .slackTokenClear: .slackTokenClear
        case .slackSetToggle: .slackSetToggle
        case .slackSetEmoji: .slackSetEmoji
        case .slackSetSearchDays: .slackSetSearchDays
        case .slackTemplateList: .slackTemplateList
        case .slackTemplateSet: .slackTemplateSet
        case .slackTemplateReset: .slackTemplateReset
        case .slackCheck: .slackCheck
        case .slackSelfTest: .slackSelfTest
        case .slackChannels: .slackChannels
        case .chatSend: .chatSend
        case .chatShow: .chatShow
        case .chatUndo: .chatUndo
        case .chatStop: .chatStop
        case .updateCheck: .updateCheck
        case .updateInstall: .updateInstall
        case .updateCancel: .updateCancel
        case .updateSkip: .updateSkip
        case .setUpdateInterval: .setUpdateInterval
        case .rulesList: .rulesList
        case .rulesAdd: .rulesAdd
        case .rulesEdit: .rulesEdit
        case .rulesRemove: .rulesRemove
        case .rulesSetEnabled: .rulesSetEnabled
        case .rulesChatSend: .rulesChatSend
        case .rulesChatShow: .rulesChatShow
        case .rulesChatUndo: .rulesChatUndo
        case .rulesChatStop: .rulesChatStop
        case .rulesSuggestions: .rulesSuggestions
        case .rulesSuggestionAct: .rulesSuggestionAct
        case .chatProposal: .chatProposal
        case .claudeReviewSet: .claudeReviewSet
        case .claudeRespondSet: .claudeRespondSet
        case .claudeStageSet: .claudeStageSet
        case .claudePromptShow: .claudePromptShow
        case .claudePromptSet: .claudePromptSet
        case .claudePromptReset: .claudePromptReset
        case .resources: .resources
        case .cleanupPreview: .cleanupPreview
        case .cleanup: .cleanup
        case .setDiskWarning: .setDiskWarning
        case .runnersList: .runnersList
        case .runnerAdd: .runnerAdd
        case .runnerSet: .runnerSet
        case .runnerRemove: .runnerRemove
        case .runnerTest: .runnerTest
        case .runnerDefault: .runnerDefault
        }
    }
}
