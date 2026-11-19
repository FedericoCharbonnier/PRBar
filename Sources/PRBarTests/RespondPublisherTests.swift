import Foundation
import PRBarCore

private let repoRef = RepoRef(owner: "o", name: "r")
private let sha1 = String(repeating: "1", count: 40)
private let sha2 = String(repeating: "2", count: 40)

/// git aislado de la configuración global y del sistema, con identidad para los commits.
private let gitEnvironment = [
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "PRBar Tests", "GIT_AUTHOR_EMAIL": "tests@prbar.invalid",
    "GIT_COMMITTER_NAME": "PRBar Tests", "GIT_COMMITTER_EMAIL": "tests@prbar.invalid",
]

/// Un remoto bare temporal (`remote.git`) con la rama `feature/7`; `local`, el clone del "usuario"; y `work`, un
/// worktree separado (detached) de PRBar con un commit nuevo sin pushear (el "fix"). Nunca toca los repos del usuario.
private struct PushRepo {
    let base: URL
    var remote: URL { base.appendingPathComponent("remote.git", isDirectory: true) }
    var local: URL { base.appendingPathComponent("local", isDirectory: true) }
    var work: URL { base.appendingPathComponent("local-worktrees/r-7-respond-0a1b2c3d", isDirectory: true) }
    /// El commit de `feature/7` en el remoto cuando se "analizó" (`startHeadOid`).
    let start: String

    static func make() throws -> PushRepo {
        let base = URL(fileURLWithPath: realPath(try temporaryDirectory().path), isDirectory: true)
        let remote = base.appendingPathComponent("remote.git", isDirectory: true)
        let local = base.appendingPathComponent("local", isDirectory: true)
        try TempGitRepo.run(base, ["init", "-q", "--bare", "-b", "main", remote.path])
        try TempGitRepo.run(base, ["init", "-q", "-b", "feature/7", local.path])
        try Data("hola\n".utf8).write(to: local.appendingPathComponent("README.md"))
        try TempGitRepo.run(local, ["add", "-A"])
        try TempGitRepo.run(local, ["commit", "-q", "-m", "base"])
        try TempGitRepo.run(local, ["remote", "add", "origin", remote.path])
        try TempGitRepo.run(local, ["push", "-q", "origin", "HEAD:refs/heads/feature/7"])
        let start = try TempGitRepo.run(local, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = PushRepo(base: base, start: start)
        try TempGitRepo.run(local, ["update-ref", "refs/prbar/respond-7-0a1b2c3d", start])
        try TempGitRepo.run(local, ["worktree", "add", "-q", "--detach", repo.work.path, start])
        try repo.write("README.md", "hola\nfix\n")
        try TempGitRepo.run(repo.work, ["commit", "-q", "-am", "fix"])
        return repo
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: work.appendingPathComponent(name))
    }

