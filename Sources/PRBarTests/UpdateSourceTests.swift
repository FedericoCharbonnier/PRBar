import Foundation
import PRBarCore

enum UpdateSourceTests {
    static let sha = String(repeating: "c", count: 40)
    static let url = "https://github.com/acme/PRBar.git"

    /// git falso. `config` devuelve `configKeys`; `fetch` sale con lo que diga `fetchStatus` (por intento: la primera
    /// llamada usa el primer valor, etc.); `ls-remote` devuelve `lsRemote`; `rev-parse` el sha (o `revParseStatus`).
    static func fakeGit(
        configKeys: String = "core.repositoryformatversion\ncore.bare\n", fetchStatus: [Int32] = [0], lsRemote: ProcessResult? = nil,
        revParseStatus: [Int32] = [0], mergeBaseStatus: Int32 = 0
    ) -> FakeProcessRunner {
        let fetches = Box(0)
        let revParses = Box(0)
        return FakeProcessRunner { _, arguments in
            if arguments.contains("config") { return ok(configKeys) }
            if arguments.contains("fetch") {
                let status = fetchStatus[min(fetches.value, fetchStatus.count - 1)]
                fetches.value += 1
                return ProcessResult(status: status, stdout: "", stderr: status == 0 ? "" : "fatal: boom")
            }
            if arguments.contains("ls-remote") {
                return lsRemote ?? ok("\(sha)\trefs/tags/v1.3.0\n")
            }
            if arguments.contains("rev-parse") {
                let status = revParseStatus[min(revParses.value, revParseStatus.count - 1)]
                revParses.value += 1
                return ProcessResult(status: status, stdout: status == 0 ? sha + "\n" : "", stderr: "")
            }
            if arguments.contains("merge-base") { return ProcessResult(status: mergeBaseStatus, stdout: "", stderr: "") }
            return ok("")
        }
    }

