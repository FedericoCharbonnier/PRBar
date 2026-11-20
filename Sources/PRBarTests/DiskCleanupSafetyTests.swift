import Foundation
import PRBarCore

/// Clean Up contra rutas con symlinks (revisión del plan 13): siempre en carpetas temporales y repos descartables.
private let isolatedGit = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

private func executor(_ repo: TempGitRepo, respondDir: URL, registry: WorkspaceRegistry = WorkspaceRegistry(),
                      worktreeRoots: [URL]? = nil) -> DiskCleanupExecutor {
    DiskCleanupExecutor(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, worktreeRoots: worktreeRoots ?? [repo.root],
                        repos: [DiskScanInput.RespondDir(repo: "acme/local", path: respondDir.path, localPath: repo.local.path)],
                        gitEnvironment: isolatedGit, registry: registry)
}

private func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

enum DiskCleanupSafetyTests {
    static let cases: [TestCase] = [
        TestCase("cleanup: rutas canónicas: el registro reconoce una ruta por un symlink, con otra mayúscula o por el inodo") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let real = base.appendingPathComponent("Real")
            let worktree = real.appendingPathComponent("api-1-respond-0a0a0a0a")
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: real)
            let registry = WorkspaceRegistry()
            registry.insert(worktree.path)   // /var/... (symlink de /private/var)
            try expect(registry.contains(base.appendingPathComponent("link/api-1-respond-0a0a0a0a").path))
            try expect(registry.contains(base.appendingPathComponent("real/api-1-respond-0a0a0a0a").path))
            try expect(registry.contains(CanonicalPath.of(worktree.path)))
            try expect(!registry.contains(base.appendingPathComponent("link/api-2-respond-0a0a0a0a").path))
            registry.remove(base.appendingPathComponent("link/api-1-respond-0a0a0a0a").path)
            try expect(!registry.contains(worktree.path))
        },
        TestCase("disk: un worktree de Responder en curso es activo aunque el worktreeDir configurado sea un symlink") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let real = base.appendingPathComponent("real-worktrees")
            let link = base.appendingPathComponent("web-worktrees")
            let worktree = real.appendingPathComponent("web-2-respond-0a0b0c0d")
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            // Como `WorktreeResolver.prepare`: realpath(base) + nombre.
            let registered = CanonicalPath.of(real.path) + "/web-2-respond-0a0b0c0d"
            let input = DiskScanInput(appSupport: base.appendingPathComponent("AppSupport"), worktreeRoots: [], logsDir: base.appendingPathComponent("Logs"),
                                      respondDirs: [DiskScanInput.RespondDir(repo: "acme/web", path: link.path, localPath: base.appendingPathComponent("web").path)],
                                      activePaths: [registered], now: Date().addingTimeInterval(3600))
            let items = DiskScanner.scan(input).items.filter { $0.kind == .worktrees }
            try expectEqual(items.count, 1)
            try expectEqual(items.first?.state, .active)
            try expectEqual(items.first?.path, registered)
        },
        TestCase("disk: un symlink con nombre de PRBar en una raíz de worktrees no se lista") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let target = base.appendingPathComponent("mine")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let root = base.appendingPathComponent("worktrees")
            let respondDir = base.appendingPathComponent("web-worktrees")
            for dir in [root, respondDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("api-1-1700000000-0d0d0d0d"), withDestinationURL: target)
            try FileManager.default.createSymbolicLink(at: respondDir.appendingPathComponent("web-2-respond-0a0b0c0d"), withDestinationURL: target)
            let input = DiskScanInput(appSupport: base.appendingPathComponent("AppSupport"), worktreeRoots: [root], logsDir: base.appendingPathComponent("Logs"),
                                      respondDirs: [DiskScanInput.RespondDir(repo: "acme/web", path: respondDir.path, localPath: base.appendingPathComponent("web").path)],
                                      activePaths: [], now: Date().addingTimeInterval(3600))
            try expectEqual(DiskScanner.scan(input).items.filter { $0.kind == .worktrees }.map(\.path), [])
        },
        TestCase("cleanup: no borra un worktree de Responder en curso pedido por la ruta del symlink del worktreeDir") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let real = repo.base.appendingPathComponent("real-worktrees")
            let link = repo.base.appendingPathComponent("local-worktrees")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let running = real.appendingPathComponent("local-7-respond-0e0e0e0e")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", running.path, "HEAD"])
            let registry = WorkspaceRegistry()
            registry.insert(CanonicalPath.of(real.path) + "/local-7-respond-0e0e0e0e")
            let viaLink = link.appendingPathComponent("local-7-respond-0e0e0e0e")
            let result = await executor(repo, respondDir: link, registry: registry).run(CleanupPlan(candidates: [
                CleanupCandidate(path: viaLink.path, bytes: 1, kind: .respondWorktree, clone: repo.local.path, title: "running"),
            ]))
            try expectEqual(result.removed, [])
            try expect(result.skipped.first?.contains("in use") == true, "\(result.skipped)")
            try expect(exists(running))
        },
        TestCase("cleanup: un symlink de Responder que apunta a un worktree del usuario se saltea y el worktree sobrevive") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let mine = repo.base.appendingPathComponent("mine")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", mine.path, "HEAD"])
            let dir = repo.base.appendingPathComponent("local-worktrees")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let link = dir.appendingPathComponent("local-7-respond-0c0c0c0c")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: mine)
            let result = await executor(repo, respondDir: dir).run(CleanupPlan(candidates: [
                CleanupCandidate(path: link.path, bytes: 1, kind: .respondWorktree, clone: repo.local.path, title: "link"),
            ]))
            try expectEqual(result.removed, [])
            try expectEqual(result.skipped.count, 1)
            try expect(exists(mine.appendingPathComponent("README.md")))
            try expect(try repo.worktreeNames().contains("mine"))
        },
        TestCase("cleanup: un symlink en la raíz temporal que apunta a un worktree del usuario se saltea y el worktree sobrevive") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let mine = repo.base.appendingPathComponent("mine")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", mine.path, "HEAD"])
            try FileManager.default.createDirectory(at: repo.root, withIntermediateDirectories: true)
            let link = repo.root.appendingPathComponent("api-1-1700000000-0d0d0d0d")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: mine)
            let result = await executor(repo, respondDir: repo.base.appendingPathComponent("local-worktrees")).run(CleanupPlan(candidates: [
                CleanupCandidate(path: link.path, bytes: 1, kind: .workspace, clone: repo.local.path, title: "link"),
            ]))
            try expectEqual(result.removed, [])
            try expectEqual(result.skipped.count, 1)
            try expect(exists(mine.appendingPathComponent("README.md")))
            try expect(try repo.worktreeNames().contains("mine"))
        },
        TestCase("cleanup: .workspace saca un worktree de review del clone configurado (git lo deja de listar)") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            try FileManager.default.createDirectory(at: repo.root, withIntermediateDirectories: true)
            let review = repo.root.appendingPathComponent("local-7-1700000000-0f0f0f0f")
            let diffOnly = repo.root.appendingPathComponent("local-8-1700000000-0f0f0f0f-diff")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", review.path, "HEAD"])
            try FileManager.default.createDirectory(at: diffOnly, withIntermediateDirectories: true)
            let result = await executor(repo, respondDir: repo.base.appendingPathComponent("local-worktrees")).run(CleanupPlan(candidates: [
                CleanupCandidate(path: review.path, bytes: 1, kind: .workspace, clone: nil, title: "review"),
                CleanupCandidate(path: diffOnly.path, bytes: 1, kind: .workspace, clone: nil, title: "diff"),
            ]))
            try expectEqual(result.removed.count, 2)
            try expect(!exists(review) && !exists(diffOnly))
            try expectEqual(try repo.worktreeNames(), ["local"])
        },
        TestCase("cleanup: .workspace saltea un worktree que ningún clone configurado lista") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            try FileManager.default.createDirectory(at: repo.root, withIntermediateDirectories: true)
            let review = repo.root.appendingPathComponent("local-7-1700000000-0f0f0f0f")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", review.path, "HEAD"])
            let other = DiskCleanupExecutor(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, worktreeRoots: [repo.root],
                                            repos: [], gitEnvironment: isolatedGit, registry: WorkspaceRegistry())
            let result = await other.run(CleanupPlan(candidates: [
                CleanupCandidate(path: review.path, bytes: 1, kind: .workspace, clone: repo.local.path, title: "review"),
            ]))
            try expectEqual(result.removed, [])
            try expectEqual(result.skipped.count, 1)
            try expect(exists(review.appendingPathComponent("README.md")))
        },
        TestCase("cleanup: saltea un worktree de Responder con solo cambios sin commitear") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let dir = repo.base.appendingPathComponent("local-worktrees")
            let dirty = dir.appendingPathComponent("local-7-respond-0d0d0d0d")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", dirty.path, "HEAD"])
            try Data("wip\n".utf8).write(to: dirty.appendingPathComponent("README.md"))
            let result = await executor(repo, respondDir: dir).run(CleanupPlan(candidates: [
                CleanupCandidate(path: dirty.path, bytes: 1, kind: .respondWorktree, clone: repo.local.path, title: "dirty"),
            ]))
            try expectEqual(result.removed, [])
            try expect(result.skipped.first?.contains("uncommitted") == true, "\(result.skipped)")
            try expectEqual(try String(contentsOf: dirty.appendingPathComponent("README.md"), encoding: .utf8), "wip\n")
        },
        TestCase("cleanup: saltea un worktree de Responder fuera del worktreeDir de su repo o de un clone que no es el configurado") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let dir = repo.base.appendingPathComponent("local-worktrees")
            let elsewhere = repo.base.appendingPathComponent("elsewhere/local-7-respond-0d0d0d0d")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", elsewhere.path, "HEAD"])
            let result = await executor(repo, respondDir: dir).run(CleanupPlan(candidates: [
                CleanupCandidate(path: elsewhere.path, bytes: 1, kind: .respondWorktree, clone: repo.local.path, title: "elsewhere"),
            ]))
            try expectEqual(result.removed, [])
            try expect(exists(elsewhere.appendingPathComponent("README.md")))
        },
    ]
}
