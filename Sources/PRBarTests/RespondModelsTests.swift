import AppKit
import Foundation
import PRBarCore

private let feedbackEpoch = Date(timeIntervalSince1970: 1_700_000_000)

private func comment(_ id: Int, _ author: String, bot: Bool = false, body: String = "texto", at offset: TimeInterval = 0) -> FeedbackComment {
    FeedbackComment(
        databaseID: id, author: author, isBot: bot, body: body, createdAt: feedbackEpoch.addingTimeInterval(offset),
        url: URL(string: "https://github.com/o/r/pull/1#discussion_r\(id)")!)
}

private func thread(_ id: String, resolved: Bool = false, outdated: Bool = false, _ comments: [FeedbackComment]) -> FeedbackItem {
    FeedbackItem(id: "thread:\(id)", kind: .thread, path: "a.swift", line: 3, isOutdated: outdated, isResolved: resolved, comments: comments)
}

private func reviewBody(_ id: Int, _ author: String, bot: Bool = false, body: String = "Revisá esto", state: ReviewState = .changesRequested, at offset: TimeInterval = 100)
    -> (item: FeedbackItem, state: ReviewState, submittedAt: Date) {
    let item = FeedbackItem(
        id: "review:\(id)", kind: .reviewBody, path: nil, line: nil, isOutdated: false,
        comments: [comment(id, author, bot: bot, body: body, at: offset)])
    return (item, state, feedbackEpoch.addingTimeInterval(offset))
}

private func select(
    threads: [FeedbackItem] = [], reviews: [(item: FeedbackItem, state: ReviewState, submittedAt: Date)] = [], lastCommitAt: Date = feedbackEpoch
) -> [String] {
    FeedbackFilter.select(threads: threads, reviewBodies: reviews, me: "me", lastCommitAt: lastCommitAt).map(\.id)
}

private func respondItem(_ action: FeedbackAction) -> RespondItem {
    RespondItem(
        feedback: thread("x", [comment(1, "ana")]), assessment: "ok", action: action, fixPlan: "cambiar X", reply: "Respuesta de Claude")
}

