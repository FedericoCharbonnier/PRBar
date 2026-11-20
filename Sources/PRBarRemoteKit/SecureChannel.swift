import CryptoKit
import Foundation
import PRBarWire

/// Una sesión de Noise ya establecida (spec P.5): cifra marcos de aplicación partidos en trozos y los rearma. Un trozo
/// que no autentica (cambiado, repetido, fuera de orden) o un marco malformado rompe la sesión: quien la usa la cierra.
struct SecureChannel: Sendable {
    let sid: String
    let handshakeHash: Data
    let startedAt: Date
    private var transport: NoiseTransport
    private var assembler = FrameAssembler()

    /// Rotación (spec P.5): handshake nuevo a las 24 h o a los 2²⁰ mensajes en cualquier dirección.
    static let maxAge: TimeInterval = 24 * 3_600
    static let maxMessages: UInt64 = 1 << 20
    /// Se comprimen los `state` y lo que pasa de 4 KiB (spec P.5).
    static let compressionThreshold = 4 * 1024

    init(sid: String, handshake: NoiseHandshake, startedAt: Date) throws {
        self.sid = sid
        handshakeHash = handshake.handshakeHash
        transport = try handshake.split()
        self.startedAt = startedAt
    }

    /// Cifra un marco: un `b` por trozo, en orden.
    mutating func seal(_ frame: RemoteFrame) throws -> [Data] {
        let data = try frame.encoded()
        var compress = data.count > Self.compressionThreshold
        if case .state = frame { compress = true }
        return try FrameChunker.chunks(for: data, compress: compress).map { try transport.send.encrypt($0) }
    }

    /// Descifra un trozo; devuelve el marco cuando está completo.
    mutating func open(_ ciphertext: Data) throws -> RemoteFrame? {
        let chunk = try transport.receive.decrypt(ciphertext)
        guard let data = try assembler.add(chunk) else { return nil }
        return try RemoteFrame.decode(data)
    }

    func needsRotation(now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= Self.maxAge
            || transport.send.n >= Self.maxMessages || transport.receive.n >= Self.maxMessages
    }
}

/// Mensajes de la sesión de emparejamiento (Noise IKpsk2, spec P.11). Chicos: van en un solo mensaje de Noise.
enum PairingMessage: Codable, Equatable, Sendable {
    /// Payload del primer mensaje del teléfono.
    case join(PairingJoin)
    /// Primer mensaje de transporte del teléfono: prueba que tenía el psk (el secreto del QR).
    case confirm
    /// "Codes Match" en la Mac.
    case result(PairingResult)
    case cancelled

    func encoded() throws -> Data { try CommandProtocol.encoder.encode(self) }

    static func decode(_ data: Data) throws -> PairingMessage {
        try CommandProtocol.decoder.decode(PairingMessage.self, from: data)
    }
}

/// Lo que el teléfono manda al unirse: nombre, modelo y sus claves públicas (la estática de Noise va en el handshake).
struct PairingJoin: Codable, Equatable, Sendable {
    var deviceName: String
    var model: String
    var relayKey: Data
    var push: Data
    var presence: Data

    var isValid: Bool {
        relayKey.count == 32 && push.count == 32 && (try? P256.Signing.PublicKey(x963Representation: presence)) != nil
            && !deviceName.isEmpty && deviceName.count <= 64 && model.count <= 64
    }
}

struct PairingResult: Codable, Equatable, Sendable {
    var deviceId: String
    var macName: String
    var macSeal: Data
    var relayHost: String
}

enum RemoteSID {
    /// 8 bytes al azar del iniciador, en hex (spec P.5).
    static func new() -> String { randomBytes(8).hexString }

    static func isValid(_ sid: String) -> Bool {
        sid.utf8.count == 16 && sid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
