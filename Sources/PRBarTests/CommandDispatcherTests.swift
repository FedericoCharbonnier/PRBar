import Foundation
import PRBarCore

/// Un ejemplo de cada comando y el método que tiene que llamar (el primer token de lo que anota `FakeActions`).
let dispatchSamples: [(command: AppCommand, call: String)] = [
    (.status, "status"),
    (.listPRs(list: .mine, account: nil), "listPRs"),
    (.resolvePR(pr: "api#1"), "resolvePR"),
    (.history(repo: nil, kind: .review, limit: 3, search: nil), "historyList"),
    (.historyShow(id: "abcd"), "historyShow"),
    (.historyReopen(id: "abcd"), "historyReopen"),
    (.refresh, "refresh"),
    (.open(pr: "api#1", target: .review), "open"),
    (.openSettings(tab: .slack), "openSettings"),
    (.openHistory(id: nil), "openHistory"),
    (.quit, "quit"),
    (.reviewStart(pr: "api#1", wait: false), "reviewStart"),
    (.reviewShow(pr: "api#1"), "reviewShow"),
    (.reviewEdit(pr: "api#1", finding: "2", title: nil, body: "b"), "reviewEdit"),
    (.reviewSetIncluded(pr: "api#1", findings: ["1"], all: false, included: true), "reviewSetIncluded"),
    (.reviewSetComment(pr: "api#1", text: "LGTM"), "reviewSetComment"),
    (.reviewPublish(pr: "api#1", event: .comment, only: nil, withComments: true, allInBody: false, confirmed: true), "reviewPublish"),
    (.reviewCancel(pr: "api#1"), "reviewCancel"),
    (.reviewDismiss(pr: "api#1"), "reviewDismiss"),
    (.respondStart(pr: "web#2", wait: false), "respondStart"),
    (.respondShow(pr: "web#2"), "respondShow"),
    (.respondSelect(pr: "web#2", items: ["1"], change: RespondSelectionChange(implement: true)), "respondSelect"),
    (.respondReset(pr: "web#2"), "respondReset"),
    (.respondImplement(pr: "web#2", wait: false), "respondImplement"),
    (.respondTest(pr: "web#2", wait: false), "respondTest"),
    (.respondDiff(pr: "web#2"), "respondDiff"),
    (.respondPush(pr: "web#2", confirmed: true, wait: false), "respondPush"),
    (.respondPushAnyway(pr: "web#2", confirmed: true, wait: false), "respondPushAnyway"),
    (.respondReplyOnly(pr: "web#2", confirmed: true, wait: false), "respondReplyOnly"),
    (.respondCancel(pr: "web#2"), "respondCancel"),
    (.respondDismiss(pr: "web#2"), "respondDismiss"),
    (.merge(pr: "api#4", method: .rebase, confirmed: true), "merge"),
    (.mergeDismiss(pr: "api#4"), "mergeDismiss"),
    (.configShow, "configShow"),
    (.setRefreshInterval(minutes: 5), "configSetRefreshInterval"),
    (.setLaunchAtLogin(enabled: true), "configSetLaunchAtLogin"),
    (.setConfirmMerge(enabled: false), "configSetConfirmMerge"),
    (.accountList, "accountList"),
    (.accountSetEnabled(login: "me", enabled: false), "accountSetEnabled"),
    (.accountReload, "accountReload"),
    (.repoList(account: nil), "repoList"),
    (.repoAvailable(account: nil, reload: true), "repoAvailable"),
    (.repoAdd(repo: "acme/api", account: nil), "repoAdd"),
    (.repoRemove(repo: "acme/api", account: nil), "repoRemove"),
    (.repoSet(repo: "acme/api", account: nil, changes: RepoChanges(addBranches: ["main"])), "repoSet"),
    (.repoBranches(repo: "acme/api", account: nil, reload: false), "repoBranches"),
    (.followList(repo: nil, account: nil), "followList"),
    (.followAdd(repo: "acme/api", users: ["ana"], account: nil), "followAdd"),
    (.followRemove(repo: "acme/api", users: ["ana"], account: nil), "followRemove"),
    (.followSuggestions(repo: "acme/api", account: nil), "followSuggestions"),
    (.notifyList, "notifyList"),
    (.notifySet(kind: .myFeedback, enabled: false), "notifySet"),
    (.notifySetEnabled(enabled: false), "notifySetEnabled"),
    (.claudeShow, "claudeShow"),
    (.claudeSet(changes: ClaudeChanges(filterEnabled: false)), "claudeSet"),
    (.claudeReset, "claudeReset"),
    (.claudeSkills, "claudeSkillList"),
    (.toolsList, "toolsList"),
    (.toolsSet(tool: .git, path: "/usr/bin/git"), "toolsSet"),
    (.slackShow, "slackShow"),
    (.slackSetEnabled(enabled: true), "slackSetEnabled"),
    (.slackSetProvider(provider: .claudeConnector), "slackSetProvider"),
    (.slackTokenSet(token: "xoxp-1"), "slackTokenSet"),
    (.slackTokenClear, "slackTokenClear"),
    (.slackSetToggle(toggle: .rounds, enabled: false), "slackSetToggle"),
    (.slackSetEmoji(kind: .eyes, name: "eyes"), "slackSetEmoji"),
    (.slackSetSearchDays(days: 30), "slackSetSearchDays"),
    (.slackTemplateList, "slackTemplateList"),
    (.slackTemplateSet(template: .round, text: "x{n}"), "slackTemplateSet"),
    (.slackTemplateReset(template: .round), "slackTemplateReset"),
    (.slackCheck, "slackCheck"),
    (.slackSelfTest(confirmed: true), "slackSelfTest"),
    (.slackChannels(reload: false), "slackChannels"),
    (.chatSend(pr: "api#1", message: "why #2?"), "chatSend"),
    (.chatShow(pr: "api#1"), "chatShow"),
    (.chatUndo(pr: "api#1", confirmed: false), "chatUndo"),
    (.chatStop(pr: "api#1"), "chatStop"),
    (.updateCheck, "updateCheck"),
    (.updateInstall(confirmed: true, cancelJobs: false), "updateInstall"),
    (.updateCancel, "updateCancel"),
    (.updateSkip(version: nil), "updateSkip"),
    (.setUpdateInterval(hours: 24), "configSetUpdateInterval"),
    (.rulesList(repo: nil), "rulesList"),
    (.rulesAdd(text: "No style comments", scope: .global, appliesTo: [.review]), "rulesAdd"),
    (.rulesEdit(id: "r1", text: "x", scope: nil, appliesTo: nil), "rulesEdit"),
    (.rulesRemove(id: "r1"), "rulesRemove"),
    (.rulesSetEnabled(id: "r1", enabled: false), "rulesSetEnabled"),
    (.rulesChatSend(message: "forget the console.log one"), "rulesChatSend"),
    (.rulesChatShow, "rulesChatShow"),
    (.rulesChatUndo(confirmed: false), "rulesChatUndo"),
    (.rulesChatStop, "rulesChatStop"),
    (.rulesSuggestions, "rulesSuggestions"),
    (.rulesSuggestionAct(id: "s1", action: .accept, text: nil), "rulesSuggestionAct"),
    (.chatProposal(pr: "api#1", number: 1, save: true, text: nil), "chatProposal"),
    (.claudeReviewSet(changes: ReviewOptionChanges(minSeverity: .medium)), "claudeReviewSet"),
    (.claudeRespondSet(changes: RespondOptionChanges(commitMode: .perComment)), "claudeRespondSet"),
    (.claudeStageSet(stage: .review, change: .useDefault), "claudeStageSet"),
    (.claudePromptShow(stage: .filter), "claudePromptShow"),
    (.claudePromptSet(stage: .filter, text: "…"), "claudePromptSet"),
    (.claudePromptReset(stage: .filter), "claudePromptReset"),
]

