import Foundation
import PRBarCore

private func finding(_ id: String, title: String = "Title", body: String = "Body") -> ReviewFinding {
    ReviewFinding(id: id, severity: .medium, file: "src/a.ts", line: 3, title: title, body: body)
}

/// f1 (se mantiene), f2 (descartado por el filtro), f3 (se mantiene). Lo usan también los tests de las Tasks 6 y 7.
func editDraft() -> ReviewDraft {
    let pr = makePR(number: 4)
    return ReviewDraft(prID: pr.id, repo: pr.repo, number: 4, title: pr.title, url: pr.url, author: pr.author,
                       headOid: pr.headOid, account: "me", summary: "s", items: [
                           ReviewItem(finding: finding("f1", body: "one"), keep: true, reason: nil),
                           ReviewItem(finding: finding("f2", body: "two"), keep: false, reason: "not real"),
                           ReviewItem(finding: finding("f3", body: "three"), keep: true, reason: nil),
                       ])
}

/// Dos comentarios: uno de código (Claude propone fix) y uno general (Claude propone responder).
func cliRespondDraft() -> RespondDraft {
    let pr = makePR(number: 9, author: "me")
    let comment = FeedbackComment(databaseID: 1, author: "ana", isBot: false, body: "Fix", createdAt: t0,
                                  url: URL(string: "https://github.com/o/r/pull/9#discussion_r1")!)
    let code = FeedbackItem(id: "thread:A", kind: .thread, path: "a.swift", line: 2, isOutdated: false, comments: [comment])
    let general = FeedbackItem(id: "review:B", kind: .reviewBody, path: nil, line: nil, isOutdated: false, comments: [comment])
    return RespondDraft(prID: pr.id, repo: pr.repo, number: 9, title: pr.title, url: pr.url, headRef: pr.headRef, account: "me",
                        worktree: ResolvedWorktree(path: "/wt", origin: .dedicated), startHeadOid: "abc", items: [
                            RespondItem(feedback: code, assessment: "ok", action: .fix, fixPlan: "plan", reply: ""),
                            RespondItem(feedback: general, assessment: "no", action: .reply, fixPlan: "", reply: "Thanks"),
                        ])
}

enum ReviewEditsCLITests {
    static let cases: [TestCase] = [
        TestCase("review edits cli: un hallazgo por #N o por id, incluidos los que agregó el chat") {
            let draft = editDraft()
            var edits = ReviewEdits.initial(for: draft)
            edits.added = [ReviewItem(finding: finding("c1"), keep: true, reason: nil)]
            try expectEqual(edits.item("2", in: draft)?.id, "f2")
            try expectEqual(edits.item("4", in: draft)?.id, "c1")
            try expectEqual(edits.item("f3", in: draft)?.id, "f3")
            try expectEqual(edits.item("c1", in: draft)?.id, "c1")
            try expectEqual(edits.item("9", in: draft)?.id, nil)
            try expectEqual(edits.item("zz", in: draft)?.id, nil)
        },
        TestCase("review edits cli: texto o título igual al original no cuenta como editado") {
            let draft = editDraft()
            var edits = ReviewEdits.initial(for: draft)
            edits.setBody("one", for: "f1", in: draft)
            edits.setTitle("Title", for: "f1", in: draft)
            try expectEqual(edits.bodies, [:])
            try expectEqual(edits.titles, [:])
            edits.setBody("uno", for: "f1", in: draft)
            edits.setTitle("Better", for: "f1", in: draft)
            try expectEqual(edits.bodies, ["f1": "uno"])
            try expectEqual(edits.items(of: draft)[0].finding.title, "Better")
        },
        TestCase("review edits cli: Select All, --only y comentarios") {
            let draft = editDraft()
            var edits = ReviewEdits.initial(for: draft)
            edits.added = [ReviewItem(finding: finding("c1"), keep: true, reason: nil)]
            edits.selected = ["f2"]
            edits.selectAllKept(in: draft)
            try expectEqual(edits.selected, ["f1", "f2", "f3", "c1"])
            try expectEqual(edits.comments(of: draft, only: ["f3", "f1"]).map(\.finding.id), ["f1", "f3"])
            try expectEqual(edits.comments(of: draft, only: nil).map(\.finding.id), ["f1", "f2", "f3", "c1"])
        },
        TestCase("review edits cli: Select All no suma los ocultos por las opciones del review") {
            let base = editDraft()
            let draft = ReviewDraft(prID: base.prID, repo: base.repo, number: base.number, title: base.title, url: base.url,
                                    author: base.author, headOid: base.headOid, account: base.account, summary: base.summary,
                                    items: [base.items[0], base.items[2].hiding("Below the minimum severity")])
            var edits = ReviewEdits(selected: [])
            edits.selectAllKept(in: draft)
            try expectEqual(edits.selected, ["f1"])
        },
        TestCase("respond cli: un comentario por número o por id") {
            let draft = cliRespondDraft()
            try expectEqual(RespondItemReference.itemID("1", in: draft), "thread:A")
            try expectEqual(RespondItemReference.itemID("review:B", in: draft), "review:B")
            try expectEqual(RespondItemReference.itemID("3", in: draft), nil)
            try expectEqual(RespondItemReference.itemID("thread:Z", in: draft), nil)
        },
    ]
}
