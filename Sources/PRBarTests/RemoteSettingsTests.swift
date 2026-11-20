import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteKit
import PRBarRemoteMac

enum RemoteSettingsTests {
    static let cases: [TestCase] = [
        TestCase("remote settings: una config sin `remote` usa los valores por defecto") {
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"accounts": []}"#.utf8))
            try expectEqual(config.remote, RemoteSettings.default)
            try expect(!config.remote.enabled && config.remote.relayHost == nil && config.remote.accountId == nil)
            try expect(!config.remote.keepAwakeWhileCharging && config.remote.mailboxEnabled)
            try expectEqual(config.remote.appInstallURL, nil)
        },
        TestCase("remote settings: ida y vuelta, y valores rotos no rompen la config") {
            var config = AppConfig()
            config.remote = RemoteSettings(enabled: true, relayHost: "relay.example.com:8443", accountId: "abc",
                                           keepAwakeWhileCharging: true, mailboxEnabled: false,
                                           appInstallURL: URL(string: "https://testflight.apple.com/join/AbCd1234"))
            let data = try JSONEncoder().encode(config)
            let back = try JSONDecoder().decode(AppConfig.self, from: data)
            try expectEqual(back.remote, config.remote)
            let broken = #"{"remote": {"enabled": "yes", "relayHost": "evil host/x", "appInstallURL": "http://example.com"}}"#
            let tolerant = try JSONDecoder().decode(AppConfig.self, from: Data(broken.utf8))
            try expectEqual(tolerant.remote.enabled, false)
            try expectEqual(tolerant.remote.relayHost, nil)
            try expectEqual(tolerant.remote.appInstallURL, nil)
        },
        TestCase("remote settings: host del relay (host, host:puerto, https://host) y rechazos") {
            try expectEqual(RemoteSettings.normalizedRelayHost("prbar.example.com"), "prbar.example.com")
            try expectEqual(RemoteSettings.normalizedRelayHost(" https://PRBar.Example.com/ "), "prbar.example.com")
            try expectEqual(RemoteSettings.normalizedRelayHost("wss://relay.example.com:8443"), "relay.example.com:8443")
            try expectEqual(RemoteSettings.normalizedRelayHost(RemoteSettings.defaultRelayURL), RemoteSettings.defaultRelayHost)
            for bad in ["", "http://relay.example.com", "relay.example.com/path", "user@relay.example.com", "relay example",
                        "https://relay.example.com?x=1", "relay.example.com:0", "relay.example.com:99999", "-relay.com",
                        "relay..com", "127.0.0.1"] {
                try expectEqual(RemoteSettings.normalizedRelayHost(bad), nil)
            }
            try expectEqual(RemoteSettings.normalizedRelayHost("127.0.0.1:9000", allowIPForTests: true), "127.0.0.1:9000")
        },
        TestCase("remote settings: el link de instalación es https de TestFlight o del App Store") {
            let ok = try RemoteSettings.installURL("https://testflight.apple.com/join/AbCd1234")
            try expectEqual(ok.absoluteString, "https://testflight.apple.com/join/AbCd1234")
            _ = try RemoteSettings.installURL("https://apps.apple.com/app/prbar/id123456")
            for bad in ["http://testflight.apple.com/join/x", "https://testflight.apple.com.evil.com/join/x",
                        "https://evil.com/testflight.apple.com", "https://user@apps.apple.com/app/x",
                        "https://apps.apple.com:444/app/x", "testflight.apple.com/join/x", "javascript:alert(1)", ""] {
                do {
                    _ = try RemoteSettings.installURL(bad)
                    throw TestFailure(description: "aceptó \(bad)")
                } catch let failure as CommandFailure {
                    try expectEqual(failure.code, .invalidUsage)
                }
            }
        },
        TestCase("remote keys: se crean una vez, en el llavero (nunca en config.json), y reset las borra") {
            let secrets = FakeSecrets()
            let store = RemoteKeyStore(secrets: secrets)
            let first = try store.loadOrCreate()
            let second = try store.loadOrCreate()
            try expectEqual(first.relay.publicKey.rawRepresentation, second.relay.publicKey.rawRepresentation)
            try expectEqual(first.noise.publicKey.rawRepresentation, second.noise.publicKey.rawRepresentation)
            try expectEqual(first.seal.publicKey.rawRepresentation, second.seal.publicKey.rawRepresentation)
            for account in ["mac-relay", "mac-noise", "mac-seal"] {
                try expect(secrets.peek(account)?.isEmpty == false, account)
            }
            try expectEqual(RemoteKeyStore.service, "PRBar Remote")
            let config = String(decoding: try JSONEncoder().encode(AppConfig()), as: UTF8.self)
            try expect(!config.contains(first.relay.rawRepresentation.base64EncodedString()))
            try store.reset()
            try expectEqual(secrets.peek("mac-relay") ?? "", "")
            let third = try store.loadOrCreate()
            try expect(third.relay.publicKey.rawRepresentation != first.relay.publicKey.rawRepresentation)
        },
        TestCase("remote keys: una clave rota en el llavero falla en vez de crear otra en silencio") {
            let secrets = FakeSecrets(["mac-relay": "not base64!", "mac-noise": "x", "mac-seal": "y"])
            do {
                _ = try RemoteKeyStore(secrets: secrets).loadOrCreate()
                throw TestFailure(description: "aceptó claves rotas")
            } catch is RemoteKeyStore.Failure {}
        },
        TestCase("remote devices: agregar, quitar, último visto, Face ID; archivo 0600 en carpeta 0700") {
            let dir = try temporaryDirectory().appendingPathComponent("remote")
            let store = RemoteDeviceStore(directory: dir)
            try expect(store.devices.isEmpty)
            let device = sampleDevice("dev1")
            try store.add(device)
            try store.add(sampleDevice("dev2"))
            try store.update(lastSeen: Date(timeIntervalSince1970: 1_800_000_100), for: "dev1")
            try store.setRequirePresence(false, for: "dev2")
            let reopened = RemoteDeviceStore(directory: dir)
            try expectEqual(reopened.devices.map(\.device.deviceId), ["dev1", "dev2"])
            try expectEqual(reopened.devices.first?.lastSeen, Date(timeIntervalSince1970: 1_800_000_100))
            try expectEqual(reopened.devices.last?.device.requirePresence, false)
            try store.remove("dev1")
            try expectEqual(RemoteDeviceStore(directory: dir).devices.map(\.device.deviceId), ["dev2"])
            let fileMode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("devices.json").path)[.posixPermissions] as? Int
            let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
            try expectEqual(fileMode, 0o600)
            try expectEqual(dirMode, 0o700)
            // Solo claves públicas.
            let text = try String(contentsOf: dir.appendingPathComponent("devices.json"), encoding: .utf8)
            try expect(!text.lowercased().contains("private"))
            try store.removeAll()
            try expect(RemoteDeviceStore(directory: dir).devices.isEmpty)
        },
        TestCase("remote devices: un devices.json roto se aparta y se arranca vacío") {
            let dir = try temporaryDirectory().appendingPathComponent("remote")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{nope".utf8).write(to: dir.appendingPathComponent("devices.json"))
            let store = RemoteDeviceStore(directory: dir)
            try expect(store.devices.isEmpty)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            try expect(names.contains { $0.hasPrefix("devices.json.broken-") }, "\(names)")
            try store.add(sampleDevice("dev3"))
            try expectEqual(RemoteDeviceStore(directory: dir).devices.count, 1)
        },
    ]

    static func sampleDevice(_ id: String, name: String = "Federico’s iPhone") -> PairedDevice {
        PairedDevice(deviceId: id, name: name, model: "iPhone 17 Pro",
                     noise: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                     push: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                     presence: P256.Signing.PrivateKey().publicKey.x963Representation,
                     pairedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
}
