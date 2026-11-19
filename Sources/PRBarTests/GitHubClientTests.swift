import Foundation
import PRBarCore

private let fullPage = """
{"data":{"repository":{"defaultBranchRef":{"name":"develop"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"number":482,"title":"Add rate limiting","url":"https://github.com/o/r/pull/482","isDraft":false,
  "createdAt":"2026-11-17T10:00:00Z","updatedAt":"2026-11-18T09:00:00Z","additions":214,"deletions":38,
  "baseRefName":"develop","headRefName":"feature/rate","headRefOid":"deadbeef","reviewDecision":"CHANGES_REQUESTED",
  "author":{"login":"juan","avatarUrl":"https://avatars.githubusercontent.com/u/1","__typename":"User"},
  "reviewRequests":{"nodes":[{"requestedReviewer":{"login":"me"}},{"requestedReviewer":{}}]},
  "reviews":{"nodes":[
    {"author":{"login":"ana","__typename":"User"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-17T12:00:00Z","commit":{"oid":"c0ffee"}},
    {"author":{"login":"me","__typename":"User"},"state":"PENDING","submittedAt":null,"commit":null}]},
  "comments":{"nodes":[
    {"author":{"login":"codecov","__typename":"Bot"},"createdAt":"2026-11-17T11:00:00Z"},
    {"author":null,"createdAt":"2026-11-17T11:30:00Z"}]},
  "commits":{"nodes":[{"commit":{"committedDate":"2026-11-18T08:00:00Z","statusCheckRollup":{"state":"FAILURE"}}}]}}
]}}}}
"""

private func minimalNode(_ number: Int) -> String {
    """
    {"number":\(number),"title":"PR \(number)","url":"https://github.com/o/r/pull/\(number)","isDraft":false,
     "createdAt":"2026-11-17T10:00:00Z","updatedAt":"2026-11-17T10:00:00Z","additions":1,"deletions":1,
     "baseRefName":"develop","headRefName":"f","headRefOid":"x","reviewDecision":null,
     "author":{"login":"juan","__typename":"User"},
     "reviewRequests":{"nodes":[]},"reviews":{"nodes":[]},"comments":{"nodes":[]},"commits":{"nodes":[]}}
    """
}

