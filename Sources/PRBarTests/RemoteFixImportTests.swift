import Foundation
import PRBarCore

private let localGitEnvironment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

/// Un worktree de Respond en el host con un commit de "fix", y el import listo para usar.
/// Runner local real que anota argumentos y entorno de cada proceso.
private final class RecordingLocalRunner: FileIOProcessRunning, ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(arguments: [String], environment: [String: String])] = []
    var calls: [(arguments: [String], environment: [String: String])] { lock.withLock { recorded } }
    /// Los archivos de credenciales que existían mientras corría cada `git` (para ver que se borran después).
    var credentialFiles: [String] = []

    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
             timeout: TimeInterval?) async throws -> ProcessResult {
        record(arguments, environment)
        return try await SystemProcessRunner().run(executable, arguments, environment: environment, currentDirectory: currentDirectory, timeout: timeout)
    }

    func runWithFiles(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
                      timeout: TimeInterval?, standardInput: URL?, standardOutput: URL?,
                      onStdoutLine: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
        record(arguments, environment)
        return try await SystemProcessRunner().runWithFiles(executable, arguments, environment: environment, currentDirectory: currentDirectory,
                                                            timeout: timeout, standardInput: standardInput, standardOutput: standardOutput,
                                                            onStdoutLine: onStdoutLine)
    }

    private func record(_ arguments: [String], _ environment: [String: String]?) {
        lock.withLock {
            recorded.append((arguments, environment ?? [:]))
            for argument in arguments where argument.hasPrefix("credential.helper=store --file=") {
                var path = String(argument.dropFirst("credential.helper=store --file=".count))
                if path.hasPrefix("'") && path.hasSuffix("'") && path.count >= 2 { path = String(path.dropFirst().dropLast()) }
                if FileManager.default.fileExists(atPath: path) { credentialFiles.append(path) }
            }
        }
    }
}

