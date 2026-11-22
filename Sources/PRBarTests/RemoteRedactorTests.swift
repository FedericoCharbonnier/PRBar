import Foundation
import PRBarCore
import PRBarRemoteKit
import PRBarRemoteMac

/// Revisión M1/L1/L5: nada de rutas locales, escapes, bidi ni secretos hacia el teléfono, por clave y por valor.
enum RemoteRedactorTests {
    static let home = "/Users/alice"
    static let clone = "/Users/alice/code/secret-client-repo"
    static let temp = "/var/folders/ab/cd1234/T"

    static func redactor() -> RemoteRedactor {
        RemoteRedactor(home: home, temporary: [temp], folders: [clone, clone + "-worktrees", "/Volumes/Work/wt"],
                       hosts: ["devbox.internal"])
    }

    /// Lo que no puede aparecer en nada de lo que va al teléfono.
    static func leaks(_ text: String) -> [String] {
        ["/Users/", "/var/folders", "/private/", "code/secret-client-repo", "/Volumes/Work", "devbox.internal", "\u{1B}",
         "\u{202E}", "\u{2066}", "\u{200B}", "\u{07}", "ghp_", "AKIA"].filter { text.contains($0) }
    }

    static let poison = "Couldn’t open \(clone)/src/a.ts (\(home)/Library/Logs/PRBar/x.log, /private\(temp)/PRBar/worktrees/api-3, "
        + "/Users/someone-else/y, /home/ci/work, devbox.internal:22) \u{1B}[31mFAIL\u{1B}[0m \u{202E}gnp.exe\u{202C} a\u{200B}b "
        + "ghp_abcdefghijklmnopqrstuvwxyz0123 AKIAABCDEFGHIJKLMNOP\u{07}"

