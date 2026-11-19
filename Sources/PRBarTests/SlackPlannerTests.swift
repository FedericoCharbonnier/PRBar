import Foundation
import PRBarCore

private let repo = RepoRef(owner: "o", name: "r")

func slackConfig(enabled: Bool = true, channel: String? = "C1", enabledAt: Date = at(-120)) -> AppConfig {
    var config = AppConfig()
    config.slack.enabled = enabled
    config.accounts = [AccountConfig(login: "me", repos: [
        RepoConfig(owner: "o", name: "r", slackChannelID: channel, slackChannelName: channel, slackEnabledAt: channel == nil ? nil : enabledAt),
    ])]
    return config
}

func slackSnap(_ prs: PullRequest..., fetched: Bool = true) -> Snapshot {
    Snapshot(items: prs.map { ClassifiedPR(pr: $0, category: .other, account: "me") }, fetchedAt: t0,
             fetchedScopes: fetched ? ["me|o/r"] : [])
}

func myPR(number: Int = 1, isDraft: Bool = false, lastCommit: Int = 0, head: String? = nil, reviews: [PRReview] = []) -> PullRequest {
    makePR(number: number, author: "me", isDraft: isDraft, lastCommit: lastCommit, head: head, reviews: reviews)
}

private func text(_ action: SlackAction) -> String {
    switch action {
    case .announce(_, _, _, _, let text), .update(_, _, _, _, _, let text, _), .reply(_, _, _, _, let text, _): text
    case .findMessage, .react: ""
    }
}

private let fresh = SlackState(baselineAt: .distantPast)

private func announced(ts: String = "111.1", channel: String = "C9", at minutes: Int = 0, lastHandled: Int? = nil) -> SlackState {
    var state = SlackState(baselineAt: .distantPast)
    state.announcements["o/r#1"] = SlackAnnouncement(channelID: channel, ts: ts, announcedAt: at(minutes), lastHandledReviewAt: lastHandled.map { at($0) })
    return state
}

