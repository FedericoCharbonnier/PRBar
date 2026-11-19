import Foundation
import PRBarCore

private let mergedBody = #"{"data":{"mergePullRequest":{"pullRequest":{"merged":true,"mergedAt":"2026-11-19T12:00:00Z"}}}}"#

private func errorBody(_ message: String, type: String) -> String {
    #"{"data":{"mergePullRequest":null},"errors":[{"type":"\#(type)","message":"\#(message)"}]}"#
}

private func merge(_ transport: FakeTransport) async throws -> Date? {
    try await GitHubClient(transport: transport, now: { t0 })
        .mergePullRequest(id: "PR_kwDOA", method: .squash, expectedHeadOid: "cafe42", token: "tok")
}

private func mergeError(_ body: String) async throws -> Error {
    try await expectThrows { _ = try await merge(FakeTransport([(200, [:], body)])) }
}

enum MergeMutationTests {
    static let cases: [TestCase] = [
        TestCase("merge mutation: manda la mutación con las variables exactas y devuelve mergedAt") {
            let transport = FakeTransport([(200, [:], mergedBody)])
            let mergedAt = try await merge(transport)
            try expectEqual(mergedAt, ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z"))
            try expectEqual(transport.requests.count, 1)
            try expectEqual(transport.requests[0].url?.absoluteString, "https://api.github.com/graphql")
            try expectEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "bearer tok")
            let body = try JSONSerialization.jsonObject(with: transport.requests[0].httpBody ?? Data()) as? [String: Any]
            let query = body?["query"] as? String ?? ""
            try expect(query.hasPrefix("mutation("))
            try expect(query.contains("mergePullRequest(input: $input)"))
            let input = (body?["variables"] as? [String: Any])?["input"] as? [String: String]
            try expectEqual(input, ["pullRequestId": "PR_kwDOA", "mergeMethod": "SQUASH", "expectedHeadOid": "cafe42"])
        },
        TestCase("merge mutation: head cambiado → headChanged") {
            let error = try await mergeError(errorBody("Head branch was modified. Review and try the merge again.", type: "UNPROCESSABLE"))
            try expectEqual(error as? MergeError, .headChanged)
            try expectEqual(error.localizedDescription, "The PR changed since you looked at it — refresh and try again.")
        },
        TestCase("merge mutation: sin permiso → forbidden con el texto de GitHub") {
            let message = "Viewer does not have permission to merge this pull request"
            let error = try await mergeError(errorBody(message, type: "FORBIDDEN"))
            try expectEqual(error as? MergeError, .forbidden(message))
        },
        TestCase("merge mutation: no se puede mergear → notMergeable") {
            let error = try await mergeError(errorBody("Pull Request is not mergeable", type: "UNPROCESSABLE"))
            try expectEqual(error as? MergeError, .notMergeable("Pull Request is not mergeable"))
            let notMerged = try await mergeError(#"{"data":{"mergePullRequest":{"pullRequest":{"merged":false,"mergedAt":null}}}}"#)
            try expectEqual(notMerged as? MergeError, .notMergeable("GitHub didn’t merge the PR"))
        },
        TestCase("merge mutation: otro error de GraphQL → other") {
            let error = try await mergeError(errorBody("Something odd", type: "INTERNAL"))
            try expectEqual(error as? MergeError, .other("Something odd"))
        },
        TestCase("merge mutation: repo con merge queue → mergeQueueRequired con un texto claro") {
            let message = "Changes must be made through the merge queue"
            let error = try await mergeError(errorBody(message, type: "UNPROCESSABLE"))
            try expectEqual(error as? MergeError, .mergeQueueRequired(message))
            try expectEqual(error.localizedDescription,
                            "This repo uses a merge queue — add the PR to the queue on GitHub. (\(message))")
        },
        TestCase("merge mutation: precedencia de classify (head > merge queue > permiso > no mergeable > otro)") {
            try expectEqual(MergeError.classify(messages: ["Head branch was modified", "merge queue"], types: ["FORBIDDEN"]), .headChanged)
            try expectEqual(MergeError.classify(messages: ["Required by the merge queue"], types: ["FORBIDDEN"]),
                            .mergeQueueRequired("Required by the merge queue"))
            try expectEqual(MergeError.classify(messages: ["Not allowed"], types: ["FORBIDDEN"]), .forbidden("Not allowed"))
            try expectEqual(MergeError.classify(messages: ["You need permission", "not mergeable"], types: ["UNPROCESSABLE"]),
                            .forbidden("You need permission; not mergeable"))
            try expectEqual(MergeError.classify(messages: ["Base branch was deleted"], types: ["UNPROCESSABLE"]),
                            .notMergeable("Base branch was deleted"))
            try expectEqual(MergeError.classify(messages: ["Expected head sha mismatch"], types: [nil]), .headChanged)
            try expectEqual(MergeError.classify(messages: ["Boom"], types: [nil]), .other("Boom"))
        },
        TestCase("merge mutation: textos de los errores nuevos") {
            try expectEqual(MergeError.unavailable("Branch is behind main").localizedDescription, "Branch is behind main")
            try expectEqual(MergeError.noLongerOpen.localizedDescription, "This PR is no longer open.")
        },
        TestCase("merge mutation: rate limit y token inválido siguen siendo PRBarError") {
            let limited = FakeTransport([(200, ["x-ratelimit-reset": "1800000900"], errorBody("API rate limit exceeded", type: "RATE_LIMITED"))])
            let rateError = try await expectThrows { _ = try await merge(limited) }
            try expectEqual(rateError as? PRBarError, .rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_900)))
            let unauthorized = try await expectThrows { _ = try await merge(FakeTransport([(401, [:], #"{"message":"Bad credentials"}"#)])) }
            try expectEqual(unauthorized as? PRBarError, .unauthorized)
        },
        TestCase("merge mutation: MergeError(_:) envuelve cualquier error") {
            try expectEqual(MergeError(PRBarError.unauthorized), .github(.unauthorized))
            try expectEqual(MergeError(MergeError.headChanged), .headChanged)
            try expectEqual(MergeError(URLError(.notConnectedToInternet)), .github(.network(URLError(.notConnectedToInternet).localizedDescription)))
        },
    ]
}