    static func poisoned(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string: .string(poison)
        case .array(let items): .array(items.map(poisoned))
        case .object(let fields): .object(fields.mapValues(poisoned))
        default: value
        }
    }

    static func text(_ value: JSONValue) throws -> String {
        String(decoding: try CommandProtocol.encoder.encode(value), as: UTF8.self)
    }

    static let cases: [TestCase] = [
        TestCase("remote redactor: rutas por valor (home, clones, temporales, otros usuarios), escapes, bidi y secretos") {
            let r = redactor()
            let out = r.text(poison)
            try expect(leaks(out).isEmpty, "\(leaks(out)) en \(out)")
            try expect(out.contains("secret-client-repo/src/a.ts"), out)
            try expect(out.contains("~/Library/Logs/PRBar/x.log"), out)
            try expect(out.contains("$TMPDIR/PRBar/worktrees/api-3"), out)
            try expect(out.contains("~/y") && out.contains("~/work"), out)
            try expect(out.contains("remote host:22"), out)
            try expect(out.contains("FAIL") && out.contains("gnp.exe") && out.contains("ab"), out)
            // `~/…` escrito así también, y sin pisar nombres parecidos.
            try expectEqual(r.text("see ~/code/secret-client-repo/README"), "see secret-client-repo/README")
            try expectEqual(r.text("/Users/alicex/z"), "~/z")
            try expectEqual(r.text("src/Users/a.ts"), "src/Users/a.ts")
            // Emoji con ZWJ y selector de variación siguen enteros.
            try expectEqual(r.text("👩‍💻 ❤️ ok"), "👩‍💻 ❤️ ok")
        },
        TestCase("remote redactor: un diff queda igual salvo controles y bidi, visibles como U+FFFD") {
            let r = redactor()
            let diff = "+let a = \"/Users/alice\"\n+x\u{202E}y\tz\n"
            let out = r.scrub(.object(["diff": .string(diff), "pr": .string("a/b#1")]))
            try expectEqual(out, .object(["diff": .string("+let a = \"/Users/alice\"\n+x\u{FFFD}y\tz\n"), "pr": .string("a/b#1")]))
        },
        TestCase("remote redactor: por clave, solo rutas absolutas; host de un trabajo remoto como remote; tools vacío") {
            let r = redactor()
            let out = r.scrub(.object([
                "path": .string("src/reports/export.ts"),
                "clone": .string(clone),
                "localPath": .string(clone),
                "dir": .string("/Volumes/Work/wt/api-1"),
                "worktreeDir": .string("~/wt"),
                "host": .string("fede@devbox.internal"),
                "tools": .array([.string("x")]),
            ]))
            try expectEqual(out, .object([
                "path": .string("src/reports/export.ts"), "clone": .string("secret-client-repo"),
                "localPath": .string("secret-client-repo"), "dir": .string("api-1"), "worktreeDir": .string("wt"),
                "host": .string("remote"), "tools": .array([]),
            ]))
        },
        TestCase("remote redactor: cada clave de RemoteActivity, RemoteHome y RemotePRDetail, envenenada, sale limpia") {
            let r = redactor()
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            let disk = DiskItem(path: clone + "-worktrees/api-1", bytes: 1, kind: .worktrees, state: .active, repo: "acme/api",
                                clone: clone, title: "api #1")
            let process = ProcessUsage(pid: 1, name: "claude", activity: ProcessActivity(kind: .respond, prID: "acme/api#1",
                                       title: "Fix", host: "devbox.internal"), cpuPercent: 1, memoryBytes: 1,
                                       startedAt: t0, isApp: false)
            let activity = RemoteActivity(
                resources: ResourcesInfo(usage: ResourceUsage(cpuPercent: 1, memoryBytes: 1, processes: [process], sampledAt: t0),
                                         disk: DiskUsage(items: [disk], scannedAt: t0)),
                usage: nil, history: [])
            var respond = RespondInfo(pr: "acme/api#1", phase: "readyToPush", runningTests: false, worktree: clone + "-worktrees/api-1",
                                      items: [], fixes: 1, replies: 0, commits: [], sensitiveChanges: [],
                                      tests: TestInfo(command: "npm test", passed: false, outputTail: poison), pushed: false,
                                      pendingReplies: 0, testCommand: "cd \(clone) && npm test", errorMessage: poison,
                                      logPath: home + "/Library/Logs/PRBar/r.log", pushBlockedByTests: false)
            respond.testSummary = poison
            let detail = RemotePRDetail(pr: nil, review: nil, respond: respond, chat: ChatInfo(
                pr: "acme/api#1", kind: "respond", readOnly: false, running: false, lockReason: poison, messages: []))
            for value in [try JSONValue(encoding: activity), try JSONValue(encoding: detail),
                          try JSONValue(encoding: RemoteHome(status: StatusInfo(appVersion: poison), prs: [], ci: []))] {
                // Tal cual (claves de verdad) y con cada texto envenenado (cualquier clave, también las futuras).
                for candidate in [value, poisoned(value)] {
                    let out = try text(r.scrub(candidate))
                    try expect(leaks(out).isEmpty, "\(leaks(out)) en \(out.prefix(300))")
                }
            }
            // Los tipos se siguen decodificando.
            let back: RemoteActivity = try r.scrub(try JSONValue(encoding: activity)).decode()
            try expectEqual(back.resources.disk.items.first?.clone, "secret-client-repo")
            try expectEqual(back.resources.usage.processes.first?.activity?.host, "remote")
        },
        TestCase("remote redactor: AppConfig da los clones, worktrees y runners") {
            var config = AppConfig()
            config.accounts = [AccountConfig(login: "fede", repos: [RepoConfig(owner: "acme", name: "api", localPath: clone,
                                                                              worktreeDir: "/Volumes/Work/wt")])]
            try expectEqual(config.remoteRedactionFolders, [clone, clone + "-worktrees", "/Volumes/Work/wt"])
        },
        TestCase("remote bridge: errores y eventos del comando también salen redactados (M1)") { @MainActor in
            let h = try await ServiceHarness.make()
            h.service.redactionInputs = { ([clone, clone + "-worktrees"], []) }
            let client = try await h.pair()
            h.actions.waitEvents = [.progress(message: "Working in \(clone)/src"), .text(delta: "see \u{1B}[1m\(home)/x\u{202E}")]
            var seen: [CommandEvent] = []
            for try await response in try await client.send(.chatSend(pr: "acme/api#4", message: "hi")) {
                if let event = response.event { seen.append(event) }
            }
            try expectEqual(seen, [.progress(message: "Working in secret-client-repo/src"), .text(delta: "see ~/x")])
            h.actions.failure = CommandFailure(.failed, "git failed in \(clone)-worktrees/api-4: \u{202E}bad")
            let failed = try await client.run(.respondShow(pr: "acme/api#4"))
            try expectEqual(failed.error, CommandFailure(.failed, "git failed in secret-client-repo-worktrees/api-4: bad"))
        },
    ]
}
