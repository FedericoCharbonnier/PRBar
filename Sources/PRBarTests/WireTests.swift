import Foundation
import PRBarCore
import PRBarRemoteKit

enum WireTests {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    static let bytes = Data([1, 2, 3, 250, 251, 252])

    /// Contrato con el relay en Go: los mismos literales están en `relay/internal/hub/testdata/frames.json`.
    static let relayFrames: [(RelayMessage, String)] = [
        (.challenge(nonce: Data(repeating: 7, count: 32), time: 1_800_000_000),
         #"{"nonce":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc","t":"challenge","time":1800000000}"#),
        (.auth(acct: "acct", client: "mac", sig: bytes, pairing: nil, proof: nil),
         #"{"acct":"acct","client":"mac","sig":"AQID-vv8","t":"auth"}"#),
        (.auth(acct: "acct", client: "pair", sig: nil, pairing: "pid", proof: bytes),
         #"{"acct":"acct","client":"pair","pairing":"pid","proof":"AQID-vv8","t":"auth"}"#),
        (.ready(mac: "online", since: 1_800_000_000), #"{"mac":"online","since":1800000000,"t":"ready"}"#),
        (.send(to: "mac", sid: "0011223344556677", b: bytes), #"{"b":"AQID-vv8","sid":"0011223344556677","t":"send","to":"mac"}"#),
        (.recv(from: "dev1", sid: "0011223344556677", b: bytes),
         #"{"b":"AQID-vv8","from":"dev1","sid":"0011223344556677","t":"recv"}"#),
        (.undeliverable(to: "mac", sid: "0011223344556677"), #"{"sid":"0011223344556677","t":"undeliverable","to":"mac"}"#),
        (.presence(mac: "offline", since: 1_800_000_000, device: nil, state: nil),
         #"{"mac":"offline","since":1800000000,"t":"presence"}"#),
        (.presence(mac: nil, since: nil, device: "dev1", state: "online"), #"{"device":"dev1","state":"online","t":"presence"}"#),
        (.push(id: "p1", to: "dev1", collapse: String(repeating: "a", count: 64), thread: String(repeating: "b", count: 32),
               b: bytes),
         #"{"b":"AQID-vv8","collapse":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","id":"p1","t":"push","thread":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","to":"dev1"}"#),
        (.pushResult(id: "p1", status: 410, reason: "Unregistered"), #"{"id":"p1","reason":"Unregistered","status":410,"t":"pushResult"}"#),
        (.pushResult(id: "p1", status: 200, reason: nil), #"{"id":"p1","status":200,"t":"pushResult"}"#),
        (.mboxPut(to: "dev1", slot: "home", b: bytes), #"{"b":"AQID-vv8","slot":"home","t":"mbox.put","to":"dev1"}"#),
        (.mboxGet, #"{"t":"mbox.get"}"#),
        (.mbox(items: [RelayMailboxItem(slot: "home", b: bytes, at: 1_800_000_000)]),
         #"{"items":[{"at":1800000000,"b":"AQID-vv8","slot":"home"}],"t":"mbox"}"#),
        (.apns(token: "abcd", env: "sandbox"), #"{"env":"sandbox","t":"apns","token":"abcd"}"#),
        (.pairOpen(pairing: "pid", authKey: Data(repeating: 7, count: 32), expires: 1_800_000_300),
         #"{"authKey":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc","expires":1800000300,"pairing":"pid","t":"pair.open"}"#),
        (.pairClose(pairing: "pid"), #"{"pairing":"pid","t":"pair.close"}"#),
        (.deviceAdd(device: "dev1", relayKey: Data(repeating: 7, count: 32)),
         #"{"device":"dev1","relayKey":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc","t":"device.add"}"#),
        (.deviceRemove(device: "dev1"), #"{"device":"dev1","t":"device.remove"}"#),
        (.devices(items: nil), #"{"t":"devices"}"#),
        (.devices(items: [RelayDeviceEntry(id: "dev1", lastSeen: 1_800_000_000)]),
         #"{"items":[{"id":"dev1","lastSeen":1800000000}],"t":"devices"}"#),
        (.error(reason: "forbidden"), #"{"reason":"forbidden","t":"error"}"#),
        (.ping, #"{"t":"ping"}"#),
        (.pong, #"{"t":"pong"}"#),
    ]

    static func remoteFrames() throws -> [(RemoteFrame, String)] {
        let cmd = Data(#"{"status":{}}"#.utf8)
        return [
            (.hello(RemoteHello(remoteProtocol: 1, commandProtocol: 5, appVersion: "1.2.0", deviceName: "iPhone")),
             #"{"appVersion":"1.2.0","commandProtocol":5,"deviceName":"iPhone","remoteProtocol":1,"t":"hello"}"#),
            (.hello(RemoteHello(remoteProtocol: 1, commandProtocol: 5, appVersion: "1.2.0", macName: "Mac", incompatible: .updateIPhone)),
             #"{"appVersion":"1.2.0","commandProtocol":5,"incompatible":"updateIPhone","macName":"Mac","remoteProtocol":1,"t":"hello"}"#),
            (.req(RemoteRequest(id: 3, sentAt: date, cmd: cmd)),
             #"{"cmd":"eyJzdGF0dXMiOnt9fQ==","id":3,"sentAt":"2027-01-15T08:00:00Z","t":"req"}"#),
            (.req(RemoteRequest(id: 4, sentAt: date, cmd: cmd,
                                presence: PresenceProof(tsMillis: 1_800_000_000_123, credentialId: Data([9, 9]),
                                                        authenticatorData: bytes, clientDataJSON: Data("{}".utf8),
                                                        signature: Data([1, 2, 3])))),
             #"{"cmd":"eyJzdGF0dXMiOnt9fQ==","id":4,"presence":{"authenticatorData":"AQID-vv8","clientDataJSON":"e30","credentialId":"CQk","signature":"AQID","ts":1800000000123,"v":2},"sentAt":"2027-01-15T08:00:00Z","t":"req"}"#),
            (.res(CommandResponse.success(id: 3, .ok)), #"{"id":3,"ok":true,"result":{"ok":true},"t":"res"}"#),
            (.res(CommandResponse.event(id: 3, .progress(message: "Reviewing…"))),
             #"{"event":{"progress":{"message":"Reviewing…"}},"id":3,"t":"res"}"#),
            (.sub(topics: ["home", "pr:a/b#1"]), #"{"t":"sub","topics":["home","pr:a/b#1"]}"#),
            (.state(RemoteStateUpdate(topic: "home", rev: 2, data: .object(["x": .int(1)]))),
             #"{"data":{"x":1},"rev":2,"t":"state","topic":"home"}"#),
            (.chatDelta(pr: "a/b#1", text: "hi"), #"{"pr":"a/b#1","t":"chatDelta","text":"hi"}"#),
            (.unpair, #"{"t":"unpair"}"#),
            (.presencePolicy(requirePresence: true, gated: [.merge, .respondPush]),
             #"{"gated":["merge","respondPush"],"requirePresence":true,"t":"presencePolicy"}"#),
            (.bye(reason: "revoked"), #"{"reason":"revoked","t":"bye"}"#),
            (.bye(reason: nil), #"{"t":"bye"}"#),
        ]
    }

    static let cases: [TestCase] = [
        TestCase("wire: marcos del relay con JSON estable") {
            for (message, literal) in relayFrames {
                try expectEqual(try message.text(), literal)
                try expectEqual(try RelayMessage.decode(literal), message)
            }
            try expectEqual(try RelayMessage.decode(#"{"t":"future","x":1}"#), .unknown("future"))
            try expect((try? RelayMessage.decode(#"{"t":"send","to":"mac","sid":"1","b":"AQID+vv8"}"#)) == nil)
        },
        TestCase("wire: marcos de aplicación con JSON estable") {
            for (frame, literal) in try remoteFrames() {
                try expectEqual(String(decoding: try frame.encoded(), as: UTF8.self), literal)
                try expectEqual(try RemoteFrame.decode(Data(literal.utf8)), frame)
            }
            try expectEqual(try RemoteFrame.decode(Data(#"{"t":"future"}"#.utf8)), .unknown("future"))
            try expectEqual(try RemoteFrame.decode(Data(#"{"t":"presencePolicy","requirePresence":false,"gated":["merge","teleport"]}"#.utf8)),
                            .presencePolicy(requirePresence: false, gated: [.merge]))
            let request = try RemoteRequest(id: 1, sentAt: date, command: .merge(pr: "a/b#1", method: nil,
                                                                                    confirmed: true, expectedHeadOid: "abc"))
            try expectEqual(try request.command(), .merge(pr: "a/b#1", method: nil, confirmed: true,
                                                          expectedHeadOid: "abc"))
        },
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
