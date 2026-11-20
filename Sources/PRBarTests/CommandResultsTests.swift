import Foundation
import PRBarCore

enum CommandResultsTests {
    static let cases: [TestCase] = [
        TestCase("resultados: ChatInfo numera las propuestas pendientes y el historial trae la conversación") {
            var draft = editDraft()
            let plain = HistoryDetail(review: ReviewRecord(draft: draft, startedAt: t0, status: .ready), logPath: nil, canReopen: false)
            try expect(plain.chat == nil)
            var session = ChatSession(prID: draft.prID, kind: .review)
            let saved = RuleProposal(scope: .global, appliesTo: [.review], text: "Saved", status: .saved)
            let first = RuleProposal(scope: .global, appliesTo: [.review, .respond], text: "No style comments")
            let second = RuleProposal(scope: .global, appliesTo: [.respond], text: "Use React Query")
            session.messages = [ChatMessage(role: .user, text: "hi"),
                                ChatMessage(role: .assistant, text: "ok", proposals: [saved, first]),
                                ChatMessage(role: .assistant, text: "and", proposals: [second])]
            draft.chat = session
            let detail = HistoryDetail(review: ReviewRecord(draft: draft, startedAt: t0, status: .ready), logPath: nil, canReopen: false)
            guard let chat = detail.chat else { throw TestFailure(description: "sin chat") }
            try expectEqual(chat.kind, "review")
            try expect(chat.readOnly)
            try expectEqual(chat.messages.map(\.role), ["user", "assistant", "assistant"])
            try expectEqual(chat.messages.flatMap(\.proposals).map(\.number), [nil, 1, 2])
            try expectEqual(chat.messages[1].proposals[1].appliesTo, [.review, .respond])
            try expect(!chat.messages.contains(where: \.undoable))
        },
        TestCase("resultados: PRInfo con JSON estable") {
            let item = ClassifiedPR(pr: makePR(number: 1), category: .toReview, account: "fede")
            let info = PRInfo(item: item, review: nil, respond: nil)
            try expectEqual(try CommandProtocol.line(info), #"{"account":"fede","additions":10,"author":"juan","baseRef":"develop","category":"toReview","ci":"success","deletions":2,"headRef":"feature/1","id":"o/r#1","isDraft":false,"number":1,"repo":"o/r","section":"toReview","tab":"to-review","title":"PR 1","updatedAt":"2027-01-15T08:00:00Z","url":"https://github.com/o/r/pull/1"}"#)
            let reviewing = PRInfo(item: item, review: .reviewing(agents: 2), respond: nil)
            try expectEqual(reviewing.review, "reviewing")
        },
        TestCase("resultados: ReviewInfo de un review listo, con números, selección y ediciones") {
            let draft = editDraft()
            var edits = ReviewEdits.initial(for: draft)
            edits.selected.insert("f2")
            edits.setBody("uno", for: "f1", in: draft)
            edits.generalComment = "LGTM"
            let info = ReviewInfo(prID: draft.prID, phase: .ready(draft), edits: edits, outdated: true)
            try expectEqual(info.phase, "ready")
            try expectEqual(info.findings.map(\.id), ["f1", "f2", "f3"])
            try expectEqual(info.findings.map(\.number), [1, 2, 3])
            try expectEqual(info.findings.map(\.included), [true, true, true])
            try expectEqual(info.findings[0].body, "uno")
            try expectEqual(info.findings[0].edited, true)
            try expectEqual(info.findings[1].keptByFilter, false)
            try expectEqual(info.findings[1].filterReason, "not real")
            try expectEqual(info.generalComment, "LGTM")
            try expectEqual(info.account, "me")
            try expect(info.outdated)
        },
        TestCase("resultados: ReviewInfo de fallido, publicado y sin review") {
            let failed = ReviewInfo(prID: "o/r#1", phase: .failed("boom", logURL: URL(fileURLWithPath: "/tmp/x.log")))
            try expectEqual(failed.phase, "failed")
            try expectEqual(failed.detail, "boom")
            try expectEqual(failed.logPath, "/tmp/x.log")
            let posted = ReviewInfo(prID: "o/r#1", phase: .published(URL(string: "https://github.com/o/r/pull/1#r")!))
            try expectEqual(posted.reviewURL?.absoluteString, "https://github.com/o/r/pull/1#r")
            try expectEqual(ReviewInfo(prID: "o/r#1", phase: nil).phase, "none")
        },
        TestCase("resultados: HistoryEntryInfo busca como la ventana de Historial") {
            let record = ReviewRecord(draft: editDraft(), startedAt: t0, status: .ready)
            let entry = HistoryEntryInfo(review: record)
            try expectEqual(entry.kind, .review)
            try expectEqual(entry.status, "ready")
            try expect(entry.matches("#4"))
            try expect(entry.matches("o/r"))
            try expect(entry.matches("pr 4"))
            try expect(!entry.matches("#5"))
        },
        TestCase("resultados: merge, ocultos, repo y reglas") {
            let item = ClassifiedPR(pr: makePR(number: 2), category: .readyToMerge, account: "fede")
            let merging = PRInfo(item: item, review: nil, respond: nil, merge: .merging(.squash))
            try expectEqual(merging.category, "readyToMerge")
            try expectEqual(merging.merge, "merging")
            try expectEqual(merging.mergeError, nil)
            let failed = PRInfo(item: item, review: nil, respond: nil, merge: .failed(method: .merge, error: .noLongerOpen))
            try expectEqual(failed.merge, "failed")
            try expect(failed.mergeError != nil)
            let merged = MergeInfo(completion: MergeCompletion(item: item, method: .rebase, mergedAt: t0))
            try expectEqual(merged.pr, item.id)
            try expectEqual(merged.method, .rebase)

            let base = editDraft()
            let hidden = ReviewDraft(prID: base.prID, repo: base.repo, number: base.number, title: base.title, url: base.url,
                                     author: base.author, headOid: base.headOid, account: base.account, summary: "s",
                                     items: [base.items[0].hiding("Below medium")])
            let info = ReviewInfo(prID: hidden.prID, phase: .ready(hidden))
            try expectEqual(info.findings.first?.hiddenBy, "Below medium")
            try expectEqual(info.findings.first?.included, false)

            let repo = RepoInfo(config: RepoConfig(owner: "acme", name: "api", ignorePaths: ["dist/**"], mergeMethod: .squash),
                                account: "me")
            try expectEqual(repo.ignorePaths, ["dist/**"])
            try expectEqual(repo.mergeMethod, .squash)

            let rule = Rule(scope: .repo("acme/web"), appliesTo: [.respond, .review], text: "Use React Query",
                            source: .prChat, createdAt: t0)
            let ruleInfo = RuleInfo(rule: rule)
            try expectEqual(ruleInfo.scope, "acme/web")
            try expectEqual(ruleInfo.appliesTo, [.review, .respond])
            try expectEqual(ruleInfo.source, "prChat")
            try expectEqual(RuleInfo.scopeName(.global), "global")
        },
        TestCase("resultados: fases con nombre para la CLI") {
            try expectEqual(ReviewPhase.reviewing(agents: 1).cliDetail, "1 agent")
            try expectEqual(RespondPhase.implementing(done: 1, total: 3).cliName, "implementing")
            try expectEqual(RespondPhase.implementing(done: 1, total: 3).cliDetail, "1/3")
        },
        TestCase("results: PRInfo trae pestaña y sección; StatusInfo viejo se lee sin totales por pestaña") {
            let mine = ClassifiedPR(pr: makePR(number: 6, author: "me"), category: .other, account: "me")
            let info = PRInfo(item: mine, review: nil, respond: nil)
            try expectEqual(info.tab, .mine)
            try expectEqual(info.section, .waitingForReview)
            let old = #"{"appVersion":"1.0.0","refreshing":false,"offline":false,"badgeCount":0,"counts":{},"issues":[],"slackIssues":[],"jobs":[],"accounts":[],"tools":[]}"#
            let status = try CommandProtocol.decoder.decode(StatusInfo.self, from: Data(old.utf8))
            try expectEqual(status.tabCounts, nil)
        },
    ]
}
