import Foundation
import PRBarWire

public enum PairingQRError: Error, Equatable, Sendable {
    case invalid(String)
}

/// `https://<host>/#pair?v=1&r=<host>&a=<accountId>&p=<pairingId>&k=<ps>&m=<macStatic>&n=<nombre>` (spec web W.4.4,
/// mismos campos que P.11). El fragmento `#` nunca llega al servidor: lo lee la web app instalada.
public struct PairingQR: Equatable, Sendable {
    public var relayHost: String
    public var accountId: String
    public var pairingId: String
    /// `ps`: 32 bytes de los que salen `pairAuthKey` y el psk de Noise. Es el secreto del QR.
    public var secret: Data
    /// `macStatic.pub` (X25519, 32 bytes).
    public var macStatic: Data
    public var macName: String

    public static let maxLength = 512
    static let maxNameLength = 64

    public init(relayHost: String, accountId: String, pairingId: String, secret: Data, macStatic: Data, macName: String) {
        self.relayHost = relayHost
        self.accountId = accountId
        self.pairingId = pairingId
        self.secret = secret
        self.macStatic = macStatic
        self.macName = macName
    }

    /// Solo letras, dígitos y `-._~` quedan sin codificar: `&`, `=`, `+`, espacios y emoji van con `%`.
    private static let unreserved = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    public var url: String {
        let items: [(String, String)] = [
            ("v", "1"), ("r", relayHost), ("a", accountId), ("p", pairingId), ("k", Base64URL.encode(secret)),
            ("m", Base64URL.encode(macStatic)), ("n", macName),
        ]
        return Self.prefix(host: relayHost) + items.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
    }

    /// `host` o `host:puerto` (un entrypoint dedicado de Traefik, spec V.2). `allowInsecure` además acepta una IP
    /// literal (el relay local de los tests de integración).
    static func prefix(host: String) -> String { "https://\(host)/#pair?" }

    /// El texto escaneado o pegado ("Paste code"); se ignoran espacios y saltos alrededor.
    public init(url input: String, allowInsecure: Bool = false) throws {
        func fail(_ why: String) -> PairingQRError { .invalid(why) }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= Self.maxLength else { throw fail("too long") }
        let marker = "/#pair?"
        guard text.hasPrefix("https://"), let range = text.range(of: marker) else { throw fail("not a pairing link") }
        let linkHost = String(text[text.index(text.startIndex, offsetBy: 8)..<range.lowerBound])
        var values: [String: String] = [:]
        for pair in text[range.upperBound...].split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let key = parts[0].removingPercentEncoding,
                  let value = parts[1].removingPercentEncoding else { throw fail("bad parameter") }
            guard values[key] == nil else { throw fail("repeated \(key)") }
            values[key] = value
        }
        guard values["v"] == "1" else { throw fail("unsupported version") }
        guard let host = values["r"], Self.isValidHost(host, allowIP: allowInsecure) else { throw fail("bad relay") }
        // La página que abre el link es la del relay del QR: un link a otro sitio con `r` de este no vale.
        guard linkHost == host else { throw fail("relay doesn't match the link") }
        guard let account = values["a"], Self.isBase32(account, length: 26) else { throw fail("bad account") }
        guard let pairing = values["p"], Self.isBase32(pairing, length: 16) else { throw fail("bad pairing id") }
        guard let k = values["k"], let secret = try? Base64URL.decode(k), secret.count == 32 else { throw fail("bad secret") }
        guard let m = values["m"], let mac = try? Base64URL.decode(m), mac.count == 32 else { throw fail("bad mac key") }
        let raw = values["n"] ?? ""
        guard raw.count <= Self.maxNameLength else { throw fail("bad name") }
        // Anyone can send a pairing link: the name shown on the confirmation screen is one plain line, without
        // bidi or invisible characters that could make it read as another Mac (review L5).
        let name = RemoteText.displayName(raw, limit: Self.maxNameLength)
        self.init(relayHost: host, accountId: account, pairingId: pairing, secret: secret, macStatic: mac,
                  macName: name.isEmpty ? "Mac" : name)
    }

    static func isBase32(_ text: String, length: Int) -> Bool {
        text.count == length && text.allSatisfy { Base32.alphabet.contains($0) }
    }

    /// Un nombre de host (letras, dígitos, `-`, `.`) con `:puerto` opcional, sin esquema, ruta ni usuario. Una IP
    /// literal (todo dígitos y puntos) solo si `allowIP`.
    public static func isValidHost(_ text: String, allowIP: Bool) -> Bool {
        var host = Substring(text)
        if let colon = text.lastIndex(of: ":") {
            let port = text[text.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(port),
                  (1...65_535).contains(number) else { return false }
            host = text[..<colon]
        }
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("."), !host.hasSuffix("."), !host.hasPrefix("-") else {
            return false
        }
        guard host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else { return false }
        return allowIP || host.contains(where: \.isLetter)
    }
}

/// Base32 (RFC 4648) en minúscula y sin relleno: ids de cuenta, dispositivo y emparejamiento (spec P.2).
public enum Base32 {
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    public static func encode(_ data: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int(buffer >> UInt32(bits - 5) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[Int(buffer << UInt32(5 - bits) & 31)]) }
        return out
    }
}

public enum RemoteIDs {
    /// 16 bytes → 26 caracteres.
    public static func newAccountId() -> String { Base32.encode(randomBytes(16)) }
    /// 16 bytes → 26 caracteres (lo elige la Mac al emparejar).
    public static func newDeviceId() -> String { Base32.encode(randomBytes(16)) }
    /// 10 bytes → 16 caracteres.
    public static func newPairingId() -> String { Base32.encode(randomBytes(10)) }
}
