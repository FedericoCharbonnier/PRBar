import CryptoKit
import Foundation
import PRBarRemoteKit

/// `WebAuthnPresenceVerifier` (spec web W.5): aserciones armadas en el test con una P-256 de software, como las de un
/// navegador, y cada caso de rechazo.
enum PresenceTests {
    static let session = Data(repeating: 0xAB, count: 32)
    static let command = Data(#"{"merge":{"pr":"a/b#1"}}"#.utf8)
    static let now = Date(timeIntervalSince1970: 1_800_000_000.123)
    static let rpId = "prbar.example.org"
    static let origin = "https://prbar.example.org"

    static func proof(_ authenticator: SoftwareWebAuthnAuthenticator, session: Data = session, reqId: UInt64 = 5,
                      command: Data = command, at date: Date = now) async throws -> PresenceProof {
        try await PresenceProof.make(authenticator: authenticator, sessionHash: session, reqId: reqId,
                                     commandBytes: command, at: date)
    }

    static func verify(_ proof: PresenceProof, credential: PresenceCredential, origin: String = origin,
                       session: Data = session, reqId: UInt64 = 5, command: Data = command,
                       now date: Date = now) -> PresenceError? {
        do {
            try WebAuthnPresenceVerifier.verify(proof, credential: credential, origin: origin, sessionHash: session,
                                                reqId: reqId, commandBytes: command, now: date)
            return nil
        } catch let error as PresenceError {
            return error
        } catch {
            return .invalidAssertion
        }
    }

    /// Una aserción de `authenticator` verificada contra la credencial de `registered`.
    static func rejection(_ authenticator: SoftwareWebAuthnAuthenticator,
                          registered: SoftwareWebAuthnAuthenticator) async throws -> PresenceError? {
        verify(try await proof(authenticator), credential: registered.credential)
    }

    static let cases: [TestCase] = [
        TestCase("presence: el desafío v2 es SHA256 de los bytes exactos") {
            let preimage = PresenceChallenge.preimage(sessionHash: Data(repeating: 1, count: 32), reqId: 0x0102,
                                                      commandBytes: Data("x".utf8), tsMillis: 1_500)
            try expectEqual(preimage.count, 16 + 32 + 8 + 32 + 8)
            var expected = Data("PRBarPresence v2".utf8) + Data(repeating: 1, count: 32)
            expected += Data([0, 0, 0, 0, 0, 0, 1, 2])
            expected += Data(SHA256.hash(data: Data("x".utf8)))
            expected += Data([0, 0, 0, 0, 0, 0, 0x05, 0xDC])   // 1500 ms
            try expectEqual(preimage, expected)
            let challenge = PresenceChallenge.make(sessionHash: Data(repeating: 1, count: 32), reqId: 0x0102,
                                                   commandBytes: Data("x".utf8), tsMillis: 1_500)
            try expectEqual(challenge, Data(SHA256.hash(data: expected)))
        },
        TestCase("presence: una aserción válida pasa (también sin crossOrigin y con extensiones)") {
            let passkey = SoftwareWebAuthnAuthenticator(rpId: rpId)
            let good = try await proof(passkey)
            try expectEqual(verify(good, credential: passkey.credential), nil)
            try expectEqual(verify(good, credential: passkey.credential, now: now.addingTimeInterval(59)), nil)
            // Un navegador puede omitir `crossOrigin` y agregar campos; authenticatorData puede traer extensiones.
            let challenge = PresenceChallenge.make(sessionHash: session, reqId: 5, commandBytes: command,
                                                   tsMillis: good.tsMillis)
            let clientData = Data(#"{"type":"webauthn.get","challenge":"\#(Base64URL.encode(challenge))","origin":"\#(origin)","other_keys_can_be_added_here":"x"}"#.utf8)
            let authData = SoftwareWebAuthnAuthenticator.authenticatorData(rpId: rpId, flags: 0x85, signCount: 7)
                + Data([0xA0])
            let signature = try passkey.key.signature(for: authData + Data(SHA256.hash(data: clientData))).derRepresentation
            let browser = PresenceProof(tsMillis: good.tsMillis, credentialId: passkey.credentialId,
                                        authenticatorData: authData, clientDataJSON: clientData, signature: signature)
            try expectEqual(verify(browser, credential: passkey.credential), nil)
        },
        TestCase("presence: rechaza UV o UP apagados, otro origen, crossOrigin, otro rpId y otro tipo") {
            let key = P256.Signing.PrivateKey()
            let id = Data(repeating: 3, count: 16)
            let registered = SoftwareWebAuthnAuthenticator(rpId: rpId, key: key, credentialId: id)
            func variant(origin: String? = nil, flags: UInt8 = 0x05, crossOrigin: Bool = false,
                         type: String = "webauthn.get", assertedRpId: String? = nil) -> SoftwareWebAuthnAuthenticator {
                SoftwareWebAuthnAuthenticator(rpId: rpId, key: key, credentialId: id, origin: origin, flags: flags,
                                              crossOrigin: crossOrigin, type: type, assertedRpId: assertedRpId)
            }
            let cases: [(String, SoftwareWebAuthnAuthenticator, PresenceError?)] = [
                ("sin UV", variant(flags: 0x01), .invalidAssertion),
                ("sin UP", variant(flags: 0x04), .invalidAssertion),
                ("otro origen", variant(origin: "https://evil.example.org"), .invalidAssertion),
                ("http", variant(origin: "http://prbar.example.org"), .invalidAssertion),
                ("crossOrigin", variant(crossOrigin: true), .invalidAssertion),
                ("otro tipo", variant(type: "webauthn.create"), .invalidAssertion),
                ("otro rpId", variant(assertedRpId: "evil.example.org"), .invalidAssertion),
                ("buena", variant(), nil),
            ]
            for (name, authenticator, expected) in cases {
                let got = try await rejection(authenticator, registered: registered)
                try expect(got == expected, "\(name): \(String(describing: got))")
            }
        },
        TestCase("presence: rechaza otro desafío (sesión, id, comando), otra credencial, otra clave y firma rota") {
            let passkey = SoftwareWebAuthnAuthenticator(rpId: rpId)
            let credential = passkey.credential
            let good = try await proof(passkey)
            try expectEqual(verify(good, credential: credential, session: Data(repeating: 0xAC, count: 32)),
                            .invalidAssertion)
            try expectEqual(verify(good, credential: credential, reqId: 6), .invalidAssertion)
            var other = command
            other[other.startIndex + 3] ^= 1
            try expectEqual(verify(good, credential: credential, command: other), .invalidAssertion)
            // Otra passkey (otro id).
            let stranger = SoftwareWebAuthnAuthenticator(rpId: rpId)
            let strangerResult = try await rejection(stranger, registered: passkey)
            try expectEqual(strangerResult, .wrongCredential)
            // El id bueno pero firmado con otra clave.
            let forged = SoftwareWebAuthnAuthenticator(rpId: rpId, credentialId: passkey.credentialId)
            let forgedResult = try await rejection(forged, registered: passkey)
            try expectEqual(forgedResult, .invalidSignature)
            var truncated = good
            truncated.signature = good.signature.dropLast()
            try expectEqual(verify(truncated, credential: credential), .invalidSignature)
            var tamperedData = good
            tamperedData.authenticatorData[tamperedData.authenticatorData.startIndex + 36] ^= 1   // signCount
            try expectEqual(verify(tamperedData, credential: credential), .invalidSignature)
            var badKey = credential
            badKey.publicKey = Data(repeating: 4, count: 91)
            try expectEqual(verify(good, credential: badKey), .invalidKey)
        },
        TestCase("presence: ts de más de 60 s (pasado o futuro) se rechaza") {
            let passkey = SoftwareWebAuthnAuthenticator(rpId: rpId)
            let good = try await proof(passkey)
            try expectEqual(verify(good, credential: passkey.credential, now: now.addingTimeInterval(61)), .stale)
            try expectEqual(verify(good, credential: passkey.credential, now: now.addingTimeInterval(-61)), .stale)
            // Cambiar `ts` en la prueba cambia el desafío: tampoco sirve.
            var moved = good
            moved.tsMillis += 1
            try expectEqual(verify(moved, credential: passkey.credential), .invalidAssertion)
        },
        TestCase("presence: ida y vuelta en JSON (v 2, base64url, milisegundos)") {
            let passkey = SoftwareWebAuthnAuthenticator(rpId: rpId)
            let good = try await proof(passkey)
            let text = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
            try expect(text.contains("\"ts\":1800000000123"))
            try expect(text.contains("\"v\":2"))
            try expect(text.contains("\"clientDataJSON\":\"\(Base64URL.encode(good.clientDataJSON))\""))
            let back = try JSONDecoder().decode(PresenceProof.self, from: Data(text.utf8))
            try expectEqual(back, good)
            try expectEqual(verify(back, credential: passkey.credential), nil)
            let v1 = text.replacingOccurrences(of: "\"v\":2", with: "\"v\":1")
            try expect((try? JSONDecoder().decode(PresenceProof.self, from: Data(v1.utf8))) == nil)
            let old = #"{"ts":1800000000123,"sig":"AAAA"}"#
            try expect((try? JSONDecoder().decode(PresenceProof.self, from: Data(old.utf8))) == nil)
        },
        TestCase("presence: la credencial va en base64url y se valida") {
            let passkey = SoftwareWebAuthnAuthenticator(rpId: rpId)
            let credential = passkey.credential
            try expect(credential.isValid)
            let text = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)
            try expect(text.contains("\"publicKey\":\"\(Base64URL.encode(credential.publicKey))\""))
            try expectEqual(try JSONDecoder().decode(PresenceCredential.self, from: Data(text.utf8)), credential)
            var x963 = credential
            x963.publicKey = passkey.key.publicKey.x963Representation
            try expect(!x963.isValid)
            var noId = credential
            noId.credentialId = Data()
            try expect(!noId.isValid)
            var noRp = credential
            noRp.rpId = ""
            try expect(!noRp.isValid)
        },
        TestCase("presence: el mismo (sesión, id) dos veces es una repetición") {
            var guardian = PresenceReplayGuard()
            try guardian.check(sessionHash: session, reqId: 1, now: now)
            try guardian.check(sessionHash: session, reqId: 2, now: now)
            try guardian.check(sessionHash: Data(repeating: 1, count: 32), reqId: 1, now: now)
            do {
                try guardian.check(sessionHash: session, reqId: 1, now: now.addingTimeInterval(30))
                throw TestFailure(description: "aceptó una repetición")
            } catch let error as PresenceError {
                try expectEqual(error, .replayed)
            }
        },
    ]
}

/// El rpId de las passkeys para un host de relay (`host:puerto` → `host`).
func rpIdOf(_ relayHost: String) -> String {
    String(relayHost.split(separator: ":").first ?? Substring(relayHost))
}