enum SlackPlannerTests {
    static let cases: [TestCase] = [
        TestCase("slack planner: desactivado no hace nada") {
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(enabled: false), state: fresh), SlackPlan())
        },
        TestCase("slack planner: PR nuevo posterior al canal → anuncio") {
            let plan = SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(), state: fresh)
            try expectEqual(plan.actions, [.announce(prID: "o/r#1", repo: repo, channelID: "C1", channelName: "C1", text: "https://github.com/o/r/pull/1")])
        },
        TestCase("slack planner: PR anterior a configurar el canal → nada") {
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(enabledAt: at(-30)), state: fresh), SlackPlan())
        },
        TestCase("slack planner: draft se recuerda y se anuncia al pasar a ready") {
            let draftPlan = SlackPlanner.plan(snapshot: slackSnap(myPR(isDraft: true)), config: slackConfig(enabledAt: at(-30)), state: fresh)
            try expectEqual(draftPlan.actions, [])
            try expectEqual(draftPlan.newDrafts, ["o/r#1"])
            var state = SlackState(baselineAt: .distantPast)
            state.seenAsDraft = ["o/r#1": at(-10)]
            let readyPlan = SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(enabledAt: at(-30)), state: state)
            try expectEqual(readyPlan.actions.count, 1)
            try expectEqual(readyPlan.newDrafts, [])
        },
        TestCase("slack planner: sin datos frescos del repo → nada") {
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR(), fetched: false), config: slackConfig(), state: fresh), SlackPlan())
        },
        TestCase("slack planner: PRs ajenos o repos sin canal → nada") {
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(makePR(author: "juan")), config: slackConfig(), state: fresh), SlackPlan())
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(channel: nil), state: fresh), SlackPlan())
        },
        TestCase("slack planner: review y después push (head distinto) → Updated en el hilo del anuncio") {
            let pr = myPR(reviews: [review("ana", .changesRequested, at: 10, commit: "old")])
            let plan = SlackPlanner.plan(snapshot: slackSnap(pr), config: slackConfig(), state: announced())
            try expectEqual(plan.actions, [.update(prID: "o/r#1", repo: repo, channelID: "C9", channelName: nil, threadTS: "111.1",
                                                   text: "Updated https://github.com/o/r/pull/1", handledReviewAt: at(10))])
        },
        TestCase("slack planner: review sobre el head actual → nada") {
            let pr = myPR(lastCommit: 20, reviews: [review("ana", .changesRequested, at: 10, commit: "abc1")])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(pr), config: slackConfig(), state: announced()), SlackPlan())
        },
        TestCase("slack planner: review sin commit conocido → nada") {
            let pr = myPR(lastCommit: 20, reviews: [review("ana", .changesRequested, at: 10)])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(pr), config: slackConfig(), state: announced()), SlackPlan())
        },
        TestCase("slack planner: la fecha del commit no importa, solo que el head cambió") {
            let pr = myPR(lastCommit: 5, head: "nuevo", reviews: [review("ana", .changesRequested, at: 10, commit: "viejo")])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(pr), config: slackConfig(), state: announced()).actions.count, 1)
        },
        TestCase("slack planner: ana revisa A, push B, bob revisa B en el mismo refresco → un solo Updated") {
            let pr = myPR(head: "B", reviews: [review("ana", .changesRequested, at: 10, commit: "A"), review("bob", .approved, at: 20, commit: "B")])
            let plan = SlackPlanner.plan(snapshot: slackSnap(pr), config: slackConfig(), state: announced())
            try expectEqual(plan.actions.count, 1)
            guard case .update(_, _, _, _, _, _, let handled) = plan.actions[0] else { throw TestFailure(description: "esperaba update") }
            try expectEqual(handled, at(20))
            // La ronda siguiente arranca después de las dos reviews: no se repite.
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(pr), config: slackConfig(), state: announced(lastHandled: 20)), SlackPlan())
        },
        TestCase("slack planner: la única review sin manejar es sobre el head → nada") {
            let pr = myPR(head: "B", reviews: [review("ana", .changesRequested, at: 10, commit: "A"), review("bob", .approved, at: 20, commit: "B")])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(pr), config: slackConfig(), state: announced(lastHandled: 10)), SlackPlan())
        },
        TestCase("slack planner: un solo Updated por ronda de review") {
            let pr = myPR(reviews: [review("ana", .changesRequested, at: 10, commit: "old")])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(pr), config: slackConfig(), state: announced(lastHandled: 10)), SlackPlan())
            let nextRound = myPR(reviews: [review("ana", .changesRequested, at: 10, commit: "old"), review("ana", .commented, at: 40, commit: "old2")])
            let plan = SlackPlanner.plan(snapshot: slackSnap(nextRound), config: slackConfig(), state: announced(lastHandled: 10))
            try expectEqual(plan.actions.count, 1)
            guard case .update(_, _, _, _, _, _, let handled) = plan.actions[0] else { throw TestFailure(description: "esperaba update") }
            try expectEqual(handled, at(40))
        },
        TestCase("slack planner: reviews previas al anuncio, propias o de bots no cuentan") {
            let early = myPR(reviews: [review("ana", .changesRequested, at: -5, commit: "old")])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(early), config: slackConfig(), state: announced()), SlackPlan())
            let ownAndBot = myPR(reviews: [review("me", .commented, at: 10, commit: "old"), review("ci", .commented, at: 11, bot: true, commit: "old")])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(ownAndBot), config: slackConfig(), state: announced()), SlackPlan())
        },
        TestCase("slack state: anuncios viejos con lastUpdatePostedAt se leen como lastHandledReviewAt") {
            let json = #"{"channelID":"C1","ts":"1.1","announcedAt":"2026-11-18T10:00:00Z","lastUpdatePostedAt":"2026-11-18T11:00:00Z"}"#
            let announcement = try JSONCoding.decoder.decode(SlackAnnouncement.self, from: Data(json.utf8))
            try expectEqual(announcement.lastHandledReviewAt, ISO8601DateFormatter().date(from: "2026-11-18T11:00:00Z"))
        },
        TestCase("models: PRReview sin commitOID (state.json viejo) se decodifica") {
            let json = #"{"author":"ana","isBot":false,"state":"APPROVED","submittedAt":"2026-11-18T10:00:00Z"}"#
            let decoded = try JSONCoding.decoder.decode(PRReview.self, from: Data(json.utf8))
            try expectEqual(decoded.commitOID, nil)
            let roundTrip = try JSONCoding.decoder.decode(PRReview.self, from: JSONCoding.encoder.encode(review("ana", .approved, at: 1, commit: "x")))
            try expectEqual(roundTrip.commitOID, "x")
        },
        TestCase("slack planner: PR anterior a encender Slack → nada (sin backlog)") {
            var config = slackConfig()
            config.slack.enabledAt = at(-30)
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR()), config: config, state: fresh), SlackPlan())
            config.slack.enabledAt = at(-90)
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR()), config: config, state: fresh).actions.count, 1)
        },
        TestCase("slack planner: plantillas vacías usan las de por defecto") {
            var config = slackConfig()
            config.slack.newPRTemplate = "  \n"
            config.slack.updateTemplate = ""
            let announce = SlackPlanner.plan(snapshot: slackSnap(myPR()), config: config, state: fresh)
            try expectEqual(announce.actions.first.map(text), "https://github.com/o/r/pull/1")
            let pr = myPR(reviews: [review("ana", .changesRequested, at: 10, commit: "old")])
            let update = SlackPlanner.plan(snapshot: slackSnap(pr), config: config, state: announced())
            try expectEqual(update.actions.first.map(text), "Updated https://github.com/o/r/pull/1")
        },
        TestCase("slack planner: PR anterior al baseline del estado → nada") {
            let state = SlackState(baselineAt: at(-30))
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(), state: state), SlackPlan())
        },
        TestCase("slack planner: draft registrado antes del corte no cuenta y se vuelve a registrar") {
            var state = SlackState(baselineAt: at(-30))
            state.seenAsDraft = ["o/r#1": at(-40)]
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(), state: state), SlackPlan())
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR(isDraft: true)), config: slackConfig(), state: state).newDrafts, ["o/r#1"])
            state.seenAsDraft = ["o/r#1": at(-20)]
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(myPR()), config: slackConfig(), state: state).actions.count, 1)
        },
    ]
}