enum CommandDispatcherTests {
    static let cases: [TestCase] = [
        TestCase("dispatcher: cada comando llama a su método") { try await everyCommand() },
        TestCase("dispatcher: los argumentos llegan") { try await arguments() },
        TestCase("dispatcher: publicar, pushear, mergear, actualizar y la prueba de Slack exigen confirmación") { try await confirmations() },
        TestCase("dispatcher: errores → CommandFailure") { try await errors() },
        TestCase("dispatcher: los eventos de una espera llegan al sink") { try await events() },
    ]

    @MainActor
    private static func run(_ command: AppCommand, _ fake: FakeActions,
                            events: @escaping CommandEventSink = { _ in }) async -> Result<JSONValue, CommandFailure> {
        await CommandDispatcher.run(command, on: fake, events: events)
    }

    @MainActor
    private static func everyCommand() async throws {
        try expectEqual(Set(dispatchSamples.map(\.command.name)), Set(AppCommand.Name.allCases))
        for sample in dispatchSamples {
            let fake = FakeActions()
            let result = await run(sample.command, fake)
            if case .failure(let error) = result { throw TestFailure(description: "\(sample.command.name): \(error.message)") }
            let call = fake.calls.last?.split(separator: " ").first.map(String.init)
            try expectEqual(call, sample.call)
        }
    }

