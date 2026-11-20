import CryptoKit
import Foundation

// Noise Protocol Framework (rev. 34), solo lo que usa PRBar: `Noise_KK_25519_ChaChaPoly_SHA256` (sesiones) y
// `Noise_IKpsk2_25519_ChaChaPoly_SHA256` (emparejamiento). Spec P.5. Los nombres siguen los de la especificación de
// Noise (CipherState, SymmetricState, HandshakeState) para poder compararla línea por línea.

public enum NoiseError: Error, Equatable, Sendable {
    /// El contador llegó a 2⁶⁴−1: la sesión no se puede seguir usando.
    case nonceExhausted
    /// Un mensaje de Noise mide como máximo 65 535 bytes.
    case messageTooLarge
    /// No autenticó (byte cambiado, mensaje repetido o fuera de orden, otra clave). La sesión queda inutilizable.
    case decryptFailed
    /// Mensaje corto o con un formato imposible.
    case malformed
    /// Se llamó fuera de turno, después de un error o antes de terminar el handshake.
    case invalidState
    /// Falta (o sobra) una clave o el psk que el patrón necesita.
    case invalidConfiguration
}

/// Las claves del handshake; con 25519 todo mide 32 bytes.
enum Noise {
    static let dhLength = 32
    static let hashLength = 32
    static let tagLength = 16
    static let maxMessageLength = 65_535

    static func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey,
                   _ publicKey: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        // CryptoKit rechaza los puntos de orden bajo (secreto todo en cero).
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.withUnsafeBytes { Data($0) }
    }

    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func hmac(key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// HKDF de Noise (sección 4.3): `temp = HMAC(ck, ikm)`, `out1 = HMAC(temp, 0x01)`, `out2 = HMAC(temp, out1 ‖ 0x02)`,
    /// `out3 = HMAC(temp, out2 ‖ 0x03)`.
    static func hkdf(chainingKey: Data, inputKeyMaterial: Data, outputs: Int) -> [Data] {
        let temp = hmac(key: chainingKey, inputKeyMaterial)
        let out1 = hmac(key: temp, Data([0x01]))
        let out2 = hmac(key: temp, out1 + Data([0x02]))
        guard outputs == 3 else { return [out1, out2] }
        return [out1, out2, hmac(key: temp, out2 + Data([0x03]))]
    }
}

/// Clave + contador de 64 bits. Nonce de ChaChaPoly = 4 bytes en cero ‖ `n` en little endian (sección 5.1 y 12.3).
public struct CipherState: Sendable {
    private var key: SymmetricKey?
    /// El próximo nonce.
    public private(set) var n: UInt64 = 0
    /// Un descifrado falló: el estado queda inutilizable (spec P.5: la sesión se cierra y se hace otro handshake).
    public private(set) var isBroken = false

    init(key: Data? = nil) {
        self.key = key.map { SymmetricKey(data: $0) }
    }

    var hasKey: Bool { key != nil }

    private func nonce() throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    mutating func encrypt(ad: Data, plaintext: Data) throws -> Data {
        guard !isBroken else { throw NoiseError.invalidState }
        guard let key else { return plaintext }
        // 2⁶⁴−1 está reservado (sección 5.1): no se usa como nonce.
        guard n != UInt64.max else { throw NoiseError.nonceExhausted }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce(), authenticating: ad)
        n += 1
        return box.ciphertext + box.tag
    }

    mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
        guard !isBroken else { throw NoiseError.invalidState }
        guard let key else { return ciphertext }
        guard n != UInt64.max else { throw NoiseError.nonceExhausted }
        guard ciphertext.count >= Noise.tagLength else {
            isBroken = true
            throw NoiseError.decryptFailed
        }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: ciphertext.dropLast(Noise.tagLength),
                                               tag: ciphertext.suffix(Noise.tagLength))
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
            n += 1
            return plaintext
        } catch {
            // El contador no avanza (sección 5.1) y el estado no se vuelve a usar.
            isBroken = true
            throw NoiseError.decryptFailed
        }
    }

    /// Transporte: un mensaje de Noise entero (texto plano + 16 de tag ≤ 65 535 bytes), sin datos asociados.
    public mutating func encrypt(_ plaintext: Data) throws -> Data {
        guard plaintext.count + Noise.tagLength <= Noise.maxMessageLength else { throw NoiseError.messageTooLarge }
        guard hasKey else { throw NoiseError.invalidState }
        return try encrypt(ad: Data(), plaintext: plaintext)
    }

    public mutating func decrypt(_ ciphertext: Data) throws -> Data {
        guard ciphertext.count <= Noise.maxMessageLength else {
            isBroken = true
            throw NoiseError.messageTooLarge
        }
        guard hasKey else { throw NoiseError.invalidState }
        return try decrypt(ad: Data(), ciphertext: ciphertext)
    }
}

