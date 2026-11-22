import Foundation

public struct ReviewSubmission: Equatable, Sendable {
    public struct InlineComment: Equatable, Sendable {
        public let path: String
        public let line: Int
        public let body: String

        public init(path: String, line: Int, body: String) {
            self.path = path
            self.line = line
            self.body = body
        }
    }
    public let commitID: String
    public let event: ReviewEvent
    public let body: String
    public let comments: [InlineComment]

    public init(commitID: String, event: ReviewEvent, body: String, comments: [InlineComment]) {
        self.commitID = commitID
        self.event = event
        self.body = body
        self.comments = comments
    }
}

/// Un hallazgo elegido por el usuario, con el texto final (posiblemente editado).
public struct SelectedComment: Equatable, Sendable {
    public let finding: ReviewFinding
    public let body: String

    public init(finding: ReviewFinding, body: String) {
        self.finding = finding
        self.body = body
    }
}

public enum ReviewPublisher {
    /// `true` si GitHub rechazó la review con 422 y tenía comentarios inline: casi siempre es una línea que ya
    /// no está en el diff. Se ofrece reintentar con todo en el body (`build` con un `DiffLineMap` vacío).
    public static func canRetryInBody(after error: Error, submission: ReviewSubmission) -> Bool {
        guard case .http(422, _)? = error as? PRBarError else { return false }
        return !submission.comments.isEmpty
    }

    /// Arma la review. Los hallazgos cuya línea está en `lineMap` van inline; el resto, al body. Con un mapa
    /// vacío (`DiffLineMap(files: [])`) todo va al body, p. ej. si el PR cambió después de la review.
    public static func build(
        draft: ReviewDraft, selected: [SelectedComment], generalComment: String, event: ReviewEvent, lineMap: DiffLineMap
    ) throws -> ReviewSubmission {
        var inline: [ReviewSubmission.InlineComment] = []
        var unanchored: [String] = []
        for comment in selected {
            let text = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let path = DiffLineMap.normalizePath(comment.finding.file)
            if let line = comment.finding.line, lineMap.contains(file: path, line: line) {
                inline.append(.init(path: path, line: line, body: text))
            } else {
                unanchored.append(PublishedPhrases.unanchoredFinding(location: comment.finding.location, text: text))
            }
        }
        let body = ([generalComment.trimmingCharacters(in: .whitespacesAndNewlines)] + unanchored)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if event != .approve && body.isEmpty && inline.isEmpty {
            throw PRBarError.emptyReview
        }
        return ReviewSubmission(commitID: draft.headOid, event: event, body: body, comments: inline)
    }
}
