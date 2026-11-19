import Foundation
import PRBarCore

private let prURL = "https://github.com/o/r/pull/1"

/// Epoch de `at(minutes)` como `ts` de Slack.
private func slackTS(_ minutes: Int, micros: String = "000100") -> String {
    "\(Int(at(minutes).timeIntervalSince1970)).\(micros)"
}

private func newStore() throws -> SlackStateStore {
    try SlackStateStore(url: temporaryDirectory().appendingPathComponent("slack-state.json"))
}

@MainActor
private func announcer(_ api: FakeSlackAPI, clock: Box<Date>, store: SlackStateStore,
                       provider: SlackProvider = .claudeConnector) -> SlackAnnouncer {
    SlackAnnouncer(api: api, provider: provider, secrets: FakeSecrets(["user-token": "xoxp-1"]), stateStore: store,
                   now: { clock.value })
}

/// Mi PR #1 ya anunciado en C1, con una review sobre un commit viejo: toca "Updated".
private func announcedState(ts: String = slackTS(-80)) -> SlackState {
    var state = SlackState(baselineAt: at(-100))
    state.announcements["o/r#1"] = SlackAnnouncement(channelID: "C1", ts: ts, announcedAt: at(-80))
    return state
}

private let reviewedPR = myPR(reviews: [review("ana", .changesRequested, at: 10, commit: "old")])

