import Foundation
import PRBarCore

enum SSHHostTests {
    static let cases: [TestCase] = [
        TestCase("ssh host: corre el script remoto con las opciones fijas; el texto hostil llega intacto") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let host = try ssh.host()
            let result = try await host.run(RemoteExec(argv: ["/bin/echo", "it's $HOME `x`"], environment: [.literal("PATH", "/bin")]), timeout: 10)
            try expectEqual(result.stdout, "it's $HOME `x`\n")
            let args = try expectNotNil(ssh.invocations().last)
            try expect(args.contains("BatchMode=yes") && args.contains("ForwardAgent=no") && args.contains("StrictHostKeyChecking=yes"))
            try expectEqual(Array(args.suffix(3).prefix(2)), ["--", "devbox"])
            try expect(args.last!.hasPrefix("/bin/sh -c '"), args.last!)
        },
        TestCase("ssh host: un host caído es unreachable") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let error = try await expectThrows {
                _ = try await ssh.host(unreachable: true).run(RemoteExec(argv: ["/bin/true"], environment: []), timeout: 10)
            }
            guard case .unreachable(let name, let detail)? = error as? RemoteRunnerError else { throw TestFailure(description: "\(error)") }
            try expectEqual(name, "devbox")
            try expect(detail.contains("Connection refused"))
        },
        TestCase("ssh host: subir y bajar binarios; nada fuera de la raíz") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let host = try ssh.host()
            let rootPath = ssh.home.appendingPathComponent(".prbar")
            try FileManager.default.createDirectory(at: rootPath.appendingPathComponent("tmp"), withIntermediateDirectories: true)
            try Data().write(to: rootPath.appendingPathComponent(RemoteRoot.marker))
            let root = try RemoteRoot(verified: rootPath.path)
            let bytes = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
            let remote = try root.child(["tmp", "blob.bin"])
            try await host.upload(bytes, to: remote, root: root)
            try expectEqual(try Data(contentsOf: URL(fileURLWithPath: remote)), bytes)
            let local = ssh.base.appendingPathComponent("down.bin")
            try await host.download(remote, to: local, root: root)
            try expectEqual(try Data(contentsOf: local), bytes)
            let before = ssh.invocations().count
            _ = try await expectThrows { try await host.upload(bytes, to: ssh.home.appendingPathComponent("x").path, root: root) }
            try expectEqual(ssh.invocations().count, before)
        },
        TestCase("ssh host: borrar exige la marca, estar adentro y dos niveles abajo") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let host = try ssh.host()
            let rootURL = ssh.home.appendingPathComponent(".prbar")
            let victim = rootURL.appendingPathComponent("work/old-run")
            try FileManager.default.createDirectory(at: victim.appendingPathComponent("deep"), withIntermediateDirectories: true)
            let root = try RemoteRoot(verified: rootURL.path)
            let unmarked = try await expectThrows { try await host.removeTree(victim.path, root: root) }
            try expect(unmarked is RemoteRunnerError)
            try expect(FileManager.default.fileExists(atPath: victim.path))
            try Data().write(to: rootURL.appendingPathComponent(RemoteRoot.marker))
            try await host.removeTree(victim.path, root: root)
            try expect(!FileManager.default.fileExists(atPath: victim.path))
            for refused in [rootURL.appendingPathComponent("work").path, rootURL.path, ssh.home.path, rootURL.path + "/work/../.."] {
                _ = try await expectThrows { try await host.removeTree(refused, root: root) }
            }
            try expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("work").path))
        },
        TestCase("ssh host: con sh, bash o zsh como shell de login, cada valor hostil llega intacto y nada se ejecuta") {
            let values = ShellQuoteTests.hostile.filter { $0.utf8.count < 1_000 } + ShellQuoteTests.randomStrings(count: 150, seed: 99)
            for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
                let ssh = try FakeSSH.make()
                defer { ssh.remove() }
                let host = try ssh.host(shell: shell)
                let result = try await host.run(RemoteExec(argv: ["/usr/bin/printf", "%s\\0"] + values, cwd: ssh.home.path,
                                                           environment: [.literal("PATH", "/usr/bin:/bin")]), timeout: 30)
                try expect(!FileManager.default.fileExists(atPath: ssh.home.appendingPathComponent("PWNED").path), "\(shell) ejecutó algo")
                var back = result.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
                if back.last == "" { back.removeLast() }
                try expectEqual(back.count, values.count)
                for (index, value) in values.enumerated() where !Array(back[index].utf8).elementsEqual(value.utf8) {
                    throw TestFailure(description: "\(shell) cambió el valor #\(index): \(Array(value.utf8).prefix(40)) → \(Array(back[index].utf8).prefix(40))")
                }
                let info = try await RunnerProbe.check(host)
                try expect(info.quotingOK, "\(shell): \(info.problems)")
            }
        },
        TestCase("ssh host: lo que imprime el rc del shell de login no se confunde con la salida del guardián ni del bundle") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let (ssh, _, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            // Tres campos terminados en NUL: un registro bien formado de mentira, que un parser laxo se saltearía.
            let noisy = try ssh.host(noise: Data("Welcome to devbox\n\u{0}x\u{0}y\u{0}".utf8))
            let work = URL(fileURLWithPath: try root.child(["work", "w"]))
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: work.appendingPathComponent("a.txt"))
            let fs = RemoteWorkspaceFS.ssh(host: noisy, home: ssh.home.path, root: root)
            let snapshot = try await expectThrows { _ = try await fs.snapshot(work.path) }
            try expect(snapshot is RemoteRunnerError, "\(snapshot)")
            _ = try await expectThrows { _ = try await fs.nestedGitEntries(work.path) }
            _ = try await expectThrows { _ = try await fs.describe([work.path]) }
            // Un import entero con ese host: corta sin dejar nada en el clone.
            let spaces = remoteWorkspaces(noisy, info, root, origin: repo.origin)
            let draft = RespondDraft(prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "T",
                                     url: URL(string: "https://github.com/o/r/pull/7")!, headRef: "feature", account: "me",
                                     worktree: ResolvedWorktree(path: work.path, origin: .dedicated), startHeadOid: repo.prSHA, items: [],
                                     runner: "devbox")
            let importer = RemoteFixImport(spaces: spaces, localGit: TempGitRepo.git, gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null"],
                                           tempRoot: repo.base.appendingPathComponent("push"), originMatches: { _, _ in true })
            _ = try await expectThrows {
                _ = try await importer.importFixes(draft: draft, localPath: repo.local.path, items: [], integrity: "x")
            }
            try expectEqual(try TempGitRepo.run(repo.local, ["for-each-ref", "refs/prbar/"]), "")
        },
    ]
}

func expectNotNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw TestFailure(description: "\(file):\(line) expected a value, got nil") }
    return value
}
