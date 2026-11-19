import Foundation
import PRBarCore

private func finding(_ id: String, title: String = "T", body: String = "B") -> ReviewFinding {
    ReviewFinding(id: id, severity: .medium, file: "src/a.ts", line: 3, title: title, body: body)
}

private func reviewDraft() -> ReviewDraft {
    ReviewDraft(prID: "PR_1", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "PR 7",
                url: URL(string: "https://github.com/o/r/pull/7")!, author: "ana", headOid: String(repeating: "a", count: 40),
                account: "me", summary: "S",
                items: [ReviewItem(finding: finding("f1"), keep: true, reason: "ok"),
                        ReviewItem(finding: finding("f2"), keep: false, reason: "dup")])
}

enum ChatModelsTests {
    static let cases: [TestCase] = [
        TestCase("chat models: ReviewEdits numbers draft findings then added ones and applies titles") {
            let draft = reviewDraft()
            var edits = ReviewEdits.initial(for: draft)
            try expectEqual(edits.selected, ["f1"])
            edits.added = [ReviewItem(finding: finding("c1"), keep: true, reason: ChatActions.addedReason)]
            edits.titles["f2"] = "New title"
            edits.bodies["f1"] = "Edited body"
            let items = edits.items(of: draft)
            try expectEqual(items.map(\.id), ["f1", "f2", "c1"])
            try expectEqual(items[1].finding.title, "New title")
            try expectEqual(edits.number(of: "c1", in: draft), 3)
            try expectEqual(edits.number(of: "zz", in: draft), nil)
            try expectEqual(edits.body(of: items[0]), "Edited body")
            try expect(edits.isEdited(items[0]))
            try expect(edits.isEdited(items[1]))
            edits.selected.insert("c1")
            let comments = edits.selectedComments(of: draft)
            try expectEqual(comments.map(\.finding.id), ["f1", "c1"])
            try expectEqual(comments[0].body, "Edited body")
        },
        TestCase("chat models: the undoable message is the last one with changes not undone") {
            var session = ChatSession(prID: "PR_1", kind: .review)
            try expectEqual(session.undoableMessageID, nil)
            var first = ChatMessage(role: .assistant, text: "a")
            first.changes = [.generalCommentEdited]
            var second = ChatMessage(role: .assistant, text: "b")
            second.changes = [.findingEdited(id: "f1")]
            session.messages = [ChatMessage(role: .user, text: "q"), first, ChatMessage(role: .assistant, text: "no changes"), second]
            try expectEqual(session.undoableMessageID, second.id)
            session.messages[3].undone = true
            try expectEqual(session.undoableMessageID, first.id)
        },
        TestCase("chat models: a pending turn is recovered as Interrupted") {
            var session = ChatSession(prID: "PR_1", kind: .respond)
            session.messages = [ChatMessage(role: .user, text: "q")]
            session.pending = true
            let recovered = session.recovered(now: t0)
            try expectEqual(recovered.pending, false)
            try expectEqual(recovered.messages.last?.role, .error)
            try expectEqual(recovered.messages.last?.text, ChatSession.interruptedText)
            try expectEqual(session.recovered(now: t0).messages.count, 2)
            try expectEqual(recovered.recovered(now: t0), recovered)
        },
        TestCase("chat models: ChatSession decodes leniently and round-trips") {
            let minimal = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","prID":"PR_1","kind":"review"}"#
            let session = try JSONCoding.decoder.decode(ChatSession.self, from: Data(minimal.utf8))
            try expectEqual(session.messages, [])
            try expectEqual(session.readOnly, false)
            try expectEqual(session.claudeSessionID, nil)
            let broken = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","prID":"PR_1","kind":"review","messages":"x","readOnly":3}"#
            try expectEqual(try JSONCoding.decoder.decode(ChatSession.self, from: Data(broken.utf8)).messages, [])
            var full = ChatSession(prID: "PR_1", kind: .respond)
            var message = ChatMessage(role: .assistant, text: "Done", createdAt: t0)
            message.changes = [.replyDrafted(commentID: "thread:A"), .filesChanged(["a.ts"]),
                               .implementSet(commentID: "thread:B", implement: false)]
            message.notes = ["Context rebuilt"]
            message.restore = ChatRestorePoint(selections: [:], selectionsAfter: [:])
            full.messages = [ChatMessage(role: .user, text: "q", createdAt: t0), message]
            full.claudeSessionID = UUID()
            full.worktreePath = "/tmp/wt"
            full.worktreeRefs = ["refs/prbar/pr-7-0a1b2c3d"]
            full.lastState = "{}"
            let data = try JSONCoding.encoder.encode(full)
            try expectEqual(try JSONCoding.decoder.decode(ChatSession.self, from: data), full)
        },
        TestCase("chat models: ReviewDraft and RespondRecord keep the chat; old files decode without it") {
            var draft = reviewDraft()
            try expectEqual(draft.chat, nil)
            try expectEqual(draft.edits, nil)
            draft.chat = ChatSession(prID: "PR_1", kind: .review)
            draft.edits = ReviewEdits.initial(for: draft)
            let decoded = try JSONCoding.decoder.decode(ReviewDraft.self, from: try JSONCoding.encoder.encode(draft))
            try expectEqual(decoded, draft)
            // A broken chat doesn't lose the draft.
            var object = try JSONSerialization.jsonObject(with: try JSONCoding.encoder.encode(draft)) as! [String: Any]
            object["chat"] = "broken"
            let tolerant = try JSONCoding.decoder.decode(ReviewDraft.self, from: try JSONSerialization.data(withJSONObject: object))
            try expectEqual(tolerant.chat, nil)
            try expectEqual(tolerant.items, draft.items)

            let respond = RespondDraft(
                prID: "PR_2", repo: RepoRef(owner: "o", name: "r"), number: 8, title: "PR 8",
                url: URL(string: "https://github.com/o/r/pull/8")!, headRef: "f", account: "me",
                worktree: ResolvedWorktree(path: "/wt", origin: .dedicated), startHeadOid: "", items: [])
            var record = RespondRecord(draft: respond, startedAt: t0)
            record.chat = ChatSession(prID: "PR_2", kind: .respond)
            let encoded = try JSONCoding.encoder.encode(record)
            try expectEqual(try JSONCoding.decoder.decode(RespondRecord.self, from: encoded), record)
            var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            old["chat"] = nil
            try expectEqual(try JSONCoding.decoder.decode(RespondRecord.self, from: try JSONSerialization.data(withJSONObject: old)).chat, nil)
            old["chat"] = 42
            try expectEqual(try JSONCoding.decoder.decode(RespondRecord.self, from: try JSONSerialization.data(withJSONObject: old)).chat, nil)
        },
        TestCase("chat models: the turn schema is valid JSON and lists every action type") {
            let schema = try JSONSerialization.jsonObject(with: Data(ChatSchemas.turn.utf8)) as! [String: Any]
            let properties = schema["properties"] as! [String: Any]
            let actions = (properties["actions"] as! [String: Any])["items"] as! [String: Any]
            let type = (actions["properties"] as! [String: Any])["type"] as! [String: Any]
            try expectEqual(type["enum"] as? [String], ChatAction.allTypes)
        },
    ]
}
