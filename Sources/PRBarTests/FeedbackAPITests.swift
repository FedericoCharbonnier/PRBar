import Foundation
import PRBarCore

private let repo = RepoRef(owner: "o", name: "r")

private let feedbackJSON = """
{"data":{"repository":{"pullRequest":{
 "headRefName":"feature/rate","headRefOid":"deadbeef","isCrossRepository":true,
 "commits":{"nodes":[{"commit":{"committedDate":"2026-11-18T08:00:00Z"}}]},
 "reviewThreads":{"nodes":[
  {"id":"PRRT_1","isResolved":false,"isOutdated":false,"path":"a.rb","line":18,
   "comments":{"nodes":[
     {"databaseId":101,"body":"Usa la IP","createdAt":"2026-11-18T09:00:00Z","url":"https://github.com/o/r/pull/7#discussion_r101","author":{"login":"ana","__typename":"User"}},
     {"databaseId":102,"body":"Dale","createdAt":"2026-11-18T09:05:00Z","url":"https://github.com/o/r/pull/7#discussion_r102","author":{"login":"me","__typename":"User"}}]}},
  {"id":"PRRT_2","isResolved":true,"isOutdated":true,"path":"b.rb","line":null,
   "comments":{"nodes":[
     {"databaseId":201,"body":"Bot dice","createdAt":"2026-11-18T09:10:00Z","url":"https://github.com/o/r/pull/7#discussion_r201","author":{"login":"codecov","__typename":"Bot"}},
     {"databaseId":202,"body":"Fantasma","createdAt":"2026-11-18T09:11:00Z","url":"https://github.com/o/r/pull/7#discussion_r202","author":null}]}},
  {"id":"PRRT_3","isResolved":false,"isOutdated":false,"path":"c.rb","line":2,"comments":{"nodes":[]}}]},
 "reviews":{"nodes":[
  {"databaseId":900,"state":"CHANGES_REQUESTED","body":"Falta manejar errores","submittedAt":"2026-11-18T10:00:00Z","url":"https://github.com/o/r/pull/7#pullrequestreview-900","author":{"login":"ana","__typename":"User"}},
  {"databaseId":null,"state":"PENDING","body":"","submittedAt":null,"url":"https://github.com/o/r/pull/7#pullrequestreview-0","author":{"login":"me","__typename":"User"}}]}
}}}}
"""

