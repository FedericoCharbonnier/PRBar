import Foundation
import PRBarCore

private let headOid = String(repeating: "a", count: 40)
private let newerOid = String(repeating: "b", count: 40)

private func reviewDraft() -> ReviewDraft {
    ReviewDraft(prID: "PR_1", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "PR 7",
                url: URL(string: "https://github.com/o/r/pull/7")!, author: "ana", headOid: headOid, account: "me",
                summary: "S", items: [])
}

private func respondDraft(worktree: String) -> RespondDraft {
    RespondDraft(prID: "PR_2", repo: RepoRef(owner: "o", name: "r"), number: 8, title: "PR 8",
                 url: URL(string: "https://github.com/o/r/pull/8")!, headRef: "f", account: "me",
                 worktree: ResolvedWorktree(path: worktree, origin: .dedicated, localPath: worktree), startHeadOid: headOid,
                 items: [RespondItem(feedback: FeedbackItem(id: "thread:A", kind: .thread, path: "a.ts", line: 1, isOutdated: false,
                                                            comments: [FeedbackComment(databaseID: 1, author: "ana", isBot: false, body: "x",
                                                                                       createdAt: t0, url: URL(string: "https://github.com/o/r/pull/8")!)]),
                                     assessment: "ok", action: .reply, fixPlan: "", reply: "r")])
}

private func service(root: URL, runner: ProcessRunning = FakeProcessRunner { _, _ in ok("") }) -> ChatService {
    ChatService(processRunner: runner, streamingRunner: FakeStreamingRunner { _, _, _ in ([], ok("")) }, tokens: FakeTokens(),
                api: FakeAPI(), gitPath: "/usr/bin/git", ghPath: "/usr/local/bin/gh", claudePath: "/usr/local/bin/claude",
                worktreeRoot: root)
}

enum ChatServiceTests {
    static let cases: [TestCase] = [
        TestCase("chat service: Respond escribe feedback.json, pr.md y fixes.diff en su carpeta de contexto") {
            let root = try temporaryDirectory()
            let draft = respondDraft(worktree: "/tmp/wt/r-8")
            let session = ChatSession(prID: draft.prID, kind: .respond)
            let result = RespondResult(items: [], diffStat: "", tests: nil, diff: "+fixed")
            var request = ChatWorkspaceRequest(session: session, subject: .respond(draft), pr: makePR(number: 8),
                                               localPath: nil, respondResult: result)
            let workspace = try await service(root: root).workspace(request)
            try expectEqual(workspace.directory.path, "/tmp/wt/r-8")
            try expect(WorktreeManager.isWorkspaceName(workspace.contextDirectory.lastPathComponent), workspace.contextDirectory.path)
            guard let feedbackURL = workspace.files.feedback else { throw TestFailure(description: "no feedback") }
            let feedback = try String(contentsOf: feedbackURL, encoding: .utf8)
            try expect(feedback.contains("thread:A"))
            try expectEqual(try String(contentsOf: workspace.contextDirectory.appendingPathComponent("fixes.diff"), encoding: .utf8), "+fixed")
            try expect(workspace.files.metadata != nil)
            request.respondResult = nil
            request.pr = nil
            let again = try await service(root: root).workspace(request)
            try expectEqual(again.files.fixesDiff, nil)
            try expectEqual(again.files.metadata, nil)
            try expect(!FileManager.default.fileExists(atPath: workspace.contextDirectory.appendingPathComponent("fixes.diff").path))
        },
        TestCase("chat service: Review reusa el worktree de un turno anterior sin correr git") {
            let root = try temporaryDirectory()
            let directory = root.appendingPathComponent("chat-r-7-\(UUID().uuidString.lowercased())", isDirectory: true)
            let context = root.appendingPathComponent(directory.lastPathComponent + ".context", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
            try Data("+++ b/src/a.ts\n".utf8).write(to: context.appendingPathComponent("pr.diff"))
            var session = ChatSession(prID: "PR_1", kind: .review)
            session.worktreePath = directory.path
            session.worktreeRefs = ["refs/prbar/pr-7-0a1b2c3d", "refs/prbar/base-7-0a1b2c3d"]
            let runner = FakeProcessRunner { _, _ in ok("") }
            let workspace = try await service(root: root, runner: runner)
                .workspace(ChatWorkspaceRequest(session: session, subject: .review(reviewDraft()), pr: nil, localPath: "/repos/r"))
            try expectEqual(workspace.directory, directory)
            try expectEqual(workspace.diffFiles, ["src/a.ts"])
            try expectEqual(workspace.refs, ["refs/prbar/pr-7-0a1b2c3d", "refs/prbar/base-7-0a1b2c3d"])
            try expectEqual(runner.calls.count, 0)
        },
        TestCase("chat service: Review sin el PR en la lista y sin worktree previo no se puede preparar") {
            let error = try await expectThrows {
                _ = try await service(root: try temporaryDirectory())
                    .workspace(ChatWorkspaceRequest(session: ChatSession(prID: "PR_1", kind: .review), subject: .review(reviewDraft()),
                                                    pr: nil, localPath: nil))
            }
            guard case .respond(let message)? = error as? PRBarError else { throw TestFailure(description: "\(error)") }
            try expect(message.contains("no longer"), message)
        },
        TestCase("chat service: Review solo diff crea chat-…-diff con pr.diff y avisa si el PR avanzó") {
            let root = try temporaryDirectory()
            let runner = FakeProcessRunner { executable, arguments in
                guard executable == "/usr/local/bin/gh" else { return fail("unexpected \(executable)") }
                if arguments.contains("view") { return ok(newerOid + "\n") }
                return ok("diff --git a/src/a.ts b/src/a.ts\n+++ b/src/a.ts\n@@ -1 +1 @@\n+x\n")
            }
            let session = ChatSession(prID: "PR_1", kind: .review)
            let workspace = try await service(root: root, runner: runner).workspace(ChatWorkspaceRequest(
                session: session, subject: .review(reviewDraft()), pr: makePR(number: 7, head: newerOid), localPath: nil))
            try expectEqual(workspace.directory.lastPathComponent,
                            WorktreeManager.chatWorkspaceName(repo: RepoRef(owner: "o", name: "r"), number: 7, sessionID: session.id) + "-diff")
            try expect(workspace.isDiffOnly)
            try expectEqual(workspace.diffFiles, ["src/a.ts"])
            try expectEqual(workspace.note, ChatService.olderCommitNote)
            try expect(FileManager.default.fileExists(atPath: workspace.contextDirectory.appendingPathComponent("pr.md").path))
        },
    ]
}
