import Foundation
import PRBarCore

private let request = TerminalRequest(command: "'/usr/local/bin/claude' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50",
                                      directory: "/tmp/PR Bar/it's", title: "o/r#7 · Review · stage 1")

enum TerminalLauncherTests {
    static let cases: [TestCase] = [
        TestCase("terminal: Terminal, iTerm, Warp y Ghostty abren un .command con open -a") {
            let script = try TerminalLauncher.script(request)
            try expectEqual(script, "#!/bin/zsh\ncd '/tmp/PR Bar/it'\\''s' && '/usr/local/bin/claude' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50\nexec /bin/zsh -l\n")
            for (choice, app) in [(TerminalChoice.terminal, "Terminal"), (.iterm, "iTerm"), (.warp, "Warp"), (.ghostty, "Ghostty")] {
                try expectEqual(try TerminalLauncher.plan(request, choice: choice, customCommand: nil), .commandFile(app: app, script: script))
            }
            var noFolder = request
            noFolder.directory = nil
            try expectEqual(try TerminalLauncher.script(noFolder),
                            "#!/bin/zsh\n'/usr/local/bin/claude' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50\nexec /bin/zsh -l\n")
        },
        TestCase("terminal: el .command no interpreta $, backticks ni saltos de línea de la carpeta") {
            var odd = request
            odd.directory = "/tmp/a $HOME `id` $(id)\nb'c"
            try expectEqual(try TerminalLauncher.script(odd),
                            "#!/bin/zsh\ncd '/tmp/a $HOME `id` $(id)\nb'\\''c' && '/usr/local/bin/claude' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50\nexec /bin/zsh -l\n")
        },
        TestCase("terminal: Orca usa su CLI con la carpeta como worktree; sin carpeta no se puede") {
            try expectEqual(try TerminalLauncher.plan(request, choice: .orca, customCommand: nil), .orca(arguments: [
                "terminal", "create", "--worktree=path:/tmp/PR Bar/it's", "--title=o/r#7 · Review · stage 1",
                "--command=\(request.command)", "--focus", "--json",
            ]))
            var noFolder = request
            noFolder.directory = nil
            let error = try await expectThrows { _ = try TerminalLauncher.plan(noFolder, choice: .orca, customCommand: nil) }
            try expectEqual(error as? TerminalLaunchError, .notInOrca)
        },
        TestCase("terminal: lo que contesta Orca") {
            try expectEqual(TerminalLauncher.orcaOutcome(stdout: #"{"id":"x","ok":true,"result":{}}"#, status: 0), nil)
            let notFound = #"{"id":"x","ok":false,"error":{"code":"selector_not_found","message":"selector_not_found"}}"#
            try expectEqual(TerminalLauncher.orcaOutcome(stdout: notFound, status: 1), .notInOrca)
            try expectEqual(TerminalLauncher.orcaOutcome(stdout: #"{"ok":false,"error":{"code":"boom","message":"No runtime"}}"#, status: 1),
                            .failed("No runtime"))
            try expectEqual(TerminalLauncher.orcaOutcome(stdout: "", status: 2), .failed("orca exited with status 2"))
            try expectEqual(TerminalLauncher.orcaOutcome(stdout: "", stderr: "orca: no runtime\n", status: 2), .failed("orca: no runtime"))
            try expectEqual(TerminalLauncher.orcaOutcome(stdout: "not json", stderr: "boom", status: 1), .failed("boom"))
            try expectEqual(TerminalLauncher.orcaOutcome(stdout: "not json", stderr: "", status: 1), .failed("not json"))
            try expectEqual(TerminalLauncher.orcaOutcome(stdout: "created", stderr: "", status: 0), nil)
            try expectEqual(TerminalLaunchError.notInOrca.errorDescription,
                            "This folder isn’t in Orca. Add the repo in Orca or choose another terminal.")
        },
        TestCase("terminal: Custom reemplaza {dir} y {command} ya entre comillas") {
            let template = "open -na Ghostty --args --working-directory={dir} -e /bin/zsh -lc {command}"
            try expectEqual(try TerminalLauncher.plan(request, choice: .custom, customCommand: template), .shell(command:
                #"open -na Ghostty --args --working-directory='/tmp/PR Bar/it'\''s' -e /bin/zsh -lc ''\''/usr/local/bin/claude'\'' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50'"#))
            let none = try await expectThrows { _ = try TerminalLauncher.plan(request, choice: .custom, customCommand: "  ") }
            try expectEqual(none as? TerminalLaunchError, .noCustomCommand)
            let noPlaceholder = try await expectThrows { _ = try TerminalLauncher.plan(request, choice: .custom, customCommand: "open -a Terminal {dir}") }
            try expectEqual(noPlaceholder as? TerminalLaunchError, .customCommandWithoutPlaceholder)
        },
        TestCase("terminal: Custom con {command}, $, backticks y saltos de línea en los valores llega tal cual al shell") {
            // Una carpeta llamada `{command}` no se vuelve a reemplazar (dejaría el comando fuera de las comillas).
            let odd = TerminalRequest(command: "echo `id` $(id) $HOME 'x'\ny {dir}", directory: "/tmp/{command} $HOME `id`\nit's", title: "t")
            let shell = try TerminalLauncher.plan(odd, choice: .custom, customCommand: "printf '%s|%s' {dir} {command}")
            guard case .shell(let command) = shell else { throw TestFailure(description: "expected .shell, got \(shell)") }
            // Solo se imprime: nada se ejecuta ni se abre.
            let result = try await SystemProcessRunner().run("/bin/sh", ["-c", command], environment: nil, currentDirectory: nil, timeout: 10)
            try expectEqual(result.stdout, "/tmp/{command} $HOME `id`\nit's|echo `id` $(id) $HOME 'x'\ny {dir}")
        },
        TestCase("terminal: Custom no acepta comillas, \\, $ ni backticks pegados a {dir} o {command}") {
            for template in [#"sh -c "{command}""#, "sh -c '{command}'", #"x --dir="{dir}" {command}"#, "x '--dir={dir}' {command}",
                             "x {dir}' {command}", #"sh -c "cd {dir}; {command}""#, "sh -c 'run {command} now'",
                             #"x \{command}"#, "x ${command}", "x `{command}`", "x {command}\"", "x a{dir}'b {command}"] {
                var error: Error?
                do { try TerminalLauncher.validateCustomCommand(template) } catch let thrown { error = thrown }
                try expect(error as? TerminalLaunchError == .quotedPlaceholder, "\(template): \(String(describing: error))")
                let viaPlan = try await expectThrows { _ = try TerminalLauncher.plan(request, choice: .custom, customCommand: template) }
                try expectEqual(viaPlan as? TerminalLaunchError, .quotedPlaceholder)
            }
            try expectEqual(TerminalLaunchError.quotedPlaceholder.errorDescription,
                            "Don’t put quotes around {dir} or {command}: PRBar quotes them.")
            for template in ["open -na Ghostty --args --working-directory={dir} -e /bin/zsh -lc {command}",
                             "kitty --directory {dir} /bin/zsh -lc {command}", "x 'quoted text' {command} \"other\" {dir}",
                             "wezterm start --cwd={dir} -- /bin/zsh -lc {command}"] {
                try TerminalLauncher.validateCustomCommand(template)
            }
            let empty = try await expectThrows { try TerminalLauncher.validateCustomCommand(" ") }
            try expectEqual(empty as? TerminalLaunchError, .noCustomCommand)
            let missing = try await expectThrows { try TerminalLauncher.validateCustomCommand("open {dir}") }
            try expectEqual(missing as? TerminalLaunchError, .customCommandWithoutPlaceholder)
        },
        TestCase("terminal: Custom se lanza aparte, no espera a un comando que sigue corriendo y avisa si falla enseguida") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let pidFile = dir.appendingPathComponent("pid")
            let opener = TerminalOpener(runner: SystemProcessRunner(), directory: dir)
            let start = Date()
            // Un terminal que se queda en primer plano (`kitty`, `alacritty -e`): acá, `sleep 60`. `{command}` va en un comentario.
            try await opener.open(request, choice: .custom, customCommand: "echo $$ > \(pidFile.path); exec sleep 60 # {command}")
            try expect(Date().timeIntervalSince(start) < 5, "took \(Date().timeIntervalSince(start)) s")
            var pid: Int32?
            for _ in 0..<50 where pid == nil {
                pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if pid == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            let child = try expectSome(pid)
            try expect(kill(child, 0) == 0, "the custom command should still be running")
            try expect(getpgid(child) != getpgid(getpid()) && getpgid(child) == child, "it should lead its own process group")
            kill(child, SIGKILL)
            let failed = try await expectThrows { try await opener.open(request, choice: .custom, customCommand: "exit 3 # {command}") }
            try expectEqual(failed as? TerminalLaunchError, .failed("the custom command exited with status 3"))
        },
        TestCase("terminal: el opener escribe el .command 755, lo abre con open -a y borra los de más de un día") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let old = dir.appendingPathComponent("prbar-session-old.command")
            let fresh = dir.appendingPathComponent("prbar-session-fresh.command")
            try Data("x".utf8).write(to: old)
            try Data("x".utf8).write(to: fresh)
            let foreign = dir.appendingPathComponent("someone-else.command")
            try Data("x".utf8).write(to: foreign)
            try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-2 * 86_400)], ofItemAtPath: foreign.path)
            try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
            try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-3600)], ofItemAtPath: fresh.path)
            let runner = FakeProcessRunner { _, _ in ok("") }
            let opener = TerminalOpener(runner: runner, directory: dir, now: { t0 }, isExecutable: { _ in false })
            try await opener.open(request, choice: .iterm, customCommand: nil)
            try expectEqual(runner.calls.count, 1)
            try expectEqual(runner.calls[0].executable, "/usr/bin/open")
            try expectEqual(Array(runner.calls[0].arguments.prefix(2)), ["-a", "iTerm"])
            let file = try expectSome(runner.calls[0].arguments.last)
            try expectEqual(try String(contentsOfFile: file, encoding: .utf8), try TerminalLauncher.script(request))
            let mode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
            try expectEqual(mode, 0o755)
            try expect(!FileManager.default.fileExists(atPath: old.path))
            try expect(FileManager.default.fileExists(atPath: fresh.path))
            try expect(FileManager.default.fileExists(atPath: foreign.path), "only PRBar’s prbar-session-*.command files are pruned")
        },
        TestCase("terminal: Orca sin su binario no está instalado; con ok:false avisa") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let missing = TerminalOpener(runner: FakeProcessRunner { _, _ in ok("") }, directory: dir, now: { t0 }, isExecutable: { _ in false })
            let error = try await expectThrows { try await missing.open(request, choice: .orca, customCommand: nil) }
            try expectEqual(error as? TerminalLaunchError, .notInstalled("Orca"))
            let orca = FakeProcessRunner { _, _ in ProcessResult(status: 1, stdout: #"{"ok":false,"error":{"code":"selector_not_found"}}"#, stderr: "") }
            let opener = TerminalOpener(runner: orca, directory: dir, now: { t0 }, isExecutable: { $0 == TerminalOpener.orcaCandidates[0] })
            let notInOrca = try await expectThrows { try await opener.open(request, choice: .orca, customCommand: nil) }
            try expectEqual(notInOrca as? TerminalLaunchError, .notInOrca)
            try expectEqual(orca.calls.first?.executable, TerminalOpener.orcaCandidates[0])
        },
    ]
}
