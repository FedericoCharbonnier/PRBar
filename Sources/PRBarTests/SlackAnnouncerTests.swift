import Foundation
import PRBarCore

private func makeAnnouncer(
    _ api: FakeSlackAPI,
    secrets: FakeSecrets = FakeSecrets(["user-token": "xoxp-1"]),
    clock: Box<Date> = Box(at(-90)),
    store: SlackStateStore? = nil
) async throws -> (SlackAnnouncer, SlackStateStore) {
    let store = try store ?? SlackStateStore(url: temporaryDirectory().appendingPathComponent("slack-state.json"))
    let announcer = await SlackAnnouncer(api: api, secrets: secrets, stateStore: store, now: { clock.value })
    return (announcer, store)
}

enum SlackAnnouncerTests {
    static let cases: [TestCase] = [
        TestCase("slack announcer: anuncia, guarda el ts y no repite") {
            let api = FakeSlackAPI()
            let (announcer, store) = try await makeAnnouncer(api)
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            try expectEqual(api.posts[0].channel, "C1")
            try expectEqual(store.load().announcements["o/r#1"]?.ts, "ts-1")
            let issues = await announcer.issues
            try expectEqual(issues, [])
        },
        TestCase("slack announcer: después de review + push manda Updated en el hilo una sola vez") {
            let api = FakeSlackAPI()
            let clock = Box(at(-90))
            let (announcer, _) = try await makeAnnouncer(api, clock: clock)
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            clock.value = at(30)
            let updated = myPR(reviews: [review("ana", .changesRequested, at: 10, commit: "old")])
            await announcer.process(snapshot: slackSnap(updated), config: slackConfig())
            await announcer.process(snapshot: slackSnap(updated), config: slackConfig())
            try expectEqual(api.posts.count, 2)
            try expectEqual(api.posts[1].threadTS, "ts-1")
            try expectEqual(api.posts[1].text, "Updated https://github.com/o/r/pull/1")
        },
        TestCase("slack announcer: una review que llega después del snapshot no se pierde") {
            let api = FakeSlackAPI()
            let clock = Box(at(-90))
            let (announcer, store) = try await makeAnnouncer(api, clock: clock)
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            // El Updated se postea mucho después de la review de bob, pero solo "maneja" la de ana.
            clock.value = at(100)
            let firstRound = myPR(head: "B", reviews: [review("ana", .changesRequested, at: 10, commit: "A")])
            await announcer.process(snapshot: slackSnap(firstRound), config: slackConfig())
            try expectEqual(store.load().announcements["o/r#1"]?.lastHandledReviewAt, at(10))
            let secondReview = myPR(head: "B", reviews: [review("ana", .changesRequested, at: 10, commit: "A"), review("bob", .changesRequested, at: 50, commit: "B")])
            await announcer.process(snapshot: slackSnap(secondReview), config: slackConfig())
            try expectEqual(api.posts.count, 2)
            let pushed = myPR(head: "C", reviews: [review("ana", .changesRequested, at: 10, commit: "A"), review("bob", .changesRequested, at: 50, commit: "B")])
            await announcer.process(snapshot: slackSnap(pushed), config: slackConfig())
            try expectEqual(api.posts.count, 3)
            try expectEqual(api.posts[2].threadTS, "ts-1")
        },
        TestCase("slack announcer: sin token → issue y ningún post") {
            let api = FakeSlackAPI()
            let (announcer, _) = try await makeAnnouncer(api, secrets: FakeSecrets())
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 0)
            let issues = await announcer.issues
            try expectEqual(issues.map(\.error), [.slack("missing_token")])
        },
        TestCase("slack announcer: error de Slack queda como issue y se reintenta") {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack("not_in_channel"))]
            let (announcer, store) = try await makeAnnouncer(api)
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            let firstIssues = await announcer.issues
            try expectEqual(firstIssues.map(\.error), [.slack("not_in_channel")])
            try expectEqual(firstIssues.map(\.detail), ["C1"])
            try expectEqual(store.load().announcements.count, 0)
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            let secondIssues = await announcer.issues
            try expectEqual(secondIssues, [])
            try expectEqual(store.load().announcements.count, 1)
        },
        TestCase("slack announcer: rate limit corta el resto de los envíos") {
            let api = FakeSlackAPI()
            api.results = [.failure(.rateLimited(resetAt: at(5)))]
            let (announcer, _) = try await makeAnnouncer(api)
            await announcer.process(snapshot: slackSnap(myPR(number: 1), myPR(number: 2)), config: slackConfig())
            try expectEqual(api.posts.count, 1)
        },
        TestCase("slack announcer: drafts se guardan en el estado") {
            let api = FakeSlackAPI()
            let (announcer, store) = try await makeAnnouncer(api)
            await announcer.process(snapshot: slackSnap(myPR(isDraft: true)), config: slackConfig())
            try expectEqual(store.load().seenAsDraft, ["o/r#1": at(-90)])
            try expectEqual(api.posts.count, 0)
        },
        TestCase("slack announcer: desactivado no postea y limpia issues") {
            let api = FakeSlackAPI()
            let (announcer, _) = try await makeAnnouncer(api, secrets: FakeSecrets())
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig(enabled: false))
            try expectEqual(api.posts.count, 0)
            let issues = await announcer.issues
            try expectEqual(issues, [])
        },
        TestCase("slack announcer: un pedido que llega a mitad de una corrida se procesa al terminar") {
            let api = FakeSlackAPI()
            let (announcer, _) = try await makeAnnouncer(api)
            let both = slackSnap(myPR(number: 1), myPR(number: 2))
            api.onPost = { index in
                if index == 1 { await announcer.process(snapshot: both, config: slackConfig()) }
            }
            await announcer.process(snapshot: slackSnap(myPR(number: 1)), config: slackConfig())
            try expectEqual(api.posts.map(\.text), ["https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2"])
        },
        TestCase("slack announcer: apagar Slack a mitad de una corrida corta los envíos y limpia issues") {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack("not_in_channel"))]
            let (announcer, _) = try await makeAnnouncer(api)
            api.onPost = { index in
                if index == 1 { await announcer.process(snapshot: slackSnap(), config: slackConfig(enabled: false)) }
            }
            await announcer.process(snapshot: slackSnap(myPR(number: 1), myPR(number: 2)), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            let issues = await announcer.issues
            try expectEqual(issues, [])
        },
        TestCase("slack announcer: reprocess sin snapshot solo limpia si Slack está apagado") {
            let api = FakeSlackAPI()
            let (announcer, _) = try await makeAnnouncer(api, secrets: FakeSecrets())
            await announcer.process(snapshot: slackSnap(), config: slackConfig())
            await announcer.reprocess(snapshot: nil, config: slackConfig())
            let kept = await announcer.issues
            try expectEqual(kept.count, 1)
            await announcer.reprocess(snapshot: nil, config: slackConfig(enabled: false))
            let cleared = await announcer.issues
            try expectEqual(cleared, [])
        },
        TestCase("slack announcer: sin nada que mandar no lee el token") {
            let secrets = FakeSecrets(["user-token": "xoxp-1"])
            let (announcer, _) = try await makeAnnouncer(FakeSlackAPI(), secrets: secrets)
            let hasToken = await announcer.hasToken
            try expectEqual(hasToken, true)
            await announcer.process(snapshot: slackSnap(), config: slackConfig())
            await announcer.process(snapshot: slackSnap(myPR(isDraft: true)), config: slackConfig())
            try expectEqual(secrets.reads, 0)
            try expectEqual(secrets.existsChecks, 2)
        },
        TestCase("slack announcer: el token se lee una sola vez y se cachea") {
            let secrets = FakeSecrets(["user-token": "xoxp-1"])
            let api = FakeSlackAPI()
            let (announcer, _) = try await makeAnnouncer(api, secrets: secrets)
            await announcer.process(snapshot: slackSnap(myPR(number: 1)), config: slackConfig())
            await announcer.process(snapshot: slackSnap(myPR(number: 2)), config: slackConfig())
            try expectEqual(api.posts.count, 2)
            try expectEqual(secrets.reads, 1)
            _ = try await announcer.testConnection()
            try expectEqual(secrets.reads, 1)
            try await announcer.saveToken("xoxp-nuevo")
            await announcer.process(snapshot: slackSnap(myPR(number: 3)), config: slackConfig())
            try expectEqual(secrets.reads, 1)
            try expectEqual(api.tokens.last, "xoxp-nuevo")
        },
        TestCase("slack announcer: guardar y borrar token actualiza hasToken") {
            let (announcer, _) = try await makeAnnouncer(FakeSlackAPI(), secrets: FakeSecrets())
            let before = await announcer.hasToken
            try expectEqual(before, false)
            let revision = await announcer.tokenRevision
            let added = try await announcer.saveToken("xoxp-nuevo")
            let nextRevision = await announcer.tokenRevision
            try expectEqual(nextRevision, revision + 1)
            try expectEqual(added, true)
            let replaced = try await announcer.saveToken("xoxp-otro")
            try expectEqual(replaced, false)
            let after = await announcer.hasToken
            try expectEqual(after, true)
            try await announcer.saveToken(nil)
            let cleared = await announcer.hasToken
            try expectEqual(cleared, false)
        },
        TestCase("slack announcer: reiniciar con el mismo estado no repite anuncios") {
            let api = FakeSlackAPI()
            let (first, store) = try await makeAnnouncer(api)
            await first.process(snapshot: slackSnap(myPR()), config: slackConfig())
            let (second, _) = try await makeAnnouncer(api, clock: Box(at(5)), store: store)
            await second.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 1)
        },
        TestCase("slack announcer: sin archivo de estado arranca con baseline = ahora y no anuncia PRs viejos") {
            let api = FakeSlackAPI()
            let (announcer, store) = try await makeAnnouncer(api, clock: Box(at(0)))
            try expectEqual(store.load().baselineAt, at(0))
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 0)
        },
        TestCase("slack announcer: estado corrupto → .bak y no anuncia PRs anteriores") {
            let dir = try temporaryDirectory()
            let url = dir.appendingPathComponent("slack-state.json")
            try Data("{basura".utf8).write(to: url)
            let api = FakeSlackAPI()
            let (announcer, store) = try await makeAnnouncer(api, clock: Box(at(0)), store: SlackStateStore(url: url))
            let backup = try String(contentsOf: dir.appendingPathComponent("slack-state.json.bak"), encoding: .utf8)
            try expectEqual(backup, "{basura")
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 0)
            try expectEqual(store.load().baselineAt, at(0))
        },
        TestCase("slack announcer: si no se puede guardar el estado queda un issue") {
            let dir = try temporaryDirectory()
            let blocker = dir.appendingPathComponent("no-es-carpeta")
            try Data().write(to: blocker)
            let api = FakeSlackAPI()
            let (announcer, _) = try await makeAnnouncer(api, store: SlackStateStore(url: blocker.appendingPathComponent("slack-state.json")))
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            let issues = await announcer.issues
            try expectEqual(issues.count, 1)
            guard case .stateNotSaved = issues.first?.error else { throw TestFailure(description: "esperaba stateNotSaved, hubo \(issues)") }
        },
        TestCase("slack state: decodifica archivos viejos o incompletos") {
            let legacy = #"{"announcements":{"o/r#1":{"channelID":"C1","ts":"1.1","announcedAt":"2026-11-18T10:00:00Z"}},"seenAsDraft":["o/r#2"]}"#
            let state = try JSONCoding.decoder.decode(SlackState.self, from: Data(legacy.utf8))
            try expectEqual(state.baselineAt, .distantPast)
            try expectEqual(state.announcements["o/r#1"]?.ts, "1.1")
            try expectEqual(state.seenAsDraft, ["o/r#2": .distantPast])
            let empty = try JSONCoding.decoder.decode(SlackState.self, from: Data("{}".utf8))
            try expectEqual(empty.announcements, [:])
        },
        TestCase("slack announcer: con el conector de Claude no hace falta token") {
            let api = FakeSlackAPI()
            let (announcer, store) = try await makeAnnouncer(api, secrets: FakeSecrets())
            await announcer.use(api, provider: .claudeConnector)
            let connected = await announcer.isConnected
            try expect(connected)
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            // La lectura anti-duplicados del canal y el post, los dos sin token.
            try expectEqual(api.tokens, ["", ""])
            try expectEqual(api.historyCalls.map(\.channel), ["C1"])
            try expectEqual(store.load().announcements["o/r#1"]?.ts, "ts-1")
            let issues = await announcer.issues
            try expectEqual(issues, [])
        },
        TestCase("slack announcer: volver al token sin token guardado → missing_token") {
            let api = FakeSlackAPI()
            let (announcer, _) = try await makeAnnouncer(api, secrets: FakeSecrets())
            await announcer.use(api, provider: .claudeConnector)
            let revision = await announcer.tokenRevision
            await announcer.use(api, provider: .userToken)
            let after = await announcer.tokenRevision
            try expectEqual(after, revision + 1)
            await announcer.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 0)
            let issues = await announcer.issues
            try expectEqual(issues.map(\.error), [.slack("missing_token")])
        },
        TestCase("slack announcer: el conector desconectado o que no hizo lo pedido corta el ciclo") {
          for code in ["connector_unavailable", "connector_mismatch"] {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack(code))]
            let (announcer, store) = try await makeAnnouncer(api, secrets: FakeSecrets())
            await announcer.use(api, provider: .claudeConnector)
            await announcer.process(snapshot: slackSnap(myPR(number: 1), myPR(number: 2)), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            try expectEqual(store.load().announcements.count, 0)
            let issues = await announcer.issues
            try expectEqual(issues.map(\.error), [.slack(code)])
          }
        },
        TestCase("slack announcer: los canales se cachean hasta recargar o cambiar la conexión") {
            final class CountingAPI: SlackAPI, @unchecked Sendable {
                var calls = 0
                func postMessage(channel: String, text: String, threadTS: String?, token: String) async throws -> String { "" }
                func authTest(token: String) async throws -> SlackIdentity { SlackIdentity(team: "", user: "") }
                func channels(token: String) async throws -> SlackChannelList {
                    calls += 1
                    return SlackChannelList(channels: [SlackChannel(id: "C\(calls)", name: "c", isPrivate: false, isMember: true)], truncated: false)
                }
                func history(channel: String, oldest: Date, token: String) async throws -> [SlackMessage] { [] }
                func threadReplies(channel: String, ts: String, token: String) async throws -> [SlackMessage] { [] }
                func addReaction(channel: String, ts: String, name: String, token: String) async throws {}
            }
            let api = CountingAPI()
            let store = try SlackStateStore(url: temporaryDirectory().appendingPathComponent("slack-state.json"))
            let announcer = await SlackAnnouncer(api: api, provider: .claudeConnector, secrets: FakeSecrets(), stateStore: store)
            _ = try await announcer.channels()
            let cached = try await announcer.channels()
            try expectEqual(api.calls, 1)
            try expectEqual(cached.channels.map(\.id), ["C1"])
            let reloaded = try await announcer.channels(reload: true)
            try expectEqual(reloaded.channels.map(\.id), ["C2"])
            await announcer.use(api, provider: .claudeConnector)
            _ = try await announcer.channels()
            try expectEqual(api.calls, 3)
        },
    ]
}
