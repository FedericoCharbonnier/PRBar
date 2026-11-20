import Foundation

extension Data {
    public init(uint64BE value: UInt64) {
        self.init(Swift.withUnsafeBytes(of: value.bigEndian) { Array($0) })
    }

    public init(uint16BE value: UInt16) {
        self.init(Swift.withUnsafeBytes(of: value.bigEndian) { Array($0) })
    }

    public init(int64BE value: Int64) {
        self.init(uint64BE: UInt64(bitPattern: value))
    }

    public init(uint32BE value: UInt32) {
        self.init(Swift.withUnsafeBytes(of: value.bigEndian) { Array($0) })
    }

    /// Lee un entero big endian de `count` bytes desde `offset` (relativo al inicio de los datos).
    func readBE(at offset: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<count { value = value << 8 | UInt64(self[startIndex + offset + i]) }
        return value
    }

    /// Hex en minúscula.
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }

    public init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
            default: nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }
}

/// Compara sin cortar en el primer byte distinto (el tiempo depende solo del largo, que no es secreto).
public func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}

/// Bytes de `SystemRandomNumberGenerator` (CSPRNG del sistema).
public func randomBytes(_ n: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}
