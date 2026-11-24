import Foundation
import PRBarCore

enum AppCommandTests {
    static let cases: [TestCase] = [
        TestCase("app command: JSON estable con etiquetas") {
            try expectEqual(try CommandProtocol.line(AppCommand.reviewStart(pr: "acme/api#1", wait: true)),
                            #"{"reviewStart":{"pr":"acme/api#1","wait":true}}"#)
            try expectEqual(try CommandProtocol.line(AppCommand.status), #"{"status":{}}"#)
            try expectEqual(try CommandProtocol.line(CommandRequest(id: 7, command: .refresh)),
                            #"{"command":{"refresh":{}},"id":7}"#)
            try expectEqual(try CommandProtocol.line(AppCommand.repoSet(repo: "acme/api", account: nil,
                                                                         changes: RepoChanges(localPath: .clear))),
                            #"{"repoSet":{"changes":{"addBranches":[],"addIgnore":[],"localPath":{"clear":{}},"removeBranches":[],"removeIgnore":[]},"repo":"acme/api"}}"#)
        },
        TestCase("app command: ida y vuelta de comandos variados") {
            let commands: [AppCommand] = [
                .listPRs(list: .toReview, account: "me"),
                .listPRs(list: .readyToMerge, account: nil),
                .history(repo: "acme/api", kind: .respond, limit: 5, search: "login"),
                .open(pr: "api#3", target: .posted),
                .reviewPublish(pr: "acme/api#1", event: .approve, only: ["1", "f3"], withComments: true, allInBody: false,
                               confirmed: true),
                .respondSelect(pr: "acme/web#2", items: ["1"], change: RespondSelectionChange(implement: true, replyText: "Done")),
                .claudeSet(changes: ClaudeChanges(filterEnabled: false, model: .set(value: "sonnet"), chatModel: .clear)),
                .slackSetToggle(toggle: .reactStart, enabled: false),
                .slackTemplateSet(template: .newPR, text: "{link}"),
                .toolsSet(tool: .gh, path: nil),
                .merge(pr: "api#4", method: .squash, confirmed: true, expectedHeadOid: "c0ffee"),
                .merge(pr: "api#4", method: nil, confirmed: false, expectedHeadOid: ""),
                .mergePreview(pr: "api#4", method: nil),
                .repoSet(repo: "acme/api", account: "me",
                         changes: RepoChanges(addIgnore: ["dist/**"], mergeMethod: .set(value: "rebase"))),
                .chatUndo(pr: "api#1", confirmed: true),
                .updateInstall(confirmed: true, cancelJobs: false),
                .updateSkip(version: "1.3.0"),
                .rulesAdd(text: "Use React Query", scope: .repo("acme/web"), appliesTo: [.respond]),
                .rulesEdit(id: "r1", text: nil, scope: .global, appliesTo: [.review]),
                .rulesSuggestionAct(id: "s1", action: .never, text: nil),
                .claudeReviewSet(changes: ReviewOptionChanges(minSeverity: .medium, maxFindings: .set(value: "10"),
                                                              categories: ["style": false], tone: .friendly)),
                .claudeRespondSet(changes: RespondOptionChanges(commitMode: .single, replyTemplate: .clear)),
                .claudeStageSet(stage: .filter, change: .skill(name: "a:b")),
                .claudePromptReset(stage: .reviewChat),
                .resources, .cleanupPreview(olderThanDays: 30), .cleanup(olderThanDays: nil, confirmed: true),
                .setDiskWarning(gigabytes: nil), .setDiskWarning(gigabytes: 5),
                .setTerminal(terminal: .orca), .setTerminalCommand(command: "open -a Terminal {dir} {command}"),
                .setKeepSessionFolders(enabled: false),
                .sessionList(pr: "api#7"), .sessionOpen(pr: "api#7", job: .ciFix, run: 2), .sessionOpen(pr: "api#7", job: nil, run: nil),
                .runnersList, .runnerAdd(host: "fede@devbox:2222", name: nil, dir: "/srv/prbar", fallback: false),
                .runnerSet(name: "devbox", dir: nil, fallback: true), .runnerRemove(name: "devbox"), .runnerTest(name: "devbox"),
                .runnerDefault(target: "local"),
                .ciList, .ciFix(pr: "api#12", wait: true), .usage(month: nil), .usage(month: "2026-10"),
                .history(repo: nil, kind: .ciFix, limit: nil, search: nil),
                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(runOn: .set(value: "devbox"))),
                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(runOn: .clear)),
            ]
            for command in commands {
                let decoded = try CommandProtocol.decode(AppCommand.self, line: try CommandProtocol.line(command))
                try expectEqual(decoded, command)
            }
        },
        TestCase("app command: Name tiene un caso por comando") {
            try expectEqual(AppCommand.Name.allCases.count, 132)
            try expectEqual(AppCommand.slackTokenSet(token: "xoxp-secret").name, .slackTokenSet)
            try expectEqual(AppCommand.reviewCancel(pr: "x").name.rawValue, "reviewCancel")
            try expectEqual(AppCommand.claudePromptShow(stage: .review).name, .claudePromptShow)
        },
        TestCase("app command: RespondSelectionChange aplica en orden") {
            var selection = RespondSelection(implement: true, fixPlan: "p", reply: false, replyText: "")
            RespondSelectionChange(implement: false, reply: true).apply(to: &selection)
            try expectEqual(selection, RespondSelection(implement: false, fixPlan: "p", reply: true, replyText: ""))
            RespondSelectionChange(replyText: "Thanks", fixPlan: "new plan").apply(to: &selection)
            try expectEqual(selection, RespondSelection(implement: false, fixPlan: "new plan", reply: true, replyText: "Thanks"))
            RespondSelectionChange(reply: false, replyText: "x").apply(to: &selection)
            try expectEqual(selection.reply, false)
        },
        TestCase("app command: nombres de toggles, notificaciones, emojis y plantillas cubren los de la config") {
            try expectEqual(Set(SlackToggleName.allCases.map(\.toggle)).count, SlackToggle.allCases.count)
            try expectEqual(Set(SlackTemplateName.allCases.map(\.kind)).count, SlackTemplateKind.allCases.count)
            try expectEqual(NotificationSettingName.allCases.count, 6)
            var settings = NotificationSettings()
            for kind in NotificationSettingName.allCases { settings[keyPath: kind.keyPath] = false }
            try expect(!settings.newToReview && !settings.reviewedPRUpdated && !settings.myPRFeedback
                       && !settings.reviewFinished && !settings.myPRApprovedOrCIFailed && !settings.readyToMerge)
            try expectEqual(PRListFilter.mine.category, .myFeedback)
            try expectEqual(Set(PRListFilter.allCases.map(\.category)), Set(PRCategory.allCases))
        },
        TestCase("app command: listPRs con pestaña y openPopover van y vuelven; un listPRs viejo no trae pestaña") {
            for command: AppCommand in [.listPRs(list: .other, account: nil, tab: .mine), .openPopover(tab: nil), .openPopover(tab: .toReview)] {
                let line = try CommandProtocol.line(CommandRequest(id: 1, command: command))
                let back = try CommandProtocol.decode(CommandRequest.self, line: line)
                try expectEqual(back.command, command)
            }
            let old = try JSONDecoder().decode(AppCommand.self, from: Data(#"{"listPRs":{"list":"mine"}}"#.utf8))
            try expectEqual(old, .listPRs(list: .mine, account: nil, tab: nil))
            try expectEqual(AppCommand.openPopover(tab: nil).name, .openPopover)
        },
    ]
}
