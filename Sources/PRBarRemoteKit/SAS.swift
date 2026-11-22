import CryptoKit
import Foundation

/// El código de 6 dígitos del emparejamiento (spec P.11): `HKDF-SHA256(ikm: handshakeHash, info: "PRBar SAS v1", 4)`
/// como `UInt32` big endian `% 1 000 000`. Los dos lados lo derivan del mismo hash de handshake de Noise IKpsk2: si un
/// tercero se metió en el medio, los hashes (y casi seguro los códigos) difieren.
public enum SAS {
    public static func code(handshakeHash: Data) -> String {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: handshakeHash),
                                         info: Data("PRBar SAS v1".utf8), outputByteCount: 4)
        let bytes = key.withUnsafeBytes { Data($0) }
        let value = UInt32(bytes.readBE(at: 0, count: 4)) % 1_000_000
        let digits = String(value)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// `"123 456"`.
    public static func display(_ code: String) -> String {
        "\(code.prefix(3)) \(code.dropFirst(3))"
    }
}
