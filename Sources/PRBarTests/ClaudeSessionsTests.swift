import Foundation
import PRBarCore

private let sessionA = "0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50"
private let sessionB = "6f1c2d3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f"

private func comment(_ body: String) -> FeedbackComment {
    FeedbackComment(databaseID: 1, author: "ana", isBot: false, body: body, createdAt: t0,
                    url: URL(string: "https://github.com/o/r/pull/7#discussion_r1")!)
}

private func respondItem(_ id: String, kind: FeedbackItem.Kind = .thread, body: String) -> RespondItem {
    RespondItem(feedback: FeedbackItem(id: id, kind: kind, path: kind == .ciChecks ? nil : "README.md", line: nil,
                                       isOutdated: false, comments: kind == .ciChecks ? [] : [comment(body)]),
                assessment: "", action: .fix, fixPlan: "", reply: "")
}

private func respondDraft(_ items: [RespondItem]) -> RespondDraft {
    var draft = RespondDraft(prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "PR 7",
                             url: URL(string: "https://github.com/o/r/pull/7")!, headRef: "feature", account: "me",
                             worktree: ResolvedWorktree(path: "/repos/r-worktrees/r-7-respond-0a1b2c3d", origin: .dedicated,
                                                        localPath: "/repos/r", ref: "refs/prbar/respond-7-0a1b2c3d"),
                             startHeadOid: String(repeating: "0", count: 40), items: items)
    draft.runner = "devbox"
    return draft
}

private func reviewDraft() -> ReviewDraft {
    ReviewDraft(prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "PR 7",
                url: URL(string: "https://github.com/o/r/pull/7")!, author: "ana", headOid: "abc", account: "me",
                summary: "ok", items: [])
}

