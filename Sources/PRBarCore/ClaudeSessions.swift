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

/// What "Terminal" offers (spec T.1/T.4), without side effects.
public enum SessionOffer {
    public struct Group: Equatable, Sendable, Identifiable {
        public let title: String
        public let sessions: [ClaudeSessionRef]
        public var id: String { title }
    }

    static let kindOrder: [ClaudeSessionRef.Kind] = [.review, .fix, .ciFix]

    /// The sessions of the PR's kept, current folders that ran in those folders: Review first, then Fixes, then
    /// CI fix, each in the order they ran.
    public static func offered(prID: String, retained: [RetainedWorktree]) -> [ClaudeSessionRef] {
        sorted(retained.filter { $0.prID == prID && !$0.superseded }.flatMap(sessions(of:)))
    }

    /// The sessions of one History record, if its folder is still kept.
    public static func ofRecord(_ recordID: UUID, retained: [RetainedWorktree]) -> [ClaudeSessionRef] {
        sorted(retained.filter { $0.recordID == recordID && !$0.superseded }.flatMap(sessions(of:)))
    }

    static func sessions(of entry: RetainedWorktree) -> [ClaudeSessionRef] {
        entry.sessions.filter { $0.directory == entry.location.directory }
    }

    static func sorted(_ sessions: [ClaudeSessionRef]) -> [ClaudeSessionRef] {
        sessions.sorted { a, b in
            let (ka, kb) = (kindOrder.firstIndex(of: a.kind) ?? 0, kindOrder.firstIndex(of: b.kind) ?? 0)
            return ka != kb ? ka < kb : a.startedAt < b.startedAt
        }
    }

    public static func groups(_ sessions: [ClaudeSessionRef]) -> [Group] {
        let titles: [ClaudeSessionRef.Kind: String] = [.review: "Review", .fix: "Fixes", .ciFix: "CI fix"]
        return kindOrder.compactMap { kind in
            let matching = sessions.filter { $0.kind == kind }
            return matching.isEmpty ? nil : Group(title: titles[kind] ?? kind.rawValue, sessions: matching)
        }
    }

    public static func mostRecent(_ sessions: [ClaudeSessionRef]) -> ClaudeSessionRef? {
        sessions.max { $0.startedAt < $1.startedAt }
    }

    /// `prbar session open`: `run` is the number of `prbar session list`; `job` alone takes its most recent; neither,
    /// the most recent of all.
    public static func pick(_ sessions: [ClaudeSessionRef], job: SessionJob?, run: Int?) throws -> ClaudeSessionRef {
        guard !sessions.isEmpty else { throw CommandFailure(.invalidState, "No Claude session for this PR yet.") }
        if let run {
            guard sessions.indices.contains(run - 1) else {
                throw CommandFailure(.notFound, "There’s no session \(run). See prbar session list.")
            }
            let session = sessions[run - 1]
            if let job, !matches(session, job) {
                throw CommandFailure(.invalidUsage, "Session \(run) isn’t from \(job.rawValue).")
            }
            return session
        }
        let candidates = job.map { job in sessions.filter { matches($0, job) } } ?? sessions
        guard let session = mostRecent(candidates) else {
            throw CommandFailure(.invalidState, "No Claude session of \(job?.rawValue ?? "this PR") yet.")
        }
        return session
    }

    static func matches(_ session: ClaudeSessionRef, _ job: SessionJob) -> Bool {
        switch job {
        case .review: session.kind == .review
        case .respond: session.kind == .fix
        case .ciFix: session.kind == .ciFix
        }
    }

    /// The button's help (spec T.4).
    public static func help(count: Int, busy: Bool, terminal: String) -> String {
        if count == 0 { return "No Claude session for this PR yet" }
        if busy { return "Claude is working on it" }
        return "Open Claude’s session in \(terminal)"
    }

    /// `busy`: the ids of the sessions whose folder PRBar is working in.
    public static func info(_ sessions: [ClaudeSessionRef], busy: Set<String>) -> [ClaudeSessionInfo] {
        sessions.enumerated().map { index, session in
            let kind = switch session.kind {
            case .review: "review"
            case .fix: "fix"
            case .ciFix: "ci-fix"
            }
            return ClaudeSessionInfo(number: index + 1, label: session.label, kind: kind, machine: session.runner ?? "this Mac",
                                     directory: session.directory, startedAt: session.startedAt, sessionID: session.id,
                                     busy: busy.contains(session.id))
        }
    }
}
