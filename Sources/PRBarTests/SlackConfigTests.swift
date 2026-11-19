import Foundation
import PRBarCore

enum SlackConfigTests {
    static let cases: [TestCase] = [
        TestCase("slack config: defaults y JSON viejo sin slack") {
            let json = #"{"accounts":[{"login":"me","repos":[{"owner":"o","name":"r"}]}]}"#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expectEqual(config.slack.enabled, false)
            try expectEqual(config.slack.newPRTemplate, "{link}")
            try expectEqual(config.slack.updateTemplate, "Updated {link}")
            try expectEqual(config.accounts[0].repos[0].slackChannelID, nil)
            try expectEqual(config.accounts[0].repos[0].slackEnabledAt, nil)
        },
        TestCase("slack config: elegir canal guarda la fecha; repetirlo no la cambia; quitarlo limpia") {
            var config = AppConfig()
            config.setAccountEnabled("me", true)
            config.addRepo(RepoRef(owner: "o", name: "r"), to: "me")
            config.setSlackChannel(id: "C1", name: "prs", repoID: "o/r", login: "me", now: at(0))
            config.setSlackChannel(id: "C1", name: "prs", repoID: "o/r", login: "me", now: at(10))
            var repo = config.accounts[0].repos[0]
            try expectEqual(repo.slackChannelID, "C1")
            try expectEqual(repo.slackChannelName, "prs")
            try expectEqual(repo.slackEnabledAt, at(0))
            config.setSlackChannel(id: "C2", name: "otro", repoID: "o/r", login: "me", now: at(20))
            try expectEqual(config.accounts[0].repos[0].slackEnabledAt, at(20))
            config.setSlackChannel(id: nil, name: nil, repoID: "o/r", login: "me", now: at(30))
            repo = config.accounts[0].repos[0]
            try expectEqual(repo.slackChannelID, nil)
            try expectEqual(repo.slackChannelName, nil)
            try expectEqual(repo.slackEnabledAt, nil)
        },
        TestCase("slack config: round-trip JSON con canal") {
            var config = AppConfig()
            config.slack.enabled = true
            config.setAccountEnabled("me", true)
            config.addRepo(RepoRef(owner: "o", name: "r"), to: "me")
            config.setSlackChannel(id: "C1", name: "prs", repoID: "o/r", login: "me", now: t0)
            let data = try JSONCoding.encoder.encode(config)
            try expectEqual(try JSONCoding.decoder.decode(AppConfig.self, from: data), config)
        },
        TestCase("slack config: encender Slack guarda enabledAt; repetirlo o apagarlo no lo cambia") {
            var config = AppConfig()
            try expectEqual(config.slack.enabledAt, nil)
            config.setSlackEnabled(true, now: at(0))
            try expectEqual(config.slack.enabled, true)
            try expectEqual(config.slack.enabledAt, at(0))
            config.setSlackEnabled(true, now: at(5))
            try expectEqual(config.slack.enabledAt, at(0))
            config.setSlackEnabled(false, now: at(10))
            try expectEqual(config.slack.enabled, false)
            config.setSlackEnabled(true, now: at(20))
            try expectEqual(config.slack.enabledAt, at(20))
            config.slackTokenAdded(now: at(30))
            try expectEqual(config.slack.enabledAt, at(30))
            let data = try JSONCoding.encoder.encode(config)
            try expectEqual(try JSONCoding.decoder.decode(AppConfig.self, from: data), config)
        },
        TestCase("slack template: reemplaza variables y escapa texto para Slack") {
            let pr = PullRequest(
                repo: RepoRef(owner: "o", name: "r"), number: 7, title: "Fix <b> & stuff",
                url: URL(string: "https://github.com/o/r/pull/7")!, isDraft: false, author: "me", authorAvatarURL: nil,
                baseRef: "main", headRef: "f", headOid: "x", additions: 1, deletions: 1,
                createdAt: t0, updatedAt: t0, lastCommitAt: t0, ciState: .success, reviewDecision: .none,
                reviews: [], comments: [], requestedReviewers: []
            )
            try expectEqual(SlackTemplate.render("{link}", pr: pr), "https://github.com/o/r/pull/7")
            try expectEqual(SlackTemplate.render("{repo}#{number} {title} por {author} {nada}", pr: pr),
                            "r#7 Fix &lt;b&gt; &amp; stuff por me {nada}")
            try expectEqual(SlackTemplate.render("Updated {link", pr: pr), "Updated {link")
        },
        TestCase("slack issue: mensaje con prefijo Slack y pista para not_in_channel") {
            let issue = RefreshIssue(account: "slack", repo: RepoRef(owner: "o", name: "r"), error: .slack("not_in_channel"))
            try expect(issue.message.hasPrefix("Slack · r:"))
            try expect(issue.message.contains("not a member"), issue.message)
            try expect(!issue.message.contains("bot"), issue.message)
            try expect(!issue.requiresLogin)
        },
        TestCase("slack issue: errores de Slack no hablan de GitHub") {
            let repo = RepoRef(owner: "o", name: "r")
            let limited = RefreshIssue(account: "slack", repo: nil, error: .rateLimited(resetAt: t0))
            try expectEqual(limited.message, "Slack is rate limiting messages · retrying at \(ClockTime.hhmm(t0))")
            for error in [PRBarError.network("offline"), .http(status: 502, message: "Slack chat.postMessage"), .invalidResponse("x")] {
                let message = RefreshIssue(account: "slack", repo: repo, error: error).message
                try expect(message.hasPrefix("Slack · r:"), message)
                try expect(!message.contains("GitHub"), message)
            }
        },
        TestCase("slack issue: not_in_channel y channel_not_found nombran el canal") {
            let repo = RepoRef(owner: "o", name: "r")
            let notIn = RefreshIssue(account: "slack", repo: repo, error: .slack("not_in_channel"), detail: "prs-web")
            try expectEqual(notIn.message, "Slack · r: Join #prs-web to post there")
            let notFound = RefreshIssue(account: "slack", repo: repo, error: .slack("channel_not_found"), detail: "prs-web")
            try expect(notFound.message.contains("#prs-web"), notFound.message)
        },
        TestCase("slack config: defaults de Plan 5 y JSON viejo de Plan 4") {
            let json = #"{"slack":{"enabled":true,"newPRTemplate":"PR {link}","enabledAt":"2026-11-18T10:00:00Z"}}"#
            let slack = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8)).slack
            try expectEqual(slack.enabled, true)
            try expectEqual(slack.newPRTemplate, "PR {link}")
            try expectEqual(slack.updateTemplate, "Updated {link}")
            try expect(slack.enabledAt != nil)
            for value in [slack.announceNewPRs, slack.postUpdated, slack.reactOnReviewStart, slack.reactOnFirstComment,
                          slack.postRoundMessages, slack.reactOnApprove] {
                try expectEqual(value, true)
            }
            try expectEqual(slack.reviewReactionsEnabledAt, nil)
            try expectEqual(slack.eyesEmoji, "eyes")
            try expectEqual(slack.commentEmoji, "speech_balloon")
            try expectEqual(slack.approvedEmoji, "approved")
            try expectEqual(slack.roundTemplate, "commented x{n}")
            try expectEqual(slack.searchDays, 30)
            try expectEqual(slack, {
                var fresh = SlackSettings()
                fresh.enabled = true
                fresh.newPRTemplate = "PR {link}"
                fresh.enabledAt = slack.enabledAt
                return fresh
            }())
        },
        TestCase("slack config: round-trip JSON con los campos de Plan 5") {
            var config = AppConfig()
            config.slack.postUpdated = false
            config.slack.reactOnApprove = false
            config.slack.reviewReactionsEnabledAt = at(3)
            config.slack.eyesEmoji = "looking"
            config.slack.roundTemplate = "x{n}"
            config.slack.searchDays = 14
            let data = try JSONCoding.encoder.encode(config)
            try expectEqual(try JSONCoding.decoder.decode(AppConfig.self, from: data), config)
        },
        TestCase("slack config: provider por defecto (conector), round-trip y valor desconocido") {
            try expectEqual(SlackSettings().provider, .claudeConnector)
            try expect(!SlackSettings().providerChosen)
            var config = AppConfig()
            config.slack.provider = .userToken
            try expect(config.slack.providerChosen)
            let data = try JSONCoding.encoder.encode(config)
            try expectEqual(try JSONCoding.decoder.decode(AppConfig.self, from: data).slack.provider, .userToken)
            let legacy = try JSONCoding.decoder.decode(AppConfig.self, from: Data(#"{"slack":{"enabled":true}}"#.utf8))
            try expectEqual(legacy.slack.provider, .claudeConnector)
            try expect(!legacy.slack.providerChosen)
            let unsetJSON = String(decoding: try JSONCoding.encoder.encode(AppConfig()), as: UTF8.self)
            try expect(!unsetJSON.contains("\"provider\""), unsetJSON)
            let future = Data(#"{"slack":{"enabled":true,"provider":"carrierPigeon","postUpdated":false}}"#.utf8)
            let decoded = try JSONCoding.decoder.decode(AppConfig.self, from: future)
            try expect(!decoded.slack.providerChosen)
            try expectEqual(decoded.slack.postUpdated, false)
        },
        TestCase("slack config: sin provider guardado, un token en el Llavero mantiene userToken; si no, el conector") {
            var withToken = AppConfig()
            try expect(withToken.resolveDefaultSlackProvider(hasUserToken: true))
            try expectEqual(withToken.slack.provider, .userToken)
            try expect(withToken.slack.providerChosen)
            var withoutToken = AppConfig()
            try expect(withoutToken.resolveDefaultSlackProvider(hasUserToken: false))
            try expectEqual(withoutToken.slack.provider, .claudeConnector)
            // Una elección guardada no se toca, haya token o no.
            var chosen = AppConfig()
            chosen.slack.provider = .claudeConnector
            try expect(!chosen.resolveDefaultSlackProvider(hasUserToken: true))
            try expectEqual(chosen.slack.provider, .claudeConnector)
            // No cuenta como un cambio de credencial: no corta el backlog.
            try expectEqual(withToken.slack.enabledAt, nil)
        },
        TestCase("slack config: cambiar el provider corta el backlog y activa las reacciones") {
            var config = AppConfig()
            config.slack.enabledAt = at(0)
            config.setSlackProvider(.claudeConnector, now: at(5))
            try expectEqual(config.slack.enabledAt, at(0))
            try expect(config.slack.providerChosen)
            config.setSlackProvider(.userToken, now: at(10))
            try expectEqual(config.slack.provider, .userToken)
            try expectEqual(config.slack.enabledAt, at(10))
            try expectEqual(config.slack.reviewReactionsEnabledAt, at(10))
        },
        TestCase("slack config: emojis normalizados; vacíos usan el default") {
            try expectEqual(SlackSettings.normalizedEmoji(":Eyes:"), "eyes")
            try expectEqual(SlackSettings.normalizedEmoji("  :+1: "), "+1")
            try expectEqual(SlackSettings.normalizedEmoji("thumbs-up_2'"), "thumbs-up_2'")
            try expectEqual(SlackSettings.normalizedEmoji("👀"), nil)
            try expectEqual(SlackSettings.normalizedEmoji("::"), nil)
            var slack = SlackSettings()
            slack.eyesEmoji = ":LOOKING:"
            slack.commentEmoji = " "
            slack.approvedEmoji = "::"
            try expectEqual(slack.effectiveEyesEmoji, "looking")
            try expectEqual(slack.effectiveCommentEmoji, "speech_balloon")
            try expectEqual(slack.effectiveApprovedEmoji, "approved")
            slack.roundTemplate = "  "
            try expectEqual(slack.effectiveRoundTemplate, "commented x{n}")
            slack.searchDays = 0
            try expectEqual(slack.effectiveSearchDays, 1)
            slack.searchDays = 500
            try expectEqual(slack.effectiveSearchDays, 90)
        },
        TestCase("slack config: activar una reacción desde apagado guarda reviewReactionsEnabledAt") {
            var config = AppConfig()
            for toggle in [SlackToggle.reactOnReviewStart, .reactOnFirstComment, .postRoundMessages, .reactOnApprove] {
                config.setSlackToggle(toggle, false, now: at(0))
            }
            try expectEqual(config.slack.reviewReactionsEnabledAt, nil)
            config.setSlackToggle(.reactOnFirstComment, true, now: at(10))
            try expectEqual(config.slack.reviewReactionsEnabledAt, at(10))
            // Con otra ya activa no se reinicia (la numeración de rondas sigue).
            config.setSlackToggle(.reactOnApprove, true, now: at(20))
            try expectEqual(config.slack.reviewReactionsEnabledAt, at(10))
            // Los toggles de mis PRs no tocan la fecha.
            config.setSlackToggle(.postUpdated, false, now: at(30))
            config.setSlackToggle(.postUpdated, true, now: at(31))
            try expectEqual(config.slack.postUpdated, true)
            try expectEqual(config.slack.reviewReactionsEnabledAt, at(10))
            // Apagar todas y volver a prender arranca de nuevo.
            config.setSlackToggle(.reactOnFirstComment, false, now: at(40))
            config.setSlackToggle(.reactOnApprove, false, now: at(40))
            config.setSlackToggle(.reactOnReviewStart, true, now: at(50))
            try expectEqual(config.slack.reviewReactionsEnabledAt, at(50))
        },
        TestCase("slack config: config vieja sin fecha arranca las reacciones al prender Slack o guardar token") {
            var config = AppConfig()
            try expectEqual(config.activateReviewReactionsIfNeeded(now: at(1)), true)
            try expectEqual(config.activateReviewReactionsIfNeeded(now: at(2)), false)
            try expectEqual(config.slack.reviewReactionsEnabledAt, at(1))
            var other = AppConfig()
            other.setSlackEnabled(true, now: at(5))
            try expectEqual(other.slack.reviewReactionsEnabledAt, at(5))
            var tokenOnly = AppConfig()
            tokenOnly.slackTokenAdded(now: at(7))
            try expectEqual(tokenOnly.slack.reviewReactionsEnabledAt, at(7))
            var off = AppConfig()
            for toggle in [SlackToggle.reactOnReviewStart, .reactOnFirstComment, .postRoundMessages, .reactOnApprove] {
                off.setSlackToggle(toggle, false)
            }
            try expectEqual(off.activateReviewReactionsIfNeeded(now: at(1)), false)
            try expectEqual(off.slack.reviewReactionsEnabledAt, nil)
        },
        TestCase("slack template: {n} solo en mensajes de ronda") {
            let pr = makePR(number: 7)
            try expectEqual(SlackTemplate.render("commented x{n}", pr: pr, n: 3), "commented x3")
            try expectEqual(SlackTemplate.render("x{n} {link}", pr: pr), "x{n} https://github.com/o/r/pull/7")
        },
        TestCase("slack token: migración borra el token de bot y pide el de usuario") {
            let dir = try temporaryDirectory()
            let store = SlackStateStore(url: dir.appendingPathComponent("slack-state.json"))
            var state = SlackState(baselineAt: at(-500))
            state.announcements["o/r#1"] = SlackAnnouncement(channelID: "C1", ts: "1.1", announcedAt: at(-400))
            try store.save(state)
            let secrets = FakeSecrets(["bot-token": "xoxb-viejo"])
            let announcer = await SlackAnnouncer(api: FakeSlackAPI(), secrets: secrets, stateStore: store, now: { at(0) })
            try expectEqual(secrets.peek("bot-token"), nil)
            try expectEqual(secrets.reads, 0)
            let needs = await announcer.needsUserToken
            let has = await announcer.hasToken
            try expectEqual(needs, true)
            try expectEqual(has, false)
            try expectEqual(store.load().announcements["o/r#1"]?.ts, "1.1")
            try expectEqual(store.load().baselineAt, at(-500))
            // Un reinicio sin token de usuario sigue pidiéndolo.
            let restarted = await SlackAnnouncer(api: FakeSlackAPI(), secrets: secrets, stateStore: store, now: { at(1) })
            let stillNeeds = await restarted.needsUserToken
            try expectEqual(stillNeeds, true)
            try await restarted.saveToken("xoxp-nuevo")
            let afterSave = await restarted.needsUserToken
            try expectEqual(afterSave, false)
            try expectEqual(secrets.peek("user-token"), "xoxp-nuevo")
            let third = await SlackAnnouncer(api: FakeSlackAPI(), secrets: secrets, stateStore: store, now: { at(2) })
            let thirdNeeds = await third.needsUserToken
            try expectEqual(thirdNeeds, false)
        },
        TestCase("slack token: con token de usuario la migración no pide nada") {
            let store = try SlackStateStore(url: temporaryDirectory().appendingPathComponent("slack-state.json"))
            let secrets = FakeSecrets(["bot-token": "xoxb-viejo", "user-token": "xoxp-1"])
            let announcer = await SlackAnnouncer(api: FakeSlackAPI(), secrets: secrets, stateStore: store, now: { at(0) })
            let needs = await announcer.needsUserToken
            try expectEqual(needs, false)
            try expectEqual(secrets.peek("bot-token"), nil)
            try expectEqual(secrets.peek("user-token"), "xoxp-1")
        },
        TestCase("slack token: solo acepta xoxp-") {
            let secrets = FakeSecrets()
            let store = try SlackStateStore(url: temporaryDirectory().appendingPathComponent("slack-state.json"))
            let announcer = await SlackAnnouncer(api: FakeSlackAPI(), secrets: secrets, stateStore: store, now: { at(0) })
            let bot = try await expectThrows { try await announcer.saveToken(" xoxb-123 ") }
            try expectEqual(bot as? PRBarError, .slack("bot_token_rejected"))
            try expectEqual((bot as? PRBarError)?.localizedDescription, "That token posts as an app (xoxb-…). Paste the User OAuth Token (xoxp-…).")
            let other = try await expectThrows { try await announcer.saveToken("abc") }
            try expectEqual(other as? PRBarError, .slack("invalid_user_token"))
            try expectEqual(secrets.peek("user-token"), nil)
            let has = await announcer.hasToken
            try expectEqual(has, false)
            let added = try await announcer.saveToken(" xoxp-123\n")
            try expectEqual(added, true)
            try expectEqual(secrets.peek("user-token"), "xoxp-123")
            try await announcer.saveToken(nil)
            try expectEqual(secrets.peek("user-token"), nil)
        },
        TestCase("slack issue: pistas para emoji inexistente y scope faltante") {
            let emoji = RefreshIssue(account: "slack", repo: nil, error: .slack("invalid_name"), detail: "approved")
            try expectEqual(emoji.message, "Slack: Emoji :approved: doesn't exist in this workspace")
            let scope = RefreshIssue(account: "slack", repo: RepoRef(owner: "o", name: "r"), error: .slack("missing_scope"), detail: "reactions:write")
            try expectEqual(scope.message, "Slack · r: Your Slack token is missing a scope (needs reactions:write)")
            let generic = RefreshIssue(account: "slack", repo: nil, error: .slack("missing_scope"))
            try expect(generic.message.contains("reactions:write"), generic.message)
            try expect(!generic.message.contains("bot"), generic.message)
        },
        TestCase("slack issue: JSON sin detail se decodifica") {
            let issue = RefreshIssue(account: "slack", repo: nil, error: .slack("x"), detail: "c")
            var json = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(issue)) as! [String: Any]
            json["detail"] = nil
            let decoded = try JSONCoding.decoder.decode(RefreshIssue.self, from: JSONSerialization.data(withJSONObject: json))
            try expectEqual(decoded.detail, nil)
            try expectEqual(decoded.error, .slack("x"))
        },
    ]
}
