import Foundation

public struct GitHubUser: Hashable, Codable, Sendable {
    public let login: String
    public let name: String?
    public let avatarURL: URL?

    public init(login: String, name: String?, avatarURL: URL?) {
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }
}

public struct RepoPRs: Equatable, Sendable {
    public let defaultBranch: String
    public let pullRequests: [PullRequest]
    /// Métodos permitidos y método por defecto de la cuenta (spec F.2); `nil` si la respuesta no los trajo.
    public let mergeSettings: RepoMergeSettings?

    public init(defaultBranch: String, pullRequests: [PullRequest], mergeSettings: RepoMergeSettings? = nil) {
        self.defaultBranch = defaultBranch
        self.pullRequests = pullRequests
        self.mergeSettings = mergeSettings
    }
}

/// Archivo de un PR según `GET /pulls/{n}/files`. `patch` es nil en binarios o diffs enormes.
public struct PRFile: Equatable, Sendable {
    public let filename: String
    public let patch: String?

    public init(filename: String, patch: String?) {
        self.filename = filename
        self.patch = patch
    }
}

/// Cuerpo de una review con su estado y fecha, para decidir si todavía pide algo.
public struct FeedbackReview: Equatable, Sendable {
    public let item: FeedbackItem
    public let state: ReviewState
    public let submittedAt: Date

    public init(item: FeedbackItem, state: ReviewState, submittedAt: Date) {
        self.item = item
        self.state = state
        self.submittedAt = submittedAt
    }
}

/// Feedback de un PR: todos los hilos (también los resueltos, marcados en `isResolved`) y los cuerpos de review.
public struct PRFeedback: Equatable, Sendable {
    public let headRefName: String
    public let headRefOid: String
    public let isCrossRepository: Bool
    public let lastCommitAt: Date
    public let threads: [FeedbackItem]
    public let reviews: [FeedbackReview]

    public init(
        headRefName: String, headRefOid: String, isCrossRepository: Bool, lastCommitAt: Date,
        threads: [FeedbackItem], reviews: [FeedbackReview]
    ) {
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.isCrossRepository = isCrossRepository
        self.lastCommitAt = lastCommitAt
        self.threads = threads
        self.reviews = reviews
    }
}

/// What `GET /repos/{o}/{r}/pulls/{n}` gives cheaply and the 2-minute refresh doesn't bring: the description.
/// Fetched on demand when a review or a respond analysis starts.
public struct PRDetails: Equatable, Sendable {
    /// Open, closed without merging, or merged.
    public enum State: Equatable, Sendable { case open, closed, merged }

    public let title: String
    /// The PR description (Markdown); empty if there is none.
    public let body: String
    public let headOid: String?
    /// `nil` if GitHub didn't say.
    public let state: State?
    public let mergedAt: Date?

    public init(title: String, body: String, headOid: String?, state: State? = nil, mergedAt: Date? = nil) {
        self.title = title
        self.body = body
        self.headOid = headOid
        self.state = state
        self.mergedAt = mergedAt
    }
}