private func remoteFix(localRunner: FileIOProcessRunning & ProcessRunning = SystemProcessRunner(), maxBundleBytes: Int = 1 << 20,
                       strictOrigin: Bool = false, beforeRemote: (TempGitRepo) throws -> Void = { _ in }) async throws
    -> (TempGitRepo, FakeSSH, RemoteWorkspaces, ResolvedWorktree, String, RemoteFixImport) {
    let repo = try TempGitRepo.make()
    try beforeRemote(repo)
    let (ssh, host, info, root) = try await verifiedFake()
    let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
    let bare = try await spaces.mirror(RepoRef(owner: "o", name: "r"))
    let (worktree, start) = try await spaces.prepareRespond(localPath: bare, repo: RepoRef(owner: "o", name: "r"), number: 7,
                                                            headRef: "feature", worktreeDir: nil, runID: "0a0b0c0d")
    let wt = URL(fileURLWithPath: worktree.path)
    try Data("fixed\n".utf8).write(to: wt.appendingPathComponent("feature.txt"))
    try TempGitRepo.run(wt, ["commit", "-q", "-am", "Fix the thing"])
    let importer = RemoteFixImport(spaces: spaces, localGit: TempGitRepo.git, localRunner: localRunner,
                                   gitEnvironment: localGitEnvironment, tempRoot: repo.base.appendingPathComponent("push"),
                                   originURL: { _ in repo.origin.path }, originMatches: { url, _ in !strictOrigin || url == repo.origin.path },
                                   maxBundleBytes: maxBundleBytes)
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
        TestCase("remote fixes: si al clone del usuario le falta el commit de inicio, se trae sin volverlo shallow") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix { repo in
                // La rama avanzó en GitHub después del último fetch del usuario.
                try TempGitRepo.run(repo.origin, ["checkout", "-q", "feature"])
                try Data("more\n".utf8).write(to: repo.origin.appendingPathComponent("more.txt"))
                try TempGitRepo.run(repo.origin, ["add", "-A"])
                try TempGitRepo.run(repo.origin, ["commit", "-q", "-m", "more"])
                try TempGitRepo.run(repo.origin, ["checkout", "-q", "main"])
            }
            defer { repo.remove(); ssh.remove() }
            try expect((try? TempGitRepo.run(repo.local, ["cat-file", "-e", "\(start)^{commit}"])) == nil, "el clone ya tenía el commit")
            _ = try await importer.importFixes(draft: draft(worktree, start: start), localPath: repo.local.path, items: [], integrity: "x")
            let shallow = try TempGitRepo.run(repo.local, ["rev-parse", "--is-shallow-repository"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(shallow, "false")
            try expect(!FileManager.default.fileExists(atPath: repo.local.appendingPathComponent(".git/shallow").path))
        },
        TestCase("remote fixes: un merge de Resolve Conflicts trae la base aparte, el diff es el combined y el push verifica") {
            var base = ""
            let (repo, ssh, spaces, worktree, start, importer) = try await remoteFix { repo in
                base = try repo.advanceBase { try Data("x\n".utf8).write(to: $0.appendingPathComponent("other.txt")) }
            }
            defer { repo.remove(); ssh.remove() }
            let fetched = try await spaces.fetchRespondBase(worktree, repo: RepoRef(owner: "o", name: "r"), baseRef: "main")
            try expectEqual(fetched, base)
            let wt = URL(fileURLWithPath: worktree.path)
            try TempGitRepo.run(wt, ["merge", "--no-ff", "-q", "-m", "Merge main into feature", base])
            var d = draft(worktree, start: start)
            d.mode = .conflicts
            d.conflicts = ConflictsContext(baseRef: "main", baseOid: base, mergeBase: start, files: [], incomingCommits: 1)
            try expect((try? TempGitRepo.run(repo.local, ["cat-file", "-e", "\(base)^{commit}"])) == nil, "el clone ya tenía la base")
            let result = try await importer.importFixes(draft: d, localPath: repo.local.path, items: [], integrity: "x")
            try expectEqual(result.diff, "")
            try expectEqual(result.commits?.count, 2)   // --first-parent: "Fix the thing" (de remoteFix) y el merge
            try await importer.push(draft: d, result: result, token: nil)
            let pushed = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(pushed, result.headOid)
        },
        TestCase("remote fixes: un merge que revierte en silencio lo que trajo la base lo muestra (outsideConflicts) y el push lo re-verifica") {
            var base = ""
            let (repo, ssh, spaces, worktree, start, importer) = try await remoteFix { repo in
                base = try repo.advanceBase { try Data("x\n".utf8).write(to: $0.appendingPathComponent("other.txt")) }
            }
            defer { repo.remove(); ssh.remove() }
            _ = try await spaces.fetchRespondBase(worktree, repo: RepoRef(owner: "o", name: "r"), baseRef: "main")
            let wt = URL(fileURLWithPath: worktree.path)
            try TempGitRepo.run(wt, ["reset", "-q", "--hard", start])
            try TempGitRepo.run(wt, ["merge", "--no-ff", "--no-commit", "-q", base])
            let record = OutsideConflicts.record(fromDiffIndex: try TempGitRepo.run(wt, ["diff-index", "--cached", "--raw", "-z", "--no-renames", "--no-abbrev", start]))
            try expectEqual(record.map(\.path), ["other.txt"])
            try TempGitRepo.run(wt, ["rm", "-q", "-f", "other.txt"])
            try TempGitRepo.run(wt, ["commit", "-q", "-m", "Merge main into feature"])
            var d = draft(worktree, start: start)
            d.mode = .conflicts
            d.conflicts = ConflictsContext(baseRef: "main", baseOid: base, mergeBase: start, files: [], incomingCommits: 1, automaticMerge: record)
            let result = try await importer.importFixes(draft: d, localPath: repo.local.path, items: [], integrity: "x")
            try expectEqual(result.outsideConflicts, ["other.txt"])
            let diff = result.diff ?? ""
            try expect(diff.contains("diff --git a/other.txt b/other.txt\ndeleted file mode 100644\n"), diff)
            try expect(diff.contains("--- a/other.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-x"), diff)
            try await importer.push(draft: d, result: result, token: nil)
            let pushed = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(pushed, result.headOid)
        },
        TestCase("remote fixes: un conflicto resuelto con la versión del PR se ve (oneSidedResolutions) y el push lo re-verifica") {
            var base = ""
            let (repo, ssh, spaces, worktree, start, importer) = try await remoteFix { repo in
                // El PR agregó feature.txt ("nuevo"); la base agrega otro: choque add/add.
                base = try repo.advanceBase { try Data("base\n".utf8).write(to: $0.appendingPathComponent("feature.txt")) }
            }
            defer { repo.remove(); ssh.remove() }
            _ = try await spaces.fetchRespondBase(worktree, repo: RepoRef(owner: "o", name: "r"), baseRef: "main")
            let wt = URL(fileURLWithPath: worktree.path)
            try TempGitRepo.run(wt, ["reset", "-q", "--hard", start])
            _ = try? TempGitRepo.run(wt, ["merge", "--no-ff", "--no-commit", "-q", base])
            try Data("nuevo\n".utf8).write(to: wt.appendingPathComponent("feature.txt"))
            try TempGitRepo.run(wt, ["add", "feature.txt"])
            try TempGitRepo.run(wt, ["commit", "-q", "-m", "Merge main into feature"])
            var d = draft(worktree, start: start)
            d.mode = .conflicts
            d.conflicts = ConflictsContext(baseRef: "main", baseOid: base, mergeBase: start,
                                           files: [ConflictFile(path: "feature.txt", kind: .content)], incomingCommits: 1, automaticMerge: [])
            let result = try await importer.importFixes(draft: d, localPath: repo.local.path, items: [], integrity: "x")
            try expectEqual(result.oneSidedResolutions, [OneSidedResolution(path: "feature.txt", kept: .pr)])
            let diff = result.diff ?? ""
            try expect(diff.contains("diff --git a/feature.txt b/feature.txt\n") && diff.contains("-base\n+nuevo"), diff)
            try await importer.push(draft: d, result: result, token: nil)
            let pushed = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(pushed, result.headOid)
        },
        TestCase("remote fixes: un Resolve Conflicts que no contiene la base no se importa ni se pushea") {
            var base = ""
            let (repo, ssh, spaces, worktree, start, importer) = try await remoteFix { repo in
                base = try repo.advanceBase { try Data("x\n".utf8).write(to: $0.appendingPathComponent("other.txt")) }
            }
            defer { repo.remove(); ssh.remove() }
            // La base está en el mirror pero el worktree no la mergeó.
            _ = try await spaces.fetchRespondBase(worktree, repo: RepoRef(owner: "o", name: "r"), baseRef: "main")
            var d = draft(worktree, start: start)
            d.mode = .conflicts
            d.conflicts = ConflictsContext(baseRef: "main", baseOid: base, mergeBase: start, files: [], incomingCommits: 1)
            let error = try await expectThrows { _ = try await importer.importFixes(draft: d, localPath: repo.local.path, items: [], integrity: "x") }
            try expect(error.localizedDescription.contains("doesn’t contain main"), error.localizedDescription)
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
        TestCase("remote fixes: after the push the run's ref on the runner's mirror moves to the pushed sha (folder not unpushed)") {
            let (repo, ssh, spaces, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            let d = draft(worktree, start: start)
            let result = try await importer.importFixes(draft: d, localPath: repo.local.path, items: [], integrity: "x")
            let before = await spaces.unpushedWork(worktree.path)
            try expect(before != nil, "before the push the fix is unpushed")
            try await importer.push(draft: d, result: result, token: nil)
            let bare = try expectNotNil(worktree.localPath)
            let ref = try expectNotNil(worktree.ref)
            let atRef = try TempGitRepo.run(URL(fileURLWithPath: bare), ["rev-parse", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(atRef, result.headOid)
            let afterPush = await spaces.unpushedWork(worktree.path)
            try expectEqual(afterPush, nil)
            // A commit the user adds later in the terminal still counts.
            let wt = URL(fileURLWithPath: worktree.path)
            try Data("later\n".utf8).write(to: wt.appendingPathComponent("feature.txt"))
            try TempGitRepo.run(wt, ["commit", "-q", "-am", "later"])
            let later = await spaces.unpushedWork(worktree.path)
            try expectEqual(later, "has 1 unpushed commit")
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
        TestCase("remote fixes: el token del clone temporal va en un archivo de credenciales 0600 y nunca en argv ni en el entorno") {
            let recorder = RecordingLocalRunner()
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix(localRunner: recorder) { repo in
                try TempGitRepo.run(repo.origin, ["checkout", "-q", "feature"])
                try Data("more\n".utf8).write(to: repo.origin.appendingPathComponent("more.txt"))
                try TempGitRepo.run(repo.origin, ["add", "-A"])
                try TempGitRepo.run(repo.origin, ["commit", "-q", "-m", "more"])
                try TempGitRepo.run(repo.origin, ["checkout", "-q", "main"])
            }
            defer { repo.remove(); ssh.remove() }
            let token = "ghp_SuperSecretToken123"
            let d = draft(worktree, start: start)
            let result = try await importer.importFixes(draft: d, localPath: nil, items: [], integrity: "x", token: token)
            try await importer.push(draft: d, result: result, token: token)
            await importer.discard(result)
            let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
            for call in recorder.calls {
                for text in call.arguments + Array(call.environment.values) {
                    try expect(!text.contains(token) && !text.contains(basic), "el token salió en \(call.arguments)")
                }
                try expect(!call.environment.keys.contains { $0.hasPrefix("GIT_CONFIG_") && $0 != "GIT_CONFIG_GLOBAL" && $0 != "GIT_CONFIG_NOSYSTEM" },
                           "\(call.environment.keys)")
            }
            // El fetch y el push usaron el archivo (reseteando los helpers del usuario), y el archivo ya no existe.
            let withHelper = recorder.calls.filter { $0.arguments.contains("credential.helper=") }
            try expect(withHelper.contains { $0.arguments.contains("fetch") } && withHelper.contains { $0.arguments.contains("push") },
                       "\(recorder.calls.map(\.arguments))")
            try expect(!recorder.credentialFiles.isEmpty)
            for file in recorder.credentialFiles { try expect(!FileManager.default.fileExists(atPath: file), file) }
        },
        TestCase("remote fixes: el archivo de credenciales es 0600 en una carpeta 0700 y git lo lee") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let file = try RemoteFixImport.CredentialFile(token: "ghp_abc/+=%", in: base)
            defer { file.remove() }
            let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            let dirMode = try FileManager.default.attributesOfItem(atPath: (file.path as NSString).deletingLastPathComponent)[.posixPermissions] as? Int
            try expectEqual(fileMode, 0o600)
            try expectEqual(dirMode, 0o700)
            let input = base.appendingPathComponent("in.txt")
            try Data("protocol=https\nhost=github.com\npath=o/r.git\n\n".utf8).write(to: input)
            let filled = try await SystemProcessRunner().runWithFiles(TempGitRepo.git, file.arguments + ["credential", "fill"],
                                                                     environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                                                                                   "GIT_TERMINAL_PROMPT": "0"],
                                                                     currentDirectory: base, timeout: 30, standardInput: input,
                                                                     standardOutput: nil, onStdoutLine: nil)
            try expect(filled.stdout.contains("username=x-access-token") && filled.stdout.contains("password=ghp_abc/+=%"), filled.stdout + filled.stderr)
            let path = file.path
            file.remove()
            try expect(!FileManager.default.fileExists(atPath: path) && !FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
        },
        TestCase("remote fixes: un bundle más grande que el tope no se baja") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix(maxBundleBytes: 64)
            defer { repo.remove(); ssh.remove() }
            let error = try await expectThrows {
                _ = try await importer.importFixes(draft: draft(worktree, start: start), localPath: repo.local.path, items: [], integrity: "x")
            }
            try expect(error.localizedDescription.contains("too big"), error.localizedDescription)
            try expect(!ssh.invocations().contains { $0.last?.contains("cat -- ") == true }, "se bajó igual")
            try expectEqual(try TempGitRepo.run(repo.local, ["for-each-ref", "refs/prbar/"]), "")
        },
        TestCase("remote fixes: objetos corruptos del host no entran al clone del usuario (fsck)") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            // Un commit con fecha inválida (fsck: badDate), hijo del inicio, como HEAD del worktree remoto.
            let wt = URL(fileURLWithPath: worktree.path)
            let tree = try TempGitRepo.run(wt, ["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = "tree \(tree)\nparent \(start)\nauthor Evil <e@x> notadate\ncommitter Evil <e@x> 1 +0000\n\nbad\n"
            let input = repo.base.appendingPathComponent("bad-commit.txt")
            try Data(raw.utf8).write(to: input)
            let bad = try TempGitRepo.run(wt, ["hash-object", "-t", "commit", "-w", "--literally", input.path])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try TempGitRepo.run(wt, ["update-ref", "HEAD", bad])
            _ = try await expectThrows {
                _ = try await importer.importFixes(draft: draft(worktree, start: start), localPath: repo.local.path, items: [], integrity: "x")
            }
            try expect((try? TempGitRepo.run(repo.local, ["cat-file", "-e", bad])) == nil, "el objeto corrupto entró al clone")
            try expectEqual(try TempGitRepo.run(repo.local, ["for-each-ref", "refs/prbar/"]), "")
        },
        TestCase("remote fixes: al pushear se revisan de nuevo el origin y el pushurl del clone del usuario") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix(strictOrigin: true)
            defer { repo.remove(); ssh.remove() }
            let d = draft(worktree, start: start)
            let result = try await importer.importFixes(draft: d, localPath: repo.local.path, items: [], integrity: "x")
            let evil = repo.base.appendingPathComponent("evil.git")
            try TempGitRepo.run(repo.base, ["init", "-q", "--bare", evil.path])
            try TempGitRepo.run(repo.local, ["config", "remote.origin.pushurl", evil.path])
            let pushURL = try await expectThrows { try await importer.push(draft: d, result: result, token: nil) }
            try expect(pushURL.localizedDescription.contains("origin"), pushURL.localizedDescription)
            try TempGitRepo.run(repo.local, ["config", "--unset", "remote.origin.pushurl"])
            try TempGitRepo.run(repo.local, ["config", "url.\(evil.path).pushInsteadOf", repo.origin.path])
            _ = try await expectThrows { try await importer.push(draft: d, result: result, token: nil) }
            try TempGitRepo.run(repo.local, ["config", "--unset", "url.\(evil.path).pushInsteadOf"])
            try TempGitRepo.run(repo.local, ["remote", "set-url", "origin", evil.path])
            _ = try await expectThrows { try await importer.push(draft: d, result: result, token: nil) }
            try expectEqual(try TempGitRepo.run(evil, ["for-each-ref"]), "")
            try TempGitRepo.run(repo.local, ["remote", "set-url", "origin", repo.origin.path])
            try await importer.push(draft: d, result: result, token: nil)
        },
        TestCase("remote fixes: discard solo borra un clone temporal que está en la carpeta de PRBar") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            let result = try await importer.importFixes(draft: draft(worktree, start: start), localPath: nil, items: [], integrity: "x")
            let objects = try expectNotNil(result.remoteObjects)
            let precious = repo.base.appendingPathComponent("precious")
            try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
            for path in [precious.path, repo.base.appendingPathComponent("push").path, repo.base.appendingPathComponent("push/../precious").path,
                         repo.local.path] {
                var forged = result
                forged.remoteObjects = RemoteObjects(repoPath: path, temporary: true, ref: objects.ref, treeOid: objects.treeOid)
                await importer.discard(forged)
                try expect(FileManager.default.fileExists(atPath: path), "borró \(path)")
            }
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
