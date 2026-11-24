import Foundation

public enum FeedbackFilter {
    /// Lo que Respond analiza y lo que la pestaña lista antes de empezar: los hilos, las reviews y los comentarios
    /// generales que piden respuesta (`select`).
    public static func select(_ feedback: PRFeedback, me: String) -> [FeedbackItem] {
        select(threads: feedback.threads,
               reviewBodies: feedback.reviews.map { ($0.item, $0.state, $0.submittedAt) },
               conversation: feedback.conversation,
               me: me, lastCommitAt: feedback.lastCommitAt)
    }

    /// Hilos no resueltos cuyo último comentario no es mío ni de un bot. Cuerpos de review no vacíos de otras personas
    /// (no bots), con estado CHANGES_REQUESTED o COMMENTED y `submittedAt` posterior a `lastCommitAt`.
    /// Comentarios generales del PR de otras personas (no bots), con texto, posteriores a `lastCommitAt` y sin un
    /// comentario general mío después (ya los respondí). `conversation` trae todos, también los míos.
    /// Orden: hilos por fecha de su primer comentario, después reviews por `submittedAt`, después comentarios generales
    /// por fecha.
    public static func select(
        threads: [FeedbackItem],
        reviewBodies: [(item: FeedbackItem, state: ReviewState, submittedAt: Date)],
        conversation: [FeedbackItem] = [],
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

        let myLast = conversation.compactMap(\.comments.first).filter { isMe($0.author, me) }.map(\.createdAt).max()
        let keptConversation = conversation
            .filter { item in
                guard let comment = item.comments.first else { return false }
                let hasText = !comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return hasText && !comment.isBot && !isMe(comment.author, me) && comment.createdAt > lastCommitAt
                    && !(myLast.map { $0 > comment.createdAt } ?? false)
            }
            .sorted { ($0.comments.first?.createdAt ?? .distantPast) < ($1.comments.first?.createdAt ?? .distantPast) }

        return keptThreads + keptReviews + keptConversation
    }

    /// Los logins de GitHub no distinguen mayúsculas.
    private static func isMe(_ author: String, _ me: String) -> Bool {
        author.caseInsensitiveCompare(me) == .orderedSame
    }
}
