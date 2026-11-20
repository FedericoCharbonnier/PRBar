import Foundation
import PRBarCore

enum RemotePluginsTests {
    static let cases: [TestCase] = [
        TestCase("remote plugins: la instalación más nueva de cada plugin del host; sin repetir") {
            let (ssh, host, _, _) = try await verifiedFake()
            defer { ssh.remove() }
            let cache = ssh.home.appendingPathComponent(".claude/plugins/cache/claude-plugins-official/pr-review-toolkit")
            for version in ["1.0.0", "2.0.0"] {
                try FileManager.default.createDirectory(at: cache.appendingPathComponent("\(version)/skills"), withIntermediateDirectories: true)
            }
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                                  ofItemAtPath: cache.appendingPathComponent("1.0.0").path)
            let empty = ssh.home.appendingPathComponent(".claude/plugins/cache/other/pr-review-toolkit/9.9.9")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)   // sin skills/commands/agents
            let dirs = try await RemotePlugins.locate(skills: ["pr-review-toolkit:review-pr", "pr-review-toolkit:other", "review"], host: host)
            try expectEqual(dirs, [cache.appendingPathComponent("2.0.0").path])
        },
        TestCase("remote plugins: un plugin que falta da el error con el comando para instalarlo") {
            let (ssh, host, _, _) = try await verifiedFake()
            defer { ssh.remove() }
            let error = try await expectThrows { _ = try await RemotePlugins.locate(skills: ["superpowers:receiving-code-review"], host: host) }
            try expectEqual(error as? RemoteRunnerError, .pluginMissing(host: "devbox", plugin: "superpowers", skill: "superpowers:receiving-code-review"))
            try expect(error.localizedDescription.contains("/plugin install superpowers"))
            // Un nombre fuera de la gramática de §8.0 ni siquiera llega al host.
            let before = ssh.invocations().count
            _ = try await expectThrows { _ = try await RemotePlugins.locate(skills: ["..:x"], host: host) }
            try expectEqual(ssh.invocations().count, before)
        },
    ]
}
