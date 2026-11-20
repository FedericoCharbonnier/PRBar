import Foundation
import PRBarCLIKit
import PRBarCore

private let repo = RepoRef(owner: "acme", name: "api")

/// Respuesta de `Queries.mergeDetail`; `pr` es el objeto `pullRequest`.
private func response(_ pr: String) -> String { #"{"data":{"repository":{"pullRequest":\#(pr)}}}"# }

private func detail(_ pr: String, number: Int = 42) async throws -> (MergeDetail, FakeTransport) {
    let transport = FakeTransport([(200, [:], response(pr))])
    let detail = try await GitHubClient(transport: transport).mergeDetail(repo: repo, number: number, token: "tok")
    return (detail, transport)
}

private let full = """
{"number":42,"title":"Add rate limiting","body":"Adds **limits**.","url":"https://github.com/acme/api/pull/42",
 "author":{"login":"me","avatarUrl":"https://a/me.png","__typename":"User"},
 "baseRefName":"main","headRefName":"feat/limits","headRefOid":"abcdef1234567890abcdef1234567890abcdef12",
 "additions":120,"deletions":8,"changedFiles":3,"mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE",
 "reviewDecision":"APPROVED","commits":{"totalCount":4},
 "latestOpinionatedReviews":{"nodes":[{"author":{"login":"ana","avatarUrl":null,"__typename":"User"},"state":"APPROVED","submittedAt":"2026-11-18T10:00:00Z"}]},
 "latestReviews":{"nodes":[
   {"author":{"login":"ana","avatarUrl":null,"__typename":"User"},"state":"COMMENTED","submittedAt":"2026-11-18T12:00:00Z"},
   {"author":{"login":"bob","avatarUrl":null,"__typename":"User"},"state":"COMMENTED","submittedAt":"2026-11-18T11:00:00Z"},
   {"author":{"login":"me","avatarUrl":null,"__typename":"User"},"state":"COMMENTED","submittedAt":"2026-11-18T11:30:00Z"}]},
 "reviewRequests":{"nodes":[{"requestedReviewer":{"login":"carl"}},{"requestedReviewer":{"name":"Backend"}},{"requestedReviewer":{}}]},
 "reviewThreads":{"totalCount":3,"nodes":[{"isResolved":true},{"isResolved":false},{"isResolved":false}]},
 "files":{"totalCount":3,"nodes":[
   {"path":"src/limit.ts","additions":100,"deletions":0,"changeType":"ADDED"},
   {"path":"src/app.ts","additions":20,"deletions":5,"changeType":"MODIFIED"},
   {"path":"old.ts","additions":0,"deletions":3,"changeType":"DELETED"}]},
 "statusCheckRollup":{"state":"FAILURE","contexts":{"totalCount":5,"nodes":[
   {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://ci/1",
    "startedAt":"2026-11-18T10:00:00Z","completedAt":"2026-11-18T10:02:30Z","isRequired":true},
   {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://ci/2",
    "startedAt":null,"completedAt":null,"isRequired":false},
   {"__typename":"CheckRun","name":"e2e","status":"IN_PROGRESS","conclusion":null,"detailsUrl":null,
    "startedAt":"2026-11-18T10:00:00Z","completedAt":null,"isRequired":false},
   {"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS","targetUrl":"https://legacy/1",
    "createdAt":"2026-11-18T10:00:00Z","isRequired":true}]}}}
"""

enum MergeDetailTests {
    static let cases: [TestCase] = [
        TestCase("merge detail: pide el PR con isRequired(pullRequestNumber:) y decodifica todo") {
            let (detail, transport) = try await detail(full)
            let body = try JSONSerialization.jsonObject(with: transport.requests[0].httpBody ?? Data()) as? [String: Any]
            let query = body?["query"] as? String ?? ""
            try expect(query.contains("isRequired(pullRequestNumber: $number)"))
            try expect(query.contains("latestOpinionatedReviews(first: 50)"))
            try expect(query.contains("files(first: 100)"))
            let variables = body?["variables"] as? [String: Any]
            try expectEqual(variables?["number"] as? Int, 42)
            try expectEqual(variables?["owner"] as? String, "acme")
            try expectEqual(detail.headOid, "abcdef1234567890abcdef1234567890abcdef12")
            try expectEqual(detail.body, "Adds **limits**.")
            try expectEqual(detail.commitCount, 4)
            try expectEqual(detail.status, .unstable)
            try expectEqual(detail.reviewDecision, .approved)
            try expectEqual(detail.unresolvedThreads, 2)
            try expectEqual(detail.totalThreads, 3)
            try expectEqual(detail.files.map(\.change), [.added, .modified, .removed])
            try expectEqual(detail.moreFiles, 0)
            try expectEqual(detail.checks.map(\.name), ["build", "lint", "e2e", "ci/legacy"])
            try expectEqual(detail.checks.map(\.state), [.passed, .failed, .running, .passed])
            try expectEqual(detail.checks.map(\.isRequired), [true, false, false, true])
            try expectEqual(detail.checks[0].duration, 150)
            try expectEqual(detail.checks[3].kind, .status)
            try expectEqual(detail.checks[3].url, URL(string: "https://legacy/1"))
            try expectEqual(detail.moreChecks, 1)
            try expectEqual(detail.checksSummary, "2 passed · 1 failed (not required) · 1 running")
        },
        TestCase("merge detail: la review vigente de cada reviewer (la opinión gana, sin el autor del PR)") {
            let (detail, _) = try await detail(full)
            try expectEqual(detail.reviews.map(\.author), ["bob", "ana"])
            try expectEqual(detail.reviews.map(\.state), [.commented, .approved])
            try expectEqual(detail.pendingReviewers, ["carl", "Backend"])
        },
        TestCase("merge detail: los campos que faltan dan vacíos, no un error") {
            let minimal = """
            {"number":7,"title":"T","url":"https://github.com/acme/api/pull/7","baseRefName":"main","headRefName":"x",
             "headRefOid":"1111111111111111111111111111111111111111","files":null,"statusCheckRollup":null,"reviewDecision":null}
            """
            let (detail, _) = try await detail(minimal, number: 7)
            try expectEqual(detail.body, "")
            try expectEqual(detail.checks, [])
            try expectEqual(detail.files, [])
            try expectEqual(detail.reviews, [])
            try expectEqual(detail.pendingReviewers, [])
            try expectEqual(detail.unresolvedThreads, 0)
            try expectEqual(detail.status, .unknown)
            try expectEqual(detail.reviewDecision, ReviewDecision.none)
            try expectEqual(detail.commitCount, nil)
            try expectEqual(detail.checksSummary, "No checks")
        },
        TestCase("merge detail: un PR que no existe es un error de GraphQL") {
            let transport = FakeTransport([(200, [:], #"{"data":{"repository":{"pullRequest":null}}}"#)])
            let error = try await expectThrows {
                _ = try await GitHubClient(transport: transport).mergeDetail(repo: repo, number: 9, token: "tok")
            }
            guard case PRBarError.graphQL? = error as? PRBarError else { throw TestFailure(description: "\(error)") }
        },
        TestCase("merge detail: resumen de checks (requeridos y no requeridos)") {
            func check(_ state: MergeCheck.State, required: Bool) -> MergeCheck {
                MergeCheck(name: "c", kind: .checkRun, state: state, isRequired: required)
            }
            var detail = MergeDetail.empty(number: 1, headOid: "a")
            detail.checks = [check(.passed, required: true), check(.passed, required: false), check(.failed, required: false),
                             check(.running, required: false), check(.skipped, required: false)]
            try expectEqual(detail.checksSummary, "2 passed · 1 failed (not required) · 1 running · 1 skipped")
            detail.checks = [check(.failed, required: true), check(.failed, required: true), check(.failed, required: false)]
            try expectEqual(detail.checksSummary, "3 failed (1 not required)")
            detail.checks = [check(.failed, required: true)]
            try expectEqual(detail.checksSummary, "1 failed")
        },
        TestCase("merge detail: estados de CheckRun y StatusContext") {
            try expectEqual(MergeCheck.State(checkStatus: "COMPLETED", conclusion: "TIMED_OUT"), .failed)
            try expectEqual(MergeCheck.State(checkStatus: "COMPLETED", conclusion: "STARTUP_FAILURE"), .failed)
            try expectEqual(MergeCheck.State(checkStatus: "COMPLETED", conclusion: "NEUTRAL"), .skipped)
            try expectEqual(MergeCheck.State(checkStatus: "COMPLETED", conclusion: "CANCELLED"), .skipped)
            try expectEqual(MergeCheck.State(checkStatus: "QUEUED", conclusion: nil), .running)
            try expectEqual(MergeCheck.State(statusState: "ERROR"), .failed)
            try expectEqual(MergeCheck.State(statusState: "EXPECTED"), .running)
            try expectEqual(MergeCheck.durationText(45), "45s")
            try expectEqual(MergeCheck.durationText(150), "2m 30s")
            try expectEqual(MergeCheck.durationText(3900), "1h 5m")
        },
        TestCase("merge detail: ida y vuelta en JSON y lectura tolerante") {
            let (original, _) = try await detail(full)
            let data = try JSONCoding.encoder.encode(original)
            try expectEqual(try JSONCoding.decoder.decode(MergeDetail.self, from: data), original)
            let old = try JSONCoding.decoder.decode(MergeDetail.self, from: Data(#"{"number":3,"headOid":"abc","status":"weird","checks":[{"name":1}]}"#.utf8))
            try expectEqual(old.status, .unknown)
            try expectEqual(old.checks, [])
        },
        TestCase("merge detail: pinned(head:) cambia solo el head") {
            let item = ClassifiedPR(pr: makePR(head: "new", merge: PRMergeState(nodeID: "PR_1", mergeable: .mergeable, status: .clean)), category: .readyToMerge, account: "me")
            let pinned = item.pinned(head: "old")
            try expectEqual(pinned.pr.headOid, "old")
            try expectEqual(pinned.id, item.id)
            try expectEqual(pinned.category, item.category)
            try expectEqual(pinned.pr.merge, item.pr.merge)
            try expectEqual(pinned.pr.title, item.pr.title)
        },
        TestCase("merge detail: prbar merge --preview muestra el resumen de la ventana") {
            let (detail, _) = try await detail(full)
            let state = PRMergeState(nodeID: "PR_42", mergeable: .mergeable, status: .unstable, commitCount: 4)
            let item = ClassifiedPR(pr: makePR(repo: repo, number: 42, author: "me", head: detail.headOid, merge: state),
                                    category: .readyToMerge, account: "me")
            let options = MergeOptions(availability: .enabled(note: nil), methods: [.squash], defaultMethod: .squash)
            var out = ""
            let output = Output(terminal: .plain, json: false, out: { out += $0 }, err: { _ in })
            MergePreviewRender.summary(MergePreviewInfo(item: item, method: .squash, options: options, deletesBranch: false,
                                                        phase: nil, detail: detail), output)
            for expected in ["Adds **limits**.", "Reviews  Approved", "ana · Approved", "bob · Commented", "Waiting for: carl, Backend",
                             "Checks: 2 passed · 1 failed (not required) · 1 running", "failed  lint  https://ci/2",
                             "and 1 more on GitHub", "2 unresolved conversations", "Files (3)  +120 −8",
                             "A src/limit.ts  +100 −0", "D old.ts  +0 −3"] {
                try expect(out.contains(expected), "\(expected) missing in\n\(out)")
            }
            var missing = ""
            let plain = Output(terminal: .plain, json: false, out: { missing += $0 }, err: { _ in })
            MergePreviewRender.summary(MergePreviewInfo(item: item, method: .squash, options: options, deletesBranch: false,
                                                        phase: nil, detailError: "Couldn’t load the PR’s summary: offline"), plain)
            try expect(missing.contains("Couldn’t load the PR’s summary: offline"), missing)
            try expect(!missing.contains("Reviews"), missing)
            // `--json` lo lleva completo.
            let json = String(decoding: try JSONCoding.encoder.encode(MergePreviewInfo(
                item: item, method: .squash, options: options, deletesBranch: false, phase: nil, detail: detail)), as: UTF8.self)
            try expect(json.contains("\"detail\"") && json.contains("isRequired"), json)
        },
    ]
}
