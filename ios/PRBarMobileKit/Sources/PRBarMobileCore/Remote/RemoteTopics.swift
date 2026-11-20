import Foundation
import PRBarWire

// The topics the Mac pushes (spec P.6). Plan 18 builds them on the Mac (`RemoteStateFeed`); until its types land in the
// shared kit these are the phone's decoders for the same JSON. Optional fields marked "plan 18 gap" are data the design
// shows that no command returns yet (listed in spec R.7); the UI hides them when absent.

public enum Topic {
    public static let home = "home"
    public static let activity = "activity"
    public static func pr(_ id: String) -> String { "pr:\(id)" }
}

/// `home`: `status` + `listPRs(nil, nil, nil)` + `ciList`.
public struct RemoteHome: Codable, Equatable, Sendable {
    public var status: StatusInfo
    public var prs: [PRInfo]
    public var ci: [CIEntry]
    /// Plan 18 gap: author display names by login ("Laura Méndez"); rows fall back to the login.
    public var people: [String: String]?
    /// Plan 18 gap: included findings of a finished review by PR ("4 comments"), and approvals of my PRs
    /// ("Approved by 2").
    public var findingCounts: [String: Int]?
    public var approvals: [String: Int]?

    public init(status: StatusInfo, prs: [PRInfo], ci: [CIEntry] = [], people: [String: String]? = nil,
                findingCounts: [String: Int]? = nil, approvals: [String: Int]? = nil) {
        self.status = status
        self.prs = prs
        self.ci = ci
        self.people = people
        self.findingCounts = findingCounts
        self.approvals = approvals
    }
}

/// One of my PRs with failing CI (`CIListEntry` of `feat/ci-cost`, the fields the phone uses).
public struct CIEntry: Codable, Equatable, Sendable {
    public var pr: String
    public var title: String
    public var url: URL
    public var account: String
    public var phase: String?
    public var respondInProgress: Bool
    public var unavailableReason: String?
    /// Plan 18 gap: how many checks failed ("2 checks failed").
    public var failedChecks: Int?

    public init(pr: String, title: String, url: URL, account: String, phase: String? = nil,
                respondInProgress: Bool = false, unavailableReason: String? = nil, failedChecks: Int? = nil) {
        self.pr = pr
        self.title = title
        self.url = url
        self.account = account
        self.phase = phase
        self.respondInProgress = respondInProgress
        self.unavailableReason = unavailableReason
        self.failedChecks = failedChecks
    }
}

/// A failed check of a Fix CI run (`CICheckFailure` of `feat/ci-cost`) plus what the design shows.
public struct CICheck: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var conclusion: String
    /// Plan 18 gap: "1m 12s".
    public var duration: String?
    /// Plan 18 gap: the tail of the failing log, one entry per line.
    public var logExcerpt: [String]?

    public init(id: String, name: String, conclusion: String, duration: String? = nil, logExcerpt: [String]? = nil) {
        self.id = id
        self.name = name
        self.conclusion = conclusion
        self.duration = duration
        self.logExcerpt = logExcerpt
    }
}

/// The `feat/ci-cost` fields of `RespondInfo` that this branch's `RespondInfo` does not decode.
public struct RespondExtras: Codable, Equatable, Sendable {
    /// `feedback` or `ciFix`.
    public var mode: String?
    public var ciChecks: [CICheck]?
    /// Plan 18 gap: how many checks ran on the head ("2 of 9").
    public var totalChecks: Int?
    /// Plan 18 gap: the file being edited ("src/reports/export.ts") and test counts ("142 passed").
    public var currentFile: String?
    public var testSummary: String?

    public init(mode: String? = nil, ciChecks: [CICheck]? = nil, totalChecks: Int? = nil, currentFile: String? = nil,
                testSummary: String? = nil) {
        self.mode = mode
        self.ciChecks = ciChecks
        self.totalChecks = totalChecks
        self.currentFile = currentFile
        self.testSummary = testSummary
    }
}

/// `pr:<owner/repo#N>`: `reviewShow`/`respondShow`/`chatShow` without "nothing there" errors.
public struct RemotePRDetail: Equatable, Sendable {
    public var pr: PRInfo
    public var review: ReviewInfo?
    public var respond: RespondInfo?
    public var respondExtras: RespondExtras?
    public var merge: MergeInfo?
    public var chat: ChatInfo?

