import Foundation
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

private func request(
    _ pr: ClassifiedPR = item(), method: MergeMethod? = nil, options opts: MergeOptions = options(), confirm: Bool = false,
    blocked: String? = nil, phase: MergePhase? = nil
) -> MergeFlow.RequestRoute {
    MergeFlow.request(pr, method: method, options: opts, confirm: confirm, blockedReason: blocked, phase: phase)
}

enum MergeFlowTests {
    static let cases: [TestCase] = [
        TestCase("merge flow: sin confirmación mergea con el método por defecto o el elegido") {
            try expectEqual(request(), .merge(.squash))
            try expectEqual(request(method: .merge), .merge(.merge))
        },
        TestCase("merge flow: con confirmación abre el diálogo") {
            try expectEqual(request(confirm: true), .confirm(.squash))
            try expectEqual(request(method: .merge, confirm: true), .confirm(.merge))
        },
        TestCase("merge flow: un merge en curso o hecho no se pide de nuevo; un error previo no impide") {
            try expectEqual(request(phase: .merging(.squash)), .ignore)
            try expectEqual(request(phase: .merged(.squash)), .ignore)
            try expectEqual(request(phase: .failed(method: .squash, error: .headChanged)), .merge(.squash))
        },
        TestCase("merge flow: lo que no se puede mergear es un error visible, no un silencio") {
            try expectEqual(request(blocked: "Installing an update"), .fail(.squash, .blocked("Installing an update")))
            try expectEqual(request(options: options(.disabled(reason: "Branch is behind main"))),
                            .fail(.squash, .unavailable("Branch is behind main")))
            try expectEqual(request(method: .rebase), .fail(.rebase, .unavailable("This repo doesn’t allow Rebase and Merge")))
            try expectEqual(request(item(category: .myFeedback)), .fail(.squash, .unavailable("This PR isn’t ready to merge")))
            try expectEqual(request(options: options(methods: [], default: nil)),
                            .fail(nil, .unavailable("This repo doesn’t allow any merge method")))
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
        TestCase("merge flow: se cierran los diálogos de PRs que ya no están listos") {
            let snapshot = Snapshot(items: [
                item(),
                ClassifiedPR(pr: makePR(number: 8, author: "me"), category: .myFeedback, account: "me"),
            ], fetchedAt: t0)
            try expectEqual(MergeFlow.confirmationsToClose(open: ["o/r#7", "o/r#8", "o/r#9"], snapshot: snapshot), ["o/r#8", "o/r#9"])
            try expectEqual(MergeFlow.confirmationsToClose(open: [], snapshot: snapshot), [])
        },
        TestCase("merge flow: el contenido del diálogo cambia si cambia algo de lo que muestra") {
            let base = MergeFlow.confirmationContentID(item(), method: .squash, options: options(), deletesBranch: false)
            try expectEqual(base, MergeFlow.confirmationContentID(item(), method: .squash, options: options(), deletesBranch: false))
            let variants = [
                MergeFlow.confirmationContentID(item(head: "x"), method: .squash, options: options(), deletesBranch: false),
                MergeFlow.confirmationContentID(item(), method: .merge, options: options(), deletesBranch: false),
                MergeFlow.confirmationContentID(item(), method: .squash, options: options(), deletesBranch: true),
                MergeFlow.confirmationContentID(item(), method: .squash, options: options(.enabled(note: "n")), deletesBranch: false),
                MergeFlow.confirmationContentID(item(), method: .squash, options: options(methods: [.squash]), deletesBranch: false),
            ]
            for variant in variants { try expect(variant != base, "\(variant) == \(base)") }
        },
    ]
}
