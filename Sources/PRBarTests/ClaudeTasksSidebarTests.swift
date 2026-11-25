import Foundation
import PRBarCore

private func draft(findings: Int) -> ReviewDraft {
    let items = (0..<findings).map { i in
        ReviewItem(finding: ReviewFinding(id: "f\(i)", severity: .medium, file: "a.ts", line: i, title: "T", body: "B"),
                   keep: true, reason: nil)
    }
    return ReviewDraft(prID: "acme/web#482", repo: RepoRef(owner: "acme", name: "web"), number: 482, title: "PR",
                       url: URL(string: "https://github.com/acme/web/pull/482")!, author: "ana", headOid: "a",
                       account: "me", summary: "S", items: items)
}

enum ClaudeTasksSidebarTests {
    static let cases: [TestCase] = [
        TestCase("grupo Claude: review corriendo con reloj, lista con hallazgos; las que corren van primero") {
            let rows = ClaudeTasksSidebar.rows([
                ClaudeTaskInput(prID: "acme/web#482", review: .ready(draft(findings: 4))),
                ClaudeTaskInput(prID: "acme/api#317", review: .reviewing(agents: 3), reviewStartedAt: t0.addingTimeInterval(-72)),
            ], now: t0)
            try expectEqual(rows.map(\.title), ["api#317", "web#482"])
            try expectEqual(rows.map(\.subtitle), ["Reviewing · 1:12", "Review ready · 4 findings"])
            try expectEqual(rows.map(\.isRunning), [true, false])
            try expectEqual(rows.map(\.tab), [.review, .review])
        },
        TestCase("grupo Claude: Respond y Fix CI por etapa; terminadas o fallidas no aparecen") {
            func row(_ phase: RespondPhase?, mode: RespondMode = .feedback, tests: Bool = false) -> ClaudeTaskRow? {
                ClaudeTasksSidebar.rows([ClaudeTaskInput(prID: "o/r#1", respond: phase, respondMode: mode, runningTests: tests,
                                                         respondStartedAt: t0.addingTimeInterval(-5))], now: t0).first
            }
            try expectEqual(row(.analyzing(agents: 2))?.subtitle, "Analyzing · 0:05")
            try expectEqual(row(.implementing(done: 1, total: 3), mode: .ciFix)?.subtitle, "Implementing · 0:05")
            try expectEqual(row(.implementing(done: 1, total: 3), mode: .ciFix)?.tab, .fixCI)
            let pushable = row(.readyToPush(draftStub, resultStub), mode: .ciFix)
            try expectEqual(pushable?.subtitle, "Fix CI · ready to push")
            try expectEqual(pushable?.isRunning, false)
            try expectEqual(row(.readyToPush(draftStub, resultStub), tests: true)?.subtitle, "Running tests · 0:05")
            try expectEqual(row(.queued)?.subtitle, "Respond · queued")
            try expectEqual(row(.pushing)?.subtitle, "Pushing…")
            try expect(row(.failed("x", logURL: nil)) == nil)
            try expect(row(nil) == nil)
            // Resolve Conflicts: se ve en Respond y su `ready` (instantáneo) sigue analizando.
            let conflicts = row(.readyToPush(draftStub, resultStub), mode: .conflicts)
            try expectEqual(conflicts?.subtitle, "Resolve Conflicts · ready to push")
            try expectEqual(conflicts?.tab, .respond)
            try expectEqual(row(.ready(draftStub), mode: .conflicts)?.subtitle, "Analyzing · 0:05")
            try expectEqual(row(.queued, mode: .conflicts)?.subtitle, "Resolve Conflicts · queued")
        },
        TestCase("grupo Claude: título del grupo, franja del popover, iPhone e indicadores de pestaña") {
            let rows = ClaudeTasksSidebar.rows([
                ClaudeTaskInput(prID: "acme/web#482", review: .ready(draft(findings: 1)), fromPhone: true),
                ClaudeTaskInput(prID: "acme/api#317", review: .queued),
            ], now: t0)
            try expectEqual(ClaudeTasksSidebar.groupTitle(rows), "Claude · 1 running")
            try expectEqual(ClaudeTasksSidebar.popoverStrip(rows), "Claude · 1 running · 1 ready")
            try expectEqual(ClaudeTasksSidebar.popoverStrip([]), nil)
            try expectEqual(rows.last?.subtitle, "Review ready · 1 finding")
            try expectEqual(rows.last?.fromPhone, true)
            try expectEqual(ClaudeTasksSidebar.indicator(prID: "acme/api#317", tab: .review, rows: rows), .running)
            try expectEqual(ClaudeTasksSidebar.indicator(prID: "acme/web#482", tab: .review, rows: rows), .ready)
            try expectEqual(ClaudeTasksSidebar.indicator(prID: "acme/web#482", tab: .details, rows: rows), nil)
        },
        TestCase("grupo Claude: reloj m:ss y h:mm:ss") {
            try expectEqual(ClaudeTasksSidebar.clock(0), "0:00")
            try expectEqual(ClaudeTasksSidebar.clock(72), "1:12")
            try expectEqual(ClaudeTasksSidebar.clock(3725), "1:02:05")
        },
    ]
}
