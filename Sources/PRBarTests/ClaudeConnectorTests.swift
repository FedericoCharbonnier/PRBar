import Foundation
import PRBarCore

private let slackPrefix = "mcp__claude_ai_Slack__"
private let sendTool = slackPrefix + "slack_send_message"
private let reactTool = slackPrefix + "slack_add_reaction"
private let readTool = slackPrefix + "slack_read_channel"
private let listTool = slackPrefix + "slack_list_user_channels"
private let profileTool = slackPrefix + "slack_read_user_profile"

private func json(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

private func initLine(servers: [(String, String)] = [("claude.ai Slack", "connected")], tools: [String] = [],
                      mode: String = "dontAsk") -> String {
    json(["type": "system", "subtype": "init", "permissionMode": mode,
          "mcp_servers": servers.map { ["name": $0.0, "status": $0.1] }, "tools": ["StructuredOutput"] + tools])
}

private func toolUse(_ name: String, _ input: [String: Any], id: String = "t1") -> String {
    json(["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
}

private func toolResult(_ text: String, id: String = "t1", isError: Bool = false) -> String {
    json(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": isError,
                                                    "content": [["type": "text", "text": text]]]]]])
}

private func resultLine(_ structured: Any = ["done": true]) -> String {
    json(["type": "result", "subtype": "success", "is_error": false, "result": "", "structured_output": structured])
}

private func denialLine(_ tool: String) -> String {
    json(["type": "system", "subtype": "permission_denied", "tool_name": tool, "tool_use_id": "t9"])
}

private let permalink = #"{"result":"Message sent: https:\/\/acme.slack.com\/archives\/C1\/p1700000000123456"}"#

private func connector(_ lines: [String], servers: ConnectorServerList = ConnectorServerList(url: nil),
                       log: URL? = nil) throws -> (ClaudeConnectorSlackAPI, FakeStreamingRunner) {
    let runner = FakeStreamingRunner { _, _, _ in (lines, ProcessResult(status: 0, stdout: "", stderr: "")) }
    let logURL = try log ?? temporaryDirectory().appendingPathComponent("slack-connector.log")
    let claude = ClaudeConnectorRunner(
        runner: runner, claudePath: "/usr/local/bin/claude",
        environment: ["PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/Users/me", "GH_TOKEN": "gho_x", "SSH_AUTH_SOCK": "/tmp/s"],
        workingDirectory: try temporaryDirectory(), logURL: logURL, servers: servers
    )
    return (ClaudeConnectorSlackAPI(runner: claude, now: { at(0) }), runner)
}

private func value(of flag: String, in arguments: [String]) -> String? {
    arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
}

private func expectSlackError(_ expected: PRBarError, file: StaticString = #fileID, line: UInt = #line,
                              _ body: () async throws -> Void) async throws {
    let error = try await expectThrows(file: file, line: line, body)
    try expectEqual(error as? PRBarError, expected, file: file, line: line)
}

private let sent = [initLine(tools: [sendTool]), toolUse(sendTool, ["channel_id": "C1", "message": "PR https://github.com/o/r/pull/1"]),
                    toolResult(permalink), resultLine()]

