import Foundation
import PRBarCore

/// Fictional sample data for snapshot mode: accounts, repos, people, PRs, reviews, responses and history. Every
/// date is relative to `now`, so the ages ("25 min", "2h") read naturally whenever the snapshots are rendered.
struct SnapshotFixtures {
    let now: Date

    // MARK: Accounts, repos and people

    static let personal = "dev-sam"
    static let work = "dev-sam-work"
    static let webApp = RepoRef(owner: "acme", name: "web-app")
    static let api = RepoRef(owner: "acme", name: "api")
    static let mobile = RepoRef(owner: "acme", name: "mobile")
    static let people = ["lucia-m", "tomas-r", "ana-p"]

    static let ghAccounts = [GHAccount(login: personal, isActive: true), GHAccount(login: work, isActive: false)]
    static let tools = ResolvedTools(gh: "/opt/homebrew/bin/gh", git: "/usr/bin/git", claude: "/usr/local/bin/claude")

    var config: AppConfig {
        var config = AppConfig()
        config.refreshIntervalMinutes = 2
        config.launchAtLogin = true
        config.accounts = [
            AccountConfig(login: Self.personal, repos: [
                RepoConfig(
                    owner: "acme", name: "web-app", localPath: "/Users/sam/Code/web-app", baseBranches: ["develop", "main"],
                    slackChannelID: "C0WEBPRS", slackChannelName: "web-prs", slackEnabledAt: date(days: -20),
                    watchedUsers: ["ana-p", "lucia-m", "tomas-r"], worktreeDir: "/Users/sam/Code/worktrees",
                    testCommand: "npm test -- --watchAll=false"
                ),
                RepoConfig(
                    owner: "acme", name: "api", localPath: "/Users/sam/Code/api", baseBranches: ["main"],
                    slackChannelID: "C0APIPRS", slackChannelName: "api-prs", slackEnabledAt: date(days: -20),
                    watchedUsers: ["tomas-r"], testCommand: "make test"
                ),
            ]),
            AccountConfig(login: Self.work, repos: [
                RepoConfig(owner: "acme", name: "mobile", localPath: "/Users/sam/Code/mobile", baseBranches: ["develop"],
                           watchedUsers: ["ana-p"]),
            ]),
        ]
        config.setSlackProvider(.claudeConnector, now: date(days: -20))
        config.setSlackEnabled(true, now: date(days: -20))
        config.claude.model = .opus
        return config
    }

    static let skills = [
        ClaudeSkillEntry(id: ClaudeSettings.defaultReviewSkill, description: "Comprehensive PR review using specialized agents",
                         source: .plugin(name: "pr-review-toolkit", directory: "/plugins/pr-review-toolkit"), availability: .available),
        ClaudeSkillEntry(id: ClaudeSettings.defaultFilterSkill,
                         description: "Verify review feedback against the code before acting on it",
                         source: .plugin(name: "superpowers", directory: "/plugins/superpowers"), availability: .available),
        ClaudeSkillEntry(id: "team-conventions", description: "Acme's code review checklist", source: .user, availability: .available),
    ]

    static let slackChannels = [
        SlackChannel(id: "C0WEBPRS", name: "web-prs", isPrivate: false, isMember: true),
        SlackChannel(id: "C0APIPRS", name: "api-prs", isPrivate: false, isMember: true),
        SlackChannel(id: "C0MOBILE", name: "mobile-prs", isPrivate: false, isMember: true),
        SlackChannel(id: "C0RELEAS", name: "releases", isPrivate: true, isMember: true),
    ]

    static var gitHubAPI: SnapshotGitHubAPI {
        SnapshotGitHubAPI(
            repos: [webApp, api, mobile, RepoRef(owner: "acme", name: "design-system"), RepoRef(owner: "dev-sam", name: "dotfiles")],
            branches: [
                webApp.fullName: ["develop", "main", "release/2.4", "staging"],
                api.fullName: ["main", "develop", "hotfix/payments"],
                mobile.fullName: ["develop", "main"],
            ],
            defaultBranches: [webApp.fullName: "develop", api.fullName: "main", mobile.fullName: "develop"],
            users: [
                GitHubUser(login: "ana-p", name: "Ana P.", avatarURL: nil),
                GitHubUser(login: "lucia-m", name: "Lucía M.", avatarURL: nil),
                GitHubUser(login: "tomas-r", name: "Tomás R.", avatarURL: nil),
                GitHubUser(login: "dev-sam", name: "Sam", avatarURL: nil),
            ]
        )
    }

