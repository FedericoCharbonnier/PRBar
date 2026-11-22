import CryptoKit
import Foundation

// Atestación de presencia con una passkey de WebAuthn (spec web W.5, reemplaza P.8): el teléfono firma un desafío con la
// passkey (Face ID) y la Mac verifica la aserción con la clave pública registrada al emparejar. El desafío queda atado a
// la sesión de Noise, al id del pedido, a los bytes exactos del comando y a la hora.

public enum PresenceError: Error, Equatable, Sendable {
    case invalidKey
    case invalidSignature
    /// `clientDataJSON` o `authenticatorData` no son lo esperado (tipo, desafío, origen, rpId, flags).
    case invalidAssertion
    /// La aserción es de otra passkey que la registrada.
    case wrongCredential
    /// `|ts − ahora| > 60 s`.
    case stale
    /// Esa prueba (sesión, id) ya se usó.
    case replayed
}

public enum PresenceChallenge {
    static let label = Data("PRBarPresence v2".utf8)

    /// `"PRBarPresence v2" ‖ sessionHash(32) ‖ reqId(u64 BE) ‖ SHA256(cmd) ‖ ts(i64 BE, ms)`: lo que se hashea.
    public static func preimage(sessionHash: Data, reqId: UInt64, commandBytes: Data, tsMillis: Int64) -> Data {
        label + sessionHash + Data(uint64BE: reqId) + Data(SHA256.hash(data: commandBytes)) + Data(int64BE: tsMillis)
    }

    /// El desafío de WebAuthn: `SHA256(preimage)` (32 bytes).
    public static func make(sessionHash: Data, reqId: UInt64, commandBytes: Data, tsMillis: Int64) -> Data {
        Data(SHA256.hash(data: preimage(sessionHash: sessionHash, reqId: reqId, commandBytes: commandBytes,
                                        tsMillis: tsMillis)))
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}

/// La passkey del teléfono como la conoce la Mac (W.4.5): id, clave pública P-256 en SPKI DER y el rpId (el host del
/// relay). En JSON, los bytes van en base64url.
public struct PresenceCredential: Codable, Equatable, Sendable {
    public var credentialId: Data
    /// SPKI DER de una P-256 (ES256).
    public var publicKey: Data
    public var rpId: String

    public init(credentialId: Data, publicKey: Data, rpId: String) {
        self.credentialId = credentialId
        self.publicKey = publicKey
        self.rpId = rpId
    }

    /// WebAuthn permite ids de hasta 1023 bytes.
    static let maxCredentialIdLength = 1_023

    public var isValid: Bool {
        (1...Self.maxCredentialIdLength).contains(credentialId.count)
            && (try? P256.Signing.PublicKey(derRepresentation: publicKey)) != nil
            && !rpId.isEmpty && rpId.count <= 253
    }

    private enum CodingKeys: String, CodingKey { case credentialId, publicKey, rpId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        credentialId = try Base64URL.decode(try c.decode(String.self, forKey: .credentialId))
        publicKey = try Base64URL.decode(try c.decode(String.self, forKey: .publicKey))
        rpId = try c.decode(String.self, forKey: .rpId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Base64URL.encode(credentialId), forKey: .credentialId)
        try c.encode(Base64URL.encode(publicKey), forKey: .publicKey)
        try c.encode(rpId, forKey: .rpId)
    }
}

/// Lo que devuelve `navigator.credentials.get` (los tres campos de `AuthenticatorAssertionResponse`).
public struct WebAuthnAssertion: Equatable, Sendable {
    public var authenticatorData: Data
    public var clientDataJSON: Data
    /// ECDSA P-256 en DER sobre `authenticatorData ‖ SHA256(clientDataJSON)`.
    public var signature: Data

    public init(authenticatorData: Data, clientDataJSON: Data, signature: Data) {
        self.authenticatorData = authenticatorData
        self.clientDataJSON = clientDataJSON
        self.signature = signature
    }
}

/// Quien firma el desafío. En el teléfono es la passkey (la web app); en Swift solo existe el de software.
public protocol WebAuthnAuthenticator: Sendable {
    var credentialId: Data { get }
    func assert(challenge: Data) async throws -> WebAuthnAssertion
}

/// Una passkey de software: para los tests y el teléfono simulado de los fixtures (nunca para un dispositivo real).
/// Arma la aserción como un navegador: `authenticatorData = SHA256(rpId) ‖ flags ‖ signCount(u32 BE)` y
/// `clientDataJSON = {"type":"webauthn.get","challenge":…,"origin":…,"crossOrigin":false}`. Los parámetros de más
/// sirven para que los tests armen aserciones malas.
public struct SoftwareWebAuthnAuthenticator: WebAuthnAuthenticator {
    public let key: P256.Signing.PrivateKey
    public let credentialId: Data
    public let rpId: String
    public var origin: String
    /// `UP` (0x01) y `UV` (0x04).
    public var flags: UInt8
    public var crossOrigin: Bool
    public var type: String
    /// El rpId cuyo hash va en `authenticatorData` (por defecto `rpId`).
    public var assertedRpId: String?
    public var signCount: UInt32

