import Foundation
import PRBarCore

let memorySHA1 = String(repeating: "1", count: 40)
let memorySHA2 = String(repeating: "2", count: 40)

enum ReviewMemoryTests {
    static let cases: [TestCase] = [
        TestCase("memoria wire: ReviewInfo suma previous, reviewedSince y recommendedAction opcionales; uno viejo decodifica igual") {
            let old = #"{"pr":"o/r#7","phase":"ready","outdated":false,"findings":[]}"#
            let decoded = try JSONDecoder().decode(ReviewInfo.self, from: Data(old.utf8))
            try expectEqual(decoded.previous, nil)
            try expectEqual(decoded.reviewedSince, nil)
            try expectEqual(decoded.recommendedAction, nil)
            let info = ReviewInfo(
                pr: "o/r#7", phase: "ready", outdated: false, findings: [],
                previous: [PreviousCommentInfo(id: "P1", location: "a.swift:3", text: "Validá el input.", status: .notFixed,
                                               note: "Sigue igual.", github: .open, outdated: false)],
                reviewedSince: memorySHA1, recommendedAction: RecommendedAction(event: .requestChanges, reason: "1 not fixed"))
            let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
            try expect(json.contains(#""status":"notFixed""#), json)
            try expect(json.contains(#""event":"REQUEST_CHANGES""#), json)
            try expectEqual(try JSONDecoder().decode(ReviewInfo.self, from: Data(json.utf8)), info)
            // Lenient: a newer value doesn't break an older PRBar.
            try expectEqual(try JSONDecoder().decode([PreviousStatus].self, from: Data(#"["someday","fixed"]"#.utf8)), [.unclear, .fixed])
            try expectEqual(try JSONDecoder().decode([GitHubThreadState].self, from: Data(#"["locked","resolved"]"#.utf8)), [.unknown, .resolved])
            try expectEqual(PreviousStatus.notFixed.title, "Not fixed")
            try expectEqual(ReviewEvent.requestChanges.title, "Request Changes")
        },
    ]
}
