import Foundation
import PRBarCore

/// Un host de `FakeSSH` ya verificado.
func verifiedFake() async throws -> (FakeSSH, SSHHost, RunnerHostInfo, RemoteRoot) {
    let ssh = try FakeSSH.make()
    try ssh.installFakeClaude()
    let host = try ssh.host()
    let info = try await RunnerProbe.check(host)
    guard let rootPath = info.root else { throw TestFailure(description: "sin raíz: \(info.problems)") }
    return (ssh, host, info, try RemoteRoot(verified: rootPath))
}

private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"Looks fine","findings":[]}}"#

enum RemoteProcessRunnerTests {
    static let cases: [TestCase] = [
        TestCase("remote runner: claude corre en el host con los argumentos de §8.3, el prompt por stdin y la lista blanca") {
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            try Data((resultLine + "\n").utf8).write(to: ssh.home.appendingPathComponent("claude-stream.jsonl"))
            let runner = RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories)
            let log = ssh.base.appendingPathComponent("claude.log")
            let claude = ClaudeRunner(runner: runner, claudePath: info.claudePath!, pluginDirs: ["/home/u/.claude/plugins/cache/m/p/1"],
                                      environment: ["PATH": "/opt/homebrew/bin", "GH_TOKEN": "nope"], logURL: log, redacting: ["ghp_x"],
                                      promptViaStandardInput: true)
            let work = try root.child(["work", "api-1-1700000000-abcdef12"])
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            struct Out: Decodable { let summary: String }
            let invocation = ClaudeInvocation(prompt: "Review it's $(rm -rf ~) safely", schema: #"{"type":"object"}"#,
                                              tools: ["Read", "Grep", "Glob", "Skill", "Agent"], workingDirectory: URL(fileURLWithPath: work),
                                              additionalDirectories: [URL(fileURLWithPath: work + ".context")], timeout: 30, logHeader: "=== stage 1 ===")
            let out = try await claude.run(invocation, as: Out.self, onAgent: { _ in })
            try expectEqual(out.summary, "Looks fine")
            let call = ssh.home.appendingPathComponent("claude-calls/1")
            try expectEqual(try String(contentsOf: call.appendingPathComponent("prompt.txt"), encoding: .utf8), "Review it's $(rm -rf ~) safely")
            try expectEqual(try String(contentsOf: call.appendingPathComponent("cwd.txt"), encoding: .utf8), work + "\n")
            let args = try String(contentsOf: call.appendingPathComponent("args.bin"), encoding: .utf8).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            try expectEqual(args.first, "-p")
            try expect(!args.contains("Review it's $(rm -rf ~) safely"))
            for flag in ["--setting-sources", "--settings", "--permission-mode", "--strict-mcp-config", "--json-schema", "--disallowedTools"] {
                try expect(args.contains(flag), flag)
            }
            let env = try String(contentsOf: call.appendingPathComponent("env.txt"), encoding: .utf8)
            try expect(!env.contains("GH_TOKEN") && !env.contains("SSH_AUTH_SOCK") && env.contains("TMPDIR=\(root.tmp)"), env)
            var leftovers = ["?"]
            for _ in 0..<30 where !leftovers.isEmpty {
                try await Task.sleep(for: .milliseconds(100))
                leftovers = try FileManager.default.contentsOfDirectory(atPath: root.tmp).filter { $0.hasSuffix(".stdin") }
                    + FileManager.default.contentsOfDirectory(atPath: root.jobs)
            }
            try expectEqual(leftovers, [])
        },
        TestCase("remote runner: git con -C y el entorno de git; un token en el entorno no sale") {
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let runner = RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories)
            let result = try await runner.run(info.gitPath!, ["--version"], environment: ["GIT_TERMINAL_PROMPT": "0"], currentDirectory: nil, timeout: 30)
            try expect(result.stdout.hasPrefix("git version"))
            _ = try await expectThrows {
                _ = try await runner.run(info.gitPath!, ["--version"], environment: ["GITHUB_TOKEN": "x"], currentDirectory: nil, timeout: 30)
            }
        },
        TestCase("remote runner: cancelar mata al grupo remoto (no solo al ssh local)") {
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            try ssh.installTool("slow", """
            #!/bin/sh
            printf '%s\\n' "$$" > "$HOME/slow.pid"
            printf '{"type":"system","subtype":"init"}\\n'
            exec sleep 60
            """)
            let runner = RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories + [ssh.home.appendingPathComponent("bin").path])
            let task = Task {
                try await runner.runStreamingIsolated(ssh.home.appendingPathComponent("bin/slow").path, [], environment: [:],
                                                      currentDirectory: URL(fileURLWithPath: root.tmp), timeout: 120) { _ in }
            }
            let pidFile = ssh.home.appendingPathComponent("slow.pid")
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(50)) }
            let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
            task.cancel()
            _ = try? await task.value
            var alive = true
            for _ in 0..<80 where alive {
                try await Task.sleep(for: .milliseconds(100))
                alive = kill(pid, 0) == 0
            }
            try expect(!alive, "el proceso remoto \(pid) sigue vivo")
        },
        TestCase("remote runner: un timeout también mata al grupo remoto") {
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            try ssh.installTool("slow", "#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$HOME/slow.pid\"\nexec sleep 60\n")
            let runner = RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories)
            _ = try await expectThrows {
                _ = try await runner.runStreamingIsolated(ssh.home.appendingPathComponent("bin/slow").path, [], environment: [:],
                                                          currentDirectory: nil, timeout: 1.5) { _ in }
            }
            let pid = Int32(try String(contentsOf: ssh.home.appendingPathComponent("slow.pid"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))!
            var alive = true
            for _ in 0..<80 where alive {
                try await Task.sleep(for: .milliseconds(100))
                alive = kill(pid, 0) == 0
            }
            try expect(!alive)
        },
    ]
}
