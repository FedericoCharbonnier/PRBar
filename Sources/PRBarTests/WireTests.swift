import Foundation
import PRBarRemoteKit

enum WireTests {
    static let cases: [TestCase] = [
        TestCase("wire: base64url sin relleno ida y vuelta") {
            for n in 0..<70 {
                let data = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 37) })
                let text = Base64URL.encode(data)
                try expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
                try expectEqual(try Base64URL.decode(text), data)
            }
            try expect((try? Base64URL.decode("a")) == nil)       // largo imposible
            try expect((try? Base64URL.decode("ab+c")) == nil)    // alfabeto estándar rechazado
            try expect((try? Base64URL.decode("ab/c")) == nil)
            try expect((try? Base64URL.decode("abc=")) == nil)    // con relleno
            try expect((try? Base64URL.decode("ab c")) == nil)    // espacios
        },
        TestCase("wire: base64url rechaza bits sobrantes no canónicos") {
            // "AB" decodifica a 1 byte (0x00) solo si los 4 bits sobrantes son cero: "AA" sí, "AB" no.
            try expectEqual(try Base64URL.decode("AA"), Data([0]))
            try expect((try? Base64URL.decode("AB")) == nil)
        },
        TestCase("wire: bytes big endian y comparación en tiempo constante") {
            try expectEqual(Data(uint64BE: 0x0102_0304_0506_0708), Data([1, 2, 3, 4, 5, 6, 7, 8]))
            try expectEqual(Data(uint16BE: 0xABCD), Data([0xAB, 0xCD]))
            try expectEqual(Data(int64BE: -2), Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE]))
            try expect(constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
            try expect(!constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
            try expect(!constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
            try expectEqual(randomBytes(32).count, 32)
            try expect(randomBytes(32) != randomBytes(32))
        },
        TestCase("wire: PRBarWire y PRBarRemoteKit no usan APIs solo de macOS") {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let forbidden = ["import AppKit", "import IOKit", "import Darwin", "Process(", "NSWorkspace", "getpeereid"]
            for target in ["PRBarWire", "PRBarRemoteKit"] {
                let dir = root.appendingPathComponent(target)
                let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
                try expect(!files.isEmpty, "\(target) sin archivos")
                for file in files {
                    let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                    for word in forbidden where text.contains(word) {
                        throw TestFailure(description: "\(target)/\(file) usa \(word): tiene que compilar para iOS")
                    }
                }
            }
        },
    ]
}
