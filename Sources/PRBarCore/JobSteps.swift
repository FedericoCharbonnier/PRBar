import Foundation

/// Where a job sends its steps (spec LP.2). Callable from any thread; `JobActivityFeed` keeps the order.
public typealias JobActivitySink = @Sendable (JobActivity) -> Void

extension JobActivity {
    /// A PRBar step. `runner`: the host where it runs (spec J), as " on <runner>" before the final "…"
    /// ("Creating the worktree on build-box…"); nil or empty = this Mac.
    public static func prbar(_ text: String, runner: String? = nil, at date: Date = Date()) -> JobActivity {
        JobActivity(kind: .prbar, text: JobStep.on(runner, text), startedAt: date)
    }

    /// A Claude step (`ClaudeActivityText`).
    public static func claude(_ text: String, at date: Date = Date()) -> JobActivity {
        JobActivity(kind: .claude, text: text, startedAt: date)
    }
}

/// PRBar's own steps (spec LP.3): fixed texts, emitted by the pipelines where each thing happens.
public enum JobStep {
    // All jobs.
    public static let readingPR = "Reading the PR on GitHub…"
    public static let writingContext = "Writing the context for Claude…"
    // Review.
    public static let creatingReviewFolder = "Creating the PR’s folder…"
    public static func updatingReviewFolder(_ headOid: String) -> String { "Updating the PR’s folder to \(headOid.prefix(7))…" }
    public static let creatingTemporaryFolder = "Creating a temporary folder…"
    public static let readingPreviousReviews = "Reading the previous reviews…"
    public static let filteringFindings = "Filtering the findings…"
    /// A cancelled review of the same PR is still letting go of its folder (`ReviewFolderLocks`).
    public static let waitingForPreviousReview = "Waiting for the previous review of this PR…"
    // Respond, Fix CI, Resolve Conflicts.
    public static let readingComments = "Reading the comments and their threads…"
    public static let creatingWorktree = "Creating the worktree…"
    public static let runningTests = "Running the tests…"
    public static let committing = "Committing…"
    public static let pushing = "Pushing…"
    public static let replying = "Replying on GitHub…"
    public static let readingFailingChecks = "Reading the failing checks…"
    public static let downloadingCILogs = "Downloading the CI logs…"
    public static func fetching(_ baseRef: String) -> String { "Fetching \(name(baseRef))…" }
    public static func merging(_ baseRef: String) -> String { "Merging \(name(baseRef))…" }
    public static let checkingConflictMarkers = "Checking for conflict markers…"
    public static let committingMerge = "Committing the merge…"
    /// On a runner: its copy of the respond skills' plugins (" on <runner>").
    public static let preparingPlugins = "Preparing Claude’s plugins…"
    /// On a runner: the fixes come back to this Mac.
    public static func bringingFixes(from runner: String) -> String { "Bringing the fixes from \(name(runner))…" }

    /// The most a name from outside (a branch, a host, what Claude asked for) takes in a step (spec LP.4).
    public static let maxNameLength = 80

    /// `text` cut to `limit` characters, the last one "…".
    public static func clip(_ text: String, limit: Int = maxNameLength) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// Text from GitHub or the user's settings in a step: one line, neutralized, at most 80 characters.
    public static func name(_ text: String) -> String { clip(UntrustedText.singleLine(text, limit: 1000)) }

    /// `text` with " on <runner>" before its final "…".
    static func on(_ runner: String?, _ text: String) -> String {
        guard let runner else { return text }
        let host = name(runner)
        guard !host.isEmpty else { return text }
        return text.hasSuffix("…") ? "\(text.dropLast()) on \(host)…" : "\(text) on \(host)"
    }
}

extension ReviewPhase {
    /// The phase in the step line of a row ("Reviewing · Reading src/a.swift"); nil when the review isn't running.
    public var stepTitle: String? {
        switch self {
        case .queued: "Queued"
        case .preparing: "Preparing"
        case .reviewing: "Reviewing"
        case .filtering: "Filtering"
        case .ready, .failed, .published: nil
        }
    }
}

extension RespondPhase {
    /// Like `ReviewPhase.stepTitle`. The tests run in `readyToPush` (`RespondQueue.runningTests`): "Testing".
    public func stepTitle(mode: RespondMode, runningTests: Bool) -> String? {
        if runningTests { return "Testing" }
        switch self {
        case .queued: return "Queued"
        case .preparing: return "Preparing"
        case .analyzing: return "Analyzing"
        case .implementing: return mode == .conflicts ? "Resolving" : mode == .ciFix ? "Fixing" : "Implementing"
        case .pushing: return "Pushing"
        case .ready, .readyToPush, .done, .failed: return nil
        }
    }
}