enum RespondModelsTests {
    static let cases: [TestCase] = [
        TestCase("feedback filter: excluye hilos resueltos") {
            try expectEqual(select(threads: [thread("a", resolved: true, [comment(1, "ana")])]), [])
        },
        TestCase("feedback filter: excluye hilos cuyo último comentario es mío o de un bot") {
            let mine = thread("mine", [comment(1, "ana"), comment(2, "me", at: 10)])
            let bot = thread("bot", [comment(3, "ana"), comment(4, "codecov", bot: true, at: 10)])
            let theirs = thread("theirs", [comment(5, "me"), comment(6, "ana", at: 10)])
            try expectEqual(select(threads: [mine, bot, theirs]), ["thread:theirs"])
        },
        TestCase("feedback filter: incluye hilos outdated pero no resueltos, ordenados por fecha") {
            let late = thread("late", [comment(1, "ana", at: 50)])
            let old = thread("old", outdated: true, [comment(2, "ana", at: 5)])
            try expectEqual(select(threads: [late, old]), ["thread:old", "thread:late"])
        },
        TestCase("feedback filter: cuerpos de review vacíos o anteriores al último commit se excluyen") {
            let empty = reviewBody(1, "ana", body: "  \n ")
            let before = reviewBody(2, "ana", at: 10)
            let after = reviewBody(3, "ana", at: 100)
            try expectEqual(select(reviews: [empty, before, after], lastCommitAt: feedbackEpoch.addingTimeInterval(50)), ["review:3"])
        },
        TestCase("feedback filter: excluye reviews APPROVED, de bots y mías; incluye COMMENTED") {
            let approved = reviewBody(1, "ana", state: .approved)
            let bot = reviewBody(2, "copilot", bot: true)
            let mine = reviewBody(3, "me")
            let commented = reviewBody(4, "ana", state: .commented)
            let dismissed = reviewBody(5, "ana", state: .dismissed)
            try expectEqual(select(reviews: [approved, bot, mine, commented, dismissed]), ["review:4"])
        },
        TestCase("feedback filter: hilos primero, después reviews") {
            let ids = select(threads: [thread("a", [comment(1, "ana")])], reviews: [reviewBody(9, "ana")])
            try expectEqual(ids, ["thread:a", "review:9"])
        },
        TestCase("respond selection: valores por defecto según la acción") {
            let fix = RespondSelection.defaults(for: respondItem(.fix))
            try expectEqual(fix, RespondSelection(implement: true, fixPlan: "cambiar X", reply: true, replyText: ""))
            let reply = RespondSelection.defaults(for: respondItem(.reply))
            try expectEqual(reply, RespondSelection(implement: false, fixPlan: "cambiar X", reply: true, replyText: "Respuesta de Claude"))
            let both = RespondSelection.defaults(for: respondItem(.fixAndReply))
            try expectEqual(both, RespondSelection(implement: true, fixPlan: "cambiar X", reply: true, replyText: "Respuesta de Claude"))
            let skip = RespondSelection.defaults(for: respondItem(.skip))
            try expect(!skip.implement && !skip.reply)
        },
        TestCase("respond models: RespondDraft round-trip") {
            let item = respondItem(.fixAndReply)
            let draft = RespondDraft(
                prID: "o/r#1", repo: RepoRef(owner: "o", name: "r"), number: 1, title: "PR", url: URL(string: "https://github.com/o/r/pull/1")!,
                headRef: "feature/x", account: "me", worktree: ResolvedWorktree(path: "/tmp/wt", origin: .created),
                startHeadOid: "abc", items: [item])
            let decoded = try JSONCoding.decoder.decode(RespondDraft.self, from: JSONCoding.encoder.encode(draft))
            try expectEqual(decoded, draft)
            try expectEqual(decoded.items[0].id, "thread:x")
        },
        TestCase("respond models: the draft keeps its language and old drafts without one decode as English") {
            let draft = RespondDraft(
                prID: "o/r#1", repo: RepoRef(owner: "o", name: "r"), number: 1, title: "PR", url: URL(string: "https://github.com/o/r/pull/1")!,
                headRef: "feature/x", account: "me", worktree: ResolvedWorktree(path: "/tmp/wt", origin: .created),
                startHeadOid: "abc", items: [respondItem(.fix)], language: PRLanguage(code: "es"))
            let data = try JSONCoding.encoder.encode(draft)
            try expectEqual(try JSONCoding.decoder.decode(RespondDraft.self, from: data).language, PRLanguage(code: "es"))

            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try expectEqual(object["language"] as? String, "es")
            object.removeValue(forKey: "language")
            let old = try JSONCoding.decoder.decode(RespondDraft.self, from: JSONSerialization.data(withJSONObject: object))
            try expectEqual(old.language, .english)
            try expectEqual(old.id, draft.id)
        },
        TestCase("respond models: reviewer y replyToCommentID") {
            let t = thread("a", [comment(11, "ana"), comment(12, "me", at: 1)])
            try expectEqual(t.reviewer, "ana")
            try expectEqual(t.replyToCommentID, 11)
            try expectEqual(reviewBody(7, "bob").item.replyToCommentID, nil)
        },
        TestCase("respond counts: fixes, respuestas planeadas y pendientes") {
            let items = [
                RespondItem(feedback: thread("a", [comment(1, "ana")]), assessment: "", action: .fix, fixPlan: "p", reply: ""),
                RespondItem(feedback: thread("b", [comment(2, "ana")]), assessment: "", action: .reply, fixPlan: "", reply: "Gracias"),
                RespondItem(feedback: thread("c", [comment(3, "ana")]), assessment: "", action: .reply, fixPlan: "", reply: "  "),
                RespondItem(feedback: thread("d", [comment(4, "ana")]), assessment: "", action: .skip, fixPlan: "", reply: "x"),
            ]
            let draft = RespondDraft(
                prID: "o/r#1", repo: RepoRef(owner: "o", name: "r"), number: 1, title: "PR", url: URL(string: "https://github.com/o/r/pull/1")!,
                headRef: "feature/x", account: "me", worktree: ResolvedWorktree(path: "/tmp/wt", origin: .created),
                startHeadOid: "abc", items: items)
            let selections = Dictionary(uniqueKeysWithValues: items.map { ($0.id, RespondSelection.defaults(for: $0)) })
            try expectEqual(RespondCounts.fixes(draft, selections), 1)
            // a (fix, sin texto → "Arreglado en") + b; c no tiene texto y d no está marcada.
            try expectEqual(RespondCounts.plannedReplies(draft, selections), 2)

            let sha = String(repeating: "a", count: 40)
            var record = RespondRecord(draft: draft, selections: selections, startedAt: Date())
            record.result = RespondResult(items: [ItemResult(id: "thread:a", status: .noChanges, commit: nil, summary: "")], diffStat: "", tests: nil)
            // El fix no cambió nada: sin commit ni texto, a no se publica.
            try expectEqual(RespondCounts.pendingReplies(record), 1)
            try expectEqual(RespondCounts.commits(record.result!), 0)
            record.result = RespondResult(items: [ItemResult(id: "thread:a", status: .committed, commit: sha, summary: "")], diffStat: "", tests: nil)
            try expectEqual(RespondCounts.pendingReplies(record), 2)
            try expectEqual(RespondCounts.commits(record.result!), 1)
            record.posted["thread:b"] = PostedReply(id: "thread:b", url: URL(string: "https://github.com/o/r/pull/1#b")!)
            try expectEqual(RespondCounts.pendingReplies(record), 1)
        },
        TestCase("respond models: los schemas son JSON válido") {
            for schema in [RespondSchemas.analysis, RespondSchemas.fix] {
                try expect((try? JSONSerialization.jsonObject(with: Data(schema.utf8))) != nil)
            }
        },
    ]
}

