import Foundation
import PRBarCore

private func draft() -> ReviewDraft {
    func item(_ id: String, keep: Bool = true) -> ReviewItem {
        ReviewItem(finding: ReviewFinding(id: id, severity: .medium, file: "src/a.ts", line: 3, title: "T \(id)", body: "B \(id)"),
                   keep: keep, reason: nil)
    }
    return ReviewDraft(prID: "PR_1", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "PR 7",
                       url: URL(string: "https://github.com/o/r/pull/7")!, author: "ana",
                       headOid: String(repeating: "a", count: 40), account: "me", summary: "S",
                       items: [item("f1"), item("f2"), item("f3", keep: false)])
}

private func respondDraft() -> RespondDraft {
    func item(_ id: String, action: FeedbackAction) -> RespondItem {
        RespondItem(feedback: FeedbackItem(id: id, kind: .thread, path: "a.ts", line: 1, isOutdated: false,
                                           comments: [FeedbackComment(databaseID: 1, author: "ana", isBot: false, body: "x",
                                                                      createdAt: t0, url: URL(string: "https://github.com/o/r/pull/7")!)]),
                    assessment: "ok", action: action, fixPlan: "plan \(id)", reply: "")
    }
    return RespondDraft(prID: "PR_2", repo: RepoRef(owner: "o", name: "r"), number: 8, title: "PR 8",
                        url: URL(string: "https://github.com/o/r/pull/8")!, headRef: "f", account: "me",
                        worktree: ResolvedWorktree(path: "/wt", origin: .dedicated), startHeadOid: "",
                        items: [item("thread:A", action: .reply), item("thread:B", action: .skip)])
}

private let diffFiles: Set<String> = ["src/a.ts", "src/b.ts"]

