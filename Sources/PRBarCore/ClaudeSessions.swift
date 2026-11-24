import Foundation
import os

/// A Claude Code session id and when PRBar heard of it (spec T.2).
public struct ClaudeSessionStamp: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var startedAt: Date

    public init(id: String, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }
}

/// Keeps the last session id `ClaudeInvocation.onSession` reported (the retry's, if there was one). Thread-safe:
/// the runner calls it from the process's reader thread.
public final class ClaudeSessionCapture: Sendable {
    private let state = OSAllocatedUnfairLock<ClaudeSessionStamp?>(initialState: nil)
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func record(_ id: String) {
        let stamp = ClaudeSessionStamp(id: id, startedAt: now())
        state.withLock { $0 = stamp }
    }

    public var stamp: ClaudeSessionStamp? { state.withLock { $0 } }
}

/// One `claude -p` run of a PR job that can be resumed in a terminal (spec T.1/T.2): a review stage, a Respond fix or
/// the Fix CI. The chat isn't one.
public struct ClaudeSessionRef: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case review, fix, ciFix }

    /// Claude Code's session id (a UUID).
    public var id: String
    /// `Review · stage N`, `Fix N: <title>` or `CI fix`.
    public var label: String
    public var kind: Kind
    /// The folder it ran in, on the machine where it ran (`claude --resume` has to run there).
    public var directory: String
    /// `nil` = this Mac; otherwise the runner's name (`RunnerSettings`).
    public var runner: String?
    public var startedAt: Date

    public init(id: String, label: String, kind: Kind, directory: String, runner: String?, startedAt: Date) {
        self.id = id
        self.label = label
        self.kind = kind
        self.directory = directory
        self.runner = runner
        self.startedAt = startedAt
    }

    /// The fix titles in the labels are cut to this many characters (with the ellipsis).
    public static let titleLimit = 50

    public static func reviewStage(_ number: Int, stamp: ClaudeSessionStamp, directory: String, runner: String?) -> ClaudeSessionRef {
        ClaudeSessionRef(id: stamp.id, label: "Review · stage \(number)", kind: .review, directory: directory, runner: runner,
                         startedAt: stamp.startedAt)
    }

    /// The sessions of a Respond or Fix CI implementation, in the order the fixes ran: `Fix N: <title>` (N counts the
    /// fixes that ran, from 1) or `CI fix`. Items without a session (Claude never started) are skipped.
    public static func fixes(draft: RespondDraft, items: [ItemResult]) -> [ClaudeSessionRef] {
        items.enumerated().compactMap { index, result in
            guard let stamp = result.session else { return nil }
            let item = draft.items.first { $0.id == result.id }
            let isCI = item?.feedback.kind == .ciChecks
            let label = isCI ? "CI fix" : "Fix \(index + 1): " + truncated(item.map(title(of:)) ?? result.id)
            return ClaudeSessionRef(id: stamp.id, label: label, kind: isCI ? .ciFix : .fix, directory: draft.worktree.path,
                                    runner: draft.runner, startedAt: stamp.startedAt)
        }
    }

    /// The finding's title: the first non-empty line of its first comment, or its file.
    static func title(of item: RespondItem) -> String {
        let body = item.feedback.comments.first?.body ?? ""
        let line = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? item.feedback.path ?? item.id
    }

    /// At most `limit` characters, the last one `…` when it was cut.
    public static func truncated(_ text: String, limit: Int = titleLimit) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// Only a UUID goes after `--resume` (spec T.5).
    public static func isValidID(_ id: String) -> Bool { UUID(uuidString: id) != nil }
}
