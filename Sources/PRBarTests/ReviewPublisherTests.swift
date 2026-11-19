import Foundation
import PRBarCore

private let repo = RepoRef(owner: "o", name: "r")

private let patchA = """
@@ -1,3 +1,4 @@
 context1
-removed
+added1
+added2
 context2
@@ -10,2 +11,3 @@
 ctx10
+new12
 ctx11
"""

private let lineMap = DiffLineMap(files: [PRFile(filename: "a.rb", patch: patchA), PRFile(filename: "img.png", patch: nil)])

private func draft(head: String = "abc123") -> ReviewDraft {
    ReviewDraft(prID: "o/r#7", repo: repo, number: 7, title: "PR", url: URL(string: "https://github.com/o/r/pull/7")!,
                author: "juan", headOid: head, account: "me", summary: "s", items: [])
}

private func finding(_ id: String, file: String = "a.rb", line: Int?) -> ReviewFinding {
    ReviewFinding(id: id, severity: .medium, file: file, line: line, title: "t", body: "b")
}

private let submission = ReviewSubmission(
    commitID: "abc123", event: .requestChanges, body: "General",
    comments: [.init(path: "a.rb", line: 2, body: "Ojo acá")]
)

private let reviewResponse = #"{"id":9,"html_url":"https://github.com/o/r/pull/7#pullrequestreview-9"}"#

