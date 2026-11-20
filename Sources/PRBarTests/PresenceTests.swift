import CryptoKit
import Foundation
import PRBarRemoteKit

enum PresenceTests {
    static let session = Data(repeating: 0xAB, count: 32)
    static let command = Data(#"{"merge":{"pr":"a/b#1"}}"#.utf8)
    static let now = Date(timeIntervalSince1970: 1_800_000_000.123)

    static func proof(_ signer: SoftwarePresenceSigner, session: Data = session, reqId: UInt64 = 5,
                      command: Data = command, at date: Date = now) async throws -> PresenceProof {
        try await PresenceProof.make(signer: signer, sessionHash: session, reqId: reqId, commandBytes: command, at: date)
    }

    static func verifies(_ proof: PresenceProof, key: Data, session: Data = session, reqId: UInt64 = 5,
                         command: Data = command, now date: Date = now) -> Bool {
        (try? PresenceVerifier.verify(proof, publicKey: key, sessionHash: session, reqId: reqId, commandBytes: command,
                                      now: date)) != nil
    }

    static let cases: [TestCase] = [
        TestCase("presence: bytes firmados exactos") {
            let bytes = PresenceMessage.bytes(sessionHash: Data(repeating: 1, count: 32), reqId: 0x0102,
                                              commandBytes: Data("x".utf8), ts: Date(timeIntervalSince1970: 1.5))
            try expectEqual(bytes.count, 16 + 32 + 8 + 32 + 8)
            var expected = Data("PRBarPresence v1".utf8) + Data(repeating: 1, count: 32)
            expected += Data([0, 0, 0, 0, 0, 0, 1, 2])
            expected += Data(SHA256.hash(data: Data("x".utf8)))
            expected += Data([0, 0, 0, 0, 0, 0, 0x05, 0xDC])   // 1500 ms
            try expectEqual(bytes, expected)
        },
        TestCase("presence: acepta la buena y rechaza sesión, id, comando, hora, clave o firma distintas") {
            let signer = SoftwarePresenceSigner()
            let key = signer.publicKey
            let good = try await proof(signer)
            try expect(verifies(good, key: key))
            try expect(!verifies(good, key: key, session: Data(repeating: 0xAC, count: 32)))
            try expect(!verifies(good, key: key, reqId: 6))
            var other = command
            other[other.startIndex + 3] ^= 1
            try expect(!verifies(good, key: key, command: other))
            try expect(verifies(good, key: key, now: now.addingTimeInterval(59)))
            try expect(!verifies(good, key: key, now: now.addingTimeInterval(61)))
            try expect(!verifies(good, key: key, now: now.addingTimeInterval(-61)))
            try expect(!verifies(good, key: SoftwarePresenceSigner().publicKey))
            var truncated = good
            truncated.sig = good.sig.dropLast()
            try expect(!verifies(truncated, key: key))
            try expect(!verifies(good, key: Data(repeating: 4, count: 65)))
        },
        TestCase("presence: ida y vuelta en JSON conserva los milisegundos") {
            let signer = SoftwarePresenceSigner()
            let good = try await proof(signer)
            let data = try JSONEncoder().encode(good)
            try expect(String(decoding: data, as: UTF8.self).contains("\"ts\":1800000000123"))
            let back = try JSONDecoder().decode(PresenceProof.self, from: data)
            try expect(verifies(back, key: signer.publicKey))
        },
        TestCase("presence: el mismo (sesión, id) dos veces es una repetición") {
            var guardian = PresenceReplayGuard()
            try guardian.check(sessionHash: session, reqId: 1, now: now)
            try guardian.check(sessionHash: session, reqId: 2, now: now)
            try guardian.check(sessionHash: Data(repeating: 1, count: 32), reqId: 1, now: now)
            do {
                try guardian.check(sessionHash: session, reqId: 1, now: now.addingTimeInterval(30))
                throw TestFailure(description: "aceptó una repetición")
            } catch let error as PresenceError {
                try expectEqual(error, .replayed)
            }
        },
    ]
}
