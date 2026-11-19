import Foundation
import PRBarCore

enum ModelsTests {
    static let cases: [TestCase] = [
        TestCase("models: categorías ordenadas por prioridad") {
            try expectEqual(PRCategory.allCases.shuffled().sorted(), [.toReview, .updatedSinceMyReview, .myFeedback, .readyToMerge, .other])
            try expect(PRCategory.toReview.countsForBadge)
            try expect(PRCategory.myFeedback.countsForBadge)
            try expect(!PRCategory.other.countsForBadge)
        },
        TestCase("models: id del PR es owner/repo#número") {
            try expectEqual(makePR(number: 42).id, "o/r#42")
        },
        TestCase("models: ClassifiedPR sobrevive un round-trip JSON") {
            let item = ClassifiedPR(pr: makePR(reviews: [review("ana", .approved, at: 5)]), category: .toReview, account: "me")
            let data = try JSONCoding.encoder.encode(item)
            try expectEqual(try JSONCoding.decoder.decode(ClassifiedPR.self, from: data), item)
        },
        TestCase("models: PRBarError tiene mensajes en español") {
            try expect(PRBarError.unauthorized.localizedDescription.contains("gh auth login"))
            try expect(PRBarError.toolNotFound("claude").localizedDescription.contains("claude"))
        },
    ]
}
