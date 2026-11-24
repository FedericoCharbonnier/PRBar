import Foundation
import PRBarCore

private func entry(_ number: Int, _ job: RetainedWorktree.Job, dir: String, account: String = "me",
                   runner: String? = nil, superseded: Bool = false) -> RetainedWorktree {
    RetainedWorktree(prID: "o/r#\(number)", account: account, repo: RepoRef(owner: "o", name: "r"), number: number, job: job,
                     recordID: UUID(), location: WorktreeLocation(directory: dir, runner: runner, repository: "/repos/r",
                                                                  refs: ["refs/prbar/pr-\(number)-0a0a0a0a", "refs/prbar/base-\(number)-0a0a0a0a"]),
                     sessions: [], retainedAt: t0, superseded: superseded)
}

enum RetainedWorktreesTests {
    static let cases: [TestCase] = [
        TestCase("carpetas conservadas: un trabajo nuevo del mismo tipo reemplaza la anterior; los otros quedan") {
            let review = entry(7, .review, dir: "/wt/r-7-a")
            let respond = entry(7, .respond, dir: "/repos/r-worktrees/r-7-respond-0a0a0a0a")
            let other = entry(8, .review, dir: "/wt/r-8-a")
            let newer = entry(7, .review, dir: "/wt/r-7-b")
            let (entries, replaced) = RetainedWorktreeRules.retain(newer, in: [review, respond, other])
            try expectEqual(replaced, [review])
            try expectEqual(Set(entries.map(\.location.directory)), ["/wt/r-7-b", "/repos/r-worktrees/r-7-respond-0a0a0a0a", "/wt/r-8-a"])
            // Volver a conservar la misma carpeta no la reemplaza.
            try expectEqual(RetainedWorktreeRules.retain(newer, in: entries).replaced, [])
        },
        TestCase("carpetas conservadas: se borran al mergear o cerrar; abiertas o sin respuesta quedan") {
            let merged = entry(1, .review, dir: "/wt/1")
            let closed = entry(2, .respond, dir: "/wt/2")
            let open = entry(3, .review, dir: "/wt/3")
            let unknown = entry(4, .review, dir: "/wt/4")
            let states: [String: PRDetails.State] = ["o/r#1": .merged, "o/r#2": .closed, "o/r#3": .open]
            try expectEqual(RetainedWorktreeRules.closedOnes([merged, closed, open, unknown], states: states), [merged, closed])
        },
        TestCase("carpetas conservadas: solo se le pregunta a GitHub por PRs fuera de la lista, de repos que respondieron, una vez por hora") {
            let listed = entry(1, .review, dir: "/wt/1")
            let gone = entry(2, .review, dir: "/wt/2")
            let otherAccount = entry(3, .review, dir: "/wt/3", account: "work")
            let scope = Snapshot.scope(account: "me", repo: RepoRef(owner: "o", name: "r"))
            let due = RetainedWorktreeRules.needsStateCheck([listed, gone, otherAccount], listed: ["o/r#1"], fetchedScopes: [scope],
                                                            checkedAt: [:], now: t0)
            try expectEqual(due, [gone])
            try expectEqual(RetainedWorktreeRules.needsStateCheck([gone], listed: [], fetchedScopes: [scope],
                                                                  checkedAt: ["o/r#2": t0.addingTimeInterval(-600)], now: t0), [])
            try expectEqual(RetainedWorktreeRules.needsStateCheck([gone], listed: [], fetchedScopes: [scope],
                                                                  checkedAt: ["o/r#2": t0.addingTimeInterval(-7200)], now: t0), [gone])
        },
        TestCase("carpetas conservadas: lsof con un proceso adentro (cwd) la deja, marcada como reemplazada") {
            let output = "p12\nfcwd\nn/Users/me/wt/r-1\np13\nfcwd\nn/Users/me/wt/r-10/src\n"
            try expect(ProcessCwd.anyInside(["/Users/me/wt/r-1"], lsofOutput: output))
            try expect(ProcessCwd.anyInside(["/Users/me/wt/r-10"], lsofOutput: output))
            try expect(!ProcessCwd.anyInside(["/Users/me/wt/r"], lsofOutput: output))
            try expect(!ProcessCwd.anyInside(["/Users/me/wt/r-2"], lsofOutput: output))

            let busy = entry(1, .review, dir: "/Users/me/wt/r-1")
            let free = entry(2, .review, dir: "/Users/me/wt/r-2")
            let removed = Box<[String]>([])
            let cleaner = RetainedWorktreeCleaner(
                isBusy: { $0.directory == "/Users/me/wt/r-1" },
                remove: { removed.value.append($0.location.directory) })
            let left = await cleaner.removeUnlessBusy([busy, free])
            try expectEqual(removed.value, ["/Users/me/wt/r-2"])
            try expectEqual(left.map(\.location.directory), ["/Users/me/wt/r-1"])
            try expect(left.allSatisfy(\.superseded))
        },
        TestCase("carpetas conservadas: el archivo, ida y vuelta; ilegible = vacío") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = RetainedWorktreeStore(fileURL: dir.appendingPathComponent("retained-worktrees.json"))
            try expectEqual(store.load(), [])
            let entries = [entry(1, .review, dir: "/wt/1"), entry(2, .respond, dir: "/wt/2", runner: "devbox", superseded: true)]
            try store.save(entries)
            try expectEqual(store.load(), entries)
            try Data("{".utf8).write(to: store.fileURL)
            try expectEqual(store.load(), [])
        },
        TestCase("carpetas conservadas: lo que hace falta para borrarlas (review y Respond)") {
            let review = entry(7, .review, dir: "/wt/r-7-1700000000-0a0a0a0a").location
            try expectEqual(review.reviewWorkspace.prRef, "refs/prbar/pr-7-0a0a0a0a")
            try expectEqual(review.reviewWorkspace.baseRef, "refs/prbar/base-7-0a0a0a0a")
            try expect(!review.reviewWorkspace.isDiffOnly)
            let respond = WorktreeLocation(directory: "/repos/r-worktrees/r-7-respond-0a0a0a0a", runner: nil, repository: "/repos/r",
                                           refs: ["refs/prbar/respond-7-0a0a0a0a"])
            try expectEqual(respond.respondWorktree, ResolvedWorktree(path: "/repos/r-worktrees/r-7-respond-0a0a0a0a", origin: .dedicated,
                                                                      localPath: "/repos/r", ref: "refs/prbar/respond-7-0a0a0a0a"))
        },
        TestCase("carpetas conservadas: la limpieza del arranque no toca las conservadas (review y Respond)") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let kept = repo.root.appendingPathComponent("local-7-1700000000-0a0a0a0a")
            let orphan = repo.root.appendingPathComponent("local-7-1700000000-0b0b0b0b")
            let respondDir = repo.base.appendingPathComponent("local-worktrees")
            let keptRespond = respondDir.appendingPathComponent("local-7-respond-0c0c0c0c")
            for url in [kept, orphan, keptRespond] {
                try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", url.path, "HEAD"])
            }
            for ref in ["refs/prbar/pr-7-0a0a0a0a", "refs/prbar/base-7-0a0a0a0a", "refs/prbar/pr-7-0b0b0b0b", "refs/prbar/base-7-0b0b0b0b"] {
                try TempGitRepo.run(repo.local, ["update-ref", ref, "HEAD"])
            }
            let isolated = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
            await WorktreeResolver(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, environment: isolated)
                .cleanupOrphans(localPath: repo.local.path, worktreeDir: respondDir.path, keeping: [keptRespond.path])
            await WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
                .cleanupOrphans(localPaths: [repo.local.path], keeping: [kept.path])
            try expect(FileManager.default.fileExists(atPath: kept.path))
            try expect(FileManager.default.fileExists(atPath: keptRespond.path))
            try expect(!FileManager.default.fileExists(atPath: orphan.path))
            // The kept review folder keeps its two refs (Clean Up needs them to tell the PR's commits from unpushed work).
            let refs = try TempGitRepo.run(repo.local, ["for-each-ref", "--format=%(refname)", "refs/prbar/"])
            try expectEqual(Set(refs.split(whereSeparator: \.isNewline).map(String.init)),
                            ["refs/prbar/pr-7-0a0a0a0a", "refs/prbar/base-7-0a0a0a0a"])
        },
    ]
}
