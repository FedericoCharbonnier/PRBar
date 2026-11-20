import Foundation
import PRBarWire

/// The design's sample data (all fictional: acme/web-app, acme/api, Laura Méndez, …), for tests, previews, snapshots
/// and the demo mode.
public enum Sample {
    public static let macName = "Diego's MacBook Pro"
    /// Thursday, Nov 20 2026, 9:38 AM in Montevideo (UTC−3).
    public static let now = Date(timeIntervalSince1970: 1_795_178_280)
    public static let me = "diego"

    public static let people: [String: String] = [
        "lmendez": "Laura Méndez", "truiz": "Tomás Ruiz", "apereira": "Ana Pereira", "diego": "Diego",
        "mfranco": "Martín Franco",
    ]

    static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
    static func url(_ id: String) -> URL {
        let parts = id.split(separator: "#")
        return URL(string: "https://github.com/\(parts[0])/pull/\(parts[1])")!
    }

    static func pr(_ id: String, _ title: String, author: String, base: String = "main", head: String,
                   ci: String = "success", add: Int, del: Int, minutes: Double, review: String? = nil,
                   respond: String? = nil, section: PopoverSection, draft: Bool = false, approvals: Int? = nil,
                   files: Int? = nil) -> PRInfo {
        let parts = id.split(separator: "#")
        return PRInfo(id: id, repo: String(parts[0]), number: Int(parts[1])!, title: title, url: url(id), author: author,
                      account: me, category: section.category.rawValue, baseRef: base, headRef: head, isDraft: draft,
                      ci: ci, additions: add, deletions: del, updatedAt: ago(minutes), review: review, respond: respond,
                      tab: section.tab, section: section, authorName: people[author], approvals: approvals,
                      changedFiles: files)
    }

    // MARK: Home

    public static let webApp491 = pr("acme/web-app#491", "Add CSV export to the monthly reports page", author: "lmendez",
                                     base: "develop", head: "feat/csv-export", add: 214, del: 38, minutes: 8,
                                     section: .toReview, files: 7)
    public static let api317 = pr("acme/api#317", "Refresh expired sessions without logging users out",
                                  author: "truiz", head: "fix/session-expiry", add: 46, del: 12, minutes: 12,
                                  review: "reviewing", section: .toReview, files: 5)
    public static let webApp482 = pr("acme/web-app#482", "Cache dashboard queries per team", author: "apereira",
                                     head: "perf/dashboard-cache", add: 131, del: 54, minutes: 95, review: "ready",
                                     section: .updatedSinceMyReview)
    public static let webApp475 = pr("acme/web-app#475", "Speed up the monthly report export", author: me,
                                     head: "perf/report-export", add: 88, del: 31, minutes: 120,
                                     section: .myFeedback)
    public static let api322 = pr("acme/api#322", "Make payment retries idempotent", author: me,
                                  head: "feat/idempotent-retries", add: 96, del: 14, minutes: 40, section: .readyToMerge,
                                  approvals: 2, files: 4)
    public static let webApp488 = pr("acme/web-app#488", "Move report jobs to the new queue", author: me,
                                     head: "chore/report-queue", ci: "failure", add: 57, del: 22, minutes: 20,
                                     section: .waitingForReview)
    public static let api330 = pr("acme/api#330", "Document the webhooks endpoint", author: me, head: "docs/webhooks",
                                  add: 64, del: 3, minutes: 300, section: .waitingForReview)
    public static let webApp493 = pr("acme/web-app#493", "Tidy up the settings page layout", author: me,
                                     head: "ui/settings-tidy", add: 40, del: 61, minutes: 1_500, section: .waitingForReview)

    public static let status = StatusInfo(
        appVersion: "1.9.0", fetchedAt: now, badgeCount: 4,
        jobs: [JobInfo(pr: "acme/api#317", kind: "review", phase: "2 agents · on devbox")],
        tabCounts: ["to-review": 3, "mine": 3],
        sectionCounts: ["toReview": 2, "updatedSinceMyReview": 1, "myFeedback": 1, "readyToMerge": 1,
                        "waitingForReview": 3])

