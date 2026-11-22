import Foundation
import PRBarRemoteKit

enum SASTests {
    static let cases: [TestCase] = [
        TestCase("sas: vectores fijos verificados con openssl") {
            // `openssl kdf -keylen 4 -kdfopt digest:SHA256 -kdfopt hexkey:<hash> -kdfopt info:"PRBar SAS v1" HKDF`
            // (sal vacía) → 0xEF3CE55E y 0xC80EFDA9; % 1 000 000 → 745502 y 425641.
            try expectEqual(SAS.code(handshakeHash: Data(repeating: 0, count: 32)), "745502")
            try expectEqual(SAS.code(handshakeHash: Data(0..<32)), "425641")
            try expectEqual(SAS.display("745502"), "745 502")
        },
        TestCase("sas: siempre 6 dígitos") {
            for _ in 0..<200 {
                let code = SAS.code(handshakeHash: randomBytes(32))
                try expect(code.count == 6 && code.allSatisfy(\.isNumber), code)
            }
            try expectEqual(SAS.display("000042"), "000 042")
        },
    ]
}