private func page(_ numbers: [Int], next: String?) -> String {
    let info = next.map { #"{"hasNextPage":true,"endCursor":"\#($0)"}"# } ?? #"{"hasNextPage":false,"endCursor":null}"#
    return #"{"data":{"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":\#(info),"nodes":[\#(numbers.map(minimalNode).joined(separator: ","))]}}}}"#
}

private let repo = RepoRef(owner: "o", name: "r")

private func branchesPage(_ names: [String]) -> String {
    "[" + names.map { #"{"name":"\#($0)"}"# }.joined(separator: ",") + "]"
}

enum GitHubClientTests {
    static let cases: [TestCase] = [
        TestCase("github: mapea un PR completo") {
            let transport = FakeTransport([(200, [:], fullPage)])
            let result = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "tok")
            try expectEqual(result.defaultBranch, "develop")
            try expectEqual(result.pullRequests.count, 1)
            let pr = result.pullRequests[0]
            try expectEqual(pr.id, "o/r#482")
            try expectEqual(pr.author, "juan")
            try expectEqual(pr.ciState, .failure)
            try expectEqual(pr.reviewDecision, .changesRequested)
            try expectEqual(pr.requestedReviewers, ["me"])
            try expectEqual(pr.reviews.map(\.author), ["ana"])
            try expectEqual(pr.reviews[0].commitOID, "c0ffee")
            try expectEqual(pr.comments.map(\.isBot), [true, false])
            try expectEqual(pr.comments[1].author, "ghost")
            try expectEqual(pr.lastCommitAt, ISO8601DateFormatter().date(from: "2026-11-18T08:00:00Z")!)
        },
        TestCase("github: manda el token y la query") {
            let transport = FakeTransport([(200, [:], page([1], next: nil))])
            _ = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "tok")
            try expectEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "bearer tok")
            try expectEqual(transport.requests[0].url?.absoluteString, "https://api.github.com/graphql")
            try expect(transport.bodyString(0).contains("pullRequests"))
            try expect(transport.bodyString(0).contains("commit { oid }"))
        },
        TestCase("github: pagina hasta que no hay más") {
            let transport = FakeTransport([(200, [:], page([1, 2], next: "C1")), (200, [:], page([3], next: nil))])
            let result = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "tok")
            try expectEqual(result.pullRequests.map(\.number), [1, 2, 3])
            try expect(transport.bodyString(1).contains("C1"))
        },
        TestCase("github: 401 → unauthorized") {
            let transport = FakeTransport([(401, [:], #"{"message":"Bad credentials"}"#)])
            let error = try await expectThrows { _ = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "t") }
            try expect(error as? PRBarError == .unauthorized)
        },
        TestCase("github: 403 sin cupo → rateLimited con hora de reset") {
            let transport = FakeTransport([(403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000000"], "{}")])
            let error = try await expectThrows { _ = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "t") }
            try expect(error as? PRBarError == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_000)))
        },
        TestCase("github: 200 con RATE_LIMITED → rateLimited con x-ratelimit-reset") {
            let body = #"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#
            let transport = FakeTransport([(200, ["x-ratelimit-reset": "1800000900"], body)])
            let error = try await expectThrows { _ = try await GitHubClient(transport: transport, now: { t0 }).openPullRequests(in: repo, token: "t") }
            try expect(error as? PRBarError == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_900)))
        },
        TestCase("github: 200 con RATE_LIMITED sin header → reintento en 60 s") {
            let body = #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#
            let transport = FakeTransport([(200, [:], body)])
            let error = try await expectThrows { _ = try await GitHubClient(transport: transport, now: { t0 }).openPullRequests(in: repo, token: "t") }
            try expect(error as? PRBarError == .rateLimited(resetAt: t0.addingTimeInterval(60)))
        },
        TestCase("github: 403 con retry-after (límite secundario) → rateLimited") {
            let transport = FakeTransport([(403, ["retry-after": "120"], #"{"message":"You have exceeded a secondary rate limit"}"#)])
            let error = try await expectThrows { _ = try await GitHubClient(transport: transport, now: { t0 }).openPullRequests(in: repo, token: "t") }
            try expect(error as? PRBarError == .rateLimited(resetAt: t0.addingTimeInterval(120)))
        },
        TestCase("github: 429 con retry-after → rateLimited") {
            let transport = FakeTransport([(429, ["retry-after": "30"], "{}")])
            let error = try await expectThrows { _ = try await GitHubClient(transport: transport, now: { t0 }).branches(of: repo, token: "t") }
            try expect(error as? PRBarError == .rateLimited(resetAt: t0.addingTimeInterval(30)))
        },
        TestCase("github: 403 sin headers de rate limit → http(403)") {
            let transport = FakeTransport([(403, [:], #"{"message":"Resource not accessible by integration"}"#)])
            let error = try await expectThrows { _ = try await GitHubClient(transport: transport, now: { t0 }).openPullRequests(in: repo, token: "t") }
            try expect(error as? PRBarError == .http(status: 403, message: "Resource not accessible by integration"))
        },
        TestCase("github: errores GraphQL → graphQL") {
            let body = #"{"data":{"repository":null},"errors":[{"message":"Could not resolve to a Repository"}]}"#
            let error = try await expectThrows { _ = try await GitHubClient(transport: FakeTransport([(200, [:], body)])).openPullRequests(in: repo, token: "t") }
            try expect(error as? PRBarError == .graphQL("Could not resolve to a Repository"))
        },
        TestCase("github: viewerRepositories mapea, pagina y pide repos de orgs y equipos") {
            func reposPage(_ repos: [(String, String)], next: String?) -> String {
                let info = next.map { #"{"hasNextPage":true,"endCursor":"\#($0)"}"# } ?? #"{"hasNextPage":false,"endCursor":null}"#
                let nodes = repos.map { #"{"name":"\#($0.1)","owner":{"login":"\#($0.0)"}}"# }.joined(separator: ",")
                return #"{"data":{"viewer":{"repositories":{"pageInfo":\#(info),"nodes":[\#(nodes),null]}}}}"#
            }
            let transport = FakeTransport([
                (200, [:], reposPage([("me", "dotfiles"), ("OrgX", "api")], next: "R1")),
                (200, [:], reposPage([("OrgY", "web")], next: nil)),
            ])
            let repos = try await GitHubClient(transport: transport).viewerRepositories(token: "t")
            try expectEqual(repos, [RepoRef(owner: "me", name: "dotfiles"), RepoRef(owner: "OrgX", name: "api"), RepoRef(owner: "OrgY", name: "web")])
            try expectEqual(transport.requests.count, 2)
            try expect(transport.bodyString(1).contains("R1"))
            try expect(transport.bodyString(0).contains("affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]"))
        },
        TestCase("github: usuario inexistente → nil") {
            let transport = FakeTransport([(404, [:], #"{"message":"Not Found"}"#)])
            let user = try await GitHubClient(transport: transport).user(login: "nadie", token: "t")
            try expectEqual(user, nil)
        },
        TestCase("github: login inválido no hace request") {
            let transport = FakeTransport([])
            let user = try await GitHubClient(transport: transport).user(login: "../etc", token: "t")
            try expectEqual(user, nil)
            try expectEqual(transport.requests.count, 0)
        },
        TestCase("github: ramas por REST") {
            let transport = FakeTransport([(200, [:], #"[{"name":"main"},{"name":"develop"}]"#)])
            let branches = try await GitHubClient(transport: transport).branches(of: repo, token: "t")
            try expectEqual(branches, ["main", "develop"])
            try expectEqual(transport.requests.count, 1)
            try expectEqual(transport.requests[0].url?.absoluteString, "https://api.github.com/repos/o/r/branches?per_page=100&page=1")
        },
        TestCase("github: rama por defecto por REST") {
            let transport = FakeTransport([(200, [:], #"{"name":"r","default_branch":"develop"}"#)])
            let branch = try await GitHubClient(transport: transport).defaultBranch(of: repo, token: "t")
            try expectEqual(branch, "develop")
            try expectEqual(transport.requests[0].url?.absoluteString, "https://api.github.com/repos/o/r")
        },
        TestCase("github: ramas pagina mientras vengan páginas llenas") {
            let full = branchesPage((0..<100).map { "b\($0)" })
            let transport = FakeTransport([(200, [:], full), (200, [:], branchesPage(["last"]))])
            let branches = try await GitHubClient(transport: transport).branches(of: repo, token: "t")
            try expectEqual(branches.count, 101)
            try expectEqual(branches.last, "last")
            try expectEqual(transport.requests.count, 2)
            try expectEqual(transport.requests[1].url?.absoluteString, "https://api.github.com/repos/o/r/branches?per_page=100&page=2")
        },
        TestCase("github: ramas corta en 10 páginas") {
            let full = branchesPage((0..<100).map { "b\($0)" })
            let transport = FakeTransport(Array(repeating: (200, [:], full), count: 12))
            let branches = try await GitHubClient(transport: transport).branches(of: repo, token: "t")
            try expectEqual(transport.requests.count, 10)
            try expectEqual(branches.count, 1000)
        },
        TestCase("github: viewerRepositories corta en 10 páginas") {
            let body = #"{"data":{"viewer":{"repositories":{"pageInfo":{"hasNextPage":true,"endCursor":"N"},"nodes":[{"name":"r","owner":{"login":"o"}}]}}}}"#
            let transport = FakeTransport(Array(repeating: (200, [:], body), count: 12))
            let repos = try await GitHubClient(transport: transport).viewerRepositories(token: "t")
            try expectEqual(transport.requests.count, 10)
            try expectEqual(repos.count, 10)
        },
        TestCase("github: assignableUsers mapea login, nombre y avatar") {
            let body = #"{"data":{"repository":{"assignableUsers":{"nodes":[{"login":"ana","name":"Ana Pérez","avatarUrl":"https://avatars.githubusercontent.com/u/2"},{"login":"beto","name":null,"avatarUrl":null},null]}}}}"#
            let transport = FakeTransport([(200, [:], body)])
            let users = try await GitHubClient(transport: transport).assignableUsers(of: repo, token: "t")
            try expectEqual(users, [
                GitHubUser(login: "ana", name: "Ana Pérez", avatarURL: URL(string: "https://avatars.githubusercontent.com/u/2")),
                GitHubUser(login: "beto", name: nil, avatarURL: nil),
            ])
            try expectEqual(transport.requests[0].url?.absoluteString, "https://api.github.com/graphql")
            try expect(transport.bodyString(0).contains("assignableUsers(first: 100)"))
            try expect(transport.bodyString(0).contains(#""owner":"o""#))
        },
        TestCase("github: assignableUsers sin repo → graphQL") {
            let body = #"{"data":{"repository":null}}"#
            let error = try await expectThrows { _ = try await GitHubClient(transport: FakeTransport([(200, [:], body)])).assignableUsers(of: repo, token: "t") }
            try expect(error as? PRBarError == .graphQL("Couldn't find the repo o/r"))
        },
    ]
}
