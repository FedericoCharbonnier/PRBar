import Foundation
import PRBarCore

private let repo = RepoRef(owner: "o", name: "r")

private func newStore() throws -> SlackStateStore {
    try SlackStateStore(url: temporaryDirectory().appendingPathComponent("slack-state.json"))
}

/// Mi PR #1 anunciado por PRBar en C1 (`ts` 111.1).
private func announcedStore() throws -> SlackStateStore {
    let store = try newStore()
    var state = SlackState(baselineAt: at(-100))
    state.announcements["o/r#1"] = SlackAnnouncement(channelID: "C1", ts: "111.1", announcedAt: at(-80))
    try store.save(state)
    return store
}

@MainActor
private func announcer(_ api: FakeSlackAPI, clock: Box<Date>, store: SlackStateStore) -> SlackAnnouncer {
    SlackAnnouncer(api: api, provider: .userToken, secrets: FakeSecrets(["user-token": "xoxp-1"]), stateStore: store,
                   now: { clock.value })
}

enum SlackMergedReplyTests {
    static let cases: [TestCase] = [
        TestCase("slack merged reply: PR anunciado → «Merged» en el hilo una sola vez") {
            let api = FakeSlackAPI()
            let store = try announcedStore()
            let slack = await announcer(api, clock: Box(at(0)), store: store)
            await slack.prMerged(myPR(), method: .squash, config: slackConfig())
            await slack.prMerged(myPR(), method: .squash, config: slackConfig())
            await slack.process(snapshot: slackSnap(), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            try expectEqual(api.posts[0].channel, "C1")
            try expectEqual(api.posts[0].threadTS, "111.1")
            try expectEqual(api.posts[0].text, "Merged :white_check_mark:")
            try expectEqual(store.load().mergedReplies["o/r#1"]?.postedAt, at(0))
            try expectEqual(store.load().uncertain, [:])
            let issues = await slack.issues
            try expectEqual(issues, [])
        },
        TestCase("slack merged reply: un PR que PRBar no anunció no responde nada") {
            let api = FakeSlackAPI()
            let store = try newStore()
            let slack = await announcer(api, clock: Box(at(0)), store: store)
            await slack.prMerged(myPR(), method: .squash, config: slackConfig())
            try expectEqual(api.posts.count, 0)
            try expectEqual(store.load().mergedReplies, [:])
        },
        TestCase("slack merged reply: con el interruptor o Slack apagados no responde") {
            let api = FakeSlackAPI()
            let store = try announcedStore()
            let slack = await announcer(api, clock: Box(at(0)), store: store)
            var off = slackConfig()
            off.slack.postMerged = false
            await slack.prMerged(myPR(), method: .squash, config: off)
            await slack.prMerged(myPR(), method: .squash, config: slackConfig(enabled: false))
            try expectEqual(api.posts.count, 0)
            try expectEqual(store.load().mergedReplies, [:])
        },
        TestCase("slack merged reply: plantilla propia con {method} y {title}") {
            let api = FakeSlackAPI()
            let store = try announcedStore()
            let slack = await announcer(api, clock: Box(at(0)), store: store)
            var config = slackConfig()
            config.slack.mergedTemplate = "Merged via {method}: {title}"
            await slack.prMerged(myPR(), method: .rebase, config: config)
            try expectEqual(api.posts.map(\.text), ["Merged via rebase: PR 1"])
        },
        TestCase("slack merged reply: si Slack falla queda el issue y se reintenta en el próximo ciclo") {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack("not_in_channel"))]
            let store = try announcedStore()
            let slack = await announcer(api, clock: Box(at(0)), store: store)
            await slack.prMerged(myPR(), method: .squash, config: slackConfig())
            let firstIssues = await slack.issues
            try expectEqual(firstIssues.map(\.error), [.slack("not_in_channel")])
            try expectEqual(store.load().mergedReplies["o/r#1"]?.postedAt, nil)
            await slack.process(snapshot: slackSnap(), config: slackConfig())
            try expectEqual(api.posts.count, 2)
            try expectEqual(api.posts[1].threadTS, "111.1")
            try expect(store.load().mergedReplies["o/r#1"]?.postedAt != nil)
            let secondIssues = await slack.issues
            try expectEqual(secondIssues, [])
        },
        TestCase("slack merged reply: un intento dudoso que sí salió no se repite") {
            let api = FakeSlackAPI()
            api.results = [.failure(.network("timeout"))]
            let store = try announcedStore()
            let clock = Box(at(0))
            let slack = await announcer(api, clock: clock, store: store)
            await slack.prMerged(myPR(), method: .squash, config: slackConfig())
            try expectEqual(store.load().uncertain["merged:o/r#1"], at(0))
            // El mensaje sí había salido.
            api.threads["C1/111.1"] = [
                SlackMessage(ts: "111.1", text: "root", user: "U1"),
                SlackMessage(ts: "\(Int(at(0).timeIntervalSince1970)).000200", text: "Merged :white_check_mark:", user: "U1"),
            ]
            clock.value = at(5)
            await slack.process(snapshot: slackSnap(), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            try expectEqual(store.load().mergedReplies["o/r#1"]?.postedAt, at(5))
            try expectEqual(store.load().uncertain, [:])
        },
        TestCase("slack merged reply: el planner reintenta un día como máximo y nunca lo ya publicado") {
            var state = SlackState(baselineAt: .distantPast)
            state.mergedReplies["o/r#1"] = MergedReply(repo: repo, channelID: "C1", threadTS: "111.1", text: "Merged", requestedAt: at(0))
            let action = SlackAction.merged(prID: "o/r#1", repo: repo, channelID: "C1", threadTS: "111.1", text: "Merged")
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(), config: slackConfig(), state: state, now: at(60)).actions, [action])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(), config: slackConfig(), state: state, now: at(60 * 25)).actions, [])
            var off = slackConfig()
            off.slack.postMerged = false
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(), config: off, state: state, now: at(60)).actions, [])
            state.mergedReplies["o/r#1"]?.postedAt = at(1)
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(), config: slackConfig(), state: state, now: at(60)).actions, [])
            try expectEqual(SlackState.uncertainKey(for: action), "merged:o/r#1")
        },
        TestCase("slack merged reply: queueMergedReply lo deja guardado enseguida, sin esperar a Slack") {
            let api = FakeSlackAPI()
            let store = try announcedStore()
            let slack = await announcer(api, clock: Box(at(0)), store: store)
            let queued = await slack.queueMergedReply(myPR(), method: .merge, config: slackConfig())
            try expect(queued)
            try expectEqual(store.load().mergedReplies["o/r#1"]?.text, "Merged :white_check_mark:")
            try expectEqual(api.posts.count, 0)
            let again = await slack.queueMergedReply(myPR(), method: .merge, config: slackConfig())
            try expect(!again)
            await slack.postQueued(config: slackConfig())
            try expectEqual(api.posts.map(\.threadTS), ["111.1"])
        },
        TestCase("slack merged reply: con el conector de Claude sale sin token y un error dudoso se verifica antes de reintentar") {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack("connector_timeout"))]
            let store = try announcedStore()
            let clock = Box(at(0))
            let slack = await announcer(api, clock: clock, store: store)
            await slack.use(api, provider: .claudeConnector)
            var config = slackConfig()
            config.slack.provider = .claudeConnector
            await slack.prMerged(myPR(), method: .squash, config: config)
            try expectEqual(api.posts.map(\.threadTS), ["111.1"])
            try expectEqual(api.tokens, [""])
            try expectEqual(store.load().uncertain["merged:o/r#1"], at(0))
            try expect(store.load().backoff["o/r#1"] != nil)
            // Había salido: pasado el backoff se encuentra en el hilo y no se publica de nuevo.
            api.threads["C1/111.1"] = [
                SlackMessage(ts: "111.1", text: "root", user: "U1"),
                SlackMessage(ts: "\(Int(at(0).timeIntervalSince1970)).000200", text: "Merged :white_check_mark:", user: "U1"),
            ]
            clock.value = at(60)
            await slack.process(snapshot: slackSnap(), config: config)
            try expectEqual(api.posts.count, 1)
            try expectEqual(store.load().mergedReplies["o/r#1"]?.postedAt, at(60))
            try expectEqual(store.load().uncertain, [:])
        },
        TestCase("slack merged reply: los pedidos viejos se borran pasado el reintento y un margen") {
            var state = SlackState(baselineAt: .distantPast)
            state.mergedReplies["o/r#1"] = MergedReply(repo: repo, channelID: "C1", threadTS: "1", text: "Merged", requestedAt: at(0))
            state.mergedReplies["o/r#2"] = MergedReply(repo: repo, channelID: "C1", threadTS: "2", text: "Merged", requestedAt: at(60 * 30),
                                                       postedAt: at(60 * 30))
            let retention = SlackState.mergedReplyRetention
            try expect(retention > SlackPlanner.mergedReplyWindow)
            try expect(!state.pruneMergedReplies(now: at(0).addingTimeInterval(retention)))
            try expect(state.pruneMergedReplies(now: at(1).addingTimeInterval(retention)))
            try expectEqual(state.mergedReplies.keys.sorted(), ["o/r#2"])
        },
        TestCase("slack merged reply: el ciclo borra y guarda los pedidos viejos") {
            let api = FakeSlackAPI()
            let store = try announcedStore()
            var state = store.load()
            state.mergedReplies["o/r#9"] = MergedReply(repo: repo, channelID: "C1", threadTS: "9", text: "Merged", requestedAt: at(0), postedAt: at(0))
            try store.save(state)
            let slack = await announcer(api, clock: Box(at(1).addingTimeInterval(SlackState.mergedReplyRetention)), store: store)
            await slack.process(snapshot: slackSnap(), config: slackConfig())
            try expectEqual(store.load().mergedReplies, [:])
        },
        TestCase("slack merged reply: el estado viejo sin mergedReplies se lee vacío") {
            let state = try JSONCoding.decoder.decode(SlackState.self, from: Data(#"{"baselineAt":"2027-01-15T08:00:00Z"}"#.utf8))
            try expectEqual(state.mergedReplies, [:])
        },
    ]
}
