import Foundation
import PRBarCore

private func classify(_ pr: PullRequest, me: String = "me", watching: Set<String> = ["juan"]) -> PRCategory? {
    ActionClassifier.classify(pr, me: me, watchedUsers: watching)
}

enum ClassifierTests {
    static let cases: [TestCase] = [
        TestCase("latest feedback: la review o el comentario más reciente de otra persona (sin bots, sin los míos ni aprobaciones)") {
            let pr = makePR(author: "me", reviews: [review("ana", .changesRequested, at: 10), review("luis", .approved, at: 90),
                                                    review("me", .commented, at: 95), review("bot", .commented, at: 99, bot: true)],
                            comments: [comment("ana", at: 30), comment("ME", at: 80), comment("ci", at: 98, bot: true)])
            try expectEqual(ActionClassifier.latestFeedbackAt(pr, me: "me"), at(30))
            try expectEqual(ActionClassifier.latestFeedbackAt(makePR(author: "me"), me: "me"), nil)
        },
        TestCase("classifier: autor no seguido y sin pedido de review → irrelevante") {
            try expectEqual(classify(makePR(author: "otro")), nil)
        },
        TestCase("classifier: autor seguido sin review mía → para revisar") {
            try expectEqual(classify(makePR()), .toReview)
        },
        TestCase("classifier: review pedida aunque no siga al autor → para revisar") {
            try expectEqual(classify(makePR(author: "otro", requested: ["me"])), .toReview)
        },
        TestCase("classifier: draft → otros") {
            try expectEqual(classify(makePR(isDraft: true)), .other)
        },
        TestCase("classifier: draft con review pedida → otros") {
            try expectEqual(classify(makePR(isDraft: true, requested: ["me"])), .other)
        },
        TestCase("classifier: aprobado y sin commits nuevos → otros") {
            try expectEqual(classify(makePR(lastCommit: 0, reviews: [review("me", .approved, at: 10)])), .other)
        },
        TestCase("classifier: aprobado y con commits nuevos → otros") {
            try expectEqual(classify(makePR(lastCommit: 20, reviews: [review("me", .approved, at: 10)])), .other)
        },
        TestCase("classifier: pedí cambios y hubo commit después → actualizado") {
            try expectEqual(classify(makePR(lastCommit: 20, reviews: [review("me", .changesRequested, at: 10)])), .updatedSinceMyReview)
        },
        TestCase("classifier: pedí cambios y no hubo commit después → otros") {
            try expectEqual(classify(makePR(lastCommit: 5, reviews: [review("me", .changesRequested, at: 10)])), .other)
        },
        TestCase("classifier: comenté y hubo commit después → actualizado") {
            try expectEqual(classify(makePR(lastCommit: 20, reviews: [review("me", .commented, at: 10)])), .updatedSinceMyReview)
        },
        TestCase("classifier: gana mi última review") {
            let pr = makePR(lastCommit: 20, reviews: [review("me", .changesRequested, at: 10), review("me", .approved, at: 30)])
            try expectEqual(classify(pr), .other)
        },
        TestCase("classifier: reviews pendientes o descartadas no cuentan") {
            let pr = makePR(reviews: [review("me", .pending, at: 10), review("me", .dismissed, at: 11)])
            try expectEqual(classify(pr), .toReview)
        },
        TestCase("classifier: me vuelven a pedir review después de aprobar → para revisar") {
            let pr = makePR(lastCommit: 20, reviews: [review("me", .approved, at: 10)], requested: ["me"])
            try expectEqual(classify(pr), .toReview)
        },
        TestCase("classifier: logins sin distinguir mayúsculas") {
            let pr = makePR(author: "Juan", lastCommit: 20, reviews: [review("ME", .changesRequested, at: 10)])
            try expectEqual(classify(pr, me: "me", watching: ["JUAN"]), .updatedSinceMyReview)
        },
        TestCase("classifier: mi PR con cambios pedidos después del último commit → feedback") {
            let pr = makePR(author: "me", lastCommit: 0, reviews: [review("ana", .changesRequested, at: 5)])
            try expectEqual(classify(pr), .myFeedback)
            try expectEqual(ActionClassifier.newFeedback(pr, me: "me"), FeedbackSummary(changesRequested: true, count: 1))
        },
        TestCase("classifier: mi PR con comentario de otro después del commit → feedback") {
            let pr = makePR(author: "me", lastCommit: 0, comments: [comment("ana", at: 3), comment("leo", at: 4)])
            try expectEqual(classify(pr), .myFeedback)
            try expectEqual(ActionClassifier.newFeedback(pr, me: "me"), FeedbackSummary(changesRequested: false, count: 2))
        },
        TestCase("classifier: mi PR con feedback anterior al último commit → otros") {
            let pr = makePR(author: "me", lastCommit: 10, reviews: [review("ana", .changesRequested, at: 5)], comments: [comment("ana", at: 6)])
            try expectEqual(classify(pr), .other)
        },
        TestCase("classifier: mis propios comentarios no son feedback") {
            try expectEqual(classify(makePR(author: "me", lastCommit: 0, comments: [comment("me", at: 5)])), .other)
        },
        TestCase("classifier: comentarios de bots no son feedback") {
            try expectEqual(classify(makePR(author: "me", lastCommit: 0, comments: [comment("codecov", at: 5, bot: true)])), .other)
        },
        TestCase("classifier: una aprobación no es feedback") {
            let pr = makePR(author: "me", lastCommit: 0, reviews: [review("ana", .approved, at: 5)])
            try expect(ActionClassifier.newFeedback(pr, me: "me").isEmpty)
            try expectEqual(classify(pr), .readyToMerge)
        },
    ]
}