    public init(pr: PRInfo, review: ReviewInfo? = nil, respond: RespondInfo? = nil, respondExtras: RespondExtras? = nil,
                merge: MergeInfo? = nil, chat: ChatInfo? = nil) {
        self.pr = pr
        self.review = review
        self.respond = respond
        self.respondExtras = respondExtras
        self.merge = merge
        self.chat = chat
    }
}

extension RemotePRDetail: Codable {
    private enum Keys: String, CodingKey { case pr, review, respond, merge, chat }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        pr = try c.decode(PRInfo.self, forKey: .pr)
        review = try c.decodeIfPresent(ReviewInfo.self, forKey: .review)
        respond = try c.decodeIfPresent(RespondInfo.self, forKey: .respond)
        // Same object, read again for the fields `RespondInfo` does not know yet.
        respondExtras = try c.decodeIfPresent(RespondExtras.self, forKey: .respond)
        merge = try c.decodeIfPresent(MergeInfo.self, forKey: .merge)
        chat = try c.decodeIfPresent(ChatInfo.self, forKey: .chat)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(pr, forKey: .pr)
        try c.encodeIfPresent(review, forKey: .review)
        if let respond {
            // Merge both views of the same object back into one.
            var object = try JSONValue(encoding: respond)
            if let respondExtras, case .object(let extra) = try JSONValue(encoding: respondExtras),
               case .object(var base) = object {
                base.merge(extra) { current, _ in current }
                object = .object(base)
            }
            try c.encode(object, forKey: .respond)
        }
        try c.encodeIfPresent(merge, forKey: .merge)
        try c.encodeIfPresent(chat, forKey: .chat)
    }
}

/// Totals of Claude use (the `ClaudeUsage` fields the phone shows).
public struct UsageTotals: Codable, Equatable, Sendable {
    public var runs: Int
    public var costUSD: Double?
    /// Chat messages (plan 18 gap: the design counts chat in messages, not runs).
    public var messages: Int?

    public init(runs: Int, costUSD: Double?, messages: Int? = nil) {
        self.runs = runs
        self.costUSD = costUSD
        self.messages = messages
    }
}

/// `usage(nil)` (`UsageInfo` of `feat/ci-cost`): the month and its split by task kind.
public struct UsageDigest: Codable, Equatable, Sendable {
    public struct Month: Codable, Equatable, Sendable {
        /// `YYYY-MM`.
        public var month: String
        public var usage: UsageTotals
        /// By `ProcessActivity.Kind` raw value: `review`, `respond`, `chat`, …
        public var byKind: [String: UsageTotals]

        public init(month: String, usage: UsageTotals, byKind: [String: UsageTotals]) {
            self.month = month
            self.usage = usage
            self.byKind = byKind
        }
    }

    public var month: Month

    public init(month: Month) {
        self.month = month
    }
}

/// Plan 18 gap: the Mac's own totals for the stat tiles ("12 cores", "of 16 GB", "212 GB free of 512").
public struct SystemStats: Codable, Equatable, Sendable {
    public var cores: Int
    public var memoryTotalBytes: UInt64
    public var memoryUsedBytes: UInt64
    public var diskFreeBytes: Int64
    public var diskTotalBytes: Int64

    public init(cores: Int, memoryTotalBytes: UInt64, memoryUsedBytes: UInt64, diskFreeBytes: Int64, diskTotalBytes: Int64) {
        self.cores = cores
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryUsedBytes = memoryUsedBytes
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
    }
}

/// Plan 18 gap: a running job with its elapsed time and estimated cost ("2 agents · 4:12 · ~$0.38").
public struct RunningJob: Codable, Equatable, Sendable {
    public var pr: String
    /// `review` or `respond` (Fix CI is a `respond` run).
    public var kind: String
    public var title: String
    public var detail: String
    public var startedAt: Date
    public var costUSD: Double?

    public init(pr: String, kind: String, title: String, detail: String, startedAt: Date, costUSD: Double? = nil) {
        self.pr = pr
        self.kind = kind
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
        self.costUSD = costUSD
    }
}

/// `activity`: `ResourcesInfo` + `usage(nil)` + the last 20 `history` entries.
public struct RemoteActivity: Codable, Equatable, Sendable {
    public var resources: ResourcesInfo
    public var usage: UsageDigest?
    public var history: [HistoryEntryInfo]
    public var system: SystemStats?
    public var running: [RunningJob]?

    public init(resources: ResourcesInfo, usage: UsageDigest? = nil, history: [HistoryEntryInfo] = [],
                system: SystemStats? = nil, running: [RunningJob]? = nil) {
        self.resources = resources
        self.usage = usage
        self.history = history
        self.system = system
        self.running = running
    }
}
