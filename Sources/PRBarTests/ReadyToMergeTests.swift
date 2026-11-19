import Foundation
import PRBarCore

private func classify(_ pr: PullRequest) -> PRCategory? {
    ActionClassifier.classify(pr, me: "me", watchedUsers: ["juan"])
}

private let clean = PRMergeState(nodeID: "PR_1", mergeable: .mergeable, status: .clean)

/// Mi PR, con el último commit en el minuto 10 (las reviews antes de eso no son feedback nuevo).
private func mine(
    isDraft: Bool = false, ci: CIState = .success, decision: ReviewDecision, reviews: [PRReview] = [],
    comments: [PRComment] = [], merge: PRMergeState = clean
) -> PullRequest {
    makePR(author: "me", isDraft: isDraft, lastCommit: 10, ci: ci, decision: decision, reviews: reviews, comments: comments, merge: merge)
}

enum ReadyToMergeTests {
    static let cases: [TestCase] = [
        TestCase("ready to merge: mi PR aprobado sin feedback nuevo → readyToMerge") {
            try expectEqual(classify(mine(decision: .approved, reviews: [review("ana", .approved, at: 5)])), .readyToMerge)
        },
        TestCase("ready to merge: aprobado pero con feedback nuevo → sigue en myFeedback") {
            let pr = mine(decision: .approved, reviews: [review("ana", .approved, at: 5)], comments: [comment("leo", at: 20)])
            try expectEqual(classify(pr), .myFeedback)
        },
        TestCase("ready to merge: con conflictos → other") {
            let conflicting = PRMergeState(nodeID: "PR_1", mergeable: .conflicting, status: .unknown)
            try expectEqual(classify(mine(decision: .approved, merge: conflicting)), .other)
            let dirty = PRMergeState(nodeID: "PR_1", mergeable: .unknown, status: .dirty)
            try expectEqual(classify(mine(decision: .approved, merge: dirty)), .other)
        },
        TestCase("ready to merge: draft aprobado → other") {
            try expectEqual(classify(mine(isDraft: true, decision: .approved)), .other)
        },
        TestCase("ready to merge: falta la aprobación requerida o hay cambios pedidos viejos → other") {
            try expectEqual(classify(mine(decision: .reviewRequired)), .other)
            try expectEqual(classify(mine(decision: .changesRequested, reviews: [review("ana", .changesRequested, at: 5)])), .other)
        },
        TestCase("ready to merge: mergeabilidad todavía desconocida → entra igual") {
            try expectEqual(classify(mine(decision: .approved, merge: .unknown)), .readyToMerge)
        },
        TestCase("ready to merge: CI fallando, checks pendientes o bloqueado no lo sacan") {
            let unstable = PRMergeState(nodeID: "PR_1", mergeable: .mergeable, status: .unstable)
            try expectEqual(classify(mine(ci: .failure, decision: .approved, merge: unstable)), .readyToMerge)
            let blocked = PRMergeState(nodeID: "PR_1", mergeable: .mergeable, status: .blocked)
            try expectEqual(classify(mine(ci: .pending, decision: .approved, merge: blocked)), .readyToMerge)
        },
        TestCase("ready to merge: repo sin reviews requeridas y aprobación vigente → readyToMerge") {
            try expectEqual(classify(mine(decision: .none, reviews: [review("ana", .approved, at: 5)])), .readyToMerge)
        },
        TestCase("ready to merge: repo sin reviews requeridas y la misma persona pide cambios después → other") {
            let pr = mine(decision: .none, reviews: [review("ana", .approved, at: 2), review("ana", .changesRequested, at: 5)])
            try expectEqual(classify(pr), .other)
        },
        TestCase("ready to merge: repo sin reviews requeridas y otra persona pide cambios → other") {
            let pr = mine(decision: .none, reviews: [review("ana", .approved, at: 5), review("leo", .changesRequested, at: 6)])
            try expectEqual(classify(pr), .other)
        },
        TestCase("ready to merge: aprobación descartada → other") {
            let pr = mine(decision: .none, reviews: [review("ana", .approved, at: 2), review("ana", .dismissed, at: 5)])
            try expectEqual(classify(pr), .other)
        },
        TestCase("ready to merge: un comentario después de aprobar no anula la aprobación") {
            let pr = mine(decision: .none, reviews: [review("ana", .approved, at: 2), review("ana", .commented, at: 5)])
            try expectEqual(classify(pr), .readyToMerge)
        },
        TestCase("ready to merge: sin reviews, o solo la mía, no alcanza") {
            try expectEqual(classify(mine(decision: .none)), .other)
            try expectEqual(classify(mine(decision: .none, reviews: [review("me", .approved, at: 5)])), .other)
        },
        TestCase("ready to merge: un PR ajeno aprobado no es Ready to Merge") {
            let pr = makePR(author: "juan", decision: .approved, reviews: [review("me", .approved, at: 5)], merge: clean)
            try expectEqual(classify(pr), .other)
        },
        TestCase("ready to merge: cuenta para el badge y va después de My PRs with Feedback") {
            try expect(PRCategory.readyToMerge.countsForBadge)
            try expectEqual(PRCategory.readyToMerge.title, "Ready to Merge")
            try expect(PRCategory.myFeedback < .readyToMerge && PRCategory.readyToMerge < .other)
            let snapshot = Snapshot(items: [ClassifiedPR(pr: mine(decision: .approved), category: .readyToMerge, account: "me")], fetchedAt: t0)
            try expectEqual(snapshot.badgeCount, 1)
        },
    ]
}
