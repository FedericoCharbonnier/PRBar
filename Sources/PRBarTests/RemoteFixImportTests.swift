import Foundation
import PRBarCore

private let localGitEnvironment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

/// Un worktree de Respond en el host con un commit de "fix", y el import listo para usar.
private func remoteFix() async throws -> (TempGitRepo, FakeSSH, RemoteWorkspaces, ResolvedWorktree, String, RemoteFixImport) {
    let repo = try TempGitRepo.make()
    let (ssh, host, info, root) = try await verifiedFake()
    let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
    let bare = try await spaces.mirror(RepoRef(owner: "o", name: "r"))
    let (worktree, start) = try await spaces.prepareRespond(localPath: bare, repo: RepoRef(owner: "o", name: "r"), number: 7,
                                                            headRef: "feature", worktreeDir: nil, runID: "0a0b0c0d")
    let wt = URL(fileURLWithPath: worktree.path)
    try Data("fixed\n".utf8).write(to: wt.appendingPathComponent("feature.txt"))
    try TempGitRepo.run(wt, ["commit", "-q", "-am", "Fix the thing"])
    let importer = RemoteFixImport(spaces: spaces, localGit: TempGitRepo.git, localRunner: SystemProcessRunner(),
                                   gitEnvironment: localGitEnvironment, tempRoot: repo.base.appendingPathComponent("push"),
                                   originURL: { _ in repo.origin.path }, originMatches: { _, _ in true })
    return (repo, ssh, spaces, worktree, start, importer)
}

private func draft(_ worktree: ResolvedWorktree, start: String) -> RespondDraft {
    RespondDraft(id: UUID(), prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "T",
                 url: URL(string: "https://github.com/o/r/pull/7")!, headRef: "feature", account: "me", worktree: worktree,
                 startHeadOid: start, items: [], language: .english, runner: "devbox")
}

enum RemoteFixImportTests {
    static let cases: [TestCase] = [
        TestCase("remote fixes: el bundle se trae al clone local, se verifica y el diff se calcula en la Mac") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            let result = try await importer.importFixes(draft: draft(worktree, start: start), localPath: repo.local.path,
                                                        items: [], integrity: "x")
            let objects = try expectNotNil(result.remoteObjects)
            try expectEqual(objects.repoPath, repo.local.path)
            try expect(!objects.temporary)
            try expect(result.diff?.contains("+fixed") == true, result.diff ?? "")
            try expectEqual(result.commits?.count, 1)
            let local = try TempGitRepo.run(repo.local, ["rev-parse", objects.ref]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(local, result.headOid)
        },
        TestCase("remote fixes: push verificado desde la Mac; el origin queda en el sha revisado") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            let d = draft(worktree, start: start)
            let result = try await importer.importFixes(draft: d, localPath: repo.local.path, items: [], integrity: "x")
            try await importer.push(draft: d, result: result, token: nil)
            let pushed = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(pushed, result.headOid)
        },
        TestCase("remote fixes: sin localPath usa un clone temporal mínimo y lo borra") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            let d = draft(worktree, start: start)
            let result = try await importer.importFixes(draft: d, localPath: nil, items: [], integrity: "x")
            let objects = try expectNotNil(result.remoteObjects)
            try expect(objects.temporary && objects.repoPath.hasPrefix(repo.base.appendingPathComponent("push").path))
            try await importer.push(draft: d, result: result, token: "ghp_test")
            let pushed = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(pushed, result.headOid)
            await importer.discard(result)
            try expect(!FileManager.default.fileExists(atPath: objects.repoPath))
        },
        TestCase("remote fixes: si el host cambió el commit después de mostrarlo, no se pushea nada") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            let d = draft(worktree, start: start)
            let result = try await importer.importFixes(draft: d, localPath: repo.local.path, items: [], integrity: "x")
            let wt = URL(fileURLWithPath: worktree.path)
            try Data("sneaky\n".utf8).write(to: wt.appendingPathComponent("evil.sh"))
            try TempGitRepo.run(wt, ["add", "-A"])
            try TempGitRepo.run(wt, ["commit", "-q", "-m", "sneaky"])
            let error = try await expectThrows { try await importer.push(draft: d, result: result, token: nil) }
            try expect(error.localizedDescription.contains("Nothing was pushed"), error.localizedDescription)
            let origin = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(origin, start)
        },
        TestCase("remote fixes: un diff mostrado que no es el del árbol traído (o una ref movida) frena el push") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            let d = draft(worktree, start: start)
            let result = try await importer.importFixes(draft: d, localPath: repo.local.path, items: [], integrity: "x")
            var tampered = result
            tampered = RespondResult(items: result.items, diffStat: result.diffStat, tests: nil, sensitiveChanges: result.sensitiveChanges,
                                     headOid: result.headOid, gitIntegrity: result.gitIntegrity, diff: "diff --git a/x b/x\n+benign\n",
                                     diffTruncated: false, commits: result.commits, dependencyChanges: result.dependencyChanges,
                                     remoteObjects: result.remoteObjects)
            let error = try await expectThrows { try await importer.push(draft: d, result: tampered, token: nil) }
            try expect(error.localizedDescription.contains("Nothing was pushed"))
            try TempGitRepo.run(repo.local, ["update-ref", result.remoteObjects!.ref, start])
            _ = try await expectThrows { try await importer.push(draft: d, result: result, token: nil) }
            let origin = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(origin, start)
        },
    ]
}