    public init(rpId: String, key: P256.Signing.PrivateKey = .init(), credentialId: Data = randomBytes(16),
                origin: String? = nil, flags: UInt8 = 0x05, crossOrigin: Bool = false, type: String = "webauthn.get",
                assertedRpId: String? = nil, signCount: UInt32 = 0) {
        self.key = key
        self.credentialId = credentialId
        self.rpId = rpId
        self.origin = origin ?? "https://\(rpId)"
        self.flags = flags
        self.crossOrigin = crossOrigin
        self.type = type
        self.assertedRpId = assertedRpId
        self.signCount = signCount
    }

    /// Lo que el teléfono manda al emparejar.
    public var credential: PresenceCredential {
        PresenceCredential(credentialId: credentialId, publicKey: key.publicKey.derRepresentation, rpId: rpId)
    }

    public static func authenticatorData(rpId: String, flags: UInt8, signCount: UInt32 = 0) -> Data {
        Data(SHA256.hash(data: Data(rpId.utf8))) + Data([flags]) + Data(uint32BE: signCount)
    }

    /// El orden de las claves es el de los navegadores (y no importa: la Mac lo parsea).
    public static func clientDataJSON(type: String = "webauthn.get", challenge: Data, origin: String,
                                      crossOrigin: Bool = false) -> Data {
        // Como un navegador: sin escapar `/` (`https://…`).
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func quoted(_ text: String) -> String {
            String(decoding: (try? encoder.encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
        return Data(("{\"type\":\(quoted(type)),\"challenge\":\(quoted(Base64URL.encode(challenge))),"
            + "\"origin\":\(quoted(origin)),\"crossOrigin\":\(crossOrigin)}").utf8)
    }

    public func assert(challenge: Data) async throws -> WebAuthnAssertion {
        let authData = Self.authenticatorData(rpId: assertedRpId ?? rpId, flags: flags, signCount: signCount)
        let clientData = Self.clientDataJSON(type: type, challenge: challenge, origin: origin, crossOrigin: crossOrigin)
        let signature = try key.signature(for: authData + Data(SHA256.hash(data: clientData))).derRepresentation
        return WebAuthnAssertion(authenticatorData: authData, clientDataJSON: clientData, signature: signature)
    }
}

/// Va en el `req` (W.5): `{v: 2, ts, credentialId, authenticatorData, clientDataJSON, signature}`, `ts` en
/// milisegundos (los mismos del desafío) y los bytes en base64url.
public struct PresenceProof: Codable, Equatable, Sendable {
    public static let version = 2

    public var tsMillis: Int64
    public var credentialId: Data
    public var authenticatorData: Data
    public var clientDataJSON: Data
    public var signature: Data

    public init(tsMillis: Int64, credentialId: Data, authenticatorData: Data, clientDataJSON: Data, signature: Data) {
        self.tsMillis = tsMillis
        self.credentialId = credentialId
        self.authenticatorData = authenticatorData
        self.clientDataJSON = clientDataJSON
        self.signature = signature
    }

    public init(tsMillis: Int64, credentialId: Data, assertion: WebAuthnAssertion) {
        self.init(tsMillis: tsMillis, credentialId: credentialId, authenticatorData: assertion.authenticatorData,
                  clientDataJSON: assertion.clientDataJSON, signature: assertion.signature)
    }

    public var ts: Date { Date(timeIntervalSince1970: Double(tsMillis) / 1000) }

    public static func make(authenticator: WebAuthnAuthenticator, sessionHash: Data, reqId: UInt64, commandBytes: Data,
                            at date: Date = Date()) async throws -> PresenceProof {
        let ms = PresenceChallenge.milliseconds(date)
        let challenge = PresenceChallenge.make(sessionHash: sessionHash, reqId: reqId, commandBytes: commandBytes,
                                               tsMillis: ms)
        return PresenceProof(tsMillis: ms, credentialId: authenticator.credentialId,
                             assertion: try await authenticator.assert(challenge: challenge))
    }

    private enum CodingKeys: String, CodingKey { case v, ts, credentialId, authenticatorData, clientDataJSON, signature }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .v) == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "unsupported presence proof")
        }
        func bytes(_ key: CodingKeys) throws -> Data { try Base64URL.decode(try c.decode(String.self, forKey: key)) }
        tsMillis = try c.decode(Int64.self, forKey: .ts)
        credentialId = try bytes(.credentialId)
        authenticatorData = try bytes(.authenticatorData)
        clientDataJSON = try bytes(.clientDataJSON)
        signature = try bytes(.signature)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.version, forKey: .v)
        try c.encode(tsMillis, forKey: .ts)
        try c.encode(Base64URL.encode(credentialId), forKey: .credentialId)
        try c.encode(Base64URL.encode(authenticatorData), forKey: .authenticatorData)
        try c.encode(Base64URL.encode(clientDataJSON), forKey: .clientDataJSON)
        try c.encode(Base64URL.encode(signature), forKey: .signature)
    }
}

