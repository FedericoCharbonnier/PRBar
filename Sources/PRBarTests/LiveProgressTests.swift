import Combine
import Foundation
import PRBarCore

/// 2026-11-26 12:00:00 UTC: los relojes de estos tests.
let progressT0 = Date(timeIntervalSince1970: 1_795_694_400)

enum LiveProgressTests {
    static let cases: [TestCase] = [
        TestCase("progreso wire: ReviewInfo y RespondInfo suman activity opcional; uno viejo decodifica igual") {
            let oldReview = #"{"pr":"o/r#7","phase":"reviewing","outdated":false,"findings":[]}"#
            try expectEqual(try JSONDecoder().decode(ReviewInfo.self, from: Data(oldReview.utf8)).activity, nil)
            let oldRespond = #"{"pr":"o/r#7","phase":"analyzing","runningTests":false,"items":[],"fixes":0,"replies":0,"commits":[],"sensitiveChanges":[],"pushed":false,"pendingReplies":0,"pushBlockedByTests":false}"#
            try expectEqual(try JSONDecoder().decode(RespondInfo.self, from: Data(oldRespond.utf8)).activity, nil)
            let step = JobActivity(kind: .claude, text: "Reading src/shop/tax.py", startedAt: progressT0)
            let info = ReviewInfo(pr: "o/r#7", phase: "reviewing", outdated: false, findings: [], activity: step)
            let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
            try expect(json.contains(#""kind":"claude""#), json)
            try expectEqual(try JSONDecoder().decode(ReviewInfo.self, from: Data(json.utf8)), info)
            // Lenient: a newer kind doesn't break an older PRBar.
            let newer = #"{"kind":"someday","text":"x","startedAt":0}"#
            try expectEqual(try JSONDecoder().decode(JobActivity.self, from: Data(newer.utf8)).kind, .prbar)
        },
        TestCase("progreso: el tiempo de un paso (12 s, 2 min 5 s, 1 h 3 min)") {
            try expectEqual(JobActivity.elapsedText(0), "0 s")
            try expectEqual(JobActivity.elapsedText(12.9), "12 s")
            try expectEqual(JobActivity.elapsedText(125), "2 min 5 s")
            try expectEqual(JobActivity.elapsedText(3780), "1 h 3 min")
            try expectEqual(JobActivity.elapsedText(-5), "0 s")
            let step = JobActivity(kind: .prbar, text: "Pushing…", startedAt: progressT0)
            try expectEqual(step.elapsedText(now: progressT0.addingTimeInterval(42)), "42 s")
        },
        TestCase("progreso: pasos de PRBar, ' on <runner>' antes de los …, y lo de afuera en una línea de a lo sumo 80") {
            try expectEqual(JobActivity.prbar(JobStep.creatingWorktree, runner: "build-box").text, "Creating the worktree on build-box…")
            try expectEqual(JobActivity.prbar(JobStep.creatingWorktree).text, "Creating the worktree…")
            try expectEqual(JobActivity.prbar(JobStep.creatingWorktree, runner: "").kind, .prbar)
            try expectEqual(JobActivity.prbar(JobStep.creatingWorktree, runner: "").text, "Creating the worktree…")
            try expectEqual(JobActivity.prbar(JobStep.committing, runner: "dev\nbox").text, "Committing on dev box…")
            try expectEqual(JobStep.fetching("main"), "Fetching main…")
            try expectEqual(JobStep.merging("release/2.0"), "Merging release/2.0…")
            try expectEqual(JobStep.updatingReviewFolder(String(repeating: "a", count: 40)), "Updating the PR’s folder to aaaaaaa…")
            let long = JobStep.fetching(String(repeating: "b", count: 200))
            try expectEqual(long, "Fetching " + String(repeating: "b", count: 79) + "……")
            try expectEqual(JobStep.clip("abc", limit: 80), "abc")
            try expectEqual(JobStep.clip(String(repeating: "x", count: 81), limit: 80).count, 80)
        },
        TestCase("progreso: el título corto de la fase para la línea del paso") {
            try expectEqual(ReviewPhase.reviewing(agents: 2).stepTitle, "Reviewing")
            try expectEqual(ReviewPhase.preparing.stepTitle, "Preparing")
            try expectEqual(ReviewPhase.failed("x", logURL: nil).stepTitle, nil)
            try expectEqual(RespondPhase.analyzing(agents: 0).stepTitle(mode: .feedback, runningTests: false), "Analyzing")
            try expectEqual(RespondPhase.implementing(done: 0, total: 1).stepTitle(mode: .conflicts, runningTests: false), "Resolving")
            try expectEqual(RespondPhase.implementing(done: 0, total: 1).stepTitle(mode: .ciFix, runningTests: false), "Fixing")
            try expectEqual(RespondPhase.pushing.stepTitle(mode: .feedback, runningTests: false), "Pushing")
            try expectEqual(RespondPhase.queued.stepTitle(mode: .feedback, runningTests: true), "Testing")
            try expectEqual(RespondPhase.failed("x", logURL: nil).stepTitle(mode: .feedback, runningTests: false), nil)
        },
        TestCase("progreso throttle: un cambio cada 0,5 s, el último gana; un paso de PRBar sale en el acto") {
            func claude(_ text: String) -> JobActivity { JobActivity(kind: .claude, text: text, startedAt: progressT0) }
            func prbar(_ text: String) -> JobActivity { JobActivity(kind: .prbar, text: text, startedAt: progressT0) }
            func at(_ seconds: TimeInterval) -> Date { progressT0.addingTimeInterval(seconds) }
            var throttle = ActivityThrottle()
            try expectEqual(throttle.offer(claude("A"), now: at(0)), .show(claude("A")))
            try expectEqual(throttle.offer(claude("B"), now: at(0.1)), .hold(until: at(0.5)))
            try expectEqual(throttle.offer(claude("C"), now: at(0.2)), .hold(until: at(0.5)))
            try expectEqual(throttle.due(now: at(0.4)), nil)
            try expectEqual(throttle.due(now: at(0.5)), claude("C"))   // B never showed: the last one wins
            try expectEqual(throttle.due(now: at(0.6)), nil)
            // A PRBar step doesn't wait, and drops the Claude step that was waiting.
            try expectEqual(throttle.offer(claude("D"), now: at(0.7)), .hold(until: at(1.0)))
            try expectEqual(throttle.offer(prbar("Committing…"), now: at(0.75)), .show(prbar("Committing…")))
            try expectEqual(throttle.due(now: at(2)), nil)
            try expectEqual(throttle.offer(prbar("Pushing…"), now: at(0.76)), .show(prbar("Pushing…")))
            // The same step as the one shown: ignored, it keeps its startedAt.
            try expectEqual(throttle.offer(JobActivity(kind: .prbar, text: "Pushing…", startedAt: at(0.8)), now: at(0.8)), .ignore)
            try expectEqual(throttle.shown?.startedAt, progressT0)
            // …and it drops a newer step that was waiting (that one is older news than what's shown again).
            try expectEqual(throttle.offer(claude("E"), now: at(3.0)), .show(claude("E")))
            try expectEqual(throttle.offer(claude("F"), now: at(3.1)), .hold(until: at(3.5)))
            try expectEqual(throttle.offer(claude("E"), now: at(3.2)), .ignore)
            try expectEqual(throttle.due(now: at(4)), nil)
            try expectEqual(throttle.shown?.text, "E")
        },
        TestCase("progreso feed: el sink entrega en orden desde cualquier hilo; clear borra e ignora al sink viejo") { @MainActor in
            let feed = JobActivityFeed(interval: 0.05)
            let sink = feed.sink(prID: "o/r#1")
            await Task.detached {
                sink(.prbar("Reading the PR on GitHub…"))
                sink(.prbar("Creating the worktree…"))
                sink(.claude("Reading a.swift"))
                sink(.claude("Reading b.swift"))
                sink(.claude("Reading c.swift"))
            }.value
            try await waitUntil { feed.current["o/r#1"]?.text == "Reading c.swift" }
            try expectEqual(feed.current["o/r#2"], nil)
            feed.clear(prID: "o/r#1")
            try expectEqual(feed.current["o/r#1"], nil)
            sink(.prbar("Pushing…"))   // the old run, late
            try await Task.sleep(for: .milliseconds(150))
            try expectEqual(feed.current["o/r#1"], nil)
            let next = feed.sink(prID: "o/r#1")
            next(.prbar("Reading the PR on GitHub…"))
            try await waitUntil { feed.current["o/r#1"]?.text == "Reading the PR on GitHub…" }
            feed.clearAll()
            try expectEqual(feed.current, [:])
        },
        TestCase("progreso feed: un paso de PRBar se publica aunque llegue otro de Claude enseguida") { @MainActor in
            let feed = JobActivityFeed(interval: 0.2)
            var seen: [String] = []
            let observation = feed.$current.sink { seen.append($0["o/r#1"]?.text ?? "-") }
            defer { observation.cancel() }
            let sink = feed.sink(prID: "o/r#1")
            sink(.claude("Reading a.swift"))
            sink(.prbar("Committing…"))
            sink(.claude("Reading b.swift"))
            try await waitUntil { feed.current["o/r#1"]?.text == "Reading b.swift" }
            try expectEqual(seen, ["-", "Reading a.swift", "Committing…", "Reading b.swift"])
            // The job ends right after a PRBar step: it's still published once, and then cleared.
            sink(.prbar("Pushing…"))
            feed.clear(prID: "o/r#1")
            try expectEqual(Array(seen.suffix(2)), ["Pushing…", "-"])
        },
    ]
}
