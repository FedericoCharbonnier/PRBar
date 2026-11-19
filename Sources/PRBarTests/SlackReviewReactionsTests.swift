import Foundation
import PRBarCore

private let repo = RepoRef(owner: "o", name: "r")
private let prURL = URL(string: "https://github.com/o/r/pull/12")!
private let ref = SlackMessageRef(channelID: "C1", ts: "100.1")

private func message(_ text: String, urls: [String] = []) -> SlackMessage {
    SlackMessage(ts: "1.0", text: text, linkedURLs: urls)
}

/// Config con canal y reacciones activas desde at(-100).
func reactionsConfig(_ change: (inout SlackSettings) -> Void = { _ in }) -> AppConfig {
    var config = slackConfig()
    config.slack.reviewReactionsEnabledAt = at(-100)
    change(&config.slack)
    return config
}

/// PR de "juan" (ajeno para "me").
func theirPR(number: Int = 1, reviews: [PRReview] = []) -> PullRequest {
    makePR(number: number, author: "juan", reviews: reviews)
}

func tracked(_ tracking: ReviewTracking, id: String = "o/r#1") -> SlackState {
    var state = SlackState(baselineAt: .distantPast)
    state.reviewTracking[id] = tracking
    return state
}

private let found = ReviewTracking(message: ref, lastSearchAt: at(0))

private func react(_ kind: ReviewReactionKind, _ emoji: String) -> SlackAction {
    .react(prID: "o/r#1", repo: repo, channelName: "C1", ref: ref, emoji: emoji, kind: kind)
}

private func reply(_ round: Int) -> SlackAction {
    .reply(prID: "o/r#1", repo: repo, channelName: "C1", ref: ref, text: "commented x\(round)", round: round)
}

private let find = SlackAction.findMessage(prID: "o/r#1", repo: repo, channelID: "C1", channelName: "C1",
                                           prURL: URL(string: "https://github.com/o/r/pull/1")!)

private func plan(_ pr: PullRequest, _ config: AppConfig = reactionsConfig(), state: SlackState = SlackState(baselineAt: .distantPast), now: Int = 0) -> [SlackAction] {
    SlackPlanner.plan(snapshot: slackSnap(pr), config: config, state: state, now: at(now)).actions
}


@MainActor
private func reactionsAnnouncer(
    _ api: FakeSlackAPI, clock: Box<Date>, store: SlackStateStore? = nil
) throws -> (SlackAnnouncer, SlackStateStore) {
    let store = try store ?? SlackStateStore(url: temporaryDirectory().appendingPathComponent("slack-state.json"))
    let announcer = SlackAnnouncer(api: api, secrets: FakeSecrets(["user-token": "xoxp-1"]), stateStore: store, now: { clock.value })
    return (announcer, store)
}

private let prLink = "<https://github.com/o/r/pull/1>"

/// Canal con el anuncio del PR #1 (el más antiguo es el que cuenta), un repost más nuevo y ruido.
private func channelWithPR() -> [String: [SlackMessage]] {
    ["C1": [
        SlackMessage(ts: "300.0", text: "otra vez \(prLink)"),
        SlackMessage(ts: "250.0", text: "<https://github.com/o/r/pull/10>"),
        SlackMessage(ts: "200.0", text: "nuevo PR \(prLink)"),
    ]]
}

private let threeRounds = [review("me", .commented, at: 1, commit: "A"), review("me", .changesRequested, at: 5, commit: "B"),
                           review("me", .approved, at: 9, commit: "C")]

private func reactionNames(_ api: FakeSlackAPI) -> [String] { api.reactions.map(\.name) }

