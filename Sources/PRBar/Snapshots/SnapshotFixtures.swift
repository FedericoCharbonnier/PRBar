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
        // Run On (spec J): devbox is the default and acme/api picks it explicitly.
        try? config.addRunner(Self.devbox)
        try? config.setDefaultRunTarget(.runner(Self.devbox.name))
        config.setRunOn(.runner(Self.devbox.name), repoID: Self.api.fullName, login: Self.personal)
        return config
    }

    // MARK: Run On (spec J) — nothing connects in snapshot mode: only the checks and placements are filled in.

    static let devbox = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(user: "fede", host: "devbox.lab"),
                                          remoteDir: "~/.prbar", fallbackToLocal: true)

    /// devbox checked 5 minutes ago with Test Connection (so "logged in" shows).
    var devboxCheck: RunnerHostInfo {
        RunnerHostInfo(host: Self.devbox.name, os: "Linux", arch: "x86_64", home: "/home/fede", gitPath: "/usr/bin/git",
                       gitVersion: "git version 2.43.0", claudePath: "/home/fede/.local/bin/claude",
                       claudeVersion: "2.1.318 (Claude Code)", perl: true, quotingOK: true,
                       root: "/home/fede/.prbar/installs/1f2e3d4c5b6a7980", problems: [], checkedAt: date(minutes: -5),
                       claudeLoggedIn: true)
    }

    /// The review in progress (acme/api#317) runs on devbox; the last web-app job fell back to this Mac (the popover
    /// row of #482 and the warning in Settings › Repos).
    var placements: RunnerPlacements {
        var placements = RunnerPlacements()
        placements.record(.remote(host: Self.devbox.name), prID: loginRedirect.id, repo: Self.api)
        placements.record(.fallback(RunnerFallback(host: Self.devbox.name, cause: .unreachable)), prID: reactQuery.id, repo: Self.webApp)
        return placements
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
        Snapshot(items: [rateLimiting, loginRedirect, reactQuery, csvExport, idempotencyKeys, reportsDarkMode] + others,
                 fetchedAt: now.addingTimeInterval(-50), repoMergeSettings: Self.mergeSettings)
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

    // MARK: Instructions

    static let styleRuleID = UUID(uuidString: "0B1C2D3E-4F50-4617-8293-A4B5C6D7E8F9")!

    /// Five rules (global, per repo with one off, and one of a repo that isn't configured) and an instructions chat that
    /// added one.
    var instructions: InstructionsFile {
        let rules = [
            Rule(id: Self.styleRuleID, scope: .global, appliesTo: [.review],
                 text: "Don’t comment on code style or formatting: the linter handles it.", source: .settingsChat,
                 createdAt: date(minutes: -30)),
            Rule(id: UUID(uuidString: "1C2D3E4F-5061-4728-93A4-B5C6D7E8F90A")!, scope: .global, appliesTo: [.review, .respond],
                 text: "Keep GitHub comments short and friendly; suggest code when it helps.", source: .manual,
                 createdAt: date(days: -30)),
            Rule(id: UUID(uuidString: "2D3E4F50-6172-4839-A4B5-C6D7E8F90A1B")!, scope: .repo("acme/web-app"), appliesTo: [.respond],
                 text: "Usamos React Query: no agregues fetch directo.", source: .prChat, createdAt: date(days: -3)),
            Rule(id: UUID(uuidString: "3E4F5061-7283-494A-B5C6-D7E8F90A1B2C")!, scope: .repo("acme/api"), appliesTo: [.review],
                 text: "Errors go through AppError; flag raw throws in handlers.", source: .manual, createdAt: date(days: -8),
                 enabled: false),
            // A repo that isn't configured: its rule shows under "Other Repos".
            Rule(id: UUID(uuidString: "50617283-94A5-4B6C-D7E8-F90A1B2C3D4E")!,
                 scope: .repo("acme/legacy-site"), appliesTo: [.review],
                 text: "Only flag security issues: this site is frozen.", source: .manual, createdAt: date(days: -40)),
        ]
        var chat = InstructionsChat()
        chat.claudeSessionID = UUID(uuidString: "4F506172-8394-4A5B-C6D7-E8F90A1B2C3D")
        chat.messages = [
            ChatMessage(role: .user, text: "No comentes estilo, eso lo resuelve el linter", createdAt: date(minutes: -31)),
            ChatMessage(role: .assistant,
                        text: "Listo: agregué una regla global para Review. Si querés que también valga para los fixes, decime.",
                        createdAt: date(minutes: -30), changes: [.ruleAdded(id: Self.styleRuleID.uuidString)],
                        restore: ChatRestorePoint(rules: Array(rules.dropFirst()), rulesAfter: rules)),
        ]
        return InstructionsFile(rules: rules, chat: chat)
    }

    /// Docs findings discarded in 3 PRs of acme/api: Settings › Instructions and the posted review suggest a rule.
    var discards: [DiscardEvent] {
        [("PR_api_301", -2), ("PR_api_305", -6), ("PR_api_309", -11)].map { pr, days in
            DiscardEvent(repo: "acme/api", prID: pr, category: .docs, title: "Document the new parameter", date: date(days: days))
        }
    }

    /// `reviewChat` plus a request to remember something and Claude's rule proposal, pending.
    var reviewChatWithRule: ChatSession {
        var session = reviewChat
        session.messages += [
            ChatMessage(role: .user, text: "De ahora en más, en api no marques los TODO", createdAt: date(minutes: -2)),
            ChatMessage(role: .assistant,
                        text: "Puedo recordarlo como regla para las reviews de acme/api. Revisala y guardala si te sirve.",
                        createdAt: date(minutes: -1),
                        proposals: [RuleProposal(scope: .repo("acme/api"), appliesTo: [.review],
                                                 text: "No marques los comentarios TODO como findings.")]),
        ]
        return session
    }

    // MARK: History

    /// ~6 records, the published review of api#317 the newest (it's the one selected).
    var historyReviews: [ReviewRecord] {
        var readyDraft = reactQueryDraft
        readyDraft.usage = Self.usage(minutes: 6.2, input: 48_000, output: 7_300, cacheRead: 380_000, cost: 0.61)
        let ready = ReviewRecord(draft: readyDraft, startedAt: date(minutes: -55), finishedAt: date(minutes: -41), status: .ready)
        let failedDraft = ReviewDraft(
            prID: "acme/mobile#96", repo: Self.mobile, number: 96, title: "Bump React Native to 0.76",
            url: URL(string: "https://github.com/acme/mobile/pull/96")!, author: "ana-p", headOid: "a1b2c3d", account: Self.work,
            summary: "", items: []
        )
        var stoppedDraft = failedDraft
        stoppedDraft.usage = .run(duration: 20 * 60, tokens: nil, cost: nil)
        let failed = ReviewRecord(draft: stoppedDraft, startedAt: date(days: -1, minutes: -30), finishedAt: date(days: -1, minutes: -26),
                                  status: .failed, errorMessage: "Claude stopped after 20 minutes without an answer.")
        let approvedDraft = ReviewDraft(
            prID: "acme/web-app#466", repo: Self.webApp, number: 466, title: "Add CSV export for reports (part 1)",
            url: URL(string: "https://github.com/acme/web-app/pull/466")!, author: "lucia-m", headOid: "d4e5f6a", account: Self.personal,
            summary: "Adds the export button and the endpoint skeleton.", items: [], language: PRLanguage(code: "es")
        )
        let approved = ReviewRecord(draft: approvedDraft, startedAt: date(days: -9), finishedAt: date(days: -9, minutes: 9),
                                    status: .published, action: .approve,
                                    reviewURL: URL(string: "https://github.com/acme/web-app/pull/466#pullrequestreview-1980")!)
        var published = publishedLoginRedirect
        published.draft.usage = Self.usage(minutes: 9.6, input: 83_000, output: 11_900, cacheRead: 560_000, cost: 0.93)
        return [published, ready, failed, approved]
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
            pushed: true, startedAt: date(minutes: -60 * 3), finishedAt: date(minutes: -60 * 3 + 14),
            usage: Self.usage(minutes: 11.3, input: 99_000, output: 15_300, cacheRead: 730_000, cost: 1.21)
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
        return [historyCIFix, done, payments]
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

extension SnapshotFixtures {
    /// Versión nueva ficticia para la ventana "Update PRBar" y Settings › General.
    static let updateRelease = ReleaseInfo(
        version: SemanticVersion(1, 3, 0), tag: "v1.3.0", title: "PRBar 1.3.0",
        notes: """
        - Chat with Claude in the Review and Respond windows
        - New `prbar` command-line tool
        - Faster refresh with many repos
        """,
        url: URL(string: "https://github.com/FedericoCharbonnier/PRBar/releases/tag/v1.3.0")!, publishedAt: nil
    )
}

// MARK: - Ready to Merge (spec F)

extension SnapshotFixtures {
    /// Ready to Merge: aprobado, checks pasando; Merge habilitado (squash por defecto) y la PR del diálogo.
    var idempotencyKeys: ClassifiedPR {
        readyToMerge(
            item(Self.api, 322, "Add idempotency keys to payment retries", author: Self.personal, base: "main",
                 head: "feat/idempotency-keys", ci: .success, adds: 96, dels: 14, updated: -30, category: .readyToMerge,
                 account: Self.personal, lastCommit: -60 * 3,
                 reviews: [PRReview(author: "tomas-r", isBot: false, state: .approved, submittedAt: date(minutes: -40))]),
            status: .unstable, commits: 3
        )
    }

    /// Ready to Merge pero bloqueado: un check requerido todavía corre.
    var reportsDarkMode: ClassifiedPR {
        readyToMerge(
            item(Self.webApp, 488, "Dark mode for the reports page", author: Self.personal, base: "develop",
                 head: "feat/reports-dark-mode", ci: .pending, adds: 241, dels: 87, updated: -15, category: .readyToMerge,
                 account: Self.personal, lastCommit: -60,
                 reviews: [PRReview(author: "lucia-m", isBot: false, state: .approved, submittedAt: date(minutes: -20))]),
            status: .blocked, commits: 7
        )
    }

    /// Lo que GitHub dice de cada repo para la cuenta personal.
    static var mergeSettings: [String: RepoMergeSettings] {
        [
            Snapshot.scope(account: personal, repo: api): RepoMergeSettings(
                squashAllowed: true, mergeCommitAllowed: true, rebaseAllowed: false, viewerDefault: .squash,
                deleteBranchOnMerge: true, viewerPermission: "WRITE"),
            Snapshot.scope(account: personal, repo: webApp): RepoMergeSettings(
                squashAllowed: true, mergeCommitAllowed: false, rebaseAllowed: true, viewerDefault: .squash,
                deleteBranchOnMerge: false, viewerPermission: "ADMIN"),
        ]
    }

    /// `base` aprobado y con datos de merge.
    private func readyToMerge(_ base: ClassifiedPR, status: MergeStateStatus, commits: Int,
                              mergeable: MergeableState = .mergeable) -> ClassifiedPR {
        let pr = base.pr
        let approved = PullRequest(
            repo: pr.repo, number: pr.number, title: pr.title, url: pr.url, isDraft: pr.isDraft, author: pr.author,
            authorAvatarURL: pr.authorAvatarURL, baseRef: pr.baseRef, headRef: pr.headRef, headOid: pr.headOid,
            additions: pr.additions, deletions: pr.deletions, createdAt: pr.createdAt, updatedAt: pr.updatedAt,
            lastCommitAt: pr.lastCommitAt, ciState: pr.ciState, reviewDecision: .approved, reviews: pr.reviews,
            comments: pr.comments, requestedReviewers: pr.requestedReviewers,
            merge: PRMergeState(nodeID: "PR_\(pr.number)", mergeable: mergeable, status: status, viewerCanUpdate: true,
                                commitCount: commits)
        )
        return ClassifiedPR(pr: approved, category: .readyToMerge, account: base.account)
    }
}

// MARK: Merge window (plan 11)

extension SnapshotFixtures {
    /// What the Merge window of api#322 shows: approved, one check that isn't required failing, one conversation open.
    var idempotencyDetail: MergeDetail {
        let pr = idempotencyKeys.pr
        func check(_ name: String, _ state: MergeCheck.State, required: Bool, seconds: Int?, kind: MergeCheck.Kind = .checkRun) -> MergeCheck {
            let started = date(minutes: -170)
            return MergeCheck(name: name, kind: kind, state: state, isRequired: required,
                              url: URL(string: "https://github.com/acme/api/actions/runs/1\(name.count)"),
                              startedAt: started, completedAt: seconds.map { started.addingTimeInterval(TimeInterval($0)) })
        }
        return MergeDetail(
            number: pr.number, title: pr.title,
            body: """
            Payment retries could charge a customer twice when the provider times out **after** accepting the charge.

            This adds an `Idempotency-Key` header to every retry, derived from the order ID, and keeps the keys for 24 h.

            - Retries reuse the key of the first attempt
            - Keys expire with the order
            - New metric: `payments.retry.duplicate_prevented`

            Closes #301.
            """,
            url: pr.url, author: pr.author, authorAvatarURL: nil, baseRef: pr.baseRef, headRef: pr.headRef, headOid: pr.headOid,
            additions: pr.additions, deletions: pr.deletions, commitCount: 3, mergeable: .mergeable, status: .unstable,
            reviewDecision: .approved,
            reviews: [
                MergeReviewSummary(author: "tomas-r", avatarURL: nil, state: .approved, submittedAt: date(minutes: -40)),
                MergeReviewSummary(author: "lucia-m", avatarURL: nil, state: .approved, submittedAt: date(minutes: -75)),
                MergeReviewSummary(author: "ana-p", avatarURL: nil, state: .commented, submittedAt: date(minutes: -150)),
            ],
            pendingReviewers: ["payments-team"],
            checks: [
                check("build", .passed, required: true, seconds: 134),
                check("unit-tests", .passed, required: true, seconds: 242),
                check("integration-tests", .passed, required: false, seconds: 368),
                check("lint", .failed, required: false, seconds: 41),
                check("codecov/patch", .passed, required: false, seconds: nil, kind: .status),
                check("deploy-preview", .running, required: false, seconds: nil),
            ],
            checksTotal: 6, unresolvedThreads: 1, totalThreads: 3,
            files: [
                MergeChangedFile(path: "src/payments/idempotency.ts", additions: 48, deletions: 0, change: .added),
                MergeChangedFile(path: "src/payments/retry.ts", additions: 19, deletions: 9, change: .modified),
                MergeChangedFile(path: "src/payments/provider/client.ts", additions: 6, deletions: 2, change: .modified),
                MergeChangedFile(path: "src/metrics/payments.ts", additions: 4, deletions: 0, change: .modified),
                MergeChangedFile(path: "src/payments/legacyRetry.ts", additions: 0, deletions: 3, change: .removed),
                MergeChangedFile(path: "test/payments/idempotency.test.ts", additions: 17, deletions: 0, change: .added),
                MergeChangedFile(path: "docs/payments.md", additions: 2, deletions: 0, change: .modified),
            ],
            changedFiles: 7)
    }

    /// The chat of api#322's Merge window: why lint failed and whether it matters.
    var mergeChat: ChatSession {
        var session = ChatSession(prID: idempotencyKeys.id, kind: .merge)
        session.claudeSessionID = UUID(uuidString: "5A1E2B3C-4D5E-4F60-8A7B-9C0D1E2F3A4B")
        session.messages = [
            ChatMessage(role: .user, text: "Why did lint fail? Is it safe to merge anyway?", createdAt: date(minutes: -6)),
            ChatMessage(role: .assistant,
                        text: "Lint flags an unused import in `src/payments/retry.ts` (`clamp`): it doesn’t change behavior and the check isn’t required. The open conversation asks for a test of a retry after the key expired, which `idempotency.test.ts` doesn’t cover yet.",
                        createdAt: date(minutes: -5)),
        ]
        return session
    }
}

// MARK: - Recursos (spec I)

extension SnapshotFixtures {
    private static let megabyte: UInt64 = 1_048_576

    /// El pie del popover y PRBar Activity: CPU 12 %, RAM 640 MB, un review corriendo (claude y git).
    var resourceUsage: ResourceUsage {
        let review = ProcessActivity.review("acme/api#317")
        let processes = [
            ProcessUsage(pid: 501, name: "PRBar", activity: nil, cpuPercent: 2, memoryBytes: 180 * Self.megabyte,
                         startedAt: date(days: -1), isApp: true),
            ProcessUsage(pid: 9123, name: "claude", activity: review, cpuPercent: 9, memoryBytes: 410 * Self.megabyte,
                         startedAt: date(minutes: -3), isApp: false),
            ProcessUsage(pid: 9188, name: "git", activity: review, cpuPercent: 1, memoryBytes: 50 * Self.megabyte,
                         startedAt: date(minutes: -3), isApp: false),
        ]
        return ResourceUsage(cpuPercent: 12, memoryBytes: 640 * Self.megabyte, processes: processes, sampledAt: now)
    }

    /// 2,3 GB: worktrees 1,1 GB (acme/api activo, acme/web-app huérfano), updater 900 MB, historial 210 MB, logs 60 MB,
    /// datos 30 MB.
    var diskUsage: DiskUsage {
        let mb: Int64 = 1_000_000
        let worktrees = "/private/var/folders/xy/T/PRBar/worktrees"
        let support = "/Users/sam/Library/Application Support/PRBar"
        return DiskUsage(items: [
            DiskItem(path: "\(worktrees)/api-317-1800000000-1a2b3c4d", bytes: 640 * mb, kind: .worktrees, state: .active,
                     repo: "acme/api", clone: "/Users/sam/Code/api", title: "api-317-1800000000-1a2b3c4d"),
            DiskItem(path: "/Users/sam/Code/worktrees/web-app-475-respond-0a0b0c0d", bytes: 460 * mb, kind: .worktrees,
                     state: .orphan, repo: "acme/web-app", clone: "/Users/sam/Code/web-app", title: "web-app-475-respond-0a0b0c0d"),
            DiskItem(path: "\(support)/source/.build", bytes: 700 * mb, kind: .updater, state: .cache, title: "Updater builds"),
            DiskItem(path: "\(support)/source", bytes: 200 * mb, kind: .updater, state: .data, title: "Updater clone"),
            DiskItem(path: "\(support)/history", bytes: 210 * mb, kind: .history, state: .data, title: "History"),
            DiskItem(path: "/Users/sam/Library/Logs/PRBar", bytes: 60 * mb, kind: .logs, state: .data, title: "Logs"),
            DiskItem(path: support, bytes: 30 * mb, kind: .appData, state: .data, title: "Settings and state"),
        ], scannedAt: now)
    }
}

// MARK: - Fix CI y costo de Claude (specs K y O)

extension SnapshotFixtures {
    /// What a run "spent" in Claude (fictional numbers).
    static func usage(minutes: Double, input: Int, output: Int, cacheRead: Int, cost: Double?, unknown: Int = 0) -> ClaudeUsage {
        var usage = ClaudeUsage.run(duration: minutes * 60, tokens: ClaudeTokenUsage(inputTokens: input, outputTokens: output,
                                                                                    cacheCreationTokens: input / 3, cacheReadTokens: cacheRead),
                                    cost: cost)
        for _ in 0..<unknown { usage += .run(duration: 40, tokens: nil, cost: nil) }
        return usage
    }

    /// The Fix CI of web-app#475: `test (node 20)` and `typecheck` failed on the PR's head.
    var ciFixDraft: RespondDraft {
        let pr = csvExport.pr
        let head = "4be81c09d2a7f3e6b5c4d3e2f1a0b9c8d7e6f5a4"
        let failing = [
            CICheckRun(source: .checkRun, id: 31_337, name: "test (node 20)", status: "completed", conclusion: "failure",
                       appSlug: "github-actions", appName: "GitHub Actions",
                       detailsURL: URL(string: "https://github.com/acme/web-app/actions/runs/1/job/31337")),
            CICheckRun(source: .checkRun, id: 31_338, name: "typecheck", status: "completed", conclusion: "failure",
                       appSlug: "github-actions", appName: "GitHub Actions",
                       detailsURL: URL(string: "https://github.com/acme/web-app/actions/runs/1/job/31338")),
        ]
        let logs = [
            31_337: """
            > web-app@2.4.0 test
            > jest --watchAll=false
            FAIL src/reports/__tests__/formatDate.test.ts
              ● formatDate › uses the user's timezone
                expect(received).toBe(expected)
                Expected: "2026-03-01 09:30"
                Received: "2026-03-01 12:30"
                  at Object.<anonymous> (src/reports/__tests__/formatDate.test.ts:14:41)
            Test Suites: 1 failed, 41 passed, 42 total
            Tests:       1 failed, 317 passed, 318 total
            ##[error]Process completed with exit code 1.
            """,
            31_338: """
            > web-app@2.4.0 typecheck
            > tsc --noEmit
            src/reports/export.ts(57,39): error TS2554: Expected 1 arguments, but got 2.
            ##[error]Process completed with exit code 2.
            """,
        ]
        let (item, context) = CIFixItem.make(headOid: head, failing: failing, logs: logs, secrets: [], prURL: pr.url,
                                             at: date(minutes: -9))
        return RespondDraft(
            prID: csvExport.id, repo: Self.webApp, number: 475, title: pr.title, url: pr.url, headRef: pr.headRef,
            account: Self.personal,
            worktree: ResolvedWorktree(path: "/Users/sam/Code/worktrees/web-app-475-respond-5e6f7a8b", origin: .dedicated,
                                       localPath: "/Users/sam/Code/web-app", ref: "refs/prbar/respond-475-5e6f7a8b"),
            startHeadOid: head, items: [item], mode: .ciFix, ci: context)
    }

    var ciFixResult: RespondResult {
        let item = ciFixDraft.items[0]
        return RespondResult(
            items: [ItemResult(id: item.id, status: .committed, commit: "e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8",
                               summary: "formatDate() ignored its timeZone option, so the test and the typecheck failed; it now takes { timeZone } and export.ts passes the user's.")],
            diffStat: """
             src/reports/export.ts     |  2 +-
             src/reports/formatDate.ts |  9 ++++++---
             2 files changed, 8 insertions(+), 4 deletions(-)
            """,
            tests: nil, sensitiveChanges: [], headOid: "e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8", gitIntegrity: "snapshot",
            diff: """
            diff --git a/src/reports/formatDate.ts b/src/reports/formatDate.ts
            --- a/src/reports/formatDate.ts
            +++ b/src/reports/formatDate.ts
            @@ -1,8 +1,11 @@
             import { formatInTimeZone } from "date-fns-tz";
            -export function formatDate(date: Date): string {
            -  return formatInTimeZone(date, "UTC", "yyyy-MM-dd HH:mm");
            +export function formatDate(date: Date, options: { timeZone?: string } = {}): string {
            +  const timeZone = options.timeZone ?? "UTC";
            +  return formatInTimeZone(date, timeZone, "yyyy-MM-dd HH:mm");
             }
            diff --git a/src/reports/export.ts b/src/reports/export.ts
            --- a/src/reports/export.ts
            +++ b/src/reports/export.ts
            @@ -57 +57 @@
            -    res.write(csvRow(row, formatDate(row.createdAt, req.user.timeZone)));
            +    res.write(csvRow(row, formatDate(row.createdAt, { timeZone: req.user.timeZone })));
            """,
            diffTruncated: false,
            commits: [CommitInfo(sha: "e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8", message: "Pass the user's timezone to formatDate")],
            dependencyChanges: [])
    }

    /// PRBar Activity: what the running review of api#317 spent so far.
    var liveUsage: [ProcessActivity: ClaudeUsage] {
        [.review("acme/api#317"): Self.usage(minutes: 2.5, input: 18_000, output: 2_400, cacheRead: 160_000, cost: 0.21)]
    }

    /// The usage ledger: the recent tasks of PRBar Activity and this month's total.
    var usageEntries: [ClaudeUsageEntry] {
        func entry(_ activity: ProcessActivity, _ stage: String, minutes: Int, job: UUID, _ usage: ClaudeUsage) -> ClaudeUsageEntry {
            ClaudeUsageEntry(date: date(minutes: minutes), jobID: job, activity: activity, stage: stage, usage: usage)
        }
        let reviewJob = UUID(), analysisJob = UUID(), fixesJob = UUID(), ciJob = UUID(), chatJob = UUID(), rulesJob = UUID(), stoppedJob = UUID()
        return [
            entry(.review("acme/web-app#482"), "review", minutes: -55, job: stoppedJob,
                  Self.usage(minutes: 1.2, input: 4_000, output: 300, cacheRead: 20_000, cost: 0.08, unknown: 1)),
            entry(.review("acme/api#317"), "review", minutes: -6, job: reviewJob,
                  Self.usage(minutes: 7.5, input: 61_000, output: 9_800, cacheRead: 410_000, cost: 0.74)),
            entry(.review("acme/api#317"), "filter", minutes: -3, job: reviewJob,
                  Self.usage(minutes: 2.1, input: 22_000, output: 2_100, cacheRead: 150_000, cost: 0.19)),
            entry(.respond("acme/web-app#475"), "analysis", minutes: -200, job: analysisJob,
                  Self.usage(minutes: 3.4, input: 31_000, output: 4_600, cacheRead: 220_000, cost: 0.36)),
            entry(.respond("acme/web-app#475"), "fix", minutes: -190, job: fixesJob,
                  Self.usage(minutes: 4.8, input: 40_000, output: 6_900, cacheRead: 300_000, cost: 0.52)),
            entry(.respond("acme/web-app#475"), "fix", minutes: -186, job: fixesJob,
                  Self.usage(minutes: 3.1, input: 28_000, output: 3_800, cacheRead: 210_000, cost: 0.33)),
            entry(.ciFix("acme/web-app#475"), "CI fix", minutes: -9, job: ciJob,
                  Self.usage(minutes: 3.6, input: 26_000, output: 4_100, cacheRead: 190_000, cost: 0.31)),
            entry(.chat("acme/api#317"), "chat", minutes: -15, job: chatJob,
                  Self.usage(minutes: 0.6, input: 9_000, output: 700, cacheRead: 60_000, cost: 0.06)),
            entry(.instructions, "instructions chat", minutes: -30, job: rulesJob,
                  Self.usage(minutes: 0.2, input: 2_500, output: 200, cacheRead: 0, cost: 0.01)),
        ]
    }

    /// History: the CI fix of web-app#475, pushed.
    var historyCIFix: RespondRecord {
        var draft = ciFixDraft
        draft.id = UUID()
        let selections = Dictionary(uniqueKeysWithValues: draft.items.map { ($0.id, RespondSelection.defaults(for: $0)) })
        return RespondRecord(draft: draft, selections: selections, result: ciFixResult, pushed: true,
                             startedAt: date(minutes: -70), finishedAt: date(minutes: -59),
                             usage: Self.usage(minutes: 3.6, input: 26_000, output: 4_100, cacheRead: 190_000, cost: 0.31))
    }
}

// MARK: - Resolve Conflicts (spec C)

extension SnapshotFixtures {
    /// Ready to Merge but its branch conflicts with `main`: the row offers Resolve Conflicts instead of Merge.
    var ledgerInvoices: ClassifiedPR {
        readyToMerge(
            item(Self.api, 327, "Move invoices to the new ledger", author: Self.personal, base: "main",
                 head: "feat/ledger-invoices", ci: .success, adds: 312, dels: 140, updated: -50, category: .readyToMerge,
                 account: Self.personal, lastCommit: -60 * 4,
                 reviews: [PRReview(author: "ana-p", isBot: false, state: .approved, submittedAt: date(minutes: -55))]),
            status: .dirty, commits: 5, mergeable: .conflicting
        )
    }

    /// web-app#475 with conflicts with its base (its Resolve Conflicts waits to be pushed in the snapshots).
    var csvExportConflicting: ClassifiedPR {
        let pr = csvExport.pr
        let conflicting = PullRequest(
            repo: pr.repo, number: pr.number, title: pr.title, url: pr.url, isDraft: pr.isDraft, author: pr.author,
            authorAvatarURL: pr.authorAvatarURL, baseRef: pr.baseRef, headRef: pr.headRef, headOid: pr.headOid,
            additions: pr.additions, deletions: pr.deletions, createdAt: pr.createdAt, updatedAt: pr.updatedAt,
            lastCommitAt: pr.lastCommitAt, ciState: pr.ciState, reviewDecision: pr.reviewDecision, reviews: pr.reviews,
            comments: pr.comments, requestedReviewers: pr.requestedReviewers,
            merge: PRMergeState(nodeID: "PR_\(pr.number)", mergeable: .conflicting, status: .dirty, viewerCanUpdate: true,
                                commitCount: 4)
        )
        return ClassifiedPR(pr: conflicting, category: csvExport.category, account: csvExport.account)
    }

    /// The main snapshot with two PRs of mine that conflict with their base.
    var conflictsSnapshot: Snapshot {
        Snapshot(items: [rateLimiting, loginRedirect, reactQuery, csvExportConflicting, idempotencyKeys, ledgerInvoices,
                         reportsDarkMode] + others,
                 fetchedAt: now.addingTimeInterval(-50), repoMergeSettings: Self.mergeSettings)
    }

    /// The Resolve Conflicts of web-app#475: the base changed formatDate.ts too, and the logo is binary.
    var conflictsDraft: RespondDraft {
        let pr = csvExport.pr
        let head = "4be81c09d2a7f3e6b5c4d3e2f1a0b9c8d7e6f5a4"
        let context = ConflictsContext(
            baseRef: pr.baseRef, baseOid: "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432",
            mergeBase: "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567",
            files: [ConflictFile(path: "src/reports/formatDate.ts", kind: .content),
                    ConflictFile(path: "src/reports/export.ts", kind: .content),
                    ConflictFile(path: "public/logo.png", kind: .byHand, reason: "binary")],
            incomingCommits: 6)
        let item = ConflictsItem.make(startHeadOid: head, context: context, description: "Adds a CSV export.",
                                      incomingLog: "9f8e7d6 Use Intl for dates\n1a2b3c4 New logo", prDiff: "",
                                      diffTruncated: false, prURL: pr.url, at: date(minutes: -7))
        return RespondDraft(
            prID: csvExport.id, repo: Self.webApp, number: 475, title: pr.title, url: pr.url, headRef: pr.headRef,
            account: Self.personal,
            worktree: ResolvedWorktree(path: "/Users/sam/Code/worktrees/web-app-475-respond-6a7b8c9d", origin: .dedicated,
                                       localPath: "/Users/sam/Code/web-app", ref: "refs/prbar/respond-475-6a7b8c9d"),
            startHeadOid: head, items: [item], mode: .conflicts, conflicts: context)
    }

    /// The merge Claude resolved: the combined diff of the two files, plus one file changed outside the conflicts.
    var conflictsResult: RespondResult {
        let item = conflictsDraft.items[0]
        let merge = "c1d2e3f4a5b6978877665544332211ffeeddccbb"
        return RespondResult(
            items: [ItemResult(id: item.id, status: .committed, commit: merge,
                               summary: "Kept the PR’s timezone option and develop’s switch to Intl.DateTimeFormat.",
                               conflictFiles: [
                                   ConflictFileSummary(path: "src/reports/formatDate.ts",
                                                       summary: "Uses Intl.DateTimeFormat from develop with the PR’s timeZone option."),
                                   ConflictFileSummary(path: "src/reports/export.ts",
                                                       summary: "Keeps develop’s new column and passes { timeZone }."),
                               ])],
            diffStat: """
             src/reports/export.ts       | 2 +-
             src/reports/formatDate.ts   | 6 ++++--
             src/reports/csvRow.ts       | 2 +-
             3 files changed, 7 insertions(+), 4 deletions(-)
            """,
            tests: nil, sensitiveChanges: [], headOid: merge, gitIntegrity: "snapshot",
            diff: """
            diff --cc src/reports/formatDate.ts
            index 1a2b3c4,5d6e7f8..9a0b1c2
            --- a/src/reports/formatDate.ts
            +++ b/src/reports/formatDate.ts
            @@@ -1,4 -1,4 +1,5 @@@
            - export function formatDate(date: Date, options: { timeZone?: string } = {}): string {
             -export function formatDate(date: Date): string {
            ++export function formatDate(date: Date, options: { timeZone?: string } = {}): string {
            ++  return new Intl.DateTimeFormat("en-CA", { timeZone: options.timeZone ?? "UTC" }).format(date);
              }
            diff --cc src/reports/export.ts
            index 2b3c4d5,6e7f8a9..0b1c2d3
            --- a/src/reports/export.ts
            +++ b/src/reports/export.ts
            @@@ -55,3 -55,4 +55,4 @@@
                for (const row of rows) {
            -     res.write(csvRow(row, formatDate(row.createdAt, { timeZone: req.user.timeZone })));
             -    res.write(csvRow(row, formatDate(row.createdAt), row.region));
            ++    res.write(csvRow(row, formatDate(row.createdAt, { timeZone: req.user.timeZone }), row.region));
                }
            diff --git a/src/reports/csvRow.ts b/src/reports/csvRow.ts
            --- a/src/reports/csvRow.ts
            +++ b/src/reports/csvRow.ts
            @@ -3 +3 @@
            -export const SEPARATOR = ";";
            +export const SEPARATOR = ",";
            """,
            diffTruncated: false,
            commits: [CommitInfo(sha: merge, message: "Merge develop into feat/csv-export")],
            dependencyChanges: [],
            outsideConflicts: ["src/reports/csvRow.ts"])
    }
}
