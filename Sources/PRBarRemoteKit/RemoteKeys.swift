import CryptoKit
import Foundation

// Las claves y lo que cada lado recuerda del otro (spec P.2). Sin almacenamiento: la Mac las guarda en el llavero y en
// `devices.json` (Plan 18); el teléfono es la web app (`web/`), que tiene su propia implementación. Las de teléfono de
// acá (`DeviceKeys`, `PairedMac`) solo las usan los tests y la Mac simulada. En JSON, cada clave va como
// `rawRepresentation` en base64url.

private func encodeKey<K: CodingKey>(_ data: Data, _ container: inout KeyedEncodingContainer<K>, _ key: K) throws {
    try container.encode(Base64URL.encode(data), forKey: key)
}

/// Las tres claves de largo plazo de la Mac.
public struct MacKeys: Codable, Sendable {
    /// Ed25519: se autentica ante el relay.
    public var relay: Curve25519.Signing.PrivateKey
    /// X25519: estática de Noise.
    public var noise: Curve25519.KeyAgreement.PrivateKey
    /// X25519: remitente HPKE de pushes y buzón.
    public var seal: Curve25519.KeyAgreement.PrivateKey

    public init(relay: Curve25519.Signing.PrivateKey = .init(), noise: Curve25519.KeyAgreement.PrivateKey = .init(),
                seal: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.relay = relay
        self.noise = noise
        self.seal = seal
    }

    private enum CodingKeys: String, CodingKey { case relay, noise, seal }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func raw(_ key: CodingKeys) throws -> Data { try Base64URL.decode(try c.decode(String.self, forKey: key)) }
        relay = try .init(rawRepresentation: raw(.relay))
        noise = try .init(rawRepresentation: raw(.noise))
        seal = try .init(rawRepresentation: raw(.seal))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodeKey(relay.rawRepresentation, &c, CodingKeys.relay)
        try encodeKey(noise.rawRepresentation, &c, CodingKeys.noise)
        try encodeKey(seal.rawRepresentation, &c, CodingKeys.seal)
    }
}

/// Las tres claves de largo plazo del teléfono (la de presencia es una passkey del sistema y no está acá).
public struct DeviceKeys: Codable, Sendable {
    public var relay: Curve25519.Signing.PrivateKey
    public var noise: Curve25519.KeyAgreement.PrivateKey
    /// Destinatario HPKE de los pushes cifrados.
    public var push: Curve25519.KeyAgreement.PrivateKey

    public init(relay: Curve25519.Signing.PrivateKey = .init(), noise: Curve25519.KeyAgreement.PrivateKey = .init(),
                push: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.relay = relay
        self.noise = noise
        self.push = push
    }

    private enum CodingKeys: String, CodingKey { case relay, noise, push }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func raw(_ key: CodingKeys) throws -> Data { try Base64URL.decode(try c.decode(String.self, forKey: key)) }
        relay = try .init(rawRepresentation: raw(.relay))
        noise = try .init(rawRepresentation: raw(.noise))
        push = try .init(rawRepresentation: raw(.push))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodeKey(relay.rawRepresentation, &c, CodingKeys.relay)
        try encodeKey(noise.rawRepresentation, &c, CodingKeys.noise)
        try encodeKey(push.rawRepresentation, &c, CodingKeys.push)
    }
}

/// Lo que el teléfono sabe de su Mac.
public struct PairedMac: Codable, Equatable, Sendable {
    public var accountId: String
    public var deviceId: String
    public var relayHost: String
    public var macName: String
    /// `macStatic.pub` (X25519).
    public var macStatic: Data
    /// `macSealKey.pub` (X25519).
    public var macSeal: Data

    public init(accountId: String, deviceId: String, relayHost: String, macName: String, macStatic: Data, macSeal: Data) {
        self.accountId = accountId
        self.deviceId = deviceId
        self.relayHost = relayHost
        self.macName = macName
        self.macStatic = macStatic
        self.macSeal = macSeal
    }

