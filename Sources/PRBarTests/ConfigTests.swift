import Foundation
import PRBarCore

enum ConfigTests {
    static let cases: [TestCase] = [
        TestCase("config: setBaseBranches reemplaza la lista sin duplicados") {
            var config = AppConfig()
            config.setAccountEnabled("me", true)
            config.addRepo(RepoRef(owner: "o", name: "r"), to: "me")
            config.setBaseBranches(["main", "develop", "main", " "], repoID: "o/r", login: "me")
            try expectEqual(config.accounts[0].repos[0].baseBranches, ["main", "develop"])
            config.setBaseBranches([], repoID: "o/r", login: "me")
            try expectEqual(config.accounts[0].repos[0].baseBranches, [])
        },
        TestCase("config: archivo inexistente → valores por defecto") {
            let dir = try temporaryDirectory()
            let store = await ConfigStore(fileURL: dir.appendingPathComponent("config.json"))
            let config = await store.config
            try expectEqual(config, AppConfig())
            try expectEqual(config.refreshIntervalMinutes, 2)
            try expect(config.notifications.enabled && config.notifications.myPRApprovedOrCIFailed)
            let loadError = await store.loadError
            try expectEqual(loadError, nil)
        },
        TestCase("config: JSON parcial completa los faltantes con defaults") {
            let json = #"{"accounts":[{"login":"me","repos":[{"owner":"o","name":"r"}]}],"notifications":{"enabled":false}}"#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expectEqual(config.accounts[0].enabled, true)
            try expectEqual(config.accounts[0].repos[0].watchedUsers, [])
            try expectEqual(config.accounts[0].repos[0].baseBranches, [])
            try expectEqual(config.accounts[0].repos[0].localPath, nil)
            try expectEqual(config.notifications.enabled, false)
            try expectEqual(config.notifications.newToReview, true)
            try expectEqual(config.refreshIntervalMinutes, 2)
        },
        TestCase("config: update persiste y se vuelve a leer igual") {
            let url = try temporaryDirectory().appendingPathComponent("config.json")
            let store = await ConfigStore(fileURL: url)
            try await store.update { $0.setAccountEnabled("me", true); $0.refreshIntervalMinutes = 5 }
            let reloaded = await ConfigStore(fileURL: url)
            let reloadedConfig = await reloaded.config
            let storedConfig = await store.config
            try expectEqual(reloadedConfig, storedConfig)
            try expectEqual(reloadedConfig.refreshIntervalMinutes, 5)
        },
        TestCase("config: archivo corrupto → defaults, error visible y backup") {
            let url = try temporaryDirectory().appendingPathComponent("config.json")
            try Data("{ no es json".utf8).write(to: url)
            let store = await ConfigStore(fileURL: url)
            let config = await store.config
            let loadError = await store.loadError
            try expectEqual(config, AppConfig())
            try expect(loadError != nil)
            try expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
        },
        TestCase("config: activar y desactivar cuentas") {
            var config = AppConfig()
            config.setAccountEnabled("me", false)
            try expectEqual(config.accounts.count, 0)
            config.setAccountEnabled("me", true)
            config.setAccountEnabled("me", false)
            try expectEqual(config.accounts.map(\.login), ["me"])
            try expectEqual(config.accounts[0].enabled, false)
        },
        TestCase("config: repos, carpeta local y ramas base") {
            var config = AppConfig()
            config.setAccountEnabled("me", true)
            let repo = RepoRef(owner: "o", name: "r")
            config.addRepo(repo, to: "me")
            config.addRepo(repo, to: "me")
            try expectEqual(config.accounts[0].repos.count, 1)
            config.setLocalPath("/tmp/r", repoID: "o/r", login: "me")
            config.toggleBaseBranch("develop", repoID: "o/r", login: "me")
            config.toggleBaseBranch("main", repoID: "o/r", login: "me")
            config.toggleBaseBranch("develop", repoID: "o/r", login: "me")
            try expectEqual(config.accounts[0].repos[0].localPath, "/tmp/r")
            try expectEqual(config.accounts[0].repos[0].baseBranches, ["main"])
            config.removeRepo("o/r", from: "me")
            try expectEqual(config.accounts[0].repos.count, 0)
        },
        TestCase("config: usuarios seguidos por repo, sin duplicados (sin distinguir mayúsculas)") {
            var config = AppConfig()
            config.setAccountEnabled("me", true)
            config.addRepo(RepoRef(owner: "o", name: "a"), to: "me")
            config.addRepo(RepoRef(owner: "o", name: "b"), to: "me")
            config.addWatchedUser("Juan", repoID: "o/a", login: "me")
            config.addWatchedUser("juan", repoID: "o/a", login: "me")
            config.addWatchedUser("ana", repoID: "o/a", login: "me")
            try expectEqual(config.accounts[0].repos[0].watchedUsers, ["Juan", "ana"])
            try expectEqual(config.accounts[0].repos[1].watchedUsers, [])
            config.removeWatchedUser("JUAN", repoID: "o/a", login: "me")
            try expectEqual(config.accounts[0].repos[0].watchedUsers, ["ana"])
        },
        TestCase("config: migra usuarios de la cuenta a cada repo sin lista propia") {
            let json = #"""
            {"accounts":[{"login":"me","watchedUsers":["juan","ana"],"repos":[
              {"owner":"o","name":"a"},
              {"owner":"o","name":"b","watchedUsers":["pepe"]}]}]}
            """#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expectEqual(config.accounts[0].repos[0].watchedUsers, ["juan", "ana"])
            try expectEqual(config.accounts[0].repos[1].watchedUsers, ["pepe"])
            let reencoded = try JSONCoding.decoder.decode(AppConfig.self, from: try JSONCoding.encoder.encode(config))
            try expectEqual(reencoded, config)
        },
        TestCase("config: ConfigStore guarda la config migrada al cargar") {
            let url = try temporaryDirectory().appendingPathComponent("config.json")
            let json = #"{"accounts":[{"login":"me","watchedUsers":["juan"],"repos":[{"owner":"o","name":"a"}]}]}"#
            try Data(json.utf8).write(to: url)
            let store = await ConfigStore(fileURL: url)
            let repoUsers = await store.config.accounts[0].repos[0].watchedUsers
            try expectEqual(repoUsers, ["juan"])
            struct LegacyProbe: Decodable { struct Account: Decodable { let watchedUsers: [String]? }; let accounts: [Account] }
            let saved = try JSONCoding.decoder.decode(LegacyProbe.self, from: Data(contentsOf: url))
            try expectEqual(saved.accounts[0].watchedUsers, nil)
            let reloaded = await ConfigStore(fileURL: url).config
            try expectEqual(reloaded.accounts[0].repos[0].watchedUsers, ["juan"])
        },
        TestCase("config: la config de un repo se busca sin distinguir mayúsculas") {
            var config = AppConfig()
            var repo = RepoConfig(owner: "Acme", name: "Web-App")
            repo.ignorePaths = ["dist/**"]
            config.accounts = [AccountConfig(login: "Me", repos: [repo])]
            try expectEqual(config.repoConfig(account: "me", repo: RepoRef(owner: "acme", name: "web-app"))?.ignorePaths, ["dist/**"])
            try expectEqual(config.repoConfig(account: "other", repo: RepoRef(owner: "acme", name: "web-app")), nil)
            try expectEqual(config.repoConfig(account: "me", repo: RepoRef(owner: "acme", name: "api")), nil)
        },
        TestCase("config: el umbral de disco está apagado por defecto, se guarda y se acota a 1–100 GB") {
            try expectEqual(AppConfig().resources.diskWarningGB, nil)
            var config = AppConfig()
            config.resources.setDiskWarning(gigabytes: 500)
            try expectEqual(config.resources.diskWarningGB, 100)
            config.resources.setDiskWarning(gigabytes: 5)
            let back = try JSONDecoder().decode(AppConfig.self, from: try JSONEncoder().encode(config))
            try expectEqual(back.resources.diskWarningGB, 5)
            let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"refreshIntervalMinutes":5}"#.utf8))
            try expectEqual(old.resources.diskWarningGB, nil)
        },
    ]
}
