import Foundation
import PRBarCore

private let repo = RepoRef(owner: "o", name: "r")
/// Para los tests con git real, donde `repo` es el `TempGitRepo`.
private let prRepoRef = repo
private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

private let fixedRunID = "0a1b2c3d"

private func manager(_ runner: FakeProcessRunner, root: URL, randomRunID: Bool = false) -> WorktreeManager {
    if randomRunID {
        return WorktreeManager(runner: runner, gitPath: "/usr/bin/git", root: root, now: { fixedNow })
    }
    return WorktreeManager(runner: runner, gitPath: "/usr/bin/git", root: root, now: { fixedNow }, runID: { fixedRunID })
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Los argumentos de cada llamada sin el prefijo de seguridad, después de comprobar que todas lo tienen:
/// `GitHardening.arguments` (sin hooks, fsmonitor, submódulos ni untracked cache) y el entorno sin LFS ni prompts.
private func gitArgs(_ runner: FakeProcessRunner, file: StaticString = #fileID, line: UInt = #line) throws -> [[String]] {
    try runner.calls.map { call in
        try expectEqual(Array(call.arguments.prefix(12)), [
            "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
            "-c", "submodule.recurse=false", "-c", "core.untrackedCache=false",
            "-c", "maintenance.auto=false", "-c", "gc.auto=0",
        ], file: file, line: line)
        try expectEqual(call.environment?["GIT_LFS_SKIP_SMUDGE"], "1", file: file, line: line)
        try expectEqual(call.environment?["GIT_TERMINAL_PROMPT"], "0", file: file, line: line)
        return Array(call.arguments.dropFirst(12))
    }
}

enum WorktreeTests {
    static let cases: [TestCase] = [
        TestCase("worktree: worktreesDir está fuera de ~/Library (que Claude tiene negado) y el viejo queda para limpiar") {
            let dir = AppPaths.worktreesDir.standardizedFileURL.path
            try expectEqual(AppPaths.worktreesDir.lastPathComponent, "worktrees")
            try expect(dir.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path), dir)
            let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
            try expect(!dir.hasPrefix(library + "/"), dir)
            try expect(AppPaths.legacyWorktreesDir.path.hasSuffix("/Library/Caches/PRBar/worktrees"), AppPaths.legacyWorktreesDir.path)
            try expect(WorktreeManager.isSafeRoot(AppPaths.legacyWorktreesDir))
        },
        TestCase("worktree: prepare con clone local hace fetch a refs propias y worktree --detach") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = gitFake()
            let workspace = try await manager(runner, root: root).prepare(repo: repo, number: 42, baseRef: "develop", localPath: "/repos/r")
            let dir = root.appendingPathComponent("r-42-1700000000-0a1b2c3d", isDirectory: true)
            try expectEqual(runner.calls.map(\.executable), ["/usr/bin/git", "/usr/bin/git", "/usr/bin/git", "/usr/bin/git"])
            try expectEqual(try gitArgs(runner), [
                ["-C", "/repos/r", "fetch", "--no-write-fetch-head", "origin", "+pull/42/head:refs/prbar/pr-42-0a1b2c3d", "+refs/heads/develop:refs/prbar/base-42-0a1b2c3d"],
                ["-C", "/repos/r", "rev-parse", "--verify", "--quiet", "refs/prbar/pr-42-0a1b2c3d^{commit}"],
                ["-C", "/repos/r", "worktree", "add", "--detach", dir.path, "refs/prbar/pr-42-0a1b2c3d"],
                ["-C", dir.path, "ls-files", "-s", "-z"],
            ])
            try expectEqual(runner.calls.map(\.timeout), [120, 10, 120, 120])
            try expectEqual(workspace, ReviewWorkspace(directory: dir, baseRef: "refs/prbar/base-42-0a1b2c3d", prRef: "refs/prbar/pr-42-0a1b2c3d", isDiffOnly: false, headOid: fetchedSHA))
        },
        TestCase("worktree: si el fetch falla, prepare lanza commandFailed y no crea el worktree") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = FakeProcessRunner { _, _ in fail("fatal: couldn't find remote ref pull/42/head\n", status: 128) }
            let error = try await expectThrows {
                _ = try await manager(runner, root: root).prepare(repo: repo, number: 42, baseRef: "develop", localPath: "/repos/r")
            }
            guard case .commandFailed(_, let status, let stderr)? = error as? PRBarError else {
                throw TestFailure(description: "error inesperado: \(error)")
            }
            try expectEqual(status, 128)
            try expectEqual(stderr, "fatal: couldn't find remote ref pull/42/head")
            let args = try gitArgs(runner)
            try expectEqual(args.first?.dropFirst(2).first, "fetch")
            try expect(!args.contains { $0.contains("add") })
            // Un fetch cortado puede haber escrito las refs: se borran igual.
            try expectEqual(Array(args.suffix(2)), [
                ["-C", "/repos/r", "update-ref", "-d", "refs/prbar/pr-42-0a1b2c3d"],
                ["-C", "/repos/r", "update-ref", "-d", "refs/prbar/base-42-0a1b2c3d"],
            ])
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        },
        TestCase("worktree: si worktree add falla, prepare lanza y borra las refs propias") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = gitFake { _, args in args.contains("add") ? fail("fatal: already exists") : ok("") }
            let error = try await expectThrows {
                _ = try await manager(runner, root: root).prepare(repo: repo, number: 42, baseRef: "develop", localPath: "/repos/r")
            }
            guard case .commandFailed(_, _, let stderr)? = error as? PRBarError else {
                throw TestFailure(description: "error inesperado: \(error)")
            }
            try expectEqual(stderr, "fatal: already exists")
            try expectEqual(Array(try gitArgs(runner).suffix(2)), [
                ["-C", "/repos/r", "update-ref", "-d", "refs/prbar/pr-42-0a1b2c3d"],
                ["-C", "/repos/r", "update-ref", "-d", "refs/prbar/base-42-0a1b2c3d"],
            ])
        },
        TestCase("worktree: si rev-parse no devuelve un SHA, prepare lanza y borra las refs propias") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = FakeProcessRunner { _, args in args.contains("rev-parse") ? ok("no-es-un-sha\n") : ok("") }
            let error = try await expectThrows {
                _ = try await manager(runner, root: root).prepare(repo: repo, number: 42, baseRef: "develop", localPath: "/repos/r")
            }
            guard case .invalidResponse? = error as? PRBarError else { throw TestFailure(description: "error inesperado: \(error)") }
            try expect(!runner.calls.contains { $0.arguments.contains("add") })
            try expectEqual(Array(try gitArgs(runner).suffix(2)), [
                ["-C", "/repos/r", "update-ref", "-d", "refs/prbar/pr-42-0a1b2c3d"],
                ["-C", "/repos/r", "update-ref", "-d", "refs/prbar/base-42-0a1b2c3d"],
            ])
        },
        TestCase("worktree: si se cancela a mitad del worktree add, limpia refs y carpeta fuera de la tarea cancelada") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = root.appendingPathComponent("r-42-1700000000-0a1b2c3d", isDirectory: true)
            let started = Box(false)
            let runner = CancellableFakeRunner(
                slow: { $0.contains("add") },
                onSlowStart: { _ in
                    // `worktree add` alcanzó a crear la carpeta antes de que lo cortaran.
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? Data("x".utf8).write(to: dir.appendingPathComponent("half.txt"))
                    started.value = true
                }
            ) { args in args.contains("rev-parse") ? ok(fetchedSHA) : ok("") }
            let m = WorktreeManager(runner: runner, gitPath: "/usr/bin/git", root: root, now: { fixedNow }, runID: { "0a1b2c3d" })
            let task = Task { try await m.prepare(repo: repo, number: 42, baseRef: "develop", localPath: "/repos/r") }
            try await waitUntil { started.value }
            task.cancel()
            let error = try await expectThrows { _ = try await task.value }
            try expect(error is CancellationError, "\(error)")
            let afterAdd = runner.calls.drop { !$0.arguments.contains("add") }.dropFirst()
            try expect(!afterAdd.isEmpty)
            // Ningún git de la limpieza corrió desde la tarea cancelada.
            try expect(afterAdd.allSatisfy { !$0.cancelled }, "\(afterAdd.map(\.arguments))")
            let cleanup = afterAdd.map { Array($0.arguments.dropFirst(GitHardening.arguments.count + 2)) }
            try expect(cleanup.contains(["worktree", "remove", "--force", dir.path]), "\(cleanup)")
            try expect(cleanup.contains(["update-ref", "-d", "refs/prbar/pr-42-0a1b2c3d"]), "\(cleanup)")
            try expect(cleanup.contains(["update-ref", "-d", "refs/prbar/base-42-0a1b2c3d"]), "\(cleanup)")
            try expect(!exists(dir), "quedó la carpeta a medio crear")
        },
        TestCase("worktree: prepare sin clone crea una carpeta -diff vacía y no corre git") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = FakeProcessRunner { _, _ in ok("") }
            let workspace = try await manager(runner, root: root).prepare(repo: repo, number: 7, baseRef: "main", localPath: nil)
            let dir = root.appendingPathComponent("r-7-1700000000-0a1b2c3d-diff", isDirectory: true)
            try expectEqual(runner.calls.count, 0)
            try expectEqual(workspace, ReviewWorkspace(directory: dir, baseRef: nil, isDiffOnly: true))
            try expect(exists(dir))
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        },
        TestCase("worktree: cleanup sigue aunque fallen los comandos y borra la carpeta") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = root.appendingPathComponent("r-42-1700000000-0a1b2c3d", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("file.txt"))
            let runner = FakeProcessRunner { _, _ in fail("boom") }
            let workspace = ReviewWorkspace(directory: dir, baseRef: "refs/prbar/base-42-0a1b2c3d", prRef: "refs/prbar/pr-42-0a1b2c3d", isDiffOnly: false)
            try FileManager.default.createDirectory(at: workspace.contextDirectory, withIntermediateDirectories: true)
            try Data("diff".utf8).write(to: workspace.diffFile)
            await manager(runner, root: root).cleanup(workspace, localPath: "/repos/r")
            // Si `worktree remove` falla, se borra la carpeta y se busca su carpeta de administración; nunca prune.
            try expectEqual(try gitArgs(runner), [
                ["-C", "/repos/r", "worktree", "remove", "--force", dir.path],
                ["-C", "/repos/r", "rev-parse", "--git-common-dir"],
                ["-C", "/repos/r", "update-ref", "-d", "refs/prbar/pr-42-0a1b2c3d"],
                ["-C", "/repos/r", "update-ref", "-d", "refs/prbar/base-42-0a1b2c3d"],
            ])
            try expectEqual(runner.calls.map(\.timeout), [10, 10, 10, 10])
            try expect(!exists(dir))
            try expect(!exists(workspace.contextDirectory))
            try expect(exists(root))
        },
        TestCase("worktree: cleanup de modo diff solo borra la carpeta") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = FakeProcessRunner { _, _ in ok("") }
            let m = manager(runner, root: root)
            let workspace = try await m.prepare(repo: repo, number: 7, baseRef: "main", localPath: nil)
            try FileManager.default.createDirectory(at: workspace.contextDirectory, withIntermediateDirectories: true)
            await m.cleanup(workspace, localPath: nil)
            try expectEqual(runner.calls.count, 0)
            try expect(!exists(workspace.directory))
            try expect(!exists(workspace.contextDirectory))
        },
        TestCase("worktree: cleanup no toca carpetas fuera de root") {
            let root = try temporaryDirectory()
            let outside = try temporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outside)
            }
            let runner = FakeProcessRunner { _, _ in ok("") }
            let workspace = ReviewWorkspace(directory: outside, baseRef: "refs/prbar/base-42-0a1b2c3d", prRef: "refs/prbar/pr-42-0a1b2c3d", isDiffOnly: false)
            await manager(runner, root: root).cleanup(workspace, localPath: "/repos/r")
            try expect(exists(outside))
            try expect(!runner.calls.contains { $0.arguments.contains("remove") })
            try expectEqual(try gitArgs(runner).map { $0.last ?? "" }, ["refs/prbar/pr-42-0a1b2c3d", "refs/prbar/base-42-0a1b2c3d"])
        },
        TestCase("worktree: cleanupOrphans vacía root y borra las refs refs/prbar en cada clone") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            for name in ["r-1-1700000000", "r-1-1700000000.context", "other-2-1700000001-diff", "other-2-1700000001-diff.context",
                         "r-1-1700000000-0a1b2c3d", "r-1-1700000000-0a1b2c3d.context", "my-repo-3-1700000002-ffff0000-diff"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            let runner = FakeProcessRunner { _, args in
                guard args.contains("for-each-ref") else { return ok("") }
                return args.contains("/repos/a") ? ok("refs/prbar/pr-1\nrefs/prbar/base-1\nrefs/heads/main\n") : ok("")
            }
            await manager(runner, root: root).cleanupOrphans(localPaths: ["/repos/a", "/repos/b"], keeping: [])
            try expectEqual(try gitArgs(runner), [
                ["-C", "/repos/a", "worktree", "list", "--porcelain"],
                ["-C", "/repos/a", "for-each-ref", "--format=%(refname)", "refs/prbar/"],
                ["-C", "/repos/a", "update-ref", "-d", "refs/prbar/pr-1"],
                ["-C", "/repos/a", "update-ref", "-d", "refs/prbar/base-1"],
                ["-C", "/repos/b", "worktree", "list", "--porcelain"],
                ["-C", "/repos/b", "for-each-ref", "--format=%(refname)", "refs/prbar/"],
            ])
            try expect(exists(root))
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        },
        TestCase("worktree: cleanupOrphans solo borra entradas con nombre de worktree de PRBar") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("r-1-1700000000"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
            await manager(FakeProcessRunner { _, _ in ok("") }, root: root).cleanupOrphans(localPaths: [], keeping: [])
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Documents"])
        },
        TestCase("worktree: el id de corrida son 8 caracteres hexadecimales y cambia en cada prepare") {
            let ids = (0..<20).map { _ in WorktreeManager.newRunID() }
            for id in ids {
                try expect(id.count == 8 && id.allSatisfy { "0123456789abcdef".contains($0) }, id)
            }
            try expect(Set(ids).count > 1)
        },
        TestCase("worktree: isWorkspaceName reconoce los nombres con y sin id de corrida") {
            for name in ["r-1-1700000000", "r-1-1700000000-0a1b2c3d", "r-1-1700000000-0a1b2c3d-diff", "r-1-1700000000-0a1b2c3d.context",
                         "my-repo-12-1700000000-deadbeef-diff.context", "r-1-1700000000-diff",
                         // Carpetas de contexto de Responder: `<owner>-<repo>-<N>-<UUID>.respond-context`.
                         "o-r-7-1F2E3D4C-5B6A-7980-A1B2-C3D4E5F60718.respond-context",
                         "my-org-my-repo-12-1F2E3D4C-5B6A-7980-A1B2-C3D4E5F60718.respond-context"] {
                try expect(WorktreeManager.isWorkspaceName(name), name)
            }
            for name in ["Documents", "r-1", "r-1-0a1b2c3d", "1-1700000000", "r-1-1700000000-XYZ12345", "r-x-1700000000-0a1b2c3d",
                         "notes.respond-context", "o-r-x-1F2E3D4C-5B6A-7980-A1B2-C3D4E5F60718.respond-context",
                         "o-r-7-not-a-uuid.respond-context"] {
                try expect(!WorktreeManager.isWorkspaceName(name), name)
            }
        },
        TestCase("worktree: dos corridas del mismo PR usan refs y carpetas distintas y no se pisan al limpiar") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = gitFake()
            let m = manager(runner, root: root, randomRunID: true)
            // Las dos corridas en paralelo, con la misma hora (now fijo).
            async let first = m.prepare(repo: repo, number: 42, baseRef: "develop", localPath: "/repos/r")
            async let second = m.prepare(repo: repo, number: 42, baseRef: "develop", localPath: "/repos/r")
            let (a, b) = try await (first, second)
            try expect(a.directory != b.directory, a.directory.path)
            try expect(a.prRef != b.prRef && a.baseRef != b.baseRef)
            for ws in [a, b] {
                try expect(ws.prRef?.hasPrefix("refs/prbar/pr-42-") == true, "\(ws.prRef ?? "nil")")
                try expect(ws.baseRef?.hasPrefix("refs/prbar/base-42-") == true, "\(ws.baseRef ?? "nil")")
                try expect(WorktreeManager.isWorkspaceName(ws.directory.lastPathComponent), ws.directory.path)
                try FileManager.default.createDirectory(at: ws.directory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: ws.contextDirectory, withIntermediateDirectories: true)
            }
            try expect(a.contextDirectory != b.contextDirectory)

            let before = runner.calls.count
            await m.cleanup(a, localPath: "/repos/r")
            let cleanupArgs = runner.calls.dropFirst(before).map { Array($0.arguments.dropFirst(2)) }
            // La limpieza de la primera solo toca lo suyo.
            try expect(!exists(a.directory) && !exists(a.contextDirectory))
            try expect(exists(b.directory) && exists(b.contextDirectory))
            for args in cleanupArgs {
                try expect(!args.contains(b.prRef!) && !args.contains(b.baseRef!) && !args.contains(b.directory.path), "\(args)")
            }
            try expect(cleanupArgs.contains { $0.contains(a.prRef!) } && cleanupArgs.contains { $0.contains(a.baseRef!) })
            await m.cleanup(b, localPath: "/repos/r")
            try expect(!exists(b.directory))
        },
        TestCase("worktree: worktreePaths lee las rutas de git worktree list --porcelain") {
            let output = """
            worktree /repos/r
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/main

            worktree /Volumes/Externo/r-feature
            HEAD 2222222222222222222222222222222222222222
            detached
            prunable gitdir file points to non-existent location

            worktree /Users/me/Library/Caches/PRBar/worktrees/r-7-1700000000-0a1b2c3d
            HEAD 3333333333333333333333333333333333333333
            detached

            """
            try expectEqual(WorktreeManager.worktreePaths(fromPorcelain: output), [
                "/repos/r", "/Volumes/Externo/r-feature", "/Users/me/Library/Caches/PRBar/worktrees/r-7-1700000000-0a1b2c3d",
            ])
        },
        TestCase("worktree: cleanupOrphans con un fake solo saca los worktrees dentro de root y nunca hace prune") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let ours = root.appendingPathComponent("r-1-1700000000-0a1b2c3d")
            try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)
            let list = "worktree /repos/a\nHEAD 1\n\nworktree /Volumes/Externo/mio\nHEAD 2\nprunable x\n\nworktree \(ours.path)\nHEAD 3\n"
            // Clean: `status` says nothing and no commit is unpushed.
            let runner = FakeProcessRunner { _, args in args.contains("list") ? ok(list) : args.contains("rev-list") ? ok("0\n") : ok("") }
            await manager(runner, root: root).cleanupOrphans(localPaths: ["/repos/a"], keeping: [])
            let args = try gitArgs(runner)
            try expect(!args.contains { $0.contains("prune") }, "\(args)")
            try expectEqual(args.filter { $0.contains("remove") }, [["-C", "/repos/a", "worktree", "remove", "--force", ours.path]])
        },
        TestCase("worktree (git real): prepare trae el PR y cleanup saca solo su worktree, sin podar los del usuario") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            // Un worktree del usuario en un disco que ya no está montado: git lo marca como "prunable".
            let userWorktree = repo.base.appendingPathComponent("volumen/mio")
            try TempGitRepo.run(repo.local, ["worktree", "add", "-q", "--detach", userWorktree.path, "main"])
            try FileManager.default.removeItem(at: repo.base.appendingPathComponent("volumen"))

            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let ws = try await m.prepare(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            try expectEqual(ws.headOid, repo.prSHA)
            try expect(exists(ws.directory.appendingPathComponent("feature.txt")))
            try expectEqual(try repo.worktreeNames().count, 3)

            await m.cleanup(ws, localPath: repo.local.path)
            try expect(!exists(ws.directory))
            try expectEqual(try repo.worktreeNames().sorted(), ["local", "mio"])
            try expectEqual(try repo.prbarRefs(), [])
        },
        TestCase("worktree (git real): si la carpeta ya no está, cleanup borra solo su carpeta de administración") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let userWorktree = repo.base.appendingPathComponent("volumen/mio")
            try TempGitRepo.run(repo.local, ["worktree", "add", "-q", "--detach", userWorktree.path, "main"])
            try FileManager.default.removeItem(at: repo.base.appendingPathComponent("volumen"))

            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let ws = try await m.prepare(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            try FileManager.default.removeItem(at: ws.directory)
            await m.cleanup(ws, localPath: repo.local.path)
            try expectEqual(try repo.worktreeNames().sorted(), ["local", "mio"])
            let admin = repo.local.appendingPathComponent(".git/worktrees")
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: admin.path), ["mio"])
        },
        TestCase("worktree (git real): cleanupOrphans saca los worktrees de PRBar (vivos o perdidos) y deja los del usuario") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let userWorktree = repo.base.appendingPathComponent("volumen/mio")
            try TempGitRepo.run(repo.local, ["worktree", "add", "-q", "--detach", userWorktree.path, "main"])
            try FileManager.default.removeItem(at: repo.base.appendingPathComponent("volumen"))
            let alive = repo.base.appendingPathComponent("vivo")
            try TempGitRepo.run(repo.local, ["worktree", "add", "-q", "--detach", alive.path, "main"])

            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let a = try await m.prepare(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            let b = try await m.prepare(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            try FileManager.default.removeItem(at: b.directory)
            try expectEqual(try repo.worktreeNames().count, 5)

            await m.cleanupOrphans(localPaths: [repo.local.path], keeping: [])
            try expectEqual(try repo.worktreeNames().sorted(), ["local", "mio", "vivo"])
            try expectEqual(try repo.prbarRefs(), [])
            try expect(!exists(a.directory))
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: repo.root.path), [])
        },
        TestCase("worktree: symlinkPaths toma solo las entradas con modo 120000 de ls-files -s -z") {
            let output = "100644 aaaa 0\tREADME.md\u{0}120000 bbbb 0\tsecreto\u{0}100755 cccc 0\tbin/run\u{0}120000 dddd 0\tdir con espacios/link\u{0}"
            try expectEqual(WorktreeManager.symlinkPaths(fromLsFiles: output), ["secreto", "dir con espacios/link"])
            try expectEqual(WorktreeManager.symlinkPaths(fromLsFiles: ""), [])
        },
        TestCase("worktree (git real): los symlinks del PR se reemplazan por texto sin seguirlos") {
            let outsideTarget = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: outsideTarget) }
            let secret = outsideTarget.appendingPathComponent("id_rsa")
            try Data("CLAVE PRIVADA\n".utf8).write(to: secret)
            let repo = try TempGitRepo.make(prSetup: { origin in
                let fm = FileManager.default
                try fm.createSymbolicLink(atPath: origin.appendingPathComponent("secreto").path, withDestinationPath: secret.path)
                try fm.createDirectory(at: origin.appendingPathComponent("sub"), withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: origin.appendingPathComponent("sub/relativo").path, withDestinationPath: "../../../afuera.txt")
                try fm.createSymbolicLink(atPath: origin.appendingPathComponent("roto").path, withDestinationPath: "/no/existe")
                try fm.createSymbolicLink(atPath: origin.appendingPathComponent("adentro").path, withDestinationPath: "feature.txt")
            })
            defer { repo.remove() }
            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let ws = try await m.prepare(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            let expected = [
                "secreto": secret.path, "sub/relativo": "../../../afuera.txt", "roto": "/no/existe", "adentro": "feature.txt",
            ]
            for (path, target) in expected {
                let url = ws.directory.appendingPathComponent(path)
                let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                try expectEqual(type, .typeRegular)
                try expectEqual(try String(contentsOf: url, encoding: .utf8), "[symlink to \(target) omitted by PRBar]\n")
            }
            // Los archivos comunes y el destino del link quedan intactos.
            try expectEqual(try String(contentsOf: ws.directory.appendingPathComponent("feature.txt"), encoding: .utf8), "nuevo\n")
            try expectEqual(try String(contentsOf: secret, encoding: .utf8), "CLAVE PRIVADA\n")
            await m.cleanup(ws, localPath: repo.local.path)
        },
        TestCase("worktree: root inseguro no se acepta para borrar") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            try expect(!WorktreeManager.isSafeRoot(URL(fileURLWithPath: "/")))
            try expect(!WorktreeManager.isSafeRoot(home))
            try expect(!WorktreeManager.isSafeRoot(home.deletingLastPathComponent()))
            try expect(!WorktreeManager.isSafeRoot(home.appendingPathComponent("Library")))
            try expect(!WorktreeManager.isSafeRoot(URL(fileURLWithPath: "/tmp")))
            try expect(WorktreeManager.isSafeRoot(AppPaths.worktreesDir))
            let temp = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            try expect(WorktreeManager.isSafeRoot(temp))
        },
        TestCase("worktree: los nombres del chat se reconocen (y no rompen los de un repo llamado chat)") {
            let session = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
            let name = WorktreeManager.chatWorkspaceName(repo: RepoRef(owner: "acme", name: "api"), number: 317, sessionID: session)
            try expectEqual(name, "chat-api-317-6f9619ff-8b86-d011-b42d-00c04fc964ff")
            for valid in [name, name + "-diff", name + ".context", name + "-diff.context",
                          "chat-my-repo-4-6f9619ff-8b86-d011-b42d-00c04fc964ff", "chat-12-1700000000-0a1b2c3d"] {
                try expect(WorktreeManager.isWorkspaceName(valid), valid)
            }
            for invalid in ["chat-api-317", "chat-api-x-6f9619ff-8b86-d011-b42d-00c04fc964ff", "chat--6f9619ff-8b86-d011-b42d-00c04fc964ff"] {
                try expect(!WorktreeManager.isWorkspaceName(invalid), invalid)
            }
        },
        TestCase("worktree (git real): el chat usa su nombre y el commit revisado aunque el PR haya avanzado") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            // The PR gets a new commit after the review.
            try TempGitRepo.run(repo.origin, ["checkout", "-q", "feature"])
            try Data("más\n".utf8).write(to: repo.origin.appendingPathComponent("later.txt"))
            try TempGitRepo.run(repo.origin, ["add", "-A"])
            try TempGitRepo.run(repo.origin, ["commit", "-q", "-m", "later"])
            try TempGitRepo.run(repo.origin, ["update-ref", "refs/pull/7/head", "HEAD"])
            try TempGitRepo.run(repo.origin, ["checkout", "-q", "main"])

            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let name = WorktreeManager.chatWorkspaceName(repo: prRepoRef, number: 7, sessionID: UUID())
            let ws = try await m.prepare(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path,
                                         name: name, pinnedHeadOid: repo.prSHA)
            try expectEqual(ws.directory.lastPathComponent, name)
            try expectEqual(ws.headOid, repo.prSHA)
            try expectEqual(try TempGitRepo.run(ws.directory, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), repo.prSHA)
            try expect(!exists(ws.directory.appendingPathComponent("later.txt")))
            await m.cleanup(ws, localPath: repo.local.path)

            // A commit the clone doesn't have: the PR's current head.
            let other = try await m.prepare(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path,
                                            name: name, pinnedHeadOid: String(repeating: "e", count: 40))
            try expect(other.headOid != repo.prSHA)
            try expect(exists(other.directory.appendingPathComponent("later.txt")))
            // The orphan cleanup at launch removes it (spec B.5: "al cerrar la app").
            await m.cleanupOrphans(localPaths: [repo.local.path], keeping: [])
            try expect(!exists(other.directory))
            try expectEqual(try repo.prbarRefs(), [])
        },
        TestCase("worktree: el chat sin clone usa <nombre>-diff") {
            let root = try temporaryDirectory()
            let m = WorktreeManager(runner: FakeProcessRunner { _, _ in ok("") }, gitPath: "/usr/bin/git", root: root)
            let name = WorktreeManager.chatWorkspaceName(repo: repo, number: 7, sessionID: UUID())
            let ws = try await m.prepare(repo: repo, number: 7, baseRef: "main", localPath: nil, name: name)
            try expectEqual(ws.directory.lastPathComponent, name + "-diff")
            try expect(ws.isDiffOnly)
        },
        TestCase("worktree: prepare rechaza un nombre que no es de chat o un pinnedHeadOid que no es un sha, sin correr git") {
            let root = try temporaryDirectory()
            let runner = FakeProcessRunner { _, _ in ok("") }
            let m = WorktreeManager(runner: runner, gitPath: "/usr/bin/git", root: root)
            let valid = WorktreeManager.chatWorkspaceName(repo: repo, number: 7, sessionID: UUID())
            for name in ["../evil", "chat-r-7-x", "a/" + valid, "", valid + "/..", valid + ".context"] {
                _ = try await expectThrows {
                    _ = try await m.prepare(repo: repo, number: 7, baseRef: "main", localPath: "/tmp/clone", name: name)
                }
            }
            for pinned in ["HEAD~1", "--upload-pack=touch x", "abc123", String(repeating: "A", count: 40), ""] {
                _ = try await expectThrows {
                    _ = try await m.prepare(repo: repo, number: 7, baseRef: "main", localPath: "/tmp/clone", name: valid,
                                            pinnedHeadOid: pinned)
                }
            }
            try expectEqual(runner.calls.count, 0)
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        },
        TestCase("worktree (git real): la review del PR crea <repo>-<N>-review y la siguiente la reusa en el head nuevo") {
            let repo = try TempGitRepo.make(baseSetup: { try Data("*.log\n".utf8).write(to: $0.appendingPathComponent(".gitignore")) })
            defer { repo.remove() }
            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let first = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            try expectEqual(first.directory.lastPathComponent, "r-7-review")
            try expectEqual(first.prRef, "refs/prbar/pr-7-review")
            try expectEqual(first.baseRef, "refs/prbar/base-7-review")
            try expectEqual(first.headOid, repo.prSHA)
            // Lo que dejó la review anterior (o un build en una Terminal): contexto y un archivo ignorado. No es trabajo.
            try FileManager.default.createDirectory(at: first.contextDirectory, withIntermediateDirectories: true)
            try Data("viejo".utf8).write(to: first.diffFile)
            try Data("build\n".utf8).write(to: first.directory.appendingPathComponent("build.log"))
            let second = try repo.advancePR { try Data("otra\n".utf8).write(to: $0.appendingPathComponent("second.txt")) }

            let again = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            try expectEqual(again.directory, first.directory)
            try expectEqual(again.headOid, second)
            try expectEqual(try TempGitRepo.run(again.directory, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), second)
            try expect(exists(again.directory.appendingPathComponent("second.txt")))
            try expect(!exists(again.directory.appendingPathComponent("build.log")))
            try expect(!exists(first.contextDirectory))
            try expectEqual(try repo.worktreeNames().sorted(), ["local", "r-7-review"])
            try expectEqual(try repo.prbarRefs().sorted(), ["refs/prbar/base-7-review", "refs/prbar/pr-7-review"])
        },
        TestCase("worktree (git real): prepareReview dice qué hace con la carpeta del PR: crear, actualizar o una temporal") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let steps = Box<[ReviewFolderStep]>([])
            let first = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path) {
                steps.value.append($0)
            }
            try expectEqual(steps.value, [.creating])
            steps.value = []
            _ = try repo.advancePR { try Data("otra\n".utf8).write(to: $0.appendingPathComponent("second.txt")) }
            _ = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path) { steps.value.append($0) }
            try expectEqual(steps.value, [.updating])
            // With the user's work it isn't touched: a folder for this run only.
            steps.value = []
            try Data("mío\n".utf8).write(to: first.directory.appendingPathComponent("notas.txt"))
            let fallback = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path) {
                steps.value.append($0)
            }
            try expectEqual(steps.value, [.temporary])
            await m.cleanup(fallback, localPath: repo.local.path)
            // Diff-only mode.
            steps.value = []
            let diffOnly = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: nil) { steps.value.append($0) }
            try expectEqual(steps.value, [.temporary])
            await m.cleanup(diffOnly, localPath: nil)
        },
        TestCase("worktree (git real): la carpeta del PR con trabajo del usuario no se toca; la review usa una carpeta propia") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let first = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            // Un cambio sin commitear y un archivo nuevo (p. ej. escritos en una Terminal).
            try Data("cambio local\n".utf8).write(to: first.directory.appendingPathComponent("feature.txt"))
            try Data("mío\n".utf8).write(to: first.directory.appendingPathComponent("notas.txt"))
            let second = try repo.advancePR { try Data("otra\n".utf8).write(to: $0.appendingPathComponent("second.txt")) }

            let fallback = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            try expect(fallback.directory != first.directory, fallback.directory.path)
            try expect(!WorktreeManager.isReviewFolder(fallback))
            try expectEqual(fallback.headOid, second)
            try expectEqual(try String(contentsOf: first.directory.appendingPathComponent("feature.txt"), encoding: .utf8), "cambio local\n")
            try expect(exists(first.directory.appendingPathComponent("notas.txt")))
            try expectEqual(try TempGitRepo.run(first.directory, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), repo.prSHA)
            await m.cleanup(fallback, localPath: repo.local.path)

            // Un commit que no está en ninguna rama: tampoco.
            try TempGitRepo.run(first.directory, ["add", "-A"])
            try TempGitRepo.run(first.directory, ["commit", "-q", "-m", "mío"])
            let again = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            try expect(again.directory != first.directory, again.directory.path)
            try expect(exists(first.directory.appendingPathComponent("notas.txt")))
            await m.cleanup(again, localPath: repo.local.path)
            try expectEqual(try repo.worktreeNames().sorted(), ["local", "r-7-review"])
        },
        TestCase("worktree (git real): los symlinks neutralizados no cuentan como trabajo: la carpeta del PR se reusa") {
            let repo = try TempGitRepo.make(prSetup: {
                try FileManager.default.createSymbolicLink(atPath: $0.appendingPathComponent("link").path, withDestinationPath: "README.md")
            })
            defer { repo.remove() }
            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let first = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            try expectEqual(try String(contentsOf: first.directory.appendingPathComponent("link"), encoding: .utf8),
                            WorktreeManager.symlinkPlaceholder(target: "README.md"))
            let second = try repo.advancePR { try Data("otra\n".utf8).write(to: $0.appendingPathComponent("second.txt")) }
            let again = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            try expectEqual(again.directory, first.directory)
            try expectEqual(again.headOid, second)
        },
        TestCase("worktree (git real): si el fetch falla, la carpeta del PR queda como estaba") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let first = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            let away = repo.base.appendingPathComponent("origin-away")
            try FileManager.default.moveItem(at: repo.origin, to: away)
            do {
                _ = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
                throw TestFailure(description: "el fetch tenía que fallar")
            } catch is PRBarError {}
            try FileManager.default.moveItem(at: away, to: repo.origin)
            try expect(exists(first.directory.appendingPathComponent("feature.txt")))
            try expectEqual(try repo.worktreeNames().sorted(), ["local", "r-7-review"])
            try expectEqual(try repo.prbarRefs().sorted(), ["refs/prbar/base-7-review", "refs/prbar/pr-7-review"])
        },
        TestCase("worktree (git real): una carpeta del PR rota se recrea; la de otro clone con el mismo nombre no se toca") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            // Una carpeta con el nombre que no es un worktree (p. ej. quedó a medio borrar).
            let broken = repo.root.appendingPathComponent("r-7-review", isDirectory: true)
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: broken.appendingPathComponent("resto.txt"))
            let ws = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            try expectEqual(ws.directory.lastPathComponent, "r-7-review")
            try expect(!exists(broken.appendingPathComponent("resto.txt")))
            try expect(exists(ws.directory.appendingPathComponent("feature.txt")))

            // Otro clone (otro owner, mismo nombre y número) en la misma raíz: usa una carpeta propia por corrida.
            let other = try TempGitRepo.make()
            defer { other.remove() }
            let otherManager = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let fallback = try await otherManager.prepareReview(repo: RepoRef(owner: "x", name: "r"), number: 7, baseRef: "main",
                                                                localPath: other.local.path)
            try expect(fallback.directory.lastPathComponent != "r-7-review", fallback.directory.path)
            try expect(!WorktreeManager.isReviewFolder(fallback))
            try expect(exists(ws.directory.appendingPathComponent("feature.txt")))
            try expectEqual(try repo.worktreeNames().sorted(), ["local", "r-7-review"])
        },
        TestCase("worktree (git real): la carpeta del PR que es un symlink o cuyo .git apunta fuera de este clone no se toca") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            try FileManager.default.createDirectory(at: repo.root, withIntermediateDirectories: true)
            let folder = repo.root.appendingPathComponent("r-7-review", isDirectory: true)
            // Un symlink a una carpeta del usuario.
            let target = repo.base.appendingPathComponent("mía", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: target.appendingPathComponent("dato.txt"))
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: target)
            let viaLink = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            try expect(viaLink.directory != folder, viaLink.directory.path)
            try expect(exists(target.appendingPathComponent("dato.txt")))
            try expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.path), target.path)
            await m.cleanup(viaLink, localPath: repo.local.path)
            try FileManager.default.removeItem(at: folder)

            // Un .git con un gitdir relativo a otro clone (existe, pero no es de este) y uno a un clone que ya no está.
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("dato.txt"))
            let otherAdmin = repo.base.appendingPathComponent("otro/.git/worktrees/r-7-review", isDirectory: true)
            try FileManager.default.createDirectory(at: otherAdmin, withIntermediateDirectories: true)
            for gitdir in ["../../otro/.git/worktrees/r-7-review", "/no/existe/.git/worktrees/r-7-review"] {
                try Data("gitdir: \(gitdir)\n".utf8).write(to: folder.appendingPathComponent(".git"))
                let state = await m.reviewFolderState(folder, clone: repo.local.path)
                try expectEqual(state, .foreign)
                let fallback = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
                try expect(fallback.directory != folder, fallback.directory.path)
                try expect(exists(folder.appendingPathComponent("dato.txt")))
                await m.cleanup(fallback, localPath: repo.local.path)
            }
        },
        TestCase("worktree (git real): un gitdir relativo a este clone vale") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let first = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            try Data("gitdir: ../../local/.git/worktrees/r-7-review\n".utf8).write(to: first.directory.appendingPathComponent(".git"))
            let state = await m.reviewFolderState(first.directory, clone: repo.local.path)
            try expectEqual(state, .valid)
        },
        TestCase("worktree: si actualizar la carpeta del PR falla, la borra y la crea de cero") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = root.appendingPathComponent("r-42-review", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("gitdir: /repos/r/.git/worktrees/r-42-review\n".utf8).write(to: dir.appendingPathComponent(".git"))
            let runner = FakeProcessRunner { _, args in
                if args.contains("--git-common-dir") { return ok("/repos/r/.git\n") }
                if args.contains("rev-parse") { return ok(fetchedSHA + "\n") }
                if args.contains("list") { return ok("worktree /repos/r\n\nworktree \(dir.path)\n") }
                if args.contains("checkout") { return fail("error: unable to unlink old 'x'", status: 1) }
                if args.contains("rev-list") { return ok("0\n") }
                return ok("")
            }
            let ws = try await manager(runner, root: root).prepareReview(repo: repo, number: 42, baseRef: "develop", localPath: "/repos/r")
            try expectEqual(ws.directory, dir)
            try expectEqual(ws.headOid, fetchedSHA)
            let commands = try gitArgs(runner).map { $0.dropFirst(2).first ?? "" }
            try expectEqual(commands, ["rev-parse", "worktree", "ls-files", "status", "rev-list",  // estado y trabajo del usuario
                                       "fetch", "rev-parse", "checkout",                      // update, falla
                                       "worktree", "update-ref", "update-ref",               // cleanup
                                       "fetch", "rev-parse", "worktree", "ls-files"])        // de cero
        },
        TestCase("worktree: sin clone, la review sigue con una carpeta -diff por corrida") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = gitFake()
            let ws = try await manager(runner, root: root).prepareReview(repo: repo, number: 42, baseRef: "develop", localPath: nil)
            try expectEqual(ws.directory.lastPathComponent, "r-42-1700000000-0a1b2c3d-diff")
            try expect(ws.isDiffOnly && !WorktreeManager.isReviewFolder(ws))
            try expectEqual(runner.calls.count, 0)
        },
        TestCase("worktree (git real): la limpieza del arranque deja la carpeta del PR conservada con sus refs fijas") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let ws = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path)
            await m.cleanupOrphans(localPaths: [repo.local.path], keeping: [ws.directory.path])
            try expectEqual(try repo.worktreeNames().sorted(), ["local", "r-7-review"])
            try expectEqual(try repo.prbarRefs().sorted(), ["refs/prbar/base-7-review", "refs/prbar/pr-7-review"])
            await m.cleanupOrphans(localPaths: [repo.local.path], keeping: [])
            try expectEqual(try repo.worktreeNames(), ["local"])
            try expectEqual(try repo.prbarRefs(), [])
        },
    ]
}
