import Foundation

/// Spec RM.5: PRBar's decision, deterministic, over what will be posted (the findings selected in the window, which starts
/// with those the filter kept and the settings don't hide; decision 10) and what Claude said about the previous comments.
extension RecommendedAction {
    public static func compute(previous: [PreviousCommentStatus], findings: [ReviewFinding]) -> RecommendedAction {
        let pending = previous.contains { $0.status == .notFixed || $0.status == .partially }
        let unclear = previous.contains { $0.status == .unclear }
        let high = findings.contains { $0.severity == .high }
        let event: ReviewEvent = if pending || high {
            .requestChanges
        } else if unclear || !findings.isEmpty {
            .comment
        } else {
            .approve
        }
        return RecommendedAction(event: event, reason: reason(previous: previous, findings: findings))
    }

    /// Live (the window recomputes it on every change): the draft's previous comments and the findings selected now.
    public static func of(_ draft: ReviewDraft, edits: ReviewEdits) -> RecommendedAction {
        compute(previous: draft.previous, findings: edits.selectedComments(of: draft).map(\.finding))
    }

    /// "2 previous comments fixed, 1 not fixed: a.swift:12; 1 new high finding".
    static func reason(previous: [PreviousCommentStatus], findings: [ReviewFinding]) -> String {
        let groups: [(status: PreviousStatus, label: String, lists: Bool)] = [
            (.fixed, "fixed", false), (.notFixed, "not fixed", true), (.partially, "partially fixed", true), (.unclear, "unclear", true),
        ]
        var previousParts: [String] = []
        for group in groups {
            let matching = previous.filter { $0.status == group.status }
            guard !matching.isEmpty else { continue }
            let noun = previousParts.isEmpty ? " previous comment\(matching.count == 1 ? "" : "s")" : ""
            previousParts.append("\(matching.count)\(noun) \(group.label)" + (group.lists ? ": " + locations(matching) : ""))
        }
        var parts: [String] = []
        if !previousParts.isEmpty { parts.append(previousParts.joined(separator: ", ")) }
        let high = findings.filter { $0.severity == .high }.count
        let others = findings.count - high
        if high > 0 { parts.append("\(high) new high finding\(high == 1 ? "" : "s")") }
        if others > 0 { parts.append("\(others) new \(high > 0 ? "other " : "")finding\(others == 1 ? "" : "s")") }
        return parts.isEmpty ? "No findings to post" : parts.joined(separator: "; ")
    }

    static func locations(_ comments: [PreviousCommentStatus]) -> String {
        let shown = comments.prefix(3).map(\.location).joined(separator: ", ")
        return comments.count > 3 ? "\(shown) and \(comments.count - 3) more" : shown
    }
}

extension PreviousCommentStatus {
    /// "open", "resolved · outdated", "unknown".
    public var githubLabel: String {
        github == .unknown ? "unknown" : outdated ? "\(github.rawValue) · outdated" : github.rawValue
    }
}

extension ReviewDraft {
    /// Spec RM.6: "Reviewed before at 1a2b3c4 · 2 fixed · 1 pending"; nil without previous comments. Pending = all that
    /// isn't fixed (decision 13).
    public var previousHeader: String? {
        guard !previous.isEmpty else { return nil }
        let fixed = previous.filter { $0.status == .fixed }.count
        let at = reviewedSince.map { " at \($0.prefix(7))" } ?? ""
        return "Reviewed before\(at) · \(fixed) fixed · \(previous.count - fixed) pending"
    }
}