    public static let home = RemoteHome(
        status: status,
        prs: [webApp491, api317, webApp482, webApp475, api322, webApp488, api330, webApp493],
        ci: [CIListEntry(pr: "acme/web-app#488", title: webApp488.title, url: webApp488.url, account: me, phase: nil,
                         respondInProgress: false, unavailableReason: nil, failedChecks: 2)],
        findingCounts: ["acme/web-app#482": 4])

    // MARK: Review (api#317)

    public static let findings: [FindingInfo] = [
        FindingInfo(number: 1, id: "f1", severity: .high, location: "src/auth/session.ts:88",
                    title: "Expired refresh tokens are retried forever",
                    body: "When the refresh token is already expired, `refreshSession` retries on every request instead of signing the user out. Stop after the first 401 and clear the session.",
                    keptByFilter: true, filterReason: nil, included: true, edited: false),
        FindingInfo(number: 2, id: "f2", severity: .medium, location: "src/auth/middleware.ts:42",
                    title: "Race between two refreshes",
                    body: "Two parallel requests can both start a refresh. Share the in-flight promise so only one refresh runs at a time.",
                    keptByFilter: true, filterReason: nil, included: true, edited: false),
        FindingInfo(number: 3, id: "f3", severity: .low, location: "src/auth/cookies.ts:17",
                    title: "Cookie max-age is hard-coded",
                    body: "The cookie lifetime repeats the session TTL as a literal. Read it from `SESSION_TTL` so they can't drift.",
                    keptByFilter: true, filterReason: nil, included: true, edited: true),
        FindingInfo(number: 4, id: "f4", severity: .low, location: "tests/session.test.ts:120",
                    title: "Test name doesn't match what it checks",
                    body: "The test says it checks logout but asserts the refresh call count.",
                    keptByFilter: true, filterReason: nil, included: false, edited: false),
    ]

    public static let review317 = ReviewInfo(
        pr: "acme/api#317", phase: "ready", detail: "2 agents · 3m 40s", title: api317.title,
        summary: "Expired sessions now refresh in the background instead of logging people out. The flow works, but an expired refresh token is retried forever and two requests can refresh at once.",
        outdated: false, findings: findings)

    public static let detail317 = RemotePRDetail(pr: api317, review: review317, respond: nil, chat: chatReview)

    // MARK: Respond (web-app#475) and Fix CI (web-app#488)

    public static let respondItems: [RespondItemInfo] = [
        RespondItemInfo(number: 1, id: "c1", reviewer: "lmendez", location: "src/reports/export.ts:57", outdated: false,
                        thread: ["This loads every row in memory before writing the CSV. Can we stream it instead?"],
                        assessment: "Valid", suggested: "implement", implement: true,
                        fixPlan: "Stream rows with a cursor and write them as they arrive.", reply: true,
                        replyText: "Good catch — it now streams rows with a cursor, so memory stays flat on big months."),
        RespondItemInfo(number: 2, id: "c2", reviewer: "lmendez", location: "src/reports/export.ts:112", outdated: false,
                        thread: ["Please add a test for an empty month."],
                        assessment: "Valid", suggested: "implement", implement: true,
                        fixPlan: "Add a test that exports a month with no rows.", reply: true,
                        replyText: "Added a test for an empty month."),
    ]

    public static func respond475(phase: String) -> RespondInfo {
        var info = RespondInfo(pr: "acme/web-app#475", phase: phase, runningTests: false,
                               title: webApp475.title, headRef: webApp475.headRef, items: respondItems, fixes: 2,
                               replies: 2, commits: [], diffStat: "2 files changed, 15 insertions(+), 4 deletions(-)",
                               sensitiveChanges: [],
                               tests: phase == "readyToPush" ? TestInfo(command: "npm test", passed: true,
                                                                        outputTail: "Tests: 142 passed, 142 total") : nil,
                               pushed: false, pendingReplies: 2, pushBlockedByTests: false, mode: .feedback)
        info.startedAt = ago(2.5)
        info.currentFile = "src/reports/export.ts"
        info.testSummary = phase == "readyToPush" ? "142 passed" : nil
        return info
    }

    public static func detail475(phase: String = "implementing") -> RemotePRDetail {
        RemotePRDetail(pr: webApp475, review: nil, respond: respond475(phase: phase), chat: chatRespond)
    }

