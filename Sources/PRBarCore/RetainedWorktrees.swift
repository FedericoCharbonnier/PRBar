import Foundation

/// Where a kept folder lives and what removes it (spec T.3).
public struct WorktreeLocation: Codable, Equatable, Hashable, Sendable {
    /// The folder, on the machine where it is.
    public var directory: String
    /// `nil` = this Mac; otherwise the runner's name.
    public var runner: String?
    /// The repo the worktree hangs from: the user's clone on this Mac or PRBar's bare mirror on the runner. Nil for a
    /// diff-only review folder (not a git worktree).
    public var repository: String?
    /// PRBar's own refs of that run (`refs/prbar/…`), deleted with the folder.
    public var refs: [String]

    public init(directory: String, runner: String?, repository: String?, refs: [String]) {
        self.directory = directory
        self.runner = runner
        self.repository = repository
        self.refs = refs
    }
}
