import Foundation
import PRBarCore

private func client(_ transport: FakeTransport) -> SlackClient {
    SlackClient(transport: transport, now: { t0 })
}

private func json(_ request: URLRequest) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
}

enum SlackClientTests {
    static let cases: [TestCase] = [
        TestCase("slack client: postMessage en hilo manda token, canal, texto y thread_ts") {
            let transport = FakeTransport([(200, [:], #"{"ok":true,"ts":"171.5"}"#)])
            let ts = try await client(transport).postMessage(channel: "C1", text: "hola", threadTS: "111.1", token: "xoxb-1")
            try expectEqual(ts, "171.5")
            let request = transport.requests[0]
            try expectEqual(request.url?.absoluteString, "https://slack.com/api/chat.postMessage")
            try expectEqual(request.httpMethod, "POST")
            try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xoxb-1")
            let body = try json(request)
            try expectEqual(body["channel"] as? String, "C1")
            try expectEqual(body["text"] as? String, "hola")
            try expectEqual(body["thread_ts"] as? String, "111.1")
            try expect(body["unfurl_links"] == nil, "se usa el unfurl por defecto de Slack")
        },
        TestCase("slack client: mensaje nuevo no manda thread_ts") {
            let transport = FakeTransport([(200, [:], #"{"ok":true,"ts":"1.0"}"#)])
            _ = try await client(transport).postMessage(channel: "C1", text: "x", threadTS: nil, token: "t")
            try expect(try json(transport.requests[0])["thread_ts"] == nil)
        },
        TestCase("slack client: ok=false → PRBarError.slack con el código") {
            let transport = FakeTransport([(200, [:], #"{"ok":false,"error":"not_in_channel"}"#)])
            let error = try await expectThrows { _ = try await client(transport).postMessage(channel: "C1", text: "x", threadTS: nil, token: "t") }
            try expect(error as? PRBarError == .slack("not_in_channel"))
        },
        TestCase("slack client: 429 → rateLimited con Retry-After") {
            let transport = FakeTransport([(429, ["Retry-After": "30"], "")])
            let error = try await expectThrows { _ = try await client(transport).postMessage(channel: "C1", text: "x", threadTS: nil, token: "t") }
            try expect(error as? PRBarError == .rateLimited(resetAt: t0.addingTimeInterval(30)))
        },
        TestCase("slack client: auth.test devuelve equipo, usuario y su ID") {
            let transport = FakeTransport([(200, [:], #"{"ok":true,"team":"Acme","user":"sam","user_id":"U42"}"#)])
            let identity = try await client(transport).authTest(token: "t")
            try expectEqual(identity, SlackIdentity(team: "Acme", user: "sam", userID: "U42"))
        },
        TestCase("slack client: canales paginados, ordenados y con is_member") {
            let transport = FakeTransport([
                (200, [:], #"{"ok":true,"channels":[{"id":"C2","name":"zeta","is_private":false,"is_member":true}],"response_metadata":{"next_cursor":"abc"}}"#),
                (200, [:], #"{"ok":true,"channels":[{"id":"C1","name":"alfa","is_private":true,"is_member":false}],"response_metadata":{"next_cursor":""}}"#),
            ])
            let list = try await client(transport).channels(token: "t")
            try expectEqual(list.truncated, false)
            try expectEqual(list.channels, [
                SlackChannel(id: "C1", name: "alfa", isPrivate: true, isMember: false),
                SlackChannel(id: "C2", name: "zeta", isPrivate: false, isMember: true),
            ])
            try expect(transport.requests[0].url?.absoluteString.contains("types=public_channel,private_channel") == true)
            try expect(transport.requests[1].url?.absoluteString.contains("cursor=abc") == true)
        },
        TestCase("slack client: si se llega al tope de páginas avisa que la lista está cortada") {
            let page = #"{"ok":true,"channels":[{"id":"C1","name":"a"}],"response_metadata":{"next_cursor":"more"}}"#
            let transport = FakeTransport(Array(repeating: (200, [:], page), count: 12))
            let list = try await client(transport).channels(token: "t")
            try expectEqual(transport.requests.count, 10)
            try expectEqual(list.truncated, true)
            try expectEqual(SlackClient.channelLimit, 2000)
        },
        TestCase("slack client: history pagina por cursor, manda oldest y deja solo mensajes raíz") {
            let transport = FakeTransport([
                (200, [:], #"{"ok":true,"messages":[{"ts":"3.0","text":"root <https://github.com/o/r/pull/1>"},{"ts":"2.5","text":"reply","thread_ts":"2.0"}],"response_metadata":{"next_cursor":"c2"}}"#),
                (200, [:], #"{"ok":true,"messages":[{"ts":"2.0","text":"parent","thread_ts":"2.0","attachments":[{"from_url":"https://github.com/o/r/pull/2","title_link":"https://github.com/o/r/pull/2/files"},{"title":"x"}],"blocks":[{"type":"rich_text","elements":[{"type":"rich_text_section","elements":[{"type":"link","url":"https://github.com/o/r/pull/3"},{"type":"text","text":"hi"}]}]},{"type":"actions","elements":[{"type":"button","url":"https://example.com","value":7}]}]},{"ts":"1.0"}],"response_metadata":{"next_cursor":""}}"#),
            ])
            let messages = try await client(transport).history(channel: "C1", oldest: Date(timeIntervalSince1970: 1_700_000_000), token: "xoxp-1")
            try expectEqual(messages, [
                SlackMessage(ts: "3.0", text: "root <https://github.com/o/r/pull/1>"),
                SlackMessage(ts: "2.0", text: "parent", linkedURLs: [
                    "https://github.com/o/r/pull/2", "https://github.com/o/r/pull/2/files",
                    "https://github.com/o/r/pull/3", "https://example.com",
                ]),
                SlackMessage(ts: "1.0", text: ""),
            ])
            try expectEqual(transport.requests.count, 2)
            let first = transport.requests[0].url?.absoluteString ?? ""
            try expect(first.hasPrefix("https://slack.com/api/conversations.history?"), first)
            try expect(first.contains("channel=C1"), first)
            try expect(first.contains("oldest=1700000000.000000"), first)
            try expect(first.contains("limit=200"), first)
            try expect(!first.contains("cursor="), first)
            try expect(transport.requests[1].url?.absoluteString.contains("cursor=c2") == true)
            try expectEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer xoxp-1")
        },
        TestCase("slack client: history revisa como máximo 1000 mensajes") {
            let messages = (0..<200).map { #"{"ts":"\#($0).0","text":"m"}"# }.joined(separator: ",")
            let page = #"{"ok":true,"messages":[\#(messages)],"response_metadata":{"next_cursor":"more"}}"#
            let transport = FakeTransport(Array(repeating: (200, [:], page), count: 8))
            let result = try await client(transport).history(channel: "C1", oldest: t0, token: "t")
            try expectEqual(transport.requests.count, 5)
            try expectEqual(result.count, 1000)
            try expectEqual(SlackClient.historyLimit, 1000)
        },
        TestCase("slack client: reactions.add manda canal, timestamp y nombre") {
            let transport = FakeTransport([(200, [:], #"{"ok":true}"#)])
            try await client(transport).addReaction(channel: "C1", ts: "1.5", name: "eyes", token: "xoxp-1")
            let request = transport.requests[0]
            try expectEqual(request.url?.absoluteString, "https://slack.com/api/reactions.add")
            try expectEqual(request.httpMethod, "POST")
            let body = try json(request)
            try expectEqual(body["channel"] as? String, "C1")
            try expectEqual(body["timestamp"] as? String, "1.5")
            try expectEqual(body["name"] as? String, "eyes")
        },
        TestCase("slack client: already_reacted no es un error") {
            let transport = FakeTransport([(200, [:], #"{"ok":false,"error":"already_reacted"}"#)])
            try await client(transport).addReaction(channel: "C1", ts: "1.5", name: "eyes", token: "t")
        },
        TestCase("slack client: invalid_name, missing_scope y not_in_channel → .slack(código)") {
            for code in ["invalid_name", "missing_scope", "not_in_channel"] {
                let transport = FakeTransport([(200, [:], #"{"ok":false,"error":"\#(code)"}"#)])
                let error = try await expectThrows { try await client(transport).addReaction(channel: "C1", ts: "1", name: "x", token: "t") }
                try expectEqual(error as? PRBarError, .slack(code))
            }
            let transport = FakeTransport([(200, [:], #"{"ok":false,"error":"missing_scope"}"#)])
            let error = try await expectThrows { _ = try await client(transport).history(channel: "C1", oldest: t0, token: "t") }
            try expectEqual(error as? PRBarError, .slack("missing_scope"))
        },
        TestCase("slack client: 429 en history y reactions → rateLimited") {
            let history = FakeTransport([(429, ["Retry-After": "12"], "")])
            let historyError = try await expectThrows { _ = try await client(history).history(channel: "C1", oldest: t0, token: "t") }
            try expectEqual(historyError as? PRBarError, .rateLimited(resetAt: t0.addingTimeInterval(12)))
            let reaction = FakeTransport([(429, [:], "")])
            let reactionError = try await expectThrows { try await client(reaction).addReaction(channel: "C1", ts: "1", name: "x", token: "t") }
            try expectEqual(reactionError as? PRBarError, .rateLimited(resetAt: t0.addingTimeInterval(60)))
        },
    ]
}
