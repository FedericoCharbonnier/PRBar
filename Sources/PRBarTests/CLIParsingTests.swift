import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

/// Parsea `arguments` como en la terminal y devuelve el `AppCommand` que mandaría (confirmado).
func parsed(_ arguments: [String], confirmed: Bool = true) throws -> AppCommand {
    let command = try PRBarCommand.parseAsRoot(arguments)
    guard let remote = command as? any RemoteCommand else {
        throw TestFailure(description: "\(arguments) no es un comando remoto")
    }
    return try remote.appCommand(confirmed: confirmed)
}

/// `true` si parsear `arguments` falla (uso inválido → exit 2).
func rejects(_ arguments: [String]) -> Bool {
    (try? PRBarCommand.parseAsRoot(arguments)) == nil
}

enum CLIParsingTests {
    static var cases: [TestCase] {
        [
            TestCase("cli parse: --json no saltea efectos; quit y update --cancel no abren la app (L14, L15)") {
                try expect(rejects(["open", "api#3", "--copy", "--json"]))
                try expect(rejects(["history", "show", "abcd", "--open-log", "--json"]))
                try expect(rejects(["history", "show", "abcd", "--reveal-log", "--json"]))
                try expect(!rejects(["history", "show", "abcd", "--json"]))
                func launches(_ arguments: [String]) throws -> Bool {
                    guard let command = try PRBarCommand.parseAsRoot(arguments) as? any RemoteCommand else {
                        throw TestFailure(description: "\(arguments) no es remoto")
                    }
                    return command.launchesApp
                }
                try expect(!(try launches(["app", "quit"])))
                try expect(!(try launches(["update", "--cancel"])))
                try expect(try launches(["update", "--check"]))
                try expect(try launches(["status"]))
            },
            TestCase("cli parse: ci y usage (specs K y O)") {
                try expectEqual(try parsed(["ci"]), .ciList)
                try expectEqual(try parsed(["ci", "fix", "api#3", "--wait"]), .ciFix(pr: "api#3", wait: true))
                try expectEqual(try parsed(["ci", "show", "api#3"]), .respondShow(pr: "api#3"))
                try expectEqual(try parsed(["ci", "push", "api#3", "--yes"]), .respondPush(pr: "api#3", confirmed: true, wait: false, mode: .ciFix))
                try expectEqual(try parsed(["ci", "push", "api#3", "--anyway", "--yes"]), .respondPushAnyway(pr: "api#3", confirmed: true, wait: false, mode: .ciFix))
                try expectEqual(try parsed(["ci", "cancel", "api#3"]), .respondCancel(pr: "api#3"))
                try expectEqual(try parsed(["usage"]), .usage(month: nil))
                try expectEqual(try parsed(["usage", "--month", "2026-03"]), .usage(month: "2026-03"))
                try expect(rejects(["usage", "--month", "2026-13"]))
                try expect(rejects(["usage", "--month", "march"]))
                try expectEqual(try parsed(["history", "--kind", "ci-fix"]), .history(repo: nil, kind: .ciFix, limit: nil, search: nil))
                try expectEqual(try parsed(["claude", "prompt", "show", "ci-fix"]), .claudePromptShow(stage: .ciFix))
                try expectEqual(try parsed(["claude", "prompt", "show", "conflicts"]), .claudePromptShow(stage: .conflicts))
            },
            TestCase("cli: prbar conflicts list|resolve|show|diff|test|push|cancel|dismiss") {
                try expectEqual(try parsed(["conflicts"]), .conflictsList)
                try expectEqual(try parsed(["conflicts", "list"]), .conflictsList)
                try expectEqual(try parsed(["conflicts", "resolve", "web#2", "--wait"]), .conflictsResolve(pr: "web#2", wait: true))
                try expectEqual(try parsed(["conflicts", "show", "web#2"]), .respondShow(pr: "web#2"))
                try expectEqual(try parsed(["conflicts", "diff", "web#2"]), .respondDiff(pr: "web#2"))
                try expectEqual(try parsed(["conflicts", "test", "web#2"]), .respondTest(pr: "web#2", wait: false))
                try expectEqual(try parsed(["conflicts", "push", "web#2", "--yes"]),
                                .respondPush(pr: "web#2", confirmed: true, wait: false, mode: .conflicts))
                try expectEqual(try parsed(["conflicts", "push", "web#2", "--anyway", "--yes"]),
                                .respondPushAnyway(pr: "web#2", confirmed: true, wait: false, mode: .conflicts))
                try expectEqual(try parsed(["conflicts", "cancel", "web#2"]), .respondCancel(pr: "web#2"))
                try expectEqual(try parsed(["history", "--kind", "conflicts"]), .history(repo: nil, kind: .conflicts, limit: nil, search: nil))
            },
            TestCase("cli parse: status") {
                try expectEqual(try parsed(["status"]), .status)
                try expectEqual(try parsed(["status", "--json"]), .status)
            },
            TestCase("cli parse: prs, refresh, open e historial") {
                try expectEqual(try parsed(["prs", "--list", "to-review", "--account", "me"]), .listPRs(list: .toReview, account: "me"))
                try expectEqual(try parsed(["prs", "--list", "ready-to-merge"]), .listPRs(list: .readyToMerge, account: nil))
                try expectEqual(try parsed(["prs"]), .listPRs(list: nil, account: nil))
                try expectEqual(try parsed(["prs", "--tab", "mine"]), .listPRs(list: nil, account: nil, tab: .mine))
                try expectEqual(try parsed(["prs", "--tab", "to-review", "--list", "other"]), .listPRs(list: .other, account: nil, tab: .toReview))
                try expectEqual(try parsed(["prs", "--tab", "mine", "--list", "ready-to-merge"]), .listPRs(list: .readyToMerge, account: nil, tab: .mine))
                try expect(rejects(["prs", "--tab", "mine", "--list", "to-review"]))
                try expect(rejects(["prs", "--tab", "to-review", "--list", "mine"]))
                try expect(rejects(["prs", "--tab", "everything"]))
                try expectEqual(try parsed(["refresh"]), .refresh)
                try expectEqual(try parsed(["open", "api#3"]), .open(pr: "api#3", target: .browser))
                try expectEqual(try parsed(["open", "api#3", "--review"]), .open(pr: "api#3", target: .review))
                try expectEqual(try parsed(["open", "api#3", "--worktree"]), .open(pr: "api#3", target: .worktree))
                try expectEqual(try parsed(["open", "api#3", "--merge"]), .open(pr: "api#3", target: .merge))
                try expectEqual(try parsed(["open", "api#3", "--copy"]), .resolvePR(pr: "api#3"))
                try expect(rejects(["open", "api#3", "--review", "--respond"]))
                try expect(rejects(["open", "api#3", "--review", "--copy"]))
                try expectEqual(try parsed(["history", "--repo", "acme/api", "--kind", "review", "--limit", "5", "--search", "login"]),
                                .history(repo: "acme/api", kind: .review, limit: 5, search: "login"))
                try expectEqual(try parsed(["history"]), .history(repo: nil, kind: nil, limit: nil, search: nil))
                try expectEqual(try parsed(["history", "--kind", "merge"]), .history(repo: nil, kind: .merge, limit: nil, search: nil))
                try expectEqual(try parsed(["history", "show", "1a2b3c4d"]), .historyShow(id: "1a2b3c4d"))
                try expectEqual(try parsed(["history", "reopen", "1a2b3c4d"]), .historyReopen(id: "1a2b3c4d"))
            },
            TestCase("cli parse: app") {
                try expectEqual(try parsed(["app", "quit"]), .quit)
                try expectEqual(try parsed(["app", "popover"]), .openPopover(tab: nil))
                try expectEqual(try parsed(["app", "popover", "--tab", "mine"]), .openPopover(tab: .mine))
                try expect(rejects(["app", "popover", "--tab", "x"]))
                try expectEqual(try parsed(["app", "settings", "slack"]), .openSettings(tab: .slack))
                try expectEqual(try parsed(["app", "settings", "instructions"]), .openSettings(tab: .instructions))
                try expectEqual(try parsed(["app", "settings"]), .openSettings(tab: nil))
                try expectEqual(try parsed(["app", "history", "1a2b"]), .openHistory(id: "1a2b"))
                try expect(rejects(["app", "settings", "nope"]))
                try expect(rejects(["app", "logs", "--slack", "--update"]))
                for local in [["app", "start"], ["app", "logs", "--slack"], ["app", "logs", "--update"], ["doctor"], ["version"],
                              ["completion", "zsh"]] {
                    let command = try PRBarCommand.parseAsRoot(local)
                    try expect(command is any LocalCommand, "\(local)")
                }
            },
            TestCase("cli parse: review") {
                try expectEqual(try parsed(["review", "acme/api#1"]), .reviewStart(pr: "acme/api#1", wait: false))
                try expectEqual(try parsed(["review", "acme/api#1", "--wait"]), .reviewStart(pr: "acme/api#1", wait: true))
                try expectEqual(try parsed(["review", "show", "api#1"]), .reviewShow(pr: "api#1"))
                try expectEqual(try parsed(["review", "edit", "api#1", "2", "--title", "T", "--body", "B"]),
                                .reviewEdit(pr: "api#1", finding: "2", title: "T", body: "B"))
                try expect(rejects(["review", "edit", "api#1", "2", "--body", "B", "--editor"]))
                try expectEqual(try parsed(["review", "include", "api#1", "1", "3"]),
                                .reviewSetIncluded(pr: "api#1", findings: ["1", "3"], all: false, included: true))
                try expectEqual(try parsed(["review", "exclude", "api#1", "--all"]),
                                .reviewSetIncluded(pr: "api#1", findings: [], all: true, included: false))
                try expect(rejects(["review", "include", "api#1"]))
                try expectEqual(try parsed(["review", "comment", "api#1", "--text", "LGTM"]), .reviewSetComment(pr: "api#1", text: "LGTM"))
                try expectEqual(try parsed(["review", "publish", "api#1", "--approve", "--only", "1,3", "--yes"]),
                                .reviewPublish(pr: "api#1", event: .approve, only: ["1", "3"], withComments: true, allInBody: false, confirmed: true))
                try expectEqual(try parsed(["review", "publish", "api#1", "--request-changes", "--all-in-body"], confirmed: false),
                                .reviewPublish(pr: "api#1", event: .requestChanges, only: nil, withComments: true, allInBody: true, confirmed: false))
                try expectEqual(try parsed(["review", "publish", "api#1", "--approve", "--no-comments"]),
                                .reviewPublish(pr: "api#1", event: .approve, only: nil, withComments: false, allInBody: false, confirmed: true))
                try expect(rejects(["review", "publish", "api#1"]))
                try expect(rejects(["review", "publish", "api#1", "--comment", "--no-comments"]))
                try expectEqual(try parsed(["review", "cancel", "api#1"]), .reviewCancel(pr: "api#1"))
                try expectEqual(try parsed(["review", "dismiss", "api#1"]), .reviewDismiss(pr: "api#1"))
            },
            TestCase("cli parse: review publish --recommended") {
                let command = try PRBarCommand.parseAsRoot(["review", "publish", "api#1", "--recommended", "--yes"])
                let remote = try expectSome(command as? any RemoteCommand)
                // Sin resolver (lo hace `prepare` con `review show`) no manda nada.
                try expect((try? remote.appCommand(confirmed: true)) == nil)
                try expect(rejects(["review", "publish", "api#1", "--recommended", "--only", "1"]))
                try expect(rejects(["review", "publish", "api#1", "--recommended", "--no-comments"]))
                try expect(rejects(["review", "publish", "api#1", "--recommended", "--approve"]))
            },
            TestCase("cli: pregunta de confirmación de la review") {
                try expectEqual(ReviewQuestion.text(event: .approve, pr: "acme/api#1", account: "me", comments: 2, general: true),
                                "Approve acme/api#1 as @me with 2 comments and a general comment?")
                try expectEqual(ReviewQuestion.text(event: .comment, pr: "acme/api#1", account: "me", comments: 1, general: false),
                                "Comment on acme/api#1 as @me with 1 comment?")
                try expectEqual(ReviewQuestion.text(event: .approve, pr: "acme/api#1", account: "me", comments: 0, general: false),
                                "Approve acme/api#1 as @me without comments?")
            },
            TestCase("cli parse: respond") {
                try expectEqual(try parsed(["respond", "web#2", "--wait"]), .respondStart(pr: "web#2", wait: true))
                try expectEqual(try parsed(["respond", "show", "web#2"]), .respondShow(pr: "web#2"))
                try expectEqual(try parsed(["respond", "select", "web#2", "1", "2", "--implement"]),
                                .respondSelect(pr: "web#2", items: ["1", "2"], change: RespondSelectionChange(implement: true)))
                try expectEqual(try parsed(["respond", "select", "web#2", "1", "--reply-only", "--reply", "Thanks!"]),
                                .respondSelect(pr: "web#2", items: ["1"], change: RespondSelectionChange(implement: false, reply: true, replyText: "Thanks!")))
                try expectEqual(try parsed(["respond", "select", "web#2", "thread:A", "--skip"]),
                                .respondSelect(pr: "web#2", items: ["thread:A"], change: RespondSelectionChange(implement: false, reply: false)))
                try expectEqual(try parsed(["respond", "select", "web#2", "1", "--implement", "--no-reply", "--plan", "Do X"]),
                                .respondSelect(pr: "web#2", items: ["1"], change: RespondSelectionChange(implement: true, reply: false, fixPlan: "Do X")))
                try expectEqual(try parsed(["respond", "select", "web#2", "--reset"]), .respondReset(pr: "web#2"))
                try expect(rejects(["respond", "select", "web#2", "--reset", "--skip"]))
                try expect(rejects(["respond", "select", "web#2", "1", "--skip", "--reply", "x"]))
                try expect(rejects(["respond", "select", "web#2", "--implement"]))
                try expectEqual(try parsed(["respond", "implement", "web#2"]), .respondImplement(pr: "web#2", wait: false))
                try expectEqual(try parsed(["respond", "test", "web#2", "--wait"]), .respondTest(pr: "web#2", wait: true))
                try expectEqual(try parsed(["respond", "diff", "web#2", "--stat"]), .respondDiff(pr: "web#2"))
                try expectEqual(try parsed(["respond", "push", "web#2", "--yes"]), .respondPush(pr: "web#2", confirmed: true, wait: false, mode: .feedback))
                try expectEqual(try parsed(["respond", "reply-only", "web#2"], confirmed: false),
                                .respondReplyOnly(pr: "web#2", confirmed: false, wait: false))
                try expectEqual(try parsed(["respond", "cancel", "web#2"]), .respondCancel(pr: "web#2"))
                try expectEqual(try parsed(["respond", "dismiss", "web#2"]), .respondDismiss(pr: "web#2"))
            },
            TestCase("cli: preguntas de push y respuestas (como la ventana)") {
                var info = RespondInfo(prID: "acme/web#2", phase: nil, record: nil, selections: [:], runningTests: false, testCommand: nil)
                info.account = "me"
                info.headRef = "feature/x"
                info.pendingReplies = 2
                info.commits = [CommitDTO(item: "a", status: "committed", sha: "abc", summary: "s")]
                try expectEqual(RespondQuestion.push(info), "Push 1 commit to feature/x and post 2 replies as @me?")
                info.pushed = true
                try expectEqual(RespondQuestion.push(info), "Post 2 pending replies as @me?")
                info.replies = 1
                try expectEqual(RespondQuestion.replyOnly(info), "Post 1 reply to acme/web#2 as @me? Nothing is pushed.")
            },
            TestCase("cli parse: config, account, notify y tools") {
                try expectEqual(try parsed(["config", "show"]), .configShow)
                try expectEqual(try parsed(["config", "set", "refresh-interval", "5"]), .setRefreshInterval(minutes: 5))
                try expectEqual(try parsed(["config", "set", "launch-at-login", "on"]), .setLaunchAtLogin(enabled: true))
                try expect(rejects(["config", "set", "launch-at-login", "maybe"]))
                try expectEqual(try parsed(["config", "set", "always-show-in-dock", "on"]), .setAlwaysShowInDock(enabled: true))
                try expectEqual(try parsed(["config", "set", "always-show-in-dock", "off"]), .setAlwaysShowInDock(enabled: false))
                try expect(rejects(["config", "set", "always-show-in-dock", "maybe"]))
                try expect(rejects(["config", "set", "refresh-interval", "x"]))
                try expect(rejects(["config", "set", "confirm-merge", "off"]))
                try expectEqual(try parsed(["notify", "set", "ready-to-merge", "on"]), .notifySet(kind: .readyToMerge, enabled: true))
                try expectEqual(try parsed(["account", "list"]), .accountList)
                try expectEqual(try parsed(["account", "enable", "me"]), .accountSetEnabled(login: "me", enabled: true))
                try expectEqual(try parsed(["account", "disable", "me"]), .accountSetEnabled(login: "me", enabled: false))
                try expectEqual(try parsed(["account", "reload"]), .accountReload)
                try expectEqual(try parsed(["notify", "list"]), .notifyList)
                try expectEqual(try parsed(["notify", "set", "my-feedback", "off"]), .notifySet(kind: .myFeedback, enabled: false))
                try expectEqual(try parsed(["notify", "enable"]), .notifySetEnabled(enabled: true))
                try expectEqual(try parsed(["notify", "disable"]), .notifySetEnabled(enabled: false))
                try expectEqual(try parsed(["tools", "list"]), .toolsList)
                try expectEqual(try parsed(["tools", "reset", "gh"]), .toolsSet(tool: .gh, path: nil))
                try expect(try PRBarCommand.parseAsRoot(["notify", "system-settings"]) is any LocalCommand)
            },
            TestCase("cli parse: repo y follow") {
                try expectEqual(try parsed(["repo", "list", "--account", "me"]), .repoList(account: "me"))
                try expectEqual(try parsed(["repo", "available", "--reload"]), .repoAvailable(account: nil, reload: true))
                try expectEqual(try parsed(["repo", "add", "acme/api"]), .repoAdd(repo: "acme/api", account: nil))
                try expectEqual(try parsed(["repo", "remove", "acme/api"]), .repoRemove(repo: "acme/api", account: nil))
                try expectEqual(try parsed(["repo", "branches", "acme/api", "--reload"]), .repoBranches(repo: "acme/api", account: nil, reload: true))
                try expectEqual(try parsed(["repo", "set", "acme/api", "--path", "none", "--worktrees", "default", "--test-command", "",
                                            "--add-branch", "main", "--add-branch", "dev", "--remove-branch", "old", "--channel", "#eng"]),
                                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(
                                    localPath: .clear, worktreeDir: .clear, testCommand: .clear,
                                    addBranches: ["main", "dev"], removeBranches: ["old"], channel: .set(value: "#eng"))))
                try expectEqual(try parsed(["repo", "set", "acme/api", "--branches", "main,develop", "--channel", "none"]),
                                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(baseBranches: ["main", "develop"], channel: .clear)))
                guard case .repoSet(_, _, let changes) = try parsed(["repo", "set", "acme/api", "--path", "~/code/api"]),
                      case .set(let path)? = changes.localPath else { throw TestFailure(description: "sin --path") }
                try expect(path.hasPrefix("/") && path.hasSuffix("/code/api"), path)
                try expect(rejects(["repo", "set", "acme/api"]))
                try expectEqual(try parsed(["repo", "set", "acme/api", "--merge-method", "rebase"]),
                                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(mergeMethod: .set(value: "rebase"))))
                try expectEqual(try parsed(["repo", "set", "acme/api", "--merge-method", "default"]),
                                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(mergeMethod: .clear)))
                try expect(rejects(["repo", "set", "acme/api", "--merge-method", "fast-forward"]))
                try expect(try PRBarCommand.parseAsRoot(["repo", "open", "acme/api"]) is any LocalCommand)
                try expectEqual(try parsed(["follow", "list"]), .followList(repo: nil, account: nil))
                try expectEqual(try parsed(["follow", "add", "acme/api", "ana", "@bob"]), .followAdd(repo: "acme/api", users: ["ana", "@bob"], account: nil))
                try expectEqual(try parsed(["follow", "remove", "acme/api", "ana"]), .followRemove(repo: "acme/api", users: ["ana"], account: nil))
                try expectEqual(try parsed(["follow", "suggestions", "acme/api"]), .followSuggestions(repo: "acme/api", account: nil))
            },
            TestCase("cli parse: claude") {
                try expectEqual(try parsed(["claude", "show"]), .claudeShow)
                try expectEqual(try parsed(["claude", "reset"]), .claudeReset)
                try expectEqual(try parsed(["claude", "skills"]), .claudeSkills)
                try expectEqual(try parsed(["claude", "set", "--review-skill", "a:b", "--filter", "off", "--model", "default"]),
                                .claudeSet(changes: ClaudeChanges(reviewSkill: "a:b", filterEnabled: false, model: .clear)))
                try expectEqual(try parsed(["claude", "set", "--model", "sonnet", "--respond-skill", "x"]),
                                .claudeSet(changes: ClaudeChanges(respondSkill: "x", model: .set(value: "sonnet"))))
                try expect(rejects(["claude", "set"]))
            },
            TestCase("cli parse: slack") {
                try expectEqual(try parsed(["slack", "show"]), .slackShow)
                try expectEqual(try parsed(["slack", "enable"]), .slackSetEnabled(enabled: true))
                try expectEqual(try parsed(["slack", "disable"]), .slackSetEnabled(enabled: false))
                try expectEqual(try parsed(["slack", "provider", "connector"]), .slackSetProvider(provider: .claudeConnector))
                try expectEqual(try parsed(["slack", "provider", "token"]), .slackSetProvider(provider: .userToken))
                SlackTokenInput.read = { _ in "xoxp-test" }
                try expectEqual(try parsed(["slack", "token", "set", "--stdin"]), .slackTokenSet(token: "xoxp-test"))
                try expectEqual(try parsed(["slack", "token", "clear"]), .slackTokenClear)
                try expectEqual(try parsed(["slack", "set", "react-start", "off"]), .slackSetToggle(toggle: .reactStart, enabled: false))
                try expectEqual(try parsed(["slack", "set", "rounds", "on"]), .slackSetToggle(toggle: .rounds, enabled: true))
                try expectEqual(try parsed(["slack", "emoji", "eyes", "eyes"]), .slackSetEmoji(kind: .eyes, name: "eyes"))
                try expectEqual(try parsed(["slack", "search-days", "30"]), .slackSetSearchDays(days: 30))
                try expectEqual(try parsed(["slack", "template", "list"]), .slackTemplateList)
                try expectEqual(try parsed(["slack", "template", "show", "new-pr"]), .slackTemplateList)
                try expectEqual(try parsed(["slack", "template", "set", "round", "commented x{n}"]),
                                .slackTemplateSet(template: .round, text: "commented x{n}"))
                try expectEqual(try parsed(["slack", "template", "reset", "update"]), .slackTemplateReset(template: .update))
                try expectEqual(try parsed(["slack", "check"]), .slackCheck)
                try expectEqual(try parsed(["slack", "test", "--yes"]), .slackSelfTest(confirmed: true))
                try expectEqual(try parsed(["slack", "channels", "--reload"]), .slackChannels(reload: true))
                try expect(rejects(["slack", "provider", "bot"]))
                try expectEqual(try parsed(["slack", "set", "merged", "off"]), .slackSetToggle(toggle: .merged, enabled: false))
                try expectEqual(try parsed(["slack", "template", "set", "merged", "Merged via {method}"]),
                                .slackTemplateSet(template: .merged, text: "Merged via {method}"))
                try expectEqual(try parsed(["slack", "template", "set", "myPR.merged", "Done"]), .slackTemplateSet(template: .merged, text: "Done"))
                try expectEqual(try parsed(["slack", "template", "reset", "myPR.merged"]), .slackTemplateReset(template: .merged))
            },
            TestCase("cli parse: merge") {
                // Sin la vista previa (que trae `prepare`) no hay head confirmado: la app lo rechaza.
                try expectEqual(try parsed(["merge", "api#4", "--yes"]),
                                .merge(pr: "api#4", method: nil, confirmed: true, expectedHeadOid: ""))
                try expectEqual(try parsed(["merge", "api#4", "--method", "rebase"], confirmed: false),
                                .merge(pr: "api#4", method: .rebase, confirmed: false, expectedHeadOid: ""))
                try expectEqual(try parsed(["merge", "api#4", "--dismiss"]), .mergeDismiss(pr: "api#4"))
                try expectEqual(try parsed(["merge", "api#4", "--preview", "--method", "merge"]),
                                .mergePreview(pr: "api#4", method: .merge))
                try expect(rejects(["merge", "api#4", "--method", "fast-forward"]))
                try expect(rejects(["merge", "api#4", "--dismiss", "--method", "squash"]))
                try expect(rejects(["merge", "api#4", "--dismiss", "--preview"]))
            },
            TestCase("cli parse: chat") {
                try expectEqual(try parsed(["chat", "api#1", "why is #2 a bug?"]), .chatSend(pr: "api#1", message: "why is #2 a bug?"))
                try expectEqual(try parsed(["chat", "api#1", "--show"]), .chatShow(pr: "api#1"))
                try expectEqual(try parsed(["chat", "api#1", "--undo", "--yes"]), .chatUndo(pr: "api#1", confirmed: true))
                try expectEqual(try parsed(["chat", "api#1", "--stop"]), .chatStop(pr: "api#1"))
                try expect(rejects(["chat", "api#1", "hi", "--undo"]))
                try expectEqual(try parsed(["claude", "set", "--chat", "off", "--chat-model", "same"]),
                                .claudeSet(changes: ClaudeChanges(chatEnabled: false, chatModel: .clear)))
            },
            TestCase("cli parse: update") {
                try expectEqual(try parsed(["update", "--check"]), .updateCheck)
                try expectEqual(try parsed(["update", "--yes"]), .updateInstall(confirmed: true, cancelJobs: false))
                try expectEqual(try parsed(["update", "--cancel-jobs", "--yes"]), .updateInstall(confirmed: true, cancelJobs: true))
                try expectEqual(try parsed(["update", "--skip"]), .updateSkip(version: nil))
                try expectEqual(try parsed(["update", "--skip", "--skip-version", "1.3.0"]), .updateSkip(version: "1.3.0"))
                try expect(rejects(["update", "--skip-version", "1.3.0"]))
                try expectEqual(try parsed(["update", "--cancel"]), .updateCancel)
                try expect(rejects(["update", "--check", "--skip"]))
                try expectEqual(try parsed(["config", "set", "update-interval", "0"]), .setUpdateInterval(hours: 0))
            },
            TestCase("cli parse: rules, opciones y prompts") {
                try expectEqual(try parsed(["rules", "list", "--repo", "acme/web"]), .rulesList(repo: "acme/web"))
                try expectEqual(try parsed(["rules", "add", "Use React Query", "--repo", "acme/web", "--fixes"]),
                                .rulesAdd(text: "Use React Query", scope: .repo("acme/web"), appliesTo: [.respond]))
                try expectEqual(try parsed(["rules", "add", "No style comments"]),
                                .rulesAdd(text: "No style comments", scope: .global, appliesTo: [.review, .respond]))
                // --review/--fixes se combinan con lo que la regla ya tiene en `prepare` (pide `rules list`).
                try expectEqual(try parsed(["rules", "edit", "r1ab", "--global", "--no-fixes"]),
                                .rulesEdit(id: "r1ab", text: nil, scope: .global, appliesTo: nil))
                try expectEqual(try parsed(["rules", "edit", "r1ab", "--repo", "acme/web", "--text", "T"]),
                                .rulesEdit(id: "r1ab", text: "T", scope: .repo("acme/web"), appliesTo: nil))
                try expect(rejects(["rules", "edit", "r1ab"]))
                try expect(rejects(["rules", "edit", "r1ab", "--global", "--repo", "acme/web"]))
                try expectEqual(try parsed(["rules", "disable", "r1ab"]), .rulesSetEnabled(id: "r1ab", enabled: false))
                try expectEqual(try parsed(["rules", "remove", "r1ab"]), .rulesRemove(id: "r1ab"))
                try expectEqual(try parsed(["rules", "chat", "forget the console.log one"]), .rulesChatSend(message: "forget the console.log one"))
                try expectEqual(try parsed(["rules", "chat", "--undo", "--yes"]), .rulesChatUndo(confirmed: true))
                try expectEqual(try parsed(["rules", "chat", "--show"]), .rulesChatShow)
                try expectEqual(try parsed(["rules", "chat", "--stop"]), .rulesChatStop)
                try expect(rejects(["rules", "chat", "hi", "--show"]))
                try expectEqual(try parsed(["rules", "suggestions"]), .rulesSuggestions)
                try expectEqual(try parsed(["rules", "suggestions", "never", "s1"]), .rulesSuggestionAct(id: "s1", action: .never, text: nil))
                try expectEqual(try parsed(["rules", "suggestions", "accept", "s1", "--text", "T"]), .rulesSuggestionAct(id: "s1", action: .accept, text: "T"))
                try expectEqual(try parsed(["rules", "suggestions", "dismiss", "s1"]), .rulesSuggestionAct(id: "s1", action: .dismiss, text: nil))
                try expectEqual(try parsed(["rules", "proposal", "save", "api#1", "1", "--text", "Edited"]),
                                .chatProposal(pr: "api#1", number: 1, save: true, text: "Edited"))
                try expectEqual(try parsed(["rules", "proposal", "save", "api#1", "2", "--global"]),
                                .chatProposal(pr: "api#1", number: 2, save: true, text: nil, scope: .global))
                try expectEqual(try parsed(["rules", "proposal", "dismiss", "api#1", "1"]), .chatProposal(pr: "api#1", number: 1, save: false, text: nil))
                try expect(rejects(["rules", "proposal", "save", "api#1", "1", "--global", "--this-repo"]))
                try expectEqual(try parsed(["claude", "review", "set", "--min-severity", "medium", "--max-findings", "10",
                                            "--ignore", "generated/**", "--category", "style=off", "--tone", "with-suggestions"]),
                                .claudeReviewSet(changes: ReviewOptionChanges(minSeverity: .medium, maxFindings: .set(value: "10"),
                                                                              addIgnore: ["generated/**"], categories: ["style": false],
                                                                              tone: .withSuggestions)))
                try expectEqual(try parsed(["claude", "review", "set", "--max-findings", "none", "--unignore", "x/**"]),
                                .claudeReviewSet(changes: ReviewOptionChanges(maxFindings: .clear, removeIgnore: ["x/**"])))
                try expect(rejects(["claude", "review", "set", "--category", "style"]))
                try expect(rejects(["claude", "review", "set"]))
                try expectEqual(try parsed(["claude", "respond", "set", "--tests-before-push", "on", "--commit-mode", "per-comment", "--allow-deps", "off"]),
                                .claudeRespondSet(changes: RespondOptionChanges(runTestsBeforePush: true, commitMode: .perComment,
                                                                                allowNewDependencies: false)))
                try expectEqual(try parsed(["claude", "respond", "set", "--commit-template", "Fix {n}", "--reply-template", "default"]),
                                .claudeRespondSet(changes: RespondOptionChanges(commitMessageTemplate: .set(value: "Fix {n}"), replyTemplate: .clear)))
                try expectEqual(try parsed(["claude", "stage", "filter", "--default"]), .claudeStageSet(stage: .filter, change: .useDefault))
                try expectEqual(try parsed(["claude", "stage", "review", "--skill", "a:b"]), .claudeStageSet(stage: .review, change: .skill(name: "a:b")))
                try expect(rejects(["claude", "stage", "filter", "--default", "--skill", "x"]))
                try expect(rejects(["claude", "stage", "chat-review", "--default"]))
                try expectEqual(try parsed(["claude", "prompt", "reset", "chat-review"]), .claudePromptReset(stage: .reviewChat))
                try expectEqual(try parsed(["claude", "prompt", "show", "chat-instructions"]), .claudePromptShow(stage: .instructionsChat))
                try expect(rejects(["claude", "prompt", "show", "reviewChat"]))
                guard case .repoSet(_, _, let changes) = try parsed(["repo", "set", "acme/web", "--ignore", "dist/**", "--unignore", "gen/**"]) else {
                    throw TestFailure(description: "repo set")
                }
                try expectEqual(changes.addIgnore, ["dist/**"])
                try expectEqual(changes.removeIgnore, ["gen/**"])
                try expectEqual(try parsed(["respond", "push", "web#2", "--anyway", "--yes"]), .respondPushAnyway(pr: "web#2", confirmed: true, wait: false, mode: .feedback))
                try expect(try PRBarCommand.parseAsRoot(["app", "logs", "--instructions"]) is any LocalCommand)
            },
            TestCase("cli: --review/--fixes cambian solo lo nombrado") {
                func flags(_ arguments: [String]) throws -> StageFlags { try StageFlags.parse(arguments) }
                try expectEqual(try flags(["--no-fixes"]).applied(to: [.review, .respond]), [.review])
                try expectEqual(try flags(["--review"]).applied(to: [.respond]), [.review, .respond])
                try expectEqual(try flags(["--no-review", "--fixes"]).applied(to: [.review]), [.respond])
                try expectEqual(try flags([]).applied(to: [.respond]), [.respond])
                try expect(try flags([]).isEmpty)
            },
            TestCase("cli parse: resources, cleanup y disk-warning") {
                try expectEqual(try parsed(["resources"]), .resources)
                try expectEqual(try parsed(["resources", "--json"]), .resources)
                try expectEqual(try parsed(["cleanup"]), .cleanup(olderThanDays: nil, confirmed: true))
                try expectEqual(try parsed(["cleanup", "--older-than", "30d"]), .cleanup(olderThanDays: 30, confirmed: true))
                try expectEqual(try parsed(["cleanup", "--older-than", "7"]), .cleanup(olderThanDays: 7, confirmed: true))
                try expectEqual(try parsed(["cleanup"], confirmed: false), .cleanup(olderThanDays: nil, confirmed: false))
                try expect(rejects(["cleanup", "--older-than", "0d"]))
                try expect(rejects(["cleanup", "--older-than", "a week"]))
                try expectEqual(try parsed(["config", "set", "disk-warning", "5"]), .setDiskWarning(gigabytes: 5))
                try expectEqual(try parsed(["config", "set", "disk-warning", "off"]), .setDiskWarning(gigabytes: nil))
                try expect(rejects(["config", "set", "disk-warning", "0"]))
                try expect(rejects(["config", "set", "disk-warning", "101"]))
                try expectEqual(try parsed(["config", "set", "terminal", "iterm"]), .setTerminal(terminal: .iterm))
                try expectEqual(try parsed(["config", "set", "terminal", "custom"]), .setTerminal(terminal: .custom))
                try expect(rejects(["config", "set", "terminal", "kitty"]))
                try expectEqual(try parsed(["config", "set", "terminal-command", ""]), .setTerminalCommand(command: ""))
                try expectEqual(try parsed(["config", "set", "terminal-command", "open -na Ghostty --args -e /bin/zsh -lc {command}"]),
                                .setTerminalCommand(command: "open -na Ghostty --args -e /bin/zsh -lc {command}"))
                try expectEqual(try parsed(["config", "set", "keep-session-folders", "off"]), .setKeepSessionFolders(enabled: false))
                try expectEqual(try parsed(["config", "set", "keep-session-folders", "on"]), .setKeepSessionFolders(enabled: true))
                try expect(rejects(["config", "set", "keep-session-folders", "maybe"]))
                try expectEqual(try parsed(["cleanup", "--preview"]), .cleanupPreview(olderThanDays: nil))
            },
            TestCase("cli parse: session list y open") {
                try expectEqual(try parsed(["session", "list", "api#7"]), .sessionList(pr: "api#7"))
                try expectEqual(try parsed(["session", "list", "api#7", "--json"]), .sessionList(pr: "api#7"))
                try expectEqual(try parsed(["session", "open", "api#7"]), .sessionOpen(pr: "api#7", job: nil, run: nil))
                try expectEqual(try parsed(["session", "open", "api#7", "--job", "ci-fix", "--run", "2"]),
                                .sessionOpen(pr: "api#7", job: .ciFix, run: 2))
                try expectEqual(try parsed(["session", "open", "api#7", "--job", "review"]),
                                .sessionOpen(pr: "api#7", job: .review, run: nil))
                try expect(rejects(["session", "open", "api#7", "--job", "chat"]))
                try expect(rejects(["session", "open", "api#7", "--run", "0"]))
                try expect(rejects(["session", "list"]))
                try expect(rejects(["session", "open"]))
            },
            TestCase("cli parse: runners y repo set --run-on") {
                try expectEqual(try parsed(["runners", "list"]), .runnersList)
                try expectEqual(try parsed(["runners"]), .runnersList)
                try expectEqual(try parsed(["runners", "add", "devbox"]), .runnerAdd(host: "devbox", name: nil, dir: nil, fallback: true))
                try expectEqual(try parsed(["runners", "add", "fede@devbox:2222", "--name", "gpu", "--dir", "/srv/prbar", "--no-fallback"]),
                                .runnerAdd(host: "fede@devbox:2222", name: "gpu", dir: "/srv/prbar", fallback: false))
                try expect(rejects(["runners", "add", "-oProxyCommand=x"]))
                try expect(rejects(["runners", "add", "--", "-oProxyCommand=x"]))
                try expect(rejects(["runners", "add", "devbox", "--dir", "~/../x"]))
                try expect(rejects(["runners", "add", "devbox", "--dir", "~/.ssh/prbar"]))
                try expect(rejects(["runners", "add", "devbox", "--name", "local"]))
                try expect(rejects(["runners", "add", "devbox", "--name", "default"]))
                // Un host que no sirve de nombre (IPv6, más de 40 caracteres): el error sugiere --name, y con --name anda.
                for host in ["[fe80::1]", "user@" + String(repeating: "a", count: 41)] {
                    do {
                        _ = try PRBarCommand.parseAsRoot(["runners", "add", host])
                        throw TestFailure(description: "\(host) was accepted")
                    } catch let error as TestFailure {
                        throw error
                    } catch {
                        let message = PRBarCommand.message(for: error)
                        try expect(message.contains("--name"), message)
                    }
                    try expectEqual(try parsed(["runners", "add", host, "--name", "gpu"]),
                                    .runnerAdd(host: host, name: "gpu", dir: nil, fallback: true))
                }
                try expectEqual(RunnerConfigError.needsName("fe80::1").localizedDescription,
                                "“fe80::1” can’t be a runner name: give it one with letters, numbers, . _ and - (Name, or --name in prbar).")
                try expectEqual(try parsed(["runners", "set", "devbox", "--fallback", "off"]), .runnerSet(name: "devbox", dir: nil, fallback: false))
                try expectEqual(try parsed(["runners", "set", "devbox", "--dir", "~/prbar"]), .runnerSet(name: "devbox", dir: "~/prbar", fallback: nil))
                try expect(rejects(["runners", "set", "devbox"]))
                try expect(rejects(["runners", "set", "devbox", "--dir", "relative/dir"]))
                try expectEqual(try parsed(["runners", "remove", "devbox"]), .runnerRemove(name: "devbox"))
                try expectEqual(try parsed(["runners", "test", "devbox"]), .runnerTest(name: "devbox"))
                try expectEqual(try parsed(["runners", "default", "local"]), .runnerDefault(target: "local"))
                try expectEqual(try parsed(["runners", "default", "devbox"]), .runnerDefault(target: "devbox"))
                try expect(rejects(["runners", "default", "a b"]))
                try expect(rejects(["runners", "default", "default"]))
                try expectEqual(try parsed(["repo", "set", "acme/api", "--run-on", "devbox"]),
                                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(runOn: .set(value: "devbox"))))
                try expectEqual(try parsed(["repo", "set", "acme/api", "--run-on", "local"]),
                                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(runOn: .set(value: "local"))))
                try expectEqual(try parsed(["repo", "set", "acme/api", "--run-on", "default"]),
                                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(runOn: .clear)))
                try expect(rejects(["repo", "set", "acme/api", "--run-on", "a b"]))
                try expect(rejects(["repo", "set", "acme/api", "--run-on", "-oProxyCommand=x"]))
            },
        ]
    }
}