enum ClaudeSessionsTests {
    static let cases: [TestCase] = [
        TestCase("sesiones: nombres de las etapas, los fixes (truncados a 50) y el Fix CI") {
            let stamp = ClaudeSessionStamp(id: sessionA, startedAt: t0)
            let stage = ClaudeSessionRef.reviewStage(2, stamp: stamp, directory: "/wt/r-7", runner: nil)
            try expectEqual(stage.label, "Review · stage 2")
            try expectEqual(stage.kind, .review)

            let long = String(repeating: "x", count: 60)
            let items = [respondItem("thread:1", body: "\n  Renombrá la variable\nporque confunde"),
                         respondItem("thread:2", body: long),
                         respondItem("ci", kind: .ciChecks, body: "")]
            let results = [
                ItemResult(id: "thread:1", status: .committed, commit: nil, summary: "", session: stamp),
                ItemResult(id: "thread:2", status: .noChanges, commit: nil, summary: "",
                           session: ClaudeSessionStamp(id: sessionB, startedAt: t0.addingTimeInterval(60))),
                ItemResult(id: "ci", status: .failed, commit: nil, summary: "", session: stamp),
                ItemResult(id: "thread:9", status: .failed, commit: nil, summary: "", session: nil),
            ]
            let fixes = ClaudeSessionRef.fixes(draft: respondDraft(items), items: results)
            try expectEqual(fixes.map(\.label), ["Fix 1: Renombrá la variable", "Fix 2: " + String(repeating: "x", count: 49) + "…", "CI fix"])
            try expectEqual(fixes.map(\.kind), [.fix, .fix, .ciFix])
            try expectEqual(Set(fixes.map(\.directory)), ["/repos/r-worktrees/r-7-respond-0a1b2c3d"])
            try expectEqual(Set(fixes.map(\.runner)), ["devbox"])
            try expectEqual(ClaudeSessionRef.truncated(long).count, 50)
        },
        TestCase("sesiones: un ReviewRecord sin sessions carga; con sesiones, ida y vuelta") {
            let old = ReviewRecord(draft: reviewDraft(), startedAt: t0, status: .ready)
            let oldJSON = try JSONCoding.encoder.encode(old)
            try expect(!String(decoding: oldJSON, as: UTF8.self).contains("sessions"))
            try expectEqual(try JSONCoding.decoder.decode(ReviewRecord.self, from: oldJSON).sessions, nil)

            let session = ClaudeSessionRef.reviewStage(1, stamp: ClaudeSessionStamp(id: sessionA, startedAt: t0),
                                                       directory: "/wt/r-7", runner: "devbox")
            let record = ReviewRecord(draft: reviewDraft(), startedAt: t0, status: .ready, sessions: [session])
            let back = try JSONCoding.decoder.decode(ReviewRecord.self, from: JSONCoding.encoder.encode(record))
            try expectEqual(back.sessions, [session])
        },
        TestCase("sesiones: un RespondRecord sin sessions (o roto) carga; con sesiones, ida y vuelta") {
            let draft = respondDraft([respondItem("thread:1", body: "Arreglá esto")])
            let old = RespondRecord(draft: draft, startedAt: t0)
            try expectEqual(try JSONCoding.decoder.decode(RespondRecord.self, from: JSONCoding.encoder.encode(old)).sessions, nil)

            var broken = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(old)) as! [String: Any]
            broken["sessions"] = "not a list"
            let tolerated = try JSONCoding.decoder.decode(RespondRecord.self, from: JSONSerialization.data(withJSONObject: broken))
            try expectEqual(tolerated.sessions, nil)

            let sessions = ClaudeSessionRef.fixes(draft: draft, items: [
                ItemResult(id: "thread:1", status: .committed, commit: nil, summary: "",
                           session: ClaudeSessionStamp(id: sessionA, startedAt: t0)),
            ])
            let record = RespondRecord(draft: draft, startedAt: t0, sessions: sessions)
            let back = try JSONCoding.decoder.decode(RespondRecord.self, from: JSONCoding.encoder.encode(record))
            try expectEqual(back.sessions, sessions)
        },
        TestCase("sesiones: la captura se queda con el último ID (el del reintento)") {
            let capture = ClaudeSessionCapture(now: { t0 })
            try expectEqual(capture.stamp, nil)
            capture.record(sessionA)
            capture.record(sessionB)
            try expectEqual(capture.stamp, ClaudeSessionStamp(id: sessionB, startedAt: t0))
            try expect(ClaudeSessionRef.isValidID(sessionA))
            try expect(!ClaudeSessionRef.isValidID("abc; rm -rf ~"))
        },
        TestCase("sesiones: se ofrecen las de las carpetas conservadas del PR, Review → Fixes → CI fix, en orden") {
            func ref(_ id: String, _ label: String, _ kind: ClaudeSessionRef.Kind, _ dir: String, _ minutes: Double) -> ClaudeSessionRef {
                ClaudeSessionRef(id: id, label: label, kind: kind, directory: dir, runner: nil, startedAt: t0.addingTimeInterval(minutes * 60))
            }
            let stage2 = ref("b", "Review · stage 2", .review, "/wt/review", 5)
            let stage1 = ref("a", "Review · stage 1", .review, "/wt/review", 1)
            let ci = ref("c", "CI fix", .ciFix, "/wt/respond", 20)
            let fix = ref("d", "Fix 1: x", .fix, "/wt/respond", 10)
            let elsewhere = ref("e", "Review · stage 1", .review, "/wt/other", 30)
            func entry(_ job: RetainedWorktree.Job, _ dir: String, _ sessions: [ClaudeSessionRef], prID: String = "o/r#7",
                       superseded: Bool = false) -> RetainedWorktree {
                RetainedWorktree(prID: prID, account: "me", repo: RepoRef(owner: "o", name: "r"), number: 7, job: job, recordID: UUID(),
                                 location: WorktreeLocation(directory: dir, runner: nil, repository: "/repos/r", refs: []),
                                 sessions: sessions, retainedAt: t0, superseded: superseded)
            }
            let retained = [entry(.respond, "/wt/respond", [ci, fix]), entry(.review, "/wt/review", [stage2, stage1, elsewhere]),
                            entry(.review, "/wt/old", [ref("f", "Review · stage 1", .review, "/wt/old", 0)], superseded: true),
                            entry(.review, "/wt/8", [ref("g", "Review · stage 1", .review, "/wt/8", 0)], prID: "o/r#8")]
            let offered = SessionOffer.offered(prID: "o/r#7", retained: retained)
            try expectEqual(offered.map(\.id), ["a", "b", "d", "c"])
            try expectEqual(SessionOffer.groups(offered).map(\.title), ["Review", "Fixes", "CI fix"])
            try expectEqual(SessionOffer.mostRecent(offered)?.id, "c")
            try expectEqual(SessionOffer.ofRecord(retained[1].recordID, retained: retained).map(\.id), ["a", "b"])
            try expectEqual(SessionOffer.ofRecord(retained[2].recordID, retained: retained), [])

            try expectEqual(try SessionOffer.pick(offered, job: nil, run: nil).id, "c")
            try expectEqual(try SessionOffer.pick(offered, job: .review, run: nil).id, "b")
            try expectEqual(try SessionOffer.pick(offered, job: nil, run: 1).id, "a")
            let noRun = try await expectThrows { _ = try SessionOffer.pick(offered, job: nil, run: 9) }
            try expectEqual((noRun as? CommandFailure)?.code, .notFound)
            let noSessions = try await expectThrows { _ = try SessionOffer.pick([], job: nil, run: nil) }
            try expectEqual((noSessions as? CommandFailure)?.code, .invalidState)
            let wrongJob = try await expectThrows { _ = try SessionOffer.pick(offered, job: .respond, run: 1) }
            try expectEqual((wrongJob as? CommandFailure)?.code, .invalidUsage)

            try expectEqual(SessionOffer.help(count: 0, busy: false, terminal: "iTerm"), "No Claude session for this PR yet")
            try expectEqual(SessionOffer.help(count: 2, busy: true, terminal: "iTerm"), "Claude is working on it")
            try expectEqual(SessionOffer.help(count: 1, busy: false, terminal: "iTerm"), "Open Claude’s session in iTerm")

            let info = SessionOffer.info(offered, busy: ["d"])
            try expectEqual(info.map(\.number), [1, 2, 3, 4])
            try expectEqual(info.map(\.kind), ["review", "review", "fix", "ci-fix"])
            try expectEqual(info.map(\.busy), [false, false, true, false])
            try expectEqual(Set(info.map(\.machine)), ["this Mac"])
        },
    ]
}
