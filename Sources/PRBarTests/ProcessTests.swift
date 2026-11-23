import Foundation
import PRBarCore

private let ghStatusOutput = """
github.com
  ✓ Logged in to github.com account dev-sam (keyring)
  - Active account: true
  - Git operations protocol: https
  - Token: gho_************************************

  ✓ Logged in to github.com account sam-personal (keyring)
  - Active account: false
  - Git operations protocol: https

  ✓ Logged in to github.com account acme-bot (keyring)
  - Active account: false
"""

/// `true` si el proceso existe y no es un zombie.
private func isAlive(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return false }
    return info.pbi_status != UInt32(SZOMB)
}

/// Espera (hasta `timeout`) a que se cumpla `condition`, chequeando cada 50 ms. Si no se cumple a tiempo, el test
/// falla acá (y no más adelante, con un índice fuera de rango que tira abajo toda la corrida).
func waitUntil(timeout: TimeInterval = 5, file: StaticString = #fileID, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            throw TestFailure(description: "\(file):\(line) waitUntil timed out after \(timeout) s")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

enum ProcessTests {
    static let cases: [TestCase] = [
        TestCase("process: SystemProcessRunner captura stdout y código") {
            let result = try await SystemProcessRunner().run("/bin/echo", ["hola"])
            try expectEqual(result.status, 0)
            try expectEqual(result.stdout, "hola\n")
        },
        TestCase("process: SystemProcessRunner captura stderr y código de error") {
            let result = try await SystemProcessRunner().run("/bin/sh", ["-c", "echo err >&2; exit 3"])
            try expectEqual(result.status, 3)
            try expectEqual(result.stderr, "err\n")
        },
        TestCase("process: timeout mata el proceso y lanza timedOut") {
            let start = Date()
            let error = try await expectThrows {
                _ = try await SystemProcessRunner().run("/bin/sh", ["-c", "sleep 30"], timeout: 0.5)
            }
            let elapsed = Date().timeIntervalSince(start)
            try expect(error as? PRBarError == .timedOut(command: "sh -c sleep 30"), "\(error)")
            try expect(elapsed < 5, "tardó \(elapsed)s")
        },
        TestCase("process: un hijo en background que retiene stdout no cuelga") {
            let start = Date()
            let result = try await SystemProcessRunner().run("/bin/sh", ["-c", "sleep 30 & echo hi"], timeout: 3)
            let elapsed = Date().timeIntervalSince(start)
            try expectEqual(result.status, 0)
            try expectEqual(result.stdout, "hi\n")
            try expect(elapsed < 2.5, "tardó \(elapsed)s")
        },
        TestCase("process: salida grande se lee completa") {
            let result = try await SystemProcessRunner().run("/bin/sh", ["-c", "yes | head -c 300000"])
            try expectEqual(result.status, 0)
            try expectEqual(result.stdout.utf8.count, 300_000)
        },
        TestCase("process: cancelar la tarea mata el proceso") {
            let start = Date()
            let task = Task { try await SystemProcessRunner().run("/bin/sh", ["-c", "sleep 30"], timeout: 60) }
            try await Task.sleep(nanoseconds: 300_000_000)
            task.cancel()
            let error = try await expectThrows { _ = try await task.value }
            let elapsed = Date().timeIntervalSince(start)
            try expect(error is CancellationError, "\(error)")
            try expect(elapsed < 5, "tardó \(elapsed)s")
        },
        TestCase("process: SIGKILL si el proceso ignora SIGTERM") {
            let start = Date()
            let runner = SystemProcessRunner(killGracePeriod: 0.5)
            let error = try await expectThrows {
                _ = try await runner.run("/bin/sh", ["-c", "trap '' TERM; sleep 30; :"], timeout: 0.3)
            }
            let elapsed = Date().timeIntervalSince(start)
            try expect(error as? PRBarError == .timedOut(command: "sh -c trap '' TERM; sleep 30; :"), "\(error)")
            try expect(elapsed < 5, "tardó \(elapsed)s")
        },
        TestCase("process: runStreaming entrega las líneas de stdout a medida que llegan") {
            let lines = Box<[String]>([])
            let times = Box<[Date]>([])
            let result = try await SystemProcessRunner().runStreaming(
                "/bin/sh", ["-c", "echo uno; sleep 0.3; echo dos; printf tres"],
                environment: nil, currentDirectory: nil, timeout: 10
            ) { line in
                lines.value.append(line)
                times.value.append(Date())
            }
            try expectEqual(lines.value, ["uno", "dos", "tres"])
            try expectEqual(result.status, 0)
            try expectEqual(result.stdout, "uno\ndos\ntres")
            let gap = times.value.last!.timeIntervalSince(times.value.first!)
            try expect(gap >= 0.2, "la primera línea llegó \(gap)s antes que la última")
        },
        TestCase("process: a streaming run keeps only the tail of stdout; every line still reaches the callback") {
            let count = Box(0)
            let result = try await SystemProcessRunner().runStreaming(
                "/bin/sh", ["-c", "yes | head -n 1500000; echo last"],
                environment: nil, currentDirectory: nil, timeout: 30
            ) { _ in count.value += 1 }
            try expectEqual(count.value, 1_500_001)
            try expect(result.stdout.utf8.count <= ProcessOutputLimits.streamingStdout, "\(result.stdout.utf8.count)")
            try expect(result.stdout.hasSuffix("y\nlast\n"))
        },
        TestCase("process: ByteTail keeps the newest bytes up to its limit") {
            var tail = ByteTail(limit: 4)
            try expectEqual(tail.data, Data())
            tail.append(contentsOf: Array("ab".utf8))
            try expectEqual(String(decoding: tail.data, as: UTF8.self), "ab")
            for chunk in ["cd", "ef", "gh", "ij", "k"] { tail.append(contentsOf: Array(chunk.utf8)) }
            try expectEqual(String(decoding: tail.data, as: UTF8.self), "hijk")
        },
        TestCase("process: LineTail keeps the last lines in order") {
            var tail = LineTail(limit: 3)
            try expectEqual(tail.text, "")
            tail.append("1")
            tail.append("2")
            try expectEqual(tail.text, "1\n2")
            for line in ["3", "4", "5", "6", "7"] { tail.append(line) }
            try expectEqual(tail.text, "5\n6\n7")
        },
        TestCase("process: runStreaming entrega una línea larga entera") {
            let lines = Box<[String]>([])
            let result = try await SystemProcessRunner().runStreaming(
                "/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\0' x; echo"],
                environment: nil, currentDirectory: nil, timeout: 10
            ) { lines.value.append($0) }
            try expectEqual(lines.value.count, 1)
            try expectEqual(lines.value.first?.count, 200_000)
            try expect(lines.value.first?.allSatisfy { $0 == "x" } == true)
            try expectEqual(result.stdout.utf8.count, 200_001)
        },
        TestCase("process: runStreaming decodifica UTF-8 multibyte") {
            let lines = Box<[String]>([])
            _ = try await SystemProcessRunner().runStreaming(
                "/bin/sh", ["-c", "printf 'añ\\nñ\\n'"],
                environment: nil, currentDirectory: nil, timeout: 10
            ) { lines.value.append($0) }
            try expectEqual(lines.value, ["añ", "ñ"])
        },
        TestCase("process: runStreaming no rompe un carácter partido entre dos lecturas") {
            // ñ = C3 B1: el primer byte llega en una lectura y el segundo en otra.
            let lines = Box<[String]>([])
            let result = try await SystemProcessRunner().runStreaming(
                "/bin/sh", ["-c", "printf 'a\\303'; sleep 0.3; printf '\\261\\nfin\\n'"],
                environment: nil, currentDirectory: nil, timeout: 10
            ) { lines.value.append($0) }
            try expectEqual(lines.value, ["añ", "fin"])
            try expectEqual(result.stdout, "añ\nfin\n")
        },
        TestCase("process: runStreaming con timeout mata el proceso y lanza timedOut") {
            let start = Date()
            let lines = Box<[String]>([])
            let error = try await expectThrows {
                _ = try await SystemProcessRunner().runStreaming(
                    "/bin/sh", ["-c", "echo antes; sleep 30"],
                    environment: nil, currentDirectory: nil, timeout: 0.5
                ) { lines.value.append($0) }
            }
            let elapsed = Date().timeIntervalSince(start)
            try expect(error as? PRBarError == .timedOut(command: "sh -c echo antes; sleep 30"), "\(error)")
            try expect(elapsed < 5, "tardó \(elapsed)s")
            try expectEqual(lines.value, ["antes"])
        },
        TestCase("process: runStreaming se cancela con la tarea") {
            let start = Date()
            let task = Task {
                try await SystemProcessRunner().runStreaming(
                    "/bin/sh", ["-c", "sleep 30"], environment: nil, currentDirectory: nil, timeout: 60
                ) { _ in }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            task.cancel()
            let error = try await expectThrows { _ = try await task.value }
            let elapsed = Date().timeIntervalSince(start)
            try expect(error is CancellationError, "\(error)")
            try expect(elapsed < 5, "tardó \(elapsed)s")
        },
        TestCase("process: runStreaming hace SIGKILL si el proceso ignora SIGTERM") {
            let start = Date()
            let runner = SystemProcessRunner(killGracePeriod: 0.5)
            let error = try await expectThrows {
                _ = try await runner.runStreaming(
                    "/bin/sh", ["-c", "trap '' TERM; sleep 30; :"],
                    environment: nil, currentDirectory: nil, timeout: 0.3
                ) { _ in }
            }
            let elapsed = Date().timeIntervalSince(start)
            try expect(error as? PRBarError == .timedOut(command: "sh -c trap '' TERM; sleep 30; :"), "\(error)")
            try expect(elapsed < 5, "tardó \(elapsed)s")
        },
        TestCase("process: cancelar mata también a los nietos (todo el grupo de procesos)") {
            let pids = Box<[pid_t]>([])
            let task = Task {
                try await SystemProcessRunner(killGracePeriod: 0.5).runStreaming(
                    "/bin/sh", ["-c", "sleep 30 & echo $!; sleep 30"], environment: nil, currentDirectory: nil, timeout: 60
                ) { line in if let pid = pid_t(line) { pids.value.append(pid) } }
            }
            try await waitUntil { !pids.value.isEmpty }
            task.cancel()
            let error = try await expectThrows { _ = try await task.value }
            try expect(error is CancellationError, "\(error)")
            let grandchild = pids.value[0]
            try await waitUntil { !isAlive(grandchild) }
            try expect(!isAlive(grandchild), "el nieto \(grandchild) sigue vivo")
        },
        TestCase("process: el timeout mata también a los nietos, aunque el líder ya haya terminado") {
            let pids = Box<[pid_t]>([])
            // El líder muere con el SIGTERM, pero el nieto lo ignora: solo el SIGKILL al grupo, que se manda
            // aunque el líder ya haya terminado, lo frena.
            let error = try await expectThrows {
                _ = try await SystemProcessRunner(killGracePeriod: 0.5).runStreaming(
                    "/bin/sh", ["-c", "(trap '' TERM; sleep 30) & echo $!; sleep 30"],
                    environment: nil, currentDirectory: nil, timeout: 0.5
                ) { line in if let pid = pid_t(line) { pids.value.append(pid) } }
            }
            try expect(error as? PRBarError != nil, "\(error)")
            try expectEqual(pids.value.count, 1)
            let grandchild = pids.value[0]
            try await waitUntil { !isAlive(grandchild) }
            try expect(!isAlive(grandchild), "el nieto \(grandchild) sigue vivo")
        },
        TestCase("process: run sin streaming también mata a los nietos al cancelar") {
            let marker = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: marker) }
            let pidFile = marker.appendingPathComponent("pid")
            let task = Task {
                try await SystemProcessRunner(killGracePeriod: 0.5).run(
                    "/bin/sh", ["-c", "sleep 30 & echo $! > '\(pidFile.path)'; sleep 30"],
                    environment: nil, currentDirectory: nil, timeout: 60
                )
            }
            try await waitUntil { (try? String(contentsOf: pidFile, encoding: .utf8))?.hasSuffix("\n") == true }
            let grandchild = pid_t((try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))
            task.cancel()
            _ = try? await task.value
            guard let grandchild else { throw TestFailure(description: "sin pid del nieto") }
            try await waitUntil { !isAlive(grandchild) }
            try expect(!isAlive(grandchild), "el nieto \(grandchild) sigue vivo")
        },
        TestCase("process: SystemProcessRunner no hereda tokens de GitHub; solo pasan si se dan explícitamente") {
            setenv("GITHUB_TOKEN", "heredado-1", 1)
            setenv("GH_TOKEN", "heredado-2", 1)
            defer { unsetenv("GITHUB_TOKEN"); unsetenv("GH_TOKEN") }
            let runner = SystemProcessRunner()
            let inherited = try await runner.run("/usr/bin/env", [], environment: nil, currentDirectory: nil, timeout: 5)
            try expect(!inherited.stdout.contains("heredado"), inherited.stdout)
            try expect(inherited.stdout.contains("HOME="), inherited.stdout)
            let explicit = try await runner.run("/usr/bin/env", [], environment: ["GH_TOKEN": "explícito"], currentDirectory: nil, timeout: 5)
            try expect(explicit.stdout.contains("GH_TOKEN=explícito"), explicit.stdout)
            try expect(!explicit.stdout.contains("heredado"), explicit.stdout)
        },
        TestCase("process: runStreamingIsolated pasa exactamente el entorno dado, sin heredar nada") {
            setenv("PRBAR_TEST_HEREDADA", "no-debe-llegar", 1)
            defer { unsetenv("PRBAR_TEST_HEREDADA") }
            let lines = Box<[String]>([])
            let result = try await SystemProcessRunner().runStreamingIsolated(
                "/usr/bin/env", [], environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/h"], currentDirectory: nil, timeout: 5
            ) { lines.value.append($0) }
            try expectEqual(result.status, 0)
            try expectEqual(Set(lines.value), ["PATH=/usr/bin:/bin", "HOME=/tmp/h"])
        },
        TestCase("process: FakeStreamingRunner emite las líneas y guarda la llamada") {
            let runner = FakeStreamingRunner { _, _, _ in (lines: ["a", "b"], result: ok("a\nb\n")) }
            let lines = Box<[String]>([])
            let dir = URL(fileURLWithPath: "/tmp/x")
            let result = try await runner.runStreaming(
                "/claude", ["-p"], environment: ["K": "V"], currentDirectory: dir, timeout: 5
            ) { lines.value.append($0) }
            try expectEqual(lines.value, ["a", "b"])
            try expectEqual(result, ok("a\nb\n"))
            try expectEqual(runner.calls.count, 1)
            try expectEqual(runner.calls[0].executable, "/claude")
            try expectEqual(runner.calls[0].arguments, ["-p"])
            try expectEqual(runner.calls[0].environment, ["K": "V"])
            try expectEqual(runner.calls[0].currentDirectory, dir)
            try expectEqual(runner.calls[0].timeout, 5)
        },
        TestCase("accounts: gh usa el timeout por defecto de 10s") {
            let runner = FakeProcessRunner { _, _ in ok("gho_abc\n") }
            let provider = AccountProvider(runner: runner, ghPath: "/gh")
            _ = try await provider.token(for: "x")
            _ = try await provider.listAccounts()
            try expectEqual(runner.calls.map(\.timeout), [10, 10])
        },
        TestCase("accounts: parsea gh auth status con varias cuentas") {
            let accounts = AccountProvider.parseStatus(ghStatusOutput)
            try expectEqual(accounts.map(\.login), ["dev-sam", "sam-personal", "acme-bot"])
            try expectEqual(accounts.map(\.isActive), [true, false, false])
        },
        TestCase("accounts: sin sesión → lista vacía") {
            try expectEqual(AccountProvider.parseStatus("You are not logged into any GitHub hosts. To log in, run: gh auth login"), [])
        },
        TestCase("accounts: listAccounts lee stdout y stderr") {
            let runner = FakeProcessRunner { _, _ in ProcessResult(status: 0, stdout: "", stderr: ghStatusOutput) }
            let provider = AccountProvider(runner: runner, ghPath: "/usr/local/bin/gh")
            let accounts = try await provider.listAccounts()
            try expectEqual(accounts.count, 3)
            try expectEqual(runner.calls[0].arguments, ["auth", "status", "--hostname", "github.com"])
        },
        TestCase("accounts: token pide el de la cuenta indicada") {
            let runner = FakeProcessRunner { _, _ in ok("gho_abc\n") }
            let provider = AccountProvider(runner: runner, ghPath: "/usr/local/bin/gh")
            let token = try await provider.token(for: "acme-bot")
            try expectEqual(token, "gho_abc")
            try expectEqual(runner.calls[0].arguments, ["auth", "token", "--hostname", "github.com", "--user", "acme-bot"])
        },
        TestCase("accounts: token falla → commandFailed") {
            let provider = AccountProvider(runner: FakeProcessRunner { _, _ in fail("no account") }, ghPath: "/gh")
            let error = try await expectThrows { _ = try await provider.token(for: "x") }
            try expect(error as? PRBarError == .commandFailed(command: "gh auth token --user x", status: 1, stderr: "no account"))
        },
        TestCase("accounts: sin ruta de gh → toolNotFound") {
            let provider = AccountProvider(runner: FakeProcessRunner { _, _ in ok("") }, ghPath: nil)
            let error = try await expectThrows { _ = try await provider.token(for: "x") }
            try expect(error as? PRBarError == .toolNotFound("gh"))
        },
        TestCase("accounts: ghPath se puede leer y escribir en paralelo") {
            let provider = AccountProvider(runner: FakeProcessRunner { _, _ in ok("tok") }, ghPath: "/a/gh")
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<5_000 {
                    // Rutas largas (> 15 bytes) para que vivan en el heap y una carrera rompa el refcount.
                    group.addTask { provider.ghPath = "/opt/homebrew/very/long/path/\(i)/gh" }
                    group.addTask { _ = provider.ghPath }
                }
            }
            provider.ghPath = "/c/gh"
            let path = provider.ghPath
            try expectEqual(path, "/c/gh")
        },
        TestCase("tools: usa la última línea de command -v") {
            let runner = FakeProcessRunner { _, _ in ok("ruido del profile\n/usr/local/bin/gh\n") }
            let locator = ToolLocator(runner: runner, home: "/Users/x", isExecutable: { $0 == "/usr/local/bin/gh" })
            let path = await locator.locate("gh", override: nil)
            try expectEqual(path, "/usr/local/bin/gh")
            try expectEqual(runner.calls[0].arguments, ["-lc", "command -v gh"])
            try expectEqual(runner.calls[0].timeout, 10)
        },
        TestCase("tools: override no ejecutable → nil") {
            let locator = ToolLocator(runner: FakeProcessRunner { _, _ in ok("") }, home: "/Users/x", isExecutable: { _ in false })
            let path = await locator.locate("gh", override: "/nope/gh")
            try expectEqual(path, nil)
        },
        TestCase("tools: si el shell falla, prueba rutas conocidas") {
            let locator = ToolLocator(runner: FakeProcessRunner { _, _ in fail("") }, home: "/Users/x", isExecutable: { $0 == "/Users/x/.local/bin/claude" })
            let path = await locator.locate("claude", override: nil)
            try expectEqual(path, "/Users/x/.local/bin/claude")
        },
        TestCase("repo path: reconoce remotes https y ssh") {
            let repo = RepoRef(owner: "Acme", name: "Web-App")
            try expect(RepoPathValidator.remoteMatches("origin\thttps://github.com/Acme/Web-App.git (fetch)\n", repo: repo))
            try expect(RepoPathValidator.remoteMatches("origin\tgit@github.com:acme/web-app.git (push)\n", repo: repo))
            try expect(!RepoPathValidator.remoteMatches("origin\thttps://github.com/Acme/Web-App-Admin.git (fetch)\n", repo: repo))
        },
        TestCase("repo path: carpeta que no es repo → mensaje de error") {
            let runner = FakeProcessRunner { _, _ in fail("fatal: not a git repository", status: 128) }
            let message = await RepoPathValidator.validate(path: "/tmp", repo: RepoRef(owner: "o", name: "r"), runner: runner, gitPath: "/usr/bin/git")
            try expectEqual(message, "The folder isn't a git repository.")
            try expectEqual(runner.calls[0].arguments, ["-C", "/tmp", "remote", "-v"])
        },
    ]
}
