import Foundation

/// The fixes' editable templates (spec E.5).
public enum FixTemplateKind: CaseIterable, Sendable {
    /// The commit's message (single commit, or one per comment).
    case commitMessage
    /// What replaces "Fixed in <commit>." in the replies.
    case reply

    public var variables: [PromptVariable] {
        switch self {
        case .commitMessage: [FixTemplates.n, FixTemplates.pr, FixTemplates.title, FixTemplates.comment]
        case .reply: [FixTemplates.commit, FixTemplates.summary, FixTemplates.pr, FixTemplates.title, FixTemplates.comment]
        }
    }

    /// What an empty template means; also the field's placeholder.
    public var placeholder: String {
        switch self {
        case .commitMessage: RespondOptions.defaultCommitMessageTemplate
        case .reply: "Fixed in {commit}."
        }
    }
}

public enum FixTemplates {
    public static let n = PromptVariable(name: "n", summary: "Number of comments addressed")
    public static let pr = PromptVariable(name: "pr", summary: "PR number, e.g. #42")
    public static let title = PromptVariable(name: "title", summary: "PR title")
    public static let comment = PromptVariable(name: "comment", summary: "First line of the comment")
    public static let commit = PromptVariable(name: "commit", summary: "Link to the fix’s commit")
    public static let summary = PromptVariable(name: "summary", summary: "What the fix did, in one line")
    static let maxCommentLength = 100

    /// The values of the variables. `item` gives `{comment}` (empty without one: a single commit covers several
    /// comments); `commit` (a sha) gives `{commit}` as a link.
    public static func values(draft: RespondDraft, item: RespondItem?, count: Int, commit: String? = nil,
                              summary: String? = nil) -> [String: String] {
        var values = ["n": "\(count)", "pr": "#\(draft.number)", "title": draft.title]
        values["comment"] = item.map { firstLine($0.feedback.comments.first?.body ?? "") } ?? ""
        if let commit { values["commit"] = "https://github.com/\(draft.repo.owner)/\(draft.repo.name)/commit/\(commit)" }
        if let summary { values["summary"] = summary }
        return values
    }

    /// The first non-empty line, trimmed, up to 100 characters (then "…").
    public static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > maxCommentLength ? String(line.prefix(maxCommentLength)) + "…" : line
    }

    /// What Settings warns about a template: `{comment}` in the commit message of a single commit, where it's empty.
    public static func warning(_ template: String, kind: FixTemplateKind, commitMode: CommitMode) -> String? {
        guard kind == .commitMessage, commitMode == .single,
              PlaceholderTemplate.names(in: template).contains(comment.name) else { return nil }
        return "With a single commit, {comment} is empty: the commit covers several comments."
    }

    /// The template with sample values, for Settings. Empty = what PRBar does without one.
    public static func preview(_ template: String, kind: FixTemplateKind) -> String {
        let sample = ["n": "2", "pr": "#123", "title": "Fix login redirect", "comment": "Validate returnTo before redirecting",
                      "commit": "https://github.com/acme/web/commit/1a2b3c4", "summary": "Validated returnTo against the allowed hosts"]
        let text = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else { return PlaceholderTemplate.render(text, values: sample) }
        let fallback = PlaceholderTemplate.render(kind.placeholder, values: sample)
        return kind == .commitMessage ? "One per comment: Claude’s message. Single commit: \(fallback)" : fallback
    }
}
