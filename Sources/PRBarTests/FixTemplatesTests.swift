import Foundation
import PRBarCore

private func draft() -> RespondDraft {
    RespondDraft(prID: "P", repo: RepoRef(owner: "acme", name: "web"), number: 42, title: "CSV export",
                 url: URL(string: "https://github.com/acme/web/pull/42")!, headRef: "csv", account: "me",
                 worktree: ResolvedWorktree(path: "/wt", origin: .dedicated), startHeadOid: "", items: [])
}

private func item(_ body: String) -> RespondItem {
    RespondItem(feedback: FeedbackItem(id: "thread:A", kind: .thread, path: "a.ts", line: 1, isOutdated: false,
                                       comments: [FeedbackComment(databaseID: 1, author: "ana", isBot: false, body: body, createdAt: t0,
                                                                  url: URL(string: "https://github.com/acme/web/pull/42")!)]),
                assessment: "ok", action: .fix, fixPlan: "", reply: "")
}

enum FixTemplatesTests {
    static let cases: [TestCase] = [
        TestCase("fix templates: valores de las variables") {
            let values = FixTemplates.values(draft: draft(), item: item("\n  Stream the rows  \nmore"), count: 3,
                                             commit: "abc", summary: "Streamed rows")
            try expectEqual(values, ["n": "3", "pr": "#42", "title": "CSV export", "comment": "Stream the rows",
                                     "commit": "https://github.com/acme/web/commit/abc", "summary": "Streamed rows"])
            let long = FixTemplates.values(draft: draft(), item: item(String(repeating: "x", count: 150)), count: 1)
            try expectEqual(long["comment"]?.count, 101)
            try expectEqual(long["commit"], nil)
        },
        TestCase("fix templates: variables por plantilla y vista previa") {
            try expectEqual(FixTemplateKind.commitMessage.variables.map(\.name), ["n", "pr", "title", "comment"])
            try expectEqual(FixTemplateKind.reply.variables.map(\.name), ["commit", "summary", "pr", "title", "comment"])
            try expectEqual(FixTemplates.preview("Fix {pr} ({n})", kind: .commitMessage), "Fix #123 (2)")
            try expect(FixTemplates.preview("", kind: .commitMessage).contains("Address review feedback (2 comments)"))
            try expectEqual(FixTemplates.preview("  ", kind: .reply), "Fixed in https://github.com/acme/web/commit/1a2b3c4.")
        },
    ]
}
