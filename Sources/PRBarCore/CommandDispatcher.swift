import Foundation

/// `AppCommand` → método de `PRBarActions`. Es el único `switch` sobre los comandos: un caso nuevo sin despachar
/// no compila. Publicar, pushear, aprobar, mergear, actualizar y la prueba de Slack exigen `confirmed` (la CLI lo
/// manda con `--yes` o después de preguntar en la terminal); acá se vuelve a verificar por si otro cliente se lo
/// salteó.
public enum CommandDispatcher {
    @MainActor
    public static func run(_ command: AppCommand, on actions: any PRBarActions,
                           events: @escaping CommandEventSink) async -> Result<JSONValue, CommandFailure> {
        do {
            if command.runsToCompletion {
                // Una tarea aparte no hereda la cancelación de la conexión.
                let task = Task { @MainActor in try await perform(command, actions, events) }
                return .success(try await task.value)
            }
            return .success(try await perform(command, actions, events))
        } catch let failure as CommandFailure {
            return .failure(failure)
        } catch is CancellationError {
            return .failure(CommandFailure(.cancelled, "Canceled."))
        } catch {
            return .failure(CommandFailure(.failed, error.localizedDescription))
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValue(encoding: value)
    }

    private static func requireConfirmation(_ confirmed: Bool, _ what: String) throws {
        guard confirmed else {
            throw CommandFailure(.confirmationRequired, "\(what) needs confirmation: run it again with --yes.")
        }
    }

    @MainActor
    private static func perform(_ command: AppCommand, _ actions: any PRBarActions,
                                _ events: @escaping CommandEventSink) async throws -> JSONValue {
        switch command {
        // Estado
        case .status:
            return try encode(await actions.status())
        case .listPRs(let list, let account, let tab):
            return try encode(actions.listPRs(list: list, account: account, tab: tab))
        case .resolvePR(let pr):
            return try encode(actions.resolvePR(pr))
        case .history(let repo, let kind, let limit, let search):
            return try encode(actions.historyList(repo: repo, kind: kind, limit: limit, search: search))
        case .historyShow(let id):
            return try encode(actions.historyShow(id: id))
        case .historyReopen(let id):
            try actions.historyReopen(id: id)
            return .ok
        case .refresh:
            await actions.refresh()
            return .ok
        // Ventanas / app
        case .open(let pr, let target):
            return try encode(actions.open(pr: pr, target: target))
        case .openSettings(let tab):
            actions.openSettings(tab: tab)
            return .ok
        case .openHistory(let id):
            try actions.openHistory(id: id)
            return .ok
        case .quit:
            actions.quit()
            return .ok
        case .openPopover(let tab):
            return try encode(await actions.openPopover(tab: tab))
        // Review
        case .reviewStart(let pr, let wait):
            return try encode(await actions.reviewStart(pr: pr, wait: wait, events: events))
        case .reviewShow(let pr):
            return try encode(actions.reviewShow(pr: pr))
        case .reviewEdit(let pr, let finding, let title, let body):
            return try encode(actions.reviewEdit(pr: pr, finding: finding, title: title, body: body))
        case .reviewSetIncluded(let pr, let findings, let all, let included):
            return try encode(actions.reviewSetIncluded(pr: pr, findings: findings, all: all, included: included))
        case .reviewSetComment(let pr, let text):
            return try encode(actions.reviewSetComment(pr: pr, text: text))
        case .reviewPublish(let pr, let event, let only, let withComments, let allInBody, let confirmed):
            try requireConfirmation(confirmed, "Posting a review")
            return try encode(await actions.reviewPublish(pr: pr, event: event, only: only, withComments: withComments,
                                                          allInBody: allInBody))
        case .reviewCancel(let pr):
            try actions.reviewCancel(pr: pr)
            return .ok
        case .reviewDismiss(let pr):
            try actions.reviewDismiss(pr: pr)
            return .ok
        // Respond
        case .respondStart(let pr, let wait):
            return try encode(await actions.respondStart(pr: pr, wait: wait, events: events))
        case .respondShow(let pr):
            return try encode(actions.respondShow(pr: pr))
        case .respondSelect(let pr, let items, let change):
            return try encode(actions.respondSelect(pr: pr, items: items, change: change))
        case .respondReset(let pr):
            return try encode(actions.respondReset(pr: pr))
        case .respondImplement(let pr, let wait):
            return try encode(await actions.respondImplement(pr: pr, wait: wait, events: events))
        case .respondTest(let pr, let wait):
            return try encode(await actions.respondTest(pr: pr, wait: wait, events: events))
        case .respondDiff(let pr):
            return try encode(actions.respondDiff(pr: pr))
        case .respondPush(let pr, let confirmed, let wait):
            try requireConfirmation(confirmed, "Pushing and posting replies")
            return try encode(await actions.respondPush(pr: pr, wait: wait, events: events))
        case .respondPushAnyway(let pr, let confirmed, let wait):
            try requireConfirmation(confirmed, "Pushing despite failed tests")
            return try encode(await actions.respondPushAnyway(pr: pr, wait: wait, events: events))
        case .respondReplyOnly(let pr, let confirmed, let wait):
            try requireConfirmation(confirmed, "Posting replies")
            return try encode(await actions.respondReplyOnly(pr: pr, wait: wait, events: events))
        case .respondCancel(let pr):
            try actions.respondCancel(pr: pr)
            return .ok
        case .respondDismiss(let pr):
            try actions.respondDismiss(pr: pr)
            return .ok
        // Fix CI y uso de Claude (specs K y O)
        case .ciList:
            return try encode(actions.ciList())
        case .ciFix(let pr, let wait):
            return try encode(await actions.ciFix(pr: pr, wait: wait, events: events))
        case .usage(let month):
            return try encode(actions.usage(month: month))
        // Ready to Merge
        case .merge(let pr, let method, let confirmed, let expectedHeadOid):
            try requireConfirmation(confirmed, "Merging a pull request")
            return try encode(await actions.merge(pr: pr, method: method, expectedHeadOid: expectedHeadOid))
        case .mergePreview(let pr, let method):
            return try encode(await actions.mergePreview(pr: pr, method: method))
        case .mergeDismiss(let pr):
            try actions.mergeDismiss(pr: pr)
            return .ok
        // Configuración
        case .configShow:
            return try encode(actions.configShow())
        case .setRefreshInterval(let minutes):
            try actions.configSetRefreshInterval(minutes: minutes)
            return .ok
        case .setLaunchAtLogin(let enabled):
            try actions.configSetLaunchAtLogin(enabled: enabled)
            return .ok
        case .accountList:
            return try encode(actions.accountList())
        case .accountSetEnabled(let login, let enabled):
            try actions.accountSetEnabled(login: login, enabled: enabled)
            return .ok
        case .accountReload:
            return try encode(await actions.accountReload())
        case .repoList(let account):
            return try encode(actions.repoList(account: account))
        case .repoAvailable(let account, let reload):
            return try encode(await actions.repoAvailable(account: account, reload: reload))
        case .repoAdd(let repo, let account):
            return try encode(await actions.repoAdd(repo: repo, account: account))
        case .repoRemove(let repo, let account):
            try actions.repoRemove(repo: repo, account: account)
            return .ok
        case .repoSet(let repo, let account, let changes):
            return try encode(await actions.repoSet(repo: repo, account: account, changes: changes))
        case .repoBranches(let repo, let account, let reload):
            return try encode(await actions.repoBranches(repo: repo, account: account, reload: reload))
        case .followList(let repo, let account):
            return try encode(actions.followList(repo: repo, account: account))
        case .followAdd(let repo, let users, let account):
            return try encode(await actions.followAdd(repo: repo, users: users, account: account))
        case .followRemove(let repo, let users, let account):
            return try encode(actions.followRemove(repo: repo, users: users, account: account))
        case .followSuggestions(let repo, let account):
            return try encode(await actions.followSuggestions(repo: repo, account: account))
        case .notifyList:
            return try encode(await actions.notifyList())
        case .notifySet(let kind, let enabled):
            try actions.notifySet(kind: kind, enabled: enabled)
            return .ok
        case .notifySetEnabled(let enabled):
            try actions.notifySetEnabled(enabled: enabled)
            return .ok
        case .claudeShow:
            return try encode(actions.claudeShow())
        case .claudeSet(let changes):
            return try encode(actions.claudeSet(changes: changes))
        case .claudeReset:
            return try encode(actions.claudeReset())
        case .claudeSkills:
            return try encode(await actions.claudeSkillList())
        case .toolsList:
            return try encode(actions.toolsList())
        case .toolsSet(let tool, let path):
            return try encode(await actions.toolsSet(tool: tool, path: path))
        // Slack
        case .slackShow:
            return try encode(actions.slackShow())
        case .slackSetEnabled(let enabled):
            try actions.slackSetEnabled(enabled: enabled)
            return .ok
        case .slackSetProvider(let provider):
            try actions.slackSetProvider(provider: provider)
            return .ok
        case .slackTokenSet(let token):
            return try encode(await actions.slackTokenSet(token: token))
        case .slackTokenClear:
            try actions.slackTokenClear()
            return .ok
        case .slackSetToggle(let toggle, let enabled):
            try actions.slackSetToggle(toggle: toggle, enabled: enabled)
            return .ok
        case .slackSetEmoji(let kind, let name):
            try actions.slackSetEmoji(kind: kind, name: name)
            return .ok
        case .slackSetSearchDays(let days):
            try actions.slackSetSearchDays(days: days)
            return .ok
        case .slackTemplateList:
            return try encode(actions.slackTemplateList())
        case .slackTemplateSet(let template, let text):
            try actions.slackTemplateSet(template: template, text: text)
            return .ok
        case .slackTemplateReset(let template):
            try actions.slackTemplateReset(template: template)
            return .ok
        case .slackCheck:
            return try encode(await actions.slackCheck())
        case .slackSelfTest(let confirmed):
            try requireConfirmation(confirmed, "Sending a test message to your Slack DM")
            return try encode(await actions.slackSelfTest())
        case .slackChannels(let reload):
            return try encode(await actions.slackChannels(reload: reload))
        // Chat
        case .chatSend(let pr, let message):
            return try encode(await actions.chatSend(pr: pr, message: message, events: events))
        case .chatShow(let pr):
            return try encode(actions.chatShow(pr: pr))
        case .chatUndo(let pr, let confirmed):
            return try encode(await actions.chatUndo(pr: pr, confirmed: confirmed))
        case .chatStop(let pr):
            return try encode(actions.chatStop(pr: pr))
        // Actualizaciones
        case .updateCheck:
            return try encode(await actions.updateCheck())
        case .updateInstall(let confirmed, let cancelJobs):
            try requireConfirmation(confirmed, "Updating PRBar")
            return try encode(await actions.updateInstall(cancelJobs: cancelJobs, events: events))
        case .updateCancel:
            try actions.updateCancel()
            return .ok
        case .updateSkip(let version):
            return try encode(await actions.updateSkip(version: version))
        case .setUpdateInterval(let hours):
            try actions.configSetUpdateInterval(hours: hours)
            return .ok
        // Instrucciones, opciones y prompts
        case .rulesList(let repo):
            return try encode(actions.rulesList(repo: repo))
        case .rulesAdd(let text, let scope, let stages):
            return try encode(actions.rulesAdd(text: text, scope: scope, appliesTo: stages))
        case .rulesEdit(let id, let text, let scope, let stages):
            return try encode(actions.rulesEdit(id: id, text: text, scope: scope, appliesTo: stages))
        case .rulesRemove(let id):
            try actions.rulesRemove(id: id)
            return .ok
        case .rulesSetEnabled(let id, let enabled):
            try actions.rulesSetEnabled(id: id, enabled: enabled)
            return .ok
        case .rulesChatSend(let message):
            return try encode(await actions.rulesChatSend(message: message, events: events))
        case .rulesChatShow:
            return try encode(actions.rulesChatShow())
        case .rulesChatUndo(let confirmed):
            return try encode(await actions.rulesChatUndo(confirmed: confirmed))
        case .rulesChatStop:
            return try encode(actions.rulesChatStop())
        case .rulesSuggestions:
            return try encode(actions.rulesSuggestions())
        case .rulesSuggestionAct(let id, let action, let text):
            return try encode(actions.rulesSuggestionAct(id: id, action: action, text: text))
        case .chatProposal(let pr, let number, let save, let text, let scope, let stages):
            return try encode(actions.chatProposal(pr: pr, number: number, save: save, text: text, scope: scope,
                                                                 appliesTo: stages))
        case .claudeReviewSet(let changes):
            return try encode(actions.claudeReviewSet(changes: changes))
        case .claudeRespondSet(let changes):
            return try encode(actions.claudeRespondSet(changes: changes))
        case .claudeStageSet(let stage, let change):
            return try encode(actions.claudeStageSet(stage: stage, change: change))
        case .claudePromptShow(let stage):
            return try encode(actions.claudePromptShow(stage: stage))
        case .claudePromptSet(let stage, let text):
            return try encode(actions.claudePromptSet(stage: stage, text: text))
        case .claudePromptReset(let stage):
            return try encode(actions.claudePromptReset(stage: stage))
        // Recursos (spec I)
        case .resources:
            return try encode(await actions.resources())
        case .cleanupPreview(let days):
            return try encode(await actions.cleanupPreview(olderThanDays: days))
        case .cleanup(let days, let confirmed, let paths):
            return try encode(try await actions.cleanup(olderThanDays: days, confirmed: confirmed, paths: paths))
        case .setDiskWarning(let gigabytes):
            try actions.configSetDiskWarning(gigabytes: gigabytes)
            return .ok
        // Dónde corre Claude (spec J)
        case .runnersList:
            return try encode(await actions.runnersList())
        case .runnerAdd(let host, let name, let dir, let fallback):
            return try encode(try await actions.runnerAdd(host: host, name: name, dir: dir, fallback: fallback))
        case .runnerSet(let name, let dir, let fallback):
            return try encode(try await actions.runnerSet(name: name, dir: dir, fallback: fallback))
        case .runnerRemove(let name):
            try await actions.runnerRemove(name: name)
            return .ok
        case .runnerTest(let name):
            return try encode(try await actions.runnerTest(name: name))
        case .runnerDefault(let target):
            try actions.runnerDefault(target: target)
            return .ok
        // Acceso desde el iPhone
        case .remoteStatus:
            return try encode(actions.remoteStatus())
        case .remoteEnable(let relay, let enrollToken):
            return try encode(try await actions.remoteEnable(relay: relay, enrollToken: enrollToken))
        case .remoteDisable:
            return try encode(try await actions.remoteDisable())
        case .remotePairStart:
            return try encode(try await actions.remotePairStart())
        case .remotePairWait(let pairing):
            return try encode(try await actions.remotePairWait(pairing: pairing, events: events))
        case .remotePairConfirm(let pairing, let confirmed):
            return try encode(try await actions.remotePairConfirm(pairing: pairing, accepted: confirmed))
        case .remoteDevices:
            return try encode(actions.remoteDevices())
        case .remoteRevoke(let device, let confirmed):
            try requireConfirmation(confirmed, "Revoking an iPhone")
            return try encode(try await actions.remoteRevoke(device: device))
        case .remoteSetKeepAwake(let enabled):
            return try encode(try actions.remoteSetKeepAwake(enabled: enabled))
        case .remoteReset(let confirmed):
            try requireConfirmation(confirmed, "Resetting iPhone access")
            return try encode(try await actions.remoteReset())
        case .remoteSetPresenceRequirement(let device, let enabled):
            return try encode(try await actions.remoteSetPresenceRequirement(device: device, enabled: enabled))
        case .remoteSetMailbox(let enabled):
            return try encode(try await actions.remoteSetMailbox(enabled: enabled))
        case .remoteSetAppLink(let url):
            return try encode(try actions.remoteSetAppLink(url: url))
        }
    }
}