    // MARK: PRs

    /// To Review, idle.
    var rateLimiting: ClassifiedPR {
        item(Self.webApp, 491, "Add rate limiting to sync endpoint", author: "lucia-m", base: "develop", head: "feat/sync-rate-limit",
             ci: .success, adds: 214, dels: 38, updated: -25, category: .toReview, account: Self.personal,
             requested: [Self.personal])
    }

    /// To Review, "Reviewing…" with 3 agents; also the PR of the Review window.
    var loginRedirect: ClassifiedPR {
        item(Self.api, 317, "Fix login redirect when session expires", author: "tomas-r", base: "main", head: "fix/session-redirect",
             ci: .pending, adds: 46, dels: 12, updated: -12, category: .toReview, account: Self.personal,
             requested: [Self.personal])
    }

    /// Updated Since My Review, with a ready review of 4 comments.
    var reactQuery: ClassifiedPR {
        item(Self.webApp, 482, "Migrate settings page to React Query", author: "ana-p", base: "develop", head: "refactor/settings-react-query",
             ci: .success, adds: 389, dels: 271, updated: -40, category: .updatedSinceMyReview, account: Self.personal,
             reviews: [PRReview(author: Self.personal, isBot: false, state: .commented, submittedAt: date(minutes: -60 * 26))])
    }

    /// My PRs with Feedback: changes requested, Respond.
    var csvExport: ClassifiedPR {
        item(Self.webApp, 475, "Add CSV export for reports", author: Self.personal, base: "develop", head: "feat/csv-export",
             ci: .failure, adds: 158, dels: 9, updated: -95, category: .myFeedback, account: Self.personal,
             lastCommit: -60 * 5,
             reviews: [PRReview(author: "tomas-r", isBot: false, state: .changesRequested, submittedAt: date(minutes: -95))],
             comments: [PRComment(author: "lucia-m", isBot: false, createdAt: date(minutes: -120))])
    }

    var others: [ClassifiedPR] {
        [
            item(Self.mobile, 96, "Bump React Native to 0.76", author: "ana-p", base: "develop", head: "chore/rn-076",
                 draft: true, ci: .pending, adds: 1204, dels: 988, updated: -60 * 3, category: .other, account: Self.work),
            item(Self.api, 309, "Handle 429 responses from the payments provider", author: Self.personal, base: "main",
                 head: "fix/payments-429", ci: .success, adds: 73, dels: 15, updated: -60 * 20, category: .other, account: Self.personal),
        ]
    }

    var snapshot: Snapshot {
        Snapshot(items: [rateLimiting, loginRedirect, reactQuery, csvExport] + others, fetchedAt: now.addingTimeInterval(-50))
    }

    /// Nothing actionable: only "Other".
    var caughtUpSnapshot: Snapshot {
        Snapshot(items: others, fetchedAt: now.addingTimeInterval(-50))
    }

    // MARK: Reviews

    /// The ready review of web-app#482 (4 comments).
    var reactQueryDraft: ReviewDraft {
        ReviewDraft(
            prID: reactQuery.id, repo: Self.webApp, number: 482, title: reactQuery.pr.title, url: reactQuery.pr.url,
            author: "ana-p", headOid: reactQuery.pr.headOid, account: Self.personal,
            summary: "Moves the settings page from hand-written fetch calls to React Query hooks.",
            items: (1...4).map { index in
                ReviewItem(finding: ReviewFinding(id: "f\(index)", severity: index == 1 ? .medium : .low,
                                                  file: "src/settings/useSettings.ts", line: 10 * index,
                                                  title: "Finding \(index)", body: "Comment \(index)"),
                           keep: true, reason: nil)
            },
            language: PRLanguage(code: "es")
        )
    }

