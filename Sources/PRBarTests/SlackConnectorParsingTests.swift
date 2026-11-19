import Foundation
import PRBarCore

private typealias F = SlackConnectorFixtures

private func send(_ text: String, isError: Bool = false) -> ConnectorWriteOutcome {
    ConnectorResultParser.parseSend(text, isError: isError, now: at(0))
}

private func react(_ text: String, isError: Bool = false) -> ConnectorWriteOutcome {
    ConnectorResultParser.parseReaction(text, isError: isError, now: at(0))
}

enum SlackConnectorParsingTests {
    static let cases: [TestCase] = [
        TestCase("connector parsing: send con ts/message_ts/permalink en JSON") {
            try expectEqual(send(F.sendJSONts), .done(ts: "1700000000.123456", channel: "D0123ABCD"))
            try expectEqual(send(F.sendJSONmessageTS), .done(ts: "1700000000.123456", channel: nil))
            try expectEqual(send(F.sendJSONpermalink), .done(ts: "1700000000.123456", channel: "D0123ABCD"))
            try expectEqual(send(F.sendNestedResultJSON), .done(ts: "1700000000.123456", channel: "C1"))
        },
        TestCase("connector parsing: send con permalink en texto (p16 dígitos → ts), también en hilo") {
            try expectEqual(send(F.sendResultPermalink), .done(ts: "1700000000.123456", channel: "C1"))
            // El p… de un permalink de respuesta es el ts de la respuesta, no el thread_ts.
            try expectEqual(send(F.sendThreadPermalink), .done(ts: "1700000001.000200", channel: "C1"))
        },
        TestCase("connector parsing: send con 'ts: …' o 'Message TS: …' en texto") {
            try expectEqual(send(F.sendPlainTS), .done(ts: "1700000000.123456", channel: nil))
            try expectEqual(send(F.sendMessageTSLabel), .done(ts: "1700000000.123456", channel: nil))
            // thread_ts no cuenta como el ts del mensaje.
            try expectEqual(send("Posted with thread_ts: 1700000000.000100"), .uncertain)
        },
        TestCase("connector parsing: send con errores de Slack (JSON, texto o is_error)") {
            try expectEqual(send(F.sendErrorJSON), .failed(.slack("not_in_channel")))
            try expectEqual(send(F.sendErrorText), .failed(.slack("channel_not_found")))
            try expectEqual(send("Error: is_archived", isError: true), .failed(.slack("is_archived")))
            try expectEqual(send("boom", isError: true), .failed(.slack("connector_error")))
            try expectEqual(send(#"{"ok":false,"error":"some_new_code"}"#), .failed(.slack("some_new_code")))
            try expectEqual(send("ratelimited", isError: true), .failed(.rateLimited(resetAt: at(0).addingTimeInterval(60))))
            // Un error explícito gana aunque haya un ts (p. ej. el del mensaje al que se quería responder).
            try expectEqual(send(#"{"ok":false,"error":"thread_not_found","ts":"1700000000.000100"}"#), .failed(.slack("thread_not_found")))
        },
        TestCase("connector parsing: send sin ts ni error reconocible → nunca éxito") {
            try expectEqual(send(F.sendOkWithoutTS), .done(ts: nil, channel: nil))
            try expectEqual(send(F.sendUnknown), .uncertain)
            try expectEqual(send(F.sendEmpty), .uncertain)
            try expectEqual(send("{}"), .uncertain)
            try expectEqual(send(#"{"result":"ok"}"#), .uncertain)
        },
        TestCase("connector parsing: reacción ok, ya hecha, error o desconocida") {
            try expectEqual(react(F.reactJSONok), .done(ts: nil, channel: nil))
            try expectEqual(react(F.reactResultText), .done(ts: nil, channel: nil))
            try expectEqual(react(F.reactAlready), .done(ts: nil, channel: nil))
            try expectEqual(react("already_reacted", isError: true), .done(ts: nil, channel: nil))
            try expectEqual(react(F.reactErrorText), .failed(.slack("invalid_name")))
            try expectEqual(react("Couldn't add the reaction", isError: false), .failed(.slack("connector_error")))
            try expectEqual(react(F.reactUnknown), .uncertain)
            try expectEqual(react(""), .uncertain)
            try expectEqual(react("{}"), .uncertain)
        },
        TestCase("connector parsing: historial real de slack_read_channel (fixture grabado)") {
            let messages = try ConnectorResultParser.parseMessages(F.readChannel)
                .unwrap("the recorded read_channel format should parse")
            try expectEqual(messages.count, 5)
            try expectEqual(messages.map(\.ts), ["1794249419.368099", "1793383941.847189", "1792765374.117489",
                                                 "1792605661.455269", "1791919628.815159"])
            try expectEqual(messages.map(\.user), ["U0000000002", "U0000000003", "U0000000001", "U0000000002", "U0000000003"])
            let mine = messages[2]
            try expectEqual(mine.linkedURLs, ["https://github.com/acme/orders/pull/66"])
            try expect(mine.text.hasPrefix("<https://github.com/acme/orders/pull/66|"), mine.text)
            try expect(!mine.text.contains("Thread:") && !mine.text.contains("Reactions:"), mine.text)
            try expect(PRLinkMatcher.matches(mine, prURL: URL(string: "https://github.com/acme/orders/pull/66")!))
            try expect(!PRLinkMatcher.matches(mine, prURL: URL(string: "https://github.com/acme/orders/pull/6")!))
            try expect(messages[1].text.contains("*Sent using*"), messages[1].text)
        },
        TestCase("connector parsing: historial vacío o formato desconocido") {
            try expectEqual(ConnectorResultParser.parseMessages(#"{"messages":"Channel: #x (C1)\n\nNo messages found."}"#), [])
            try expectEqual(ConnectorResultParser.parseMessages(#"{"messages":""}"#), [])
            try expectEqual(ConnectorResultParser.parseMessages("something else entirely"), nil)
            try expectEqual(ConnectorResultParser.parseMessages(#"{"result":"weird"}"#), nil)
        },
        TestCase("connector parsing: hilo con el mismo formato (padre y respuestas)") {
            let thread = #"{"messages":"=== Message from Sam <f@x.com> (U0000000001) at 2026-11-19 10:00:00 -03 === \nMessage TS: 1700000000.000100\nPRBar connector test (you can delete this)\nReactions: eyes (1)\n\n=== Message from Sam <f@x.com> (U0000000001) at 2026-11-19 10:00:05 -03 === \nMessage TS: 1700000005.000200\nPRBar connector test reply"}"#
            let messages = try ConnectorResultParser.parseMessages(thread).unwrap("thread")
            try expectEqual(messages, [
                SlackMessage(ts: "1700000000.000100", text: "PRBar connector test (you can delete this)", user: "U0000000001"),
                SlackMessage(ts: "1700000005.000200", text: "PRBar connector test reply", user: "U0000000001"),
            ])
        },
        TestCase("connector parsing: texto comparable sin el formato de links de Slack") {
            try expectEqual(SlackText.comparable("Updated <https://github.com/o/r/pull/1|github.com/o/r/pull/1>"),
                            SlackText.comparable("Updated https://github.com/o/r/pull/1"))
            try expectEqual(SlackText.comparable("a &amp; b  <https://x.y>\n"), "a & b https://x.y")
            try expect(SlackText.comparable("commented x2") != SlackText.comparable("commented x3"))
        },
    ]
}

extension Optional {
    func unwrap(_ what: String, file: StaticString = #fileID, line: UInt = #line) throws -> Wrapped {
        guard let self else { throw TestFailure(description: "\(file):\(line) \(what) was nil") }
        return self
    }
}
