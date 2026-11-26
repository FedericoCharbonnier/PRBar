import Foundation

/// What Claude says about a comment PRBar posted in an earlier review of the PR (spec RM.4). Lenient: an unknown value
/// is `unclear`.
public enum PreviousStatus: String, Codable, Sendable, CaseIterable {
    case fixed, notFixed, partially, unclear

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PreviousStatus(rawValue: raw) ?? .unclear
    }

    public var title: String {
        switch self {
        case .fixed: "Fixed"
        case .notFixed: "Not fixed"
        case .partially: "Partially"
        case .unclear: "Unclear"
        }
    }
}

/// The comment's thread on GitHub when the review started (spec RM.3.1). `unknown`: no thread matched (deleted, an old
/// review without its URL) or the query failed. Lenient like `PreviousStatus`.
public enum GitHubThreadState: String, Codable, Sendable {
    case resolved, open, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GitHubThreadState(rawValue: raw) ?? .unknown
    }
}

/// A previous comment as the CLI and the phone see it (spec RM.6).
public struct PreviousCommentInfo: Codable, Equatable, Sendable {
    /// `P1`, `P2`…
    public var id: String
    /// `src/a.swift:12`.
    public var location: String
    /// The text PRBar posted.
    public var text: String
    public var status: PreviousStatus
    public var note: String
    public var github: GitHubThreadState
    public var outdated: Bool

    public init(id: String, location: String, text: String, status: PreviousStatus, note: String, github: GitHubThreadState,
                outdated: Bool) {
        self.id = id
        self.location = location
        self.text = text
        self.status = status
        self.note = note
        self.github = github
        self.outdated = outdated
    }
}

/// PRBar's recommended decision and why (spec RM.5). Computed by PRBar, never by Claude.
public struct RecommendedAction: Codable, Equatable, Sendable {
    public var event: ReviewEvent
    /// "2 previous comments fixed, 1 not fixed: a.swift:12; 1 new high finding".
    public var reason: String

    public init(event: ReviewEvent, reason: String) {
        self.event = event
        self.reason = reason
    }
}

extension ReviewEvent {
    /// The name the Review window and the CLI show.
    public var title: String {
        switch self {
        case .approve: "Approve"
        case .comment: "Comment"
        case .requestChanges: "Request Changes"
        }
    }
}