    /// The review of api#317 shown in the Review window: 3 kept findings, 2 discarded, comments in Spanish.
    var loginRedirectDraft: ReviewDraft {
        ReviewDraft(
            prID: loginRedirect.id, repo: Self.api, number: 317, title: loginRedirect.pr.title, url: loginRedirect.pr.url,
            author: "tomas-r", headOid: loginRedirect.pr.headOid, account: Self.personal,
            summary: "The PR sends users back to the page they were on after their session expires, by saving a returnTo parameter before redirecting to /login. The approach is sound; the main risk is that returnTo isn’t validated, which allows an open redirect.",
            items: [
                ReviewItem(finding: ReviewFinding(
                    id: "open-redirect", severity: .high, file: "src/auth/session.ts", line: 88,
                    title: "El parámetro returnTo se usa sin validar (open redirect)",
                    body: """
                    `returnTo` viene de la query y se pasa directo a `res.redirect()`. Un link como `/login?returnTo=https://evil.example` manda al usuario a otro dominio después de iniciar sesión.

                    Sugerencia: aceptar solo rutas relativas del mismo origen:

                    ```ts
                    const safe = returnTo?.startsWith("/") && !returnTo.startsWith("//") ? returnTo : "/";
                    ```
                    """
                ), keep: true, reason: "Confirmed: session.ts:88 redirects to the raw query value."),
                ReviewItem(finding: ReviewFinding(
                    id: "api-401", severity: .medium, file: "src/auth/middleware.ts", line: 41,
                    title: "Las rutas de la API responden 302 a /login en vez de 401",
                    body: "Para pedidos `fetch` desde el front, un 302 a HTML rompe el manejo de errores. Conviene responder 401 cuando el header `Accept` es JSON y dejar el redirect solo para navegación."
                ), keep: true, reason: "Holds: the middleware doesn't check the Accept header."),
                ReviewItem(finding: ReviewFinding(
                    id: "missing-test", severity: .low, file: "src/auth/__tests__/session.test.ts", line: 12,
                    title: "Falta un test para la sesión renovada durante el redirect",
                    body: "Agregaría un caso donde el token se renueva entre el redirect y el login, para cubrir el cambio en `refreshSession()`."
                ), keep: true, reason: nil),
                ReviewItem(finding: ReviewFinding(
                    id: "hardcoded-ttl", severity: .medium, file: "src/config/env.ts", line: 7,
                    title: "Duración de la sesión fija en el código", body: "El TTL de 30 minutos está hardcodeado."
                ), keep: false, reason: "Already read from SESSION_TTL in env.ts:3; 30 minutes is only the fallback."),
                ReviewItem(finding: ReviewFinding(
                    id: "rename", severity: .low, file: "src/auth/session.ts", line: 120,
                    title: "Renombrar expTs a expiresAt", body: "Un nombre más claro ayudaría."
                ), keep: false, reason: "Style preference; expTs follows the naming used across the auth module."),
            ],
            language: PRLanguage(code: "es")
        )
    }

    static let generalComment = "¡Buen trabajo! El flujo de redirect funciona bien; dejé un par de comentarios sobre la validación de returnTo."

    /// The published review of api#317 (3 comments + general comment, Request Changes).
    var publishedLoginRedirect: ReviewRecord {
        let draft = loginRedirectDraft
        return ReviewRecord(
            draft: draft, startedAt: date(minutes: -18), finishedAt: date(minutes: -2), status: .published,
            published: Dictionary(uniqueKeysWithValues: draft.items.filter(\.keep).map { ($0.id, $0.finding.body) }),
            generalComment: Self.generalComment, action: .requestChanges,
            reviewURL: URL(string: "https://github.com/acme/api/pull/317#pullrequestreview-2201")!
        )
    }

    // MARK: Respond

