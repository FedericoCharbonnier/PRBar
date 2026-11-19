import Foundation
import PRBarCore

/// Un release como los que devuelve `UpdateChecker`.
func makeRelease(_ version: String, notes: String = "- Faster refresh") -> ReleaseInfo {
    ReleaseInfo(
        version: SemanticVersion(version)!, tag: "v\(version)", title: "PRBar \(version)", notes: notes,
        url: URL(string: "https://github.com/FedericoCharbonnier/PRBar/releases/tag/v\(version)")!, publishedAt: nil
    )
}

/// El JSON de `GET /repos/{repo}/releases/latest` (solo los campos que se leen).
func releaseJSON(
    tag: String = "v1.3.0", draft: Bool = false, prerelease: Bool = false,
    body: String = #"## What's new\n\n- Faster refresh\n- Chat with Claude"#
) -> String {
    #"""
    {"tag_name": "\#(tag)", "name": "PRBar \#(tag)", "body": "\#(body)", "draft": \#(draft), "prerelease": \#(prerelease),
     "html_url": "https://github.com/FedericoCharbonnier/PRBar/releases/tag/\#(tag)", "published_at": "2026-11-20T10:00:00Z"}
    """#
}

/// Transporte que falla como sin red.
struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

enum UpdateCheckerTests {
    static let cases: [TestCase] = [
        TestCase("update checker: lee el último release sin token") {
            let transport = FakeTransport([(200, [:], releaseJSON())])
            let checker = UpdateChecker(transport: transport, repo: "FedericoCharbonnier/PRBar")
            let release = try await checker.latestRelease()
            try expectEqual(release, ReleaseInfo(
                version: SemanticVersion(1, 3, 0), tag: "v1.3.0", title: "PRBar v1.3.0",
                notes: "## What's new\n\n- Faster refresh\n- Chat with Claude",
                url: URL(string: "https://github.com/FedericoCharbonnier/PRBar/releases/tag/v1.3.0")!,
                publishedAt: ISO8601DateFormatter().date(from: "2026-11-20T10:00:00Z")
            ))
            let request = transport.requests[0]
            try expectEqual(request.url?.absoluteString, "https://api.github.com/repos/FedericoCharbonnier/PRBar/releases/latest")
            try expectEqual(request.httpMethod, "GET")
            try expectEqual(request.value(forHTTPHeaderField: "Authorization"), nil)
            try expectEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            try expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("PRBar/") == true)
        },
        TestCase("update checker: el repo de un fork va en la URL") {
            let transport = FakeTransport([(200, [:], releaseJSON())])
            _ = try await UpdateChecker(transport: transport, repo: "acme/PRBar-fork").latestRelease()
            try expectEqual(transport.requests[0].url?.absoluteString, "https://api.github.com/repos/acme/PRBar-fork/releases/latest")
        },
        TestCase("update checker: sin releases (404) → nil") {
            let checker = UpdateChecker(transport: FakeTransport([(404, [:], #"{"message":"Not Found"}"#)]), repo: "a/b")
            let release = try await checker.latestRelease()
            try expectEqual(release, nil)
        },
        TestCase("update checker: ignora drafts, prereleases y tags que no son versión") {
            let bodies = [releaseJSON(draft: true), releaseJSON(prerelease: true), releaseJSON(tag: "v2.0.0-beta.1"),
                          releaseJSON(tag: "nightly")]
            for body in bodies {
                let release = try await UpdateChecker(transport: FakeTransport([(200, [:], body)]), repo: "a/b").latestRelease()
                try expectEqual(release, nil)
            }
        },
        TestCase("update checker: sin título ni notas usa 'PRBar X.Y.Z' y notas vacías") {
            let body = #"{"tag_name": "v1.4.0", "name": "", "body": null, "draft": false, "prerelease": false, "html_url": "https://github.com/a/b/releases/tag/v1.4.0"}"#
            let release = try await UpdateChecker(transport: FakeTransport([(200, [:], body)]), repo: "a/b").latestRelease()
            try expectEqual(release?.title, "PRBar 1.4.0")
            try expectEqual(release?.notes, "")
            try expectEqual(release?.publishedAt, nil)
        },
        TestCase("update checker: errores HTTP, límite y red") {
            let server = try await expectThrows {
                _ = try await UpdateChecker(transport: FakeTransport([(500, [:], #"{"message":"boom"}"#)]), repo: "a/b").latestRelease()
            }
            try expectEqual(server as? PRBarError, .http(status: 500, message: "boom"))
            let limited = try await expectThrows {
                _ = try await UpdateChecker(transport: FakeTransport([
                    (403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"], #"{"message":"rate limit"}"#),
                ]), repo: "a/b").latestRelease()
            }
            try expectEqual(limited as? PRBarError, .rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_000)))
            let offline = try await expectThrows {
                _ = try await UpdateChecker(transport: OfflineTransport(), repo: "a/b").latestRelease()
            }
            guard case .network? = offline as? PRBarError else { throw TestFailure(description: "expected .network, got \(offline)") }
            let garbage = try await expectThrows {
                _ = try await UpdateChecker(transport: FakeTransport([(200, [:], "<html>")]), repo: "a/b").latestRelease()
            }
            guard case .invalidResponse? = garbage as? PRBarError else { throw TestFailure(description: "got \(garbage)") }
        },
        TestCase("update checker: resumen de las notas para la notificación") {
            try expectEqual(makeRelease("1.3.0", notes: "## What's new\n\n- Faster refresh\n- Chat").summary, "Faster refresh")
            try expectEqual(makeRelease("1.3.0", notes: "  * Fixed the badge  ").summary, "Fixed the badge")
            try expectEqual(makeRelease("1.3.0", notes: "# Only a heading\n\n").summary, nil)
            let long = makeRelease("1.3.0", notes: String(repeating: "a", count: 200)).summary ?? ""
            try expectEqual(long.count, 120)
            try expect(long.hasSuffix("…"))
        },
    ]
}