enum SlackReviewReactionsTests {
    static let cases: [TestCase] = [
        TestCase("pr link matcher: formatos de Slack, http/https, www, mayúsculas y sufijos") {
            let matching = [
                "<https://github.com/o/r/pull/12>",
                "mirá <https://github.com/o/r/pull/12|o/r#12> porfa",
                "http://github.com/o/r/pull/12",
                "<https://www.github.com/O/R/pull/12/>",
                "https://github.com/o/r/pull/12/files",
                "<https://github.com/o/r/pull/12/commits/abc123|commit>",
                "https://github.com/o/r/pull/12/checks",
                "https://github.com/o/r/pull/12#discussion_r99",
                "github.com/o/r/pull/12",
            ]
            for text in matching {
                try expect(PRLinkMatcher.matches(message(text), prURL: prURL), text)
            }
            try expect(PRLinkMatcher.matches(message("<https://github.com/o/r/pull/12>"), prURL: URL(string: "https://github.com/O/R/pull/12")!))
        },
        TestCase("pr link matcher: otro número, repo, owner o tipo de link no matchea") {
            let other = [
                "https://github.com/o/r/pull/123",
                "https://github.com/o/r/pull/1",
                "https://github.com/o/r2/pull/12",
                "https://github.com/x/r/pull/12",
                "https://github.com/o/r/issues/12",
                "https://gitlab.com/o/r/pull/12",
                "PR 12 de o/r, sin link",
                "",
            ]
            for text in other {
                try expect(!PRLinkMatcher.matches(message(text), prURL: prURL), text)
            }
        },
        TestCase("pr link matcher: busca también en attachments y blocks") {
            try expect(PRLinkMatcher.matches(message("nuevo PR", urls: ["https://example.com", "https://github.com/o/r/pull/12/files"]), prURL: prURL))
            try expect(!PRLinkMatcher.matches(message("nuevo PR", urls: ["https://github.com/o/r/pull/120"]), prURL: prURL))
        },
        TestCase("review rounds: mismo commit = 1 ronda, commit nuevo = 2") {
            let sameCommit = [review("me", .commented, at: 1, commit: "A"), review("me", .commented, at: 2, commit: "A"),
                              review("me", .changesRequested, at: 3, commit: "A")]
            try expectEqual(ReviewRounds.compute(reviews: sameCommit, me: "me", since: at(0)),
                            ReviewRoundsSummary(commentRounds: 1, approved: false, firstReviewAt: at(1)))
            let newCommit = sameCommit + [review("me", .commented, at: 10, commit: "B")]
            try expectEqual(ReviewRounds.compute(reviews: newCommit, me: "Me", since: at(0)).commentRounds, 2)
        },
        TestCase("review rounds: sin commitOID cada review es una ronda; otros autores y bots no cuentan") {
            let reviews = [review("me", .commented, at: 1), review("me", .commented, at: 2), review("me", .commented, at: 3, commit: "A"),
                           review("ana", .commented, at: 4, commit: "B"), review("me", .commented, at: 5, bot: true, commit: "C")]
            try expectEqual(ReviewRounds.compute(reviews: reviews, me: "me", since: at(0)).commentRounds, 3)
        },
        TestCase("review rounds: approved y el filtro por since") {
            let reviews = [review("me", .commented, at: -10, commit: "A"), review("me", .approved, at: -5, commit: "A"),
                           review("me", .commented, at: 5, commit: "B")]
            try expectEqual(ReviewRounds.compute(reviews: reviews, me: "me", since: at(0)),
                            ReviewRoundsSummary(commentRounds: 1, approved: false, firstReviewAt: at(5)))
            try expectEqual(ReviewRounds.compute(reviews: reviews, me: "me", since: at(-20)),
                            ReviewRoundsSummary(commentRounds: 2, approved: true, firstReviewAt: at(-10)))
            let approvedOnly = [review("me", .approved, at: 1, commit: "A")]
            try expectEqual(ReviewRounds.compute(reviews: approvedOnly, me: "me", since: at(0)),
                            ReviewRoundsSummary(commentRounds: 0, approved: true, firstReviewAt: at(1)))
            try expectEqual(ReviewRounds.compute(reviews: [], me: "me", since: at(0)),
                            ReviewRoundsSummary(commentRounds: 0, approved: false, firstReviewAt: nil))
        },
        TestCase("slack planner reviews: sin mensaje busca; sin nada que reaccionar no busca") {
            let reviewed = theirPR(reviews: [review("me", .commented, at: 1, commit: "A")])
            try expectEqual(plan(reviewed), [find])
            try expectEqual(plan(theirPR()), [])
            try expectEqual(plan(theirPR(), state: tracked(ReviewTracking(pendingEyes: true))), [find])
        },
        TestCase("slack planner reviews: una búsqueda reciente no se repite hasta pasados 10 minutos") {
            let reviewed = theirPR(reviews: [review("me", .commented, at: 1, commit: "A")])
            let state = tracked(ReviewTracking(lastSearchAt: at(0)))
            try expectEqual(plan(reviewed, state: state, now: 9), [])
            try expectEqual(plan(reviewed, state: state, now: 10), [find])
        },
        TestCase("slack planner reviews: reacciones en orden 👀, 💬, rondas y aprobado") {
            let pr = theirPR(reviews: [review("me", .commented, at: 1, commit: "A"), review("me", .changesRequested, at: 5, commit: "B"),
                                       review("me", .approved, at: 9, commit: "C")])
            try expectEqual(plan(pr, state: tracked(found)),
                            [react(.eyes, "eyes"), react(.comment, "speech_balloon"), reply(2), react(.approved, "approved")])
        },
        TestCase("slack planner reviews: ronda 3 recién descubierta publica x2 y x3; lo hecho no se repite") {
            let pr = theirPR(reviews: [review("me", .commented, at: 1, commit: "A"), review("me", .commented, at: 5, commit: "B"),
                                       review("me", .commented, at: 9, commit: "C")])
            var tracking = found
            tracking.reacted = ["eyes", "comment"]
            try expectEqual(plan(pr, state: tracked(tracking)), [reply(2), reply(3)])
            tracking.roundsPosted = 2
            try expectEqual(plan(pr, state: tracked(tracking)), [reply(3)])
            tracking.roundsPosted = 3
            try expectEqual(plan(pr, state: tracked(tracking)), [])
        },
        TestCase("slack planner reviews: 👀 pendiente por apretar Review en PRBar") {
            var tracking = found
            tracking.pendingEyes = true
            try expectEqual(plan(theirPR(), state: tracked(tracking)), [react(.eyes, "eyes")])
        },
        TestCase("slack planner reviews: un toggle apagado no genera su acción; emojis y plantilla configurables") {
            let pr = theirPR(reviews: [review("me", .commented, at: 1, commit: "A"), review("me", .commented, at: 5, commit: "B"),
                                       review("me", .approved, at: 9, commit: "C")])
            let state = tracked(found)
            try expectEqual(plan(pr, reactionsConfig { $0.reactOnReviewStart = false }, state: state),
                            [react(.comment, "speech_balloon"), reply(2), react(.approved, "approved")])
            try expectEqual(plan(pr, reactionsConfig { $0.reactOnFirstComment = false }, state: state),
                            [react(.eyes, "eyes"), reply(2), react(.approved, "approved")])
            try expectEqual(plan(pr, reactionsConfig { $0.postRoundMessages = false }, state: state),
                            [react(.eyes, "eyes"), react(.comment, "speech_balloon"), react(.approved, "approved")])
            try expectEqual(plan(pr, reactionsConfig { $0.reactOnApprove = false }, state: state),
                            [react(.eyes, "eyes"), react(.comment, "speech_balloon"), reply(2)])
            let custom = reactionsConfig {
                $0.eyesEmoji = ":Looking:"
                $0.approvedEmoji = "white_check_mark"
                $0.roundTemplate = "otra ronda ({n})"
                $0.reactOnFirstComment = false
            }
            try expectEqual(plan(pr, custom, state: state), [
                react(.eyes, "looking"),
                .reply(prID: "o/r#1", repo: repo, channelName: "C1", ref: ref, text: "otra ronda (2)", round: 2),
                react(.approved, "white_check_mark"),
            ])
        },
        TestCase("slack planner reviews: reviews anteriores a since se ignoran; sin fecha de activación no hay nada") {
            let old = theirPR(reviews: [review("me", .commented, at: -110, commit: "A"), review("me", .approved, at: -105, commit: "A")])
            try expectEqual(plan(old, state: tracked(found)), [])
            try expectEqual(plan(old), [])
            let mixed = theirPR(reviews: [review("me", .commented, at: -110, commit: "A"), review("me", .commented, at: 5, commit: "B")])
            // Solo cuenta la ronda nueva: es la primera, no "x2".
            try expectEqual(plan(mixed, state: tracked(found)), [react(.eyes, "eyes"), react(.comment, "speech_balloon")])
            var neverEnabled = slackConfig()
            neverEnabled.slack.reviewReactionsEnabledAt = nil
            try expectEqual(plan(mixed, neverEnabled, state: tracked(ReviewTracking(message: ref, pendingEyes: true))), [])
            // Encender Slack o el baseline del estado también cortan.
            var laterSlack = reactionsConfig()
            laterSlack.slack.enabledAt = at(10)
            try expectEqual(plan(mixed, laterSlack, state: tracked(found)), [])
            var baseline = tracked(found)
            baseline.baselineAt = at(10)
            try expectEqual(plan(mixed, state: baseline), [])
        },
        TestCase("slack planner reviews: mis propios PRs no reaccionan") {
            var tracking = found
            tracking.pendingEyes = true
            let mine = myPR(reviews: [review("me", .commented, at: 1, commit: "A"), review("me", .approved, at: 2, commit: "A")])
            var state = tracked(tracking)
            state.announcements["o/r#1"] = SlackAnnouncement(channelID: "C1", ts: "1.1", announcedAt: at(0))
            try expectEqual(plan(mine, state: state), [])
        },
        TestCase("slack planner reviews: sin canal o sin scope fresco no hace nada") {
            let pr = theirPR(reviews: [review("me", .commented, at: 1, commit: "A")])
            var noChannel = slackConfig(channel: nil)
            noChannel.slack.reviewReactionsEnabledAt = at(-100)
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(pr), config: noChannel, state: tracked(found)).actions, [])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(pr, fetched: false), config: reactionsConfig(), state: tracked(found)).actions, [])
        },
        TestCase("slack planner: announceNewPRs y postUpdated apagados no publican") {
            let fresh = SlackState(baselineAt: .distantPast)
            try expectEqual(plan(myPR(), reactionsConfig { $0.announceNewPRs = false }, state: fresh), [])
            var announced = SlackState(baselineAt: .distantPast)
            announced.announcements["o/r#1"] = SlackAnnouncement(channelID: "C1", ts: "1.1", announcedAt: at(0))
            let reviewed = myPR(reviews: [review("ana", .changesRequested, at: 10, commit: "old")])
            try expectEqual(plan(reviewed, reactionsConfig { $0.postUpdated = false }, state: announced), [])
            try expectEqual(plan(reviewed, state: announced).count, 1)
        },
        TestCase("slack reactions: ciclo completo con búsqueda, 👀, 💬, x2 y approved sin duplicar") {
            let api = FakeSlackAPI()
            api.messages = channelWithPR()
            let clock = Box(at(-90))
            let (announcer, store) = try await reactionsAnnouncer(api, clock: clock)
            clock.value = at(10)
            let snapshot = slackSnap(theirPR(reviews: threeRounds))
            await announcer.process(snapshot: snapshot, config: reactionsConfig())
            try expectEqual(api.historyCalls.count, 1)
            try expectEqual(api.historyCalls[0].channel, "C1")
            try expectEqual(api.historyCalls[0].oldest, at(10).addingTimeInterval(-30 * 86_400))
            try expectEqual(reactionNames(api), ["eyes", "speech_balloon", "approved"])
            try expect(api.reactions.allSatisfy { $0.channel == "C1" && $0.ts == "200.0" })
            try expectEqual(api.posts.count, 1)
            try expectEqual(api.posts[0].text, "commented x2")
            try expectEqual(api.posts[0].threadTS, "200.0")
            try expectEqual(api.tokens.allSatisfy { $0 == "xoxp-1" }, true)
            let tracking = store.load().reviewTracking["o/r#1"]
            try expectEqual(tracking?.message, SlackMessageRef(channelID: "C1", ts: "200.0"))
            try expectEqual(tracking?.reacted, ["eyes", "comment", "approved"])
            try expectEqual(tracking?.roundsPosted, 2)
            let issues = await announcer.issues
            try expectEqual(issues, [])

            clock.value = at(30)
            await announcer.process(snapshot: snapshot, config: reactionsConfig())
            try expectEqual(api.historyCalls.count, 1)
            try expectEqual(api.reactions.count, 3)
            try expectEqual(api.posts.count, 1)

            // Ronda nueva: solo x3.
            let fourth = theirPR(reviews: threeRounds + [review("me", .commented, at: 20, commit: "D")])
            await announcer.process(snapshot: slackSnap(fourth), config: reactionsConfig())
            try expectEqual(api.posts.map(\.text), ["commented x2", "commented x3"])
            try expectEqual(api.reactions.count, 3)
        },
        TestCase("slack reactions: reiniciar con el mismo estado no duplica") {
            let api = FakeSlackAPI()
            api.messages = channelWithPR()
            let clock = Box(at(-90))
            let (first, store) = try await reactionsAnnouncer(api, clock: clock)
            clock.value = at(10)
            let snapshot = slackSnap(theirPR(reviews: threeRounds))
            await first.process(snapshot: snapshot, config: reactionsConfig())
            clock.value = at(60)
            let (second, _) = try await reactionsAnnouncer(api, clock: clock, store: store)
            await second.process(snapshot: snapshot, config: reactionsConfig())
            try expectEqual(api.historyCalls.count, 1)
            try expectEqual(api.reactions.count, 3)
            try expectEqual(api.posts.count, 1)
        },
        TestCase("slack reactions: sin mensaje en el canal se reintenta cada 10 minutos") {
            let api = FakeSlackAPI()
            let clock = Box(at(-90))
            let (announcer, store) = try await reactionsAnnouncer(api, clock: clock)
            clock.value = at(10)
            let snapshot = slackSnap(theirPR(reviews: threeRounds))
            await announcer.process(snapshot: snapshot, config: reactionsConfig())
            try expectEqual(store.load().reviewTracking["o/r#1"]?.lastSearchAt, at(10))
            try expectEqual(store.load().reviewTracking["o/r#1"]?.message, nil)
            clock.value = at(19)
            await announcer.process(snapshot: snapshot, config: reactionsConfig())
            try expectEqual(api.historyCalls.count, 1)
            api.messages = channelWithPR()
            clock.value = at(20)
            await announcer.process(snapshot: snapshot, config: reactionsConfig())
            try expectEqual(api.historyCalls.count, 2)
            try expectEqual(reactionNames(api), ["eyes", "speech_balloon", "approved"])
        },
        TestCase("slack reactions: varios PRs del mismo canal hacen una sola búsqueda") {
            let api = FakeSlackAPI()
            api.messages = ["C1": [SlackMessage(ts: "1.0", text: prLink), SlackMessage(ts: "2.0", text: "<https://github.com/o/r/pull/2>")]]
            let clock = Box(at(-90))
            let (announcer, _) = try await reactionsAnnouncer(api, clock: clock)
            clock.value = at(10)
            let reviewed = [review("me", .approved, at: 1, commit: "A")]
            await announcer.process(snapshot: slackSnap(theirPR(number: 1, reviews: reviewed), theirPR(number: 2, reviews: reviewed)),
                                    config: reactionsConfig())
            try expectEqual(api.historyCalls.count, 1)
            try expectEqual(api.reactions.map { "\($0.ts) \($0.name)" }, ["1.0 eyes", "1.0 approved", "2.0 eyes", "2.0 approved"])
        },
        TestCase("slack reactions: reviewStarted reacciona con 👀 y lo persiste") {
            let api = FakeSlackAPI()
            api.messages = channelWithPR()
            let clock = Box(at(-90))
            let (announcer, store) = try await reactionsAnnouncer(api, clock: clock)
            clock.value = at(10)
            let item = ClassifiedPR(pr: theirPR(), category: .other, account: "me")
            await announcer.reviewStarted(item: item, config: reactionsConfig())
            try expectEqual(reactionNames(api), ["eyes"])
            try expectEqual(api.reactions.first?.ts, "200.0")
            let tracking = store.load().reviewTracking["o/r#1"]
            try expectEqual(tracking?.reacted, ["eyes"])
            try expectEqual(tracking?.pendingEyes, false)
            // Repetirlo no vuelve a reaccionar.
            await announcer.reviewStarted(item: item, config: reactionsConfig())
            try expectEqual(api.reactions.count, 1)
        },
        TestCase("slack reactions: reviewStarted sin mensaje deja 👀 pendiente y reacciona al encontrarlo") {
            let api = FakeSlackAPI()
            let clock = Box(at(-90))
            let (announcer, store) = try await reactionsAnnouncer(api, clock: clock)
            clock.value = at(10)
            let item = ClassifiedPR(pr: theirPR(), category: .other, account: "me")
            await announcer.reviewStarted(item: item, config: reactionsConfig())
            try expectEqual(api.reactions.count, 0)
            try expectEqual(store.load().reviewTracking["o/r#1"]?.pendingEyes, true)
            // Tras reiniciar sigue pendiente.
            api.messages = channelWithPR()
            clock.value = at(25)
            let (restarted, _) = try await reactionsAnnouncer(api, clock: clock, store: store)
            await restarted.process(snapshot: slackSnap(theirPR()), config: reactionsConfig())
            try expectEqual(reactionNames(api), ["eyes"])
            try expectEqual(store.load().reviewTracking["o/r#1"]?.pendingEyes, false)
        },
        TestCase("slack reactions: reviewStarted no hace nada en PRs propios, sin canal o con el toggle apagado") {
            let api = FakeSlackAPI()
            api.messages = channelWithPR()
            let clock = Box(at(-90))
            let (announcer, store) = try await reactionsAnnouncer(api, clock: clock)
            clock.value = at(10)
            await announcer.reviewStarted(item: ClassifiedPR(pr: myPR(), category: .other, account: "me"), config: reactionsConfig())
            let other = ClassifiedPR(pr: theirPR(), category: .other, account: "me")
            await announcer.reviewStarted(item: other, config: reactionsConfig { $0.reactOnReviewStart = false })
            var noChannel = slackConfig(channel: nil)
            noChannel.slack.reviewReactionsEnabledAt = at(-100)
            await announcer.reviewStarted(item: other, config: noChannel)
            try expectEqual(api.reactions.count, 0)
            try expectEqual(store.load().reviewTracking, [:])
        },
        TestCase("slack reactions: reviewStarted conserva el resto del último snapshot y sus issues") {
            let api = FakeSlackAPI()
            api.messages = channelWithPR()
            api.historyErrors = ["C1": .slack("missing_scope")]
            let clock = Box(at(-90))
            let (announcer, _) = try await reactionsAnnouncer(api, clock: clock)
            clock.value = at(10)
            let reviewed = theirPR(number: 2, reviews: [review("me", .approved, at: 1, commit: "A")])
            await announcer.process(snapshot: slackSnap(reviewed), config: reactionsConfig())
            let before = await announcer.issues
            try expectEqual(before.map(\.message), ["Slack · r: Your Slack token is missing a scope (needs channels:history, groups:history)"])
            await announcer.reviewStarted(item: ClassifiedPR(pr: theirPR(), category: .other, account: "me"), config: reactionsConfig())
            // El #2 ya se buscó hace menos de 10 minutos; el #1 se busca y vuelve a fallar: un solo issue por canal.
            try expectEqual(api.historyCalls.count, 2)
            let after = await announcer.issues
            try expectEqual(after.count, 1)
        },
        TestCase("slack reactions: emoji inexistente → issue visible, sin reintentar hasta cambiar el emoji") {
            let api = FakeSlackAPI()
            api.messages = channelWithPR()
            api.reactionErrors = ["approved": .slack("invalid_name")]
            let clock = Box(at(-90))
            let (announcer, store) = try await reactionsAnnouncer(api, clock: clock)
            clock.value = at(10)
            let snapshot = slackSnap(theirPR(reviews: threeRounds))
            await announcer.process(snapshot: snapshot, config: reactionsConfig())
            try expectEqual(reactionNames(api), ["eyes", "speech_balloon", "approved"])
            try expectEqual(api.posts.count, 1)
            let issues = await announcer.issues
            try expectEqual(issues.map(\.message), ["Slack: Emoji :approved: doesn't exist in this workspace"])
            try expectEqual(store.load().reviewTracking["o/r#1"]?.reacted, ["eyes", "comment"])

            await announcer.process(snapshot: snapshot, config: reactionsConfig())
            try expectEqual(api.reactions.count, 3)
            let stillThere = await announcer.issues
            try expectEqual(stillThere.count, 1)

            // Apagar la reacción saca el issue; cambiar el emoji la reintenta.
            await announcer.process(snapshot: snapshot, config: reactionsConfig { $0.reactOnApprove = false })
            let off = await announcer.issues
            try expectEqual(off, [])
            await announcer.process(snapshot: snapshot, config: reactionsConfig { $0.approvedEmoji = "white_check_mark" })
            try expectEqual(reactionNames(api), ["eyes", "speech_balloon", "approved", "white_check_mark"])
            let fixed = await announcer.issues
            try expectEqual(fixed, [])
            try expectEqual(store.load().reviewTracking["o/r#1"]?.reacted, ["eyes", "comment", "approved"])
        },
        TestCase("slack reactions: el estado se guarda después de cada acción") {
            let api = FakeSlackAPI()
            api.messages = channelWithPR()
            let clock = Box(at(-90))
            let (announcer, store) = try await reactionsAnnouncer(api, clock: clock)
            clock.value = at(10)
            let seen = Box<[Set<String>]>([])
            api.onReaction = { _ in seen.value.append(store.load().reviewTracking["o/r#1"]?.reacted ?? []) }
            await announcer.process(snapshot: slackSnap(theirPR(reviews: threeRounds)), config: reactionsConfig())
            // Durante cada reacción, el estado en disco ya tiene el mensaje y las reacciones anteriores.
            try expectEqual(seen.value, [[], ["eyes"], ["eyes", "comment"]])
            try expectEqual(store.load().reviewTracking["o/r#1"]?.message?.ts, "200.0")
        },
        TestCase("slack reactions: rate limit corta el ciclo; not_in_channel da la pista de unirse") {
            let api = FakeSlackAPI()
            api.messages = channelWithPR()
            api.reactionErrors = ["eyes": .rateLimited(resetAt: at(15))]
            let clock = Box(at(-90))
            let (announcer, _) = try await reactionsAnnouncer(api, clock: clock)
            clock.value = at(10)
            await announcer.process(snapshot: slackSnap(theirPR(reviews: threeRounds)), config: reactionsConfig())
            try expectEqual(api.reactions.count, 1)
            try expectEqual(api.posts.count, 0)
            let limited = await announcer.issues
            try expectEqual(limited.map(\.error), [.rateLimited(resetAt: at(15))])

            api.reactionErrors = ["eyes": .slack("not_in_channel")]
            await announcer.process(snapshot: slackSnap(theirPR(reviews: threeRounds)), config: reactionsConfig())
            let notIn = await announcer.issues
            try expectEqual(notIn.map(\.message), ["Slack · r: Join #C1 to post there"])
            try expectEqual(reactionNames(api), ["eyes", "eyes", "speech_balloon", "approved"])
        },
        TestCase("slack reactions: mensaje borrado → se vuelve a buscar") {
            let api = FakeSlackAPI()
            api.messages = channelWithPR()
            api.reactionErrors = ["eyes": .slack("message_not_found")]
            let clock = Box(at(-90))
            let (announcer, store) = try await reactionsAnnouncer(api, clock: clock)
            clock.value = at(10)
            await announcer.process(snapshot: slackSnap(theirPR(reviews: [review("me", .commented, at: 1, commit: "A")])), config: reactionsConfig())
            try expectEqual(store.load().reviewTracking["o/r#1"]?.message, nil)
        },
        TestCase("slack state: reviewTracking se lee de forma tolerante") {
            let json = #"{"baselineAt":"2026-11-18T10:00:00Z","reviewTracking":{"o/r#1":{"message":{"channelID":"C1","ts":"1.1"},"reacted":["eyes"]},"o/r#2":{}}}"#
            let state = try JSONCoding.decoder.decode(SlackState.self, from: Data(json.utf8))
            try expectEqual(state.reviewTracking["o/r#1"], ReviewTracking(message: SlackMessageRef(channelID: "C1", ts: "1.1"), reacted: ["eyes"]))
            try expectEqual(state.reviewTracking["o/r#2"], ReviewTracking())
            var full = SlackState(baselineAt: t0)
            full.reviewTracking["o/r#3"] = ReviewTracking(message: ref, lastSearchAt: t0, reacted: ["comment"], roundsPosted: 3, pendingEyes: true)
            try expectEqual(try JSONCoding.decoder.decode(SlackState.self, from: JSONCoding.encoder.encode(full)), full)
        },
    ]
}
