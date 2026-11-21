import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteFixtures
@_spi(Testing) import PRBarRemoteKit
import PRBarWire

/// Los vectores de `prbar-remote-fixture vectors` (los de `web/test/fixtures/`) vuelven a pasar por los decodificadores
/// y verificadores de Swift: si la Mac cambia el formato, cambian los vectores y la web lo nota.
enum WebVectorsTests {
    @MainActor
    static func load() async throws -> [String: Any] {
        let files = try await WebVectors.files()
        try expectEqual(files.keys.sorted(), ["app.json", "frames.json", "hpke.json", "noise-ikpsk2.json", "noise-kk.json",
                                              "pairing-qr.json", "presence.json", "relay-auth.json", "sas.json"])
        var out: [String: Any] = [:]
        for (name, data) in files { out[name] = try JSONSerialization.jsonObject(with: data) }
        // Nada de rutas locales en lo que se commitea.
        for data in files.values { try expect(!String(decoding: data, as: UTF8.self).contains("/Users/")) }
        out["raw"] = files
        return out
    }

    static func hex(_ any: Any?) throws -> Data {
        guard let text = any as? String, let data = Data(hexString: text) else {
            throw TestFailure(description: "hex inválido: \(String(describing: any))")
        }
        return data
    }

    static func list(_ any: Any?) throws -> [[String: Any]] {
        guard let list = any as? [[String: Any]] else { throw TestFailure(description: "no es una lista") }
        return list
    }

