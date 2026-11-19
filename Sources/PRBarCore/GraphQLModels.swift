import Foundation

enum Queries {
    static let openPullRequests = """
    query($owner: String!, $name: String!, $cursor: String) {
      repository(owner: $owner, name: $name) {
        defaultBranchRef { name }
        squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed viewerDefaultMergeMethod deleteBranchOnMerge viewerPermission
        pullRequests(states: OPEN, first: 50, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id number title url isDraft createdAt updatedAt additions deletions
            baseRefName headRefName headRefOid reviewDecision mergeable mergeStateStatus viewerCanUpdate
            author { login avatarUrl __typename }
            reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } } } }
            reviews(last: 50) { nodes { author { login __typename } state submittedAt commit { oid } } }
            comments(last: 50) { nodes { author { login __typename } createdAt } }
            commits(last: 1) { totalCount nodes { commit { committedDate statusCheckRollup { state } } } }
          }
        }
      }
    }
    """

    static let reviewFeedback = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          headRefName headRefOid isCrossRepository
          commits(last: 1) { nodes { commit { committedDate } } }
          reviewThreads(first: 100) {
            nodes {
              id isResolved isOutdated path line
              comments(first: 30) { nodes { databaseId body createdAt url author { login __typename } } }
            }
          }
          reviews(last: 50) { nodes { databaseId state body submittedAt url author { login __typename } } }
        }
      }
    }
    """

    static let viewerRepositories = """
    query($cursor: String) {
      viewer {
        repositories(first: 100, after: $cursor, isArchived: false,
                     affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
                     ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
                     orderBy: {field: PUSHED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes { name owner { login } }
        }
      }
    }
    """

    static let assignableUsers = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        assignableUsers(first: 100) { nodes { login name avatarUrl } }
      }
    }
    """
}

struct GraphQLEnvelope<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLErrorItem]?
}

struct GraphQLErrorItem: Decodable {
    let message: String
    /// p. ej. `"RATE_LIMITED"`, `"NOT_FOUND"`.
    let type: String?
}

struct Nodes<T: Decodable>: Decodable {
    let nodes: [T?]
}

struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

struct ActorNode: Decodable {
    let login: String
    let avatarUrl: URL?
    let typename: String?

    enum CodingKeys: String, CodingKey {
        case login, avatarUrl
        case typename = "__typename"
    }

    var isBot: Bool { typename == "Bot" }
}

struct PRQueryData: Decodable {
    struct Repository: Decodable {
        let defaultBranchRef: NameNode?
        let pullRequests: Connection
        // Ajustes de merge (spec F.2). Opcionales: si faltan, no se sabe.
        let squashMergeAllowed: Bool?
        let mergeCommitAllowed: Bool?
        let rebaseMergeAllowed: Bool?
        let viewerDefaultMergeMethod: String?
        let deleteBranchOnMerge: Bool?
        let viewerPermission: String?

        /// `nil` si la respuesta no trae ninguno de los métodos (una respuesta vieja o recortada).
        var mergeSettings: RepoMergeSettings? {
            guard squashMergeAllowed != nil || mergeCommitAllowed != nil || rebaseMergeAllowed != nil else { return nil }
            return RepoMergeSettings(
                squashAllowed: squashMergeAllowed ?? false, mergeCommitAllowed: mergeCommitAllowed ?? false,
                rebaseAllowed: rebaseMergeAllowed ?? false, viewerDefault: MergeMethod(graphQL: viewerDefaultMergeMethod),
                deleteBranchOnMerge: deleteBranchOnMerge ?? false, viewerPermission: viewerPermission
            )
        }
    }
    struct NameNode: Decodable { let name: String }
    struct Connection: Decodable {
        let pageInfo: PageInfo
        let nodes: [PRNode?]
    }
    let repository: Repository?
}

struct PRNode: Decodable {
    struct ReviewRequest: Decodable {
        struct Reviewer: Decodable { let login: String? }
        let requestedReviewer: Reviewer?
    }
    struct Review: Decodable {
        struct CommitRef: Decodable { let oid: String }
        let author: ActorNode?
        let state: String
        let submittedAt: Date?
        let commit: CommitRef?
    }
    struct Comment: Decodable {
        let author: ActorNode?
        let createdAt: Date
    }
    struct CommitWrapper: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable { let state: String }
            let committedDate: Date
            let statusCheckRollup: Rollup?
        }
        let commit: Commit
    }
    struct CommitConnection: Decodable {
        let totalCount: Int?
        let nodes: [CommitWrapper?]
    }

    let id: String?
    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let additions: Int
    let deletions: Int
    let baseRefName: String
    let headRefName: String
    let headRefOid: String
    let reviewDecision: String?
    let mergeable: String?
    let mergeStateStatus: String?
    let viewerCanUpdate: Bool?
    let author: ActorNode?
    let reviewRequests: Nodes<ReviewRequest>
    let reviews: Nodes<Review>
    let comments: Nodes<Comment>
    let commits: CommitConnection

    func toPullRequest(repo: RepoRef) -> PullRequest {
        let commit = commits.nodes.compactMap { $0 }.last?.commit
        return PullRequest(
            repo: repo, number: number, title: title, url: url, isDraft: isDraft,
            author: author?.login ?? "ghost", authorAvatarURL: author?.avatarUrl,
            baseRef: baseRefName, headRef: headRefName, headOid: headRefOid,
            additions: additions, deletions: deletions,
            createdAt: createdAt, updatedAt: updatedAt,
            lastCommitAt: commit?.committedDate ?? createdAt,
            ciState: CIState(rollup: commit?.statusCheckRollup?.state),
            reviewDecision: ReviewDecision(graphQL: reviewDecision),
            reviews: reviews.nodes.compactMap { node in
                guard let node, let submittedAt = node.submittedAt, let state = ReviewState(rawValue: node.state) else { return nil }
                return PRReview(author: node.author?.login ?? "ghost", isBot: node.author?.isBot ?? false, state: state, submittedAt: submittedAt, commitOID: node.commit?.oid)
            },
            comments: comments.nodes.compactMap { node in
                guard let node else { return nil }
                return PRComment(author: node.author?.login ?? "ghost", isBot: node.author?.isBot ?? false, createdAt: node.createdAt)
            },
            requestedReviewers: reviewRequests.nodes.compactMap { $0?.requestedReviewer?.login },
            merge: PRMergeState(
                nodeID: id, mergeable: MergeableState(graphQL: mergeable), status: MergeStateStatus(graphQL: mergeStateStatus),
                viewerCanUpdate: viewerCanUpdate, commitCount: commits.totalCount
            )
        )
    }
}

