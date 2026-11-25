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
            // Ready to Merge es lo que queda cuando ya no hay nada que responder (spec F.1). Para decidirlo no cuenta
            // el feedback ya cerrado por una aprobación posterior o por mi respuesta (spec F.8.18).
            if isReadyToMerge(pr, me: me) && feedbackBlockingMerge(pr, me: me).isEmpty { return .readyToMerge }
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
        let (reviews, comments) = feedback(pr, me: me.lowercased())
        return summary(reviews: reviews, comments: comments)
    }

    /// La fecha del último feedback de otra persona (no bot): review con cambios pedidos o comentarios, o comentario
    /// general. Decide si una corrida de Respond terminada quedó vieja (`RespondQueue.finishedRunsWithNewFeedback`).
    public static func latestFeedbackAt(_ pr: PullRequest, me: String) -> Date? {
        let me = me.lowercased()
        let reviews = pr.reviews.filter {
            !$0.isBot && $0.author.lowercased() != me && ($0.state == .changesRequested || $0.state == .commented)
        }.map(\.submittedAt)
        let comments = pr.comments.filter { !$0.isBot && $0.author.lowercased() != me }.map(\.createdAt)
        return (reviews + comments).max()
    }

    /// El feedback nuevo que todavía impide Ready to Merge (spec F.8.18): sin lo de quien aprobó después (su última
    /// aprobación es posterior) ni los comentarios que ya respondí con un comentario mío posterior. Solo decide
    /// Ready to Merge: My PRs with Feedback sigue usando `newFeedback`.
    public static func feedbackBlockingMerge(_ pr: PullRequest, me: String) -> FeedbackSummary {
        let me = me.lowercased()
        var lastApproval: [String: Date] = [:]
        for review in pr.reviews where review.state == .approved {
            let key = review.author.lowercased()
            lastApproval[key] = max(lastApproval[key] ?? .distantPast, review.submittedAt)
        }
        let lastMine = pr.comments.filter { $0.author.lowercased() == me }.map(\.createdAt).max()
        func approvedLater(_ author: String, than date: Date) -> Bool {
            lastApproval[author.lowercased()].map { $0 > date } ?? false
        }
        let (reviews, comments) = feedback(pr, me: me)
        return summary(
            reviews: reviews.filter { !approvedLater($0.author, than: $0.submittedAt) },
            comments: comments.filter { comment in
                !approvedLater(comment.author, than: comment.createdAt) && !(lastMine.map { $0 > comment.createdAt } ?? false)
            }
        )
    }

    private static func feedback(_ pr: PullRequest, me: String) -> (reviews: [PRReview], comments: [PRComment]) {
        let reviews = pr.reviews.filter {
            !$0.isBot && $0.author.lowercased() != me
                && ($0.state == .changesRequested || $0.state == .commented)
                && $0.submittedAt > pr.lastCommitAt
        }
        let comments = pr.comments.filter {
            !$0.isBot && $0.author.lowercased() != me && $0.createdAt > pr.lastCommitAt
        }
        return (reviews, comments)
    }

    private static func summary(reviews: [PRReview], comments: [PRComment]) -> FeedbackSummary {
        FeedbackSummary(changesRequested: reviews.contains { $0.state == .changesRequested }, count: reviews.count + comments.count)
    }

    /// Mi PR está aprobado y no es draft (spec F.1). El CI no cuenta: se ve en la fila. Los conflictos tampoco
    /// (spec F.1.1): el PR queda en Ready to Merge con el botón deshabilitado y "This branch has conflicts", así no se
    /// pierde en Waiting for Review. Una mergeabilidad todavía desconocida (`UNKNOWN`) no lo saca: el botón dice "Checking…".
    public static func isReadyToMerge(_ pr: PullRequest, me: String) -> Bool {
        guard !pr.isDraft else { return false }
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
