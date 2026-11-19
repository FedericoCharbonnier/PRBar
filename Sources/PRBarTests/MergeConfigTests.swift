import Foundation
import PRBarCore

enum MergeConfigTests {
    static let cases: [TestCase] = [
        TestCase("merge config: por defecto confirma y ningún repo fija método") {
            try expect(AppConfig().merge.confirm)
            try expectEqual(RepoConfig(owner: "o", name: "r").mergeMethod, nil)
        },
        TestCase("merge config: un config viejo sin merge ni mergeMethod") {
            let json = #"{"accounts":[{"login":"me","repos":[{"owner":"o","name":"r"}]}]}"#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expect(config.merge.confirm)
            try expectEqual(config.accounts[0].repos[0].mergeMethod, nil)
        },
        TestCase("merge config: lee merge.confirm y mergeMethod") {
            let json = #"{"merge":{"confirm":false},"accounts":[{"login":"me","repos":[{"owner":"o","name":"r","mergeMethod":"rebase"}]}]}"#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expect(!config.merge.confirm)
            try expectEqual(config.accounts[0].repos[0].mergeMethod, .rebase)
        },
        TestCase("merge config: valores inválidos caen en el default sin perder el resto") {
            let json = #"""
            {"merge":"yes","refreshIntervalMinutes":5,
             "accounts":[{"login":"me","repos":[{"owner":"o","name":"r","mergeMethod":"octopus","testCommand":"make test"}]}]}
            """#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expect(config.merge.confirm)
            try expectEqual(config.refreshIntervalMinutes, 5)
            try expectEqual(config.accounts[0].repos[0].mergeMethod, nil)
            try expectEqual(config.accounts[0].repos[0].testCommand, "make test")
        },
        TestCase("merge config: setMergeMethod y round-trip") {
            var config = AppConfig()
            config.accounts = [AccountConfig(login: "me", repos: [RepoConfig(owner: "o", name: "r")])]
            config.setMergeMethod(.squash, repoID: "o/r", login: "me")
            config.merge.confirm = false
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
