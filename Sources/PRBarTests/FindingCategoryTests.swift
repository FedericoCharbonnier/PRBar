import Foundation
import PRBarCore

private func finding(_ id: String, category: FindingCategory = .docs) -> ReviewFinding {
    ReviewFinding(id: id, severity: .low, file: "a.ts", line: 1, title: id, body: "B", category: category)
}

private func draft(_ items: [ReviewItem]) -> ReviewDraft {
    ReviewDraft(prID: "P", repo: RepoRef(owner: "o", name: "r"), number: 1, title: "T",
                url: URL(string: "https://github.com/o/r/pull/1")!, author: "a", headOid: "h", account: "me",
                summary: "S", items: items)
}

enum FindingCategoryTests {
    static let cases: [TestCase] = [
        TestCase("finding category: falta o desconocida → other; se conserva al codificar") {
            let old = #"{"id":"f1","severity":"low","file":"a.ts","line":null,"title":"T","body":"B"}"#
            try expectEqual(try JSONCoding.decoder.decode(ReviewFinding.self, from: Data(old.utf8)).category, .other)
            let weird = #"{"id":"f1","severity":"low","file":"a.ts","line":3,"title":"T","body":"B","category":"vibes"}"#
            try expectEqual(try JSONCoding.decoder.decode(ReviewFinding.self, from: Data(weird.utf8)).category, .other)
            let styled = finding("f2", category: .style)
            try expectEqual(try JSONCoding.decoder.decode(ReviewFinding.self, from: JSONCoding.encoder.encode(styled)), styled)
        },
        TestCase("finding category: el esquema de la etapa 1 la pide") {
            try expect(ReviewSchemas.stageOne.contains(
                #""category":{"type":"string","enum":["bug","security","performance","tests","style","docs","other"]}"#))
            try expect(ReviewSchemas.stageOne.contains(#""required":["id","severity","category","file","line","title","body"]"#))
        },
        TestCase("review item: hiddenBy falta en registros viejos; los ocultos no cuentan ni arrancan elegidos") {
            let json = #"{"finding":{"id":"f1","severity":"low","file":"a.ts","line":null,"title":"T","body":"B"},"keep":true,"reason":null}"#
            try expectEqual(try JSONCoding.decoder.decode(ReviewItem.self, from: Data(json.utf8)).hiddenBy, nil)
            let review = draft([ReviewItem(finding: finding("f1"), keep: true, reason: nil),
                                ReviewItem(finding: finding("f2"), keep: true, reason: nil, hiddenBy: "Category off: docs"),
                                ReviewItem(finding: finding("f3"), keep: false, reason: "dup")])
            try expectEqual(review.keptCount, 1)
            var edits = ReviewEdits.initial(for: review)
            try expectEqual(edits.selected, ["f1"])
            edits.titles["f2"] = "Renamed"
            let f2 = edits.items(of: review)[1]
            try expectEqual(f2.finding.title, "Renamed")
            try expectEqual(f2.finding.category, .docs)
            try expectEqual(f2.hiddenBy, "Category off: docs")
            try expect(f2.isHidden)
        },
        TestCase("review edits: userDiscarded son los mantenidos y visibles que no se publican") {
            let review = draft([ReviewItem(finding: finding("f1"), keep: true, reason: nil),
                                ReviewItem(finding: finding("f2"), keep: true, reason: nil),
                                ReviewItem(finding: finding("f3"), keep: true, reason: nil, hiddenBy: "x"),
                                ReviewItem(finding: finding("f4"), keep: false, reason: "dup")])
            var edits = ReviewEdits.initial(for: review)
            edits.selected = ["f1", "f4"]
            try expectEqual(edits.userDiscarded(of: review).map(\.id), ["f2"])
        },
    ]
}
