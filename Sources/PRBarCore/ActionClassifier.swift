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
            // Ready to Merge es lo que queda cuando ya no hay nada que responder (spec F.1).
            if !newFeedback(pr, me: me).isEmpty { return .myFeedback }
            return isReadyToMerge(pr, me: me) ? .readyToMerge : .other
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

    /// Mi PR está aprobado, no es draft y no tiene conflictos (spec F.1). El CI no cuenta: se ve en la fila.
    /// Una mergeabilidad todavía desconocida (`UNKNOWN`) no lo saca: el botón dice "Checking…".
    public static func isReadyToMerge(_ pr: PullRequest, me: String) -> Bool {
        guard !pr.isDraft, pr.merge.mergeable != .conflicting, pr.merge.status != .dirty else { return false }
        switch pr.reviewDecision {
        case .approved: return true
        case .none: return hasCurrentApproval(pr, me: me.lowercased())
        case .changesRequested, .reviewRequired: return false
        }
    }

    /// Sin `reviewDecision` (el repo no exige reviews): la última review de cada persona entre aprobar, pedir cambios
    /// y descartada. Hace falta al menos una aprobación vigente y ningún pedido de cambios vigente.
    static func hasCurrentApproval(_ pr: PullRequest, me: String) -> Bool {
        var latest: [String: PRReview] = [:]
        for review in pr.reviews where review.author.lowercased() != me
            && [.approved, .changesRequested, .dismissed].contains(review.state) {
            let key = review.author.lowercased()
            if let current = latest[key], current.submittedAt >= review.submittedAt { continue }
            latest[key] = review
        }
        let states = latest.values.map(\.state)
        return states.contains(.approved) && !states.contains(.changesRequested)
    }
}