    public static let ciChecks: [CICheckFailure] = [
        CICheckFailure(id: "check:1", name: "unit-tests", conclusion: "failure", appName: "GitHub Actions",
                       detailsURL: nil, hasLog: true, durationSeconds: 134,
                       logExcerpt: ["FAIL src/jobs/report-queue.test.ts", "✕ enqueues one job per team (38 ms)",
                                    "Expected: 3", "Received: 0"]),
        CICheckFailure(id: "check:2", name: "lint", conclusion: "failure", appName: "GitHub Actions", detailsURL: nil,
                       hasLog: true, durationSeconds: 41,
                       logExcerpt: ["src/jobs/report-queue.ts", "12:7  error  'legacyQueue' is defined but never used"]),
    ]

    public static func detail488(phase: String = "analyzing") -> RemotePRDetail {
        var info = RespondInfo(pr: "acme/web-app#488", phase: phase, runningTests: false, title: webApp488.title,
                               headRef: webApp488.headRef, items: [], fixes: 0, replies: 0, commits: [],
                               diffStat: phase == "readyToPush" ? "2 files changed, 6 insertions(+), 3 deletions(-)" : nil,
                               sensitiveChanges: [], pushed: false, pendingReplies: 0, pushBlockedByTests: false,
                               mode: .ciFix, ciChecks: ciChecks)
        info.totalChecks = 9
        info.startedAt = ago(2)
        info.testSummary = phase == "readyToPush" ? "142 passed" : nil
        return RemotePRDetail(pr: webApp488, review: nil, respond: info, chat: nil)
    }

    public static let diff475 = RespondDiff(
        pr: "acme/web-app#475", diffStat: "2 files changed, 15 insertions(+), 4 deletions(-)",
        diff: """
        diff --git a/src/reports/export.ts b/src/reports/export.ts
        --- a/src/reports/export.ts
        +++ b/src/reports/export.ts
        @@ -52,10 +52,16 @@ export async function exportMonth(month: Month, out: Writable) {
           const header = columns.map((c) => c.title).join(",");
           out.write(header + "\\n");
        -  const rows = await db.reports.findMany({ where: { month } });
        -  for (const row of rows) {
        -    out.write(toCsv(row) + "\\n");
        -  }
        +  let written = 0;
        +  const cursor = db.reports.cursor({ where: { month }, batchSize: 500 });
        +  for await (const batch of cursor) {
        +    for (const row of batch) {
        +      out.write(toCsv(row) + "\\n");
        +    }
        +  }
        +  // Streams rows so memory stays flat on big months.
        +  await cursor.close();
           out.end();
         }
        diff --git a/src/reports/export.test.ts b/src/reports/export.test.ts
        --- a/src/reports/export.test.ts
        +++ b/src/reports/export.test.ts
        @@ -40,3 +40,9 @@ describe("exportMonth", () => {
           });
        +
        +  it("exports only the header for an empty month", async () => {
        +    const out = await collect(exportMonth(emptyMonth));
        +    expect(out).toBe(header + "\\n");
        +  });
        +});
         });
        """,
        truncated: false, sensitiveChanges: [])

    // MARK: Merge (api#322)

    public static let mergeDetail322 = MergeDetail(
        number: 322, title: api322.title,
        body: "Payment retries now send an idempotency key, so a retry after a timeout can't charge twice. Keys live for 24 hours in Redis.",
        url: api322.url, author: me, authorAvatarURL: nil, baseRef: "main", headRef: "feat/idempotent-retries",
        headOid: "9f3c2a1", additions: 96, deletions: 14, commitCount: 3, mergeable: .mergeable, status: .clean,
        reviewDecision: .approved,
        reviews: [MergeReviewSummary(author: "lmendez", avatarURL: nil, state: .approved, submittedAt: ago(30)),
                  MergeReviewSummary(author: "truiz", avatarURL: nil, state: .approved, submittedAt: ago(25))],
        pendingReviewers: [],
        checks: (1...9).map { MergeCheck(name: "check-\($0)", kind: .checkRun, state: .passed, isRequired: $0 <= 3) },
        checksTotal: 9, unresolvedThreads: 0, totalThreads: 3,
        files: [MergeChangedFile(path: "src/payments/retry.ts", additions: 58, deletions: 9, change: .modified),
                MergeChangedFile(path: "src/payments/idempotency.ts", additions: 30, deletions: 0, change: .added),
                MergeChangedFile(path: "src/payments/retry.test.ts", additions: 6, deletions: 3, change: .modified),
                MergeChangedFile(path: "README.md", additions: 2, deletions: 2, change: .modified)],
        changedFiles: 4)

