import Foundation
import PRBarCore

private let sha = String(repeating: "1", count: 40)

private func result(tests: TestRun? = nil, committed: Bool = true) -> RespondResult {
    RespondResult(items: [ItemResult(id: "a", status: committed ? .committed : .noChanges, commit: committed ? sha : nil, summary: "")],
                  diffStat: "", tests: tests)
}

enum RespondPushGateTests {
    static let cases: [TestCase] = [
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
