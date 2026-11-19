import Foundation

public struct RepoRef: Hashable, Codable, Sendable, Identifiable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public var fullName: String { "\(owner)/\(name)" }
    public var id: String { fullName }
}

public enum ReviewState: String, Codable, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case commented = "COMMENTED"
    case dismissed = "DISMISSED"
    case pending = "PENDING"
}

public struct PRReview: Hashable, Codable, Sendable {
    public let author: String
    public let isBot: Bool
    public let state: ReviewState
    public let submittedAt: Date
    /// Commit sobre el que se hizo la review. `nil` en `state.json` viejos o si GitHub no lo informa.
    public let commitOID: String?

    public init(author: String, isBot: Bool, state: ReviewState, submittedAt: Date, commitOID: String? = nil) {
        self.author = author
        self.isBot = isBot
        self.state = state
        self.submittedAt = submittedAt
        self.commitOID = commitOID
    }

    private enum CodingKeys: String, CodingKey { case author, isBot, state, submittedAt, commitOID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        author = try c.decode(String.self, forKey: .author)
        isBot = try c.decode(Bool.self, forKey: .isBot)
        state = try c.decode(ReviewState.self, forKey: .state)
        submittedAt = try c.decode(Date.self, forKey: .submittedAt)
        commitOID = try c.decodeIfPresent(String.self, forKey: .commitOID)
    }
}

public struct PRComment: Hashable, Codable, Sendable {
    public let author: String
    public let isBot: Bool
    public let createdAt: Date

    public init(author: String, isBot: Bool, createdAt: Date) {
        self.author = author
        self.isBot = isBot
        self.createdAt = createdAt
    }
}

public enum CIState: String, Codable, Sendable {
    case success, failure, pending, none
}

public enum ReviewDecision: String, Codable, Sendable {
    case approved, changesRequested, reviewRequired, none
}

public struct PullRequest: Hashable, Codable, Sendable, Identifiable {
    public let repo: RepoRef
    public let number: Int
    public let title: String
    public let url: URL
    public let isDraft: Bool
    public let author: String
    public let authorAvatarURL: URL?
    public let baseRef: String
    public let headRef: String
    public let headOid: String
    public let additions: Int
    public let deletions: Int
    public let createdAt: Date
    public let updatedAt: Date
    /// Fecha del último commit; se usa como aproximación del "último push" (spec §6).
    public let lastCommitAt: Date
    public let ciState: CIState
    public let reviewDecision: ReviewDecision
    public let reviews: [PRReview]
    public let comments: [PRComment]
    public let requestedReviewers: [String]

    public init(
        repo: RepoRef, number: Int, title: String, url: URL, isDraft: Bool,
        author: String, authorAvatarURL: URL?, baseRef: String, headRef: String, headOid: String,
        additions: Int, deletions: Int, createdAt: Date, updatedAt: Date, lastCommitAt: Date,
        ciState: CIState, reviewDecision: ReviewDecision,
        reviews: [PRReview], comments: [PRComment], requestedReviewers: [String]
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.author = author
        self.authorAvatarURL = authorAvatarURL
        self.baseRef = baseRef
        self.headRef = headRef
        self.headOid = headOid
        self.additions = additions
        self.deletions = deletions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCommitAt = lastCommitAt
        self.ciState = ciState
        self.reviewDecision = reviewDecision
        self.reviews = reviews
        self.comments = comments
        self.requestedReviewers = requestedReviewers
    }

    public var id: String { "\(repo.fullName)#\(number)" }
}

public enum PRCategory: String, Codable, Sendable, CaseIterable, Comparable, Identifiable {
    case toReview, updatedSinceMyReview, myFeedback, other

    public var id: String { rawValue }
    public var countsForBadge: Bool { self != .other }

    public var title: String {
        switch self {
        case .toReview: "To Review"
        case .updatedSinceMyReview: "Updated Since My Review"
        case .myFeedback: "My PRs with Feedback"
        case .other: "Other"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self)! }

    public static func < (lhs: PRCategory, rhs: PRCategory) -> Bool { lhs.order < rhs.order }
}

public struct ClassifiedPR: Hashable, Codable, Sendable, Identifiable {
    public let pr: PullRequest
    public let category: PRCategory
    /// Login de la cuenta de GitHub desde la que se vio este PR.
    public let account: String

    public init(pr: PullRequest, category: PRCategory, account: String) {
        self.pr = pr
        self.category = category
        self.account = account
    }

    public var id: String { pr.id }
}