    static func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    static let cases: [TestCase] = [
        TestCase("web vectors: Noise KK e IKpsk2 corren con el mismo código que los oficiales") {
            let all = try await load()
            let raw = all["raw"] as! [String: Data]
            for name in ["noise-kk.json", "noise-ikpsk2.json"] {
                let vectors = try JSONDecoder().decode([NoiseTests.Vector].self, from: raw[name]!)
                try expectEqual(vectors.count, 1)
                for v in vectors { try NoiseTests.run(v) }
            }
            let ik = try list(all["noise-ikpsk2.json"])[0]
            let messages = try list(ik["messages"])
            try expect(PairingWire.isValidJoin(try hex(messages[0]["payload"])))
            try expectEqual(ik["sas"] as? String, SAS.code(handshakeHash: try hex(ik["handshake_hash"])))
            let secrets = PairingSecrets(secret: try hex(ik["ps"]))
            try expectEqual(try hex(ik["pairAuthKey"]), secrets.authKey)
            try expectEqual(try hex((ik["init_psks"] as? [String])?.first), secrets.psk)
            // Los payloads de transporte de KK son trozos de marcos reales.
            let kk = try list(all["noise-kk.json"])[0]
            for message in try list(kk["messages"]).dropFirst(2) {
                var assembler = FrameAssembler()
                let frame = try assembler.add(try hex(message["payload"]))
                try expectEqual(frame.map { String(decoding: $0, as: UTF8.self) }, message["frame"] as? String)
            }
        },
        TestCase("web vectors: HPKE (push y buzón), SAS y firmas del relay") {
            let all = try await load()
            typealias Priv = Curve25519.KeyAgreement.PrivateKey
            let entries = try list(all["hpke.json"])
            let push = entries[0], mailbox = entries[1]
            let skR = try Priv(rawRepresentation: try hex(push["skR"]))
            let pkS = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: try hex(push["pkS"]))
            try expectEqual(try hex(push["info"]), SealedInfo.push(account: WebVectors.accountId, device: WebVectors.deviceId))
            let opened = try PushPayload.open(pushField: push["envelopeB64url"] as! String, by: skR, from: pkS,
                                              info: try hex(push["info"]))
            try expectEqual(try CommandProtocol.encoder.encode(opened), try hex(push["plaintext"]))
            try expectEqual(try SealedEnvelope.open(try hex(push["envelope"]), by: skR, from: pkS, info: try hex(push["info"])),
                            try hex(push["plaintext"]))
            let blob = try MailboxBlob.open(try hex(mailbox["envelope"]), by: skR, from: pkS, account: WebVectors.accountId,
                                            device: WebVectors.deviceId, slot: "home", minimumRev: 0)
            try expectEqual(try CommandProtocol.encoder.encode(blob), try hex(mailbox["plaintext"]))
            for entry in try list(all["sas.json"]) {
                try expectEqual(entry["code"] as? String, SAS.code(handshakeHash: try hex(entry["handshakeHash"])))
            }
            for entry in try list(all["relay-auth.json"]) {
                let key = try Curve25519.Signing.PublicKey(rawRepresentation: try hex(entry["publicKey"]))
                let message = RelayAuth.message(host: entry["host"] as! String, account: entry["acct"] as! String,
                                                client: entry["client"] as! String, nonce: try hex(entry["nonce"]))
                try expectEqual(message, try hex(entry["message"]))
                try expect(key.isValidSignature(try hex(entry["sig"]), for: message))
            }
        },
        TestCase("web vectors: presencia — desafío exacto y una prueba que la Mac acepta") {
            let all = try await load()
            for entry in try list(all["presence.json"]) {
                let session = try hex(entry["sessionHash"]), cmd = try hex(entry["cmd"])
                let reqId = (entry["reqId"] as! NSNumber).uint64Value, ts = (entry["ts"] as! NSNumber).int64Value
                try expect(reqId < 1 << 53, "reqId no entra en un número de JS")
                try expectEqual(PresenceChallenge.make(sessionHash: session, reqId: reqId, commandBytes: cmd, tsMillis: ts),
                                try hex(entry["challenge"]))
                guard let proofObject = entry["proof"], let credentialObject = entry["credential"] else { continue }
                let proof = try JSONDecoder().decode(PresenceProof.self, from: try data(proofObject))
                let credential = try JSONDecoder().decode(PresenceCredential.self, from: try data(credentialObject))
                try WebAuthnPresenceVerifier.verify(proof, credential: credential, origin: entry["origin"] as! String,
                                                    sessionHash: session, reqId: reqId, commandBytes: cmd,
                                                    now: Date(timeIntervalSince1970: Double(ts) / 1000))
                try expect(!(entry["clientDataJSON"] as! String).contains("\\/"), "barras escapadas")
            }
        },
        TestCase("web vectors: QR de emparejamiento y marcos del relay y de la app") {
            let all = try await load()
            let qr = all["pairing-qr.json"] as! [String: Any]
            for entry in try list(qr["valid"]) {
                let parsed = try PairingQR(url: entry["url"] as! String)
                try expectEqual(parsed.relayHost, entry["relayHost"] as? String)
                try expectEqual(parsed.secret, try hex(entry["secret"]))
                try expectEqual(parsed.macStatic, try hex(entry["macStatic"]))
                try expectEqual(parsed.macName, entry["macName"] as? String)
                try expectEqual(PairingSecrets.proof(authKey: try hex(entry["authKey"]), nonce: try hex(entry["nonce"])),
                                try hex(entry["proof"]))
            }
            for text in qr["invalid"] as! [String] { try expect((try? PairingQR(url: text)) == nil, text) }
            let frames = all["frames.json"] as! [String: Any]
            for entry in try list(frames["relay"]) {
                let text = entry["text"] as! String
                try expectEqual(try RelayMessage.decode(text).text(), text)
            }
            for entry in try list(frames["app"]) {
                let text = entry["text"] as! String
                let frame = try RemoteFrame.decode(Data(text.utf8))
                try expectEqual(String(decoding: try frame.encoded(), as: UTF8.self), text)
                try expectEqual(frame.type, entry["type"] as? String)
            }
            for entry in try list(frames["chunks"]) {
                var assembler = FrameAssembler()
                var frame: Data?
                for chunk in entry["chunks"] as! [String] { frame = try assembler.add(try hex(chunk)) }
                try expectEqual(frame.map { String(decoding: $0, as: UTF8.self) }, entry["frame"] as? String)
            }
        },
        TestCase("web vectors: cada comando del teléfono, su respuesta y los tópicos decodifican") {
            let all = try await load()
            let app = all["app.json"] as! [String: Any]
            let commands = try list(app["commands"])
            let names = Set(commands.compactMap { $0["name"] as? String })
            let phone = AppCommand.Name.allCases.filter { RemotePolicy.classify($0) != .denied }.map(\.rawValue)
            try expectEqual(names, Set(phone))
            for entry in commands {
                let text = entry["text"] as! String
                let command = try CommandProtocol.decode(AppCommand.self, line: text)
                try expectEqual(try CommandProtocol.line(command), text)
                let response = try CommandProtocol.decode(CommandResponse.self, line: entry["responseText"] as! String)
                try expect(response.ok == true, "\(entry["name"] ?? "") falló en el fixture: \(String(describing: response.error))")
            }
            let topics = try list(app["topics"])
            let home = try CommandProtocol.decoder.decode(RemoteHome.self, from: Data((topics[0]["text"] as! String).utf8))
            try expectEqual(home.prs.count, 3)
            _ = try CommandProtocol.decoder.decode(RemotePRDetail.self, from: Data((topics[1]["text"] as! String).utf8))
            _ = try CommandProtocol.decoder.decode(RemoteActivity.self, from: Data((topics[3]["text"] as! String).utf8))
            for object in app["push"] as! [Any] {
                _ = try CommandProtocol.decoder.decode(PushPayload.self, from: try data(object))
            }
            try expectEqual(app["protocolVersion"] as? Int, CommandProtocol.version)
        },
    ]
}
