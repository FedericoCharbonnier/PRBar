import Foundation
import PRBarCore

private func logFile() throws -> URL {
    try temporaryDirectory().appendingPathComponent("slack-connector.log")
}

private func statuses(_ steps: [SlackSelfTestStep]) -> [SlackSelfTestStep.Status] { steps.map(\.status) }

enum SlackSelfTestTests {
    static let cases: [TestCase] = [
        TestCase("self-test: textos y confirmación exactos") {
            try expectEqual(SlackSelfTest.rootText, "PRBar connector test (you can delete this)")
            try expectEqual(SlackSelfTest.replyText, "PRBar connector test reply")
            try expectEqual(SlackSelfTest.confirmation,
                            "PRBar will post a test message in your own DM, react 👀, reply in its thread, then read it back.")
        },
        TestCase("self-test: perfil → un post al DM propio → 👀 → una respuesta en el hilo → lectura") {
            let api = FakeSlackAPI()
            api.results = [.success("1700000000.000100"), .success("1700000005.000200")]
            api.postedChannel = "D0SELF"
            api.threads["D0SELF/1700000000.000100"] = [
                SlackMessage(ts: "1700000000.000100", text: SlackSelfTest.rootText, user: "U1"),
                SlackMessage(ts: "1700000005.000200", text: SlackSelfTest.replyText, user: "U1"),
            ]
            let log = try logFile()
            let steps = await SlackSelfTest.run(api: api, token: "", logURL: log)
            try expectEqual(statuses(steps), [.ok, .ok, .ok, .ok, .ok])
            try expectEqual(api.authCalls, 1)
            // Exactamente un mensaje raíz y una respuesta, al DM propio (el ID de usuario) y después a su canal.
            try expectEqual(api.posts.count, 2)
            try expectEqual(api.posts[0].channel, "U1")
            try expectEqual(api.posts[0].text, SlackSelfTest.rootText)
            try expectEqual(api.posts[0].threadTS, nil)
            try expectEqual(api.posts[1].channel, "D0SELF")
            try expectEqual(api.posts[1].text, SlackSelfTest.replyText)
            try expectEqual(api.posts[1].threadTS, "1700000000.000100")
            try expectEqual(api.reactions.map(\.channel), ["D0SELF"])
            try expectEqual(api.reactions.map(\.ts), ["1700000000.000100"])
            try expectEqual(api.reactions.map(\.name), ["eyes"])
            try expectEqual(api.threadCalls.map(\.channel), ["D0SELF"])
            try expect(steps[1].detail.contains("1700000000.000100"), steps[1].detail)
            try expect(steps[3].detail.contains("1700000005.000200"), steps[3].detail)
            let logged = try String(contentsOf: log, encoding: .utf8)
            try expect(logged.contains("=== self-test: Post a test message in your DM: ✓"), logged)
        },
        TestCase("self-test: sin canal en el resultado sigue con el ID de usuario") {
            let api = FakeSlackAPI()
            api.results = [.success("1700000000.000100"), .success("1700000005.000200")]
            api.threads["U1/1700000000.000100"] = [
                SlackMessage(ts: "1700000000.000100", text: SlackSelfTest.rootText, user: "U1"),
                SlackMessage(ts: "1700000005.000200", text: SlackSelfTest.replyText, user: "U1"),
            ]
            let steps = await SlackSelfTest.run(api: api, token: "", logURL: try logFile())
            try expectEqual(statuses(steps), [.ok, .ok, .ok, .ok, .ok])
            try expectEqual(api.reactions.map(\.channel), ["U1"])
        },
        TestCase("self-test: un paso que falla corta el resto, sin reintentos") {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack("connector_uncertain"))]
            let log = try logFile()
            let steps = await SlackSelfTest.run(api: api, token: "", logURL: log)
            try expectEqual(statuses(steps), [.ok, .failed, .skipped, .skipped, .skipped])
            try expectEqual(api.posts.count, 1)
            try expectEqual(api.reactions.count, 0)
            try expect(steps[1].detail.contains("couldn't tell"), steps[1].detail)
            let logged = try String(contentsOf: log, encoding: .utf8)
            try expect(logged.contains("✗"), logged)
        },
        TestCase("self-test: sin el ID propio no se postea nada") {
            let api = FakeSlackAPI()
            api.authError = .slack("connector_unavailable")
            let steps = await SlackSelfTest.run(api: api, token: "", logURL: try logFile())
            try expectEqual(statuses(steps), [.failed, .skipped, .skipped, .skipped, .skipped])
            try expectEqual(api.posts.count, 0)
        },
        TestCase("self-test: la reacción falla → no hay respuesta en el hilo") {
            let api = FakeSlackAPI()
            api.reactionErrors["eyes"] = .slack("connector_mismatch")
            let steps = await SlackSelfTest.run(api: api, token: "", logURL: try logFile())
            try expectEqual(statuses(steps), [.ok, .ok, .failed, .skipped, .skipped])
            try expectEqual(api.posts.count, 1)
        },
        TestCase("self-test: la lectura no encuentra la respuesta → ✗") {
            let api = FakeSlackAPI()
            api.results = [.success("1700000000.000100"), .success("1700000005.000200")]
            api.threads["U1/1700000000.000100"] = [SlackMessage(ts: "1700000000.000100", text: SlackSelfTest.rootText, user: "U1")]
            let steps = await SlackSelfTest.run(api: api, token: "", logURL: try logFile())
            try expectEqual(statuses(steps), [.ok, .ok, .ok, .ok, .failed])
            try expect(steps[4].detail.contains("reply"), steps[4].detail)
        },
        TestCase("self-test: el announcer usa la API y la conexión actuales") {
            let api = FakeSlackAPI()
            let store = try SlackStateStore(url: temporaryDirectory().appendingPathComponent("slack-state.json"))
            let announcer = await SlackAnnouncer(api: api, provider: .userToken, secrets: FakeSecrets(), stateStore: store)
            // Con token y sin token guardado: falla el primer paso, sin tocar Slack.
            let missing = await announcer.sendSelfTest(logURL: try logFile())
            try expectEqual(statuses(missing).first, .failed)
            try expectEqual(api.authCalls, 0)
            await announcer.use(api, provider: .claudeConnector)
            let steps = await announcer.sendSelfTest(logURL: try logFile())
            try expectEqual(steps.first?.status, .ok)
            try expectEqual(api.posts.first?.channel, "U1")
            try expectEqual(api.tokens.first, "")
        },
    ]
}
