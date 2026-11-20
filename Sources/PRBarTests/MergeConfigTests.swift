import Foundation
import PRBarCore

enum MergeConfigTests {
    static let cases: [TestCase] = [
        TestCase("merge config: ningún repo fija método por defecto") {
            try expectEqual(RepoConfig(owner: "o", name: "r").mergeMethod, nil)
        },
        TestCase("merge config: un config viejo sin merge ni mergeMethod") {
            let json = #"{"accounts":[{"login":"me","repos":[{"owner":"o","name":"r"}]}]}"#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expectEqual(config.accounts[0].repos[0].mergeMethod, nil)
        },
        TestCase("merge config: un config con merge.confirm (quitado, spec G.1) carga sin error y no lo vuelve a escribir") {
            let json = #"{"merge":{"confirm":false},"refreshIntervalMinutes":5,"accounts":[{"login":"me","repos":[{"owner":"o","name":"r","mergeMethod":"rebase"}]}]}"#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expectEqual(config.refreshIntervalMinutes, 5)
            try expectEqual(config.accounts[0].repos[0].mergeMethod, .rebase)
            let written = String(decoding: try JSONCoding.encoder.encode(config), as: UTF8.self)
            try expect(!written.contains("\"merge\""), written)
        },
        TestCase("merge config: valores inválidos caen en el default sin perder el resto") {
            let json = #"""
            {"merge":"yes","refreshIntervalMinutes":5,
             "accounts":[{"login":"me","repos":[{"owner":"o","name":"r","mergeMethod":"octopus","testCommand":"make test"}]}]}
            """#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expectEqual(config.refreshIntervalMinutes, 5)
            try expectEqual(config.accounts[0].repos[0].mergeMethod, nil)
            try expectEqual(config.accounts[0].repos[0].testCommand, "make test")
        },
        TestCase("merge config: setMergeMethod y round-trip") {
            var config = AppConfig()
            config.accounts = [AccountConfig(login: "me", repos: [RepoConfig(owner: "o", name: "r")])]
            config.setMergeMethod(.squash, repoID: "o/r", login: "me")
            try expectEqual(config.accounts[0].repos[0].mergeMethod, .squash)
            let decoded = try JSONCoding.decoder.decode(AppConfig.self, from: JSONCoding.encoder.encode(config))
            try expectEqual(decoded, config)
            config.setMergeMethod(nil, repoID: "o/r", login: "me")
            try expectEqual(config.accounts[0].repos[0].mergeMethod, nil)
            config.setMergeMethod(.merge, repoID: "o/otro", login: "me")
            try expectEqual(config.accounts[0].repos.map(\.mergeMethod), [nil])
        },
    ]
}