    var csvDraft: RespondDraft {
        let pr = csvExport.pr
        return RespondDraft(
            prID: csvExport.id, repo: Self.webApp, number: 475, title: pr.title, url: pr.url, headRef: pr.headRef,
            account: Self.personal,
            worktree: ResolvedWorktree(path: "/Users/sam/Code/worktrees/web-app-475", origin: .dedicated,
                                       localPath: "/Users/sam/Code/web-app", ref: "refs/prbar/respond-475"),
            startHeadOid: "4be81c09d2a7f3e6b5c4d3e2f1a0b9c8d7e6f5a4",
            items: [
                RespondItem(
                    feedback: feedback("thread:1", .thread, path: "src/reports/export.ts", line: 54, author: "tomas-r", minutes: -95,
                                       body: "Esto arma todo el CSV en memoria antes de mandarlo. Con reportes de 100k filas se va a quedar sin memoria. ¿Podemos hacer streaming?"),
                    assessment: "Valid: buildCsv() joins every row into one string. Streaming the rows keeps memory flat.",
                    action: .fix, fixPlan: "Write rows to the response as they come from the cursor instead of building one string.",
                    reply: ""),
                RespondItem(
                    feedback: feedback("thread:2", .thread, path: "src/reports/csv.ts", line: 18, author: "lucia-m", minutes: -120,
                                       body: "¿Por qué no usar csv-stringify en vez de escapar a mano?"),
                    assessment: "A question, not a bug: the hand-written escaping is small and covered by tests.",
                    action: .reply, fixPlan: "",
                    reply: "Preferí no sumar una dependencia para esto: el escape cubre comillas, comas y saltos de línea, y está testeado en csv.test.ts."),
                RespondItem(
                    feedback: feedback("review:3", .reviewBody, path: nil, line: nil, author: "ana-p", minutes: -100,
                                       body: "Las fechas salen en UTC; deberían respetar la zona horaria del usuario."),
                    assessment: "Valid: dates are formatted with toISOString(). The user's timezone is available on the request.",
                    action: .fixAndReply, fixPlan: "Format dates with the timezone from the request's user settings.",
                    reply: "¡Buen punto! Ahora las fechas salen en la zona horaria del usuario."),
            ],
            language: PRLanguage(code: "es")
        )
    }

    static let testCommand = "npm test -- --watchAll=false"

    var csvResult: RespondResult {
        RespondResult(
            items: [
                ItemResult(id: "thread:1", status: .committed, commit: "9f3c2a1e7b6d5c4f3e2d1c0b9a8f7e6d5c4b3a21",
                           summary: "Rows are streamed from the cursor to the response."),
                ItemResult(id: "review:3", status: .committed, commit: "c41d8e2f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c19",
                           summary: "Dates use the user's timezone."),
            ],
            diffStat: """
             package.json                      |  1 +
             src/reports/export.ts             | 41 +++++++++++++++++++-----------
             src/reports/formatDate.ts         | 18 +++++++++++++
             3 files changed, 45 insertions(+), 15 deletions(-)
            """,
            tests: nil,
            sensitiveChanges: ["package.json"],
            headOid: "c41d8e2f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c19",
            gitIntegrity: "snapshot",
            diff: """
            diff --git a/package.json b/package.json
            --- a/package.json
            +++ b/package.json
            @@ -24,6 +24,7 @@
                 "date-fns": "^3.6.0",
            +    "date-fns-tz": "^3.2.0",
                 "express": "^4.21.1",
            diff --git a/src/reports/export.ts b/src/reports/export.ts
            --- a/src/reports/export.ts
            +++ b/src/reports/export.ts
            @@ -48,14 +48,19 @@ export async function exportReport(req: Request, res: Response) {
            -  const rows = await db.reports.findAll({ where: filters });
            -  const csv = buildCsv(rows);
            -  res.send(csv);
            +  res.setHeader("Content-Type", "text/csv; charset=utf-8");
            +  res.write(csvHeader(columns));
            +  for await (const row of db.reports.cursor({ where: filters })) {
            +    res.write(csvRow(row, { timeZone: req.user.timeZone }));
            +  }
            +  res.end();
             }
            """,
            diffTruncated: false,
            commits: [
                CommitInfo(sha: "9f3c2a1e7b6d5c4f3e2d1c0b9a8f7e6d5c4b3a21", message: "Stream CSV rows instead of building the file in memory"),
                CommitInfo(sha: "c41d8e2f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c19", message: "Format report dates in the user's timezone"),
            ]
        )
    }

    var csvTests: TestRun {
        TestRun(command: Self.testCommand, passed: true, outputTail: """
        PASS src/reports/__tests__/export.test.ts
        PASS src/reports/__tests__/csv.test.ts
        PASS src/reports/__tests__/formatDate.test.ts

        Test Suites: 42 passed, 42 total
        Tests:       318 passed, 318 total
        Time:        8.41 s
        """)
    }

    // MARK: Chat

