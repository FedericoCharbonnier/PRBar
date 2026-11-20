import Foundation
import PRBarCLIKit
import PRBarCore

private let clean = PRMergeState(nodeID: "PR_7", mergeable: .mergeable, status: .clean)

private func item(head: String = "cafe7", category: PRCategory = .readyToMerge, merge: PRMergeState = clean) -> ClassifiedPR {
    ClassifiedPR(pr: makePR(number: 7, author: "me", head: head, decision: .approved, merge: merge), category: category, account: "me")
}

private func options(
    _ availability: MergeAvailability = .enabled(note: nil), methods: [MergeMethod] = [.squash, .merge], default method: MergeMethod? = .squash
) -> MergeOptions {
    MergeOptions(availability: availability, methods: methods, defaultMethod: method)
}

private func check(
    _ pr: ClassifiedPR = item(), method: MergeMethod? = nil, options opts: MergeOptions = options(), blocked: String? = nil,
    phase: MergePhase? = nil, expected: String? = nil
) -> Result<MergeMethod, CommandFailure> {
    MergeFlow.commandCheck(pr, method: method, options: opts, blockedReason: blocked, phase: phase, expectedHeadOid: expected)
}

enum MergeFlowTests {
    static let cases: [TestCase] = [
        TestCase("merge flow: solo lo que llegó a GitHub queda en el historial como intento fallido") {
            for error: MergeError in [.headChanged, .forbidden("no"), .notMergeable("no"), .mergeQueueRequired("q"),
                                      .github(.network("offline")), .other("x")] {
                try expect(MergeFlow.recordsAttempt(error), "\(error)")
            }
            for error: MergeError in [.alreadyInProgress, .alreadyMerged, .missingMergeData, .blocked("update"),
                                      .unavailable("not ready"), .noLongerOpen] {
                try expect(!MergeFlow.recordsAttempt(error), "\(error)")
            }
        },
        TestCase("merge flow (CLI): elige el método y mergea solo el head que se mostró") {
            try expectEqual(check(), .success(.squash))
            try expectEqual(check(method: .merge, expected: "cafe7"), .success(.merge))
            guard case .failure(let changed) = check(expected: "beef1") else { throw TestFailure(description: "mergeó otro head") }
            try expectEqual(changed.code, .invalidState)
            try expect(changed.message.contains("changed since") && changed.message.contains("cafe7"), changed.message)
            guard case .failure(let missing) = check(expected: "") else { throw TestFailure(description: "sin head") }
            try expectEqual(missing.code, .invalidUsage)
        },
        TestCase("merge flow (CLI): lo que no se puede mergear es un error, con un error previo no") {
            func failure(_ result: Result<MergeMethod, CommandFailure>) -> CommandFailure? {
                if case .failure(let failure) = result { return failure }
                return nil
            }
            try expect(failure(check(item(category: .myFeedback)))?.message.contains("isn’t in Ready to Merge") == true)
            try expectEqual(failure(check(blocked: "Installing an update")), CommandFailure(.invalidState, "Installing an update"))
            try expect(failure(check(phase: .merging(.squash)))?.message.contains("already being merged") == true)
            try expect(failure(check(phase: .merged(.squash)))?.message.contains("already merged") == true)
            try expectEqual(failure(check(method: .rebase)),
                            CommandFailure(.invalidState, "This repo doesn’t allow Rebase and Merge"))
            try expectEqual(failure(check(options: options(methods: [], default: nil)))?.code, .invalidState)
            try expectEqual(check(phase: .failed(method: .squash, error: .headChanged)), .success(.squash))
        },
        TestCase("merge flow (CLI): la vista previa dice por qué no se puede todavía, sin fallar") {
            func preview(_ pr: ClassifiedPR = item(), method: MergeMethod? = nil, options opts: MergeOptions = options(),
                         blocked: String? = nil, phase: MergePhase? = nil) -> MergeFlow.PreviewCheck {
                MergeFlow.previewCheck(pr, method: method, options: opts, blockedReason: blocked, phase: phase)
            }
            try expectEqual(preview(), MergeFlow.PreviewCheck(method: .squash, problem: nil))
            try expectEqual(preview(method: .merge), MergeFlow.PreviewCheck(method: .merge, problem: nil))
            let feedback = preview(item(category: .myFeedback))
            try expectEqual(feedback.method, .squash)
            try expect(feedback.problem?.contains("isn’t in Ready to Merge") == true, "\(feedback)")
            try expectEqual(preview(method: .rebase), MergeFlow.PreviewCheck(method: .rebase, problem: "This repo doesn’t allow Rebase and Merge"))
            try expectEqual(preview(blocked: "Installing an update").problem, "Installing an update")
            let none = preview(options: options(methods: [], default: nil))
            try expectEqual(none.method, .merge)
            try expect(none.problem != nil)
            // La vista previa lo lleva y lo muestra.
            let info = MergePreviewInfo(item: item(category: .myFeedback), method: feedback.method, options: options(),
                                        deletesBranch: false, phase: nil, problem: feedback.problem)
            try expectEqual(info.problem, feedback.problem)
            var out = ""
            MergePreviewRender.summary(info, Output(terminal: .plain, json: false, out: { out += $0 }, err: { _ in }))
            try expect(out.contains("Can’t merge yet: "), out)
        },
        TestCase("merge flow (CLI): la vista previa muestra lo del diálogo") {
            let state = PRMergeState(nodeID: "PR_7", mergeable: .mergeable, status: .unstable, commitCount: 3)
            let preview = MergePreviewInfo(item: item(merge: state), method: .squash,
                                           options: options(.enabled(note: "Some checks are failing")), deletesBranch: true,
                                           phase: .failed(method: .squash, error: .headChanged))
            try expectEqual(preview.pr, "o/r#7")
            try expectEqual(preview.headOid, "cafe7")
            try expectEqual(preview.baseRef, "develop")
            try expectEqual(preview.headRef, "feature/7")
            try expectEqual(preview.commitCount, 3)
            try expectEqual(preview.method, .squash)
            try expectEqual(preview.note, "Some checks are failing")
            try expectEqual(preview.deletesBranch, true)
            try expectEqual(preview.previousError, MergeError.headChanged.localizedDescription)
        },
        TestCase("merge flow: \"Merge…\" abre la ventana salvo con el PR ya mergeado (spec G.1)") {
            try expectEqual(MergeFlow.request(phase: nil), .open)
            try expectEqual(MergeFlow.request(phase: .merging(.squash)), .open)
            try expectEqual(MergeFlow.request(phase: .failed(method: .squash, error: .headChanged)), .open)
            try expectEqual(MergeFlow.request(phase: .merged(.squash)), .ignore)
        },
        TestCase("merge flow: MergePolicy.problem (la CLI y AppModel.merge)") {
            try expectEqual(MergePolicy.problem(item(), method: .squash, options: options()), nil)
            try expectEqual(MergePolicy.problem(item(category: .other), method: .squash, options: options()),
                            .unavailable("This PR isn’t ready to merge"))
            try expectEqual(MergePolicy.problem(item(), method: .rebase, options: options()),
                            .unavailable("This repo doesn’t allow Rebase and Merge"))
            try expectEqual(MergePolicy.problem(item(), method: .squash, options: options(.disabled(reason: MergePolicy.checking))),
                            .unavailable(MergePolicy.checking))
        },
        TestCase("merge flow: Retry tras head cambiado solo limpia (aunque no haya confirmación)") {
            let failure = MergeFailure(item: item(head: "old"), method: .squash, error: .headChanged)
            try expectEqual(MergeFlow.retry(failure, current: item(head: "new")), .changed)
            // Aunque el refresco no haya traído el head nuevo: el usuario vuelve a apretar Merge.
            try expectEqual(MergeFlow.retry(failure, current: item(head: "old")), .changed)
        },
        TestCase("merge flow: Retry de otro error con el PR cambiado tampoco mergea lo que no se vio") {
            let failure = MergeFailure(item: item(head: "old"), method: .squash, error: .github(.network("offline")))
            try expectEqual(MergeFlow.retry(failure, current: item(head: "new")), .changed)
        },
        TestCase("merge flow: Retry de otro error con el mismo head vuelve a pedir con el mismo método") {
            let failure = MergeFailure(item: item(), method: .merge, error: .github(.network("offline")))
            let current = item(merge: PRMergeState(nodeID: "PR_7", mergeable: .mergeable, status: .unstable))
            try expectEqual(MergeFlow.retry(failure, current: current), .request(current, .merge))
            let noMethod = MergeFailure(item: item(), method: nil, error: .unavailable("x"))
            try expectEqual(MergeFlow.retry(noMethod, current: current), .request(current, nil))
        },
        TestCase("merge flow: Retry sin el PR en la lista → hay que mirar si se mergeó") {
            let failure = MergeFailure(item: item(), method: .squash, error: .github(.network("offline")))
            try expectEqual(MergeFlow.retry(failure, current: nil), .missing)
        },
    ]
}