/// La verificación de la Mac (W.5). La repetición la controla `PresenceReplayGuard` (que se consulta después).
public enum WebAuthnPresenceVerifier {
    public static let maxSkew: TimeInterval = 60
    static let flagUserPresent: UInt8 = 0x01
    static let flagUserVerified: UInt8 = 0x04
    /// `clientDataJSON` real ronda los 150 bytes: más que esto no se parsea.
    static let maxClientDataLength = 4_096

    /// `origin`: el de la web app (`https://<host del relay>`).
    public static func verify(_ proof: PresenceProof, credential: PresenceCredential, origin: String, sessionHash: Data,
                              reqId: UInt64, commandBytes: Data, now: Date) throws {
        guard proof.credentialId == credential.credentialId else { throw PresenceError.wrongCredential }
        guard let key = try? P256.Signing.PublicKey(derRepresentation: credential.publicKey) else {
            throw PresenceError.invalidKey
        }
        guard abs(proof.ts.timeIntervalSince(now)) <= maxSkew else { throw PresenceError.stale }
        let challenge = PresenceChallenge.make(sessionHash: sessionHash, reqId: reqId, commandBytes: commandBytes,
                                               tsMillis: proof.tsMillis)
        try checkClientData(proof.clientDataJSON, challenge: challenge, origin: origin)
        try checkAuthenticatorData(proof.authenticatorData, rpId: credential.rpId)
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: proof.signature) else {
            throw PresenceError.invalidSignature
        }
        let signed = proof.authenticatorData + Data(SHA256.hash(data: proof.clientDataJSON))
        guard key.isValidSignature(signature, for: signed) else { throw PresenceError.invalidSignature }
    }

    static func checkClientData(_ data: Data, challenge: Data, origin: String) throws {
        guard data.count <= maxClientDataLength,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "webauthn.get",
              object["challenge"] as? String == Base64URL.encode(challenge),
              object["origin"] as? String == origin else { throw PresenceError.invalidAssertion }
        // `crossOrigin` puede faltar; si está, tiene que ser `false` (un iframe de otro sitio no vale).
        if let cross = object["crossOrigin"] {
            guard let flag = cross as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), !flag.boolValue else {
                throw PresenceError.invalidAssertion
            }
        }
    }

    static func checkAuthenticatorData(_ data: Data, rpId: String) throws {
        // rpIdHash (32) ‖ flags (1) ‖ signCount (4) ‖ extensiones opcionales. El contador no se usa (iCloud da 0).
        guard data.count >= 37 else { throw PresenceError.invalidAssertion }
        let bytes = [UInt8](data)
        guard Data(bytes[0..<32]) == Data(SHA256.hash(data: Data(rpId.utf8))) else { throw PresenceError.invalidAssertion }
        let flags = bytes[32]
        guard flags & flagUserPresent != 0, flags & flagUserVerified != 0 else { throw PresenceError.invalidAssertion }
    }
}

/// Recuerda las pruebas usadas mientras pueden seguir siendo válidas (2 × la tolerancia de hora): memoria acotada.
public struct PresenceReplayGuard: Sendable {
    private var seen: [Data: Date] = [:]
    static let retention: TimeInterval = 2 * WebAuthnPresenceVerifier.maxSkew + 60
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