    /// The chat of the api#317 review: a question that narrows #2 and a finding Claude added (#6).
    var reviewChat: ChatSession {
        var session = ChatSession(prID: loginRedirect.id, kind: .review)
        session.claudeSessionID = UUID(uuidString: "0D5C4E61-7A1B-4C1E-9F1A-2B3C4D5E6F70")
        session.messages = [
            ChatMessage(role: .user, text: "Is #2 really a problem? Most of our API calls already send Accept: application/json.",
                        createdAt: date(minutes: -9)),
            ChatMessage(role: .assistant,
                        text: "Mostly yes: `fetchJSON()` in `src/api/client.ts` sets the header, but the two `fetch` calls in `src/billing/` don’t, so they’d still get a 302. I narrowed #2 to say exactly that.",
                        createdAt: date(minutes: -8), changes: [.findingEdited(id: "api-401")]),
            ChatMessage(role: .user, text: "Agregá un finding porque POST /login no tiene rate limit", createdAt: date(minutes: -4)),
            ChatMessage(role: .assistant,
                        text: "Listo, agregué el #6: `POST /login` no limita los intentos. Lo marqué como medio y sugiero reusar el middleware `rateLimit`.",
                        createdAt: date(minutes: -3), changes: [.findingAdded(id: "c1")]),
        ]
        return session
    }

    /// The Review window's state after `reviewChat`: #2 rewritten and #6 added and selected.
    var reviewChatEdits: ReviewEdits {
        var edits = ReviewEdits.initial(for: loginRedirectDraft)
        edits.bodies["api-401"] = "Las llamadas `fetch` de `src/billing/` no mandan `Accept: application/json`, así que reciben un 302 a HTML en vez de un 401. Conviene responder 401 cuando el pedido no es de navegación."
        edits.added = [ReviewItem(
            finding: ReviewFinding(id: "c1", severity: .medium, file: "src/auth/login.ts", line: 23,
                                   title: "POST /login no limita los intentos",
                                   body: "Sin rate limit se pueden probar contraseñas sin freno. Sugiero reusar el middleware `rateLimit` de `src/api/limits.ts`."),
            keep: true, reason: ChatActions.addedReason)]
        edits.selected.insert("c1")
        edits.generalComment = Self.generalComment
        return edits
    }

    /// The chat of the web-app#475 respond: a reply drafted for Lucía and a change to the fixes.
    var respondChat: ChatSession {
        var session = ChatSession(prID: csvExport.id, kind: .respond)
        session.claudeSessionID = UUID(uuidString: "5A4B3C2D-1E0F-4A1B-8C2D-3E4F5A6B7C8D")
        session.messages = [
            ChatMessage(role: .user, text: "Contestale a Lucía que podemos pasar a csv-stringify más adelante",
                        createdAt: date(minutes: -12)),
            ChatMessage(role: .assistant,
                        text: "Actualicé la respuesta a @lucia-m: explica por qué el escape a mano alcanza hoy y propone pasar a csv-stringify en otro PR.",
                        createdAt: date(minutes: -11), changes: [.replyDrafted(commentID: "thread:2")]),
            ChatMessage(role: .user, text: "formatDate should fall back to UTC when the user has no timezone",
                        createdAt: date(minutes: -6)),
            ChatMessage(role: .assistant,
                        text: "Done: `formatDate()` falls back to UTC and there’s a test for it. PRBar committed the change; check the diff before pushing.",
                        createdAt: date(minutes: -5),
                        changes: [.filesChanged(["src/reports/formatDate.ts", "src/reports/formatDate.test.ts"])]),
        ]
        return session
    }

    // MARK: History

    /// ~6 records, the published review of api#317 the newest (it's the one selected).
    var historyReviews: [ReviewRecord] {
        let ready = ReviewRecord(draft: reactQueryDraft, startedAt: date(minutes: -55), finishedAt: date(minutes: -41), status: .ready)
        let failedDraft = ReviewDraft(
            prID: "acme/mobile#96", repo: Self.mobile, number: 96, title: "Bump React Native to 0.76",
            url: URL(string: "https://github.com/acme/mobile/pull/96")!, author: "ana-p", headOid: "a1b2c3d", account: Self.work,
            summary: "", items: []
        )
        let failed = ReviewRecord(draft: failedDraft, startedAt: date(days: -1, minutes: -30), finishedAt: date(days: -1, minutes: -26),
                                  status: .failed, errorMessage: "Claude stopped after 20 minutes without an answer.")
        let approvedDraft = ReviewDraft(
            prID: "acme/web-app#466", repo: Self.webApp, number: 466, title: "Add CSV export for reports (part 1)",
            url: URL(string: "https://github.com/acme/web-app/pull/466")!, author: "lucia-m", headOid: "d4e5f6a", account: Self.personal,
            summary: "Adds the export button and the endpoint skeleton.", items: [], language: PRLanguage(code: "es")
        )
        let approved = ReviewRecord(draft: approvedDraft, startedAt: date(days: -9), finishedAt: date(days: -9, minutes: 9),
                                    status: .published, action: .approve,
                                    reviewURL: URL(string: "https://github.com/acme/web-app/pull/466#pullrequestreview-1980")!)
        return [publishedLoginRedirect, ready, failed, approved]
    }

