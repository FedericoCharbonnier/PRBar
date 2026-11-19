import Foundation
import PRBarCore

private struct Answer: Decodable, Equatable {
    let summary: String
}

private let schema = #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}"#
private let agentLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}"#
private let validLine = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"Listo."}}"#
private let invalidLine = #"{"type":"result","subtype":"success","is_error":false,"result":"sin json"}"#

private let readOnly = ["Read", "Grep", "Glob", "Skill", "Agent"]
private let plugins = ["/plugins/pr-review-toolkit/unknown", "/plugins/superpowers/5.0.7"]
private let workdir = URL(fileURLWithPath: "/tmp/wt/r-7-1")
private let environment = ["PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]

private func invocation(tools: [String] = readOnly, extra: [URL] = [URL(fileURLWithPath: "/tmp/wt/r-7-1.context")],
                        header: String = "=== prueba ===") -> ClaudeInvocation {
    ClaudeInvocation(prompt: "Hacé algo.", schema: schema, tools: tools, workingDirectory: workdir,
                     additionalDirectories: extra, timeout: 42, logHeader: header)
}

private func claude(_ runner: FakeStreamingRunner, log: URL, secrets: [String] = [],
                    environment: [String: String] = environment) -> ClaudeRunner {
    ClaudeRunner(runner: runner, claudePath: "/usr/local/bin/claude", pluginDirs: plugins,
                 environment: environment, logURL: log, redacting: secrets)
}

private func logFile() throws -> URL {
    try temporaryDirectory().appendingPathComponent("logs/claude.log")
}

private func prompt(of call: FakeStreamingRunner.Call) -> String {
    guard let index = call.arguments.firstIndex(of: "-p") else { return "" }
    return call.arguments[index + 1]
}

private func value(of flag: String, in arguments: [String]) -> String? {
    arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
}

enum ClaudeRunnerTests {
    static let cases: [TestCase] = [
        TestCase("claude runner: con deadline, cada intento (también el reintento) usa solo lo que queda; vencido no lanza nada") {
            let runner = FakeStreamingRunner { _, _, _ in ([invalidLine], ok("")) }
            var budget = invocation()
            budget.timeout = 600
            budget.deadline = Date().addingTimeInterval(30)
            _ = try await expectThrows { _ = try await claude(runner, log: try logFile()).run(budget, as: Answer.self, onAgent: { _ in }) }
            try expectEqual(runner.calls.count, 2)
            try expect(runner.calls.allSatisfy { ($0.timeout ?? 999) <= 30 && ($0.timeout ?? 0) > 20 }, "\(runner.calls.map(\.timeout))")
            let late = FakeStreamingRunner { _, _, _ in ([validLine], ok("")) }
            budget.deadline = Date().addingTimeInterval(-1)
            let error = try await expectThrows { _ = try await claude(late, log: try logFile()).run(budget, as: Answer.self, onAgent: { _ in }) }
            guard case .timedOut? = error as? PRBarError else { throw TestFailure(description: "\(error)") }
            try expectEqual(late.calls.count, 0)
        },
        TestCase("claude runner: argumentos aislados con herramientas de solo lectura acotadas al cwd") {
            let args = ClaudeRunner.arguments(for: invocation(), pluginDirs: plugins)
            try expectEqual(args, [
                "-p", "Hacé algo.", "--output-format", "stream-json", "--verbose", "--json-schema", schema,
                "--setting-sources", "",
                "--settings", ClaudeRunner.settings(additionalDirectories: [URL(fileURLWithPath: "/tmp/wt/r-7-1.context")]),
                "--plugin-dir", "/plugins/pr-review-toolkit/unknown",
                "--plugin-dir", "/plugins/superpowers/5.0.7",
                "--permission-mode", "dontAsk",
                "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                "--tools", "Read,Grep,Glob,Skill,Agent",
                // Nunca `Read`, `Grep` ni `Glob` sueltos: un permiso sin ruta vale para cualquier archivo del disco.
                "--allowedTools", "Read(./**),Skill,Agent",
                "--disallowedTools", "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,mcp__*",
                "--add-dir", "/tmp/wt/r-7-1.context",
            ])
        },
        TestCase("claude runner: the configured model goes in --model; without one, no flag") {
            let args = ClaudeRunner.arguments(for: invocation(), pluginDirs: plugins, model: .sonnet)
            try expectEqual(Array(args.prefix(4)), ["-p", "Hacé algo.", "--model", "sonnet"])
            try expectEqual(Array(args.dropFirst(4)), Array(ClaudeRunner.arguments(for: invocation(), pluginDirs: plugins).dropFirst(2)))
            try expect(!ClaudeRunner.arguments(for: invocation(), pluginDirs: plugins).contains("--model"))
            let runner = FakeStreamingRunner { _, _, _ in ([validLine], ok("")) }
            let withModel = ClaudeRunner(runner: runner, claudePath: "/usr/local/bin/claude", pluginDirs: plugins,
                                         environment: environment, logURL: try logFile(), redacting: [], model: .opus)
            _ = try await withModel.run(invocation(), as: Answer.self, onAgent: { _ in })
            try expectEqual(value(of: "--model", in: runner.calls[0].arguments), "opus")
        },
        TestCase("claude runner: con Edit y Write los acota al cwd y sigue negando shell, red y MCP") {
            let tools = readOnly + ["Edit", "Write"]
            let args = ClaudeRunner.arguments(
                for: invocation(tools: tools, extra: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]),
                pluginDirs: []
            )
            try expectEqual(value(of: "--tools", in: args), "Read,Grep,Glob,Skill,Agent,Edit,Write")
            // Write se rige por las reglas de Edit.
            try expectEqual(value(of: "--allowedTools", in: args), "Read(./**),Edit(./**),Skill,Agent")
            try expectEqual(value(of: "--disallowedTools", in: args), "Bash,NotebookEdit,WebFetch,WebSearch,mcp__*")
            try expectEqual(value(of: "--setting-sources", in: args), "")
            try expectEqual(value(of: "--permission-mode", in: args), "dontAsk")
            try expectEqual(value(of: "--mcp-config", in: args), #"{"mcpServers":{}}"#)
            try expect(args.contains("--strict-mcp-config"))
            try expect(!args.contains("--plugin-dir"))
            try expectEqual(args.suffix(4), ["--add-dir", "/a", "--add-dir", "/b"])
            // Solo Edit: Write sigue negada.
            let onlyEdit = ClaudeRunner.arguments(for: invocation(tools: readOnly + ["Edit"]), pluginDirs: [])
            try expectEqual(value(of: "--disallowedTools", in: onlyEdit), "Bash,Write,NotebookEdit,WebFetch,WebSearch,mcp__*")
            try expectEqual(value(of: "--allowedTools", in: onlyEdit), "Read(./**),Edit(./**),Skill,Agent")
            // Ninguna herramienta de archivos queda permitida sin ruta.
            for list in [args, onlyEdit, ClaudeRunner.arguments(for: invocation(), pluginDirs: [])] {
                let allowed = (value(of: "--allowedTools", in: list) ?? "").split(separator: ",").map(String.init)
                for bare in ["Read", "Grep", "Glob", "Edit", "Write", "NotebookEdit"] {
                    try expect(!allowed.contains(bare), "\(bare) suelto en \(allowed)")
                }
            }
        },
        TestCase("claude runner: --settings bloquea lecturas y escrituras fuera del cwd, niega secretos y el shell de los skills") {
            let json = ClaudeRunner.settings(additionalDirectories: [URL(fileURLWithPath: "/tmp/ctx dir"), URL(fileURLWithPath: "/b")])
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
            try expectEqual(object["disableSkillShellExecution"] as? Bool, true)
            let permissions = object["permissions"] as? [String: Any] ?? [:]
            try expectEqual(permissions["blockReadsOutsideWorkingDirectories"] as? Bool, true)
            try expectEqual(permissions["blockWritesOutsideWorkingDirectories"] as? Bool, true)
            try expectEqual(permissions["disableBypassPermissionsMode"] as? String, "disable")
            // Las carpetas extra solo se pueden leer (con ruta absoluta: `//` + la ruta; los espacios no rompen nada).
            try expectEqual(permissions["allow"] as? [String], ["Read(//tmp/ctx dir/**)", "Read(//b/**)"])
            let deny = permissions["deny"] as? [String] ?? []
            for path in ["~/.ssh/**", "~/.aws/**", "~/.config/**", "~/Library/**", "~/.gnupg/**", "//**/.env*"] {
                try expect(deny.contains("Read(\(path))") && deny.contains("Edit(\(path))"), "falta \(path) en \(deny)")
            }
            try expectEqual(ClaudeRunner.deniedPaths, ["~/.ssh/**", "~/.aws/**", "~/.config/**", "~/Library/**", "~/.gnupg/**", "//**/.env*"])
            // Edit/Write can't touch git's files anywhere (verified with the real CLI 2.1.318: `.gitattributes` and
            // `.lfsconfig` were writable without these rules; `.git` was already protected by the CLI).
            for rule in ["Edit(//**/.git)", "Edit(//**/.git/**)", "Edit(//**/.gitattributes)", "Edit(//**/.lfsconfig)"] {
                try expect(deny.contains(rule), "falta \(rule) en \(deny)")
            }
            try expect(!deny.contains("Read(//**/.gitattributes)"), "\(deny)")
            // Determinístico: el mismo JSON para la misma entrada.
            try expectEqual(json, ClaudeRunner.settings(additionalDirectories: [URL(fileURLWithPath: "/tmp/ctx dir"), URL(fileURLWithPath: "/b")]))
        },
        TestCase("claude runner: un cwd o una carpeta extra dentro de una ruta negada se rechaza sin lanzar nada") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            for (cwd, extra) in [
                (home.appendingPathComponent("Library/Caches/PRBar/worktrees/r-7-1"), [URL]()),
                (workdir, [home.appendingPathComponent(".config/x")]),
                (home.appendingPathComponent(".ssh"), [URL]()),
            ] {
                let runner = FakeStreamingRunner { _, _, _ in ([validLine], ok("")) }
                let bad = ClaudeInvocation(prompt: "x", schema: schema, tools: readOnly, workingDirectory: cwd,
                                           additionalDirectories: extra, timeout: 1, logHeader: "x")
                let error = try await expectThrows {
                    _ = try await claude(runner, log: try logFile()).run(bad, as: Answer.self, onAgent: { _ in })
                }
                guard case .deniedDirectory? = error as? ClaudeRunnerError else {
                    throw TestFailure(description: "\(cwd.path): error inesperado \(error)")
                }
                try expectEqual(runner.calls.count, 0)
            }
        },
        TestCase("claude runner: una invocación con Bash es rechazada sin lanzar nada") {
            for tools in [readOnly + ["Bash"], ["Bash(git:*)"], ["BashOutput"], readOnly + ["WebFetch"], ["NotebookEdit"]] {
                let runner = FakeStreamingRunner { _, _, _ in ([validLine], ok("")) }
                let log = try logFile()
                let error = try await expectThrows {
                    _ = try await claude(runner, log: log).run(invocation(tools: tools), as: Answer.self, onAgent: { _ in })
                }
                guard case .forbiddenTool? = error as? ClaudeRunnerError else {
                    throw TestFailure(description: "\(tools): error inesperado \(error)")
                }
                try expectEqual(runner.calls.count, 0)
                try expect(!FileManager.default.fileExists(atPath: log.path), "no debe escribir el log")
            }
            let runner = FakeStreamingRunner { _, _, _ in ([validLine], ok("")) }
            let error = try await expectThrows {
                _ = try await claude(runner, log: try logFile()).run(invocation(tools: ["Read", "Bash"]), as: Answer.self, onAgent: { _ in })
            }
            try expectEqual(error as? ClaudeRunnerError, .forbiddenTool("Bash"))
        },
        TestCase("claude runner: un token en una variable permitida es rechazado sin lanzar nada") {
            let runner = FakeStreamingRunner { _, _, _ in ([validLine], ok("")) }
            let error = try await expectThrows {
                _ = try await claude(runner, log: try logFile(), secrets: ["gho_SECRETO"],
                                     environment: ["PATH": "/usr/bin", "LANG": "Bearer gho_SECRETO"])
                    .run(invocation(), as: Answer.self, onAgent: { _ in })
            }
            try expectEqual(error as? ClaudeRunnerError, .secretInEnvironment(variable: "LANG"))
            try expectEqual(runner.calls.count, 0)
        },
        TestCase("claude runner: el entorno es una lista blanca; todo lo demás se descarta y no se hereda") {
            let runner = FakeStreamingRunner { _, _, _ in ([validLine], ok("")) }
            let env = ["PATH": "/usr/bin", "HOME": "/Users/me", "GH_TOKEN": "ghp_x", "AWS_SECRET_ACCESS_KEY": "a",
                       "SSH_AUTH_SOCK": "/tmp/s", "ANTHROPIC_API_KEY": "k", "SHELL": "/bin/zsh"]
            _ = try await claude(runner, log: try logFile(), environment: env).run(invocation(), as: Answer.self, onAgent: { _ in })
            try expectEqual(runner.calls[0].environment, ["PATH": "/usr/bin", "HOME": "/Users/me", "SHELL": "/bin/zsh"])
            // El proceso recibe exactamente ese entorno: sin heredar el de la app.
            try expectEqual(runner.isolated, [true])
        },
        TestCase("claude runner: environment arma la lista blanca (PATH, HOME, USER, LOGNAME, TMPDIR, LANG, LC_ALL, SHELL=zsh)") {
            let inherited = ["HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "TMPDIR": "/var/folders/x/T/",
                             "LANG": "es_AR.UTF-8", "LC_ALL": "es_AR.UTF-8", "SHELL": "/bin/bash",
                             "GH_TOKEN": "ghp_x", "GITHUB_TOKEN": "y", "AWS_PROFILE": "p", "SSH_AUTH_SOCK": "/tmp/s",
                             "PATH": "/evil/bin:/usr/bin", "DYLD_INSERT_LIBRARIES": "/x.dylib", "NODE_OPTIONS": "--require x"]
            let env = ClaudeRunner.environment(toolPaths: ["/opt/homebrew/bin/git"], inherited: inherited)
            try expectEqual(env, [
                "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/me", "USER": "me", "LOGNAME": "me",
                "TMPDIR": "/var/folders/x/T/", "LANG": "es_AR.UTF-8", "LC_ALL": "es_AR.UTF-8", "SHELL": "/bin/zsh",
            ])
            try expectEqual(Set(ClaudeRunner.environmentAllowlist),
                            ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"])
            // Lo que falta en el entorno de la app no se inventa (salvo HOME, USER y LOGNAME, que se averiguan).
            let minimal = ClaudeRunner.environment(toolPaths: [], inherited: [:])
            try expectEqual(minimal["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
            try expectEqual(minimal["SHELL"], "/bin/zsh")
            try expectEqual(minimal["HOME"], NSHomeDirectory())
            try expectEqual(minimal["USER"], NSUserName())
            try expect(minimal["LC_ALL"] == nil)
            try expect(Set(minimal.keys).isSubset(of: Set(ClaudeRunner.environmentAllowlist)))
        },
        TestCase("claude runner: pasa ejecutable, entorno, cwd y timeout, y decodifica la salida") {
            let runner = FakeStreamingRunner { _, _, _ in ([validLine], ok("")) }
            let answer = try await claude(runner, log: try logFile()).run(invocation(), as: Answer.self, onAgent: { _ in })
            try expectEqual(answer, Answer(summary: "Listo."))
            let call = runner.calls[0]
            try expectEqual(call.executable, "/usr/local/bin/claude")
            try expectEqual(call.arguments, ClaudeRunner.arguments(for: invocation(), pluginDirs: plugins))
            try expectEqual(call.environment, environment)
            try expectEqual(runner.isolated, [true])
            try expectEqual(call.currentDirectory, workdir)
            try expectEqual(call.timeout, 42)
        },
        TestCase("claude runner: onAgent recibe 0 al empezar y el total de subagentes, en orden") {
            let runner = FakeStreamingRunner { _, _, _ in ([agentLine, agentLine, validLine], ok("")) }
            let seen = Box<[Int]>([])
            _ = try await claude(runner, log: try logFile()).run(invocation(), as: Answer.self) { seen.value.append($0) }
            try expectEqual(seen.value, [0, 1, 2])
        },
        TestCase("claude runner: salida inválida se reintenta una vez, con su encabezado en el log") {
            let attempts = Box(0)
            let runner = FakeStreamingRunner { _, _, _ in
                attempts.value += 1
                return (attempts.value == 1 ? [invalidLine] : [agentLine, validLine], ok(""))
            }
            let log = try logFile()
            let seen = Box<[Int]>([])
            let answer = try await claude(runner, log: log).run(invocation(header: "=== stage 1 ==="), as: Answer.self) {
                seen.value.append($0)
            }
            try expectEqual(answer.summary, "Listo.")
            try expectEqual(runner.calls.count, 2)
            try expectEqual(seen.value, [0, 0, 1])
            try expectEqual(prompt(of: runner.calls[0]), "Hacé algo.")
            let retry = prompt(of: runner.calls[1])
            try expect(retry.hasPrefix("Hacé algo.\n\nThe previous attempt returned an invalid result"), retry)
            let text = try String(contentsOf: log, encoding: .utf8)
            let first = text.range(of: "=== stage 1 ===\n")
            let marker = text.range(of: "--- invalid result:")
            let second = text.range(of: "=== stage 1 (retry) ===\n")
            try expect(first != nil && marker != nil && second != nil, text)
            try expect(first!.lowerBound < marker!.lowerBound && marker!.lowerBound < second!.lowerBound, text)
            try expect(text.contains(invalidLine) && text.contains(validLine), text)
        },
        TestCase("claude runner: dos salidas inválidas propagan invalidOutput") {
            let runner = FakeStreamingRunner { _, _, _ in ([invalidLine], ok("")) }
            let error = try await expectThrows {
                _ = try await claude(runner, log: try logFile()).run(invocation(), as: Answer.self, onAgent: { _ in })
            }
            guard case .invalidOutput? = error as? ClaudeError else { throw TestFailure(description: "error inesperado: \(error)") }
            try expectEqual(runner.calls.count, 2)
        },
        TestCase("claude runner: sin resultado se reintenta; un resultado de error no") {
            let empty = FakeStreamingRunner { _, _, _ in ([], ok("")) }
            let noResult = try await expectThrows {
                _ = try await claude(empty, log: try logFile()).run(invocation(), as: Answer.self, onAgent: { _ in })
            }
            try expectEqual(noResult as? ClaudeError, .noResult)
            try expectEqual(empty.calls.count, 2)

            let errorLine = #"{"type":"result","subtype":"error","is_error":true,"result":"se rompió"}"#
            let failing = FakeStreamingRunner { _, _, _ in ([errorLine], ok("")) }
            let failed = try await expectThrows {
                _ = try await claude(failing, log: try logFile()).run(invocation(), as: Answer.self, onAgent: { _ in })
            }
            try expectEqual(failed as? ClaudeError, .failed("se rompió"))
            try expectEqual(failing.calls.count, 1)
        },
        TestCase("claude runner: salida ≠ 0 sin result lanza commandFailed sin reintentar") {
            let runner = FakeStreamingRunner { _, _, _ in ([], fail("boom\n", status: 2)) }
            let error = try await expectThrows {
                _ = try await claude(runner, log: try logFile()).run(invocation(), as: Answer.self, onAgent: { _ in })
            }
            try expectEqual(error as? PRBarError, .commandFailed(command: "claude", status: 2, stderr: "boom"))
            try expectEqual(runner.calls.count, 1)
        },
        TestCase("claude runner: si el proceso lanza, lo deja en el log y lo relanza") {
            let runner = FakeStreamingRunner { _, _, _ in throw PRBarError.timedOut(command: "claude") }
            let log = try logFile()
            let error = try await expectThrows {
                _ = try await claude(runner, log: log).run(invocation(), as: Answer.self, onAgent: { _ in })
            }
            try expectEqual(error as? PRBarError, .timedOut(command: "claude"))
            try expectEqual(runner.calls.count, 1)
            let text = try String(contentsOf: log, encoding: .utf8)
            try expect(text.contains("=== prueba ===") && text.contains("--- "), text)
        },
        TestCase("claude runner: el token se tacha del log, de la salida y de los errores") {
            let secret = "gho_SECRETO123"
            let leaky = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"Vi gho_SECRETO123."}}"#
            let runner = FakeStreamingRunner { _, _, _ in
                ([leaky], ProcessResult(status: 0, stdout: "", stderr: "stderr con gho_SECRETO123"))
            }
            let log = try logFile()
            let answer = try await claude(runner, log: log, secrets: [secret, ""]).run(invocation(), as: Answer.self, onAgent: { _ in })
            try expectEqual(answer.summary, "Vi ***.")
            let text = try String(contentsOf: log, encoding: .utf8)
            try expect(!text.contains(secret), text)
            try expect(text.contains("stderr con ***"), text)

            let failing = FakeStreamingRunner { _, _, _ in ([], fail("auth gho_SECRETO123 inválido", status: 1)) }
            let error = try await expectThrows {
                _ = try await claude(failing, log: try logFile(), secrets: [secret]).run(invocation(), as: Answer.self, onAgent: { _ in })
            }
            try expectEqual(error as? PRBarError, .commandFailed(command: "claude", status: 1, stderr: "auth *** inválido"))

            let errorLine = #"{"type":"result","subtype":"error","is_error":true,"result":"falló con gho_SECRETO123"}"#
            let erroring = FakeStreamingRunner { _, _, _ in ([errorLine], ok("")) }
            let claudeError = try await expectThrows {
                _ = try await claude(erroring, log: try logFile(), secrets: [secret]).run(invocation(), as: Answer.self, onAgent: { _ in })
            }
            try expectEqual(claudeError as? ClaudeError, .failed("falló con ***"))
        },
        TestCase("claude runner: PATH antepone las carpetas de las herramientas sin repetir") {
            try expectEqual(
                ClaudeRunner.environment(toolPaths: ["/opt/homebrew/bin/git", "/opt/homebrew/bin/gh", "/Users/me/.local/bin/claude"])["PATH"],
                "/opt/homebrew/bin:/Users/me/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            )
            try expectEqual(ClaudeRunner.environment(toolPaths: [])["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        },
        TestCase("claude stream: cuenta los subagentes con el nombre Agent y con el viejo Task") {
            var parser = ClaudeStreamParser()
            let task = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Task","input":{}}]}}"#
            try expectEqual(parser.consume(agentLine), .agentStarted(total: 1))
            try expectEqual(parser.consume(task), .agentStarted(total: 2))
            try expectEqual(ClaudeReviewer.reviewTools.last, "Agent")
            try expectEqual(RespondAnalyzer.tools.last, "Agent")
            try expectEqual(FixImplementer.tools.last, "Agent")
        },
        TestCase("claude runner: MainActorRelay entrega en orden en el main actor y finish espera") {
            let seen = Box<[Int]>([])
            let onMain = Box(true)
            let relay = MainActorRelay<Int> { value in
                if !Thread.isMainThread { onMain.value = false }
                seen.value.append(value)
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for n in 0..<100 { relay.send(n) } }
            }
            await relay.finish()
            try expectEqual(seen.value, Array(0..<100))
            try expect(onMain.value)
        },
        TestCase("claude runner: --session-id o --resume van después de -p y --model, en minúscula") {
            let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
            var start = invocation()
            start.session = .start(id)
            let args = ClaudeRunner.arguments(for: start, pluginDirs: plugins, model: .haiku)
            try expectEqual(Array(args.prefix(6)), ["-p", "Hacé algo.", "--model", "haiku",
                                                    "--session-id", "6f9619ff-8b86-d011-b42d-00c04fc964ff"])
            var resume = invocation()
            resume.session = .resume(id)
            let resumed = ClaudeRunner.arguments(for: resume, pluginDirs: plugins)
            try expectEqual(Array(resumed.prefix(4)), ["-p", "Hacé algo.", "--resume", "6f9619ff-8b86-d011-b42d-00c04fc964ff"])
            // The rest is the same as without a session.
            try expectEqual(Array(resumed.dropFirst(4)), Array(ClaudeRunner.arguments(for: invocation(), pluginDirs: plugins).dropFirst(2)))
        },
        TestCase("claude runner: el reintento de una sesión la continúa con --resume y un prompt corto") {
            let id = UUID()
            let calls = Box(0)
            let runner = FakeStreamingRunner { _, _, _ in
                calls.value += 1
                return ([calls.value == 1 ? invalidLine : validLine], ok(""))
            }
            var call = invocation(header: "=== chat 1 ===")
            call.session = .start(id)
            let answer = try await claude(runner, log: try logFile()).run(call, as: Answer.self, onAgent: { _ in })
            try expectEqual(answer, Answer(summary: "Listo."))
            try expectEqual(value(of: "--session-id", in: runner.calls[0].arguments), id.uuidString.lowercased())
            try expectEqual(value(of: "--resume", in: runner.calls[1].arguments), id.uuidString.lowercased())
            try expect(!runner.calls[1].arguments.contains("--session-id"))
            try expect(prompt(of: runner.calls[1]).hasPrefix("Your previous answer was invalid"), prompt(of: runner.calls[1]))
            try expect(!prompt(of: runner.calls[1]).contains("Hacé algo."))
        },
        TestCase("claude runner: onEvent recibe 0 al empezar, texto y herramientas") {
            let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Mirando."},{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/wt/r-7-1/a.ts"}}]}}"#
            let runner = FakeStreamingRunner { _, _, _ in ([line, validLine], ok("")) }
            let events = Box<[ClaudeStreamEvent]>([])
            _ = try await claude(runner, log: try logFile()).run(invocation(), as: Answer.self, onEvent: { events.value.append($0) })
            try expectEqual(events.value, [.agentStarted(total: 0), .text("Mirando."), .toolUse(name: "Read", detail: "/tmp/wt/r-7-1/a.ts")])
        },
    ]
}
