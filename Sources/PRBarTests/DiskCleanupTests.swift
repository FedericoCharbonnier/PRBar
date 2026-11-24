import Foundation
import PRBarCore

private func item(_ path: String, _ state: DiskItemState, kind: DiskCategoryKind = .worktrees, bytes: Int64 = 100,
                  clone: String? = nil, title: String? = nil) -> DiskItem {
    DiskItem(path: path, bytes: bytes, kind: kind, state: state, repo: nil, clone: clone,
             title: title ?? URL(fileURLWithPath: path).lastPathComponent)
}

enum DiskCleanupTests {
    static let cases: [TestCase] = [
        TestCase("cleanup: el plan solo trae huérfanos y caché del updater; nunca activos ni datos") {
            let usage = DiskUsage(items: [
                item("/w/api-1-1-aaaaaaaa", .active),
                item("/w/api-2-1-bbbbbbbb", .orphan),
                item("/s/source/.build", .cache, kind: .updater, title: "Updater builds"),
                item("/s/update-staging", .cache, kind: .updater, title: "Update staging"),
                item("/s/history", .data, kind: .history),
            ], scannedAt: t0)
            let plan = DiskCleanup.plan(usage: usage, oldFiles: [], updateInProgress: false)
            try expectEqual(plan.candidates.map(\.path), ["/w/api-2-1-bbbbbbbb", "/s/source/.build", "/s/update-staging"])
            try expectEqual(plan.totalBytes, 300)
            let busy = DiskCleanup.plan(usage: usage, oldFiles: [], updateInProgress: true)
            try expectEqual(busy.candidates.map(\.path), ["/w/api-2-1-bbbbbbbb"])
        },
        TestCase("cleanup: al confirmar solo se ejecuta lo que está en el plan nuevo y en el confirmado") {
            let a = CleanupCandidate(path: "/w/a", bytes: 1, kind: .workspace, clone: nil, title: "a")
            let b = CleanupCandidate(path: "/w/b", bytes: 2, kind: .workspace, clone: nil, title: "b")
            let c = CleanupCandidate(path: "/w/c", bytes: 4, kind: .workspace, clone: nil, title: "c")
            let fresh = CleanupPlan(candidates: [a, b, c])
            try expectEqual(fresh.limited(to: ["/w/a", "/w/c", "/w/gone"]).candidates, [a, c])
            try expectEqual(fresh.limited(to: nil), fresh)
            try expectEqual(fresh.limited(to: []).candidates, [])
        },
        TestCase("cleanup: archivos viejos solo si se piden, nunca prbar.log") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let old = base.appendingPathComponent("history/review/old.json")
            let new = base.appendingPathComponent("history/review/new.json")
            let log = base.appendingPathComponent("Logs/prbar.log")
            for url in [old, new, log] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
            let longAgo = Date().addingTimeInterval(-40 * 86_400)
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: log.path)
            let files = DiskCleanup.oldFiles(in: [base.appendingPathComponent("history"), base.appendingPathComponent("Logs")],
                                             olderThanDays: 30, now: Date())
            try expectEqual(files.map(\.path), [old.standardizedFileURL.path])
        },
        TestCase("cleanup: el ejecutor saca un worktree de Responder limpio y saltea uno con commits sin pushear") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let dir = repo.base.appendingPathComponent("local-worktrees")
            let clean = dir.appendingPathComponent("local-7-respond-0a0a0a0a")
            let dirty = dir.appendingPathComponent("local-7-respond-0b0b0b0b")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", clean.path, "HEAD"])
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", dirty.path, "HEAD"])
            try Data("fix\n".utf8).write(to: dirty.appendingPathComponent("fix.txt"))
            try TempGitRepo.run(dirty, ["add", "-A"])
            try TempGitRepo.run(dirty, ["commit", "-q", "-m", "unpushed fix"])
            let plan = CleanupPlan(candidates: [
                CleanupCandidate(path: clean.path, bytes: 1, kind: .respondWorktree, clone: repo.local.path, title: "clean"),
                CleanupCandidate(path: dirty.path, bytes: 1, kind: .respondWorktree, clone: repo.local.path, title: "dirty"),
            ])
            let executor = DiskCleanupExecutor(runner: SystemProcessRunner(), gitPath: TempGitRepo.git,
                                               worktreeRoots: [repo.root],
                                               repos: [DiskScanInput.RespondDir(repo: "acme/local", path: dir.path, localPath: repo.local.path)],
                                               gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                                               registry: WorkspaceRegistry())
            let result = await executor.run(plan)
            try expectEqual(result.removed, [clean.path])
            try expectEqual(result.skipped.count, 1)
            try expect(result.skipped[0].contains("unpushed"), result.skipped[0])
            try expect(FileManager.default.fileExists(atPath: dirty.path))
            try expect(!FileManager.default.fileExists(atPath: clean.path))
            try expectEqual(try repo.worktreeNames().sorted(), ["local", "local-7-respond-0b0b0b0b"])
        },
        TestCase("cleanup: el ejecutor re-verifica y no toca algo que pasó a estar activo ni algo fuera de las raíces") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let root = base.appendingPathComponent("worktrees")
            let busy = root.appendingPathComponent("api-1-1700000000-cccccccc-diff")
            let outside = base.appendingPathComponent("elsewhere/api-1-1700000000-dddddddd-diff")
            for url in [busy, outside] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            let registry = WorkspaceRegistry()
            registry.insert(busy.path)
            let executor = DiskCleanupExecutor(runner: SystemProcessRunner(), gitPath: "/usr/bin/git", worktreeRoots: [root], repos: [],
                                               gitEnvironment: [:], registry: registry)
            let result = await executor.run(CleanupPlan(candidates: [
                CleanupCandidate(path: busy.path, bytes: 1, kind: .workspace, clone: nil, title: "busy"),
                CleanupCandidate(path: outside.path, bytes: 1, kind: .workspace, clone: nil, title: "outside"),
            ]))
            try expectEqual(result.removed, [])
            try expect(FileManager.default.fileExists(atPath: busy.path) && FileManager.default.fileExists(atPath: outside.path))
            try expectEqual(result.skipped.count, 2)
        },
        TestCase("cleanup: una carpeta de review conservada con cambios sin commitear se saltea; limpia se borra") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let clean = repo.root.appendingPathComponent("local-7-1700000000-0a0a0a0a")
            let dirty = repo.root.appendingPathComponent("local-7-1700000000-0b0b0b0b")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", clean.path, "HEAD"])
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", dirty.path, "HEAD"])
            try Data("wip\n".utf8).write(to: dirty.appendingPathComponent("wip.txt"))
            let executor = DiskCleanupExecutor(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, worktreeRoots: [repo.root],
                                               repos: [DiskScanInput.RespondDir(repo: "acme/local", path: repo.base.appendingPathComponent("local-worktrees").path,
                                                                                localPath: repo.local.path)],
                                               retained: [clean.path, dirty.path],
                                               gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                                               registry: WorkspaceRegistry())
            let result = await executor.run(CleanupPlan(candidates: [
                CleanupCandidate(path: clean.path, bytes: 1, kind: .workspace, clone: repo.local.path, title: "clean"),
                CleanupCandidate(path: dirty.path, bytes: 1, kind: .workspace, clone: repo.local.path, title: "dirty"),
            ]))
            try expectEqual(result.removed, [clean.path])
            try expectEqual(result.skipped, ["dirty: has uncommitted changes"])
            try expect(FileManager.default.fileExists(atPath: dirty.path))
        },
        TestCase("cleanup: a leftover review/chat worktree (not kept) with uncommitted or unpushed work is skipped, never deleted") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let dirty = repo.root.appendingPathComponent("local-7-1700000000-0b0b0b0b")
            let committed = repo.root.appendingPathComponent("local-7-1700000000-0c0c0c0c")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", dirty.path, "HEAD"])
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", committed.path, "HEAD"])
            try Data("wip\n".utf8).write(to: dirty.appendingPathComponent("wip.txt"))
            try Data("mine\n".utf8).write(to: committed.appendingPathComponent("mine.txt"))
            try TempGitRepo.run(committed, ["add", "-A"])
            try TempGitRepo.run(committed, ["commit", "-q", "-m", "my work"])
            let executor = DiskCleanupExecutor(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, worktreeRoots: [repo.root],
                                               repos: [DiskScanInput.RespondDir(repo: "acme/local", path: repo.base.appendingPathComponent("local-worktrees").path,
                                                                                localPath: repo.local.path)],
                                               gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                                               registry: WorkspaceRegistry())
            let result = await executor.run(CleanupPlan(candidates: [
                CleanupCandidate(path: dirty.path, bytes: 1, kind: .workspace, clone: repo.local.path, title: "dirty"),
                CleanupCandidate(path: committed.path, bytes: 1, kind: .workspace, clone: repo.local.path, title: "committed"),
            ]))
            try expectEqual(result.removed, [])
            try expectEqual(result.skipped, ["dirty: has uncommitted changes", "committed: has 1 unpushed commit"])
            try expect(FileManager.default.fileExists(atPath: dirty.path) && FileManager.default.fileExists(atPath: committed.path))
        },
        TestCase("cleanup: una carpeta conservada con un proceso adentro (una sesión abierta) se saltea") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let open = repo.root.appendingPathComponent("local-7-1700000000-0a0a0a0a")
            let closed = repo.root.appendingPathComponent("local-7-1700000000-0b0b0b0b")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", open.path, "HEAD"])
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", closed.path, "HEAD"])
            let asked = Box<[String]>([])
            let executor = DiskCleanupExecutor(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, worktreeRoots: [repo.root],
                                               repos: [DiskScanInput.RespondDir(repo: "acme/local", path: repo.base.appendingPathComponent("local-worktrees").path,
                                                                                localPath: repo.local.path)],
                                               retained: [open.path, closed.path],
                                               gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                                               registry: WorkspaceRegistry(),
                                               isBusy: { path in
                                                   asked.value.append(path)
                                                   return path == CanonicalPath.of(open.path)
                                               })
            let result = await executor.run(CleanupPlan(candidates: [
                CleanupCandidate(path: open.path, bytes: 1, kind: .workspace, clone: repo.local.path, title: "open"),
                CleanupCandidate(path: closed.path, bytes: 1, kind: .workspace, clone: repo.local.path, title: "closed"),
            ]))
            try expectEqual(result.removed, [closed.path])
            try expectEqual(result.skipped, ["open: has a process working in it"])
            try expect(FileManager.default.fileExists(atPath: open.path))
            try expectEqual(asked.value.count, 2)
        },
    ]
}