    @MainActor
    private static func arguments() async throws {
        let fake = FakeActions()
        _ = await run(.reviewPublish(pr: "acme/api#3", event: .approve, only: ["1", "f2"], withComments: false,
                                     allInBody: true, confirmed: true), fake)
        try expectEqual(fake.calls.last, #"reviewPublish acme/api#3 APPROVE only=["1", "f2"] comments=false body=true"#)
        _ = await run(.respondSelect(pr: "web#2", items: ["1", "2"],
                                     change: RespondSelectionChange(implement: false, replyText: "Thanks")), fake)
        try expectEqual(fake.calls.last, #"respondSelect web#2 ["1", "2"] implement=false reply=- text=Thanks plan=-"#)
        let result = await run(.reviewCancel(pr: "x"), fake)
        try expectEqual(result, .success(.ok))
    }

    @MainActor
    private static func confirmations() async throws {
        let unconfirmed: [AppCommand] = [
            .reviewPublish(pr: "a#1", event: .comment, only: nil, withComments: true, allInBody: false, confirmed: false),
            .respondPush(pr: "a#1", confirmed: false, wait: false),
            .respondPushAnyway(pr: "a#1", confirmed: false, wait: false),
            .merge(pr: "a#1", method: nil, confirmed: false),
            .updateInstall(confirmed: false, cancelJobs: false),
            .respondReplyOnly(pr: "a#1", confirmed: false, wait: false),
            .slackSelfTest(confirmed: false),
        ]
        for command in unconfirmed {
            let fake = FakeActions()
            let result = await run(command, fake)
            guard case .failure(let failure) = result else { throw TestFailure(description: "\(command.name) no pidió --yes") }
            try expectEqual(failure.code, .confirmationRequired)
            try expectEqual(fake.calls, [])
        }
    }

    @MainActor
    private static func errors() async throws {
        let fake = FakeActions()
        fake.failure = CommandFailure(.notFound, "No PR")
        let notFound = await run(.reviewShow(pr: "x"), fake)
        try expectEqual(notFound, .failure(CommandFailure(.notFound, "No PR")))
        fake.failure = PRBarError.toolNotFound("gh")
        let failed = await run(.reviewShow(pr: "x"), fake)
        try expectEqual(failed, .failure(CommandFailure(.failed, PRBarError.toolNotFound("gh").localizedDescription)))
        fake.failure = CancellationError()
        let cancelled = await run(.reviewShow(pr: "x"), fake)
        try expectEqual(cancelled, .failure(CommandFailure(.cancelled, "Canceled.")))
    }

    @MainActor
    private static func events() async throws {
        let fake = FakeActions()
        fake.waitEvents = [.progress(message: "Queued"), .progress(message: "Reviewing…")]
        let box = EventBox()
        _ = await run(.reviewStart(pr: "x", wait: true), fake) { event in box.append(event) }
        try expectEqual(box.events, fake.waitEvents)
    }
}

/// Junta eventos desde un closure `@Sendable`.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CommandEvent] = []

    func append(_ event: CommandEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var events: [CommandEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
