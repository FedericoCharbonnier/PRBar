import Foundation
import PRBarCore

private func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private let isolatedGit = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

private func placement(_ ssh: FakeSSH, origin: URL) async throws -> RemotePlacement {
    let host = try ssh.host()
    let info = try await RunnerProbe.check(host)
    return try RemotePlacement(host: host, info: info,
                               gitEnvironment: isolatedGit.merging(["GIT_AUTHOR_NAME": "PRBar Tests", "GIT_AUTHOR_EMAIL": "tests@prbar.invalid",
                                                                    "GIT_COMMITTER_NAME": "PRBar Tests",
                                                                    "GIT_COMMITTER_EMAIL": "tests@prbar.invalid"]) { _, new in new },
                               remoteURLs: { _ in [origin.path] }, originMatches: { _, _ in true })
}

/// Una salida de Claude para la llamada `n` del `claude` de mentira (o para todas, sin `n`).
private func stream(_ ssh: FakeSSH, _ output: [String: Any], call n: Int? = nil, session: String? = nil) throws {
    let name = n.map { "claude-stream-\($0).jsonl" } ?? "claude-stream.jsonl"
    let initLine = session.map { line(["type": "system", "subtype": "init", "session_id": $0]) + "\n" } ?? ""
    try Data((initLine + line(["type": "result", "subtype": "success", "is_error": false, "result": "", "structured_output": output]) + "\n").utf8)
        .write(to: ssh.home.appendingPathComponent(name))
}

/// La próxima corrida de Claude pierde la conexión y el Stop no se puede confirmar (no se puede dejar la lápida):
/// `RemoteRunnerError.jobNotStopped`. `restore` vuelve a dejar escribir en `jobs/`.
private func loseNextClaude(_ ssh: FakeSSH, _ remote: RemotePlacement) throws -> () -> Void {
    try Data("remote-home/bin/claude".utf8).write(to: ssh.dropNext)
    // `jobs/` de solo lectura recién cuando se cae Claude: los git de antes (también trabajos) escriben ahí su pgid.
    try Data(remote.root.jobs.utf8).write(to: URL(fileURLWithPath: ssh.dropNext.path + ".lock"))
    return { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: remote.root.jobs) }
}

private func respondFeedback(_ repo: TempGitRepo) -> PRFeedback {
    PRFeedback(
        headRefName: "feature", headRefOid: repo.prSHA, isCrossRepository: false, lastCommitAt: at(-10),
        threads: [FeedbackItem(id: "thread:A", kind: .thread, path: "feature.txt", line: 1, isOutdated: false,
                               comments: [FeedbackComment(databaseID: 101, author: "ana", isBot: false, body: "Change it", createdAt: t0,
                                                          url: URL(string: "https://github.com/o/r/pull/7#discussion_r101")!)])],
        reviews: [])
}

/// Un `RespondPipeline` en el host falso, con el skill de Respond por defecto instalado allá y el análisis (llamada 1)
/// con un ítem a arreglar.
private func respondPipeline(_ repo: TempGitRepo, _ ssh: FakeSSH, _ remote: RemotePlacement?, workspaceFS: any WorkspaceFS = LocalWorkspaceFS())
    throws -> RespondPipeline {
    let analysis: [String: Any] = ["items": [["id": "thread:A", "assessment": "Right", "action": "fix", "fixPlan": "Change it", "reply": ""]]]
    try stream(ssh, analysis, call: 1)
    try FileManager.default.createDirectory(at: ssh.home.appendingPathComponent(".claude/plugins/cache/m/superpowers/1.0.0/skills"),
                                            withIntermediateDirectories: true)
    return RespondPipeline(
        processRunner: SystemProcessRunner(), streamingRunner: SystemProcessRunner(), tokens: FakeTokens(),
        api: FakeFeedbackAPI(feedback: respondFeedback(repo)), gitPath: "/usr/bin/git", claudePath: "/nonexistent/claude",
        gitEnvironment: isolatedGit, logURLProvider: { _ in ssh.base.appendingPathComponent("respond.log") },
        originMatches: { _, _ in true }, workspaceFS: workspaceFS, placement: remote,
        importer: remote.map {
            RemoteFixImport(spaces: $0.workspaces, localGit: "/usr/bin/git", gitEnvironment: isolatedGit,
                            tempRoot: repo.base.appendingPathComponent("push"), originURL: { _ in repo.origin.path },
                            originMatches: { _, _ in true })
        })
}