    func head(_ dir: URL) throws -> String {
        try TempGitRepo.run(dir, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remoteHead() throws -> String {
        try TempGitRepo.run(remote, ["rev-parse", "refs/heads/feature/7"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Un pre-push en `.git/hooks` del clone (los hooks del usuario) que deja `marker` y sale con `status`.
    func installPrePush(marker: URL, status: Int) throws {
        let hook = local.appendingPathComponent(".git/hooks/pre-push")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho corrio > '\(marker.path)'\necho 'pre-push dice que no' >&2\nexit \(status)\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    func draft() -> RespondDraft {
        RespondDraft(prID: "PR_7", repo: repoRef, number: 7, title: "PR 7", url: URL(string: "https://github.com/o/r/pull/7")!,
                     headRef: "feature/7", account: "me",
                     worktree: ResolvedWorktree(path: work.path, origin: .dedicated, localPath: local.path, ref: "refs/prbar/respond-7-0a1b2c3d"),
                     startHeadOid: start, items: [])
    }

    /// El resultado tal como lo deja `FixImplementer`: el HEAD que vio el usuario y la huella de git de ese momento.
    func result() async throws -> RespondResult {
        RespondResult(items: [], diffStat: "", tests: nil, headOid: try head(work),
                      gitIntegrity: try await publisher().integrity(of: work))
    }
}

/// Escribe (o agrega al final de) un archivo, creando sus carpetas.
private func writeFile(_ url: URL, _ text: String, append: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = append ? ((try? String(contentsOf: url, encoding: .utf8)) ?? "") : ""
    try Data((old + text).utf8).write(to: url)
}

private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func feedback(_ id: String, kind: FeedbackItem.Kind, databaseID: Int, author: String = "ana",
                      body: String = "Cambiá esto.") -> FeedbackItem {
    FeedbackItem(
        id: id, kind: kind, path: kind == .thread ? "README.md" : nil, line: kind == .thread ? 1 : nil, isOutdated: false,
        comments: [FeedbackComment(databaseID: databaseID, author: author, isBot: false, body: body, createdAt: t0,
                                   url: URL(string: "https://github.com/o/r/pull/7#discussion_r\(databaseID)")!)])
}

private func respondItem(_ feedback: FeedbackItem) -> RespondItem {
    RespondItem(feedback: feedback, assessment: "Tiene razón.", action: .fixAndReply, fixPlan: "plan", reply: "")
}

private let threadA = respondItem(feedback("thread:A", kind: .thread, databaseID: 101))
private let threadB = respondItem(feedback("thread:B", kind: .thread, databaseID: 102))
private let reviewR = respondItem(feedback("review:55", kind: .reviewBody, databaseID: 55, author: "beto",
                                           body: "Faltan tests.\nY también docs."))
private let threadC = respondItem(feedback("thread:C", kind: .thread, databaseID: 103))

private func draft(path: String = "/tmp/wt", headRef: String = "feature/7", origin: ResolvedWorktree.Origin = .dedicated,
                   items: [RespondItem] = [threadA, threadB, reviewR, threadC]) -> RespondDraft {
    RespondDraft(prID: "PR_7", repo: repoRef, number: 7, title: "PR 7", url: URL(string: "https://github.com/o/r/pull/7")!,
                 headRef: headRef, account: "me",
                 worktree: ResolvedWorktree(path: path, origin: origin, localPath: "/repos/r", ref: "refs/prbar/respond-7-0a1b2c3d"),
                 startHeadOid: String(repeating: "0", count: 40), items: items, language: PRLanguage(code: "es"))
}

private func selection(reply: Bool = true, text: String = "") -> RespondSelection {
    RespondSelection(implement: true, fixPlan: "plan", reply: reply, replyText: text)
}

private let selections: [String: RespondSelection] = [
    "thread:A": selection(),
    "thread:B": selection(text: "Gracias, lo dejo así a propósito."),
    "review:55": selection(text: "Agregados."),
    "thread:C": selection(),
]

private let result = RespondResult(items: [
    ItemResult(id: "thread:A", status: .committed, commit: sha1, summary: "ok"),
    ItemResult(id: "thread:B", status: .noChanges, commit: nil, summary: "nada"),
    ItemResult(id: "review:55", status: .committed, commit: sha2, summary: "ok"),
    ItemResult(id: "thread:C", status: .failed, commit: nil, summary: "falló"),
], diffStat: "", tests: nil)

private let expectedA = FakeFeedbackAPI.Post.reply(commentID: 101, body: "Arreglado en https://github.com/o/r/commit/\(sha1).")
private let expectedB = FakeFeedbackAPI.Post.reply(commentID: 102, body: "Gracias, lo dejo así a propósito.")
private let expectedR = FakeFeedbackAPI.Post.issue(
    body: "@beto\n\n> Faltan tests.\n\nArreglado en https://github.com/o/r/commit/\(sha2). Agregados.")

/// `originMatches`: los remotos de los tests son carpetas locales; el chequeo real se prueba aparte.
private func publisher(_ api: GitHubAPI = FakeFeedbackAPI(), runner: ProcessRunning = SystemProcessRunner(),
                       originMatches: @escaping @Sendable (String, RepoRef) -> Bool = { _, _ in true }) -> RespondPublisher {
    RespondPublisher(runner: runner, gitPath: TempGitRepo.git, api: api, environment: gitEnvironment, originMatches: originMatches)
}

private func respondMessage(_ error: Error) throws -> String {
    guard case .respond(let message)? = error as? PRBarError else {
        throw TestFailure(description: "error inesperado: \(error)")
    }
    return message
}

enum RespondPublisherTests {
    static let cases: [TestCase] = [
        TestCase("respond publisher: replyText in all 4 combinations, in the PR's language") {
            let es = PRLanguage(code: "es")
            let withText = RespondSelection(implement: true, fixPlan: "", reply: true, replyText: "  Gracias.  ")
            let empty = RespondSelection(implement: true, fixPlan: "", reply: true, replyText: " \n")
            try expectEqual(RespondPublisher.replyText(selection: withText, commit: sha1, repo: repoRef, language: es),
                            "Arreglado en https://github.com/o/r/commit/\(sha1). Gracias.")
            try expectEqual(RespondPublisher.replyText(selection: empty, commit: sha1, repo: repoRef, language: es),
                            "Arreglado en https://github.com/o/r/commit/\(sha1).")
            try expectEqual(RespondPublisher.replyText(selection: withText, commit: nil, repo: repoRef, language: es), "Gracias.")
            try expectEqual(RespondPublisher.replyText(selection: empty, commit: nil, repo: repoRef, language: es), nil)
        },
        TestCase("respond publisher: replyText uses English for an English PR") {
            let empty = RespondSelection(implement: true, fixPlan: "", reply: true, replyText: "")
            try expectEqual(RespondPublisher.replyText(selection: empty, commit: sha1, repo: repoRef, language: .english),
                            "Fixed in https://github.com/o/r/commit/\(sha1).")
            let thanks = RespondSelection(implement: true, fixPlan: "", reply: true, replyText: "Obrigado.")
            try expectEqual(RespondPublisher.replyText(selection: thanks, commit: sha1, repo: repoRef, language: PRLanguage(code: "pt")),
                            "Corrigido em https://github.com/o/r/commit/\(sha1). Obrigado.")
        },
        TestCase("respond publisher: push del sha revisado con los argumentos exactos: sin --force, --no-verify ni hooksPath") {
            let reviewed = String(repeating: "a", count: 40)
            let handler: (String, [String]) -> ProcessResult = { _, args in
                if args.contains("check-ref-format") { return ok("feature/7\n") }
                if args.contains("--git-dir") { return ok("/nonexistent/gitdir\n/nonexistent/common\n") }
                if args.contains("get-url") { return ok("git@github.com:o/r.git\n") }
                if args.contains("rev-parse") { return ok(reviewed + "\n") }
                return ok("")
            }
            let integrity = try await publisher(runner: FakeProcessRunner(handler)).integrity(of: URL(fileURLWithPath: "/tmp/wt"))
            let result = RespondResult(items: [], diffStat: "", tests: nil, headOid: reviewed, gitIntegrity: integrity)
            let runner = FakeProcessRunner(handler)
            try await publisher(runner: runner, originMatches: { WorktreeResolver.originMatches($0, repo: $1) }).push(draft: draft(path: "/tmp/wt"), result: result)
            let calls = runner.calls
            let push = try calls.last ?? { throw TestFailure(description: "sin llamadas") }()
            try expectEqual(push.arguments, ["-C", "/tmp/wt", "-c", "core.fsmonitor=false", "-c", "submodule.recurse=false",
                                             "-c", "core.untrackedCache=false", "push", "origin", "\(reviewed):refs/heads/feature/7"])
            try expectEqual(push.timeout, 120)
            try expect(calls.allSatisfy { $0.executable == TempGitRepo.git })
            try expect(calls.allSatisfy { $0.environment?["GIT_TERMINAL_PROMPT"] == "0" })
            // Lo de antes del push: todo endurecido (salvo check-ref-format, que no mira ningún repo).
            let verbs = calls.dropLast().map { call in
                call.arguments.contains("check-ref-format") ? "check-ref-format" : call.arguments.dropFirst(2 + GitHardening.arguments.count).first ?? ""
            }
            try expectEqual(verbs, ["check-ref-format", "rev-parse", "config", "remote", "rev-parse", "merge-base"])
            for call in calls.dropLast() where !call.arguments.contains("check-ref-format") {
                try expectEqual(Array(call.arguments.dropFirst(2).prefix(GitHardening.arguments.count)), GitHardening.arguments)
            }
            let flat = push.arguments
            try expect(!flat.contains { $0.hasPrefix("--force") || $0 == "-f" || $0 == "--no-verify" || $0.contains("hooksPath") }, "\(flat)")
            try expect(!flat.contains { $0.hasPrefix("+") || $0.contains(":+") || $0.hasPrefix("HEAD") })
        },
        TestCase("respond publisher: una rama inválida, un worktree que no es de PRBar o un resultado sin sha no llegan al push") {
            for bad in ["--upload-pack=x", "a..b", "HEAD", "con espacio", ""] {
                let runner = FakeProcessRunner { _, _ in ok("\(bad)\n") }
                let error = try await expectThrows {
                    try await publisher(runner: runner).push(draft: draft(headRef: bad), result: result)
                }
                try expect(try respondMessage(error).contains("isn't valid"))
                try expect(!runner.calls.contains { $0.arguments.contains("push") }, bad)
            }
            for (origin, headOid) in [(ResolvedWorktree.Origin.mainClone, sha1), (.existingWorktree, sha1), (.created, sha1),
                                      (.dedicated, nil), (.dedicated, "HEAD")] {
                let runner = FakeProcessRunner { _, args in ok(args.contains("check-ref-format") ? "feature/7\n" : "") }
                let stale = RespondResult(items: [], diffStat: "", tests: nil, headOid: headOid, gitIntegrity: "x")
                let error = try await expectThrows { try await publisher(runner: runner).push(draft: draft(origin: origin), result: stale) }
                try expect(try respondMessage(error).contains("Analyze the PR again"))
                try expect(!runner.calls.contains { $0.arguments.contains("push") })
            }
        },
        TestCase("respond publisher: push real del sha revisado a un remoto bare, con el pre-push del usuario") {
            let repo = try PushRepo.make()
            defer { repo.remove() }
            let marker = repo.base.appendingPathComponent("hook-ran")
            try repo.installPrePush(marker: marker, status: 0)
            let result = try await repo.result()
            try await publisher().push(draft: repo.draft(), result: result)
            try expectEqual(try repo.remoteHead(), result.headOid)
            try expect(FileManager.default.fileExists(atPath: marker.path), "el pre-push del usuario tiene que correr")
        },
        TestCase("respond publisher: si HEAD cambió desde que el usuario vio el diff, no se pushea") {
            let repo = try PushRepo.make()
            defer { repo.remove() }
            let result = try await repo.result()
            try repo.write("README.md", "otra cosa\n")
            try TempGitRepo.run(repo.work, ["commit", "-q", "-am", "después del review"])
            let error = try await expectThrows { try await publisher().push(draft: repo.draft(), result: result) }
            try expect(try respondMessage(error).contains("changed"), "\(error)")
            try expectEqual(try repo.remoteHead(), repo.start)
        },
        TestCase("respond publisher: un sha revisado que no desciende de startHeadOid no se pushea") {
            let repo = try PushRepo.make()
            defer { repo.remove() }
            try TempGitRepo.run(repo.work, ["checkout", "-q", "--orphan", "otra"])
            try TempGitRepo.run(repo.work, ["commit", "-q", "-m", "historia ajena"])
            try TempGitRepo.run(repo.work, ["checkout", "-q", "--detach"])
            let result = try await repo.result()
            let error = try await expectThrows { try await publisher().push(draft: repo.draft(), result: result) }
            try expect(try respondMessage(error).contains(repo.start), "\(error)")
            try expectEqual(try repo.remoteHead(), repo.start)
        },
        TestCase("respond publisher: un .git anidado frena el push sin correr git") {
            let repo = try PushRepo.make()
            defer { repo.remove() }
            let result = try await repo.result()
            try FileManager.default.createDirectory(at: repo.work.appendingPathComponent("sub/.git"), withIntermediateDirectories: true)
            let recorder = FakeProcessRunner { _, args in ok(args.contains("check-ref-format") ? "feature/7\n" : "") }
            let error = try await expectThrows { try await publisher(runner: recorder).push(draft: repo.draft(), result: result) }
            try expect(try respondMessage(error).contains("sub/.git"), "\(error)")
            try expectEqual(recorder.calls.map(\.arguments), [["check-ref-format", "--branch", "feature/7"]])
        },
        TestCase("respond publisher: si cambiaron los hooks o la config de git desde los fixes, no se pushea") {
            for target in [".git/hooks/pre-push", ".git/config"] {
                let repo = try PushRepo.make()
                defer { repo.remove() }
                let result = try await repo.result()
                let url = repo.local.appendingPathComponent(target)
                let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try Data((old + "\n# cambio\n").utf8).write(to: url)
                let error = try await expectThrows { try await publisher().push(draft: repo.draft(), result: result) }
                try expect(try respondMessage(error).contains("git"), "\(error)")
                try expectEqual(try repo.remoteHead(), repo.start)
            }
        },
        TestCase("respond publisher: Finder y el git del usuario en su clone después de los fixes no frenan el push") {
            let repo = try PushRepo.make()
            defer { repo.remove() }
            let common = repo.local.appendingPathComponent(".git")
            let result = try await repo.result()
            for name in [".DS_Store", "._config", "hooks/.DS_Store", "info/.DS_Store", "worktrees/.DS_Store", "gc.log",
                         "COMMIT_EDITMSG", "rr-cache/x/preimage", "lfs/tmp/x"] {
                try writeFile(common.appendingPathComponent(name), "x")
            }
            try TempGitRepo.run(repo.local, ["fetch", "-q", "origin"])                 // FETCH_HEAD
            try TempGitRepo.run(repo.local, ["reset", "-q", "--soft", "HEAD"])         // ORIG_HEAD
            try TempGitRepo.run(repo.local, ["pack-refs", "--all"])                    // packed-refs
            try TempGitRepo.run(repo.local, ["checkout", "-q", "-b", "otra-rama"])     // el HEAD del clone
            let other = repo.base.appendingPathComponent("other")
            try TempGitRepo.run(repo.local, ["worktree", "add", "-q", "-b", "other", other.path, "HEAD"])  // otro admin dir
            try writeFile(other.appendingPathComponent("o.txt"), "o\n")
            try TempGitRepo.run(other, ["add", "-A"])
            try TempGitRepo.run(other, ["commit", "-q", "-m", "other"])
            try await publisher().push(draft: repo.draft(), result: result)
            try expectEqual(try repo.remoteHead(), result.headOid)
        },
        TestCase("respond publisher: hooks, config, info/attributes, el admin dir de PRBar o un include cambiados frenan el push") {
            typealias Change = (name: String, setup: (PushRepo) throws -> Void, change: (PushRepo) throws -> Void)
            let common: (PushRepo) -> URL = { $0.local.appendingPathComponent(".git") }
            let admin: (PushRepo) -> URL = { common($0).appendingPathComponent("worktrees/\($0.work.lastPathComponent)") }
            let changes: [Change] = [
                ("hook", { _ in }, { try writeFile(common($0).appendingPathComponent("hooks/pre-push"), "#!/bin/sh\n") }),
                ("fsmonitor", { _ in }, { try writeFile(common($0).appendingPathComponent("config"), "[core]\n\tfsmonitor = x\n", append: true) }),
                ("attributes", { _ in }, { try writeFile(common($0).appendingPathComponent("info/attributes"), "* filter=evil\n") }),
                ("commondir", { _ in }, { try writeFile(admin($0).appendingPathComponent("commondir"), common($0).path + "\n") }),
                ("gitdir", { _ in }, { try writeFile(admin($0).appendingPathComponent("gitdir"), "\n", append: true) }),
                ("include", { repo in
                    try TempGitRepo.run(repo.local, ["config", "include.path", "extra.cfg"])
                    try writeFile(common(repo).appendingPathComponent("extra.cfg"), "[user]\n\tname = x\n")
                }, { try writeFile(common($0).appendingPathComponent("extra.cfg"), "[core]\n\tpager = x\n") }),
            ]
            for change in changes {
                let repo = try PushRepo.make()
                defer { repo.remove() }
                try change.setup(repo)
                let result = try await repo.result()
                try change.change(repo)
                let error = try await expectThrows { try await publisher().push(draft: repo.draft(), result: result) }
                try expect(try respondMessage(error).contains("git configuration or hooks changed"), "\(change.name): \(error)")
                try expectEqual(try repo.remoteHead(), repo.start)
            }
        },
        TestCase("respond publisher: una config de git incluida desde el worktree frena el push") {
            let repo = try PushRepo.make()
            defer { repo.remove() }
            try TempGitRepo.run(repo.local, ["config", "include.path", repo.work.appendingPathComponent("evil.cfg").path])
            try repo.write("evil.cfg", "[core]\n\tpager = x\n")
            let result = try await repo.result()
            let error = try await expectThrows { try await publisher().push(draft: repo.draft(), result: result) }
            try expect(try respondMessage(error).contains("evil.cfg"), "\(error)")
            try expectEqual(try repo.remoteHead(), repo.start)
        },
        TestCase("respond publisher: si origin no es el repo del PR no se pushea") {
            let repo = try PushRepo.make()
            defer { repo.remove() }
            let result = try await repo.result()
            let strict = publisher(originMatches: { WorktreeResolver.originMatches($0, repo: $1) })
            let error = try await expectThrows { try await strict.push(draft: repo.draft(), result: result) }
            let message = try respondMessage(error)
            try expect(message.contains(repo.remote.path) && message.contains("o/r"), message)
            try expectEqual(try repo.remoteHead(), repo.start)
        },
        TestCase("respond publisher: push rechazado porque el remoto avanzó da el error del plan con el stderr") {
            let repo = try PushRepo.make()
            defer { repo.remove() }
            let other = repo.base.appendingPathComponent("other")
            try TempGitRepo.run(repo.base, ["clone", "-q", "-b", "feature/7", repo.remote.path, other.path])
            try Data("otro\n".utf8).write(to: other.appendingPathComponent("otro.txt"))
            try TempGitRepo.run(other, ["add", "-A"])
            try TempGitRepo.run(other, ["commit", "-q", "-m", "otro"])
            try TempGitRepo.run(other, ["push", "-q", "origin", "HEAD:refs/heads/feature/7"])
            let advanced = try repo.remoteHead()

            let error = try await expectThrows { try await publisher().push(draft: repo.draft(), result: try await repo.result()) }
            let message = try respondMessage(error)
            try expect(message.hasPrefix("GitHub rejected the push: the branch moved ahead. Pull the changes and try again."), message)
            try expect(message.contains("rejected"), message)
            try expectEqual(try repo.remoteHead(), advanced)
        },
        TestCase("respond publisher: un pre-push que falla frena el push con su salida") {
            let repo = try PushRepo.make()
            defer { repo.remove() }
            let before = try repo.remoteHead()
            let marker = repo.base.appendingPathComponent("hook-ran")
            try repo.installPrePush(marker: marker, status: 1)
            let error = try await expectThrows { try await publisher().push(draft: repo.draft(), result: try await repo.result()) }
            let message = try respondMessage(error)
            try expect(message.contains("pre-push dice que no"), message)
            try expect(!message.contains("the branch moved ahead"), message)
            try expect(FileManager.default.fileExists(atPath: marker.path))
            try expectEqual(try repo.remoteHead(), before)
        },
        TestCase("respond publisher: publica hilos, comentario general con @mención y cita; nada para .failed sin texto") {
            let api = FakeFeedbackAPI()
            let seen = Box<[String]>([])
            let (posted, error) = await publisher(api).postReplies(
                draft: draft(), selections: selections, result: result, alreadyPosted: [:], token: "tok"
            ) { id, _ in seen.value.append(id) }
            try expect(error == nil, "\(String(describing: error))")
            try expectEqual(api.posts, [expectedA, expectedB, expectedR])
            try expectEqual(Set(posted.keys), ["thread:A", "thread:B", "review:55"])
            try expectEqual(posted["thread:A"]?.id, "thread:A")
            try expectEqual(posted["thread:A"]?.url, URL(string: "https://github.com/o/r/pull/7#discussion_r101-1")!)
            try expectEqual(seen.value, ["thread:A", "thread:B", "review:55"])
            try expectEqual(api.tokens, ["tok", "tok", "tok"])
        },
        TestCase("respond publisher: sin reply, sin selección o sin texto ni commit no se publica") {
            let api = FakeFeedbackAPI()
            let only: [String: RespondSelection] = [
                "thread:A": selection(reply: false, text: "no va"),
                "thread:C": selection(),
            ]
            let (posted, error) = await publisher(api).postReplies(
                draft: draft(), selections: only, result: result, alreadyPosted: [:], token: "tok")
            try expect(error == nil)
            try expectEqual(api.posts, [])
            try expectEqual(posted, [:])
        },
        TestCase("respond publisher: solo publica lo pendiente y devuelve todo lo publicado") {
            let api = FakeFeedbackAPI()
            let previous = PostedReply(id: "thread:A", url: URL(string: "https://github.com/o/r/pull/7#discussion_r1")!)
            let (posted, error) = await publisher(api).postReplies(
                draft: draft(), selections: selections, result: result, alreadyPosted: ["thread:A": previous], token: "tok")
            try expect(error == nil)
            try expectEqual(api.posts, [expectedB, expectedR])
            try expectEqual(posted["thread:A"], previous)
            try expectEqual(posted.count, 3)
        },
        TestCase("respond publisher: un error a mitad devuelve lo publicado y el error; el reintento no duplica") {
            let api = FakeFeedbackAPI()
            api.failPosts = [2]
            let seen = Box<[String]>([])
            let first = await publisher(api).postReplies(
                draft: draft(), selections: selections, result: result, alreadyPosted: [:], token: "tok"
            ) { id, _ in seen.value.append(id) }
            try expect(first.error != nil)
            try expectEqual(Set(first.posted.keys), ["thread:A"])
            try expectEqual(seen.value, ["thread:A"])
            try expectEqual(api.posts, [expectedA])

            let retry = await publisher(api).postReplies(
                draft: draft(), selections: selections, result: result, alreadyPosted: first.posted, token: "tok")
            try expect(retry.error == nil)
            try expectEqual(api.posts, [expectedA, expectedB, expectedR])
            try expectEqual(retry.posted["thread:A"], first.posted["thread:A"])
            try expectEqual(retry.posted.count, 3)
        },
        TestCase("respond publisher: sin resultado (solo respuestas) no antepone commits") {
            let api = FakeFeedbackAPI()
            let (_, error) = await publisher(api).postReplies(
                draft: draft(), selections: selections, result: nil, alreadyPosted: [:], token: "tok")
            try expect(error == nil)
            try expectEqual(api.posts, [expectedB, .issue(body: "@beto\n\n> Faltan tests.\n\nAgregados.")])
        },
    ]
}
