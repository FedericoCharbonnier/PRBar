import CryptoKit
import Foundation
import PRBarWire

// Pushes y buzón cifrados de la Mac al teléfono (spec P.9 y Q.1): HPKE modo auth (RFC 9180) con
// DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20Poly1305. Remitente `macSealKey`, destinatario `devicePushKey`.

public enum SealedError: Error, Equatable, Sendable {
    /// Sobre corto, relleno roto o JSON que no decodifica.
    case malformed
    /// No entra en el tope (push) aunque se corte el texto.
    case tooLarge
    /// Un blob del buzón más viejo que el último visto: el relay intentó volver atrás el estado.
    case rollback
    /// El blob dice ser de otra ranura que la del `info`.
    case wrongSlot
}

public enum SealedInfo {
    public static func push(account: String, device: String) -> Data { Data("PRBar push v1|\(account)|\(device)".utf8) }
    public static func mailbox(account: String, device: String, slot: String) -> Data {
        Data("PRBar mailbox v1|\(account)|\(device)|\(slot)".utf8)
    }
}

/// `len (u32 BE) ‖ datos ‖ ceros` hasta un múltiplo de `block`: el tamaño cifrado solo deja ver el bloque.
public enum Padding {
    public static func pad(_ data: Data, to block: Int) -> Data {
        var out = Data(uint32BE: UInt32(data.count)) + data
        let remainder = out.count % block
        if remainder != 0 { out.append(Data(count: block - remainder)) }
        return out
    }

    public static func unpad(_ data: Data) throws -> Data {
        guard data.count >= 4 else { throw SealedError.malformed }
        let length = Int(data.readBE(at: 0, count: 4))
        guard length <= data.count - 4 else { throw SealedError.malformed }
        let body = data.dropFirst(4)
        guard body.dropFirst(length).allSatisfy({ $0 == 0 }) else { throw SealedError.malformed }
        return Data(body.prefix(length))
    }
}

/// Sobre HPKE modo auth: `enc (32) ‖ ciphertext`. El remitente queda autenticado por su clave estática.
public enum SealedEnvelope {
    public static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static let encLength = 32
    static let tagLength = 16
    public static let paddingBlock = 256

    public static func seal(_ plaintext: Data, from sender: Curve25519.KeyAgreement.PrivateKey,
                            to recipient: Curve25519.KeyAgreement.PublicKey, info: Data) throws -> Data {
        var s = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info, authenticatedBy: sender)
        let ciphertext = try s.seal(Padding.pad(plaintext, to: paddingBlock))
        return s.encapsulatedKey + ciphertext
    }

    public static func open(_ envelope: Data, by recipient: Curve25519.KeyAgreement.PrivateKey,
                            from sender: Curve25519.KeyAgreement.PublicKey, info: Data) throws -> Data {
        guard envelope.count >= encLength + tagLength + 4 else { throw SealedError.malformed }
        var r = try HPKE.Recipient(privateKey: recipient, ciphersuite: suite, info: info,
                                   encapsulatedKey: envelope.prefix(encLength), authenticatedBy: sender)
        return try Padding.unpad(r.open(envelope.dropFirst(encLength)))
    }

    /// Largo del sobre para un texto plano de `count` bytes.
    static func envelopeLength(plaintextCount count: Int) -> Int {
        encLength + Padding.pad(Data(count: count), to: paddingBlock).count + tagLength
    }
}

/// El contenido de una notificación (spec P.9). Lo único que viaja en claro es el texto genérico que arma el relay.
public struct PushPayload: Codable, Equatable, Sendable {
    public var v: Int
    public var id: UUID
    public var createdAt: Date
    public var kind: String
    public var title: String
    public var body: String
    public var threadId: String
    public var pr: String?
    public var deepLink: String
    public var badge: Int?

    public init(id: UUID = UUID(), createdAt: Date, kind: String, title: String, body: String, threadId: String,
                pr: String? = nil, deepLink: String, badge: Int? = nil) {
        v = 1
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.title = title
        self.body = body
        self.threadId = threadId
        self.pr = pr
        self.deepLink = deepLink
        self.badge = badge
    }

    /// Tope del campo `e` del payload de APNs (base64): deja lugar al resto bajo los 4 KiB de Apple.
    public static let maxEnvelopeBase64 = 3_072

    /// El sobre en base64 estándar para el campo `e`. Si no entra, corta `body` (y si hace falta `title`) con "…".
    public func sealedForAPNs(from sender: Curve25519.KeyAgreement.PrivateKey,
                              to recipient: Curve25519.KeyAgreement.PublicKey, info: Data) throws -> String {
        let fitting = try fitted()
        let envelope = try SealedEnvelope.seal(try CommandProtocol.encoder.encode(fitting), from: sender, to: recipient,
                                               info: info)
        let text = envelope.base64EncodedString()
        guard text.count <= Self.maxEnvelopeBase64 else { throw SealedError.tooLarge }
        return text
    }

