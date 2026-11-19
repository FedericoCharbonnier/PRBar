import Foundation
import PRBarCore

enum UpdateSourceTests {
    static let sha = String(repeating: "c", count: 40)

    /// git falso: `rev-parse` devuelve `sha` (o `revParseStatus`), `merge-base` sale con `mergeBaseStatus`.
    static func fakeGit(revParseStatus: Int32 = 0, mergeBaseStatus: Int32 = 0) -> FakeProcessRunner {
        FakeProcessRunner { _, arguments in
            if arguments.contains("rev-parse") {
                return ProcessResult(status: revParseStatus, stdout: revParseStatus == 0 ? sha + "\n" : "", stderr: "")
            }
            if arguments.contains("merge-base") { return ProcessResult(status: mergeBaseStatus, stdout: "", stderr: "") }
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
    }

    static let cases: [TestCase] = [
        TestCase("update source: primera vez clona sin checkout; todos los git endurecidos") {
            let dir = try temporaryDirectory().appendingPathComponent("source", isDirectory: true)
            let runner = fakeGit()
            let source = UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: dir,
                                      remoteURL: UpdateSource.remoteURL(forRepo: "acme/PRBar"))
            let result = try await source.checkout(tag: "v1.3.0")
            try expectEqual(result, sha)
            let h = GitHardening.arguments
            try expectEqual(runner.calls.map(\.arguments), [
                h + ["clone", "--no-checkout", "--quiet", "https://github.com/acme/PRBar.git", dir.path],
                h + ["-C", dir.path, "fetch", "--quiet", "--tags", "--force", "--prune", "origin"],
                h + ["-C", dir.path, "rev-parse", "--verify", "--quiet", "refs/tags/v1.3.0^{commit}"],
                h + ["-C", dir.path, "merge-base", "--is-ancestor", sha, "refs/remotes/origin/main"],
                h + ["-C", dir.path, "checkout", "--quiet", "--force", "--detach", sha],
                h + ["-C", dir.path, "clean", "-ffdq"],
            ])
            try expect(runner.calls.allSatisfy { $0.executable == "/usr/bin/git" })
            try expect(runner.calls.allSatisfy { $0.environment == GitHardening.environment })
        },
        TestCase("update source: con clon existente actualiza la URL de origin en vez de clonar") {
            let dir = try temporaryDirectory().appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let runner = fakeGit()
            let source = UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: dir, remoteURL: "https://github.com/acme/fork.git")
            _ = try await source.checkout(tag: "v1.3.0")
            try expectEqual(runner.calls.first?.arguments,
                            GitHardening.arguments + ["-C", dir.path, "remote", "set-url", "origin", "https://github.com/acme/fork.git"])
            try expect(!runner.calls.contains { $0.arguments.contains("clone") })
        },
        TestCase("update source: tag inexistente → tagMissing, sin checkout") {
            let runner = fakeGit(revParseStatus: 1)
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
            for tag in ["--upload-pack=touch /tmp/x", "main", "v1.3"] {
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
        },
    ]
}
