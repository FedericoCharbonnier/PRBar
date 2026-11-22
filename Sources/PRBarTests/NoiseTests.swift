import CryptoKit
import Foundation
@_spi(Testing) import PRBarRemoteKit

enum NoiseTests {
    struct Message: Decodable {
        let payload: String
        let ciphertext: String
    }

    struct Vector: Decodable {
        let source: String
        let protocol_name: String
        let init_prologue: String
        let init_psks: [String]?
        let init_static: String
        let init_ephemeral: String
        let init_remote_static: String?
        let resp_prologue: String
        let resp_psks: [String]?
        let resp_static: String
        let resp_ephemeral: String
        let resp_remote_static: String?
        let handshake_hash: String?
        let messages: [Message]
    }

    static func hex(_ text: String) throws -> Data {
        guard let data = Data(hexString: text) else { throw TestFailure(description: "hex inválido: \(text)") }
        return data
    }

    static func load() throws -> [Vector] {
        try JSONDecoder().decode([Vector].self, from: Data(NoiseVectors.json.utf8))
    }

    /// Corre un vector completo: handshake + mensajes de transporte, alternando iniciador/respondedor como el vector.
    static func run(_ v: Vector) throws {
        let pattern: NoisePattern = v.protocol_name.contains("_KK_") ? .kk : .ikpsk2
        typealias Priv = Curve25519.KeyAgreement.PrivateKey
        typealias Pub = Curve25519.KeyAgreement.PublicKey
        var initiator = try NoiseHandshake(
            pattern: pattern, initiator: true, prologue: hex(v.init_prologue),
            localStatic: Priv(rawRepresentation: hex(v.init_static)),
            remoteStatic: v.init_remote_static.map { try Pub(rawRepresentation: hex($0)) },
            psk: v.init_psks?.first.map(hex), fixedEphemeral: Priv(rawRepresentation: hex(v.init_ephemeral)))
        var responder = try NoiseHandshake(
            pattern: pattern, initiator: false, prologue: hex(v.resp_prologue),
            localStatic: Priv(rawRepresentation: hex(v.resp_static)),
            remoteStatic: v.resp_remote_static.map { try Pub(rawRepresentation: hex($0)) },
            psk: v.resp_psks?.first.map(hex), fixedEphemeral: Priv(rawRepresentation: hex(v.resp_ephemeral)))
        let label = "\(v.source) \(v.protocol_name)"
        var transports: (initiator: NoiseTransport, responder: NoiseTransport)?
        for (index, message) in v.messages.enumerated() {
            let payload = try hex(message.payload)
            let expected = try hex(message.ciphertext)
            let fromInitiator = index % 2 == 0
            if index < 2 {
                let written = fromInitiator ? try initiator.writeMessage(payload: payload)
                                            : try responder.writeMessage(payload: payload)
                try expect(written == expected, "\(label): mensaje \(index) distinto")
                let read = fromInitiator ? try responder.readMessage(written) : try initiator.readMessage(written)
                try expect(read == payload, "\(label): payload \(index) distinto")
                if index == 1 {
                    try expect(initiator.isComplete && responder.isComplete, "\(label): handshake incompleto")
                    try expectEqual(initiator.handshakeHash, responder.handshakeHash)
                    if let hash = v.handshake_hash { try expectEqual(initiator.handshakeHash, try hex(hash)) }
                    transports = (try initiator.split(), try responder.split())
                }
            } else {
                guard var t = transports else { throw TestFailure(description: "\(label): sin transporte") }
                if fromInitiator {
                    let written = try t.initiator.send.encrypt(payload)
                    try expect(written == expected, "\(label): transporte \(index) distinto")
                    try expectEqual(try t.responder.receive.decrypt(written), payload)
                } else {
                    let written = try t.responder.send.encrypt(payload)
                    try expect(written == expected, "\(label): transporte \(index) distinto")
                    try expectEqual(try t.initiator.receive.decrypt(written), payload)
                }
                transports = t
            }
        }
    }

