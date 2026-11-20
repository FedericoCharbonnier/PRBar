import Foundation

public enum Base64URLError: Error, Equatable {
    case invalid
}

/// base64url sin relleno (RFC 4648 §5). Estricto: rechaza `=`, `+`, `/`, espacios, largos imposibles y bits sobrantes
/// distintos de cero, así cada valor tiene una sola escritura (importa para ids y claves que se comparan como texto).
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) throws -> Data {
        let bytes = Array(text.utf8)
        guard bytes.count % 4 != 1 else { throw Base64URLError.invalid }
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                continue
            default:
                throw Base64URLError.invalid
            }
        }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - bytes.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), encode(data) == text else { throw Base64URLError.invalid }
        return data
    }
}
