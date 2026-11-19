import PRBarCore

enum ReviewSummaryTextTests {
    static let cases: [TestCase] = [
        TestCase("review summary: the approve-with-comments menu item reflects what will be posted") {
            try expectEqual(ReviewSummaryText.approveWithCommentsItem(inline: 0, hasGeneral: false), "Approve…")
            try expectEqual(ReviewSummaryText.approveWithCommentsItem(inline: 1, hasGeneral: false), "Approve with 1 Comment…")
            try expectEqual(ReviewSummaryText.approveWithCommentsItem(inline: 0, hasGeneral: true), "Approve with 1 Comment…")
            try expectEqual(ReviewSummaryText.approveWithCommentsItem(inline: 2, hasGeneral: false), "Approve with 2 Comments…")
            try expectEqual(ReviewSummaryText.approveWithCommentsItem(inline: 2, hasGeneral: true), "Approve with 3 Comments…")
        },
        TestCase("review summary: the approval message is precise") {
            func message(_ inline: Int, _ general: Bool) -> String {
                ReviewSummaryText.approval(repo: "r", number: 123, account: "dev-sam", inline: inline, hasGeneral: general)
            }
            try expectEqual(message(3, true), "Approve r#123 as @dev-sam with 3 inline comments and a general comment?")
            try expectEqual(message(1, false), "Approve r#123 as @dev-sam with 1 inline comment?")
            try expectEqual(message(1, true), "Approve r#123 as @dev-sam with 1 inline comment and a general comment?")
            try expectEqual(message(0, true), "Approve r#123 as @dev-sam with a general comment?")
            try expectEqual(message(0, false), "Approve r#123 as @dev-sam with no comments?")
        },
    ]
}
