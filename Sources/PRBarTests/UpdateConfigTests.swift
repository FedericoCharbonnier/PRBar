import Foundation
import PRBarCore

enum UpdateConfigTests {
    static let cases: [TestCase] = [
        TestCase("updates config: defaults") {
            let settings = AppConfig().updates
            try expectEqual(settings.repo, "FedericoCharbonnier/PRBar")
            try expectEqual(settings.checkIntervalHours, 24)
            try expect(settings.checksAutomatically)
            try expectEqual(settings.lastCheckAt, nil)
            try expectEqual(settings.notifiedVersion, nil)
            try expectEqual(settings.skippedVersion, nil)
        },
        TestCase("updates config: JSON sin 'updates' usa los defaults") {
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(#"{"refreshIntervalMinutes": 5}"#.utf8))
            try expectEqual(config.updates, UpdateSettings())
            try expectEqual(config.refreshIntervalMinutes, 5)
        },
        TestCase("updates config: parcial, tipos equivocados y negativos caen a los defaults") {
            let json = #"{"updates": {"repo": 7, "checkIntervalHours": -3, "skippedVersion": "1.3.0", "lastCheckAt": "ayer"}}"#
            let settings = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8)).updates
            try expectEqual(settings.repo, UpdateSettings.defaultRepo)
            try expectEqual(settings.checkIntervalHours, 0)
            try expectEqual(settings.skippedVersion, "1.3.0")
            try expectEqual(settings.lastCheckAt, nil)
        },
        TestCase("updates config: 'updates' que no es objeto no rompe el resto de la config") {
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(#"{"updates": "x", "launchAtLogin": true}"#.utf8))
            try expectEqual(config.updates, UpdateSettings())
            try expectEqual(config.launchAtLogin, true)
        },
        TestCase("updates config: round-trip") {
            var config = AppConfig()
            config.updates.repo = "acme/PRBar"
            config.updates.checkIntervalHours = 6
            config.updates.lastCheckAt = Date(timeIntervalSince1970: 1_800_000_000)
            config.updates.notifiedVersion = "1.3.0"
            config.updates.skippedVersion = "1.2.0"
            let data = try JSONCoding.encoder.encode(config)
            try expectEqual(try JSONCoding.decoder.decode(AppConfig.self, from: data), config)
        },
        TestCase("updates config: repo inválido → el default; válido → tal cual") {
            var settings = UpdateSettings()
            for bad in ["", "PRBar", "a/b/c", "../x", "acme/-x", "acme/.git", "ac me/x", "acme/"] {
                settings.repo = bad
                try expectEqual(settings.effectiveRepo, UpdateSettings.defaultRepo)
            }
            settings.repo = " acme-co/PRBar.fork_2 "
            try expectEqual(settings.effectiveRepo, "acme-co/PRBar.fork_2")
        },
        TestCase("updates config: switch de chequeo automático") {
            var settings = UpdateSettings()
            settings.checkIntervalHours = 6
            settings.setAutomaticChecks(true)
            try expectEqual(settings.checkIntervalHours, 6)
            settings.setAutomaticChecks(false)
            try expectEqual(settings.checkIntervalHours, 0)
            try expect(!settings.checksAutomatically)
            settings.setAutomaticChecks(true)
            try expectEqual(settings.checkIntervalHours, 24)
        },
    ]
}
