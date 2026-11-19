import Foundation

/// Decide si un mensaje de Slack contiene el link de un PR (spec §17.2, punto 1).
///
/// Se buscan referencias `host/owner/repo/pull/N` en el `text` (los links de Slack `<url|texto>` y `<url>`
/// incluidos) y en las URLs de attachments y blocks. Da igual http o https, `www.`, mayúsculas en owner y repo,
/// barra final, sufijos como `/files`, `/commits` o `/checks` y fragmentos `#…`. El número tiene que terminar
/// ahí: `pull/12` no matchea `pull/123`.
public enum PRLinkMatcher {
    public static func matches(_ message: SlackMessage, prURL: URL) -> Bool {
        guard let target = PullReference(url: prURL), let regex = target.regex else { return false }
        return ([message.text] + message.linkedURLs).contains { candidate in
            let range = NSRange(candidate.startIndex..., in: candidate)
            return regex.matches(in: candidate, range: range).contains { match in
                guard let owner = Range(match.range(at: 1), in: candidate),
                      let repo = Range(match.range(at: 2), in: candidate),
                      let number = Range(match.range(at: 3), in: candidate)
                else { return false }
                return candidate[owner].lowercased() == target.owner
                    && candidate[repo].lowercased() == target.repo
                    && Int(candidate[number]) == target.number
            }
        }
    }

    private struct PullReference {
        let host: String
        let owner: String
        let repo: String
        let number: Int

        init?(url: URL) {
            let parts = url.path.split(separator: "/").map(String.init)
            guard let rawHost = url.host?.lowercased(), parts.count >= 4, parts[2] == "pull", let number = Int(parts[3])
            else { return nil }
            host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
            owner = parts[0].lowercased()
            repo = parts[1].lowercased()
            self.number = number
        }

        /// `(https?://)?(www.)?host/owner/repo/pull/N`, sin otro dígito después de N.
        var regex: NSRegularExpression? {
            let pattern = #"(?:https?://)?(?:www\.)?"# + NSRegularExpression.escapedPattern(for: host)
                + #"/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)(?!\d)"#
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }
}

/// Resultado de `ReviewRounds.compute`.
public struct ReviewRoundsSummary: Equatable, Sendable {
    /// Rondas de comentarios: commits distintos sobre los que dejé reviews COMMENTED/CHANGES_REQUESTED.
    public var commentRounds: Int
    public var approved: Bool
    /// Mi primera review (de cualquier tipo) desde `since`.
    public var firstReviewAt: Date?

    public init(commentRounds: Int, approved: Bool, firstReviewAt: Date?) {
        self.commentRounds = commentRounds
        self.approved = approved
        self.firstReviewAt = firstReviewAt
    }
}

/// Cuenta mis rondas de review en un PR ajeno (spec §17.2, puntos 3–5).
public enum ReviewRounds {
    /// Una ronda es un `commitOID` distinto entre mis reviews COMMENTED o CHANGES_REQUESTED con
    /// `submittedAt >= since` (responder varios hilos sobre el mismo commit no suma). Una review sin
    /// `commitOID` cuenta como ronda propia. Las reviews anteriores a `since` no cuentan para nada.
    public static func compute(reviews: [PRReview], me: String, since: Date) -> ReviewRoundsSummary {
        let mine = reviews
            .filter { !$0.isBot && $0.author.lowercased() == me.lowercased() && $0.submittedAt >= since && $0.state != .pending }
            .sorted { $0.submittedAt < $1.submittedAt }
        var commits: Set<String> = []
        var rounds = 0
        for review in mine where review.state == .commented || review.state == .changesRequested {
            if let oid = review.commitOID {
                if commits.insert(oid).inserted { rounds += 1 }
            } else {
                rounds += 1
            }
        }
        return ReviewRoundsSummary(
            commentRounds: rounds,
            approved: mine.contains { $0.state == .approved },
            firstReviewAt: mine.first?.submittedAt
        )
    }
}