enum FeedbackAPITests {
    static let cases: [TestCase] = [
        TestCase("feedback api: mapea hilos, bots, autor null y line null") {
            let transport = FakeTransport([(200, [:], feedbackJSON)])
            let feedback = try await GitHubClient(transport: transport).reviewFeedback(repo: repo, number: 7, token: "tok")
            try expectEqual(feedback.headRefName, "feature/rate")
            try expectEqual(feedback.headRefOid, "deadbeef")
            try expect(feedback.isCrossRepository)
            try expectEqual(feedback.lastCommitAt, Date(timeIntervalSince1970: 1_794_988_800))
            // El hilo sin comentarios no cuenta.
            try expectEqual(feedback.threads.map(\.id), ["thread:PRRT_1", "thread:PRRT_2"])
            let first = feedback.threads[0]
            try expectEqual(first.path, "a.rb")
            try expectEqual(first.line, 18)
            try expect(!first.isResolved && !first.isOutdated)
            try expectEqual(first.comments.map(\.databaseID), [101, 102])
            try expectEqual(first.replyToCommentID, 101)
            let second = feedback.threads[1]
            try expect(second.isResolved && second.isOutdated)
            try expectEqual(second.line, nil)
            try expectEqual(second.comments.map(\.author), ["codecov", "ghost"])
            try expectEqual(second.comments.map(\.isBot), [true, false])
        },
        TestCase("feedback api: mapea cuerpos de review y descarta los pendientes") {
            let transport = FakeTransport([(200, [:], feedbackJSON)])
            let feedback = try await GitHubClient(transport: transport).reviewFeedback(repo: repo, number: 7, token: "tok")
            try expectEqual(feedback.reviews.count, 1)
            let review = feedback.reviews[0]
            try expectEqual(review.state, .changesRequested)
            try expectEqual(review.item.id, "review:900")
            try expectEqual(review.item.kind, .reviewBody)
            try expectEqual(review.item.comments[0].body, "Falta manejar errores")
            try expectEqual(review.item.reviewer, "ana")
            try expectEqual(review.item.replyToCommentID, nil)
            try expectEqual(review.submittedAt, Date(timeIntervalSince1970: 1_794_996_000))
        },
        TestCase("feedback api: la query va a GraphQL con owner, name y number") {
            let transport = FakeTransport([(200, [:], feedbackJSON)])
            _ = try await GitHubClient(transport: transport).reviewFeedback(repo: repo, number: 7, token: "tok")
            let request = transport.requests[0]
            try expectEqual(request.url?.absoluteString, "https://api.github.com/graphql")
            try expectEqual(request.httpMethod, "POST")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let variables = body?["variables"] as? [String: Any]
            try expectEqual(variables?["owner"] as? String, "o")
            try expectEqual(variables?["name"] as? String, "r")
            try expectEqual(variables?["number"] as? Int, 7)
            try expect((body?["query"] as? String)?.contains("reviewThreads") == true)
        },
        TestCase("feedback api: PR inexistente es un error de GraphQL") {
            let transport = FakeTransport([(200, [:], #"{"data":{"repository":{"pullRequest":null}}}"#)])
            let error = try await expectThrows {
                _ = try await GitHubClient(transport: transport).reviewFeedback(repo: repo, number: 7, token: "tok")
            }
            guard case PRBarError.graphQL = error else { throw TestFailure(description: "se esperaba .graphQL, llegó \(error)") }
        },
        TestCase("feedback api: replyToReviewComment hace POST a /replies y devuelve html_url") {
            let transport = FakeTransport([(201, [:], #"{"html_url":"https://github.com/o/r/pull/7#discussion_r555"}"#)])
            let url = try await GitHubClient(transport: transport).replyToReviewComment(
                repo: repo, number: 7, commentID: 101, body: "Arreglado en abc123", token: "tok")
            try expectEqual(url.absoluteString, "https://github.com/o/r/pull/7#discussion_r555")
            let request = transport.requests[0]
            try expectEqual(request.httpMethod, "POST")
            try expectEqual(request.url?.absoluteString, "https://api.github.com/repos/o/r/pulls/7/comments/101/replies")
            try expectEqual(transport.bodyString(0), #"{"body":"Arreglado en abc123"}"#)
            try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "bearer tok")
        },
        TestCase("feedback api: addIssueComment hace POST a /issues/{n}/comments") {
            let transport = FakeTransport([(201, [:], #"{"html_url":"https://github.com/o/r/pull/7#issuecomment-9"}"#)])
            let url = try await GitHubClient(transport: transport).addIssueComment(repo: repo, number: 7, body: "Gracias", token: "tok")
            try expectEqual(url.absoluteString, "https://github.com/o/r/pull/7#issuecomment-9")
            let request = transport.requests[0]
            try expectEqual(request.httpMethod, "POST")
            try expectEqual(request.url?.absoluteString, "https://api.github.com/repos/o/r/issues/7/comments")
            try expectEqual(transport.bodyString(0), #"{"body":"Gracias"}"#)
        },
        TestCase("feedback api: un 2xx sin html_url devuelve la URL del PR") {
            let transport = FakeTransport([(201, [:], "{}"), (200, [:], "no es json")])
            let client = GitHubClient(transport: transport)
            let reply = try await client.replyToReviewComment(repo: repo, number: 7, commentID: 1, body: "x", token: "tok")
            let comment = try await client.addIssueComment(repo: repo, number: 7, body: "x", token: "tok")
            try expectEqual(reply.absoluteString, "https://github.com/o/r/pull/7")
            try expectEqual(comment.absoluteString, "https://github.com/o/r/pull/7")
        },
        TestCase("feedback api: un 422 se convierte en .http(422, mensaje)") {
            let transport = FakeTransport([(422, [:], #"{"message":"Validation Failed"}"#), (422, [:], #"{"message":"Nope"}"#)])
            let client = GitHubClient(transport: transport)
            let replyError = try await expectThrows {
                _ = try await client.replyToReviewComment(repo: repo, number: 7, commentID: 1, body: "x", token: "tok")
            }
            guard case PRBarError.http(let status, let message) = replyError else { throw TestFailure(description: "llegó \(replyError)") }
            try expectEqual(status, 422)
            try expectEqual(message, "Validation Failed")
            let commentError = try await expectThrows {
                _ = try await client.addIssueComment(repo: repo, number: 7, body: "x", token: "tok")
            }
            guard case PRBarError.http(let status2, _) = commentError else { throw TestFailure(description: "llegó \(commentError)") }
            try expectEqual(status2, 422)
        },
        TestCase("details api: GETs /pulls/{n} and returns the description, title and head commit") {
            let json = #"{"number":7,"title":"Validar email","body":"Agrega la validación.\r\n\r\nDetalles.","head":{"sha":"deadbeef","ref":"feature/x"},"base":{"ref":"main"},"user":{"login":"ana"}}"#
            let transport = FakeTransport([(200, [:], json)])
            let details = try await GitHubClient(transport: transport).pullRequestDetails(repo: repo, number: 7, token: "tok")
            try expectEqual(details, PRDetails(title: "Validar email", body: "Agrega la validación.\r\n\r\nDetalles.", headOid: "deadbeef"))
            let request = transport.requests[0]
            try expectEqual(request.httpMethod ?? "GET", "GET")
            try expectEqual(request.url?.absoluteString, "https://api.github.com/repos/o/r/pulls/7")
            try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "bearer tok")
        },
        TestCase("details api: a null description is empty") {
            let transport = FakeTransport([(200, [:], #"{"title":"T","body":null,"head":{"sha":"abc"}}"#)])
            let details = try await GitHubClient(transport: transport).pullRequestDetails(repo: repo, number: 7, token: "tok")
            try expectEqual(details.body, "")
            try expectEqual(details.title, "T")
        },
        TestCase("details api: a 404 is an HTTP error") {
            let transport = FakeTransport([(404, [:], #"{"message":"Not Found"}"#)])
            let error = try await expectThrows {
                _ = try await GitHubClient(transport: transport).pullRequestDetails(repo: repo, number: 7, token: "tok")
            }
            guard case PRBarError.http(404, _) = error else { throw TestFailure(description: "got \(error)") }
        },
    ]
}
