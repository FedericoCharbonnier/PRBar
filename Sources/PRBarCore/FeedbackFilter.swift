import Foundation

public enum FeedbackFilter {
    /// Hilos no resueltos cuyo último comentario no es mío ni de un bot. Cuerpos de review no vacíos de otras personas
    /// (no bots), con estado CHANGES_REQUESTED o COMMENTED y `submittedAt` posterior a `lastCommitAt`.
    /// Orden: hilos por fecha de su primer comentario, después reviews por `submittedAt`.
    public static func select(
        threads: [FeedbackItem],
        reviewBodies: [(item: FeedbackItem, state: ReviewState, submittedAt: Date)],
        me: String,
        lastCommitAt: Date
    ) -> [FeedbackItem] {
        let keptThreads = threads
            .filter { thread in
                guard !thread.isResolved, let last = thread.comments.last else { return false }
                return !last.isBot && !isMe(last.author, me)
            }
            .sorted { ($0.comments.first?.createdAt ?? .distantPast) < ($1.comments.first?.createdAt ?? .distantPast) }

        let keptReviews = reviewBodies
            .filter { entry in
                guard entry.state == .changesRequested || entry.state == .commented,
                      entry.submittedAt > lastCommitAt,
                      let comment = entry.item.comments.first else { return false }
                let hasText = !comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return hasText && !comment.isBot && !isMe(comment.author, me)
            }
            .sorted { $0.submittedAt < $1.submittedAt }
            .map(\.item)

        return keptThreads + keptReviews
    }

    /// Los logins de GitHub no distinguen mayúsculas.
    private static func isMe(_ author: String, _ me: String) -> Bool {
        author.caseInsensitiveCompare(me) == .orderedSame
    }
}
