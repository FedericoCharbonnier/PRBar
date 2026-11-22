import Foundation
import PRBarCore

/// Un "remoto" bare con `main` y `feature/x`, un clone de trabajo para empujarle commits (`seed`) y el clone
/// del "usuario" (`local`). Todo en una carpeta temporal: nunca toca los repos del usuario.
private struct RespondRepo {
    let base: URL
    var origin: URL { base.appendingPathComponent("origin.git", isDirectory: true) }
    var seed: URL { base.appendingPathComponent("seed", isDirectory: true) }
    var local: URL { base.appendingPathComponent("local", isDirectory: true) }

    static func make() throws -> RespondRepo {
        let base = URL(fileURLWithPath: realPath(try temporaryDirectory().path), isDirectory: true)
        let repo = RespondRepo(base: base)
        try git(base, ["init", "-q", "--bare", "-b", "main", repo.origin.path])
        try git(base, ["clone", "-q", repo.origin.path, repo.seed.path])
        try git(repo.seed, ["checkout", "-q", "-b", "main"])
        try repo.write("README.md", "hola\n", in: repo.seed)
        try git(repo.seed, ["add", "-A"])
        try git(repo.seed, ["commit", "-q", "-m", "base"])
        try git(repo.seed, ["checkout", "-q", "-b", "feature/x"])
        try repo.write("feature.txt", "uno\n", in: repo.seed)
        try git(repo.seed, ["add", "-A"])
        try git(repo.seed, ["commit", "-q", "-m", "feature"])
        try git(repo.seed, ["push", "-q", "origin", "main", "feature/x"])
        try git(base, ["clone", "-q", repo.origin.path, repo.local.path])
        return repo
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func write(_ name: String, _ text: String, in directory: URL) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    func read(_ name: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    /// Un commit nuevo en `origin/feature/x` (hecho desde `seed`); devuelve su SHA.
    @discardableResult
    func pushRemoteCommit(_ text: String) throws -> String {
        try git(seed, ["checkout", "-q", "feature/x"])
        try write("feature.txt", text, in: seed)
        try git(seed, ["commit", "-q", "-am", "remoto"])
        try git(seed, ["push", "-q", "origin", "feature/x"])
        return try sha(seed, "HEAD")
    }

    func sha(_ directory: URL, _ rev: String) throws -> String {
        try git(directory, ["rev-parse", rev]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var defaultWorktreeDir: URL { URL(fileURLWithPath: local.path + "-worktrees", isDirectory: true) }

    @discardableResult
    func git(_ directory: URL, _ arguments: [String]) throws -> String { try TempGitRepo.run(directory, arguments) }
    @discardableResult
    static func git(_ directory: URL, _ arguments: [String]) throws -> String { try TempGitRepo.run(directory, arguments) }
}

/// El resolver con git real y la configuración global/del sistema aislada. `origin` es una carpeta local, así que
/// el chequeo de la URL de `origin` se reemplaza (salvo en el test que lo prueba).
private func resolver(_ runner: ProcessRunning = SystemProcessRunner(),
                      originMatches: @escaping @Sendable (String, RepoRef) -> Bool = { _, _ in true }) -> WorktreeResolver {
    WorktreeResolver(runner: runner, gitPath: TempGitRepo.git,
                     environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                     originMatches: originMatches)
}

private let repoRef = RepoRef(owner: "o", name: "r")
private let runID = "0a1b2c3d"

private func prepare(_ repo: RespondRepo, headRef: String = "feature/x", worktreeDir: String? = nil,
                     runner: ProcessRunning = SystemProcessRunner()) async throws -> (worktree: ResolvedWorktree, headOid: String) {
    try await resolver(runner).prepare(localPath: repo.local.path, repo: repoRef, number: 7, headRef: headRef,
                                       worktreeDir: worktreeDir, runID: runID)
}

private func respondMessage(_ error: Error) throws -> String {
    guard case .respond(let message)? = error as? PRBarError else {
        throw TestFailure(description: "error inesperado: \(error)")
    }
    return message
}

/// `realpath(3)` (git guarda `/private/var/...`, no `/var/...`).
private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

enum WorktreeResolverTests {
    static let cases: [TestCase] = [
        TestCase("resolver: nombres de la carpeta y de la ref de una corrida") {
            try expectEqual(WorktreeResolver.directoryName(repo: repoRef, number: 7, runID: runID), "r-7-respond-0a1b2c3d")
            try expectEqual(WorktreeResolver.directoryName(repo: RepoRef(owner: "o", name: ".."), number: 7, runID: runID),
                            "repo-7-respond-0a1b2c3d")
            try expectEqual(WorktreeResolver.respondRef(number: 7, runID: runID), "refs/prbar/respond-7-0a1b2c3d")
            try expect(WorktreeResolver.isRespondWorktreeName("r-7-respond-0a1b2c3d"))
            try expect(WorktreeResolver.isRespondWorktreeName("my-app-12-respond-ffffffff"))
            for name in ["feature-x", "r-7-respond-0A1B2C3D", "r-7-respond-0a1b2c3", "r-x-respond-0a1b2c3d", "-7-respond-0a1b2c3d", "r-7-0a1b2c3d"] {
                try expect(!WorktreeResolver.isRespondWorktreeName(name), name)
            }
        },
        TestCase("resolver: defaultWorktreeDir") {
            try expectEqual(WorktreeResolver.defaultWorktreeDir(localPath: "/repos/app"), "/repos/app-worktrees")
            try expectEqual(WorktreeResolver.defaultWorktreeDir(localPath: "/repos/app/"), "/repos/app-worktrees")
        },
        TestCase("resolver: la URL de origin tiene que ser la del repo (https o ssh)") {
            for url in ["https://github.com/o/r", "https://github.com/o/r.git", "https://github.com/O/R.git/",
                        "git@github.com:o/r.git", "git@github.com:o/r", "ssh://git@github.com/o/r.git", "ssh://git@github.com/o/r"] {
                try expect(WorktreeResolver.originMatches(url, repo: repoRef), url)
            }
            for url in ["https://github.com/o/r2.git", "https://github.com/evil/r.git", "https://evil.com/o/r.git",
                        "https://github.com.evil.com/o/r.git", "git@evil.com:o/r.git", "/tmp/origin.git",
                        "https://github.com/o/r/extra", "file:///github.com/o/r", "https://x@github.com@evil.com/o/r", ""] {
                try expect(!WorktreeResolver.originMatches(url, repo: repoRef), url)
            }
        },
        TestCase("resolver: headRef inválido se rechaza antes de correr fetch") {
            for ref in ["", "-x", "--upload-pack=evil", "a..b", "a b", "tab\tx", "bell\u{7}", "HEAD", "x.lock", "a//b", "@{-1}", "foo~1"] {
                let runner = FakeProcessRunner { _, args in
                    // check-ref-format corre de verdad para que git decida.
                    if args.contains("check-ref-format") {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: TempGitRepo.git)
                        process.arguments = ["check-ref-format", "--branch", args.last ?? ""]
                        let out = Pipe()
                        process.standardOutput = out
                        process.standardError = Pipe()
                        try? process.run()
                        let data = out.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        return ProcessResult(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self), stderr: "")
                    }
                    return ok("")
                }
                let error = try await expectThrows {
                    _ = try await resolver(runner).prepare(localPath: "/repos/r", repo: repoRef, number: 7, headRef: ref,
                                                          worktreeDir: nil, runID: runID)
                }
                _ = try respondMessage(error)
                let others = runner.calls.filter { !$0.arguments.contains("check-ref-format") }
                try expect(others.isEmpty, "\(ref.debugDescription): \(others.map(\.arguments))")
            }
        },
        TestCase("resolver (git real): un origin que no es el repo frena antes del fetch") {
            let repo = try RespondRepo.make()
            defer { repo.remove() }
            try repo.git(repo.local, ["remote", "set-url", "origin", "https://github.com/evil/r.git"])
            let recorder = RecordingRunner()
            let error = try await expectThrows {
                _ = try await WorktreeResolver(runner: recorder, gitPath: TempGitRepo.git,
                                               environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
                    .prepare(localPath: repo.local.path, repo: repoRef, number: 7, headRef: "feature/x", worktreeDir: nil, runID: runID)
            }
            let message = try respondMessage(error)
            try expect(message.contains("github.com/evil/r.git") && message.contains("o/r"), message)
            try expect(!recorder.calls.contains { $0.arguments.contains("fetch") || $0.arguments.contains("worktree") })
            try expect(!FileManager.default.fileExists(atPath: repo.defaultWorktreeDir.path))
        },
        TestCase("resolver (git real): crea un worktree propio, separado (detached), desde una ref propia; nunca el clone ni la rama") {
            let repo = try RespondRepo.make()
            defer { repo.remove() }
            // El usuario está en la rama del PR, con cambios sin commitear y un commit sin pushear: nada de eso se toca ni se usa.
            try repo.git(repo.local, ["checkout", "-q", "-b", "feature/x", "--track", "origin/feature/x"])
            try repo.write("local.txt", "mío\n", in: repo.local)
            try repo.git(repo.local, ["add", "-A"])
            try repo.git(repo.local, ["commit", "-q", "-m", "local sin pushear"])
            try repo.write("feature.txt", "cambio sin commitear\n", in: repo.local)
            let localHead = try repo.sha(repo.local, "HEAD")
            let newSHA = try repo.pushRemoteCommit("dos\n")

            let recorder = RecordingRunner()
            let (worktree, headOid) = try await prepare(repo, runner: recorder)
            let expected = repo.defaultWorktreeDir.appendingPathComponent("r-7-respond-0a1b2c3d").path
            try expectEqual(worktree, ResolvedWorktree(path: expected, origin: .dedicated, localPath: repo.local.path,
                                                       ref: "refs/prbar/respond-7-0a1b2c3d"))
            try expectEqual(headOid, newSHA)
            let dir = URL(fileURLWithPath: expected)
            try expectEqual(try repo.sha(dir, "HEAD"), newSHA)
            try expectEqual(try repo.git(dir, ["rev-parse", "--abbrev-ref", "HEAD"]), "HEAD\n")
            try expectEqual(try repo.read("feature.txt", in: dir), "dos\n")
            try expectEqual(try repo.sha(repo.local, "refs/prbar/respond-7-0a1b2c3d"), newSHA)
            // El clone del usuario quedó como estaba: rama, HEAD, cambios y sin FETCH_HEAD nuevo.
            try expectEqual(try repo.git(repo.local, ["rev-parse", "--abbrev-ref", "HEAD"]), "feature/x\n")
            try expectEqual(try repo.sha(repo.local, "HEAD"), localHead)
            try expectEqual(try repo.sha(repo.local, "feature/x"), localHead)
            try expectEqual(try repo.read("feature.txt", in: repo.local), "cambio sin commitear\n")
            try expectEqual(try repo.git(repo.local, ["branch", "--list", "--format=%(refname)"]), "refs/heads/feature/x\nrefs/heads/main\n")
            // Todos los git van endurecidos, sin prompts, sin --force ni reset.
            for call in recorder.calls where !call.arguments.contains("check-ref-format") {
                try expectEqual(call.environment?["GIT_TERMINAL_PROMPT"], "0")
                try expectEqual(Array(call.arguments.dropFirst(2).prefix(GitHardening.arguments.count)), GitHardening.arguments)
                try expect(!call.arguments.contains("--force") && !call.arguments.contains("-f") && !call.arguments.contains("reset"), "\(call.arguments)")
            }
            let fetch = recorder.calls.first { $0.arguments.contains("fetch") }
            try expect(fetch?.arguments.contains("+refs/heads/feature/x:refs/prbar/respond-7-0a1b2c3d") == true, "\(String(describing: fetch))")
            try expect(fetch?.arguments.contains("--no-write-fetch-head") == true)
            try expectEqual(fetch?.timeout, 120)
            let add = recorder.calls.first { $0.arguments.contains("worktree") && $0.arguments.contains("add") }
            try expect(add?.arguments.suffix(3) == ["--detach", expected, newSHA], "\(String(describing: add))")
        },
        TestCase("resolver (git real): con worktreeDir propio y aunque ya haya un worktree del usuario en la rama") {
            let repo = try RespondRepo.make()
            defer { repo.remove() }
            let mine = repo.base.appendingPathComponent("mis-worktrees/fx")
            try repo.git(repo.local, ["worktree", "add", "-q", "--track", "-b", "feature/x", mine.path, "origin/feature/x"])
            try repo.write("feature.txt", "trabajo del usuario\n", in: mine)
            let custom = repo.base.appendingPathComponent("otra-carpeta")
            let (worktree, _) = try await prepare(repo, worktreeDir: custom.path)
            try expectEqual(worktree.path, custom.appendingPathComponent("r-7-respond-0a1b2c3d").path)
            try expectEqual(try repo.read("feature.txt", in: mine), "trabajo del usuario\n")
            try expectEqual(try repo.read("feature.txt", in: URL(fileURLWithPath: worktree.path)), "uno\n")
        },
        TestCase("resolver (git real): la carpeta destino ya existe (o es un symlink) → error sin tocarla y sin dejar la ref") {
            for useSymlink in [false, true] {
                let repo = try RespondRepo.make()
                defer { repo.remove() }
                let target = repo.defaultWorktreeDir.appendingPathComponent("r-7-respond-0a1b2c3d")
                let outside = repo.base.appendingPathComponent("afuera")
                if useSymlink {
                    try FileManager.default.createDirectory(at: repo.defaultWorktreeDir, withIntermediateDirectories: true)
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
                } else {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    try repo.write("mio.txt", "no tocar\n", in: target)
                }
                let error = try await expectThrows { _ = try await prepare(repo) }
                _ = try respondMessage(error)
                if useSymlink {
                    try expect(!FileManager.default.fileExists(atPath: outside.path))
                } else {
                    try expectEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["mio.txt"])
                }
                try expectEqual(try repo.git(repo.local, ["for-each-ref", "refs/prbar/"]), "")
            }
        },
        TestCase("resolver (git real): si la rama no existe en origin, falla sin crear nada") {
            let repo = try RespondRepo.make()
            defer { repo.remove() }
            _ = try await expectThrows { _ = try await prepare(repo, headRef: "no-existe") }
            try expectEqual((try? FileManager.default.contentsOfDirectory(atPath: repo.defaultWorktreeDir.path)) ?? [], [])
            try expectEqual(try repo.git(repo.local, ["for-each-ref", "refs/prbar/"]), "")
        },
        TestCase("resolver (git real): cleanup saca el worktree y la ref; cleanupOrphans solo los de Responder") {
            let repo = try RespondRepo.make()
            defer { repo.remove() }
            let (worktree, _) = try await prepare(repo)
            await resolver().cleanup(worktree)
            try expect(!FileManager.default.fileExists(atPath: worktree.path))
            try expectEqual(try repo.git(repo.local, ["for-each-ref", "refs/prbar/"]), "")
            try expect(!(try repo.git(repo.local, ["worktree", "list", "--porcelain"])).contains("respond"))

            // Huérfanos: uno de Responder limpio, uno con cambios sin commitear, uno con un commit sin pushear (como
            // "Ready to push"), uno del usuario en la misma carpeta y otro afuera.
            let orphan = try await resolver().prepare(localPath: repo.local.path, repo: repoRef, number: 8, headRef: "feature/x",
                                                      worktreeDir: nil, runID: "ffffffff").worktree
            let dirty = try await resolver().prepare(localPath: repo.local.path, repo: repoRef, number: 9, headRef: "feature/x",
                                                     worktreeDir: nil, runID: "eeeeeeee").worktree
            try repo.write("feature.txt", "a medias\n", in: URL(fileURLWithPath: dirty.path))
            let committed = try await resolver().prepare(localPath: repo.local.path, repo: repoRef, number: 10, headRef: "feature/x",
                                                         worktreeDir: nil, runID: "dddddddd").worktree
            let committedURL = URL(fileURLWithPath: committed.path)
            try repo.write("feature.txt", "fix\n", in: committedURL)
            try repo.git(committedURL, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-am", "fix"])
            let userInDir = repo.defaultWorktreeDir.appendingPathComponent("feature-x")
            try repo.git(repo.local, ["worktree", "add", "-q", "--detach", userInDir.path, "origin/feature/x"])
            let userNamedLikeUs = repo.base.appendingPathComponent("elsewhere/r-9-respond-0a1b2c3d")
            try repo.git(repo.local, ["worktree", "add", "-q", "--detach", userNamedLikeUs.path, "origin/feature/x"])
            await resolver().cleanupOrphans(localPath: repo.local.path, worktreeDir: nil)
            try expect(!FileManager.default.fileExists(atPath: orphan.path))
            try expect(FileManager.default.fileExists(atPath: dirty.path), "con cambios sin commitear no se borra")
            try expect(FileManager.default.fileExists(atPath: committed.path), "con commits sin pushear no se borra")
            try expect(FileManager.default.fileExists(atPath: userInDir.path))
            try expect(FileManager.default.fileExists(atPath: userNamedLikeUs.path))
            // Quedan las refs de los worktrees guardados; la del limpio se borra.
            let refs = try repo.git(repo.local, ["for-each-ref", "--format=%(refname)", "refs/prbar/"])
                .split(separator: "\n").map(String.init).sorted()
            try expectEqual(refs, ["refs/prbar/respond-10-dddddddd", "refs/prbar/respond-9-eeeeeeee"])

            // La limpieza del arranque de los worktrees de review (`WorktreeManager`) tampoco las borra.
            let manager = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git,
                                          root: repo.base.appendingPathComponent("prbar-worktrees"))
            await manager.cleanupOrphans(localPaths: [repo.local.path])
            try expectEqual(try repo.git(repo.local, ["for-each-ref", "--format=%(refname)", "refs/prbar/"])
                .split(separator: "\n").map(String.init).sorted(), refs)
            // Ya pusheado (el commit está en un remoto): se borra con su ref.
            try repo.git(committedURL, ["push", "-q", "origin", "HEAD:refs/heads/feature/x"])
            try repo.git(repo.local, ["fetch", "-q", "origin"])
            await resolver().cleanupOrphans(localPath: repo.local.path, worktreeDir: nil)
            try expect(!FileManager.default.fileExists(atPath: committed.path))
            try expect(FileManager.default.fileExists(atPath: dirty.path))
            try expectEqual(try repo.git(repo.local, ["for-each-ref", "--format=%(refname)", "refs/prbar/"])
                .trimmingCharacters(in: .whitespacesAndNewlines), "refs/prbar/respond-9-eeeeeeee")
        },
        TestCase("config: worktreeDir y testCommand son opcionales y tienen setters") {
            let json = #"{"accounts":[{"login":"me","repos":[{"owner":"o","name":"r"}]}]}"#
            var config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expectEqual(config.accounts[0].repos[0].worktreeDir, nil)
            try expectEqual(config.accounts[0].repos[0].testCommand, nil)
            config.setWorktreeDir("/w", repoID: "o/r", login: "me")
            config.setTestCommand("swift test", repoID: "o/r", login: "me")
            let data = try JSONCoding.encoder.encode(config)
            let decoded = try JSONCoding.decoder.decode(AppConfig.self, from: data)
            try expectEqual(decoded.accounts[0].repos[0].worktreeDir, "/w")
            try expectEqual(decoded.accounts[0].repos[0].testCommand, "swift test")
            config.setWorktreeDir("  ", repoID: "o/r", login: "me")
            config.setTestCommand(nil, repoID: "o/r", login: "me")
            try expectEqual(config.accounts[0].repos[0].worktreeDir, nil)
            try expectEqual(config.accounts[0].repos[0].testCommand, nil)
        },
    ]
}

/// Corre los procesos de verdad y registra cada llamada.
private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    typealias Call = (arguments: [String], environment: [String: String]?, timeout: TimeInterval?)
    private let lock = NSLock()
    private var recorded: [Call] = []
    private let real = SystemProcessRunner()
    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?, timeout: TimeInterval?) async throws -> ProcessResult {
        lock.withLock { recorded.append((arguments, environment, timeout)) }
        return try await real.run(executable, arguments, environment: environment, currentDirectory: currentDirectory, timeout: timeout)
    }
}
