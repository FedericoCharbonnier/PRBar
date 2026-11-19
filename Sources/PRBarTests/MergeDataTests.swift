import Foundation
import PRBarCore

private let repo = RepoRef(owner: "o", name: "r")

private let mergePage = """
{"data":{"repository":{"defaultBranchRef":{"name":"main"},
 "squashMergeAllowed":true,"mergeCommitAllowed":false,"rebaseMergeAllowed":true,
 "viewerDefaultMergeMethod":"REBASE","deleteBranchOnMerge":true,"viewerPermission":"WRITE",
 "pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"id":"PR_kwDOA","number":42,"title":"Ship it","url":"https://github.com/o/r/pull/42","isDraft":false,
  "createdAt":"2026-11-17T10:00:00Z","updatedAt":"2026-11-18T09:00:00Z","additions":3,"deletions":1,
  "baseRefName":"main","headRefName":"feat/x","headRefOid":"cafe42","reviewDecision":"APPROVED",
  "mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","viewerCanUpdate":true,
  "author":{"login":"me","__typename":"User"},
  "reviewRequests":{"nodes":[]},"reviews":{"nodes":[]},"comments":{"nodes":[]},
  "commits":{"totalCount":3,"nodes":[{"commit":{"committedDate":"2026-11-18T08:00:00Z","statusCheckRollup":{"state":"FAILURE"}}}]}}
]}}}}
"""

/// Una respuesta sin ninguno de los campos nuevos (p. ej. de antes de este plan).
private let bareNode = """
{"data":{"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"number":1,"title":"PR 1","url":"https://github.com/o/r/pull/1","isDraft":false,
  "createdAt":"2026-11-17T10:00:00Z","updatedAt":"2026-11-17T10:00:00Z","additions":1,"deletions":1,
  "baseRefName":"main","headRefName":"f","headRefOid":"x","reviewDecision":null,
  "author":{"login":"juan","__typename":"User"},
  "reviewRequests":{"nodes":[]},"reviews":{"nodes":[]},"comments":{"nodes":[]},"commits":{"nodes":[]}}
]}}}}
"""

private let settings = RepoMergeSettings(
    squashAllowed: true, mergeCommitAllowed: false, rebaseAllowed: true, viewerDefault: .rebase,
    deleteBranchOnMerge: true, viewerPermission: "WRITE")

private func builder(_ api: FakeAPI, tokens: FakeTokens = FakeTokens()) -> SnapshotBuilder {
    SnapshotBuilder(api: api, tokens: tokens, now: { t0 })
}

enum MergeDataTests {
    static let cases: [TestCase] = [
        TestCase("merge data: mapea node id, mergeable, mergeStateStatus, commits y ajustes del repo") {
            let transport = FakeTransport([(200, [:], mergePage)])
            let result = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "tok")
            try expectEqual(result.pullRequests.count, 1)
            try expectEqual(result.pullRequests[0].merge, PRMergeState(
                nodeID: "PR_kwDOA", mergeable: .mergeable, status: .unstable, viewerCanUpdate: true, commitCount: 3))
            try expectEqual(result.pullRequests[0].reviewDecision, .approved)
            try expectEqual(result.mergeSettings, settings)
        },
        TestCase("merge data: la query pide los campos de merge") {
            let transport = FakeTransport([(200, [:], mergePage)])
            _ = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "tok")
            let body = transport.bodyString(0)
            for field in ["mergeable", "mergeStateStatus", "viewerCanUpdate", "totalCount", "squashMergeAllowed",
                          "mergeCommitAllowed", "rebaseMergeAllowed", "viewerDefaultMergeMethod", "deleteBranchOnMerge",
                          "viewerPermission"] {
                try expect(body.contains(field), "missing \(field)")
            }
        },
        TestCase("merge data: una respuesta sin los campos nuevos → desconocido y sin ajustes") {
            let transport = FakeTransport([(200, [:], bareNode)])
            let result = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "tok")
            try expectEqual(result.pullRequests[0].merge, .unknown)
            try expectEqual(result.mergeSettings, nil)
        },
        TestCase("merge data: el snapshot guarda los ajustes por cuenta y repo") {
            let api = FakeAPI(prs: ["o/r": .success(RepoPRs(defaultBranch: "develop", pullRequests: [], mergeSettings: settings))])
            let snapshot = await builder(api).build(config: config(account("me")), previous: nil)
            try expectEqual(snapshot.repoMergeSettings, ["me|o/r": settings])
        },
        TestCase("merge data: un repo que falla conserva los ajustes anteriores") {
            let previous = Snapshot(items: [], fetchedAt: t0, fetchedScopes: ["me|o/r"], repoMergeSettings: ["me|o/r": settings])
            let api = FakeAPI(prs: ["o/r": .failure(.http(status: 502, message: "Bad Gateway"))])
            let snapshot = await builder(api).build(config: config(account("me")), previous: previous)
            try expectEqual(snapshot.repoMergeSettings, ["me|o/r": settings])
        },
        TestCase("merge data: una cuenta sin token conserva solo sus ajustes") {
            let previous = Snapshot(items: [], fetchedAt: t0, fetchedScopes: ["me|o/r", "otra|o/r"],
                                    repoMergeSettings: ["me|o/r": settings, "otra|o/r": RepoMergeSettings()])
            let api = FakeAPI(prs: ["o/r": .success(RepoPRs(defaultBranch: "develop", pullRequests: []))])
            let snapshot = await builder(api, tokens: FakeTokens(failing: ["me"]))
                .build(config: config(account("me"), account("otra")), previous: previous)
            // "otra" se consultó bien y la respuesta no trajo ajustes; "me" no se pudo consultar y queda como estaba.
            try expectEqual(snapshot.repoMergeSettings, ["me|o/r": settings])
        },
    ]
}