public protocol GitHubAPI: Sendable {
    func openPullRequests(in repo: RepoRef, token: String) async throws -> RepoPRs
    func viewerRepositories(token: String) async throws -> [RepoRef]
    func branches(of repo: RepoRef, token: String) async throws -> [String]
    func defaultBranch(of repo: RepoRef, token: String) async throws -> String
    /// Usuarios que se pueden asignar en el repo (hasta 100): sirven de sugerencias para seguir.
    func assignableUsers(of repo: RepoRef, token: String) async throws -> [GitHubUser]
    func user(login: String, token: String) async throws -> GitHubUser?
    func pullRequestFiles(repo: RepoRef, number: Int, token: String) async throws -> [PRFile]
    /// The PR's description and a few cheap fields (`GET /pulls/{n}`).
    func pullRequestDetails(repo: RepoRef, number: Int, token: String) async throws -> PRDetails
    func submitReview(repo: RepoRef, number: Int, submission: ReviewSubmission, token: String) async throws -> URL
    func reviewFeedback(repo: RepoRef, number: Int, token: String) async throws -> PRFeedback
    func replyToReviewComment(repo: RepoRef, number: Int, commentID: Int, body: String, token: String) async throws -> URL
    func addIssueComment(repo: RepoRef, number: Int, body: String, token: String) async throws -> URL
    /// Mergea el PR (`mergePullRequest`) solo si su head sigue siendo `expectedHeadOid`. Devuelve `mergedAt`.
    /// Errores: `MergeError` (head cambiado, sin permiso, no mergeable) o `PRBarError` (red, token, rate limit).
    func mergePullRequest(id: String, method: MergeMethod, expectedHeadOid: String, token: String) async throws -> Date?
    /// Lo que muestra la ventana de Merge (spec G.3): descripción, reviews, checks, hilos y archivos.
    func mergeDetail(repo: RepoRef, number: Int, token: String) async throws -> MergeDetail
}

public struct GitHubClient: GitHubAPI {
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private static let maxPRPages = 4
    private static let maxRepoPages = 10
    private static let branchesPerPage = 100
    private static let maxBranchPages = 10
    private static let filesPerPage = 100
    private static let maxFilesPages = 30
    /// Espera cuando GitHub informa un rate limit sin decir hasta cuándo.
    private static let defaultRateLimitWait: TimeInterval = 60

