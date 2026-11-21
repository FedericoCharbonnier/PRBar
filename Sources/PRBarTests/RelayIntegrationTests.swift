import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteKit

/// Swift ↔ Go: con `PRBAR_RELAY_BIN` (binario de `go build ./cmd/prbar-relay` para macOS) levanta el relay de verdad
/// en 127.0.0.1 y corre emparejamiento, sesión, política, revocación y push con `WebSocketRelayLink` sobre `ws://`.
/// Sin la variable, se saltea (y pasa).
enum RelayIntegrationTests {
    final class RelayProcess {
        let process = Process()
        let port: Int
        let token = randomBytes(32).hexString
        let data: URL

        init(binary: String) throws {
            port = Int.random(in: 20_000...60_000)
            data = try temporaryDirectory()
            process.executableURL = URL(fileURLWithPath: binary)
            process.environment = [
                "RELAY_LISTEN": "127.0.0.1:\(port)",
                "RELAY_DATA": data.path,
                "RELAY_PUBLIC_HOST": "127.0.0.1",
                "RELAY_ENROLL_TOKEN": token,
                "RELAY_TEST_MODE": "1",
                "RELAY_TRUSTED_PROXIES": "none",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        var host: String { "127.0.0.1:\(port)" }

        func waitUntilHealthy() async throws {
            let url = URL(string: "http://\(host)/healthz")!
            for _ in 0..<100 {
                if let (data, _) = try? await URLSession.shared.data(from: url), String(decoding: data, as: UTF8.self) == "ok" {
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw TestFailure(description: "the relay didn't start")
        }

        func enroll(_ key: Curve25519.Signing.PublicKey) async throws -> String {
            var request = URLRequest(url: URL(string: "http://\(host)/v1/accounts")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(["enrollToken": token,
                                                         "macRelayKey": Base64URL.encode(key.rawRepresentation)])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let account = try JSONDecoder().decode([String: String].self, from: data)["accountId"] else {
                throw TestFailure(description: "enroll failed")
            }
            return account
        }

        func stop() {
            process.terminate()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: data)
        }
    }

    static let cases: [TestCase] = [
        TestCase("relay integration: emparejar, sesión, política, revocar y push contra el relay en Go") {
            guard let binary = ProcessInfo.processInfo.environment["PRBAR_RELAY_BIN"] else {
                print("    skipped: PRBAR_RELAY_BIN not set")
                return
            }
            let relay = try RelayProcess(binary: binary)
            defer { relay.stop() }
            try await relay.waitUntilHealthy()
            let keys = MacKeys()
            let account = try await relay.enroll(keys.relay.publicKey)
            let factory = WebSocketRelayLink.factory(host: relay.host, allowInsecureTransportForTests: true)
            let recorder = CommandRecorder()
            let host = RemoteHost(
                configuration: .init(accountId: account, relayHost: relay.host, macName: "Mac", appVersion: "1.2.0",
                                     keys: keys, pushTimeout: .seconds(5), backoff: { _ in .milliseconds(200) }),
                devices: [], linkFactory: factory, handler: { command, _ in
                    await recorder.record(command)
                    return .success(.ok)
                })
            try await host.connect()
            // Emparejar.
            let presence = SoftwareWebAuthnAuthenticator(rpId: rpIdOf(relay.host))
            let client = RemoteClient(configuration: .init(appVersion: "1.2.0", deviceName: "iPhone", model: "iPhone",
                                                           handshakeTimeout: .seconds(5)),
                                      linkFactory: factory)
            let qr = try await host.startPairing()
            try await Task.sleep(for: .milliseconds(200))
            let events = host.events
            async let joined: String = within(10) {
                for await event in events { if case .pairingJoined(let sas, _, _) = event { return sas } }
                throw TestFailure(description: "no join")
            }
            let sas = try await client.startPairing(qr: qr, presence: presence.credential)
            let joinedSAS = try await joined
            try expectEqual(joinedSAS, sas)
            try await host.confirmPairing(true)
            let paired = try await within(10) { try await client.finishPairing() }
            // Sesión, comando y política.
            try await within(10) { try await client.connect() }
            let status = try await client.run(.status)
            try expectEqual(status.ok, true)
            let denied = try await client.run(.quit)
            try expectEqual(denied.error?.code, .unauthorized)
            let merge = AppCommand.merge(pr: "a/b#1", method: nil, confirmed: true, expectedHeadOid: "abc")
            let gated = try await client.run(merge)
            try expectEqual(gated.error?.code, .unauthorized)
            let signed = try await client.run(merge, presence: presence)
            try expectEqual(signed.ok, true)
            // Push: sin suscripción de Web Push el relay contesta 410 (sin VAPID, 503): llega y vuelve.
            let payload = PushPayload(createdAt: Date(), kind: "k", title: "t", body: "b", threadId: "x",
                                      deepLink: "prbar://")
            let pushStatus = try await host.push(payload, to: paired.deviceId)
            try expect([410, 503].contains(pushStatus), "push status \(pushStatus)")
            // Revocar: el relay corta con 4403.
            await host.revoke(paired.deviceId)
            try await eventually(10, "revoked") { await client.status == .revoked }
            let commands = await recorder.commands
            try expectEqual(commands, [.status, merge])
            await host.disconnect()
        },
    ]
}
