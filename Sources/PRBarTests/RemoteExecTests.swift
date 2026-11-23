import Foundation
import PRBarCore

/// Corre `script` con `/bin/sh -c` y exactamente `environment`; devuelve stdout.
func runLocalScript(_ script: String, environment: [String: String], stdin: URL? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.environment = environment
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    if let stdin { process.standardInput = try FileHandle(forReadingFrom: stdin) }
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// El exit code de `/bin/sh -c <script>`.
func runLocalScriptStatus(_ script: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.environment = ["PATH": "/usr/bin:/bin"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private let dirty: [String: String] = [
    "PATH": "/usr/bin:/bin", "HOME": "/remote/home", "USER": "fede", "LANG": "en_US.UTF-8",
    "GH_TOKEN": "ghp_secret", "GITHUB_TOKEN": "ghp_secret2", "SLACK_TOKEN": "xoxp-1", "SSH_AUTH_SOCK": "/tmp/agent",
    "PERL5OPT": "-Mevil", "DYLD_INSERT_LIBRARIES": "/x.dylib", "NODE_OPTIONS": "--require evil", "AWS_SECRET_ACCESS_KEY": "k",
]

enum RemoteExecTests {
    static let cases: [TestCase] = [
        TestCase("remote exec: Claude recibe solo la lista blanca") {
            let root = try RemoteRoot(verified: "/remote/home/.prbar")
            let exec = RemoteExec(argv: ["/usr/bin/env"], environment: RemoteEnvironment.claude(pathDirectories: ["/opt/claude/bin"], root: root))
            let lines = Set(try runLocalScript(try exec.script(), environment: dirty).split(separator: "\n").map(String.init))
            try expectEqual(lines, [
                "PATH=/opt/claude/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/remote/home", "USER=fede",
                "LANG=en_US.UTF-8", "SHELL=/bin/sh", "TMPDIR=/remote/home/.prbar/tmp",
            ])
        },
        TestCase("remote exec: git pasa solo sus variables y el agent del host; un token es un error interno") {
            let root = try RemoteRoot(verified: "/remote/home/.prbar")
            let env = try RemoteEnvironment.git(passing: ["GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": "Fede", "NODE_OPTIONS": "x"],
                                                pathDirectories: ["/usr/bin"], root: root)
            let lines = Set(try runLocalScript(try RemoteExec(argv: ["/usr/bin/env"], environment: env).script(), environment: dirty)
                .split(separator: "\n").map(String.init))
            try expect(lines.contains("GIT_TERMINAL_PROMPT=0") && lines.contains("GIT_AUTHOR_NAME=Fede"))
            try expect(lines.contains("SSH_AUTH_SOCK=/tmp/agent") && lines.contains("GIT_LFS_SKIP_SMUDGE=1"))
            try expect(!lines.contains { $0.hasPrefix("GH_TOKEN") || $0.hasPrefix("NODE_OPTIONS") || $0.hasPrefix("PERL5OPT") || $0.hasPrefix("AWS_") })
            let leak = try await expectThrows {
                _ = try RemoteEnvironment.git(passing: ["GH_TOKEN": "x"], pathDirectories: [], root: root)
            }
            try expectEqual(leak as? RemoteRunnerError, .secretInEnvironment("GH_TOKEN"))
        },
        TestCase("remote exec: una variable GIT_* desconocida es un error; GIT_INDEX_FILE solo dentro de <raíz>/tmp") {
            let root = try RemoteRoot(verified: "/remote/home/.prbar")
            for name in ["GIT_DIR", "GIT_SSH_COMMAND", "GIT_CONFIG_PARAMETERS", "GIT_EXEC_PATH", "GIT_CONFIG_COUNT", "GIT_WORK_TREE"] {
                let error = try await expectThrows { _ = try RemoteEnvironment.git(passing: [name: "x"], pathDirectories: [], root: root) }
                try expectEqual(error as? RemoteRunnerError, .unsupportedEnvironment(name))
            }
            let inside = root.tmp + "/chat-index-1"
            let env = try RemoteEnvironment.git(passing: ["GIT_INDEX_FILE": inside], pathDirectories: [], root: root)
            try expect(env.contains(.literal("GIT_INDEX_FILE", inside)), "\(env)")
            for outside in [root.work + "/x/.git/index", "/tmp/index", root.tmp, root.tmp + "/../work/i", root.tmp + "/a/b", "relative",
                            root.tmp + "/x\u{0301}/../i"] {
                let error = try await expectThrows {
                    _ = try RemoteEnvironment.git(passing: ["GIT_INDEX_FILE": outside], pathDirectories: [], root: root)
                }
                try expectEqual(error as? RemoteRunnerError, .unsupportedEnvironment("GIT_INDEX_FILE"))
            }
        },
        TestCase("remote exec: argumentos y cwd hostiles llegan intactos; nada se ejecuta") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let cwd = base.appendingPathComponent("it's a $(touch PWNED) dir")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            let values = ShellQuoteTests.hostile.filter { !$0.isEmpty } + [""]
            let exec = RemoteExec(argv: ["/usr/bin/printf", "%s\\0"] + values, cwd: cwd.path, environment: [.literal("PATH", "/usr/bin:/bin")])
            let output = try runLocalScript(try exec.script(), environment: dirty)
            var parts = output.components(separatedBy: "\0")
            parts.removeLast()
            try expectEqual(parts, values)
            try expect(!FileManager.default.fileExists(atPath: cwd.appendingPathComponent("PWNED").path))
            try expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("PWNED").path))
        },
        TestCase("remote exec: pid file con el grupo, stdin de un archivo remoto, umask 077") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let input = base.appendingPathComponent("prompt.txt")
            try Data("Review this PR".utf8).write(to: input)
            let pidFile = base.appendingPathComponent("job.pid").path
            let exec = RemoteExec(argv: ["/bin/sh", "-c", "cat; umask; cat \"$0\"; exit 7", pidFile], environment: [.literal("PATH", "/usr/bin:/bin")],
                                  standardInput: .remoteFile(input.path), pidFile: pidFile)
            let output = try runLocalScript(try exec.script(), environment: dirty)
            let lines = output.split(separator: "\n").map(String.init)
            try expectEqual(lines.first, "Review this PR0077")
            try expect(lines.count == 2 && Int(lines[1]).map { $0 > 1 } == true, output)
            // Al terminar, el shell borra el archivo del pgid (y sale con el código del comando).
            try expect(!FileManager.default.fileExists(atPath: pidFile))
            let status = try runLocalScriptStatus(try exec.script())
            try expectEqual(status, 7)
        },
        TestCase("remote exec: programas y variables inválidos se rechazan") {
            // Con marcas combinantes: para `String` "=\u{301}" o "-\u{301}" no es "=" ni "-", pero los bytes sí.
            for bad in ["", "rel/path", "a=b", "/x=y", "-x", "/a b/c\n", "/x=\u{0301}y", "-\u{0301}x", "/a/../\u{0301}b",
                        "a/\u{0301}b"] {
                let error = try? RemoteExec(argv: [bad], environment: []).script()
                try expect(error == nil, "aceptó \(bad)")
            }
            try expect((try? RemoteExec(argv: ["/bin/true"], environment: [.literal("A-B", "1")]).script()) == nil)
            try expect((try? RemoteExec(argv: ["git"], environment: []).script()) != nil)
        },
        TestCase("remote root: solo rutas absolutas verificadas; hijos confinados") {
            for bad in ["", "/", "/srv", "relative/x", "/a/../b", "/a/./b", "/a//b", "/a/b\n", "/a/b/"] {
                try expect((try? RemoteRoot(verified: bad)) == nil, "aceptó \(bad)")
            }
            let root = try RemoteRoot(verified: "/home/fede/.prbar")
            try expectEqual(try root.child(["work", "api-1-1700000000-abcdef12"]), "/home/fede/.prbar/work/api-1-1700000000-abcdef12")
            for bad in [[".."], ["work", ".."], ["a/b"], [""], ["-rf"], ["x\ny"], ["."]] {
                try expect((try? root.child(bad)) == nil, "aceptó \(bad)")
            }
            try expect(root.contains("/home/fede/.prbar/work/x"))
            try expect(!root.contains("/home/fede/.prbar") && !root.contains("/home/fede/.prbarx/y") && !root.contains("/home/fede/.prbar/../x")
                       && !root.contains("/home/fede/.prbar/work/../../x"))
            try expect(root.isRemovable("/home/fede/.prbar/work/x") && !root.isRemovable("/home/fede/.prbar/work"))
            // Byte a byte, nunca por grafemas ni equivalencia canónica.
            let accented = try RemoteRoot(verified: "/home/fede/caf\u{e9}")
            for bad in ["/home/fede/cafe\u{0301}/work/x", "/home/fede/caf\u{e9}/work/../\u{0301}x",
                        "/home/fede/caf\u{e9}/work/..", "/home/fede/caf\u{e9}/work/./x"] {
                try expect(!accented.contains(bad) && !accented.isRemovable(bad), "aceptó \(bad.unicodeScalars.map { String($0.value, radix: 16) })")
            }
            try expect(accented.isRemovable("/home/fede/caf\u{e9}/work/x\u{0301}"))
            try expect(!root.isRemovable("/home/fede/.prbar/work/../\u{0301}") && !root.contains("/home/fede/.prbar/\u{0301}/../../x"))
            try expect((try? RemoteRoot(verified: "/home/fede/x/../\u{0301}y")) == nil)
        },
    ]
}
