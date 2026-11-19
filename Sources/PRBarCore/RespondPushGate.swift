import Foundation

/// What "Push and Reply" does with "Run tests before pushing" (spec E.5).
public enum RespondPushGate: Equatable, Sendable {
    /// Push now.
    case ready
    /// Run the tests first; push only if they pass.
    case runTests
    /// The tests of this code failed: push only if the user says "Push Anyway".
    case testsFailed(TestRun)

    /// Tests only count when there are commits to push and the repo has a test command. A run counts if it's of the
    /// same command (a chat turn that changed the code already clears `tests`).
    public static func evaluate(result: RespondResult, testCommand: String?, runTestsBeforePush: Bool, pushed: Bool) -> RespondPushGate {
        let command = testCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard runTestsBeforePush, !pushed, !command.isEmpty, RespondCounts.commits(result) > 0 else { return .ready }
        guard let tests = result.tests, tests.command.trimmingCharacters(in: .whitespacesAndNewlines) == command else {
            return .runTests
        }
        return tests.passed ? .ready : .testsFailed(tests)
    }
}