private func filesJSON(_ count: Int, from start: Int = 0) -> String {
    let items = (start..<start + count).map { #"{"filename":"f\#($0).swift","patch":"@@ -1 +1 @@\n+x"}"# }
    return "[" + items.joined(separator: ",") + "]"
}

enum ReviewPublisherTests {
    static let cases: [TestCase] = [
        TestCase("diff map: líneas agregadas, de contexto y borradas en dos hunks") {
            // Hunk 1 (+1,4): contexto=1, borrada (sin línea), agregadas=2,3, contexto=4. Hunk 2 (+11,3): 11, 12 (agregada), 13.
            for line in [1, 2, 3, 4, 11, 12, 13] {
                try expect(lineMap.contains(file: "a.rb", line: line), "línea \(line) debería ser comentable")
            }
            for line in [0, 5, 10, 14] {
                try expect(!lineMap.contains(file: "a.rb", line: line), "línea \(line) no debería ser comentable")
            }
            try expect(!lineMap.contains(file: "otro.rb", line: 1))
        },
        TestCase("diff map: un archivo sin patch no tiene líneas") {
            try expect(!lineMap.contains(file: "img.png", line: 1))
        },
        TestCase("diff map: ignora los encabezados antes del primer @@") {
            let patch = "diff --git a/x.rb b/x.rb\nindex 1..2 100644\n--- a/x.rb\n+++ b/x.rb\n@@ -1,2 +1,3 @@\n uno\n+dos\n tres"
            try expectEqual(DiffLineMap.commentableLines(in: patch), [1, 2, 3])
        },
        TestCase("diff map: el \\n final no agrega una línea de contexto fantasma") {
            let patch = "@@ -1,2 +1,2 @@\n uno\n+dos\n"
            try expectEqual(DiffLineMap.commentableLines(in: patch), [1, 2])
        },
        TestCase("diff map: una línea vacía dentro del hunk no cuenta como contexto") {
            let patch = "@@ -1,2 +1,3 @@\n uno\n\n+dos\n tres"
            try expectEqual(DiffLineMap.commentableLines(in: patch), [1, 2, 3])
        },
        TestCase("diff map: \\ No newline at end of file no cuenta como línea") {
            let patch = "@@ -1,2 +1,2 @@\n uno\n-dos\n\\ No newline at end of file\n+dos\n\\ No newline at end of file"
            try expectEqual(DiffLineMap.commentableLines(in: patch), [1, 2])
        },
        TestCase("diff map: un archivo borrado no tiene líneas comentables") {
            let map = DiffLineMap(files: [PRFile(filename: "viejo.rb", patch: "@@ -1,3 +0,0 @@\n-a\n-b\n-c\n")])
            for line in 0...3 { try expect(!map.contains(file: "viejo.rb", line: line), "línea \(line)") }
        },
        TestCase("diff map: un archivo renombrado se busca por el nombre nuevo") {
            let map = DiffLineMap(files: [PRFile(filename: "nuevo/nombre.rb", patch: "@@ -4,3 +4,4 @@\n ctx\n+agregada\n ctx\n ctx")])
            try expect(map.contains(file: "nuevo/nombre.rb", line: 5))
            try expect(!map.contains(file: "viejo/nombre.rb", line: 5))
        },
        TestCase("diff map: normaliza ./ y el prefijo absoluto del worktree en las rutas de los hallazgos") {
            let worktree = URL(fileURLWithPath: "/Users/me/Library/Caches/PRBar/worktrees/r-7-1700000000-0a1b2c3d")
            try expectEqual(DiffLineMap.normalizePath("./a.rb"), "a.rb")
            try expectEqual(DiffLineMap.normalizePath("././lib/a.rb"), "lib/a.rb")
            try expectEqual(DiffLineMap.normalizePath(" lib/a.rb\n"), "lib/a.rb")
            try expectEqual(DiffLineMap.normalizePath(worktree.path + "/lib/a.rb", worktree: worktree), "lib/a.rb")
            try expectEqual(DiffLineMap.normalizePath("/private" + worktree.path + "/lib/a.rb", worktree: worktree), "lib/a.rb")
            try expectEqual(DiffLineMap.normalizePath("/etc/hosts", worktree: worktree), "/etc/hosts")
            try expect(lineMap.contains(file: "./a.rb", line: 2))
        },
        TestCase("publisher: un hallazgo con ./ en la ruta va inline con la ruta normalizada") {
            let selected = [SelectedComment(finding: finding("1", file: "./a.rb", line: 2), body: "x")]
            let result = try ReviewPublisher.build(draft: draft(), selected: selected, generalComment: "", event: .comment, lineMap: lineMap)
            try expectEqual(result.comments, [.init(path: "a.rb", line: 2, body: "x")])
        },
        TestCase("publisher: comentarios en el diff van inline y el commit es headOid") {
            let result = try ReviewPublisher.build(
                draft: draft(head: "deadbeef"),
                selected: [SelectedComment(finding: finding("f1", line: 2), body: "  Usá otra cosa  ")],
                generalComment: "", event: .comment, lineMap: lineMap)
            try expectEqual(result.comments, [.init(path: "a.rb", line: 2, body: "Usá otra cosa")])
            try expectEqual(result.body, "")
            try expectEqual(result.commitID, "deadbeef")
            try expectEqual(result.event, .comment)
        },
        TestCase("publisher: fuera del diff o sin línea van al body, con el general primero") {
            let result = try ReviewPublisher.build(
                draft: draft(),
                selected: [
                    SelectedComment(finding: finding("f1", line: 99), body: "texto"),
                    SelectedComment(finding: finding("f2", file: "b.rb", line: nil), body: "otro"),
                    SelectedComment(finding: finding("f3", line: 2), body: "inline"),
                ],
                generalComment: " General ", event: .requestChanges, lineMap: lineMap)
            try expectEqual(result.body, "General\n\n**a.rb:99** — texto\n\n**b.rb** — otro")
            try expectEqual(result.comments.count, 1)
        },
        TestCase("publisher: con un mapa vacío (PR desactualizado) todo va al body") {
            let selected = [
                SelectedComment(finding: finding("1", line: 2), body: "inline normalmente"),
                SelectedComment(finding: finding("2", line: 12), body: "otro"),
            ]
            let result = try ReviewPublisher.build(
                draft: draft(), selected: selected, generalComment: "General", event: .comment, lineMap: DiffLineMap(files: [])
            )
            try expectEqual(result.comments, [])
            try expectEqual(result.body, "General\n\n**a.rb:2** — inline normalmente\n\n**a.rb:12** — otro")
        },
        TestCase("publisher: un 422 con comentarios inline ofrece reintentar todo en el body") {
            let unprocessable = PRBarError.http(status: 422, message: "Unprocessable Entity")
            try expect(ReviewPublisher.canRetryInBody(after: unprocessable, submission: submission))
            let bodyOnly = ReviewSubmission(commitID: "abc123", event: .comment, body: "x", comments: [])
            try expect(!ReviewPublisher.canRetryInBody(after: unprocessable, submission: bodyOnly))
            try expect(!ReviewPublisher.canRetryInBody(after: PRBarError.http(status: 500, message: "x"), submission: submission))
            try expect(!ReviewPublisher.canRetryInBody(after: PRBarError.unauthorized, submission: submission))
        },
        TestCase("publisher: un texto vacío se ignora") {
            let result = try ReviewPublisher.build(
                draft: draft(),
                selected: [SelectedComment(finding: finding("f1", line: 2), body: "  \n "), SelectedComment(finding: finding("f2", line: 3), body: "ok")],
                generalComment: "", event: .comment, lineMap: lineMap)
            try expectEqual(result.comments.map(\.line), [3])
        },
        TestCase("publisher: COMMENT sin nada lanza emptyReview") {
            let error = try await expectThrows {
                _ = try ReviewPublisher.build(
                    draft: draft(), selected: [SelectedComment(finding: finding("f1", line: 2), body: " ")],
                    generalComment: " ", event: .comment, lineMap: lineMap)
            }
            try expectEqual(error as? PRBarError, .emptyReview)
            try expectEqual((error as? PRBarError)?.errorDescription, "Select at least one comment or write a general one.")
        },
        TestCase("publisher: REQUEST_CHANGES sin nada lanza emptyReview") {
            let error = try await expectThrows {
                _ = try ReviewPublisher.build(draft: draft(), selected: [], generalComment: "", event: .requestChanges, lineMap: lineMap)
            }
            try expectEqual(error as? PRBarError, .emptyReview)
        },
        TestCase("publisher: APPROVE sin nada es válido") {
            let result = try ReviewPublisher.build(draft: draft(), selected: [], generalComment: "", event: .approve, lineMap: lineMap)
            try expectEqual(result.event, .approve)
            try expectEqual(result.body, "")
            try expectEqual(result.comments, [])
        },
        TestCase("github: submitReview manda método, URL y JSON, y devuelve html_url") {
            let transport = FakeTransport([(200, [:], reviewResponse)])
            let url = try await GitHubClient(transport: transport).submitReview(repo: repo, number: 7, submission: submission, token: "tok")
            try expectEqual(url.absoluteString, "https://github.com/o/r/pull/7#pullrequestreview-9")
            let request = transport.requests[0]
            try expectEqual(request.httpMethod, "POST")
            try expectEqual(request.url?.absoluteString, "https://api.github.com/repos/o/r/pulls/7/reviews")
            try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "bearer tok")
            let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            try expectEqual(json?["commit_id"] as? String, "abc123")
            try expectEqual(json?["event"] as? String, "REQUEST_CHANGES")
            try expectEqual(json?["body"] as? String, "General")
            let comments = json?["comments"] as? [[String: Any]]
            try expectEqual(comments?.count, 1)
            try expectEqual(comments?[0]["path"] as? String, "a.rb")
            try expectEqual(comments?[0]["line"] as? Int, 2)
            try expectEqual(comments?[0]["side"] as? String, "RIGHT")
            try expectEqual(comments?[0]["body"] as? String, "Ojo acá")
        },
        TestCase("github: submitReview con 422 lanza http(422) con el mensaje de GitHub") {
            let transport = FakeTransport([(422, [:], #"{"message":"Unprocessable Entity"}"#)])
            let error = try await expectThrows {
                _ = try await GitHubClient(transport: transport).submitReview(repo: repo, number: 7, submission: submission, token: "tok")
            }
            try expectEqual(error as? PRBarError, .http(status: 422, message: "Unprocessable Entity"))
        },
        TestCase("github: submitReview con 2xx sin html_url cuenta como publicada y usa la URL del PR") {
            let transport = FakeTransport([(200, [:], #"{"id":9}"#)])
            let url = try await GitHubClient(transport: transport).submitReview(repo: repo, number: 7, submission: submission, token: "tok")
            try expectEqual(url.absoluteString, "https://github.com/o/r/pull/7")
            try expectEqual(transport.requests.count, 1)
        },
        TestCase("github: submitReview con 2xx y cuerpo ilegible cuenta como publicada") {
            for body in ["", "no es json", #"{"html_url":"no es una url válida ::"}"#] {
                let transport = FakeTransport([(201, [:], body)])
                let url = try await GitHubClient(transport: transport).submitReview(repo: repo, number: 7, submission: submission, token: "tok")
                try expect(url.absoluteString.hasPrefix("https://github.com/o/r/pull/7"), "\(body) → \(url)")
            }
        },
        TestCase("github: submitReview con 401 lanza unauthorized") {
            let transport = FakeTransport([(401, [:], "{}")])
            let error = try await expectThrows {
                _ = try await GitHubClient(transport: transport).submitReview(repo: repo, number: 7, submission: submission, token: "tok")
            }
            try expectEqual(error as? PRBarError, .unauthorized)
        },
        TestCase("github: pullRequestFiles pagina (100 + 3 archivos = 2 requests)") {
            let transport = FakeTransport([(200, [:], filesJSON(100)), (200, [:], filesJSON(3, from: 100))])
            let files = try await GitHubClient(transport: transport).pullRequestFiles(repo: repo, number: 7, token: "tok")
            try expectEqual(files.count, 103)
            try expectEqual(transport.requests.count, 2)
            try expectEqual(transport.requests[0].url?.absoluteString, "https://api.github.com/repos/o/r/pulls/7/files?per_page=100&page=1")
            try expectEqual(transport.requests[1].url?.absoluteString, "https://api.github.com/repos/o/r/pulls/7/files?per_page=100&page=2")
            try expectEqual(files[0], PRFile(filename: "f0.swift", patch: "@@ -1 +1 @@\n+x"))
        },
        TestCase("github: pullRequestFiles acepta archivos sin patch") {
            let transport = FakeTransport([(200, [:], #"[{"filename":"img.png"}]"#)])
            let files = try await GitHubClient(transport: transport).pullRequestFiles(repo: repo, number: 7, token: "tok")
            try expectEqual(files, [PRFile(filename: "img.png", patch: nil)])
            try expectEqual(transport.requests.count, 1)
        },
    ]
}
