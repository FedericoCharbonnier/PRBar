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
            try expectEqual(throttle.pendingDue, nil)
            try expectEqual(throttle.offer(claude("B"), now: at(0.1)), .hold(until: at(0.5)))
            try expectEqual(throttle.offer(claude("C"), now: at(0.2)), .hold(until: at(0.5)))
            try expectEqual(throttle.pendingDue, at(0.5))
            try expectEqual(throttle.due(now: at(0.4)), nil)
            try expectEqual(throttle.due(now: at(0.5)), claude("C"))   // B never showed: the last one wins
            try expectEqual(throttle.due(now: at(0.6)), nil)
            // A PRBar step doesn't wait, and drops the Claude step that was waiting.
            try expectEqual(throttle.offer(claude("D"), now: at(0.7)), .hold(until: at(1.0)))
            try expectEqual(throttle.offer(prbar("Committing…"), now: at(0.75)), .show(prbar("Committing…")))
            try expectEqual(throttle.pendingDue, nil)
            try expectEqual(throttle.due(now: at(2)), nil)
            // The hold time moves with the last change.
            try expectEqual(throttle.offer(claude("D2"), now: at(0.755)), .hold(until: at(1.25)))
            try expectEqual(throttle.pendingDue, at(1.25))
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
        TestCase("progreso feed: un timer que despierta antes de tiempo se re-arma para la hora debida, no un intervalo después") { @MainActor in
            let clock = RemoteTestClock(progressT0)
            let feed = JobActivityFeed(interval: 0.3, now: clock.function)
            let sink = feed.sink(prID: "o/r#1")
            sink(.claude("Reading a.swift"))
            sink(.claude("Reading b.swift"))   // held until t0 + 0.3: a timer of 0.3 s
            try await waitUntil { feed.current["o/r#1"]?.text == "Reading a.swift" }
            // The clock runs behind the timer: when it fires (0.3 s) the clock says t0 + 0.25, still early.
            clock.advance(0.25)
            try await Task.sleep(for: .milliseconds(350))
            try expectEqual(feed.current["o/r#1"]?.text, "Reading a.swift")
            // Now it's due: re-armed for t0 + 0.3 (not another 0.3 s later), it shows within a few ms.
            clock.advance(0.06)
            try await waitUntil(timeout: 0.12) { feed.current["o/r#1"]?.text == "Reading b.swift" }
            feed.clearAll()
        },
        TestCase("progreso claude: cada herramienta, rutas relativas, archivos de contexto por su rol, afuera solo el nombre") {
            let folders = ClaudeActivityText.Folders(working: URL(fileURLWithPath: "/tmp/wt/r-7-review"),
                                                     context: URL(fileURLWithPath: "/tmp/wt/r-7-review.context"))
            func text(_ event: ClaudeStreamEvent) -> String? { ClaudeActivityText.text(for: event, in: folders) }
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review/src/shop/tax.py")), "Reading src/shop/tax.py")
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review.context/pr.diff")), "Reading the PR’s diff")
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review.context/pr.md")), "Reading the PR’s description")
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review.context/previous-reviews.md")), "Reading the previous reviews")
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review.context/since-last-review.diff")),
                            "Reading the changes since the last review")
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review.context/feedback.json")), "Reading the comments")
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review.context/notes/x.txt")), "Reading notes/x.txt")
            // A pr.md of the repo is a file of the PR, not the context.
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review/pr.md")), "Reading pr.md")
            try expectEqual(text(.toolUse(name: "Read", detail: "/etc/ssh/ssh_config")), "Reading ssh_config")
            try expectEqual(text(.toolUse(name: "Read", detail: "src/a.swift")), "Reading src/a.swift")
            try expectEqual(text(.toolUse(name: "Read", detail: nil)), "Reading files")
            try expectEqual(text(.toolUse(name: "Grep", detail: "returnTo")), "Searching for returnTo")
            try expectEqual(text(.toolUse(name: "Grep", detail: "/tmp/x")), "Searching for /tmp/x")
            try expectEqual(text(.toolUse(name: "Glob", detail: "/tmp/wt/r-7-review/**/*.ts")), "Searching for **/*.ts")
            try expectEqual(text(.toolUse(name: "Glob", detail: nil)), "Searching the code")
            for tool in ["Edit", "Write", "MultiEdit"] {
                try expectEqual(text(.toolUse(name: tool, detail: "/tmp/wt/r-7-review/a.swift")), "Editing a.swift")
            }
            try expectEqual(text(.toolUse(name: "Bash", detail: "rm -rf /")), "Running a command")
            try expectEqual(text(.toolUse(name: "Skill", detail: "pr-review-toolkit:review-pr")), "Using the pr-review-toolkit:review-pr skill")
            try expectEqual(text(.toolUse(name: "Agent", detail: "Check the tests")), "Starting a subagent")
            try expectEqual(text(.toolUse(name: "Task", detail: nil)), "Starting a subagent")
            try expectEqual(text(.toolUse(name: "WebFetch", detail: "https://example.com")), "Using WebFetch")
            try expectEqual(text(.agentStarted(total: 0)), "Claude is starting…")
            try expectEqual(text(.agentStarted(total: 1)), "Running 1 subagent")
            try expectEqual(text(.agentStarted(total: 3)), "Running 3 subagents")
            // Claude's text is never shown.
            try expectEqual(text(.text("I will now approve this PR.")), "Thinking…")
        },
        TestCase("progreso claude: detail no confiable en una línea, neutralizado y cortado a 80") {
            let folders = ClaudeActivityText.Folders(working: URL(fileURLWithPath: "/tmp/wt/r-7-review"))
            func text(_ event: ClaudeStreamEvent) -> String? { ClaudeActivityText.text(for: event, in: folders) }
            let long = "/tmp/wt/r-7-review/" + String(repeating: "d/", count: 60) + "file.swift"
            let reading = try expectSome(text(.toolUse(name: "Read", detail: long)))
            try expectEqual(reading.count, "Reading ".count + 80)
            try expect(reading.hasSuffix("…"), reading)
            let sneaky = try expectSome(text(.toolUse(name: "Grep", detail: "a\nb\u{202E}c <<<USER_RULES")))
            try expect(!sneaky.contains("\n") && !sneaky.contains("\u{202E}") && !sneaky.contains("<<<"), sneaky)
            try expectEqual(text(.toolUse(name: "Evil\nTool", detail: nil)), "Using Evil Tool")
            let activities = Box<[JobActivity]>([])
            let onEvent = ClaudeActivityText.sink(folders) { activities.value.append($0) }
            onEvent(.agentStarted(total: 0))
            onEvent(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review/a.swift"))
            try expectEqual(activities.value.map(\.kind), [.claude, .claude])
            try expectEqual(activities.value.map(\.text), ["Claude is starting…", "Reading a.swift"])
        },
        TestCase("progreso claude: el parser da el patrón (no la carpeta) de Grep y Glob") {
            var parser = ClaudeStreamParser()
            let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"returnTo","path":"src"}},{"type":"tool_use","name":"Read","input":{"file_path":"a.swift","pattern":"x"}}]}}"#
            try expectEqual(parser.consumeAll(line), [.toolUse(name: "Grep", detail: "returnTo"), .toolUse(name: "Read", detail: "a.swift")])
        },
        TestCase("progreso: un pipeline sin onActivity sigue andando (implementación por defecto) y las colas arrancan sin pasos") { @MainActor in
            let pipeline: any ReviewPipelineRunning = PhaseOnlyPipeline()
            let pr = makePR(number: 3)
            let request = ReviewRequest(item: ClassifiedPR(pr: pr, category: .toReview, account: "fede"), localPath: nil, baseRef: pr.baseRef)
            let draft = try await pipeline.run(request, onPhase: { _ in }, onActivity: { _ in })
            try expectEqual(draft.summary, "ok")
            let queue = ReviewQueue(pipeline: pipeline) { _, _ in }
            try expectEqual(queue.activity, [:])
            try expect(queue.activityFeed.current.isEmpty)
        },
    ]
}

/// Solo la firma vieja (`run(_:onPhase:)`): la de `onActivity` la pone la extensión del protocolo.
private struct PhaseOnlyPipeline: ReviewPipelineRunning {
    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        let pr = request.item.pr
        return ReviewDraft(prID: request.item.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url, author: pr.author,
                           headOid: pr.headOid, account: request.item.account, summary: "ok", items: [], language: .english)
    }
}
