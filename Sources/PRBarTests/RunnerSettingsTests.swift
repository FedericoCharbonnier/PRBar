import Foundation
import PRBarCore

enum RunnerSettingsTests {
    static let cases: [TestCase] = [
        TestCase("runners: endpoints válidos") {
            try expectEqual(try SSHEndpoint.parse("devbox"), SSHEndpoint(host: "devbox"))
            try expectEqual(try SSHEndpoint.parse("fede@devbox.local:2222"), SSHEndpoint(user: "fede", host: "devbox.local", port: 2222))
            try expectEqual(try SSHEndpoint.parse("root@[fe80::1]:22"), SSHEndpoint(user: "root", host: "fe80::1", port: 22))
            try expectEqual(try SSHEndpoint.parse("root@[fe80::1]:22").display, "root@[fe80::1]:22")
        },
        TestCase("runners: endpoints hostiles o inválidos se rechazan") {
            for text in ["", "-oProxyCommand=touch x", "a b", "host;rm", "$(x)", "`x`", "h:0", "h:70000", "h:p", "@h", "u@", "u@-h",
                         "a'b", "h\nx", "[::1", "[zz]", "user@host@x", "h:1:2", "-h", "h/x"] {
                let parsed = try? SSHEndpoint.parse(text)
                try expect(parsed == nil, "aceptó \(text.debugDescription)")
            }
        },
        TestCase("runners: nombres y carpetas remotas") {
            try expect(RunnerDestination.isValidName("devbox") && RunnerDestination.isValidName("gpu-1.lab"))
            for bad in ["", "local", "Default", "-x", "a b", "a/b", String(repeating: "x", count: 41)] {
                try expect(!RunnerDestination.isValidName(bad), "aceptó \(bad)")
            }
            for good in ["~/.prbar", "~/work/prbar", "/srv/prbar", "/home/fede/.prbar"] {
                try expect(RunnerDestination.isValidRemoteDir(good), "rechazó \(good)")
            }
            for bad in ["", "~", "~/", "/", "/srv", "relative", "~/../x", "~/a/./b", "/a//b", "~/a b", "~/$(x)", "~/.ssh/x",
                        "~/.config/prbar", "~/Library/PRBar", "~/.aws", "~/.gnupg/x", "/srv/prbar/"] {
                try expect(!RunnerDestination.isValidRemoteDir(bad), "aceptó \(bad)")
            }
            let destination = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(host: "devbox"))
            try expectEqual(try destination.remoteDirExpression(), #""$HOME"/'.prbar'"#)
        },
        TestCase("runners: el destino se resuelve repo → global → This Mac; uno borrado es This Mac (nunca otro host)") {
            var settings = RunnerSettings()
            let devbox = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(host: "devbox"))
            let gpu = RunnerDestination(name: "gpu", endpoint: SSHEndpoint(host: "gpu"))
            settings.destinations = [devbox, gpu]
            var repo = RepoConfig(owner: "acme", name: "api")
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), nil)
            settings.defaultTarget = .runner("devbox")
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), devbox)
            repo.runOn = .runner("gpu")
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), gpu)
            repo.runOn = .local
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), nil)
            repo.runOn = .runner("GPU")
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), gpu)
            // Un repo fijado a un host que ya no existe nunca corre en otro (el default es devbox): corre en esta Mac.
            repo.runOn = .runner("gone")
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), nil)
            repo.runOn = nil
            settings.defaultTarget = .runner("gone")
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), nil)
        },
        TestCase("runners: config va y vuelve; sacar un destino limpia repos y default") {
            var config = AppConfig()
            config.accounts = [AccountConfig(login: "me")]
            config.addRepo(RepoRef(owner: "acme", name: "api"), to: "me")
            try config.addRunner(RunnerDestination(name: "devbox", endpoint: try SSHEndpoint.parse("fede@devbox:2222"), remoteDir: "/srv/prbar"))
            let duplicate = try await expectThrows { try config.addRunner(RunnerDestination(name: "DEVBOX", endpoint: SSHEndpoint(host: "x"))) }
            try expectEqual(duplicate as? RunnerConfigError, .duplicate("DEVBOX"))
            try config.setDefaultRunTarget(.runner("devbox"))
            config.setRunOn(.runner("devbox"), repoID: "acme/api", login: "me")
            let back = try JSONDecoder().decode(AppConfig.self, from: try JSONEncoder().encode(config))
            try expectEqual(back.runners, config.runners)
            try expectEqual(back.repoConfig(account: "me", repo: RepoRef(owner: "acme", name: "api"))?.runOn, .runner("devbox"))
            let json = String(decoding: try JSONEncoder().encode(config.runners.defaultTarget), as: UTF8.self)
            try expectEqual(json, #""devbox""#)
            try config.removeRunner(named: "devbox")
            try expectEqual(config.runners.destinations, [])
            try expectEqual(config.runners.defaultTarget, .local)
            try expectEqual(config.repoConfig(account: "me", repo: RepoRef(owner: "acme", name: "api"))?.runOn, nil)
            // Una config editada a mano con otras mayúsculas: sacar el destino igual limpia el repo y el default.
            try config.addRunner(RunnerDestination(name: "devbox", endpoint: SSHEndpoint(host: "devbox")))
            config.runners.defaultTarget = .runner("DevBox")
            config.setRunOn(.runner("DEVBOX"), repoID: "acme/api", login: "me")
            try config.removeRunner(named: "devbox")
            try expectEqual(config.runners.defaultTarget, .local)
            try expectEqual(config.repoConfig(account: "me", repo: RepoRef(owner: "acme", name: "api"))?.runOn, nil)
            let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"refreshIntervalMinutes":5}"#.utf8))
            try expectEqual(old.runners, RunnerSettings())
        },
        TestCase("runners: una config editada a mano con destinos inválidos los descarta al leerla") {
            func destination(_ name: String, host: String, user: String? = nil, port: Int? = nil, dir: String = "~/.prbar") -> String {
                var endpoint = #""host":"\#(host)""#
                if let user { endpoint += #","user":"\#(user)""# }
                if let port { endpoint += #","port":\#(port)"# }
                return #"{"name":"\#(name)","endpoint":{\#(endpoint)},"remoteDir":"\#(dir)","fallbackToLocal":true}"#
            }
            let entries = [
                destination("ok", host: "devbox", user: "fede", port: 2222),
                destination("opt", host: "-oProxyCommand=touch PWNED"),
                destination("user", host: "devbox", user: "-oX"),
                destination("port", host: "devbox", port: 0),
                destination("bigport", host: "devbox", port: 70_000),
                destination("space", host: "dev box"),
                destination("bad name", host: "devbox"),
                destination("local", host: "devbox"),
                destination("dir", host: "devbox", dir: "~/.ssh/x"),
                destination("OK", host: "other"),
                destination("v6", host: "fe80::1"),
                #"{"name":"broken"}"#,
            ]
            let json = #"{"destinations":["# + entries.joined(separator: ",") + #"],"defaultTarget":"ok"}"#
            let settings = try JSONDecoder().decode(RunnerSettings.self, from: Data(json.utf8))
            try expectEqual(settings.destinations.map(\.name), ["ok", "v6"])
            try expectEqual(settings.destinations[0].endpoint, SSHEndpoint(user: "fede", host: "devbox", port: 2222))
            try expectEqual(settings.defaultTarget, .runner("ok"))
        },
        TestCase("runners: hosts de ~/.ssh/config sin comodines, con Include de un nivel") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try Data("Host devbox gpu-1\n  HostName 10.0.0.2\nHost *.internal *\nInclude extra/*.conf\nhost  Lab\n".utf8)
                .write(to: dir.appendingPathComponent("config"))
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("extra"), withIntermediateDirectories: true)
            try Data("Host build-box\nInclude ../config\n".utf8).write(to: dir.appendingPathComponent("extra/a.conf"))
            try expectEqual(SSHConfigHosts.hosts(configAt: dir.appendingPathComponent("config")), ["build-box", "devbox", "gpu-1", "Lab"])
            // Negaciones, `?`, nombres que ssh leería como opción o con caracteres raros, y `Host=x`.
            try Data("Host !bad ok-1 we?rd -opt a$b\nHost=eq-host\n\tHost tabbed\n# Host commented\n".utf8)
                .write(to: dir.appendingPathComponent("config"))
            try expectEqual(SSHConfigHosts.hosts(configAt: dir.appendingPathComponent("config")), ["eq-host", "ok-1", "tabbed"])
            try expectEqual(SSHConfigHosts.hosts(configAt: dir.appendingPathComponent("missing")), [])
        },
        TestCase("runners: herramientas de esta Mac — git siempre, claude solo si el trabajo corre acá") {
            try expectEqual(LocalTools.missing(git: nil, claude: "/c", runsOnHost: true), "git")
            try expectEqual(LocalTools.missing(git: "/g", claude: nil, runsOnHost: true), nil)
            try expectEqual(LocalTools.missing(git: "/g", claude: nil, runsOnHost: false), "claude")
            try expectEqual(LocalTools.missing(git: nil, claude: nil, runsOnHost: false), "git")
            try expectEqual(LocalTools.missing(git: "/g", claude: "/c", runsOnHost: false), nil)
        },
        TestCase("runners: estado de esta Mac en Run On") {
            try expectEqual(LocalTools.statusSummary(git: "/g", claude: "/c", gitVersion: "git version 2.47.1", claudeVersion: "2.1.318 (Claude Code)"),
                            "✓ claude 2.1.318 · git 2.47.1")
            try expectEqual(LocalTools.statusSummary(git: "/g", claude: "/c", gitVersion: nil, claudeVersion: nil), "✓ claude · git")
            try expectEqual(LocalTools.statusSummary(git: "/g", claude: nil, gitVersion: "git version 2.47.1", claudeVersion: nil),
                            "⚠ claude isn’t installed")
            try expectEqual(LocalTools.statusSummary(git: nil, claude: nil, gitVersion: nil, claudeVersion: nil), "⚠ git isn’t installed")
        },
    ]
}