    public init(transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    public func openPullRequests(in repo: RepoRef, token: String) async throws -> RepoPRs {
        var cursor: String?
        var pullRequests: [PullRequest] = []
        var defaultBranch = "main"
        var mergeSettings: RepoMergeSettings?
        for _ in 0..<Self.maxPRPages {
            let data: PRQueryData = try await graphQL(
                Queries.openPullRequests,
                variables: ["owner": repo.owner, "name": repo.name, "cursor": cursor],
                token: token
            )
            guard let repository = data.repository else {
                throw PRBarError.graphQL("Couldn't find the repo \(repo.fullName)")
            }
            defaultBranch = repository.defaultBranchRef?.name ?? defaultBranch
            mergeSettings = mergeSettings ?? repository.mergeSettings
            pullRequests += repository.pullRequests.nodes.compactMap { $0?.toPullRequest(repo: repo) }
            guard repository.pullRequests.pageInfo.hasNextPage, let next = repository.pullRequests.pageInfo.endCursor else { break }
            cursor = next
        }
        return RepoPRs(defaultBranch: defaultBranch, pullRequests: pullRequests, mergeSettings: mergeSettings)
    }

    public func viewerRepositories(token: String) async throws -> [RepoRef] {
        var cursor: String?
        var repos: [RepoRef] = []
        for _ in 0..<Self.maxRepoPages {
            let data: ViewerReposData = try await graphQL(Queries.viewerRepositories, variables: ["cursor": cursor], token: token)
            repos += data.viewer.repositories.nodes.compactMap { node in
                node.map { RepoRef(owner: $0.owner.login, name: $0.name) }
            }
            guard data.viewer.repositories.pageInfo.hasNextPage, let next = data.viewer.repositories.pageInfo.endCursor else { break }
            cursor = next
        }
        return repos
    }

    public func branches(of repo: RepoRef, token: String) async throws -> [String] {
        struct Branch: Decodable { let name: String }
        var names: [String] = []
        for page in 1...Self.maxBranchPages {
            let data = try await restGET(
                "/repos/\(repo.owner)/\(repo.name)/branches?per_page=\(Self.branchesPerPage)&page=\(page)", token: token)
            let decoded: [Branch]
            do {
                decoded = try JSONCoding.decoder.decode([Branch].self, from: data)
            } catch {
                throw PRBarError.invalidResponse("branches: \(error)")
            }
            names += decoded.map(\.name)
            if decoded.count < Self.branchesPerPage { break }
        }
        return names
    }

    public func defaultBranch(of repo: RepoRef, token: String) async throws -> String {
        struct Repository: Decodable { let default_branch: String }
        let data = try await restGET("/repos/\(repo.owner)/\(repo.name)", token: token)
        do {
            return try JSONCoding.decoder.decode(Repository.self, from: data).default_branch
        } catch {
            throw PRBarError.invalidResponse("repo: \(error)")
        }
    }

    public func assignableUsers(of repo: RepoRef, token: String) async throws -> [GitHubUser] {
        let data: AssignableUsersData = try await graphQL(
            Queries.assignableUsers, variables: ["owner": repo.owner, "name": repo.name], token: token)
        guard let repository = data.repository else {
            throw PRBarError.graphQL("Couldn't find the repo \(repo.fullName)")
        }
        return repository.assignableUsers.nodes.compactMap { node in
            node.map { GitHubUser(login: $0.login, name: $0.name, avatarURL: $0.avatarUrl) }
        }
    }

    public func user(login: String, token: String) async throws -> GitHubUser? {
        struct User: Decodable {
            let login: String
            let name: String?
            let avatar_url: URL?
        }
        guard !login.isEmpty, login.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        do {
            let data = try await restGET("/users/\(login)", token: token)
            let user = try JSONCoding.decoder.decode(User.self, from: data)
            return GitHubUser(login: user.login, name: user.name, avatarURL: user.avatar_url)
        } catch PRBarError.http(let status, _) where status == 404 {
            return nil
        }
    }

    public func pullRequestFiles(repo: RepoRef, number: Int, token: String) async throws -> [PRFile] {
        struct File: Decodable {
            let filename: String
            let patch: String?
        }
        var files: [PRFile] = []
        for page in 1...Self.maxFilesPages {
            let data = try await restGET(
                "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)/files?per_page=\(Self.filesPerPage)&page=\(page)", token: token)
            let decoded: [File]
            do {
                decoded = try JSONCoding.decoder.decode([File].self, from: data)
            } catch {
                throw PRBarError.invalidResponse("PR files: \(error)")
            }
            files += decoded.map { PRFile(filename: $0.filename, patch: $0.patch) }
            if decoded.count < Self.filesPerPage { break }
        }
        return files
    }

    public func pullRequestDetails(repo: RepoRef, number: Int, token: String) async throws -> PRDetails {
        struct Head: Decodable { let sha: String? }
        struct Pull: Decodable {
            let title: String?
            let body: String?
            let head: Head?
            let state: String?
            let merged: Bool?
            let merged_at: Date?
        }
        let data = try await restGET("/repos/\(repo.owner)/\(repo.name)/pulls/\(number)", token: token)
        do {
            let pull = try JSONCoding.decoder.decode(Pull.self, from: data)
            let state: PRDetails.State? = if pull.merged == true || pull.merged_at != nil {
                .merged
            } else {
                switch pull.state { case "open": .open; case "closed": .closed; default: nil }
            }
            return PRDetails(title: pull.title ?? "", body: pull.body ?? "", headOid: pull.head?.sha, state: state,
                             mergedAt: pull.merged_at)
        } catch {
            throw PRBarError.invalidResponse("PR details: \(error)")
        }
    }

    public func submitReview(repo: RepoRef, number: Int, submission: ReviewSubmission, token: String) async throws -> URL {
        let payload: [String: Any] = [
            "commit_id": submission.commitID,
            "event": submission.event.rawValue,
            "body": submission.body,
            "comments": submission.comments.map { comment -> [String: Any] in
                ["path": comment.path, "line": comment.line, "side": "RIGHT", "body": comment.body]
            },
        ]
        return try await postForURL(
            "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)/reviews", payload: payload,
            repo: repo, number: number, what: "the review", token: token)
    }

    public func reviewFeedback(repo: RepoRef, number: Int, token: String) async throws -> PRFeedback {
        let data: FeedbackQueryData = try await graphQL(
            Queries.reviewFeedback, jsonVariables: ["owner": repo.owner, "name": repo.name, "number": number], token: token)
        guard let pr = data.repository?.pullRequest else {
            throw PRBarError.graphQL("Couldn't find the PR \(repo.fullName)#\(number)")
        }
        return pr.toFeedback()
    }

    public func replyToReviewComment(repo: RepoRef, number: Int, commentID: Int, body: String, token: String) async throws -> URL {
        try await postForURL(
            "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)/comments/\(commentID)/replies", payload: ["body": body],
            repo: repo, number: number, what: "the reply", token: token)
    }

    public func addIssueComment(repo: RepoRef, number: Int, body: String, token: String) async throws -> URL {
        try await postForURL(
            "/repos/\(repo.owner)/\(repo.name)/issues/\(number)/comments", payload: ["body": body],
            repo: repo, number: number, what: "the comment", token: token)
    }

    public func mergePullRequest(id: String, method: MergeMethod, expectedHeadOid: String, token: String) async throws -> Date? {
        let input: [String: Any] = ["pullRequestId": id, "mergeMethod": method.graphQLValue, "expectedHeadOid": expectedHeadOid]
        let (envelope, response): (GraphQLEnvelope<MergeMutationData>, HTTPURLResponse) = try await graphQLEnvelope(
            Mutations.mergePullRequest, jsonVariables: ["input": input], token: token)
        if let errors = envelope.errors, !errors.isEmpty {
            try throwIfRateLimited(errors, response: response)
            throw MergeError.classify(messages: errors.map(\.message), types: errors.map(\.type))
        }
        guard let pr = envelope.data?.mergePullRequest?.pullRequest else {
            throw MergeError.other("GitHub didn’t return the merged PR")
        }
        guard pr.merged else { throw MergeError.notMergeable("GitHub didn’t merge the PR") }
        return pr.mergedAt
    }

    /// Tolerante a errores parciales (spec G.8): GitHub puede responder con el PR y errores de algunos campos (un
    /// `isRequired` sin permiso, `files` con timeout, un nodo bajo SSO). Con el PR, se muestra lo que llegó y las
    /// secciones afectadas quedan en `incomplete`; solo el rate limit o la falta del PR son un error.
    public func mergeDetail(repo: RepoRef, number: Int, token: String) async throws -> MergeDetail {
        let (envelope, response): (GraphQLEnvelope<MergeDetailQueryData>, HTTPURLResponse) = try await graphQLEnvelope(
            Queries.mergeDetail, jsonVariables: ["owner": repo.owner, "name": repo.name, "number": number], token: token)
        let errors = envelope.errors ?? []
        try throwIfRateLimited(errors, response: response)
        let messages = errors.map(\.message).joined(separator: "; ")
        guard let pr = envelope.data?.repository?.pullRequest else {
            AppLog.write("GitHub: couldn't load the summary of \(repo.fullName)#\(number)\(errors.isEmpty ? "" : ": \(messages)")")
            throw PRBarError.graphQL(errors.isEmpty ? "Couldn't find the PR \(repo.fullName)#\(number)" : messages)
        }
        var detail = pr.toDetail()
        if !errors.isEmpty {
            detail.incomplete = MergeDetail.Section.sections(forErrorPaths: errors.map(\.path))
            AppLog.write("GitHub: the summary of \(repo.fullName)#\(number) came with errors "
                + "(\(detail.incomplete.map(\.rawValue).joined(separator: ", "))): \(messages)")
        }
        return detail
    }

    /// POST de JSON que devuelve el `html_url` de lo creado. `perform` solo vuelve con un 2xx: lo publicado ya está
    /// en GitHub. Si la respuesta no trae `html_url` (o no se puede leer) igual cuenta como publicado, con la URL del
    /// PR: un error invitaría a publicarlo de nuevo y duplicarlo.
    private func postForURL(_ path: String, payload: [String: Any], repo: RepoRef, number: Int, what: String, token: String) async throws -> URL {
        struct Response: Decodable { let html_url: URL? }
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = "POST"
        applyHeaders(&request, token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let (data, _) = try await perform(request)
        if let url = (try? JSONCoding.decoder.decode(Response.self, from: data))?.html_url {
            return url
        }
        AppLog.write("GitHub: \(what) on \(repo.fullName)#\(number) was posted, but the response has no html_url; using the PR URL")
        return URL(string: "https://github.com/\(repo.owner)/\(repo.name)/pull/\(number)")!
    }

    // MARK: - HTTP

    private func graphQL<T: Decodable>(_ query: String, variables: [String: String?], token: String) async throws -> T {
        let encoded: [String: Any] = variables.mapValues { value -> Any in
            if let value { return value }
            return NSNull()
        }
        return try await graphQL(query, jsonVariables: encoded, token: token)
    }

    private func graphQL<T: Decodable>(_ query: String, jsonVariables: [String: Any], token: String) async throws -> T {
        let (envelope, response): (GraphQLEnvelope<T>, HTTPURLResponse) = try await graphQLEnvelope(
            query, jsonVariables: jsonVariables, token: token)
        if let errors = envelope.errors, !errors.isEmpty {
            try throwIfRateLimited(errors, response: response)
            throw PRBarError.graphQL(errors.map(\.message).joined(separator: "; "))
        }
        guard let payload = envelope.data else { throw PRBarError.invalidResponse("GraphQL without data") }
        return payload
    }

    /// El sobre de GraphQL tal cual (datos y errores), para quien necesita mirar los errores (el merge).
    private func graphQLEnvelope<T: Decodable>(
        _ query: String, jsonVariables: [String: Any], token: String
    ) async throws -> (GraphQLEnvelope<T>, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        applyHeaders(&request, token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": jsonVariables])
        let (data, response) = try await perform(request)
        do {
            return (try JSONCoding.decoder.decode(GraphQLEnvelope<T>.self, from: data), response)
        } catch {
            throw PRBarError.invalidResponse("GraphQL: \(error)")
        }
    }

    /// GitHub puede responder 200 con el rate limit de GraphQL como error.
    private func throwIfRateLimited(_ errors: [GraphQLErrorItem], response: HTTPURLResponse) throws {
        guard errors.contains(where: { $0.type == "RATE_LIMITED" }) else { return }
        let reset = Self.header("x-ratelimit-reset", in: response).map { Date(timeIntervalSince1970: $0) }
        throw PRBarError.rateLimited(resetAt: reset ?? now().addingTimeInterval(Self.defaultRateLimitWait))
    }

    private func restGET(_ path: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        applyHeaders(&request, token: token)
        return try await perform(request).data
    }

    private func applyHeaders(_ request: inout URLRequest, token: String) {
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PRBar", forHTTPHeaderField: "User-Agent")
    }

    private func perform(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300:
            return (data, response)
        case 401:
            throw PRBarError.unauthorized
        case 403, 429:
            // Límite primario: sin cupo hasta `x-ratelimit-reset`.
            if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0",
               let reset = Self.header("x-ratelimit-reset", in: response) {
                throw PRBarError.rateLimited(resetAt: Date(timeIntervalSince1970: reset))
            }
            // Límite secundario: `retry-after` en segundos.
            if let retryAfter = Self.header("retry-after", in: response) {
                throw PRBarError.rateLimited(resetAt: now().addingTimeInterval(retryAfter))
            }
            throw PRBarError.http(status: response.statusCode, message: Self.errorMessage(from: data))
        default:
            throw PRBarError.http(status: response.statusCode, message: Self.errorMessage(from: data))
        }
    }

    private static func header(_ name: String, in response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: name).flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func errorMessage(from data: Data) -> String {
        struct Body: Decodable { let message: String }
        if let body = try? JSONDecoder().decode(Body.self, from: data) { return body.message }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }
}