struct ViewerReposData: Decodable {
    struct Viewer: Decodable { let repositories: Connection }
    struct Connection: Decodable {
        let pageInfo: PageInfo
        let nodes: [RepoNode?]
    }
    struct RepoNode: Decodable {
        struct Owner: Decodable { let login: String }
        let name: String
        let owner: Owner
    }
    let viewer: Viewer
}

struct AssignableUsersData: Decodable {
    struct Repository: Decodable { let assignableUsers: Nodes<UserNode> }
    struct UserNode: Decodable {
        let login: String
        let name: String?
        let avatarUrl: URL?
    }
    let repository: Repository?
}

extension CIState {
    init(rollup: String?) {
        switch rollup {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        case "PENDING", "EXPECTED": self = .pending
        default: self = .none
        }
    }
}

extension ReviewDecision {
    init(graphQL: String?) {
        switch graphQL {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .reviewRequired
        default: self = .none
        }
    }
}

struct FeedbackQueryData: Decodable {
    struct Repository: Decodable { let pullRequest: PRFeedbackNode? }
    let repository: Repository?
}

struct PRFeedbackNode: Decodable {
    struct CommitWrapper: Decodable {
        struct Commit: Decodable { let committedDate: Date }
        let commit: Commit
    }
    struct CommentNode: Decodable {
        let databaseId: Int?
        let body: String
        let createdAt: Date
        let url: URL
        let author: ActorNode?
    }
    struct ThreadNode: Decodable {
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
        let path: String?
        let line: Int?
        let comments: Nodes<CommentNode>
    }
    struct ReviewNode: Decodable {
        let databaseId: Int?
        let state: String
        let body: String
        let submittedAt: Date?
        let url: URL
        let author: ActorNode?
    }
    struct ThreadConnection: Decodable { let nodes: [ThreadNode?] }

    let headRefName: String
    let headRefOid: String
    let isCrossRepository: Bool
    let commits: Nodes<CommitWrapper>
    let reviewThreads: ThreadConnection
    let reviews: Nodes<ReviewNode>

    func toFeedback() -> PRFeedback {
        let threads = reviewThreads.nodes.compactMap { node -> FeedbackItem? in
            guard let node else { return nil }
            let comments = node.comments.nodes.compactMap { comment -> FeedbackComment? in
                guard let comment, let id = comment.databaseId else { return nil }
                return FeedbackComment(
                    databaseID: id, author: comment.author?.login ?? "ghost", isBot: comment.author?.isBot ?? false,
                    body: comment.body, createdAt: comment.createdAt, url: comment.url)
            }
            guard !comments.isEmpty else { return nil }
            return FeedbackItem(
                id: "thread:\(node.id)", kind: .thread, path: node.path, line: node.line,
                isOutdated: node.isOutdated, isResolved: node.isResolved, comments: comments)
        }
        let reviewBodies = reviews.nodes.compactMap { node -> FeedbackReview? in
            guard let node, let id = node.databaseId, let submittedAt = node.submittedAt,
                  let state = ReviewState(rawValue: node.state) else { return nil }
            let comment = FeedbackComment(
                databaseID: id, author: node.author?.login ?? "ghost", isBot: node.author?.isBot ?? false,
                body: node.body, createdAt: submittedAt, url: node.url)
            let item = FeedbackItem(id: "review:\(id)", kind: .reviewBody, path: nil, line: nil, isOutdated: false, comments: [comment])
            return FeedbackReview(item: item, state: state, submittedAt: submittedAt)
        }
        let lastCommit = commits.nodes.compactMap { $0 }.last?.commit.committedDate
        return PRFeedback(
            headRefName: headRefName, headRefOid: headRefOid, isCrossRepository: isCrossRepository,
            lastCommitAt: lastCommit ?? .distantPast, threads: threads, reviews: reviewBodies)
    }
}
