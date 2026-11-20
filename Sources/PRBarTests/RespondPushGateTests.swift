import Foundation
import PRBarCore

private let sha = String(repeating: "1", count: 40)

private func result(tests: TestRun? = nil, committed: Bool = true) -> RespondResult {
    RespondResult(items: [ItemResult(id: "a", status: committed ? .committed : .noChanges, commit: committed ? sha : nil, summary: "")],
                  diffStat: "", tests: tests)
}

private func record(result: RespondResult? = nil, pushed: Bool = false) -> RespondRecord {
    let draft = RespondDraft(
        prID: "o/r#8", repo: RepoRef(owner: "o", name: "r"), number: 8, title: "PR 8",
        url: URL(string: "https://github.com/o/r/pull/8")!, headRef: "f", account: "me",
        worktree: ResolvedWorktree(path: "/wt", origin: .dedicated), startHeadOid: "", items: [])
    return RespondRecord(draft: draft, result: result, pushed: pushed, startedAt: Date(timeIntervalSince1970: 0))
}

private let readyToPush = RespondPhase.readyToPush(record().draft, result())

private func pushCheck(
    _ record: RespondRecord = record(result: result()), phase: RespondPhase? = readyToPush, runningTests: Bool = false,
    chatting: Bool = false, gate: RespondPushGate = .ready, anyway: Bool = false
) -> String? {
    RespondPushGate.commandCheck(record, phase: phase, runningTests: runningTests, chatting: chatting, gate: gate,
                                 anyway: anyway)?.message
}

enum RespondPushGateTests {
    static let cases: [TestCase] = [
        TestCase("respond push (CLI): qué impide pushear, en orden") {
            try expectEqual(pushCheck(), nil)
            try expectEqual(pushCheck(phase: .failed("x", logURL: nil)), nil)
            try expect(pushCheck(record(result: nil))?.contains("reply-only") == true)
            try expect(pushCheck(phase: .implementing(done: 1, total: 2))?.contains("can’t be pushed now (implementing)") == true)
            try expect(pushCheck(runningTests: true)?.contains("Wait for the tests") == true)
            try expect(pushCheck(record(result: result(), pushed: true))?.contains("already pushed") == true)
            let failed = TestRun(command: "make test", passed: false, outputTail: "")
            try expect(pushCheck(gate: .testsFailed(failed))?.contains("--anyway") == true)
            try expectEqual(pushCheck(gate: .testsFailed(failed), anyway: true), nil)
            try expect(pushCheck(anyway: true)?.contains("Nothing is blocked") == true)
            try expect(pushCheck(chatting: true)?.contains("--stop") == true)
        },
        TestCase("respond push gate: sin la opción, sin comando, sin commits o ya pusheado no hay tests") {
            try expectEqual(RespondPushGate.evaluate(result: result(), testCommand: "make test", runTestsBeforePush: false, pushed: false), .ready)
            try expectEqual(RespondPushGate.evaluate(result: result(), testCommand: "  ", runTestsBeforePush: true, pushed: false), .ready)
            try expectEqual(RespondPushGate.evaluate(result: result(committed: false), testCommand: "make test",
                                                     runTestsBeforePush: true, pushed: false), .ready)
            try expectEqual(RespondPushGate.evaluate(result: result(), testCommand: "make test", runTestsBeforePush: true, pushed: true), .ready)
        },
        TestCase("respond push gate: sin corrida válida corre tests; pasó → push; falló → bloqueado") {
            try expectEqual(RespondPushGate.evaluate(result: result(), testCommand: "make test", runTestsBeforePush: true, pushed: false),
                            .runTests)
            let other = TestRun(command: "npm test", passed: true, outputTail: "")
            try expectEqual(RespondPushGate.evaluate(result: result(tests: other), testCommand: "make test",
                                                     runTestsBeforePush: true, pushed: false), .runTests)
            let passed = TestRun(command: "make test", passed: true, outputTail: "")
            try expectEqual(RespondPushGate.evaluate(result: result(tests: passed), testCommand: "make test",
                                                     runTestsBeforePush: true, pushed: false), .ready)
            let failed = TestRun(command: "make test", passed: false, outputTail: "1 failure")
            try expectEqual(RespondPushGate.evaluate(result: result(tests: failed), testCommand: "make test",
                                                     runTestsBeforePush: true, pushed: false), .testsFailed(failed))
        },
    ]
}