    private enum CodingKeys: String, CodingKey { case accountId, deviceId, relayHost, macName, macStatic, macSeal }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(String.self, forKey: .accountId)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        relayHost = try c.decode(String.self, forKey: .relayHost)
        macName = try c.decode(String.self, forKey: .macName)
        macStatic = try Base64URL.decode(try c.decode(String.self, forKey: .macStatic))
        macSeal = try Base64URL.decode(try c.decode(String.self, forKey: .macSeal))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(relayHost, forKey: .relayHost)
        try c.encode(macName, forKey: .macName)
        try encodeKey(macStatic, &c, CodingKeys.macStatic)
        try encodeKey(macSeal, &c, CodingKeys.macSeal)
    }
}

/// Lo que la Mac sabe de un teléfono: solo claves públicas.
public struct PairedDevice: Codable, Equatable, Sendable {
    public var deviceId: String
    public var name: String
    public var model: String
    /// `deviceStatic.pub` (X25519).
    public var noise: Data
    /// `devicePushKey.pub` (X25519).
    public var push: Data
    /// La passkey del teléfono (W.4.5). `nil`: se emparejó sin passkey y los comandos gated quedan bloqueados.
    public var presence: PresenceCredential?
    public var pairedAt: Date
    /// Merge, push, tests y lo que publica en GitHub (reviews, respuestas) piden Face ID (por defecto sí, spec P.8).
    public var requirePresence: Bool

    public init(deviceId: String, name: String, model: String, noise: Data, push: Data, presence: PresenceCredential?,
                pairedAt: Date,
                requirePresence: Bool = true) {
        self.deviceId = deviceId
        self.name = name
        self.model = model
        self.noise = noise
        self.push = push
        self.presence = presence
        self.pairedAt = pairedAt
        self.requirePresence = requirePresence
    }

    private enum CodingKeys: String, CodingKey { case deviceId, name, model, noise, push, presence, pairedAt, requirePresence }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        name = try c.decode(String.self, forKey: .name)
        model = try c.decode(String.self, forKey: .model)
        noise = try Base64URL.decode(try c.decode(String.self, forKey: .noise))
        push = try Base64URL.decode(try c.decode(String.self, forKey: .push))
        // Un `devices.json` de la app nativa tenía acá un texto (x963): no decodifica y el archivo se descarta.
        presence = try c.decodeIfPresent(PresenceCredential.self, forKey: .presence)
        pairedAt = try c.decode(Date.self, forKey: .pairedAt)
        requirePresence = try c.decodeIfPresent(Bool.self, forKey: .requirePresence) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(name, forKey: .name)
        try c.encode(model, forKey: .model)
        try encodeKey(noise, &c, CodingKeys.noise)
        try encodeKey(push, &c, CodingKeys.push)
        try c.encodeIfPresent(presence, forKey: .presence)
        try c.encode(pairedAt, forKey: .pairedAt)
        try c.encode(requirePresence, forKey: .requirePresence)
    }
}

/// Lo que sale del secreto del QR (spec P.11). El relay solo ve `authKey`; `psk` nunca sale de los dos extremos.
public struct PairingSecrets: Sendable {
    public let authKey: Data
    public let psk: Data

    public init(secret ps: Data) {
        func derive(_ info: String) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ps), info: Data(info.utf8), outputByteCount: 32)
                .withUnsafeBytes { Data($0) }
        }
        authKey = derive("PRBar relay pairing v1")
        psk = derive("PRBar noise psk v1")
    }

    /// `proof` = HMAC-SHA256(`pairAuthKey`, `nonce`).
    public static func proof(authKey: Data, nonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: authKey)))
    }
}

/// Los prólogos de Noise (spec P.5 y P.11): atan el handshake a la cuenta y al dispositivo o a la ranura.
public enum RemotePrologue {
    public static func session(account: String, device: String) -> Data {
        Data("PRBar Remote v1".utf8) + Data(account.utf8) + Data([0]) + Data(device.utf8)
    }

    public static func pairing(account: String, pairing: String) -> Data {
        Data("PRBar Pair v1".utf8) + Data(account.utf8) + Data([0]) + Data(pairing.utf8)
    }
}
