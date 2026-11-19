import Foundation
import PRBarCore

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func at(_ minutes: Int) -> Date {
    t0.addingTimeInterval(TimeInterval(minutes * 60))
}

func review(_ author: String, _ state: ReviewState, at minutes: Int, bot: Bool = false, commit: String? = nil) -> PRReview {
    PRReview(author: author, isBot: bot, state: state, submittedAt: at(minutes), commitOID: commit)
}

func comment(_ author: String, at minutes: Int, bot: Bool = false) -> PRComment {
    PRComment(author: author, isBot: bot, createdAt: at(minutes))
}

func makePR(
    repo: RepoRef = RepoRef(owner: "o", name: "r"),
    number: Int = 1,
    author: String = "juan",
    isDraft: Bool = false,
    base: String = "develop",
    lastCommit: Int = 0,
    head: String? = nil,
    ci: CIState = .success,
    decision: ReviewDecision = .none,
    reviews: [PRReview] = [],
    comments: [PRComment] = [],
    requested: [String] = [],
    updated: Int = 0
) -> PullRequest {
    PullRequest(
        repo: repo, number: number, title: "PR \(number)",
        url: URL(string: "https://github.com/\(repo.fullName)/pull/\(number)")!,
        isDraft: isDraft, author: author, authorAvatarURL: nil,
        baseRef: base, headRef: "feature/\(number)", headOid: head ?? "abc\(number)",
        additions: 10, deletions: 2,
        createdAt: at(-60), updatedAt: at(updated), lastCommitAt: at(lastCommit),
        ciState: ci, reviewDecision: decision,
        reviews: reviews, comments: comments, requestedReviewers: requested
    )
}
