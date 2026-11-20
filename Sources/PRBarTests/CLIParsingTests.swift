import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

/// Parsea `arguments` como en la terminal y devuelve el `AppCommand` que mandaría (confirmado).
func parsed(_ arguments: [String], confirmed: Bool = true) throws -> AppCommand {
    let command = try PRBarCommand.parseAsRoot(arguments)
    guard let remote = command as? any RemoteCommand else {
        throw TestFailure(description: "\(arguments) no es un comando remoto")
    }
    return try remote.appCommand(confirmed: confirmed)
}

/// `true` si parsear `arguments` falla (uso inválido → exit 2).
func rejects(_ arguments: [String]) -> Bool {
    (try? PRBarCommand.parseAsRoot(arguments)) == nil
}

enum CLIParsingTests {
    static var cases: [TestCase] {
        [
            TestCase("cli parse: status") {
                try expectEqual(try parsed(["status"]), .status)
                try expectEqual(try parsed(["status", "--json"]), .status)
            },
            TestCase("cli parse: prs, refresh, open e historial") {
                try expectEqual(try parsed(["prs", "--list", "to-review", "--account", "me"]), .listPRs(list: .toReview, account: "me"))
                try expectEqual(try parsed(["prs", "--list", "ready-to-merge"]), .listPRs(list: .readyToMerge, account: nil))
                try expectEqual(try parsed(["prs"]), .listPRs(list: nil, account: nil))
                try expectEqual(try parsed(["refresh"]), .refresh)
                try expectEqual(try parsed(["open", "api#3"]), .open(pr: "api#3", target: .browser))
                try expectEqual(try parsed(["open", "api#3", "--review"]), .open(pr: "api#3", target: .review))
                try expectEqual(try parsed(["open", "api#3", "--worktree"]), .open(pr: "api#3", target: .worktree))
                try expectEqual(try parsed(["open", "api#3", "--copy"]), .resolvePR(pr: "api#3"))
                try expect(rejects(["open", "api#3", "--review", "--respond"]))
                try expect(rejects(["open", "api#3", "--review", "--copy"]))
                try expectEqual(try parsed(["history", "--repo", "acme/api", "--kind", "review", "--limit", "5", "--search", "login"]),
                                .history(repo: "acme/api", kind: .review, limit: 5, search: "login"))
                try expectEqual(try parsed(["history"]), .history(repo: nil, kind: nil, limit: nil, search: nil))
                try expectEqual(try parsed(["history", "show", "1a2b3c4d"]), .historyShow(id: "1a2b3c4d"))
                try expectEqual(try parsed(["history", "reopen", "1a2b3c4d"]), .historyReopen(id: "1a2b3c4d"))
            },
            TestCase("cli parse: app") {
                try expectEqual(try parsed(["app", "quit"]), .quit)
                try expectEqual(try parsed(["app", "settings", "slack"]), .openSettings(tab: .slack))
                try expectEqual(try parsed(["app", "settings", "instructions"]), .openSettings(tab: .instructions))
                try expectEqual(try parsed(["app", "settings"]), .openSettings(tab: nil))
                try expectEqual(try parsed(["app", "history", "1a2b"]), .openHistory(id: "1a2b"))
                try expect(rejects(["app", "settings", "nope"]))
                try expect(rejects(["app", "logs", "--slack", "--update"]))
                for local in [["app", "start"], ["app", "logs", "--slack"], ["app", "logs", "--update"], ["doctor"], ["version"],
                              ["completion", "zsh"]] {
                    let command = try PRBarCommand.parseAsRoot(local)
                    try expect(command is any LocalCommand, "\(local)")
                }
            },
        ]
    }
}
