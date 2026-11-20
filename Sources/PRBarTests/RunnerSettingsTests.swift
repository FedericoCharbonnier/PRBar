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
        TestCase("runners: el destino se resuelve repo → global → This Mac; uno borrado cuenta como Default") {
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
            repo.runOn = .runner("gone")
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), devbox)
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
            let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"refreshIntervalMinutes":5}"#.utf8))
            try expectEqual(old.runners, RunnerSettings())
        },
    ]
}