private func respondItem() -> ClassifiedPR {
    ClassifiedPR(pr: makePR(repo: RepoRef(owner: "o", name: "r"), number: 7, author: "me"), category: .myFeedback, account: "me")
}

private let fixSelection = RespondSelection(implement: true, fixPlan: "Change it", reply: false, replyText: "")

enum RemoteFlowTests {
    static let cases: [TestCase] = [
        TestCase("remote flow: un review corre en el host (worktree, contexto, claude aislado) y conserva solo el worktree") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let finding: [String: Any] = ["id": "f1", "severity": "high", "file": "feature.txt", "line": 1, "title": "T", "body": "B"]
            try stream(ssh, ["summary": "One issue", "findings": [finding]], session: "1b4e28ba-2fa1-11d2-883f-0016d3cca427")
            let remote = try await placement(ssh, origin: repo.origin)
            var settings = ClaudeSettings()
            settings.filterEnabled = false
            settings.reviewSkill = "review"
            let pipeline = ReviewPipeline(processRunner: SystemProcessRunner(), streamingRunner: SystemProcessRunner(), tokens: FakeTokens(),
                                          api: FakeAPI(), gitPath: "/usr/bin/git", ghPath: nil, claudePath: "/nonexistent/claude",
                                          settings: settings, logURLProvider: { _ in ssh.base.appendingPathComponent("review.log") },
                                          placement: remote)
            let item = ClassifiedPR(pr: makePR(repo: RepoRef(owner: "o", name: "r"), number: 7, base: "main"), category: .toReview, account: "me")
            let draft = try await pipeline.run(ReviewRequest(item: item, localPath: nil, baseRef: "main")) { _ in }
            try expectEqual(draft.headOid, repo.prSHA)
            try expectEqual(draft.summary, "One issue")
            let cwd = try String(contentsOf: ssh.home.appendingPathComponent("claude-calls/1/cwd.txt"), encoding: .utf8)
            try expect(cwd.hasPrefix(remote.root.work + "/"), cwd)
            let args = try String(contentsOf: ssh.home.appendingPathComponent("claude-calls/1/args.bin"), encoding: .utf8)
                .split(separator: "\0").map(String.init)
            try expect(args.contains("--add-dir") && args.contains { $0.hasSuffix(".context") }, "\(args)")
            let prompt = try String(contentsOf: ssh.home.appendingPathComponent("claude-calls/1/prompt.txt"), encoding: .utf8)
            try expect(!prompt.isEmpty && !args.contains(prompt), "el prompt no fue por stdin")
            let kept = try expectSome(draft.retainedLocation)
            try expectEqual(kept.runner, remote.name)
            try expectEqual(URL(fileURLWithPath: kept.directory).lastPathComponent, "r-7-review")
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: remote.root.work),
                            [URL(fileURLWithPath: kept.directory).lastPathComponent])
            let sent = ssh.invocations().flatMap { $0 }.joined()
            try expect(!sent.contains("tok-me"), "un token salió de la Mac")
        },
        TestCase("remote flow: un review en el host dice ' on devbox' en los pasos que corren allá; los de GitHub no") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            try stream(ssh, ["summary": "Fine", "findings": []])
            let remote = try await placement(ssh, origin: repo.origin)
            var settings = ClaudeSettings()
            settings.filterEnabled = false
            settings.reviewSkill = "review"
            let pipeline = ReviewPipeline(processRunner: SystemProcessRunner(), streamingRunner: SystemProcessRunner(), tokens: FakeTokens(),
                                          api: FakeAPI(), gitPath: "/usr/bin/git", ghPath: nil, claudePath: "/nonexistent/claude",
                                          settings: settings, logURLProvider: { _ in ssh.base.appendingPathComponent("review.log") },
                                          placement: remote)
            let item = ClassifiedPR(pr: makePR(repo: RepoRef(owner: "o", name: "r"), number: 7, base: "main"), category: .toReview, account: "me")
            let activities = Box<[JobActivity]>([])
            _ = try await pipeline.run(ReviewRequest(item: item, localPath: nil, baseRef: "main"), onPhase: { _ in },
                                       onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.filter { $0.kind == .prbar }.map(\.text),
                            [JobStep.readingPR, "Creating the PR’s folder on devbox…", "Writing the context for Claude on devbox…"])
        },
        TestCase("remote flow: Respond analiza e implementa en el host, el diff se calcula en la Mac y se pushea desde la Mac") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            try stream(ssh, ["status": "done", "summary": "Changed", "commitMessage": "Change it"], call: 2)
            try Data("printf 'fixed by claude\\n' > feature.txt\n".utf8).write(to: ssh.home.appendingPathComponent("claude-edit-2.sh"))
            let remote = try await placement(ssh, origin: repo.origin)
            let pipeline = try respondPipeline(repo, ssh, remote)
            let draft = try await pipeline.analyze(RespondRequest(item: respondItem(), localPath: repo.local.path, worktreeDir: nil),
                                                   draftID: UUID()) { _ in }
            try expectEqual(draft.runner, "devbox")
            try expectEqual(draft.localPath, repo.local.path)
            try expect(remote.root.contains(draft.worktree.path), draft.worktree.path)
            // La carpeta de contexto del análisis ya no está.
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: remote.root.work).filter { $0.hasSuffix(".respond-context") }, [])
            let result = try await pipeline.implement(draft: draft, selections: [draft.items[0].id: fixSelection]) { _, _ in }
            try expect(result.diff?.contains("+fixed by claude") == true, result.diff ?? "")
            try expectEqual(result.remoteObjects?.repoPath, repo.local.path)
            try expectEqual(result.items.first?.status, .committed)
            try await pipeline.push(draft: draft, result: result)
            let pushed = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(pushed, result.headOid)
            await pipeline.cleanup(draft: draft)
            try expect(!FileManager.default.fileExists(atPath: draft.worktree.path))
            let refs = try TempGitRepo.run(repo.local, ["for-each-ref", "--format=%(refname)", "refs/prbar/"])
            try expectEqual(refs, "")
            let sent = ssh.invocations().flatMap { $0 }.joined()
            try expect(!sent.contains("tok-me"), "un token salió de la Mac")
        },
        TestCase("remote flow: release de un Respond pusheado deja el worktree en el host y borra la copia de la Mac") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            try stream(ssh, ["status": "done", "summary": "Changed", "commitMessage": "Change it"], call: 2)
            try Data("printf 'fixed by claude\\n' > feature.txt\n".utf8).write(to: ssh.home.appendingPathComponent("claude-edit-2.sh"))
            let remote = try await placement(ssh, origin: repo.origin)
            let pipeline = try respondPipeline(repo, ssh, remote)
            let draft = try await pipeline.analyze(RespondRequest(item: respondItem(), localPath: repo.local.path, worktreeDir: nil),
                                                   draftID: UUID()) { _ in }
            let result = try await pipeline.implement(draft: draft, selections: [draft.items[0].id: fixSelection]) { _, _ in }
            try await pipeline.push(draft: draft, result: result)
            try expect(try TempGitRepo.run(repo.local, ["for-each-ref", "--format=%(refname)", "refs/prbar/"]).contains("refs/prbar/remote-"))
            await pipeline.release(draft: draft)
            try expect(FileManager.default.fileExists(atPath: draft.worktree.path))
            try expectEqual(try TempGitRepo.run(repo.local, ["for-each-ref", "--format=%(refname)", "refs/prbar/"]), "")
            await pipeline.cleanup(draft: draft)
            try expect(!FileManager.default.fileExists(atPath: draft.worktree.path))
        },
        TestCase("remote flow: Respond sin carpeta local usa el mirror del host y un clone temporal anotado en WorkspaceRegistry") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            try stream(ssh, ["status": "done", "summary": "Changed", "commitMessage": "Change it"], call: 2)
            try Data("printf 'fixed by claude\\n' > feature.txt\n".utf8).write(to: ssh.home.appendingPathComponent("claude-edit-2.sh"))
            let remote = try await placement(ssh, origin: repo.origin)
            let pipeline = try respondPipeline(repo, ssh, remote)
            let draft = try await pipeline.analyze(RespondRequest(item: respondItem(), localPath: nil, worktreeDir: nil), draftID: UUID()) { _ in }
            try expectEqual(draft.localPath, nil)
            let result = try await pipeline.implement(draft: draft, selections: [draft.items[0].id: fixSelection]) { _, _ in }
            let objects = try expectNotNil(result.remoteObjects)
            try expect(objects.temporary, objects.repoPath)
            try expect(WorkspaceRegistry.shared.contains(objects.repoPath), "Clean Up podría borrar el clone temporal")
            try await pipeline.push(draft: draft, result: result)
            let pushed = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(pushed, result.headOid)
            await pipeline.cleanup(draft: draft)
            try expect(!FileManager.default.fileExists(atPath: objects.repoPath))
            try expect(!WorkspaceRegistry.shared.contains(objects.repoPath))
        },
        TestCase("remote flow: en esta Mac, Respond sin carpeta local falla con el texto del botón") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let pipeline = try respondPipeline(repo, ssh, nil)
            let error = try await expectThrows {
                _ = try await pipeline.analyze(RespondRequest(item: respondItem(), localPath: nil, worktreeDir: nil), draftID: UUID()) { _ in }
            }
            try expectEqual(error.localizedDescription, RespondPipeline.needsLocalPathMessage)
        },
        TestCase("remote flow: la cancelación de un Respond remoto mira el worktree con el WorkspaceFS y el git del host") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let remote = try await placement(ssh, origin: repo.origin)
            let pipeline = try respondPipeline(repo, ssh, remote)
            let draft = try await pipeline.analyze(RespondRequest(item: respondItem(), localPath: repo.local.path, worktreeDir: nil),
                                                   draftID: UUID()) { _ in }
            let worktree = URL(fileURLWithPath: draft.worktree.path)
            try Data("half done\n".utf8).write(to: worktree.appendingPathComponent("feature.txt"))
            try TempGitRepo.run(worktree, ["commit", "-q", "-am", "partial"])
            let cancellation = await pipeline.cancellation(of: draft)
            try expectEqual(cancellation.unpushedCommits, 1)
            try expect(!cancellation.dirty)
            // Sin el host (solo el disco de esta Mac) no se mira: no se sabe.
            let local = try respondPipeline(repo, ssh, nil)
            let unknown = await local.cancellation(of: draft)
            try expectEqual(unknown.unpushedCommits, nil)
            await pipeline.cleanup(draft: draft)
        },
        TestCase("remote flow: si no se confirma que Claude paró, el review deja el worktree y el error lo explica") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let remote = try await placement(ssh, origin: repo.origin)
            let restore = try loseNextClaude(ssh, remote)
            defer { restore() }
            var settings = ClaudeSettings()
            settings.filterEnabled = false
            settings.reviewSkill = "review"
            let pipeline = ReviewPipeline(processRunner: SystemProcessRunner(), streamingRunner: SystemProcessRunner(), tokens: FakeTokens(),
                                          api: FakeAPI(), gitPath: "/usr/bin/git", ghPath: nil, claudePath: "/nonexistent/claude",
                                          settings: settings, logURLProvider: { _ in ssh.base.appendingPathComponent("review.log") },
                                          placement: remote)
            let item = ClassifiedPR(pr: makePR(repo: RepoRef(owner: "o", name: "r"), number: 7, base: "main"), category: .toReview, account: "me")
            let error = try await expectThrows {
                _ = try await pipeline.run(ReviewRequest(item: item, localPath: nil, baseRef: "main")) { _ in }
            }
            try expect(RemoteUnstoppedJobs.isNotStopped(error), "\(error)")
            try expect(error.localizedDescription.contains("Claude may still be running on devbox; PRBar won’t touch that worktree"),
                       error.localizedDescription)
            let left = try FileManager.default.contentsOfDirectory(atPath: remote.root.work)
            try expect(left.contains { !$0.hasSuffix(".context") }, "se borró el worktree: \(left)")
        },
        TestCase("remote flow: si no se confirma que Claude paró en un fix, ni la limpieza de Respond toca el worktree") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let remote = try await placement(ssh, origin: repo.origin)
            let pipeline = try respondPipeline(repo, ssh, remote)
            let draft = try await pipeline.analyze(RespondRequest(item: respondItem(), localPath: repo.local.path, worktreeDir: nil),
                                                   draftID: UUID()) { _ in }
            let restore = try loseNextClaude(ssh, remote)
            defer { restore() }
            let error = try await expectThrows {
                _ = try await pipeline.implement(draft: draft, selections: [draft.items[0].id: fixSelection]) { _, _ in }
            }
            try expectEqual(error as? RemoteRunnerError, .jobNotStopped(host: "devbox"))
            await pipeline.cleanup(draft: draft)
            try expect(FileManager.default.fileExists(atPath: draft.worktree.path), "se borró el worktree")
            let cancellation = await pipeline.cancellation(of: draft)
            try expectEqual(cancellation.unpushedCommits, nil)
        },
        TestCase("remote flow: un turno del chat de Respond en el host usa un índice temporal en <raíz>/tmp y trae el commit a la Mac") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let remote = try await placement(ssh, origin: repo.origin)
            let pipeline = try respondPipeline(repo, ssh, remote)
            let draft = try await pipeline.analyze(RespondRequest(item: respondItem(), localPath: repo.local.path, worktreeDir: nil),
                                                   draftID: UUID()) { _ in }
            try stream(ssh, ["reply": "Done", "actions": []], call: 2)
            try Data("printf 'from the chat\\n' > feature.txt\n".utf8).write(to: ssh.home.appendingPathComponent("claude-edit-2.sh"))
            let service = ChatService(processRunner: SystemProcessRunner(), streamingRunner: SystemProcessRunner(), tokens: FakeTokens(),
                                      api: FakeAPI(), gitPath: "/usr/bin/git", ghPath: nil, claudePath: "/nonexistent/claude",
                                      worktreeRoot: repo.base.appendingPathComponent("wt"), gitEnvironment: isolatedGit,
                                      placement: remote,
                                      importer: RemoteFixImport(spaces: remote.workspaces, localGit: "/usr/bin/git", gitEnvironment: isolatedGit,
                                                                tempRoot: repo.base.appendingPathComponent("push"),
                                                                originURL: { _ in repo.origin.path }, originMatches: { _, _ in true }))
            let session = ChatSession(prID: draft.prID, kind: .respond)
            let workspace = try await service.workspace(ChatWorkspaceRequest(session: session, subject: .respond(draft), pr: makePR(number: 7),
                                                                             localPath: nil))
            try expect(remote.root.contains(workspace.contextDirectory.path), workspace.contextDirectory.path)
            try expect(FileManager.default.fileExists(atPath: workspace.contextDirectory.appendingPathComponent("feedback.json").path))
            let input = ChatTurnInput(kind: .respond, claudeSessionID: nil, bootstrap: "B", message: "m", stateIfChanged: nil,
                                      transcript: [], canEditFiles: true, workingDirectory: workspace.directory,
                                      additionalDirectories: [workspace.contextDirectory], turn: 1, fence: .random())
            let before = RespondResult(items: [], diffStat: "", tests: nil)
            let (output, outcome) = try await service.sendEditing(input, draft: draft, result: before, sessionID: session.id,
                                                                  logURL: repo.base.appendingPathComponent("chat.log")) { _ in }
            try expectEqual(output.reply, "Done")
            let result = try expectNotNil(outcome.result)
            try expect(result.diff?.contains("+from the chat") == true, result.diff ?? "")
            let objects = try expectNotNil(result.remoteObjects)
            try expectEqual(objects.repoPath, repo.local.path)
            // El snapshot usó un índice temporal en <raíz>/tmp (nunca el del worktree), que ya no está.
            let sent = ssh.invocations().flatMap { $0 }.joined()
            try expect(sent.contains("GIT_INDEX_FILE=" + remote.root.tmp + "/prbar-chat-index-"), "sin índice temporal remoto")
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: remote.root.tmp).filter { $0.hasPrefix("prbar-chat-index") }, [])
            let snapshot = try expectNotNil(outcome.snapshot)
            let changedSince = await service.filesChangedSince(draft: draft, snapshot: snapshot)
            try expect(!changedSince)
            // Deshacer vuelve el host y la copia local al commit de antes.
            _ = try await service.undoFiles(draft: draft, snapshot: snapshot, logURL: repo.base.appendingPathComponent("chat.log"))
            let local = try TempGitRepo.run(repo.local, ["rev-parse", objects.ref]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(local, draft.startHeadOid)
            await service.cleanup(session: session, subject: .respond(draft), localPath: nil)
            try expect(!FileManager.default.fileExists(atPath: workspace.contextDirectory.path))
            await pipeline.cleanup(draft: draft)
        },
        TestCase("remote flow: chat de Respond en el host: si el turno o su undo no se pueden traer a la Mac, el host vuelve a como estaba") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let remote = try await placement(ssh, origin: repo.origin)
            let pipeline = try respondPipeline(repo, ssh, remote)
            let draft = try await pipeline.analyze(RespondRequest(item: respondItem(), localPath: repo.local.path, worktreeDir: nil),
                                                   draftID: UUID()) { _ in }
            try stream(ssh, ["reply": "Done", "actions": []])
            for call in [2, 3] {
                try Data("printf 'from the chat\\n' > feature.txt\n".utf8).write(to: ssh.home.appendingPathComponent("claude-edit-\(call).sh"))
            }
            // `importing == false`: traer los commits a la Mac falla (el origin del clone no coincide).
            func service(importing: Bool) -> ChatService {
                ChatService(processRunner: SystemProcessRunner(), streamingRunner: SystemProcessRunner(), tokens: FakeTokens(),
                            api: FakeAPI(), gitPath: "/usr/bin/git", ghPath: nil, claudePath: "/nonexistent/claude",
                            worktreeRoot: repo.base.appendingPathComponent("wt"), gitEnvironment: isolatedGit, placement: remote,
                            importer: RemoteFixImport(spaces: remote.workspaces, localGit: "/usr/bin/git", gitEnvironment: isolatedGit,
                                                      tempRoot: repo.base.appendingPathComponent("push"),
                                                      originURL: { _ in repo.origin.path }, originMatches: { _, _ in importing }))
            }
            let good = service(importing: true)
            let broken = service(importing: false)
            let session = ChatSession(prID: draft.prID, kind: .respond)
            let workspace = try await good.workspace(ChatWorkspaceRequest(session: session, subject: .respond(draft), pr: makePR(number: 7),
                                                                          localPath: nil))
            let worktree = URL(fileURLWithPath: draft.worktree.path, isDirectory: true)
            let head = { try TempGitRepo.run(worktree, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) }
            let clean = { try TempGitRepo.run(worktree, ["status", "--porcelain", "--untracked-files=all"]).isEmpty }
            let start = try head()
            let before = RespondResult(items: [], diffStat: "", tests: nil)
            let log = repo.base.appendingPathComponent("chat.log")
            func input(_ turn: Int) -> ChatTurnInput {
                ChatTurnInput(kind: .respond, claudeSessionID: nil, bootstrap: "B", message: "m", stateIfChanged: nil, transcript: [],
                              canEditFiles: true, workingDirectory: workspace.directory, additionalDirectories: [workspace.contextDirectory],
                              turn: turn, fence: .random())
            }

            // 1. El turno commiteó en el host pero no se pudo traer: se deshace allá (sin Undo que ofrecer).
            let error = try await expectThrows {
                _ = try await broken.sendEditing(input(1), draft: draft, result: before, sessionID: session.id, logURL: log) { _ in }
            }
            try expect(error.localizedDescription.contains("undid"), error.localizedDescription)
            try expectEqual(try head(), start)
            try expect(try clean())
            try expect(!(try String(contentsOf: worktree.appendingPathComponent("feature.txt"), encoding: .utf8)).contains("from the chat"))

            // 2. Un turno que sí se trae; su undo en el host no se puede traer: el host vuelve al turno y Undo sigue valiendo.
            let (_, outcome) = try await good.sendEditing(input(2), draft: draft, result: before, sessionID: session.id, logURL: log) { _ in }
            let snapshot = try expectNotNil(outcome.snapshot)
            let undoError = try await expectThrows { _ = try await broken.undoFiles(draft: draft, snapshot: snapshot, logURL: log) }
            try expect(undoError.localizedDescription.contains("wasn’t undone"), undoError.localizedDescription)
            try expectEqual(try head(), snapshot.headAfter)
            try expect(try clean())
            let changedSince = await good.filesChangedSince(draft: draft, snapshot: snapshot)
            try expect(!changedSince)
            _ = try await good.undoFiles(draft: draft, snapshot: snapshot, logURL: log)
            try expectEqual(try head(), start)
            await good.cleanup(session: session, subject: .respond(draft), localPath: nil)
            await pipeline.cleanup(draft: draft)
        },
        TestCase("remote flow: si no se confirmó que Claude paró en un worktree, ni el chat ni los fixes vuelven a correr ahí") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let remote = try await placement(ssh, origin: repo.origin)
            let pipeline = try respondPipeline(repo, ssh, remote)
            let draft = try await pipeline.analyze(RespondRequest(item: respondItem(), localPath: repo.local.path, worktreeDir: nil),
                                                   draftID: UUID()) { _ in }
            try stream(ssh, ["reply": "Done", "actions": []])
            let service = ChatService(processRunner: SystemProcessRunner(), streamingRunner: SystemProcessRunner(), tokens: FakeTokens(),
                                      api: FakeAPI(), gitPath: "/usr/bin/git", ghPath: nil, claudePath: "/nonexistent/claude",
                                      worktreeRoot: repo.base.appendingPathComponent("wt"), gitEnvironment: isolatedGit, placement: remote)
            let session = ChatSession(prID: draft.prID, kind: .respond)
            let workspace = try await service.workspace(ChatWorkspaceRequest(session: session, subject: .respond(draft), pr: makePR(number: 7),
                                                                             localPath: nil))
            RemoteUnstoppedJobs.shared.insert(host: "devbox", path: draft.worktree.path)
            let input = ChatTurnInput(kind: .respond, claudeSessionID: nil, bootstrap: "B", message: "m", stateIfChanged: nil,
                                      transcript: [], canEditFiles: true, workingDirectory: workspace.directory,
                                      additionalDirectories: [workspace.contextDirectory], turn: 1, fence: .random())
            let log = repo.base.appendingPathComponent("chat.log")
            let before = RespondResult(items: [], diffStat: "", tests: nil)
            let errors = [
                try await expectThrows { _ = try await service.sendEditing(input, draft: draft, result: before, sessionID: session.id, logURL: log) { _ in } },
                try await expectThrows { _ = try await service.send(input, subject: .respond(draft), logURL: log) { _ in } },
                try await expectThrows {
                    let snapshot = ChatFileSnapshot(ref: "refs/prbar/chat-x-1", tree: repo.prSHA, headBefore: repo.prSHA, headAfter: repo.prSHA,
                                                    resultBefore: before)
                    _ = try await service.undoFiles(draft: draft, snapshot: snapshot, logURL: log)
                },
                try await expectThrows { _ = try await pipeline.implement(draft: draft, selections: [draft.items[0].id: fixSelection]) { _, _ in } },
            ]
            for error in errors { try expect(RemoteUnstoppedJobs.isNotStopped(error), error.localizedDescription) }
            // Solo corrió el Claude del análisis.
            try expectEqual(try String(contentsOf: ssh.home.appendingPathComponent("claude-count"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), "1")
            let tests = await pipeline.runTests(draft: draft, testCommand: "true")
            try expect(!tests.passed && tests.outputTail.contains("Claude may still be running"), tests.outputTail)
            // La carpeta de contexto del chat (Claude la puede estar leyendo) queda.
            await service.cleanup(session: session, subject: .respond(draft), localPath: nil)
            try expect(FileManager.default.fileExists(atPath: workspace.contextDirectory.path))
        },
        TestCase("remote flow: el chat de un review prepara su worktree en el host, lo reusa y lo limpia") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let remote = try await placement(ssh, origin: repo.origin)
            let service = ChatService(processRunner: SystemProcessRunner(), streamingRunner: SystemProcessRunner(), tokens: FakeTokens(),
                                      api: FakeAPI(), gitPath: "/usr/bin/git", ghPath: nil, claudePath: "/nonexistent/claude",
                                      worktreeRoot: repo.base.appendingPathComponent("wt"), gitEnvironment: isolatedGit, placement: remote)
            let draft = ReviewDraft(prID: "PR_7", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "PR 7",
                                    url: URL(string: "https://github.com/o/r/pull/7")!, author: "ana", headOid: repo.prSHA,
                                    account: "me", summary: "S", items: [])
            var session = ChatSession(prID: draft.prID, kind: .review)
            let pr = makePR(repo: RepoRef(owner: "o", name: "r"), number: 7, base: "main")
            let workspace = try await service.workspace(ChatWorkspaceRequest(session: session, subject: .review(draft), pr: pr, localPath: nil))
            try expect(workspace.directory.path.hasPrefix(remote.root.work + "/"), workspace.directory.path)
            try expectEqual(workspace.diffFiles, ["feature.txt"])
            try expectEqual(workspace.note, nil)
            try expectEqual(workspace.runner, "devbox")
            session.worktreePath = workspace.directory.path
            session.worktreeRefs = workspace.refs
            let again = try await service.workspace(ChatWorkspaceRequest(session: session, subject: .review(draft), pr: pr, localPath: nil))
            try expectEqual(again, workspace)
            await service.cleanup(session: session, subject: .review(draft), localPath: nil)
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: remote.root.work), [])
        },
        TestCase("remote flow: SSHHost.live usa el id de esta instalación (la raíz es installs/<id>)") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let idFile = ssh.base.appendingPathComponent("support/installation-id")
            let host = try await SSHHost.live(RunnerDestination(name: "devbox", endpoint: SSHEndpoint(host: "devbox")),
                                              sshPath: ssh.executable.path, installationIDFile: idFile,
                                              controlDirectory: ssh.controlDirectory, sshEnvironment: ssh.environment())
            let id = try String(contentsOf: idFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(host.installationID, id)
            try expect(host.enforceHostKey)
            let info = try await RunnerProbe.check(host)
            try expect(info.root?.hasSuffix("/installs/" + id) == true, info.root ?? "sin raíz")
        },
        TestCase("remote flow: Respond en el host: ' on devbox' en el worktree, el contexto y el commit; no en GitHub") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            try stream(ssh, ["status": "done", "summary": "Changed", "commitMessage": "Change it"], call: 2)
            try Data("printf 'fixed by claude\\n' > feature.txt\n".utf8).write(to: ssh.home.appendingPathComponent("claude-edit-2.sh"))
            let remote = try await placement(ssh, origin: repo.origin)
            let pipeline = try respondPipeline(repo, ssh, remote)
            let activities = Box<[JobActivity]>([])
            let draft = try await pipeline.analyze(RespondRequest(item: respondItem(), localPath: repo.local.path, worktreeDir: nil),
                                                   draftID: UUID(), onPhase: { _ in }, onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.filter { $0.kind == .prbar }.map(\.text), [
                JobStep.readingComments, JobStep.readingPR, "Creating the worktree on devbox…", "Writing the context for Claude on devbox…",
            ])
            activities.value = []
            _ = try await pipeline.implement(draft: draft, selections: [draft.items[0].id: fixSelection], onProgress: { _, _ in },
                                             onActivity: { activities.value.append($0) })
            try expect(activities.value.contains { $0.kind == .prbar && $0.text == "Committing on devbox…" },
                       "\(activities.value.map(\.text))")
            await pipeline.cleanup(draft: draft)
        },
    ]
}