enum ChatActionsTests {
    static let cases: [TestCase] = [
        TestCase("chat actions: review edits, adds, includes and sets the general comment") {
            let draft = draft()
            let start = ReviewEdits.initial(for: draft)
            let applied = ChatActions.applyReview([
                ChatAction(type: "editFinding", id: "f2", title: "Better\ntitle", body: "Better body"),
                ChatAction(type: "addFinding", title: "Null check", body: "Missing null check", severity: "high",
                           file: "./src/b.ts", line: 9),
                ChatAction(type: "setIncluded", id: "f3", included: true),
                ChatAction(type: "setIncluded", id: "f1", included: false),
                ChatAction(type: "setGeneralComment", text: "  Nice work!  "),
            ], to: start, draft: draft, diffFiles: diffFiles)
            let edits = applied.state
            try expectEqual(edits.titles["f2"], "Better title")
            try expectEqual(edits.bodies["f2"], "Better body")
            try expectEqual(edits.added.map(\.id), ["c1"])
            try expectEqual(edits.added[0].finding.file, "src/b.ts")
            try expectEqual(edits.added[0].finding.severity, .high)
            try expectEqual(edits.added[0].reason, ChatActions.addedReason)
            try expectEqual(edits.selected, ["f2", "f3", "c1"])
            try expectEqual(edits.generalComment, "Nice work!")
            try expectEqual(applied.changes, [.findingEdited(id: "f2"), .findingAdded(id: "c1"),
                                              .findingIncluded(id: "f3", included: true),
                                              .findingIncluded(id: "f1", included: false), .generalCommentEdited])
            try expectEqual(applied.notes, [])
            try expectEqual(edits.number(of: "c1", in: draft), 4)
        },
        TestCase("chat actions: review discards invalid actions with a note and never writes them") {
            let draft = draft()
            let start = ReviewEdits.initial(for: draft)
            let applied = ChatActions.applyReview([
                ChatAction(type: "editFinding", id: "f9", body: "x"),
                ChatAction(type: "editFinding", id: "f1", title: "  ", body: ""),
                ChatAction(type: "addFinding", title: "t", body: "b", severity: "critical", file: "src/a.ts"),
                ChatAction(type: "addFinding", title: "t", body: "b", severity: "low", file: "src/zzz.ts"),
                ChatAction(type: "addFinding", title: "t", body: " ", severity: "low", file: "src/a.ts"),
                ChatAction(type: "addFinding", title: "t", body: "b", severity: "low", file: "src/a.ts", line: 0),
                ChatAction(type: "setIncluded", id: "f1"),
                ChatAction(type: "setGeneralComment"),
                ChatAction(type: "draftReply", body: "hi", commentID: "thread:A"),
                ChatAction(type: "publish"),
            ], to: start, draft: draft, diffFiles: diffFiles)
            try expectEqual(applied.state, start)
            try expectEqual(applied.changes, [])
            try expectEqual(applied.notes.count, 10)
            try expect(applied.notes[0].contains("f9"), applied.notes[0])
            try expect(applied.notes[3].contains("src/zzz.ts"), applied.notes[3])
            try expect(applied.notes[9].contains("publish"), applied.notes[9])
        },
        TestCase("chat actions: two added findings get c1 and c2, also after earlier turns") {
            let draft = draft()
            var start = ReviewEdits.initial(for: draft)
            start.added = [ReviewItem(finding: ReviewFinding(id: "c1", severity: .low, file: "src/a.ts", line: nil, title: "t", body: "b"),
                                      keep: true, reason: ChatActions.addedReason)]
            let add = ChatAction(type: "addFinding", title: "t", body: "b", severity: "low", file: "src/a.ts")
            let applied = ChatActions.applyReview([add, add], to: start, draft: draft, diffFiles: diffFiles)
            try expectEqual(applied.state.added.map(\.id), ["c1", "c2", "c3"])
        },
        TestCase("chat actions: added ids follow ReviewEdits.addedCount, so they're never reused") {
            let draft = draft()
            var start = ReviewEdits.initial(for: draft)
            start.addedCount = 2   // c1 and c2 were added and undone
            let add = ChatAction(type: "addFinding", title: "t", body: "b", severity: "low", file: "src/a.ts")
            let applied = ChatActions.applyReview([add], to: start, draft: draft, diffFiles: diffFiles)
            try expectEqual(applied.state.added.map(\.id), ["c3"])
            try expectEqual(applied.state.addedCount, 3)
            // Older saved state without the counter: it comes from the added ids.
            var object = try JSONSerialization.jsonObject(with: try JSONCoding.encoder.encode(applied.state)) as! [String: Any]
            object["addedCount"] = nil
            let old = try JSONCoding.decoder.decode(ReviewEdits.self, from: try JSONSerialization.data(withJSONObject: object))
            try expectEqual(old.addedCount, 3)
            try expectEqual(old.added, applied.state.added)
        },
        TestCase("chat actions: respond drafts replies and sets implement only before implementing") {
            let draft = respondDraft()
            let start = Dictionary(uniqueKeysWithValues: draft.items.map { ($0.id, RespondSelection.defaults(for: $0)) })
            let applied = ChatActions.applyRespond([
                ChatAction(type: "draftReply", body: "Thanks, fixed!", commentID: "thread:B"),
                ChatAction(type: "setImplement", commentID: "thread:A", implement: true),
                ChatAction(type: "draftReply", body: "  ", commentID: "thread:A"),
                ChatAction(type: "draftReply", body: "x", commentID: "thread:Z"),
                ChatAction(type: "editFinding", id: "f1", body: "x"),
            ], to: start, draft: draft, canSetImplement: true)
            try expectEqual(applied.state["thread:B"]?.reply, true)
            try expectEqual(applied.state["thread:B"]?.replyText, "Thanks, fixed!")
            try expectEqual(applied.state["thread:A"]?.implement, true)
            try expectEqual(applied.state["thread:A"]?.fixPlan, "plan thread:A")
            try expectEqual(applied.changes, [.replyDrafted(commentID: "thread:B"), .implementSet(commentID: "thread:A", implement: true)])
            try expectEqual(applied.notes.count, 3)

            let late = ChatActions.applyRespond([ChatAction(type: "setImplement", commentID: "thread:A", implement: true)],
                                                to: start, draft: draft, canSetImplement: false)
            try expectEqual(late.state, start)
            try expectEqual(late.notes.count, 1)
        },
        TestCase("chat actions: files in the diff come from the +++ lines") {
            let diff = """
            diff --git a/src/a.ts b/src/a.ts
            --- a/src/a.ts
            +++ b/src/a.ts
            @@ -1 +1 @@
            -x
            +y
            diff --git a/old.ts b/old.ts
            --- a/old.ts
            +++ /dev/null
            diff --git a/n.ts b/n.ts
            +++ b/dir/new file.ts\t
            """
            try expectEqual(ChatActions.files(inDiff: diff), ["src/a.ts", "dir/new file.ts"])
        },
        TestCase("chat actions: files in the diff ignore hunk lines and read quoted, binary and renamed paths") {
            let diff = [
                "diff --git a/src/a.ts b/src/a.ts",
                "--- a/src/a.ts",
                "+++ b/src/a.ts",
                "@@ -1,2 +1,2 @@",
                "-x",
                "+++ b/evil.ts",
                "--- a/also-evil.ts",
                " context",
                #"diff --git "a/sp\303\251cial \"q\".ts" "b/sp\303\251cial \"q\".ts""#,
                #"--- "a/sp\303\251cial \"q\".ts""#,
                #"+++ "b/sp\303\251cial \"q\".ts""#,
                "@@ -1 +1 @@",
                "-a",
                "+b",
                "diff --git a/img.png b/img.png",
                "Binary files a/img.png and b/img.png differ",
                "diff --git a/old name.ts b/new name.ts",
                "similarity index 100%",
                "rename from old name.ts",
                "rename to new name.ts",
            ].joined(separator: "\n")
            try expectEqual(ChatActions.files(inDiff: diff), ["src/a.ts", "spécial \"q\".ts", "img.png", "new name.ts"])
        },
        TestCase("chat actions: the summary groups changes and uses #N") {
            let numbers = ["f2": 2, "c1": 4, "f1": 1]
            let summary = ChatActions.summary([.findingEdited(id: "f2"), .findingEdited(id: "f2"), .findingAdded(id: "c1"),
                                               .findingIncluded(id: "f1", included: false), .filesChanged(["a.ts", "b.ts"])]) {
                numbers[$0]
            }
            try expectEqual(summary, "Edited #2, added #4, excluded #1, changed 2 files")
            try expectEqual(ChatActions.summary([.replyDrafted(commentID: "a"), .generalCommentEdited, .filesChanged(["a"]),
                                                 .implementSet(commentID: "b", implement: true)]) { _ in nil },
                            "Edited the general comment, drafted 1 reply, marked 1 fix to implement, changed 1 file")
            try expectEqual(ChatActions.summary([]) { _ in nil }, "")
        },
        TestCase("chat actions: proposeRule da propuestas validadas y no cambia el estado") {
            let draft = draft()
            let start = ReviewEdits.initial(for: draft)
            let actions = [ChatAction(type: "proposeRule", text: "  No style comments. ", scope: "repo", appliesTo: ["review"]),
                           ChatAction(type: "proposeRule", text: "Always ghp_abcdefghijklmnopqrstuvwxyz0123", appliesTo: []),
                           ChatAction(type: "proposeRule", text: "   "),
                           ChatAction(type: "proposeRule", text: "b"), ChatAction(type: "proposeRule", text: "c")]
            let applied = ChatActions.applyReview(actions, to: start, draft: draft, diffFiles: diffFiles)
            try expectEqual(applied.state, start)
            try expectEqual(applied.changes, [])
            try expectEqual(applied.notes, [])
            let (proposals, notes) = ChatActions.proposals(actions, repo: draft.repo, stage: .review)
            try expectEqual(proposals.map(\.text), ["No style comments.", "Always ***", "b"])
            try expectEqual(proposals[0].scope, .repo("o/r"))
            try expectEqual(proposals[1].scope, .global)
            try expectEqual(proposals[1].appliesTo, [.review])
            try expect(proposals.allSatisfy { $0.status == .pending })
            try expectEqual(notes.count, 2)
            try expect(ChatSchemas.turn.contains("\"proposeRule\""))
        },
    ]
}
