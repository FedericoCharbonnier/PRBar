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
            TestCase("cli parse: status") {
                try expectEqual(try parsed(["status"]), .status)
                try expectEqual(try parsed(["status", "--json"]), .status)
            },
            TestCase("cli parse: prs, refresh, open e historial") {
                try expectEqual(try parsed(["prs", "--list", "to-review", "--account", "me"]), .listPRs(list: .toReview, account: "me"))
                try expectEqual(try parsed(["prs", "--list", "ready-to-merge"]), .listPRs(list: .readyToMerge, account: nil))
                try expectEqual(try parsed(["prs"]), .listPRs(list: nil, account: nil))
                try expectEqual(try parsed(["refresh"]), .refresh)
                try expectEqual(try parsed(["open", "api#3"]), .open(pr: "api#3", target: .browser))
                try expectEqual(try parsed(["open", "api#3", "--review"]), .open(pr: "api#3", target: .review))
                try expectEqual(try parsed(["open", "api#3", "--worktree"]), .open(pr: "api#3", target: .worktree))
                try expectEqual(try parsed(["open", "api#3", "--copy"]), .resolvePR(pr: "api#3"))
                try expect(rejects(["open", "api#3", "--review", "--respond"]))
                try expect(rejects(["open", "api#3", "--review", "--copy"]))
                try expectEqual(try parsed(["history", "--repo", "acme/api", "--kind", "review", "--limit", "5", "--search", "login"]),
                                .history(repo: "acme/api", kind: .review, limit: 5, search: "login"))
                try expectEqual(try parsed(["history"]), .history(repo: nil, kind: nil, limit: nil, search: nil))
                try expectEqual(try parsed(["history", "show", "1a2b3c4d"]), .historyShow(id: "1a2b3c4d"))
                try expectEqual(try parsed(["history", "reopen", "1a2b3c4d"]), .historyReopen(id: "1a2b3c4d"))
            },
            TestCase("cli parse: app") {
                try expectEqual(try parsed(["app", "quit"]), .quit)
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
                try expectEqual(try parsed(["respond", "push", "web#2", "--yes"]), .respondPush(pr: "web#2", confirmed: true, wait: false))
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
                try expect(rejects(["config", "set", "refresh-interval", "x"]))
                try expectEqual(try parsed(["config", "set", "confirm-merge", "off"]), .setConfirmMerge(enabled: false))
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
                try expectEqual(try parsed(["merge", "api#4", "--yes"]), .merge(pr: "api#4", method: nil, confirmed: true))
                try expectEqual(try parsed(["merge", "api#4", "--method", "rebase"], confirmed: false),
                                .merge(pr: "api#4", method: .rebase, confirmed: false))
                try expectEqual(try parsed(["merge", "api#4", "--dismiss"]), .mergeDismiss(pr: "api#4"))
                try expect(rejects(["merge", "api#4", "--method", "fast-forward"]))
                try expect(rejects(["merge", "api#4", "--dismiss", "--method", "squash"]))
                try expectEqual(MergeQuestion.text(pr: "acme/api#4", method: .squash), "Squash and Merge acme/api#4?")
                try expectEqual(MergeQuestion.text(pr: "acme/api#4", method: nil), "Merge acme/api#4 with the repo’s default method?")
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
        ]
    }
}