    public static func open(apnsField text: String, by recipient: Curve25519.KeyAgreement.PrivateKey,
                            from sender: Curve25519.KeyAgreement.PublicKey, info: Data) throws -> PushPayload {
        guard text.count <= maxEnvelopeBase64, let envelope = Data(base64Encoded: text) else { throw SealedError.malformed }
        let plaintext = try SealedEnvelope.open(envelope, by: recipient, from: sender, info: info)
        do {
            return try CommandProtocol.decoder.decode(PushPayload.self, from: plaintext)
        } catch {
            throw SealedError.malformed
        }
    }

    private func fits() throws -> Bool {
        let count = try CommandProtocol.encoder.encode(self).count
        let base64 = (SealedEnvelope.envelopeLength(plaintextCount: count) + 2) / 3 * 4
        return base64 <= Self.maxEnvelopeBase64
    }

    /// Una copia que entra: corta `body` y después `title` lo justo (búsqueda binaria sobre los caracteres).
    func fitted() throws -> PushPayload {
        if try fits() { return self }
        func cut(_ keyPath: WritableKeyPath<PushPayload, String>, in payload: PushPayload) throws -> PushPayload? {
            let full = Array(payload[keyPath: keyPath])
            func candidate(_ n: Int) -> PushPayload {
                var copy = payload
                copy[keyPath: keyPath] = n == full.count ? String(full) : String(full.prefix(n)) + "…"
                return copy
            }
            var low = 0, high = full.count
            guard try candidate(0).fits() else { return nil }
            while low < high {
                let mid = (low + high + 1) / 2
                if try candidate(mid).fits() { low = mid } else { high = mid - 1 }
            }
            return candidate(low)
        }
        if let shorter = try cut(\.body, in: self) { return shorter }
        var empty = self
        empty.body = ""
        if let shorter = try cut(\.title, in: empty) { return shorter }
        throw SealedError.tooLarge
    }
}

/// Un estado guardado en el buzón del relay (spec Q.1): el último `home` cifrado, con `rev` para no volver atrás.
public struct MailboxBlob: Codable, Equatable, Sendable {
    public var slot: String
    public var rev: Int
    public var createdAt: Date
    public var data: Data

    public init(slot: String, rev: Int, createdAt: Date, data: Data) {
        self.slot = slot
        self.rev = rev
        self.createdAt = createdAt
        self.data = data
    }

    public func seal(from sender: Curve25519.KeyAgreement.PrivateKey, to recipient: Curve25519.KeyAgreement.PublicKey,
                     account: String, device: String) throws -> Data {
        try SealedEnvelope.seal(try CommandProtocol.encoder.encode(self), from: sender, to: recipient,
                                info: SealedInfo.mailbox(account: account, device: device, slot: slot))
    }

    /// Abre y valida: misma ranura que el `info` y `rev` ≥ `minimumRev` (el último visto).
    public static func open(_ envelope: Data, by recipient: Curve25519.KeyAgreement.PrivateKey,
                            from sender: Curve25519.KeyAgreement.PublicKey, account: String, device: String, slot: String,
                            minimumRev: Int) throws -> MailboxBlob {
        let plaintext = try SealedEnvelope.open(envelope, by: recipient, from: sender,
                                                info: SealedInfo.mailbox(account: account, device: device, slot: slot))
        let blob: MailboxBlob
        do {
            blob = try CommandProtocol.decoder.decode(MailboxBlob.self, from: plaintext)
        } catch {
            throw SealedError.malformed
        }
        guard blob.slot == slot else { throw SealedError.wrongSlot }
        guard blob.rev >= minimumRev else { throw SealedError.rollback }
        return blob
    }
}

/// `apns-collapse-id` y `thread-id` opacos (spec P.9): estables para el mismo par de claves, sin sentido para el relay
/// ni para Apple. `pushIdKey` = HKDF del secreto X25519 estático entre `macSealKey` y `devicePushKey`.
public struct PushIdentifiers: Sendable {
    private let key: SymmetricKey

    /// Lado Mac.
    public init(macSeal: Curve25519.KeyAgreement.PrivateKey, devicePush: Curve25519.KeyAgreement.PublicKey) throws {
        key = Self.derive(try macSeal.sharedSecretFromKeyAgreement(with: devicePush))
    }

    /// Lado teléfono (la extensión de notificaciones no lo necesita; la app sí para agrupar).
    public init(devicePush: Curve25519.KeyAgreement.PrivateKey, macSeal: Curve25519.KeyAgreement.PublicKey) throws {
        key = Self.derive(try devicePush.sharedSecretFromKeyAgreement(with: macSeal))
    }

    private static func derive(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("PRBar push ids v1".utf8),
                                       outputByteCount: 32)
    }

    private func mac(_ parts: [String]) -> Data {
        // Separador 0x00: "a"+"bc" y "ab"+"c" no dan lo mismo.
        Data(HMAC<SHA256>.authenticationCode(for: Data(parts.joined(separator: "\u{0}").utf8), using: key))
    }

    /// 64 caracteres hex (32 bytes).
    public func collapse(kind: String, pr: String) -> String { mac(["collapse", kind, pr]).hexString }

    /// 32 caracteres hex (16 bytes).
    public func thread(pr: String) -> String { mac(["thread", pr]).prefix(16).hexString }
}