    var historyResponds: [RespondRecord] {
        var csv = csvDraft
        csv.id = UUID()
        let selections = Dictionary(uniqueKeysWithValues: csv.items.map { ($0.id, RespondSelection.defaults(for: $0)) })
        var result = csvResult
        result.tests = csvTests
        let done = RespondRecord(
            draft: csv, selections: selections, result: result,
            posted: Dictionary(uniqueKeysWithValues: csv.items.map {
                ($0.id, PostedReply(id: $0.id, url: URL(string: "https://github.com/acme/web-app/pull/475#discussion_r\($0.id.count)")!))
            }),
            pushed: true, startedAt: date(minutes: -60 * 3), finishedAt: date(minutes: -60 * 3 + 14)
        )
        let paymentsDraft = RespondDraft(
            prID: "acme/api#309", repo: Self.api, number: 309, title: "Handle 429 responses from the payments provider",
            url: URL(string: "https://github.com/acme/api/pull/309")!, headRef: "fix/payments-429", account: Self.personal,
            worktree: ResolvedWorktree(path: "/Users/sam/Code/api-worktrees/api-309", origin: .dedicated),
            startHeadOid: "77aa88bb", items: [
                RespondItem(feedback: feedback("thread:9", .thread, path: "src/payments/client.ts", line: 30, author: "tomas-r",
                                               minutes: -60 * 50, body: "¿Hace falta un tope de reintentos?"),
                            assessment: "Yes: retries are unbounded.", action: .fixAndReply,
                            fixPlan: "Cap retries at 3 with exponential backoff.", reply: "Sí, quedó con un máximo de 3."),
            ]
        )
        let payments = RespondRecord(
            draft: paymentsDraft,
            selections: ["thread:9": RespondSelection.defaults(for: paymentsDraft.items[0])],
            posted: ["thread:9": PostedReply(id: "thread:9", url: URL(string: "https://github.com/acme/api/pull/309#discussion_r1")!)],
            pushed: true, startedAt: date(days: -2), finishedAt: date(days: -2, minutes: 11)
        )
        return [done, payments]
    }

    // MARK: Helpers

    func date(days: Int = 0, minutes: Int = 0) -> Date {
        now.addingTimeInterval(TimeInterval(days * 86_400 + minutes * 60))
    }

    private func item(
        _ repo: RepoRef, _ number: Int, _ title: String, author: String, base: String, head: String, draft: Bool = false,
        ci: CIState, adds: Int, dels: Int, updated: Int, category: PRCategory, account: String, lastCommit: Int? = nil,
        reviews: [PRReview] = [], comments: [PRComment] = [], requested: [String] = []
    ) -> ClassifiedPR {
        let pr = PullRequest(
            repo: repo, number: number, title: title, url: URL(string: "https://github.com/\(repo.fullName)/pull/\(number)")!,
            isDraft: draft, author: author, authorAvatarURL: nil, baseRef: base, headRef: head,
            headOid: String(format: "%07x", number * 104_729), additions: adds, deletions: dels,
            createdAt: date(days: -3), updatedAt: date(minutes: updated), lastCommitAt: date(minutes: lastCommit ?? updated),
            ciState: ci, reviewDecision: reviews.contains { $0.state == .changesRequested } ? .changesRequested : .reviewRequired,
            reviews: reviews, comments: comments, requestedReviewers: requested
        )
        return ClassifiedPR(pr: pr, category: category, account: account)
    }

    private func feedback(_ id: String, _ kind: FeedbackItem.Kind, path: String?, line: Int?, author: String, minutes: Int,
                          body: String) -> FeedbackItem {
        FeedbackItem(id: id, kind: kind, path: path, line: line, isOutdated: false, comments: [
            FeedbackComment(databaseID: id.unicodeScalars.reduce(1_000) { $0 + Int($1.value) }, author: author, isBot: false, body: body,
                            createdAt: date(minutes: minutes),
                            url: URL(string: "https://github.com/acme/web-app/pull/475#discussion_r\(id.count)")!),
        ])
    }
}