    static let cases: [TestCase] = [
        TestCase("noise: vectores KK e IKpsk2") {
            let vectors = try load()
            try expect(vectors.contains { $0.protocol_name == "Noise_KK_25519_ChaChaPoly_SHA256" && $0.handshake_hash != nil })
            try expect(vectors.contains { $0.protocol_name == "Noise_IKpsk2_25519_ChaChaPoly_SHA256" })
            for v in vectors { try run(v) }
        },
        TestCase("noise: un byte cambiado, un mensaje repetido o fuera de orden rompe la sesión") {
            let (a, b) = try NoiseTestPair.kk()
            var sa = a
            let m1 = try sa.send.encrypt(Data("uno".utf8))
            let m2 = try sa.send.encrypt(Data("dos".utf8))
            var bad = m1
            bad[bad.startIndex] ^= 1
            var sb = b
            try expect((try? sb.receive.decrypt(bad)) == nil)
            // Después de un fallo el estado no se vuelve a usar, ni con el mensaje bueno.
            try expect((try? sb.receive.decrypt(m1)) == nil)
            var sb2 = b
            try expectEqual(try sb2.receive.decrypt(m1), Data("uno".utf8))
            try expect((try? sb2.receive.decrypt(m1)) == nil)   // repetido
            var sb3 = b
            try expect((try? sb3.receive.decrypt(m2)) == nil)   // fuera de orden
        },
        TestCase("noise: KK con una estática remota distinta no completa") {
            let i = Curve25519.KeyAgreement.PrivateKey(), r = Curve25519.KeyAgreement.PrivateKey()
            let other = Curve25519.KeyAgreement.PrivateKey()
            var initiator = try NoiseHandshake(pattern: .kk, initiator: true, prologue: Data("p".utf8), localStatic: i,
                                               remoteStatic: r.publicKey, psk: nil)
            var responder = try NoiseHandshake(pattern: .kk, initiator: false, prologue: Data("p".utf8), localStatic: r,
                                               remoteStatic: other.publicKey, psk: nil)
            let m1 = try initiator.writeMessage()
            try expect((try? responder.readMessage(m1)) == nil)
            try expect(!responder.isComplete)
            try expect((try? responder.writeMessage()) == nil)   // sin turno después del fallo
        },
        TestCase("noise: KK con otro prólogo no completa") {
            let i = Curve25519.KeyAgreement.PrivateKey(), r = Curve25519.KeyAgreement.PrivateKey()
            var initiator = try NoiseHandshake(pattern: .kk, initiator: true, prologue: Data("a".utf8), localStatic: i,
                                               remoteStatic: r.publicKey, psk: nil)
            var responder = try NoiseHandshake(pattern: .kk, initiator: false, prologue: Data("b".utf8), localStatic: r,
                                               remoteStatic: i.publicKey, psk: nil)
            try expect((try? responder.readMessage(try initiator.writeMessage())) == nil)
        },
        TestCase("noise: IKpsk2 con otro psk no completa") {
            let i = Curve25519.KeyAgreement.PrivateKey(), r = Curve25519.KeyAgreement.PrivateKey()
            var initiator = try NoiseHandshake(pattern: .ikpsk2, initiator: true, prologue: Data(), localStatic: i,
                                               remoteStatic: r.publicKey, psk: Data(repeating: 1, count: 32))
            var responder = try NoiseHandshake(pattern: .ikpsk2, initiator: false, prologue: Data(), localStatic: r,
                                               remoteStatic: nil, psk: Data(repeating: 2, count: 32))
            // El primer mensaje no lleva el psk (va en el token del segundo): el respondedor lo lee y aprende la estática.
            _ = try responder.readMessage(try initiator.writeMessage(payload: Data("hola".utf8)))
            try expectEqual(responder.remoteStaticKey?.rawRepresentation, i.publicKey.rawRepresentation)
            let m2 = try responder.writeMessage()
            try expect((try? initiator.readMessage(m2)) == nil)
            try expect(!initiator.isComplete)
        },
        TestCase("noise: configuración inválida y fuera de turno") {
            let k = Curve25519.KeyAgreement.PrivateKey()
            try expect((try? NoiseHandshake(pattern: .kk, initiator: true, prologue: Data(), localStatic: k,
                                            remoteStatic: nil, psk: nil)) == nil)
            try expect((try? NoiseHandshake(pattern: .ikpsk2, initiator: true, prologue: Data(), localStatic: k,
                                            remoteStatic: k.publicKey, psk: Data(count: 31))) == nil)
            var h = try NoiseHandshake(pattern: .kk, initiator: false, prologue: Data(), localStatic: k,
                                       remoteStatic: k.publicKey, psk: nil)
            try expect((try? h.writeMessage()) == nil)   // el respondedor no escribe primero
            try expect((try? h.split()) == nil)
        },
        TestCase("noise: mensaje de más de 65535 bytes rechazado") {
            var (a, b) = try NoiseTestPair.kk()
            try expect((try? a.send.encrypt(Data(count: 65_520))) == nil)
            let ok = try a.send.encrypt(Data(count: 65_519))
            try expectEqual(ok.count, 65_535)
            try expectEqual(try b.receive.decrypt(ok).count, 65_519)
            try expect((try? b.receive.decrypt(Data(count: 65_536))) == nil)
        },
    ]
}

/// Un par de transportes KK con claves al azar (la Mac responde, el teléfono inicia).
enum NoiseTestPair {
    static func kk() throws -> (NoiseTransport, NoiseTransport) {
        let i = Curve25519.KeyAgreement.PrivateKey(), r = Curve25519.KeyAgreement.PrivateKey()
        var initiator = try NoiseHandshake(pattern: .kk, initiator: true, prologue: Data("t".utf8), localStatic: i,
                                           remoteStatic: r.publicKey, psk: nil)
        var responder = try NoiseHandshake(pattern: .kk, initiator: false, prologue: Data("t".utf8), localStatic: r,
                                           remoteStatic: i.publicKey, psk: nil)
        _ = try responder.readMessage(try initiator.writeMessage())
        _ = try initiator.readMessage(try responder.writeMessage())
        return (try initiator.split(), try responder.split())
    }
}