/// `ck`, `h` y el `CipherState` del handshake (sección 5.2).
struct SymmetricState {
    private(set) var ck: Data
    private(set) var h: Data
    private(set) var cipher = CipherState()

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        h = name.count <= Noise.hashLength ? name + Data(repeating: 0, count: Noise.hashLength - name.count) : Noise.hash(name)
        ck = h
    }

    mutating func mixKey(_ inputKeyMaterial: Data) {
        let out = Noise.hkdf(chainingKey: ck, inputKeyMaterial: inputKeyMaterial, outputs: 2)
        ck = out[0]
        cipher = CipherState(key: out[1])
    }

    mutating func mixHash(_ data: Data) {
        h = Noise.hash(h + data)
    }

    mutating func mixKeyAndHash(_ inputKeyMaterial: Data) {
        let out = Noise.hkdf(chainingKey: ck, inputKeyMaterial: inputKeyMaterial, outputs: 3)
        ck = out[0]
        mixHash(out[1])
        cipher = CipherState(key: out[2])
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(ad: h, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ad: h, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (CipherState, CipherState) {
        let out = Noise.hkdf(chainingKey: ck, inputKeyMaterial: Data(), outputs: 2)
        return (CipherState(key: out[0]), CipherState(key: out[1]))
    }
}

public enum NoisePattern: Sendable, Equatable {
    /// `-> s`, `<- s` / `-> e, es, ss` / `<- e, ee, se`.
    case kk
    /// `<- s` / `-> e, es, s, ss` / `<- e, ee, se, psk`.
    case ikpsk2

    enum Token { case e, s, ee, es, se, ss, psk }

    var protocolName: String {
        switch self {
        case .kk: "Noise_KK_25519_ChaChaPoly_SHA256"
        case .ikpsk2: "Noise_IKpsk2_25519_ChaChaPoly_SHA256"
        }
    }

    var messages: [[Token]] {
        switch self {
        case .kk: [[.e, .es, .ss], [.e, .ee, .se]]
        case .ikpsk2: [[.e, .es, .s, .ss], [.e, .ee, .se, .psk]]
        }
    }

    var usesPSK: Bool { self == .ikpsk2 }
}

/// Las dos direcciones del transporte, ya orientadas según el rol.
public struct NoiseTransport: Sendable {
    public var send: CipherState
    public var receive: CipherState
}

/// `HandshakeState` (sección 5.3) para KK e IKpsk2. Un error al leer deja el handshake inutilizable.
public struct NoiseHandshake {
    public let pattern: NoisePattern
    public let initiator: Bool
    private var symmetric: SymmetricState
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    private var localEphemeral: Curve25519.KeyAgreement.PrivateKey?
    private let fixedEphemeral: Curve25519.KeyAgreement.PrivateKey?
    public private(set) var remoteStaticKey: Curve25519.KeyAgreement.PublicKey?
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    private let psk: Data?
    private var messageIndex = 0
    private var failed = false

    public init(pattern: NoisePattern, initiator: Bool, prologue: Data, localStatic: Curve25519.KeyAgreement.PrivateKey,
                remoteStatic: Curve25519.KeyAgreement.PublicKey?, psk: Data?) throws {
        try self.init(pattern: pattern, initiator: initiator, prologue: prologue, localStatic: localStatic,
                      remoteStatic: remoteStatic, psk: psk, fixedEphemeral: nil)
    }

    /// `fixedEphemeral` es solo para los vectores de prueba: en producción la efímera sale siempre al azar.
    @_spi(Testing)
    public init(pattern: NoisePattern, initiator: Bool, prologue: Data, localStatic: Curve25519.KeyAgreement.PrivateKey,
                remoteStatic: Curve25519.KeyAgreement.PublicKey?, psk: Data?,
                fixedEphemeral: Curve25519.KeyAgreement.PrivateKey?) throws {
        switch pattern {
        case .kk:
            guard remoteStatic != nil, psk == nil else { throw NoiseError.invalidConfiguration }
        case .ikpsk2:
            // El iniciador conoce la estática del respondedor (pre-mensaje `<- s`); el respondedor la aprende.
            guard (remoteStatic != nil) == initiator, psk?.count == 32 else { throw NoiseError.invalidConfiguration }
        }
        self.pattern = pattern
        self.initiator = initiator
        self.localStatic = localStatic
        self.remoteStaticKey = remoteStatic
        self.psk = psk
        self.fixedEphemeral = fixedEphemeral
        symmetric = SymmetricState(protocolName: pattern.protocolName)
        symmetric.mixHash(prologue)
        // Pre-mensajes: primero los del iniciador, después los del respondedor.
        let initiatorStatic = initiator ? localStatic.publicKey : remoteStatic
        let responderStatic = initiator ? remoteStatic : localStatic.publicKey
        switch pattern {
        case .kk:
            symmetric.mixHash(initiatorStatic!.rawRepresentation)
            symmetric.mixHash(responderStatic!.rawRepresentation)
        case .ikpsk2:
            symmetric.mixHash(responderStatic!.rawRepresentation)
        }
    }

    public var isComplete: Bool { messageIndex == pattern.messages.count && !failed }

    /// `h` al terminar: identifica la sesión (SAS, atestación de presencia).
    public var handshakeHash: Data { symmetric.h }

    private var isMyTurn: Bool { (messageIndex % 2 == 0) == initiator }

    public mutating func writeMessage(payload: Data = Data()) throws -> Data {
        guard !failed, messageIndex < pattern.messages.count, isMyTurn else { throw NoiseError.invalidState }
        do {
            var out = Data()
            for token in pattern.messages[messageIndex] {
                switch token {
                case .e:
                    let e = fixedEphemeral ?? Curve25519.KeyAgreement.PrivateKey()
                    localEphemeral = e
                    out += e.publicKey.rawRepresentation
                    symmetric.mixHash(e.publicKey.rawRepresentation)
                    if pattern.usesPSK { symmetric.mixKey(e.publicKey.rawRepresentation) }
                case .s:
                    out += try symmetric.encryptAndHash(localStatic.publicKey.rawRepresentation)
                default:
                    try mixDH(token)
                }
            }
            out += try symmetric.encryptAndHash(payload)
            guard out.count <= Noise.maxMessageLength else { throw NoiseError.messageTooLarge }
            messageIndex += 1
            return out
        } catch {
            failed = true
            throw error
        }
    }

    public mutating func readMessage(_ message: Data) throws -> Data {
        guard !failed, messageIndex < pattern.messages.count, !isMyTurn else { throw NoiseError.invalidState }
        do {
            guard message.count <= Noise.maxMessageLength else { throw NoiseError.messageTooLarge }
            var rest = message[...]
            func take(_ count: Int) throws -> Data {
                guard rest.count >= count else { throw NoiseError.malformed }
                defer { rest = rest.dropFirst(count) }
                return Data(rest.prefix(count))
            }
            for token in pattern.messages[messageIndex] {
                switch token {
                case .e:
                    let raw = try take(Noise.dhLength)
                    remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
                    symmetric.mixHash(raw)
                    if pattern.usesPSK { symmetric.mixKey(raw) }
                case .s:
                    let length = Noise.dhLength + (symmetric.cipher.hasKey ? Noise.tagLength : 0)
                    let raw = try symmetric.decryptAndHash(try take(length))
                    remoteStaticKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
                default:
                    try mixDH(token)
                }
            }
            let payload = try symmetric.decryptAndHash(Data(rest))
            messageIndex += 1
            return payload
        } catch let error as NoiseError {
            failed = true
            throw error
        } catch {
            failed = true
            throw NoiseError.decryptFailed
        }
    }

    private mutating func mixDH(_ token: NoisePattern.Token) throws {
        func need<T>(_ value: T?) throws -> T {
            guard let value else { throw NoiseError.invalidState }
            return value
        }
        switch token {
        case .ee:
            symmetric.mixKey(try Noise.dh(need(localEphemeral), need(remoteEphemeral)))
        case .es:
            symmetric.mixKey(initiator ? try Noise.dh(need(localEphemeral), need(remoteStaticKey))
                                       : try Noise.dh(localStatic, need(remoteEphemeral)))
        case .se:
            symmetric.mixKey(initiator ? try Noise.dh(localStatic, need(remoteEphemeral))
                                       : try Noise.dh(need(localEphemeral), need(remoteStaticKey)))
        case .ss:
            symmetric.mixKey(try Noise.dh(localStatic, need(remoteStaticKey)))
        case .psk:
            symmetric.mixKeyAndHash(try need(psk))
        case .e, .s:
            throw NoiseError.invalidState
        }
    }

    /// Las claves de transporte (`Split()`), orientadas: el iniciador manda con la primera.
    public func split() throws -> NoiseTransport {
        guard isComplete else { throw NoiseError.invalidState }
        let (c1, c2) = symmetric.split()
        return initiator ? NoiseTransport(send: c1, receive: c2) : NoiseTransport(send: c2, receive: c1)
    }
}
