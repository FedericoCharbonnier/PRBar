import Foundation
import PRBarCore

private func builder(_ api: FakeAPI, tokens: FakeTokens = FakeTokens()) -> SnapshotBuilder {
    SnapshotBuilder(api: api, tokens: tokens, now: { t0 })
}

private func repoPRs(_ prs: PullRequest..., defaultBranch: String = "develop") -> Result<RepoPRs, PRBarError> {
    .success(RepoPRs(defaultBranch: defaultBranch, pullRequests: prs))
}

enum SnapshotTests {
    static let cases: [TestCase] = [
        TestCase("snapshot: sin ramas configuradas usa la rama por defecto") {
            let api = FakeAPI(prs: ["o/r": repoPRs(makePR(number: 1, base: "develop"), makePR(number: 2, base: "main"))])
            let snapshot = await builder(api).build(config: config(account("me")), previous: nil)
            try expectEqual(snapshot.items.map(\.id), ["o/r#1"])
            try expectEqual(snapshot.items[0].category, .toReview)
            try expectEqual(snapshot.badgeCount, 1)
        },
        TestCase("snapshot: los usuarios seguidos son por repo") {
            let a = RepoRef(owner: "o", name: "a")
            let b = RepoRef(owner: "o", name: "b")
            let api = FakeAPI(prs: [
                "o/a": repoPRs(makePR(repo: a, number: 1, author: "juan")),
                "o/b": repoPRs(makePR(repo: b, number: 2, author: "juan"), makePR(repo: b, number: 3, author: "juan", requested: ["me"])),
            ])
            let me = AccountConfig(login: "me", repos: [
                RepoConfig(owner: "o", name: "a", watchedUsers: ["juan"]),
                RepoConfig(owner: "o", name: "b"),
            ])
            let snapshot = await builder(api).build(config: config(me), previous: nil)
            try expectEqual(Set(snapshot.items.map(\.id)), ["o/a#1", "o/b#3"])
        },
        TestCase("snapshot: ramas configuradas filtran") {
            let api = FakeAPI(prs: ["o/r": repoPRs(makePR(number: 1, base: "develop"), makePR(number: 2, base: "main"))])
            let snapshot = await builder(api).build(config: config(account("me", bases: ["main"])), previous: nil)
            try expectEqual(snapshot.items.map(\.id), ["o/r#2"])
        },
        TestCase("snapshot: un PR visto desde dos cuentas aparece una vez con la categoría más urgente") {
            let pr = makePR(number: 1, reviews: [review("a", .approved, at: 10)])
            let api = FakeAPI(prs: ["o/r": repoPRs(pr)])
            let snapshot = await builder(api).build(config: config(account("a"), account("b")), previous: nil)
            try expectEqual(snapshot.items.count, 1)
            try expectEqual(snapshot.items[0].category, .toReview)
            try expectEqual(snapshot.items[0].account, "b")
        },
        TestCase("snapshot: PR de una de mis cuentas se ve desde la cuenta autora") {
            let pr = makePR(number: 1, author: "a", requested: ["b"])
            let api = FakeAPI(prs: ["o/r": repoPRs(pr)])
            let snapshot = await builder(api).build(config: config(account("a"), account("b")), previous: nil)
            try expectEqual(snapshot.items.count, 1)
            try expectEqual(snapshot.items[0].account, "a")
            try expect(snapshot.items[0].category != .toReview)
        },
        TestCase("snapshot: ordena por categoría y después por actualización") {
            let api = FakeAPI(prs: ["o/r": repoPRs(
                makePR(number: 1, updated: 1),
                makePR(number: 2, author: "me", lastCommit: 0, comments: [comment("ana", at: 5)], updated: 9),
                makePR(number: 3, updated: 5)
            )])
            let snapshot = await builder(api).build(config: config(account("me")), previous: nil)
            try expectEqual(snapshot.items.map(\.pr.number), [3, 1, 2])
        },
        TestCase("snapshot: cuentas desactivadas se ignoran") {
            let api = FakeAPI(prs: ["o/r": repoPRs(makePR())])
            let snapshot = await builder(api).build(config: config(account("me", enabled: false)), previous: nil)
            try expectEqual(snapshot.items, [])
            try expectEqual(snapshot.failedCompletely, false)
        },
        TestCase("snapshot: si falla el token se conserva lo anterior y se informa") {
            let previous = Snapshot(items: [ClassifiedPR(pr: makePR(), category: .toReview, account: "me")], fetchedAt: at(-14))
            let snapshot = await builder(FakeAPI(), tokens: FakeTokens(failing: ["me"])).build(config: config(account("me")), previous: previous)
            try expectEqual(snapshot.items, previous.items)
            try expectEqual(snapshot.issues, [RefreshIssue(account: "me", repo: nil, error: .unauthorized)])
            try expectEqual(snapshot.failedCompletely, true)
            try expectEqual(snapshot.fetchedAt, at(-14))
        },
        TestCase("snapshot: si falla un repo se conserva lo anterior de ese repo") {
            let previous = Snapshot(items: [ClassifiedPR(pr: makePR(), category: .toReview, account: "me")], fetchedAt: at(-5))
            let api = FakeAPI(prs: ["o/r": .failure(.http(status: 502, message: "Bad gateway"))])
            let snapshot = await builder(api).build(config: config(account("me")), previous: previous)
            try expectEqual(snapshot.items, previous.items)
            try expectEqual(snapshot.issues, [RefreshIssue(account: "me", repo: RepoRef(owner: "o", name: "r"), error: .http(status: 502, message: "Bad gateway"))])
            try expectEqual(snapshot.failedCompletely, true)
        },
        TestCase("snapshot: cuenta sin repos no cuenta como falla total") {
            var noRepos = account("me")
            noRepos.repos = []
            let snapshot = await builder(FakeAPI()).build(config: config(noRepos), previous: nil)
            try expectEqual(snapshot.failedCompletely, false)
            try expectEqual(snapshot.fetchedAt, t0)
        },
        TestCase("snapshot: fetchedScopes solo incluye repos consultados con éxito") {
            var me = account("me")
            me.repos.append(RepoConfig(owner: "o", name: "roto", baseBranches: []))
            let api = FakeAPI(prs: ["o/r": repoPRs(makePR()), "o/roto": .failure(.http(status: 502, message: "x"))])
            let snapshot = await builder(api, tokens: FakeTokens(failing: ["sin-token"])).build(config: config(me, account("sin-token")), previous: nil)
            try expectEqual(snapshot.fetchedScopes, ["me|o/r"])
        },
        TestCase("snapshot: state.json sin fetchedScopes se lee vacío") {
            let url = try temporaryDirectory().appendingPathComponent("state.json")
            try Data(#"{"items":[],"fetchedAt":"2027-01-15T08:00:00Z","issues":[],"failedCompletely":false}"#.utf8).write(to: url)
            try expectEqual(SnapshotStore(url: url).load()?.fetchedScopes, [])
        },
        TestCase("snapshot: errores de red quedan como .network") {
            let api = FakeAPI(rawErrors: ["o/r": URLError(.notConnectedToInternet)])
            let snapshot = await builder(api).build(config: config(account("me")), previous: nil)
            guard case .network = snapshot.issues.first?.error else { throw TestFailure(description: "esperaba .network, hubo \(snapshot.issues)") }
        },
        TestCase("snapshot: rate limit queda registrado") {
            let reset = at(30)
            let api = FakeAPI(prs: ["o/r": .failure(.rateLimited(resetAt: reset))])
            let snapshot = await builder(api).build(config: config(account("me")), previous: nil)
            try expectEqual(snapshot.rateLimitedUntil, reset)
        },
        TestCase("snapshot: tras un rate limit no se consultan más repos y se conserva lo anterior") {
            var me = account("me")
            me.repos = ["a", "b", "c"].map { RepoConfig(owner: "o", name: $0, watchedUsers: ["juan"]) }
            let reset = at(30)
            let previousC = ClassifiedPR(pr: makePR(repo: RepoRef(owner: "o", name: "c"), number: 3), category: .toReview, account: "me")
            let previous = Snapshot(items: [previousC], fetchedAt: at(-5))
            let api = FakeAPI(prs: [
                "o/a": repoPRs(makePR(repo: RepoRef(owner: "o", name: "a"), number: 1)),
                "o/b": .failure(.rateLimited(resetAt: reset)),
                "o/c": repoPRs(),
            ])
            let snapshot = await builder(api).build(config: config(me, account("otra")), previous: previous)
            try expectEqual(api.calls.value, ["o/a", "o/b"])
            try expectEqual(snapshot.rateLimitedUntil, reset)
            try expectEqual(Set(snapshot.items.map(\.id)), ["o/a#1", "o/c#3"])
            try expectEqual(snapshot.fetchedScopes, ["me|o/a"])
            try expectEqual(snapshot.failedCompletely, false)
        },
        TestCase("snapshot: SnapshotStore guarda y lee") {
            let url = try temporaryDirectory().appendingPathComponent("state.json")
            let store = SnapshotStore(url: url)
            try expectEqual(store.load(), nil)
            let snapshot = Snapshot(items: [ClassifiedPR(pr: makePR(), category: .toReview, account: "me")], fetchedAt: t0, issues: [
                RefreshIssue(account: "me", repo: nil, error: .commandFailed(command: "gh auth token --user me", status: 1, stderr: "no")),
                RefreshIssue(account: "me", repo: RepoRef(owner: "o", name: "r"), error: .rateLimited(resetAt: at(30))),
            ], fetchedScopes: ["me|o/r"])
            store.save(snapshot)
            try expectEqual(store.load(), snapshot)
        },
        TestCase("snapshot: state.json viejo con errors[String] se lee sin issues") {
            let url = try temporaryDirectory().appendingPathComponent("state.json")
            let json = #"{"items":[],"fetchedAt":"2027-01-15T08:00:00Z","errors":["o/r (me): boom"],"failedCompletely":false}"#
            try Data(json.utf8).write(to: url)
            let loaded = SnapshotStore(url: url).load()
            try expectEqual(loaded?.issues, [])
            try expectEqual(loaded?.failedCompletely, false)
        },
        TestCase("snapshot: issues agrupados por cuenta en orden de aparición") {
            let r = RepoRef(owner: "o", name: "r")
            let snapshot = Snapshot(items: [], fetchedAt: t0, issues: [
                RefreshIssue(account: "b", repo: r, error: .graphQL("x")),
                RefreshIssue(account: "a", repo: nil, error: .unauthorized),
                RefreshIssue(account: "b", repo: nil, error: .graphQL("y")),
            ])
            try expectEqual(snapshot.issuesByAccount.map(\.account), ["b", "a"])
            try expectEqual(snapshot.issuesByAccount[0].issues.count, 2)
        },
        TestCase("issue: falta de autenticación pide gh auth login") {
            let unauthorized = RefreshIssue(account: "me", repo: nil, error: .unauthorized)
            let tokenFailed = RefreshIssue(account: "me", repo: nil, error: .commandFailed(command: "gh auth token --user me", status: 1, stderr: "no"))
            let other = RefreshIssue(account: "me", repo: nil, error: .commandFailed(command: "gh auth status", status: 1, stderr: "no"))
            try expect(unauthorized.requiresLogin)
            try expect(tokenFailed.requiresLogin)
            try expect(!other.requiresLogin)
            try expectEqual(unauthorized.message, "The account me isn't signed in")
        },
        TestCase("issue: mensajes de rate limit y genéricos") {
            let reset = at(30)
            let limited = RefreshIssue(account: "me", repo: RepoRef(owner: "o", name: "r"), error: .rateLimited(resetAt: reset))
            try expectEqual(limited.message, "GitHub rate limit reached · retrying at \(ClockTime.hhmm(reset))")
            let generic = RefreshIssue(account: "me", repo: RepoRef(owner: "o", name: "r"), error: .graphQL("x"))
            try expectEqual(generic.message, "o/r: \(PRBarError.graphQL("x").localizedDescription)")
            let accountLevel = RefreshIssue(account: "me", repo: nil, error: .toolNotFound("gh"))
            try expect(accountLevel.message.hasPrefix("me: "))
        },
        TestCase("prstore: refresh publica, persiste y avisa con el snapshot anterior") {
            let url = try temporaryDirectory().appendingPathComponent("config.json")
            let configStore = await ConfigStore(fileURL: url)
            try await configStore.update { $0 = config(account("me")) }
            let stateStore = SnapshotStore(url: url.deletingLastPathComponent().appendingPathComponent("state.json"))
            let changes = Box<[(Snapshot?, Snapshot)]>([])
            let store = await PRStore(
                builder: builder(FakeAPI(prs: ["o/r": repoPRs(makePR())])),
                configStore: configStore, stateStore: stateStore, now: { t0 },
                onChange: { changes.value.append(($0, $1)) }
            )
            await store.refresh()
            await store.refresh()
            try expectEqual(changes.value.count, 2)
            try expectEqual(changes.value[0].0, nil)
            try expectEqual(changes.value[1].0?.items.count, 1)
            let publishedBadge = await store.snapshot?.badgeCount
            try expectEqual(publishedBadge, 1)
            try expectEqual(stateStore.load()?.items.count, 1)
        },
        TestCase("prstore: no refresca mientras dura el rate limit") {
            let url = try temporaryDirectory().appendingPathComponent("config.json")
            let configStore = await ConfigStore(fileURL: url)
            let stateStore = SnapshotStore(url: url.deletingLastPathComponent().appendingPathComponent("state.json"))
            stateStore.save(Snapshot(items: [], fetchedAt: t0, rateLimitedUntil: at(10)))
            let calls = Box(0)
            let store = await PRStore(builder: builder(FakeAPI()), configStore: configStore, stateStore: stateStore, now: { t0 }, onChange: { _, _ in calls.value += 1 })
            await store.refresh()
            try expectEqual(calls.value, 0)
        },
    ]
}
