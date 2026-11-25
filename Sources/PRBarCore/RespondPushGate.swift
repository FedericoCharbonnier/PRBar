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

extension RespondPushGate {
    public var isTestsFailed: Bool {
        if case .testsFailed = self { return true }
        return false
    }

    /// `prbar ci push` sobre una corrida de Responder (o al revés) no pushea, tampoco con `--yes` (K.6.14). Un Resolve
    /// Conflicts solo se pushea pidiéndolo por su modo (decisión C.9.9): `nil` (la web, una CLI vieja) tampoco. Fuera
    /// de eso, `expected == nil` no se chequea. Desde el teléfono (`fromPhone`) un Resolve Conflicts nunca se pushea.
    public static func modeCheck(expected: RespondMode?, actual: RespondMode, prID: String, fromPhone: Bool = false) -> CommandFailure? {
        if actual == .conflicts && fromPhone {
            return CommandFailure(.unauthorized, "\(prID) is a Resolve Conflicts run: push it from PRBar on your Mac.")
        }
        if actual == .conflicts && expected != .conflicts {
            return CommandFailure(.invalidState,
                                  "\(prID) is a Resolve Conflicts run: push it with `prbar conflicts push \(prID)` or from PRBar on your Mac.")
        }
        guard let expected, expected != actual else { return nil }
        switch actual {
        case .feedback where expected == .conflicts, .ciFix where expected == .conflicts:
            return CommandFailure(.invalidState,
                                  "\(prID) isn’t a Resolve Conflicts run: use `\(pushCommand(actual)) \(prID)`.")
        case .feedback:
            return CommandFailure(.invalidState, "\(prID) isn’t a Fix CI: use `prbar respond push \(prID)`.")
        case .ciFix:
            return CommandFailure(.invalidState, "\(prID) is a Fix CI: use `prbar ci push \(prID)`.")
        case .conflicts:
            return nil
        }
    }

    /// El comando de la CLI que pushea una corrida de este modo.
    public static func pushCommand(_ mode: RespondMode) -> String {
        switch mode {
        case .ciFix: "prbar ci push"
        case .conflicts: "prbar conflicts push"
        case .feedback: "prbar respond push"
        }
    }

    /// Lo que impide "Push and Reply" / "Push Anyway" (`anyway`) desde `prbar respond push`: sin fixes, en una fase
    /// que no lo permite, con tests corriendo, ya todo publicado, tests que fallaron (sin `--anyway`), nada bloqueado
    /// por tests (con `--anyway`) o el chat contestando. `nil` = se puede.
    public static func commandCheck(
        _ record: RespondRecord, phase: RespondPhase?, runningTests: Bool, chatting: Bool, gate: RespondPushGate, anyway: Bool,
        blockedByCI: Bool = false
    ) -> CommandFailure? {
        let id = record.draft.prID
        guard record.result != nil else {
            return CommandFailure(.invalidState, "Nothing to push: \(id) has no implemented fixes. To post only replies use `prbar respond reply-only \(id)`.")
        }
        switch phase {
        case .readyToPush?, .failed?: break
        default: return CommandFailure(.invalidState, "\(id) can’t be pushed now (\(phase?.cliName ?? "none")).")
        }
        if runningTests { return CommandFailure(.invalidState, "Wait for the tests to finish.") }
        if record.pushed && RespondCounts.pendingReplies(record) == 0 {
            return CommandFailure(.invalidState, "Everything was already pushed and posted.")
        }
        let command = pushCommand(record.draft.mode)
        if anyway && !gate.isTestsFailed && !blockedByCI {
            return CommandFailure(.invalidState, record.draft.implementsAlone
                ? "Nothing is blocked: use `\(command) \(id)`."
                : "Nothing is blocked by failed tests: use `\(command) \(id)`.")
        }
        if !anyway, case .testsFailed(let run) = gate {
            return CommandFailure(.invalidState, "“\(run.command)” failed, so PRBar didn’t push. Push anyway with `\(command) \(id) --anyway`.")
        }
        if chatting {
            return CommandFailure(.invalidState, "Wait for Claude to finish answering in the chat (`prbar chat \(id) --stop` stops it).")
        }
        return nil
    }
}