    public static let mergePreview322 = MergePreviewInfo(
        pr: "acme/api#322", title: api322.title, url: api322.url, baseRef: "main", headRef: "feat/idempotent-retries",
        headOid: "9f3c2a1", commitCount: 3, method: .squash, deletesBranch: true, detail: mergeDetail322)

    // MARK: Chat

    static func message(_ role: String, _ text: String, minutes: Double, changes: String? = nil,
                        undoable: Bool = false) -> ChatMessageInfo {
        ChatMessageInfo(id: UUID(), role: role, text: text, createdAt: ago(minutes), changes: changes, undone: false,
                        notes: [], undoable: undoable)
    }

    public static let chatReview = ChatInfo(pr: "acme/api#317", kind: "review", readOnly: false, running: false,
                                            lockReason: nil, messages: [
        message("user", "Is finding 3 really Medium? The TTL only matters if someone changes it.", minutes: 6),
        message("assistant", "Fair point — it's a maintainability issue, not a bug today. I lowered it to Low and kept the comment.",
                minutes: 5, changes: "Changed finding #3\nSeverity Medium → Low", undoable: true),
        message("user", "Thanks. Anything else worth flagging?", minutes: 2),
    ])

    public static let chatRespond = ChatInfo(pr: "acme/web-app#475", kind: "respond", readOnly: false, running: false,
                                             lockReason: nil, messages: [
        message("user", "Use a batch size of 500 for the cursor.", minutes: 4),
        message("assistant", "Done — the cursor now reads 500 rows per batch.", minutes: 3,
                changes: "Edited fix in src/reports/export.ts\n+1 −1 · tests re-running", undoable: true),
    ])

    public static let chatMerge = ChatInfo(pr: "acme/api#322", kind: "merge", readOnly: true, running: false,
                                           lockReason: nil, messages: [
        message("user", "Is it safe to merge before the Redis upgrade?", minutes: 3),
        message("assistant", "Yes. It only uses SET with NX and EX, which the current Redis already supports.", minutes: 2),
    ])

    // MARK: Activity

    public static let activity = RemoteActivity(
        resources: ResourcesInfo(usage: ResourceUsage(cpuPercent: 38, memoryBytes: 11_200_000_000, processes: [],
                                                      sampledAt: now),
                                 disk: DiskUsage(items: [], scannedAt: now)),
        usage: UsageInfo(month: UsageMonth(month: "2026-11", usage: ClaudeUsage(runs: 89, costUSD: 48.20),
                                           byKind: ["review": ClaudeUsage(runs: 31, costUSD: 29.10),
                                                    "respond": ClaudeUsage(runs: 12, costUSD: 14.60),
                                                    "chat": ClaudeUsage(runs: 46, costUSD: 4.50)]),
                         tasks: []),
        history: [],
        system: MacSystemInfo(cores: 12, memoryTotalBytes: 16_000_000_000, memoryUsedBytes: 11_200_000_000,
                              diskFreeBytes: 212_000_000_000, diskTotalBytes: 512_000_000_000),
        running: [RunningJobInfo(pr: "acme/api#317", kind: "review", title: api317.title, phase: "2 agents",
                                 startedAt: now.addingTimeInterval(-252), costUSD: 0.38),
                  RunningJobInfo(pr: "acme/web-app#488", kind: "respond", title: webApp488.title,
                                 phase: "Running tests", startedAt: now.addingTimeInterval(-123), costUSD: 0.21)])

    // MARK: Settings

    public static let notifications = NotificationsInfo(
        enabled: true,
        kinds: ["review-finished": true, "new-to-review": true, "my-feedback": true, "ready-to-merge": true,
                "approved-or-ci": true, "reviewed-updated": false],
        deniedInMacOS: false)

    public static let details: [String: RemotePRDetail] = [
        "acme/api#317": detail317, "acme/web-app#475": detail475(), "acme/web-app#488": detail488(),
        "acme/api#322": RemotePRDetail(pr: api322, review: nil, respond: nil, chat: chatMerge, slackChannel: "#api-reviews"),
    ]
}
