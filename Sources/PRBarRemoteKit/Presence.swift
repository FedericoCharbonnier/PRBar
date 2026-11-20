import CryptoKit
import Foundation

// Atestación de presencia (spec P.8): el teléfono firma con una P-256 del Secure Enclave que exige Face ID; la Mac
// verifica la firma con la clave pública registrada al emparejar. La prueba queda atada a la sesión de Noise, al id del
// pedido, a los bytes exactos del comando y a la hora.

public enum PresenceError: Error, Equatable, Sendable {
    case invalidKey
    case invalidSignature
    /// `|ts − ahora| > 60 s`.
    case stale
    /// Esa prueba (sesión, id) ya se usó.
    case replayed
}

public enum PresenceMessage {
    static let label = Data("PRBarPresence v1".utf8)

    /// `"PRBarPresence v1" ‖ sessionHash(32) ‖ reqId(u64 BE) ‖ SHA256(cmd) ‖ ts(i64 BE, ms)`.
    public static func bytes(sessionHash: Data, reqId: UInt64, commandBytes: Data, ts: Date) -> Data {
        bytes(sessionHash: sessionHash, reqId: reqId, commandBytes: commandBytes, tsMillis: milliseconds(ts))
    }

    /// Con los milisegundos tal cual (sin pasar por `Double`, que podría correr uno).
    public static func bytes(sessionHash: Data, reqId: UInt64, commandBytes: Data, tsMillis: Int64) -> Data {
        label + sessionHash + Data(uint64BE: reqId) + Data(SHA256.hash(data: commandBytes)) + Data(int64BE: tsMillis)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}

/// Firma ECDSA P-256/SHA-256 en DER. La del Secure Enclave es del Plan 19 (iOS).
public protocol PresenceSigner: Sendable {
    func sign(_ message: Data) async throws -> Data
}

/// Una P-256 de software: para los tests (y nunca para un dispositivo real).
public struct SoftwarePresenceSigner: PresenceSigner {
    private let key: P256.Signing.PrivateKey

    public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.key = key
    }

    /// x963 (65 bytes), lo que se registra al emparejar.
    public var publicKey: Data { key.publicKey.x963Representation }

    public func sign(_ message: Data) async throws -> Data {
        try key.signature(for: message).derRepresentation
    }
}

/// Va en el `req`. `ts` viaja en milisegundos (los mismos que se firmaron) y `sig` en base64url.
public struct PresenceProof: Codable, Equatable, Sendable {
    public var tsMillis: Int64
    public var sig: Data

    public init(tsMillis: Int64, sig: Data) {
        self.tsMillis = tsMillis
        self.sig = sig
    }

    public var ts: Date { Date(timeIntervalSince1970: Double(tsMillis) / 1000) }

    public static func make(signer: PresenceSigner, sessionHash: Data, reqId: UInt64, commandBytes: Data,
                            at date: Date = Date()) async throws -> PresenceProof {
        let ms = PresenceMessage.milliseconds(date)
        let message = PresenceMessage.bytes(sessionHash: sessionHash, reqId: reqId, commandBytes: commandBytes,
                                            tsMillis: ms)
        return PresenceProof(tsMillis: ms, sig: try await signer.sign(message))
    }

    private enum CodingKeys: String, CodingKey { case ts, sig }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tsMillis = try c.decode(Int64.self, forKey: .ts)
        sig = try Base64URL.decode(try c.decode(String.self, forKey: .sig))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tsMillis, forKey: .ts)
        try c.encode(Base64URL.encode(sig), forKey: .sig)
    }
}

public enum PresenceVerifier {
    public static let maxSkew: TimeInterval = 60

    /// Verifica firma y hora. La repetición la controla `PresenceReplayGuard` (que se consulta después de verificar).
    public static func verify(_ proof: PresenceProof, publicKey: Data, sessionHash: Data, reqId: UInt64,
                              commandBytes: Data, now: Date) throws {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey) else { throw PresenceError.invalidKey }
        guard abs(proof.ts.timeIntervalSince(now)) <= maxSkew else { throw PresenceError.stale }
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: proof.sig) else {
            throw PresenceError.invalidSignature
        }
        let message = PresenceMessage.bytes(sessionHash: sessionHash, reqId: reqId, commandBytes: commandBytes,
                                            tsMillis: proof.tsMillis)
        guard key.isValidSignature(signature, for: message) else { throw PresenceError.invalidSignature }
    }
}

/// Recuerda las pruebas usadas mientras pueden seguir siendo válidas (2 × la tolerancia de hora): memoria acotada.
public struct PresenceReplayGuard: Sendable {
    private var seen: [Data: Date] = [:]
    static let retention: TimeInterval = 2 * PresenceVerifier.maxSkew + 60
    static let maxEntries = 4_096

    public init() {}

    public mutating func check(sessionHash: Data, reqId: UInt64, now: Date) throws {
        seen = seen.filter { now.timeIntervalSince($0.value) < Self.retention }
        let key = sessionHash + Data(uint64BE: reqId)
        guard seen[key] == nil else { throw PresenceError.replayed }
        // Con el tope lleno se rechaza en vez de olvidar (olvidar abriría la puerta a una repetición).
        guard seen.count < Self.maxEntries else { throw PresenceError.replayed }
        seen[key] = now
    }
}