    static func source(_ runner: FakeProcessRunner, _ dir: URL) -> UpdateSource {
        UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: dir, remoteURL: url)
    }

    /// Un clon "existente" en `dir` (solo la carpeta `.git`).
    static func existingClone() throws -> URL {
        let dir = try temporaryDirectory().appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        return dir
    }

    static func subcommands(_ runner: FakeProcessRunner) -> [String] {
        runner.calls.compactMap { call in
            let args = Array(call.arguments.dropFirst(UpdateSource.gitArguments.count))
            return (args.first == "-C" ? args.dropFirst(2).first : args.first).map { String($0) }
        }
    }

    static let cases: [TestCase] = [
        TestCase("update source: primera vez hace init sin plantillas y fetch con URL y refspecs explícitos") {
            let dir = try temporaryDirectory().appendingPathComponent("source", isDirectory: true)
            let runner = fakeGit()
            let result = try await source(runner, dir).checkout(tag: "v1.3.0")
            try expectEqual(result, sha)
            let a = UpdateSource.gitArguments
            try expectEqual(runner.calls.map(\.arguments), [
                a + ["init", "--quiet", "--template=", dir.path],
                a + ["-C", dir.path, "fetch", "--quiet", "--no-tags", "--force", url,
                     "+refs/heads/main:refs/remotes/origin/main", "+refs/tags/v1.3.0:refs/tags/v1.3.0"],
                a + ["-C", dir.path, "rev-parse", "--verify", "--quiet", "refs/tags/v1.3.0^{commit}"],
                a + ["-C", dir.path, "merge-base", "--is-ancestor", sha, "refs/remotes/origin/main"],
                a + ["-C", dir.path, "checkout", "--quiet", "--force", "--detach", sha],
                a + ["-C", dir.path, "clean", "-ffdq"],
            ])
            try expect(runner.calls.allSatisfy { $0.executable == "/usr/bin/git" })
            try expect(runner.calls.allSatisfy { $0.environment == UpdateSource.environment })
        },
        TestCase("update source: git sin config global ni del sistema, sin attributes ni credenciales") {
            try expectEqual(UpdateSource.environment["GIT_CONFIG_GLOBAL"], "/dev/null")
            try expectEqual(UpdateSource.environment["GIT_CONFIG_NOSYSTEM"], "1")
            try expectEqual(UpdateSource.environment["GIT_TERMINAL_PROMPT"], "0")
            try expectEqual(Array(UpdateSource.gitArguments.prefix(GitHardening.arguments.count)), GitHardening.arguments)
            let extra = Array(UpdateSource.gitArguments.dropFirst(GitHardening.arguments.count))
            try expect(extra.contains("core.attributesFile=/dev/null"), "\(extra)")
            try expect(extra.contains("credential.helper="), "\(extra)")
        },
        TestCase("update source: clon existente con config esperada se reusa (sin init)") {
            let dir = try existingClone()
            let runner = fakeGit()
            _ = try await source(runner, dir).checkout(tag: "v1.3.0")
            try expectEqual(runner.calls.first?.arguments,
                            UpdateSource.gitArguments + ["-C", dir.path, "config", "--local", "--list", "--name-only"])
            try expect(!subcommands(runner).contains("init"))
            try expect(!subcommands(runner).contains("remote"))
        },
        TestCase("update source: config local con claves de más → borra el clon y vuelve a empezar") {
            for keys in ["core.bare\nremote.origin.url\n", "core.bare\nurl.https://evil/.insteadof\n", "include.path\n",
                         "credential.helper\n", "http.proxy\n", "filter.x.smudge\n", "core.sshcommand\n"] {
                let dir = try existingClone()
                try Data("junk".utf8).write(to: dir.appendingPathComponent("junk.txt"))
                let runner = fakeGit(configKeys: keys)
                _ = try await source(runner, dir).checkout(tag: "v1.3.0")
                try expectEqual(Array(subcommands(runner).prefix(3)), ["config", "init", "fetch"])
                try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("junk.txt").path), keys)
            }
        },
        TestCase("update source: .git/info/attributes → borra el clon y vuelve a empezar") {
            let dir = try existingClone()
            try Data("* filter=evil\n".utf8).write(to: dir.appendingPathComponent(".git/info/attributes"))
            let runner = fakeGit()
            _ = try await source(runner, dir).checkout(tag: "v1.3.0")
            try expectEqual(subcommands(runner).first, "init")
            try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git/info/attributes").path))
        },
        TestCase("update source: fetch que falla y el tag no está en el remoto → tagMissing sin reintentar") {
            let dir = try temporaryDirectory().appendingPathComponent("s", isDirectory: true)
            let runner = fakeGit(fetchStatus: [128], lsRemote: ok(""))
            let error = try await expectThrows { _ = try await source(runner, dir).checkout(tag: "v9.9.9") }
            try expectEqual(error as? UpdateError, .tagMissing("v9.9.9"))
            try expectEqual(subcommands(runner), ["init", "fetch", "ls-remote"])
            try expectEqual(runner.calls[2].arguments, UpdateSource.gitArguments + ["ls-remote", "--tags", url, "refs/tags/v9.9.9"])
        },
        TestCase("update source: fetch que falla por otra cosa → borra el clon y reintenta una vez") {
            let dir = try existingClone()
            let runner = fakeGit(fetchStatus: [128, 0])
            let sha = try await source(runner, dir).checkout(tag: "v1.3.0")
            try expectEqual(sha, Self.sha)
            try expectEqual(Array(subcommands(runner).prefix(5)), ["config", "fetch", "ls-remote", "init", "fetch"])

            let failing = fakeGit(fetchStatus: [128])
            let error = try await expectThrows { _ = try await source(failing, try existingClone()).checkout(tag: "v1.3.0") }
            guard case .commandFailed? = error as? PRBarError else { throw TestFailure(description: "\(error)") }
            try expectEqual(subcommands(failing).filter { $0 == "init" }.count, 1)
            try expectEqual(subcommands(failing).filter { $0 == "fetch" }.count, 2)
        },
        TestCase("update source: rev-parse que falla raro (128) → reintenta una vez desde cero") {
            let runner = fakeGit(revParseStatus: [128, 0])
            let sha = try await source(runner, try existingClone()).checkout(tag: "v1.3.0")
            try expectEqual(sha, Self.sha)
            try expectEqual(subcommands(runner).filter { $0 == "init" }.count, 1)
        },
        TestCase("update source: tag inexistente → tagMissing, sin checkout") {
            let runner = fakeGit(revParseStatus: [1])
            let source = UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: try temporaryDirectory().appendingPathComponent("s"),
                                      remoteURL: "https://github.com/a/b.git")
            let error = try await expectThrows { _ = try await source.checkout(tag: "v9.9.9") }
            try expectEqual(error as? UpdateError, .tagMissing("v9.9.9"))
            try expect(!runner.calls.contains { $0.arguments.contains("checkout") })
        },
        TestCase("update source: tag no alcanzable desde origin/main → tagNotOnMain, sin checkout") {
            let runner = fakeGit(mergeBaseStatus: 1)
            let source = UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: try temporaryDirectory().appendingPathComponent("s"),
                                      remoteURL: "https://github.com/a/b.git")
            let error = try await expectThrows { _ = try await source.checkout(tag: "v1.3.0") }
            try expectEqual(error as? UpdateError, .tagNotOnMain("v1.3.0"))
            try expect(!runner.calls.contains { $0.arguments.contains("checkout") })
        },
        TestCase("update source: un tag que no es versión no llega a git") {
            let runner = fakeGit()
            let source = UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: try temporaryDirectory().appendingPathComponent("s"),
                                      remoteURL: "https://github.com/a/b.git")
            for tag in ["--upload-pack=touch /tmp/x", "main", "v1.3", "1.3.0", "V1.3.0", "v01.3.0", "v1.03.0", "v1.3.0+x",
                        "v1.3.0-beta.1", " v1.3.0", "v1.3.0\n"] {
                let error = try await expectThrows { _ = try await source.checkout(tag: tag) }
                try expectEqual(error as? UpdateError, .invalidTag(tag))
            }
            try expectEqual(runner.calls.count, 0)
        },
        TestCase("update source: git real — tag en main sí, tag en otra rama no") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let origin = base.appendingPathComponent("origin", isDirectory: true)
            try TempGitRepo.run(base, ["init", "-q", "-b", "main", origin.path])
            try Data("1\n".utf8).write(to: origin.appendingPathComponent("VERSION"))
            try TempGitRepo.run(origin, ["add", "-A"])
            try TempGitRepo.run(origin, ["commit", "-q", "-m", "one"])
            try TempGitRepo.run(origin, ["tag", "-a", "v1.0.0", "-m", "1.0.0"])
            let mainSHA = try TempGitRepo.run(origin, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try TempGitRepo.run(origin, ["checkout", "-q", "-b", "side"])
            try Data("9\n".utf8).write(to: origin.appendingPathComponent("VERSION"))
            try TempGitRepo.run(origin, ["commit", "-q", "-am", "side"])
            try TempGitRepo.run(origin, ["tag", "-a", "v9.0.0", "-m", "9.0.0"])
            try TempGitRepo.run(origin, ["checkout", "-q", "main"])

            let source = UpdateSource(runner: SystemProcessRunner(), gitPath: TempGitRepo.git,
                                      directory: base.appendingPathComponent("source", isDirectory: true), remoteURL: origin.path)
            let sha = try await source.checkout(tag: "v1.0.0")
            try expectEqual(sha, mainSHA)
            let version = try String(contentsOf: source.directory.appendingPathComponent("VERSION"), encoding: .utf8)
            try expectEqual(version, "1\n")

            let error = try await expectThrows { _ = try await source.checkout(tag: "v9.0.0") }
            try expectEqual(error as? UpdateError, .tagNotOnMain("v9.0.0"))
            // El clon se reusa y sigue en el tag bueno.
            let again = try await source.checkout(tag: "v1.0.0")
            try expectEqual(again, mainSHA)

            let missing = try await expectThrows { _ = try await source.checkout(tag: "v7.7.7") }
            try expectEqual(missing as? UpdateError, .tagMissing("v7.7.7"))
        },
        TestCase("update source: git real — un clon con config o attributes ajenos se rehace y no corre filtros") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let origin = base.appendingPathComponent("origin", isDirectory: true)
            try TempGitRepo.run(base, ["init", "-q", "-b", "main", origin.path])
            try Data("1\n".utf8).write(to: origin.appendingPathComponent("VERSION"))
            try TempGitRepo.run(origin, ["add", "-A"])
            try TempGitRepo.run(origin, ["commit", "-q", "-m", "one"])
            try TempGitRepo.run(origin, ["tag", "-a", "v1.0.0", "-m", "1.0.0"])
            let mainSHA = try TempGitRepo.run(origin, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Otro repo al que un insteadOf mandaría el fetch.
            let evil = base.appendingPathComponent("evil", isDirectory: true)
            try TempGitRepo.run(base, ["init", "-q", "-b", "main", evil.path])

            let dir = base.appendingPathComponent("source", isDirectory: true)
            let source = UpdateSource(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, directory: dir, remoteURL: origin.path)
            _ = try await source.checkout(tag: "v1.0.0")
            let pwned = base.appendingPathComponent("PWNED")
            try TempGitRepo.run(dir, ["config", "url.\(evil.path).insteadOf", origin.path])
            try TempGitRepo.run(dir, ["config", "filter.evil.smudge", "touch \(pwned.path); cat"])
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
            try Data("* filter=evil\n".utf8).write(to: dir.appendingPathComponent(".git/info/attributes"))
            try FileManager.default.removeItem(at: dir.appendingPathComponent("VERSION"))

            let sha = try await source.checkout(tag: "v1.0.0")
            try expectEqual(sha, mainSHA)
            try expect(!FileManager.default.fileExists(atPath: pwned.path))
            try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git/info/attributes").path))
            let keys = try TempGitRepo.run(dir, ["config", "--local", "--list", "--name-only"])
                .split(separator: "\n").map(String.init)
            try expect(Set(keys).isSubset(of: UpdateSource.allowedConfigKeys), "\(keys)")
            try expectEqual(try String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8), "1\n")
        },
    ]
}
