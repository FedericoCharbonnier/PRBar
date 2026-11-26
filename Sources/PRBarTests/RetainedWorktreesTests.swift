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
            var superseded = review
            superseded.superseded = true
            try expectEqual(replaced, [superseded])
            // The replaced one stays in the list, superseded (not offered, still protected), until it's really gone:
            // a quit before its removal mustn't turn it into an orphan.
            try expectEqual(Set(entries.map(\.location.directory)),
                            ["/wt/r-7-a", "/wt/r-7-b", "/repos/r-worktrees/r-7-respond-0a0a0a0a", "/wt/r-8-a"])
            try expectEqual(entries.filter(\.superseded), [superseded])
            // Volver a conservar la misma carpeta no la reemplaza (la vieja sigue pendiente).
            let again = RetainedWorktreeRules.retain(newer, in: entries)
            try expectEqual(again.replaced.map(\.location.directory), ["/wt/r-7-a"])
            try expectEqual(again.entries.filter { !$0.superseded }.map(\.location.directory).sorted(),
                            ["/repos/r-worktrees/r-7-respond-0a0a0a0a", "/wt/r-7-b", "/wt/r-8-a"])
            try expectEqual(again.entries.count, 4)
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
            let dirty = entry(3, .respond, dir: "/Users/me/wt/r-3")
            let stuck = entry(4, .review, dir: "/Users/me/wt/r-4")
            let cleaner = RetainedWorktreeCleaner(
                isBusy: { $0.directory == "/Users/me/wt/r-1" },
                unpushedWork: { $0.directory == "/Users/me/wt/r-3" ? "has uncommitted changes" : nil },
                remove: { entry in
                    removed.value.append(entry.location.directory)
                    return entry.location.directory != "/Users/me/wt/r-4"   // r-4: still on disk afterwards.
                })
            let left = await cleaner.removeUnlessBusy([busy, free, dirty, stuck])
            try expectEqual(removed.value, ["/Users/me/wt/r-2", "/Users/me/wt/r-4"])
            // Una carpeta con trabajo sin pushear tampoco se borra: queda para Clean Up, que la saltea y lo dice. Una
            // que no se pudo borrar (runner caído, git que falla) queda para reintentar al arrancar.
            try expectEqual(left.map(\.location.directory), ["/Users/me/wt/r-1", "/Users/me/wt/r-3", "/Users/me/wt/r-4"])
            try expect(left.allSatisfy(\.superseded))
        },
        TestCase("carpetas conservadas: turning Keep folders for Terminal off removes them safely (busy or dirty ones stay)") {
            let free = entry(1, .review, dir: "/Users/me/wt/r-1")
            let busy = entry(2, .review, dir: "/Users/me/wt/r-2")
            let dirty = entry(3, .respond, dir: "/Users/me/wt/r-3")
            let removed = Box<[String]>([])
            let cleaner = RetainedWorktreeCleaner(
                isBusy: { $0.directory == "/Users/me/wt/r-2" },
                unpushedWork: { $0.directory == "/Users/me/wt/r-3" ? "has 1 unpushed commit" : nil },
                remove: { removed.value.append($0.location.directory); return true })
            var on = AppConfig()
            var off = AppConfig()
            off.setKeepSessionFolders(false)
            // Unchanged or turned on: nothing happens.
            let unchanged = await RetainedWorktreeRules.keepSettingChanged(from: on, to: on, retained: [free], cleaner: cleaner)
            let turnedOn = await RetainedWorktreeRules.keepSettingChanged(from: off, to: on, retained: [free], cleaner: cleaner)
            try expect(unchanged == nil && turnedOn == nil)
            try expectEqual(removed.value, [])
            on.setKeepSessionFolders(true)
            let turnedOff = await RetainedWorktreeRules.keepSettingChanged(from: on, to: off, retained: [free, busy, dirty], cleaner: cleaner)
            let change = try expectSome(turnedOff)
            try expectEqual(removed.value, ["/Users/me/wt/r-1"])
            try expectEqual(change.removed.map(\.location.directory), ["/Users/me/wt/r-1", "/Users/me/wt/r-2", "/Users/me/wt/r-3"])
            try expectEqual(change.left.map(\.location.directory), ["/Users/me/wt/r-2", "/Users/me/wt/r-3"])
            try expect(change.left.allSatisfy(\.superseded))
        },
        TestCase("carpetas conservadas: one on a runner that's no longer in Settings is dropped, not retried forever") {
            let gone = entry(1, .review, dir: "/home/me/work/r-1", runner: "old-box")
            let here = entry(2, .review, dir: "/Users/me/wt/r-2")
            let asked = Box<[String]>([])
            let cleaner = RetainedWorktreeCleaner(
                isBusy: { asked.value.append($0.directory); return true },
                unpushedWork: { _ in nil },
                remove: { _ in true },
                isManaged: { $0.runner != "old-box" })
            let left = await cleaner.removeUnlessBusy([gone, here])
            // Never touched (PRBar no longer manages that machine) and not left for a retry.
            try expectEqual(asked.value, ["/Users/me/wt/r-2"])
            try expectEqual(left.map(\.location.directory), ["/Users/me/wt/r-2"])
        },
        TestCase("carpetas conservadas: en un runner, lsof ve la ruta real aunque la raíz esté bajo un symlink") {
            let script = try ProcessCwd.remoteScript(resolving: ["/home/me/link/work/r-1"])
            try expect(script.contains("'/home/me/link/work/r-1'") && script.contains("pwd -P"), script)
            let output = "prbar-resolved /data/me/work/r-1\np12\nfcwd\nn/data/me/work/r-1/src\n"
            try expect(ProcessCwd.anyInside(["/home/me/link/work/r-1"], remoteOutput: output))
            try expect(!ProcessCwd.anyInside(["/home/me/link/work/r-1"], lsofOutput: output))
            try expect(!ProcessCwd.anyInside(["/home/me/link/work/r-1"], remoteOutput: "prbar-resolved /data/me/work/r-1\np12\nfcwd\nn/data/me/work/r-10\n"))

            // Several folders in one run: one resolved line each, in order (empty when the folder is gone).
            let several = try ProcessCwd.remoteScript(resolving: ["/w/a", "/w/b", "/w/c"])
            try expect(several.contains("'/w/c'"), several)
            let busyOutput = "prbar-resolved /real/a\nprbar-resolved \nprbar-resolved /real/c\np1\nfcwd\nn/real/c/src\np2\nfcwd\nn/w/b\n"
            try expectEqual(ProcessCwd.busyDirectories(["/w/a", "/w/b", "/w/c"], remoteOutput: busyOutput), ["/w/b", "/w/c"])
            // Lines that don't match the folders: can't tell which one, so all count as busy.
            try expectEqual(ProcessCwd.busyDirectories(["/w/a", "/w/b"], remoteOutput: "prbar-resolved /real/a\n"), ["/w/a", "/w/b"])
        },
        TestCase("carpetas conservadas: las refs de una carpeta de review salen de su nombre") {
            try expectEqual(WorktreeManager.reviewRefs(forWorkspaceName: "my-repo-2-7-1700000000-0a0a0a0a"),
                            ["refs/prbar/pr-7-0a0a0a0a", "refs/prbar/base-7-0a0a0a0a"])
            try expectEqual(WorktreeManager.reviewRefs(forWorkspaceName: "r-7-1700000000-0a0a0a0a-diff"), [])
            try expectEqual(WorktreeManager.reviewRefs(forWorkspaceName: "r-7-1700000000-0a0a0a0a.context"), [])
            try expectEqual(WorktreeManager.reviewRefs(forWorkspaceName: "r-7-1700000000"), [])
            try expectEqual(WorktreeManager.reviewRefs(forWorkspaceName: "my-repo-2-7-1700000000"), [])
            try expectEqual(WorktreeManager.reviewRefs(forWorkspaceName: "r-7-respond-0a0a0a0a"), [])
            try expectEqual(WorktreeManager.reviewRefs(forWorkspaceName: "r-7-1700000000-0A0A0A0A"), [])
            let chat = WorktreeManager.chatWorkspaceName(repo: RepoRef(owner: "o", name: "r"), number: 7, sessionID: UUID())
            try expectEqual(WorktreeManager.reviewRefs(forWorkspaceName: chat), [])
        },
        TestCase("carpetas conservadas: el archivo, ida y vuelta; ilegible = vacío") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = RetainedWorktreeStore(fileURL: dir.appendingPathComponent("retained-worktrees.json"))
            try expectEqual(store.load(), [])
            let entries = [entry(1, .review, dir: "/wt/1"), entry(2, .respond, dir: "/wt/2", runner: "devbox", superseded: true)]
            try store.save(entries)
            try expectEqual(store.load(), entries)
            // Una entrada que no se entiende (p. ej. de una versión más nueva) se saltea; las demás quedan.
            let encoded = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(entries)) as! [[String: Any]]
            var unknown = encoded[1]
            unknown["job"] = "somethingNew"
            try JSONSerialization.data(withJSONObject: [encoded[0], unknown]).write(to: store.fileURL)
            try expectEqual(store.load(), [entries[0]])
            // Ilegible: vacío, y el archivo queda aparte (`.corrupt-<fecha>`) en vez de pisarse.
            try Data("{".utf8).write(to: store.fileURL)
            try expectEqual(store.load(), [])
            try expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            try expect(names.contains { $0.hasPrefix("retained-worktrees.json.corrupt-") }, "\(names)")
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
        TestCase("carpetas conservadas: la limpieza del arranque deja un worktree de review con cambios sin commitear") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let dirty = repo.root.appendingPathComponent("local-7-1700000000-0a0a0a0a")
            let clean = repo.root.appendingPathComponent("local-8-1700000000-0b0b0b0b")
            for url in [dirty, clean] {
                try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", url.path, "HEAD"])
            }
            for ref in ["refs/prbar/pr-7-0a0a0a0a", "refs/prbar/base-7-0a0a0a0a", "refs/prbar/pr-8-0b0b0b0b"] {
                try TempGitRepo.run(repo.local, ["update-ref", ref, "HEAD"])
            }
            try Data("wip\n".utf8).write(to: dirty.appendingPathComponent("wip.txt"))
            await WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
                .cleanupOrphans(localPaths: [repo.local.path], keeping: [])
            try expect(FileManager.default.fileExists(atPath: dirty.appendingPathComponent("wip.txt").path))
            try expect(!FileManager.default.fileExists(atPath: clean.path))
            let refs = try TempGitRepo.run(repo.local, ["for-each-ref", "--format=%(refname)", "refs/prbar/"])
            try expectEqual(Set(refs.split(whereSeparator: \.isNewline).map(String.init)),
                            ["refs/prbar/pr-7-0a0a0a0a", "refs/prbar/base-7-0a0a0a0a"])
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
        TestCase("carpetas conservadas: la limpieza del arranque no vacía la raíz de worktrees con trabajo sin pushear") {
            // A review folder of a repo that isn't set up any more (its `worktree list` isn't asked): the last pass
            // that empties the root keeps it if it has work, and removes it when clean.
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let dirty = repo.root.appendingPathComponent("local-7-1700000000-0a0a0a0a")
            let clean = repo.root.appendingPathComponent("local-8-1700000000-0b0b0b0b")
            let diffOnly = repo.root.appendingPathComponent("local-9-1700000000-0c0c0c0c-diff")
            for url in [dirty, clean] {
                try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", url.path, "HEAD"])
            }
            try FileManager.default.createDirectory(at: diffOnly, withIntermediateDirectories: true)
            try Data("wip\n".utf8).write(to: dirty.appendingPathComponent("wip.txt"))
            await WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
                .cleanupOrphans(localPaths: [], keeping: [])
            try expect(FileManager.default.fileExists(atPath: dirty.appendingPathComponent("wip.txt").path))
            try expect(!FileManager.default.fileExists(atPath: clean.path))
            try expect(!FileManager.default.fileExists(atPath: diffOnly.path))
        },
        TestCase("carpetas conservadas: la de review del PR se reemplaza en el lugar y no depende de Keep folders") {
            let first = entry(7, .review, dir: "/wt/r-7-review")
            let second = entry(7, .review, dir: "/wt/r-7-review")   // otra review, la misma carpeta
            let legacy = entry(7, .review, dir: "/wt/r-7-1700000000-0a0a0a0a")
            try expect(second.isReviewFolderPerPR && !legacy.isReviewFolderPerPR)
            let (entries, replaced) = RetainedWorktreeRules.retain(second, in: [legacy, first])
            // La del nombre viejo se reemplaza (la regla de siempre); la del PR no: es la misma carpeta, con el último registro.
            try expectEqual(replaced.map(\.location.directory), ["/wt/r-7-1700000000-0a0a0a0a"])
            try expectEqual(entries.filter { !$0.superseded }.map(\.recordID), [second.recordID])
            // Keep folders off: solo se van las de Respond (y las de review con nombre viejo).
            let removed = Box<[String]>([])
            let cleaner = RetainedWorktreeCleaner(isBusy: { _ in false }, unpushedWork: { _ in nil },
                                                  remove: { removed.value.append($0.location.directory); return true })
            var on = AppConfig()
            on.setKeepSessionFolders(true)
            var off = AppConfig()
            off.setKeepSessionFolders(false)
            let respond = entry(8, .respond, dir: "/repos/r-worktrees/r-8-respond-0a0a0a0a")
            let change = try expectSome(await RetainedWorktreeRules.keepSettingChanged(from: on, to: off, retained: [second, respond],
                                                                                       cleaner: cleaner))
            try expectEqual(change.removed.map(\.location.directory), ["/repos/r-worktrees/r-8-respond-0a0a0a0a"])
            try expectEqual(removed.value, ["/repos/r-worktrees/r-8-respond-0a0a0a0a"])
            // Mergeado o cerrado: se borra como cualquiera.
            try expectEqual(RetainedWorktreeRules.closedOnes([second], states: ["o/r#7": .merged]).map(\.recordID), [second.recordID])
        },
    ]
}
