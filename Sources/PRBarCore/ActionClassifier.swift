import Foundation

public struct FeedbackSummary: Equatable, Sendable {
    public let changesRequested: Bool
    public let count: Int

    public init(changesRequested: Bool, count: Int) {
        self.changesRequested = changesRequested
        self.count = count
    }

    public var isEmpty: Bool { count == 0 }
}

public enum ActionClassifier {
    /// Devuelve la categoría del PR para la cuenta `me`, o `nil` si el PR no es relevante (spec §7).
    public static func classify(_ pr: PullRequest, me: String, watchedUsers: Set<String>) -> PRCategory? {
        let me = me.lowercased()
        let author = pr.author.lowercased()

        if author == me {
            return newFeedback(pr, me: me).isEmpty ? .other : .myFeedback
        }

        let watched = Set(watchedUsers.map { $0.lowercased() })
        let requested = pr.requestedReviewers.contains { $0.lowercased() == me }
        guard watched.contains(author) || requested else { return nil }

        if pr.isDraft { return .other }
        if requested { return .toReview }

        let myReviews = pr.reviews.filter {
            $0.author.lowercased() == me && [.approved, .changesRequested, .commented].contains($0.state)
        }
        guard let last = myReviews.max(by: { $0.submittedAt < $1.submittedAt }) else {
            return .toReview
        }
        if last.state != .approved && pr.lastCommitAt > last.submittedAt {
            return .updatedSinceMyReview
        }
        return .other
    }

    /// Reviews (cambios pedidos o comentarios) y comentarios de otras personas posteriores al último commit.
    public static func newFeedback(_ pr: PullRequest, me: String) -> FeedbackSummary {
        let me = me.lowercased()
        let reviews = pr.reviews.filter {
            !$0.isBot && $0.author.lowercased() != me
                && ($0.state == .changesRequested || $0.state == .commented)
                && $0.submittedAt > pr.lastCommitAt
        }
        let comments = pr.comments.filter {
            !$0.isBot && $0.author.lowercased() != me && $0.createdAt > pr.lastCommitAt
        }
        return FeedbackSummary(
            changesRequested: reviews.contains { $0.state == .changesRequested },
            count: reviews.count + comments.count
        )
    }
}
