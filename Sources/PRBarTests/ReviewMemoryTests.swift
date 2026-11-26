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
        TestCase("carpeta del PR: nombre y refs fijos; la reconocen la limpieza y Clean Up") {
            try expectEqual(WorktreeManager.reviewFolderName(repo: RepoRef(owner: "o", name: "my/repo"), number: 7), "my_repo-7-review")
            try expect(WorktreeManager.isReviewFolderName("my-repo-12-review"))
            try expect(WorktreeManager.isReviewFolderName("r-7-review.context"))
            try expect(!WorktreeManager.isReviewFolderName("r-review"))
            try expect(!WorktreeManager.isReviewFolderName("r-7-review-diff"))
            try expect(!WorktreeManager.isReviewFolderName("r-7-1700000000-0a0a0a0a"))
            try expect(WorktreeManager.isWorkspaceName("r-7-review"))
            try expect(WorktreeManager.isWorkspaceName("r-7-review.context"))
            try expectEqual(WorktreeManager.reviewRefs(forWorkspaceName: "my-repo-12-review"),
                            ["refs/prbar/pr-12-review", "refs/prbar/base-12-review"])
            try expectEqual(WorktreeManager.reviewRefs(forWorkspaceName: "r-7-review.context"), [])
            // The old names keep working.
            try expectEqual(WorktreeManager.reviewRefs(forWorkspaceName: "r-7-1700000000-0a0a0a0a"),
                            ["refs/prbar/pr-7-0a0a0a0a", "refs/prbar/base-7-0a0a0a0a"])
            let location = WorktreeLocation(directory: "/wt/r-7-review", runner: nil, repository: "/repos/r",
                                            refs: WorktreeManager.reviewRefs(forWorkspaceName: "r-7-review"))
            try expectEqual(location.reviewWorkspace.prRef, "refs/prbar/pr-7-review")
            try expectEqual(location.reviewWorkspace.baseRef, "refs/prbar/base-7-review")
            let perPR = ReviewWorkspace(directory: URL(fileURLWithPath: "/wt/r-7-review"), baseRef: "b", prRef: "p", isDiffOnly: false)
            let perRun = ReviewWorkspace(directory: URL(fileURLWithPath: "/wt/r-7-1700000000-0a0a0a0a"), baseRef: "b", isDiffOnly: false)
            try expect(WorktreeManager.isReviewFolder(perPR) && !WorktreeManager.isReviewFolder(perRun))
        },
    ]
}
