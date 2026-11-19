import Foundation

/// Una variable que se puede usar en una plantilla de Slack.
public struct SlackTemplateVariable: Hashable, Sendable {
    /// Nombre sin llaves, como lo entiende `SlackTemplate.render`.
    public let name: String
    public let summary: String

    /// Lo que se inserta en el texto: `{name}`.
    public var token: String { "{\(name)}" }

    public static let link = SlackTemplateVariable(name: "link", summary: "PR link")
    public static let title = SlackTemplateVariable(name: "title", summary: "PR title")
    public static let number = SlackTemplateVariable(name: "number", summary: "PR number")
    public static let repo = SlackTemplateVariable(name: "repo", summary: "Repository name")
    public static let author = SlackTemplateVariable(name: "author", summary: "PR author")
    public static let round = SlackTemplateVariable(name: "n", summary: "Round number")
    public static let method = SlackTemplateVariable(name: "method", summary: "Merge method (squash, merge or rebase)")
}

/// Las plantillas editables de la pestaña Slack.
public enum SlackTemplateKind: CaseIterable, Sendable {
    case newPR, update, round, merged

    public var keyPath: WritableKeyPath<SlackSettings, String> {
        switch self {
        case .newPR: \.newPRTemplate
        case .update: \.updateTemplate
        case .round: \.roundTemplate
        case .merged: \.mergedTemplate
        }
    }

    public var defaultTemplate: String {
        switch self {
        case .newPR: SlackSettings.defaultNewPRTemplate
        case .update: SlackSettings.defaultUpdateTemplate
        case .round: SlackSettings.defaultRoundTemplate
        case .merged: SlackSettings.defaultMergedTemplate
        }
    }

    /// Variables disponibles; `{n}` solo en el mensaje de ronda y `{method}` solo en "Merged".
    public var variables: [SlackTemplateVariable] {
        let common: [SlackTemplateVariable] = [.link, .title, .number, .repo, .author]
        switch self {
        case .round: return common + [.round]
        case .merged: return common + [.method]
        case .newPR, .update: return common
        }
    }

    /// Ronda con la que se previsualiza el mensaje de ronda (la segunda: «commented x2»).
    public var sampleRound: Int? { self == .round ? 2 : nil }

    /// Método con el que se previsualiza "Merged".
    public var sampleMethod: String? { self == .merged ? MergeMethod.squash.rawValue : nil }

    public func isDefault(_ template: String) -> Bool { template == defaultTemplate }

    /// Lo que se manda de verdad: una plantilla vacía (o solo espacios) cae en la de por defecto.
    public func effective(_ template: String) -> String {
        SlackSettings.nonEmpty(template) ?? defaultTemplate
    }
}

/// Vista previa de una plantilla con un PR de ejemplo, sin tocar GitHub ni Slack.
public enum SlackTemplatePreview {
    public static let fallbackAuthor = "you"

    /// PR de ejemplo `acme/web#123`; el autor es el login de la cuenta conectada, o «you».
    public static func sample(author: String? = nil) -> PullRequest {
        let login = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let now = Date(timeIntervalSince1970: 0)
        return PullRequest(
            repo: RepoRef(owner: "acme", name: "web"), number: 123, title: "Fix login redirect",
            url: URL(string: "https://github.com/acme/web/pull/123")!, isDraft: false,
            author: login.isEmpty ? fallbackAuthor : login, authorAvatarURL: nil,
            baseRef: "main", headRef: "fix-login-redirect", headOid: "0000000",
            additions: 12, deletions: 3, createdAt: now, updatedAt: now, lastCommitAt: now,
            ciState: .success, reviewDecision: .none, reviews: [], comments: [], requestedReviewers: []
        )
    }

    /// El texto tal como lo mandaría PRBar (con la plantilla por defecto si está vacía), en texto plano.
    public static func text(_ template: String, kind: SlackTemplateKind, author: String? = nil) -> String {
        let rendered = SlackTemplate.render(
            kind.effective(template), pr: sample(author: author), n: kind.sampleRound, method: kind.sampleMethod
        )
        return plainText(fromSlack: rendered)
    }

    /// mrkdwn de Slack a texto plano: `<url|texto>` → `texto`, `<url>` → `url`, `<@U1>` → `@U1`,
    /// `<#C1|general>` → `#general`, y `&amp; &lt; &gt;` → `& < >`.
    public static func plainText(fromSlack text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: ">"),
                  !rest[afterOpen..<close].contains("<") else {
                result += "<"
                rest = rest[afterOpen...]
                continue
            }
            let inner = rest[afterOpen..<close]
            let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = String(parts[0])
            let label = parts.count > 1 ? String(parts[1]) : ""
            if let prefix = target.first, "@#".contains(prefix) {
                result += label.isEmpty ? target : "\(prefix)\(label)"
            } else {
                result += label.isEmpty ? target : label
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