enum ClaudeConnectorTests {
    static let cases: [TestCase] = [
        TestCase("slack connector: flags exactos, sin herramientas propias y solo la herramienta de la operación") {
            let arguments = ClaudeConnectorRunner.arguments(prompt: "P", schema: "S", tool: sendTool,
                                                            deniedServers: ["braindown", "claude.ai Google Drive", "claude.ai Slack"])
            let otherSlack = ClaudeConnectorRunner.slackTools.filter { $0 != sendTool }
            let disallowed = ClaudeConnectorRunner.builtInTools + otherSlack
                + ["mcp__claude-in-chrome", "mcp__braindown", "mcp__claude_ai_Google_Drive"]
            let settings = #"{"deniedMcpServers":[{"serverName":"claude-in-chrome"},{"serverName":"braindown"},{"serverName":"claude.ai Google Drive"}],"disableAllHooks":true,"permissions":{"deny":["mcp__claude-in-chrome","mcp__braindown","mcp__claude_ai_Google_Drive"],"disableBypassPermissionsMode":"disable"}}"#
            try expectEqual(arguments, [
                "-p", "P", "--model", "haiku", "--output-format", "stream-json", "--verbose", "--json-schema", "S",
                "--system-prompt", value(of: "--system-prompt", in: arguments) ?? "",
                "--setting-sources", "user", "--settings", settings,
                "--disable-slash-commands", "--no-chrome", "--no-session-persistence",
                "--permission-mode", "dontAsk", "--tools", "", "--allowedTools", sendTool,
                "--disallowedTools", disallowed.joined(separator: ","),
            ])
            try expect(ClaudeConnectorRunner.builtInTools.contains("Bash"))
            try expect(ClaudeConnectorRunner.builtInTools.contains("WebFetch"))
            try expect(!disallowed.contains(sendTool))
            try expect(!arguments.contains("mcp__claude_ai_Slack"))
            try expect(!arguments.contains { $0.contains("bypassPermissions") && !$0.contains("disableBypass") })
            try expect(value(of: "--system-prompt", in: arguments)?.contains("untrusted data") == true)
        },
        TestCase("slack connector: corrida aislada, con lista blanca de entorno, timeout y log") {
            let log = try temporaryDirectory().appendingPathComponent("logs/slack-connector.log")
            let (api, runner) = try connector(sent, log: log)
            _ = try await api.postMessage(channel: "C1", text: "PR https://github.com/o/r/pull/1", threadTS: nil, token: "")
            try expectEqual(runner.isolated, [true])
            let call = runner.calls[0]
            try expectEqual(call.executable, "/usr/local/bin/claude")
            try expectEqual(call.timeout, 60)
            try expectEqual(call.environment, ["PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/Users/me", "MCP_CONNECTION_NONBLOCKING": "0"])
            let prompt = value(of: "-p", in: call.arguments) ?? ""
            try expect(prompt.contains(#"{"channel_id":"C1","message":"PR https://github.com/o/r/pull/1"}"#), prompt)
            try expect(prompt.contains("untrusted data"))
            let logged = try String(contentsOf: log, encoding: .utf8)
            try expect(logged.contains("=== slack: post in C1 ==="))
            try expect(logged.contains("slack_send_message"))
        },
        TestCase("slack connector: post verificado devuelve el ts del permalink") {
            let (api, _) = try connector(sent)
            let ts = try await api.postMessage(channel: "C1", text: "PR https://github.com/o/r/pull/1", threadTS: nil, token: "")
            try expectEqual(ts, "1700000000.123456")
        },
        TestCase("slack connector: respuesta en hilo con thread_ts exacto") {
            let lines = [initLine(), toolUse(sendTool, ["channel_id": "C1", "message": "commented x2", "thread_ts": "1700000000.000100"]),
                         toolResult(#"{"result":"Message sent","ts":"1700000001.000200"}"#), resultLine()]
            let (api, _) = try connector(lines)
            let ts = try await api.postMessage(channel: "C1", text: "commented x2", threadTS: "1700000000.000100", token: "")
            try expectEqual(ts, "1700000001.000200")
            // Slack dijo ok sin ts: a una respuesta en hilo le alcanza.
            let (bare, _) = try connector([lines[0], lines[1], toolResult(#"{"ok":true}"#), lines[3]])
            let fallback = try await bare.postMessage(channel: "C1", text: "commented x2", threadTS: "1700000000.000100", token: "")
            try expectEqual(fallback, "1700000000.000100")
            // Un texto sin ts ni ok explícito no es un éxito, tampoco en un hilo.
            let (vague, _) = try connector([lines[0], lines[1], toolResult("Message sent"), lines[3]])
            try await expectSlackError(.slack("connector_uncertain")) {
                _ = try await vague.postMessage(channel: "C1", text: "commented x2", threadTS: "1700000000.000100", token: "")
            }
        },
        TestCase("slack connector: post raíz con ok sin ts → connector_no_ts; formato desconocido → connector_uncertain") {
            let (okOnly, _) = try connector([sent[0], sent[1], toolResult(#"{"ok":true}"#), sent[3]])
            try await expectSlackError(.slack("connector_no_ts")) {
                _ = try await okOnly.postMessage(channel: "C1", text: "PR https://github.com/o/r/pull/1", threadTS: nil, token: "")
            }
            for text in ["Message sent", "", "{}", "Done."] {
                let (api, _) = try connector([sent[0], sent[1], toolResult(text), sent[3]])
                try await expectSlackError(.slack("connector_uncertain")) {
                    _ = try await api.postMessage(channel: "C1", text: "PR https://github.com/o/r/pull/1", threadTS: nil, token: "")
                }
            }
        },
        TestCase("slack connector: cada formato plausible del resultado de send (fixtures)") {
            let cases: [(String, Result<SlackPostResult, PRBarError>)] = [
                (SlackConnectorFixtures.sendJSONts, .success(SlackPostResult(ts: "1700000000.123456", channel: "D0123ABCD"))),
                (SlackConnectorFixtures.sendJSONmessageTS, .success(SlackPostResult(ts: "1700000000.123456", channel: nil))),
                (SlackConnectorFixtures.sendJSONpermalink, .success(SlackPostResult(ts: "1700000000.123456", channel: "D0123ABCD"))),
                (SlackConnectorFixtures.sendResultPermalink, .success(SlackPostResult(ts: "1700000000.123456", channel: "C1"))),
                (SlackConnectorFixtures.sendPlainTS, .success(SlackPostResult(ts: "1700000000.123456", channel: nil))),
                (SlackConnectorFixtures.sendMessageTSLabel, .success(SlackPostResult(ts: "1700000000.123456", channel: nil))),
                (SlackConnectorFixtures.sendNestedResultJSON, .success(SlackPostResult(ts: "1700000000.123456", channel: "C1"))),
                (SlackConnectorFixtures.sendErrorJSON, .failure(.slack("not_in_channel"))),
                (SlackConnectorFixtures.sendErrorText, .failure(.slack("channel_not_found"))),
                (SlackConnectorFixtures.sendUnknown, .failure(.slack("connector_uncertain"))),
            ]
            for (text, expected) in cases {
                let (api, _) = try connector([sent[0], sent[1], toolResult(text), sent[3]])
                let got: Result<SlackPostResult, PRBarError>
                do {
                    got = .success(try await api.postMessageResult(channel: "C1", text: "PR https://github.com/o/r/pull/1", threadTS: nil, token: ""))
                } catch {
                    got = .failure(error as? PRBarError ?? .network("\(error)"))
                }
                try expectEqual(got, expected)
            }
        },
        TestCase("slack connector: timeout después de empezar la llamada → connector_uncertain; antes → timedOut") {
            let started = [initLine(), toolUse(sendTool, ["channel_id": "C1", "message": "hola"])]
            let runner = FakeStreamingRunner { _, _, _ in (started, ProcessResult(status: 0, stdout: "", stderr: "")) }
            runner.failAfterOutput = PRBarError.timedOut(command: "claude -p …")
            let claude = ClaudeConnectorRunner(runner: runner, claudePath: "/c", environment: [:], workingDirectory: try temporaryDirectory(),
                                               logURL: try temporaryDirectory().appendingPathComponent("l.log"), servers: ConnectorServerList(url: nil))
            try await expectSlackError(.slack("connector_uncertain")) {
                _ = try await ClaudeConnectorSlackAPI(runner: claude).postMessage(channel: "C1", text: "hola", threadTS: nil, token: "")
            }
            let early = FakeStreamingRunner { _, _, _ in ([initLine()], ProcessResult(status: 0, stdout: "", stderr: "")) }
            early.failAfterOutput = PRBarError.timedOut(command: "claude -p …")
            let beforeCall = ClaudeConnectorRunner(runner: early, claudePath: "/c", environment: [:], workingDirectory: try temporaryDirectory(),
                                                   logURL: try temporaryDirectory().appendingPathComponent("l.log"), servers: ConnectorServerList(url: nil))
            try await expectSlackError(.timedOut(command: "claude")) {
                _ = try await ClaudeConnectorSlackAPI(runner: beforeCall).postMessage(channel: "C1", text: "hola", threadTS: nil, token: "")
            }
        },
        TestCase("slack connector: una escritura sin tool_result → connector_uncertain") {
            let (api, _) = try connector([sent[0], sent[1], sent[3]])
            try await expectSlackError(.slack("connector_uncertain")) {
                _ = try await api.postMessage(channel: "C1", text: "PR https://github.com/o/r/pull/1", threadTS: nil, token: "")
            }
        },
        TestCase("slack connector: el tool_result crudo y lo interpretado quedan en el log") {
            let log = try temporaryDirectory().appendingPathComponent("slack-connector.log")
            let (api, _) = try connector([sent[0], sent[1], toolResult(SlackConnectorFixtures.sendUnknown), sent[3]], log: log)
            _ = try? await api.postMessage(channel: "C1", text: "PR https://github.com/o/r/pull/1", threadTS: nil, token: "")
            let logged = try String(contentsOf: log, encoding: .utf8)
            try expect(logged.contains("--- tool_result: Message sent successfully ---"), logged)
            try expect(logged.contains("--- parsed: uncertain ---"), logged)
        },
        TestCase("slack connector: otro texto, otro canal o un argumento de más → connector_mismatch") {
            let variants: [[String: Any]] = [
                ["channel_id": "C1", "message": "PR https://github.com/o/r/pull/1 "],
                ["channel_id": "C2", "message": "PR https://github.com/o/r/pull/1"],
                ["channel_id": "C1", "message": "PR https://github.com/o/r/pull/1", "unfurl_app_links": true],
                ["channel_id": "C1", "message": "PR https://github.com/o/r/pull/1", "thread_ts": "1700000000.000100"],
            ]
            for input in variants {
                let (api, _) = try connector([sent[0], toolUse(sendTool, input), toolResult(permalink), resultLine()])
                try await expectSlackError(.slack("connector_mismatch")) {
                    _ = try await api.postMessage(channel: "C1", text: "PR https://github.com/o/r/pull/1", threadTS: nil, token: "")
                }
            }
        },
        TestCase("slack connector: una llamada extra o una herramienta distinta → connector_mismatch") {
            let input: [String: Any] = ["channel_id": "C1", "message": "hola"]
            let twice = [initLine(), toolUse(sendTool, input), toolResult(permalink), toolUse(sendTool, input, id: "t2"),
                         toolResult(permalink, id: "t2"), resultLine()]
            let other = [initLine(), toolUse(readTool, ["channel_id": "C1"]), toolResult("{}"), resultLine()]
            let extra = [initLine(), toolUse(sendTool, input), toolResult(permalink),
                         toolUse(profileTool, [:], id: "t2"), toolResult("{}", id: "t2"), resultLine()]
            let denied = [initLine(), toolUse(sendTool, input), toolResult(permalink), denialLine("mcp__braindown__get_todays_events"), resultLine()]
            for lines in [twice, other, extra, denied] {
                let (api, _) = try connector(lines)
                try await expectSlackError(.slack("connector_mismatch")) {
                    _ = try await api.postMessage(channel: "C1", text: "hola", threadTS: nil, token: "")
                }
            }
        },
        TestCase("slack connector: sin llamada → connector_unavailable si Slack no conectó, si no mismatch") {
            let (offline, _) = try connector([initLine(servers: [("claude.ai Slack", "needs-auth")]), resultLine()])
            try await expectSlackError(.slack("connector_unavailable")) {
                try await offline.addReaction(channel: "C1", ts: "1.2", name: "eyes", token: "")
            }
            let (lazy, _) = try connector([initLine(), resultLine()])
            try await expectSlackError(.slack("connector_mismatch")) {
                try await lazy.addReaction(channel: "C1", ts: "1.2", name: "eyes", token: "")
            }
        },
        TestCase("slack connector: un permissionMode distinto de dontAsk se rechaza") {
            let (api, _) = try connector([initLine(mode: "auto")] + sent.dropFirst())
            try await expectSlackError(.slack("connector_mismatch")) {
                _ = try await api.postMessage(channel: "C1", text: "PR https://github.com/o/r/pull/1", threadTS: nil, token: "")
            }
        },
        TestCase("slack connector: reacción verificada; already_reacted no es error") {
            let input: [String: Any] = ["channel_id": "C1", "message_ts": "1700000000.000100", "emoji": "eyes"]
            let (api, runner) = try connector([initLine(), toolUse(reactTool, input), toolResult(#"{"result":"Reaction added"}"#), resultLine()])
            for text in [SlackConnectorFixtures.reactJSONok, SlackConnectorFixtures.reactResultText, SlackConnectorFixtures.reactAlready] {
                let (ok, _) = try connector([initLine(), toolUse(reactTool, input), toolResult(text), resultLine()])
                try await ok.addReaction(channel: "C1", ts: "1700000000.000100", name: "eyes", token: "")
            }
            let (unknown, _) = try connector([initLine(), toolUse(reactTool, input), toolResult(SlackConnectorFixtures.reactUnknown), resultLine()])
            try await expectSlackError(.slack("connector_uncertain")) {
                try await unknown.addReaction(channel: "C1", ts: "1700000000.000100", name: "eyes", token: "")
            }
            try await api.addReaction(channel: "C1", ts: "1700000000.000100", name: "eyes", token: "")
            try expectEqual(value(of: "--allowedTools", in: runner.calls[0].arguments), reactTool)
            let (again, _) = try connector([initLine(), toolUse(reactTool, input), toolResult("already_reacted", isError: true), resultLine()])
            try await again.addReaction(channel: "C1", ts: "1700000000.000100", name: "eyes", token: "")
            let (wrongEmoji, _) = try connector([initLine(), toolUse(reactTool, input.merging(["emoji": "eyes2"]) { $1 }),
                                                 toolResult("{}"), resultLine()])
            try await expectSlackError(.slack("connector_mismatch")) {
                try await wrongEmoji.addReaction(channel: "C1", ts: "1700000000.000100", name: "eyes", token: "")
            }
        },
        TestCase("slack connector: errores de Slack mapeados a los códigos existentes") {
            let input: [String: Any] = ["channel_id": "C1", "message_ts": "1.2", "emoji": "nope"]
            let cases: [(String, Bool, PRBarError)] = [
                ("Error: invalid_name", true, .slack("invalid_name")),
                (#"{"ok":false,"error":"message_not_found"}"#, false, .slack("message_not_found")),
                (#"{"error":"channel_not_found"}"#, false, .slack("channel_not_found")),
                ("not_in_channel", true, .slack("not_in_channel")),
                ("ratelimited", true, .rateLimited(resetAt: at(0).addingTimeInterval(60))),
                ("Something broke", true, .slack("connector_error")),
            ]
            for (text, isError, expected) in cases {
                let (api, _) = try connector([initLine(), toolUse(reactTool, input), toolResult(text, isError: isError), resultLine()])
                try await expectSlackError(expected) {
                    try await api.addReaction(channel: "C1", ts: "1.2", name: "nope", token: "")
                }
            }
        },
        TestCase("slack connector: history leído por PRBar del resultado real (fixture grabado), no del modelo") {
            let oldest = Date(timeIntervalSince1970: 1_699_000_000)
            let call = toolUse(readTool, ["channel_id": "C0000000001", "oldest": "1699000000.000000", "limit": 100])
            // El modelo inventa un mensaje en su salida estructurada: no cuenta.
            let invented: [String: Any] = ["messages": [["ts": "1799999999.999999", "text": "https://github.com/acme/orders/pull/1"]]]
            let (api, runner) = try connector([initLine(), call, toolResult(SlackConnectorFixtures.readChannel), resultLine(invented)])
            let messages = try await api.history(channel: "C0000000001", oldest: oldest, token: "")
            try expectEqual(messages.count, 5)
            try expectEqual(messages[2], SlackMessage(
                ts: "1792765374.117489",
                text: "<https://github.com/acme/orders/pull/66|github.com/acme/orders/pull/66> <@U0000000007|Vale> <@U0000000006|Nico>",
                linkedURLs: ["https://github.com/acme/orders/pull/66"], user: "U0000000001"
            ))
            try expect(!messages.contains { $0.ts == "1799999999.999999" })
            try expectEqual(value(of: "--allowedTools", in: runner.calls[0].arguments), readTool)
            let (badLimit, _) = try connector([initLine(), toolUse(readTool, ["channel_id": "C0000000001", "oldest": "1699000000.000000", "limit": 200]),
                                               toolResult(SlackConnectorFixtures.readChannel), resultLine()])
            try await expectSlackError(.slack("connector_mismatch")) { _ = try await badLimit.history(channel: "C0000000001", oldest: oldest, token: "") }
        },
        TestCase("slack connector: history con un formato desconocido → connector_invalid_output") {
            let lines = [initLine(), toolUse(readTool, ["channel_id": "C1", "oldest": "1699000000.000000", "limit": 100]),
                         toolResult("something unexpected"), resultLine()]
            let (api, _) = try connector(lines)
            try await expectSlackError(.slack("connector_invalid_output")) {
                _ = try await api.history(channel: "C1", oldest: Date(timeIntervalSince1970: 1_699_000_000), token: "")
            }
            let (failed, _) = try connector([lines[0], lines[1], toolResult("channel_not_found", isError: true), lines[3]])
            try await expectSlackError(.slack("channel_not_found")) {
                _ = try await failed.history(channel: "C1", oldest: Date(timeIntervalSince1970: 1_699_000_000), token: "")
            }
        },
        TestCase("slack connector: hilo con slack_read_thread y argumentos exactos") {
            let threadTool = slackPrefix + "slack_read_thread"
            let raw = #"{"messages":"=== Message from Sam <f@x.com> (U0000000001) at 2026-11-19 10:00:00 -03 === \nMessage TS: 1700000000.000100\nPR https:\/\/github.com\/o\/r\/pull\/1\n\n=== Message from Sam <f@x.com> (U0000000001) at 2026-11-19 10:05:00 -03 === \nMessage TS: 1700000300.000200\nUpdated <https:\/\/github.com\/o\/r\/pull\/1|github.com\/o\/r\/pull\/1>"}"#
            let lines = [initLine(), toolUse(threadTool, ["channel_id": "C1", "message_ts": "1700000000.000100", "limit": 100]),
                         toolResult(raw), resultLine()]
            let (api, runner) = try connector(lines)
            let messages = try await api.threadReplies(channel: "C1", ts: "1700000000.000100", token: "")
            try expectEqual(messages.map(\.ts), ["1700000000.000100", "1700000300.000200"])
            try expectEqual(messages.map(\.user), ["U0000000001", "U0000000001"])
            try expectEqual(SlackText.comparable(messages[1].text), "Updated https://github.com/o/r/pull/1")
            try expectEqual(value(of: "--allowedTools", in: runner.calls[0].arguments), threadTool)
        },
        TestCase("slack connector: canales solo con IDs reales; nextCursor marca truncado") {
            let raw = ##"{"result":"Channels\n### #general\n- **ID:** C0000000002\n### #secret\n- **ID:** G123\n"}"##
            let structured: [String: Any] = ["channels": [
                ["id": "G123", "name": "secret", "isPrivate": true],
                ["id": "C0000000002", "name": "#general", "isPrivate": false],
                ["id": "CFAKE", "name": "invented", "isPrivate": false],
            ], "nextCursor": "abc"]
            let lines = [initLine(), toolUse(listTool, ["types": "public_channel,private_channel", "exclude_archived": true, "limit": 200]),
                         toolResult(raw), resultLine(structured)]
            let (api, _) = try connector(lines)
            let list = try await api.channels(token: "")
            try expectEqual(list, SlackChannelList(channels: [
                SlackChannel(id: "C0000000002", name: "general", isPrivate: false, isMember: true),
                SlackChannel(id: "G123", name: "secret", isPrivate: true, isMember: true),
            ], truncated: true))
            let (stringBool, _) = try connector([initLine(), toolUse(listTool, ["types": "public_channel,private_channel", "exclude_archived": "true", "limit": 200]),
                                                 toolResult(raw), resultLine(structured)])
            try await expectSlackError(.slack("connector_mismatch")) { _ = try await stringBool.channels(token: "") }
        },
        TestCase("slack connector: test de conexión con el perfil propio") {
            let raw = #"{"result":"User ID: U0000000001\nUsername: dev-sam\nOrganization Name: Acme\n"}"#
            let lines = [initLine(), toolUse(profileTool, [:]), toolResult(raw),
                         resultLine(["user": "dev-sam", "userID": "U0000000001", "team": "Acme"])]
            let (api, _) = try connector(lines)
            let identity = try await api.authTest(token: "")
            try expectEqual(identity, SlackIdentity(team: "Acme", user: "dev-sam", userID: "U0000000001"))
            let (invented, _) = try connector([lines[0], lines[1], lines[2], resultLine(["user": "x", "userID": "U999"])])
            try await expectSlackError(.slack("connector_mismatch")) { _ = try await invented.authTest(token: "") }
            let (withArgs, _) = try connector([lines[0], toolUse(profileTool, ["user_id": "U1"]), lines[2], lines[3]])
            try await expectSlackError(.slack("connector_mismatch")) { _ = try await withArgs.authTest(token: "") }
        },
        TestCase("slack connector: aprende los otros servidores MCP y los niega en la próxima corrida") {
            let file = try temporaryDirectory().appendingPathComponent("servers.json")
            let servers = ConnectorServerList(url: file)
            let first = [initLine(servers: [("braindown", "connected"), ("claude.ai Slack", "connected"), ("claude.ai Gmail", "needs-auth")])]
                + sent.dropFirst()
            let (api, runner) = try connector(first, servers: servers)
            _ = try await api.postMessage(channel: "C1", text: "PR https://github.com/o/r/pull/1", threadTS: nil, token: "")
            _ = try await api.postMessage(channel: "C1", text: "PR https://github.com/o/r/pull/1", threadTS: nil, token: "")
            let firstDenied = value(of: "--disallowedTools", in: runner.calls[0].arguments) ?? ""
            let secondDenied = value(of: "--disallowedTools", in: runner.calls[1].arguments) ?? ""
            try expect(!firstDenied.contains("mcp__braindown"))
            try expect(secondDenied.contains("mcp__braindown"))
            try expect(secondDenied.contains("mcp__claude_ai_Gmail"))
            try expect(value(of: "--settings", in: runner.calls[1].arguments)?.contains(#"{"serverName":"claude.ai Gmail"}"#) == true)
            try expectEqual(ConnectorServerList(url: file).names, ["braindown", "claude.ai Gmail"])
        },
        TestCase("slack connector: claude falla sin resultado → commandFailed") {
            let runner = FakeStreamingRunner { _, _, _ in ([], ProcessResult(status: 1, stdout: "", stderr: "not logged in")) }
            let claude = ClaudeConnectorRunner(runner: runner, claudePath: "/c", environment: [:], workingDirectory: try temporaryDirectory(),
                                               logURL: try temporaryDirectory().appendingPathComponent("l.log"), servers: ConnectorServerList(url: nil))
            let api = ClaudeConnectorSlackAPI(runner: claude)
            try await expectSlackError(.commandFailed(command: "claude", status: 1, stderr: "not logged in")) {
                try await api.addReaction(channel: "C1", ts: "1.2", name: "eyes", token: "")
            }
        },
    ]
}
