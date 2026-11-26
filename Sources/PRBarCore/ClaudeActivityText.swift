import Foundation

/// Claude's step (spec LP.4): what each stream event says, for the step line. Claude's own text is never shown. What
/// Claude asked for (`detail`: paths, patterns, skill names) can come from the PR: one line, neutralized, cut to 80.
public enum ClaudeActivityText {
    public static let starting = "Claude is starting…"
    public static let thinking = "Thinking…"

    /// Where Claude works: paths are shown relative to these.
    public struct Folders: Equatable, Sendable {
        /// The worktree (Claude's cwd).
        public var working: URL?
        /// The context folder (`--add-dir`): its files are named by their role.
        public var context: URL?

        public init(working: URL?, context: URL? = nil) {
            self.working = working
            self.context = context
        }
    }

    /// The context files PRBar writes, by their role (spec LP.4; decision 19).
    static let roles: [String: String] = [
        "pr.diff": "the PR’s diff",
        "pr.md": "the PR’s description",
        "previous-reviews.md": "the previous reviews",
        "since-last-review.diff": "the changes since the last review",
        "feedback.json": "the comments",
    ]

    public static func text(for event: ClaudeStreamEvent, in folders: Folders) -> String? {
        switch event {
        case .agentStarted(let total):
            return total == 0 ? starting : "Running \(total) subagent\(total == 1 ? "" : "s")"
        case .text:
            return thinking
        case .toolUse(let rawName, let detail):
            let name = UntrustedText.singleLine(rawName, limit: 60)
            switch name {
            case "Read": return detail.map { "Reading \(path($0, in: folders))" } ?? "Reading files"
            case "Grep": return detail.map { "Searching for \(plain($0))" } ?? "Searching the code"
            case "Glob": return detail.map { "Searching for \(path($0, in: folders))" } ?? "Searching the code"
            case "Edit", "Write", "MultiEdit", "NotebookEdit": return detail.map { "Editing \(path($0, in: folders))" } ?? "Editing files"
            case "Bash": return "Running a command"
            case "Skill": return detail.map { "Using the \(plain($0)) skill" } ?? "Using a skill"
            case "Agent", "Task": return "Starting a subagent"
            default: return "Using \(name.isEmpty ? "a tool" : name)"
            }
        }
    }

    public static func activity(for event: ClaudeStreamEvent, in folders: Folders, at date: Date = Date()) -> JobActivity? {
        text(for: event, in: folders).map { JobActivity.claude($0, at: date) }
    }

    /// The `onEvent` of a Claude run (`ClaudeRunner.run(_:as:onEvent:)`) that sends each event as a step.
    public static func sink(_ folders: Folders, to onActivity: @escaping JobActivitySink) -> @Sendable (ClaudeStreamEvent) -> Void {
        { event in
            if let activity = activity(for: event, in: folders) { onActivity(activity) }
        }
    }

    /// Decision 20: inside the context folder → its role (or the path inside it); inside the worktree → relative; anywhere
    /// else → only its file name; a relative path as it is.
    static func path(_ raw: String, in folders: Folders) -> String {
        let text = UntrustedText.singleLine(raw, limit: 4096)
        guard text.hasPrefix("/") else { return JobStep.clip(text) }
        if let context = folders.context, let inside = relative(text, to: context) {
            return roles[inside] ?? JobStep.clip(inside)
        }
        if let working = folders.working, let inside = relative(text, to: working) {
            return JobStep.clip(inside)
        }
        return JobStep.clip((text as NSString).lastPathComponent)
    }

    static func plain(_ raw: String) -> String { JobStep.clip(UntrustedText.singleLine(raw, limit: 4096)) }

    /// `path` inside `root` (also through `/private` and symlinks, like `ChatActivity.relative`); nil if it isn't.
    static func relative(_ path: String, to root: URL) -> String? {
        let bases = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path, "/private" + root.standardizedFileURL.path]
        for base in bases where path.hasPrefix(base + "/") {
            let inside = String(path.dropFirst(base.count + 1))
            return inside.isEmpty ? nil : inside
        }
        return nil
    }
}
