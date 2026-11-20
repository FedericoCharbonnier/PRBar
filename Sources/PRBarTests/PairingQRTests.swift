import Foundation
import PRBarRemoteKit

enum PairingQRTests {
    static func sample(name: String = "Federico’s MacBook Pro & co 🚀", host: String = "prbar.example.org") -> PairingQR {
        PairingQR(relayHost: host, accountId: "abcdefghijklmnopqrstuvwxyz", pairingId: "abcdefghij234567",
                  secret: Data(repeating: 7, count: 32), macStatic: Data(repeating: 9, count: 32), macName: name)
    }

    static func rejects(_ text: String, allowInsecure: Bool = false) throws {
        try expect((try? PairingQR(url: text, allowInsecure: allowInsecure)) == nil, "aceptó \(text)")
    }

    static let cases: [TestCase] = [
        TestCase("pairing qr: ida y vuelta con nombre raro") {
            let qr = sample()
            let text = qr.url
            try expect(text.hasPrefix("prbar://pair?v=1&"))
            try expect(!text.contains(" ") && !text.contains("🚀"))
            try expectEqual(try PairingQR(url: text), qr)
            try expectEqual(try PairingQR(url: sample(name: "a=b&c=d+e%20").url).macName, "a=b&c=d+e%20")
        },
        TestCase("pairing qr: rechaza lo que no es un QR de PRBar") {
            let good = sample().url
            try rejects(good.replacingOccurrences(of: "v=1", with: "v=2"))
            try rejects(good.replacingOccurrences(of: "prbar://pair?", with: "https://pair?"))
            try rejects(good.replacingOccurrences(of: "prbar://pair?", with: "prbar://other?"))
            try rejects(good.replacingOccurrences(of: "prbar://pair?", with: "prbar://pair/x?"))
            try rejects(good + "&v=1")                                                   // repetido
            try rejects(good.replacingOccurrences(of: Base64URL.encode(Data(repeating: 7, count: 32)),
                                                  with: Base64URL.encode(Data(repeating: 7, count: 31))))
            try rejects(good.replacingOccurrences(of: Base64URL.encode(Data(repeating: 9, count: 32)),
                                                  with: Base64URL.encode(Data(repeating: 9, count: 33))))
            try rejects(sample(host: "wss://prbar.example.org").url)
            try rejects(sample(host: "prbar.example.org/x").url)
            try rejects(sample(host: "prbar.example.org:99999").url, allowInsecure: true)
            try rejects(sample(host: "prbar.example.org:+443").url)
            try rejects(sample(host: "user@prbar.example.org").url)
            try rejects(sample(host: "127.0.0.1:18080").url)                             // IP literal solo en tests
            // Un entrypoint dedicado de Traefik (spec V.2) usa otro puerto.
            try expectEqual(try PairingQR(url: sample(host: "prbar.example.org:8443").url).relayHost, "prbar.example.org:8443")
            try rejects(sample(host: "").url)
            try rejects(sample(name: String(repeating: "x", count: 600)).url)            // > 512 caracteres
            try rejects(good.replacingOccurrences(of: "a=abcdefghijklmnopqrstuvwxyz", with: "a=ABC"))
            for key in ["r", "a", "p", "k", "m"] {
                let without = good.split(separator: "&").filter { !$0.hasPrefix("\(key)=") }.joined(separator: "&")
                try rejects(without)
            }
            let local = sample(host: "127.0.0.1:18080").url
            try expectEqual(try PairingQR(url: local, allowInsecure: true).relayHost, "127.0.0.1:18080")
        },
        TestCase("pairing qr: ids al azar en base32 minúscula") {
            let account = RemoteIDs.newAccountId(), pairing = RemoteIDs.newPairingId()
            try expectEqual(account.count, 26)
            try expectEqual(pairing.count, 16)
            try expect((account + pairing).allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
            try expect(RemoteIDs.newAccountId() != account)
            try expectEqual(Base32.encode(Data("foobar".utf8)), "mzxw6ytboi")
        },
    ]
}