enum SlackAntiDuplicateTests {
    static let cases: [TestCase] = [
        TestCase("anti-dup: con el conector, antes de cada anuncio se busca mi mensaje con el link del PR") {
            let api = FakeSlackAPI()
            // Un mensaje de otra persona con el mismo link no cuenta.
            api.messages["C1"] = [SlackMessage(ts: slackTS(-89), text: "<\(prURL)>", linkedURLs: [prURL], user: "U9")]
            let clock = Box(at(-90))
            let store = try newStore()
            let slack = await announcer(api, clock: clock, store: store)
            await slack.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.historyCalls.map(\.channel), ["C1"])
            try expectEqual(api.posts.count, 1)
            try expectEqual(store.load().announcements["o/r#1"]?.ts, "ts-1")
            try expectEqual(store.load().uncertain, [:])
        },
        TestCase("anti-dup: anuncio incierto y después se encuentra el mensaje → no hay segundo post") {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack("connector_uncertain"))]
            let clock = Box(at(-90))
            let store = try newStore()
            let slack = await announcer(api, clock: clock, store: store)
            await slack.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            try expect(store.load().uncertain["announce:o/r#1"] != nil)
            let issues = await slack.issues
            try expectEqual(issues.map(\.error), [.slack("connector_uncertain")])
            // El mensaje sí había salido.
            api.messages["C1"] = [SlackMessage(ts: slackTS(-90), text: "<\(prURL)|github.com/o/r/pull/1>", linkedURLs: [prURL], user: "U1")]
            clock.value = at(-79)
            await slack.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            try expectEqual(store.load().announcements["o/r#1"]?.ts, slackTS(-90))
            try expectEqual(store.load().uncertain, [:])
            try expectEqual(store.load().backoff, [:])
        },
        TestCase("anti-dup: un reinicio con la marca de incierto comprueba antes de postear (también con token)") {
            let api = FakeSlackAPI()
            api.results = [.failure(.network("connection reset"))]
            let clock = Box(at(-90))
            let store = try newStore()
            let first = await announcer(api, clock: clock, store: store, provider: .userToken)
            // La marca se guarda antes del post: un cierre a mitad de camino también la deja.
            let markedDuringPost = Box(false)
            api.onPost = { _ in markedDuringPost.value = store.load().uncertain["announce:o/r#1"] != nil }
            await first.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expect(markedDuringPost.value)
            try expectEqual(api.historyCalls.count, 0)
            try expect(store.load().uncertain["announce:o/r#1"] != nil)
            // Reinicio: otra instancia, mismo archivo de estado.
            let restartedAPI = FakeSlackAPI()
            restartedAPI.messages["C1"] = [SlackMessage(ts: slackTS(-90), text: prURL, user: "U1")]
            clock.value = at(-85)
            let restarted = await announcer(restartedAPI, clock: clock, store: store, provider: .userToken)
            await restarted.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(restartedAPI.historyCalls.count, 1)
            try expectEqual(restartedAPI.posts.count, 0)
            try expectEqual(store.load().announcements["o/r#1"]?.ts, slackTS(-90))
            try expectEqual(store.load().uncertain, [:])
        },
        TestCase("anti-dup: con token y sin marca no se lee el canal antes de anunciar") {
            let api = FakeSlackAPI()
            let store = try newStore()
            let slack = await announcer(api, clock: Box(at(-90)), store: store, provider: .userToken)
            await slack.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.historyCalls.count, 0)
            try expectEqual(api.authCalls, 0)
            try expectEqual(api.posts.count, 1)
        },
        TestCase("anti-dup: si la comprobación falla no se postea") {
            let api = FakeSlackAPI()
            api.historyErrors["C1"] = .slack("connector_invalid_output")
            let store = try newStore()
            let slack = await announcer(api, clock: Box(at(-90)), store: store)
            await slack.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 0)
            let issues = await slack.issues
            try expectEqual(issues.map(\.error), [.slack("connector_invalid_output")])
        },
        TestCase("anti-dup: 'Updated' incierto y luego encontrado en el hilo → no se repite") {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack("connector_uncertain"))]
            let clock = Box(at(30))
            let store = try newStore()
            try store.save(announcedState())
            let slack = await announcer(api, clock: clock, store: store)
            await slack.process(snapshot: slackSnap(reviewedPR), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            try expect(store.load().uncertain["update:o/r#1"] != nil)
            api.threads["C1/\(slackTS(-80))"] = [
                SlackMessage(ts: slackTS(-80), text: prURL, user: "U1"),
                SlackMessage(ts: slackTS(30, micros: "000200"), text: "Updated <\(prURL)|github.com/o/r/pull/1>", user: "U1"),
            ]
            clock.value = at(41)
            await slack.process(snapshot: slackSnap(reviewedPR), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            try expectEqual(api.threadCalls.map(\.ts), [slackTS(-80)])
            try expectEqual(store.load().announcements["o/r#1"]?.lastHandledReviewAt, at(10))
            try expectEqual(store.load().uncertain, [:])
        },
        TestCase("anti-dup: un 'Updated' igual pero anterior al intento, o de otra persona, no cuenta") {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack("connector_uncertain"))]
            let clock = Box(at(30))
            let store = try newStore()
            try store.save(announcedState())
            let slack = await announcer(api, clock: clock, store: store)
            await slack.process(snapshot: slackSnap(reviewedPR), config: slackConfig())
            api.threads["C1/\(slackTS(-80))"] = [
                SlackMessage(ts: slackTS(-60), text: "Updated \(prURL)", user: "U1"),
                SlackMessage(ts: slackTS(31), text: "Updated \(prURL)", user: "U9"),
            ]
            clock.value = at(41)
            await slack.process(snapshot: slackSnap(reviewedPR), config: slackConfig())
            try expectEqual(api.posts.count, 2)
            try expectEqual(store.load().uncertain, [:])
        },
        TestCase("anti-dup: 'commented xN' incierto y luego encontrado en el hilo → no se repite") {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack("connector_mismatch"))]
            let clock = Box(at(20))
            let store = try newStore()
            let parent = SlackMessageRef(channelID: "C1", ts: slackTS(-50))
            try store.save(tracked(ReviewTracking(message: parent, lastSearchAt: at(0))))
            let config = reactionsConfig {
                $0.reactOnReviewStart = false
                $0.reactOnFirstComment = false
                $0.reactOnApprove = false
            }
            let pr = theirPR(reviews: [review("me", .commented, at: 1, commit: "A"), review("me", .changesRequested, at: 5, commit: "B")])
            let slack = await announcer(api, clock: clock, store: store)
            await slack.process(snapshot: slackSnap(pr), config: config)
            try expectEqual(api.posts.map(\.text), ["commented x2"])
            try expect(store.load().uncertain["reply:o/r#1:2"] != nil)
            api.threads["C1/\(slackTS(-50))"] = [SlackMessage(ts: slackTS(20, micros: "000300"), text: "commented x2", user: "U1")]
            clock.value = at(31)
            await slack.process(snapshot: slackSnap(pr), config: config)
            try expectEqual(api.posts.count, 1)
            try expectEqual(store.load().reviewTracking["o/r#1"]?.roundsPosted, 2)
            try expectEqual(store.load().uncertain, [:])
        },
        TestCase("anti-dup: backoff por PR tras errores del conector: 10 → 30 → 60 min, con tope") {
            try expectEqual(SlackBackoff.next(after: nil, now: at(0)), SlackBackoff(failures: 1, until: at(10)))
            try expectEqual(SlackBackoff.next(after: SlackBackoff(failures: 1, until: at(10)), now: at(10)), SlackBackoff(failures: 2, until: at(40)))
            try expectEqual(SlackBackoff.next(after: SlackBackoff(failures: 2, until: at(40)), now: at(40)), SlackBackoff(failures: 3, until: at(100)))
            try expectEqual(SlackBackoff.next(after: SlackBackoff(failures: 3, until: at(100)), now: at(100)), SlackBackoff(failures: 4, until: at(160)))

            let api = FakeSlackAPI()
            api.results = [.failure(.slack("not_in_channel")), .failure(.slack("not_in_channel")), .failure(.slack("not_in_channel")),
                           .failure(.slack("not_in_channel"))]
            let clock = Box(at(-90))
            let store = try newStore()
            let slack = await announcer(api, clock: clock, store: store)
            func cycle(at minutes: Int) async -> [PRBarError] {
                clock.value = at(minutes)
                await slack.process(snapshot: slackSnap(myPR()), config: slackConfig())
                return await slack.issues.map(\.error)
            }
            _ = await cycle(at: -90)
            try expectEqual(api.posts.count, 1)
            // Dentro del backoff no se intenta nada, pero el error sigue a la vista.
            let waiting = await cycle(at: -81)
            try expectEqual(api.posts.count, 1)
            try expectEqual(waiting, [.slack("not_in_channel")])
            _ = await cycle(at: -80)
            try expectEqual(api.posts.count, 2)
            _ = await cycle(at: -51)
            try expectEqual(api.posts.count, 2)
            _ = await cycle(at: -50)
            try expectEqual(api.posts.count, 3)
            _ = await cycle(at: 9)
            try expectEqual(api.posts.count, 3)
            _ = await cycle(at: 10)
            try expectEqual(api.posts.count, 4)
            try expectEqual(store.load().backoff["o/r#1"], SlackBackoff(failures: 4, until: at(70)))
            // Un éxito borra el backoff.
            _ = await cycle(at: 70)
            try expectEqual(api.posts.count, 5)
            try expectEqual(store.load().backoff, [:])
        },
        TestCase("anti-dup: con token no hay backoff") {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack("not_in_channel"))]
            let clock = Box(at(-90))
            let store = try newStore()
            let slack = await announcer(api, clock: clock, store: store, provider: .userToken)
            await slack.process(snapshot: slackSnap(myPR()), config: slackConfig())
            clock.value = at(-89)
            await slack.process(snapshot: slackSnap(myPR()), config: slackConfig())
            try expectEqual(api.posts.count, 2)
            try expectEqual(store.load().backoff, [:])
        },
        TestCase("anti-dup: el ID propio se pide una vez y se guarda") {
            let api = FakeSlackAPI()
            let store = try newStore()
            let clock = Box(at(-90))
            let slack = await announcer(api, clock: clock, store: store)
            await slack.process(snapshot: slackSnap(myPR(number: 1), myPR(number: 2)), config: slackConfig())
            try expectEqual(api.authCalls, 1)
            try expectEqual(store.load().selfUserID, "U1")
            try expectEqual(api.posts.count, 2)
            // Cambiar de conexión lo olvida.
            await slack.use(api, provider: .userToken)
            try expectEqual(store.load().selfUserID, nil)
        },
    ]
}