enum RespondConfirmationTests {
    static let cases: [TestCase] = [
        TestCase("confirmation (M1): Return = Cancel; the action needs a click") { @MainActor in
            let alert = ConfirmAlert.make(title: "Push?", message: "Details", action: "Push and Reply")
            try expectEqual(alert.messageText, "Push?")
            try expectEqual(alert.informativeText, "Details")
            try expectEqual(alert.buttons.map(\.title), ["Cancel", "Push and Reply"])
            try expectEqual(alert.buttons[0].keyEquivalent, "\r")
            try expectEqual(alert.buttons[1].keyEquivalent, "")
            try expect(alert.buttons[1].hasDestructiveAction)
            try expectEqual(ConfirmAlert.confirmed(.alertSecondButtonReturn), true)
            try expectEqual(ConfirmAlert.confirmed(.alertFirstButtonReturn), false)
            try expectEqual(ConfirmAlert.confirmed(.abort), false)
        },
        TestCase("confirmación del push: avisa de los hooks en el worktree de PRBar y del git pull") {
            let text = RespondCopy.pushConfirmation(account: "fede", worktree: "/w/r-7-respond-0a1b2c3d", headRef: "feature/x",
                                                    sha: String(repeating: "a", count: 40))
            for needle in ["@fede", "/w/r-7-respond-0a1b2c3d", "hooks", "aaaaaaaaaaaa", "git pull", "feature/x"] {
                try expect(text.contains(needle), "falta \(needle): \(text)")
            }
            try expect(RespondCopy.ownWorktreeNote.contains("PRBar always uses its own worktree"))
            try expect(RespondCopy.ownWorktreeNote.contains("git pull"))
            // Plain text (alert and footer): no Markdown backticks shown literally.
            try expect(!RespondCopy.ownWorktreeNote.contains("`"))
            try expect(!text.contains("`"))
            try expect(RespondCopy.diffTruncatedNote.contains("diff truncated; review the rest in the worktree"))
        },
    ]
}
