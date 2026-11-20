import Foundation
import PRBarCore

enum RunnerProbeTests {
    static let cases: [TestCase] = [
        TestCase("probe: SO, git, claude (por sh -l), perl, comillas intactas; crea la raíz con su marca") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let info = try await RunnerProbe.check(try ssh.host())
            try expectEqual(info.problems, [])
            try expectEqual(info.gitPath, "/usr/bin/git")
            try expectEqual(info.claudePath, ssh.home.appendingPathComponent("bin/claude").path)
            try expectEqual(info.claudeVersion, "2.1.400 (Claude Code)")
            try expect(info.quotingOK && info.perl)
            // Cada instalación de PRBar (esta Mac) tiene su subcarpeta: dos Macs con la misma carpeta no se pisan.
            let base = ssh.home.appendingPathComponent(".prbar").path
            let root = base + "/installs/" + FakeSSH.installationID
            try expectEqual(info.root, root)
            try expect(FileManager.default.fileExists(atPath: base + "/" + RemoteRoot.marker))
            for sub in ["work", "repos", "jobs", "tmp", RemoteRoot.marker] {
                try expect(FileManager.default.fileExists(atPath: root + "/" + sub), sub)
            }
            let other = try await RunnerProbe.check(try ssh.host(installationID: "00000000-0000-4000-8000-0000000000b2"))
            try expectEqual(other.root, base + "/installs/00000000-0000-4000-8000-0000000000b2")
            let mode = try FileManager.default.attributesOfItem(atPath: base + "/installs")[.posixPermissions] as? Int
            try expectEqual(mode, 0o700)
        },
        TestCase("probe: el id de instalación se crea una vez (0600) y se reusa; uno inválido se rechaza") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("sub/installation-id")
            let first = try RemoteInstallation.id(file: file)
            try expect(RemoteInstallation.isValidID(first), first)
            try expectEqual(try RemoteInstallation.id(file: file), first)
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            try expectEqual(mode, 0o600)
            try Data("../../etc".utf8).write(to: file)
            let replaced = try RemoteInstallation.id(file: file)
            try expect(RemoteInstallation.isValidID(replaced) && replaced != first)
            for bad in ["", "../x", "00000000-0000-4000-8000-0000000000A1", "x'; touch PWNED; '", "00000000-0000-4000-8000-0000000000a1/.."] {
                try expect(!RemoteInstallation.isValidID(bad), bad)
            }
        },
        TestCase("probe: una carpeta existente ajena no se usa; sin claude, problema claro") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let foreign = ssh.home.appendingPathComponent(".prbar")
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
            try Data("mine".utf8).write(to: foreign.appendingPathComponent("notes.txt"))
            let info = try await RunnerProbe.check(try ssh.host())
            try expectEqual(info.root, nil)
            try expect(info.problems.contains { $0.contains("already exists and isn’t PRBar’s") }, "\(info.problems)")
            try expect(info.problems.contains { $0.contains("claude isn’t installed") }, "\(info.problems)")
            try expect(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("notes.txt").path))
        },
        TestCase("probe: parseo, git viejo y comillas cambiadas") {
            let output = """
            os=Linux
            arch=x86_64
            gitpath=/usr/bin/git
            git=git version 2.25.1
            claudepath=/home/u/.local/bin/claude
            claude=2.1.400 (Claude Code)
            perl=ok
            quoting=changed
            root=/home/u/.prbar
            """
            let info = RunnerProbe.parse(output, host: "devbox", now: t0)
            try expect(info.problems.contains { $0.contains("git 2.31") }, "\(info.problems)")
            try expect(info.problems.contains { $0.contains("login shell") }, "\(info.problems)")
            try expectEqual(RunnerProbe.gitVersion("git version 2.39.3 (Apple Git-146)").map { [$0.0, $0.1, $0.2] }, [2, 39, 3])
        },
        TestCase("probe: login de Claude con un claude -p mínimo") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            try Data(#"ok"#.utf8).write(to: ssh.home.appendingPathComponent("claude-stream.jsonl"))
            let host = try ssh.host()
            let info = try await RunnerProbe.check(host)
            let loggedIn = try await RunnerProbe.claudeLoggedIn(host, info: info)
            try expect(loggedIn)
            let args = try String(contentsOf: ssh.home.appendingPathComponent("claude-calls/1/args.bin"), encoding: .utf8)
                .split(separator: "\0").map(String.init)
            try expect(args.contains("haiku") && args.contains("--strict-mcp-config") && !args.contains { $0.contains("Reply") })
            let prompt = try String(contentsOf: ssh.home.appendingPathComponent("claude-calls/1/prompt.txt"), encoding: .utf8)
            try expect(prompt.contains("Reply with the single word"))
            try Data("Invalid API key".utf8).write(to: ssh.home.appendingPathComponent("claude-stream.jsonl"))
            let notLogged = try await RunnerProbe.claudeLoggedIn(host, info: info)
            try expect(!notLogged)
        },
        TestCase("probe: la salud se cachea 5 min si anda y 60 s si no") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let cache = RunnerHealthCache()
            let host = try ssh.host()
            _ = try await cache.info(for: host, now: t0)
            _ = try await cache.info(for: host, now: t0.addingTimeInterval(200))
            let afterTwo = ssh.invocations().count
            _ = try await cache.info(for: host, now: t0.addingTimeInterval(301))
            try expectEqual(ssh.invocations().count, afterTwo + 1)
            let down = try ssh.host(unreachable: true)
            let failCache = RunnerHealthCache()
            _ = try? await failCache.info(for: down, now: t0)
            let afterFail = ssh.invocations().count
            _ = try? await failCache.info(for: down, now: t0.addingTimeInterval(30))
            try expectEqual(ssh.invocations().count, afterFail)
            _ = try? await failCache.info(for: down, now: t0.addingTimeInterval(61))
            try expectEqual(ssh.invocations().count, afterFail + 1)
        },
        TestCase("probe: la salud se cachea por destino (host y carpeta) y una verificación en curso no vuelve después de forget") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            // Un `claude --version` lento mientras exista `~/slow` (la verificación queda en curso).
            try ssh.installTool("claude", """
            #!/bin/sh
            [ -f "$HOME/slow" ] && sleep 2
            echo '2.1.400 (Claude Code)'
            """)
            let cache = RunnerHealthCache()
            let first = try await cache.info(for: try ssh.host())
            // El mismo nombre con otra carpeta (`prbar runners set --dir`): nunca la raíz vieja.
            let moved = try await cache.info(for: try ssh.host(remoteDir: "~/other-prbar"))
            try expect(moved.root != first.root && moved.root?.hasPrefix(ssh.home.path + "/other-prbar/") == true, moved.root ?? "-")
            await cache.forget("devbox")
            try Data().write(to: ssh.home.appendingPathComponent("slow"))
            let host = try ssh.host()
            let probe = Task { try await cache.info(for: host) }
            try await Task.sleep(nanoseconds: 700_000_000)
            await cache.forget("DevBox")
            _ = try await probe.value
            let after = await cache.last("devbox")
            try expectEqual(after, nil)
        },
    ]
}
