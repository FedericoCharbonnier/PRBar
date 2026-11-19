import Foundation
import PRBarCore

private struct Sample: Codable, Equatable {
    let name: String
    let count: Int
    let when: Date
}

enum CommandProtocolTests {
    static let cases: [TestCase] = [
        TestCase("protocolo: JSONValue distingue bool, int, double, null, array y object") {
            let line = #"{"a":1,"b":[true,null,"x",1.5],"c":{"d":false}}"#
            let value = try CommandProtocol.decode(JSONValue.self, line: line)
            try expectEqual(value, .object([
                "a": .int(1), "b": .array([.bool(true), .null, .string("x"), .double(1.5)]), "c": .object(["d": .bool(false)]),
            ]))
            try expectEqual(try CommandProtocol.line(value), line)
        },
        TestCase("protocolo: JSONValue ida y vuelta de un Codable (fechas ISO 8601)") {
            let sample = Sample(name: "x", count: 3, when: t0)
            let value = try JSONValue(encoding: sample)
            try expectEqual(value, .object(["name": .string("x"), "count": .int(3), "when": .string("2027-01-15T08:00:00Z")]))
            try expectEqual(try value.decode(Sample.self), sample)
        },
        TestCase("protocolo: líneas estables de respuesta, error, evento y hello") {
            try expectEqual(try CommandProtocol.line(CommandResponse.success(id: 1, .object(["ok": .bool(true)]))),
                            #"{"id":1,"ok":true,"result":{"ok":true}}"#)
            try expectEqual(try CommandProtocol.line(CommandResponse.failure(id: 2, CommandFailure(.notFound, "No PR"))),
                            #"{"error":{"code":"notFound","message":"No PR"},"id":2,"ok":false}"#)
            try expectEqual(try CommandProtocol.line(CommandResponse.event(id: 3, .progress(message: "Reviewing…"))),
                            #"{"event":{"progress":{"message":"Reviewing…"}},"id":3}"#)
            try expectEqual(try CommandProtocol.line(HelloMessage(hello: Hello(protocolVersion: 1, version: "1.0.0"))),
                            #"{"hello":{"protocolVersion":1,"version":"1.0.0"}}"#)
        },
        TestCase("protocolo: la línea nunca tiene saltos (el texto con \\n va escapado)") {
            let line = try CommandProtocol.line(CommandResponse.event(id: 1, .text(delta: "a\nb")))
            try expect(!line.contains("\n"), line)
        },
        TestCase("protocolo: mensaje de versiones incompatibles") {
            try expectEqual(CommandFailure.protocolMismatch(cli: "1.3.0", app: "1.2.0").message,
                            "prbar 1.3.0 can't talk to PRBar 1.2.0 — run `prbar update` or reinstall")
        },
    ]
}
