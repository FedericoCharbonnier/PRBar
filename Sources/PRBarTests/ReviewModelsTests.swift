import Foundation
import PRBarCore

enum ReviewModelsTests {
    static let cases: [TestCase] = [
        TestCase("review models: decodifica la salida de la etapa 1") {
            let json = #"{"summary":"Agrega rate limiting.","findings":[{"id":"f1","severity":"high","file":"a.rb","line":18,"title":"Usa la IP","body":"Cuerpo"},{"id":"f2","severity":"low","file":"b.rb","line":null,"title":"Nombre","body":"Otro"}]}"#
            let output = try JSONDecoder().decode(ReviewStageOneOutput.self, from: Data(json.utf8))
            try expectEqual(output.findings.map(\.severity), [.high, .low])
            try expectEqual(output.findings[1].line, nil)
        },
        TestCase("review models: el draft combina hallazgos y veredictos (sin veredicto = keep)") {
            let findings = [
                ReviewFinding(id: "f1", severity: .high, file: "a.rb", line: 1, title: "t1", body: "b1"),
                ReviewFinding(id: "f2", severity: .medium, file: "b.rb", line: 2, title: "t2", body: "b2"),
                ReviewFinding(id: "f3", severity: .low, file: "c.rb", line: 3, title: "t3", body: "b3"),
            ]
            let verdicts = [ReviewVerdict(id: "f2", verdict: .discard, reason: "No aplica")]
            let items = ReviewItem.combine(findings: findings, verdicts: verdicts)
            try expectEqual(items.map(\.keep), [true, false, true])
            try expectEqual(items[1].reason, "No aplica")
        },
        TestCase("review models: los schemas son JSON válido") {
            for schema in [ReviewSchemas.stageOne, ReviewSchemas.stageTwo] {
                try expect((try? JSONSerialization.jsonObject(with: Data(schema.utf8))) != nil)
            }
        },
        TestCase("review models: ReviewDraft round-trip") {
            let draft = ReviewDraft(
                prID: "o/r#1", repo: RepoRef(owner: "o", name: "r"), number: 1, title: "PR", url: URL(string: "https://github.com/o/r/pull/1")!,
                author: "juan", headOid: "abc", account: "me", summary: "s",
                items: [ReviewItem(finding: ReviewFinding(id: "f1", severity: .low, file: "a", line: 1, title: "t", body: "b"), keep: true, reason: nil)]
            )
            try expectEqual(try JSONCoding.decoder.decode(ReviewDraft.self, from: JSONCoding.encoder.encode(draft)), draft)
        },
        TestCase("review models: the draft keeps its language and old drafts without one decode as English") {
            let draft = ReviewDraft(
                prID: "o/r#1", repo: RepoRef(owner: "o", name: "r"), number: 1, title: "PR", url: URL(string: "https://github.com/o/r/pull/1")!,
                author: "juan", headOid: "abc", account: "me", summary: "s", items: [], language: PRLanguage(code: "pt"))
            let data = try JSONCoding.encoder.encode(draft)
            let decoded = try JSONCoding.decoder.decode(ReviewDraft.self, from: data)
            try expectEqual(decoded, draft)
            try expectEqual(decoded.language.displayName, "Portuguese")

            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            object.removeValue(forKey: "language")
            let old = try JSONCoding.decoder.decode(ReviewDraft.self, from: JSONSerialization.data(withJSONObject: object))
            try expectEqual(old.language, .english)
            try expectEqual(old.id, draft.id)
        },
    ]
}
