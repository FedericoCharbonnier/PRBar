import Foundation
import PRBarWire

// The topics the Mac pushes (spec P.6) are PRBarWire's `RemoteHome`, `RemotePRDetail` and `RemoteActivity`, the same
// types the Mac's `RemoteStateFeed` encodes. Their optional fields (display names, approvals, file counts, failed
// checks, durations, log excerpts, test summaries, the Mac's totals, running jobs, the Slack channel) are what the
// design shows beyond the commands (spec R.7): when a Mac doesn't send one, the UI keeps its fallback.

public enum Topic {
    public static let home = "home"
    public static let activity = "activity"
    public static func pr(_ id: String) -> String { "pr:\(id)" }
}

public extension RemoteHome {
    /// The author's display name ("Laura Méndez") when any of the Mac's PRs carries it, else the login.
    func displayName(_ login: String) -> String {
        prs.first { $0.author == login && $0.authorName != nil }?.authorName ?? login
    }
}
