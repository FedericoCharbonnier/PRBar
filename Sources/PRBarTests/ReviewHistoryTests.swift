import Foundation
import PRBarCore

private func draft(_ number: Int = 1) -> ReviewDraft {
    ReviewDraft(
        prID: "o/r#\(number)", repo: RepoRef(owner: "o", name: "r"), number: number, title: "PR \(number)",
        url: URL(string: "https://github.com/o/r/pull/\(number)")!, author: "juan", headOid: "abc", account: "me", summary: "s",
        items: [ReviewItem(finding: ReviewFinding(id: "f1", severity: .low, file: "a.rb", line: 1, title: "t", body: "b"), keep: true, reason: nil)]
    )
}

private func record(_ number: Int, started: TimeInterval, status: ReviewRecord.Status = .ready) -> ReviewRecord {
    ReviewRecord(draft: draft(number), startedAt: Date(timeIntervalSince1970: started), status: status)
}

enum ReviewHistoryTests {
    static let cases: [TestCase] = [
        TestCase("history: guarda y lee un registro") {
            let dir = try temporaryDirectory()
            let history = ReviewHistory(directory: dir)
            var saved = record(1, started: 1_000)
            saved.finishedAt = Date(timeIntervalSince1970: 1_060)
            saved.published = ["f1": "texto final"]
            saved.generalComment = "General"
            saved.action = .requestChanges
            saved.reviewURL = URL(string: "https://github.com/o/r/pull/1#pullrequestreview-1")
            try history.save(saved)
            try expectEqual(history.all(), [saved])
            try expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(saved.id.uuidString).json").path))
        },
        TestCase("history: all() ordena del más nuevo al más viejo") {
            let history = ReviewHistory(directory: try temporaryDirectory())
            let old = record(1, started: 1_000)
            let mid = record(2, started: 2_000)
            let new = record(3, started: 3_000)
            for item in [mid, new, old] { try history.save(item) }
            try expectEqual(history.all().map(\.id), [new.id, mid.id, old.id])
        },
        TestCase("history: un archivo corrupto se ignora sin romper el resto") {
            let dir = try temporaryDirectory()
            let history = ReviewHistory(directory: dir)
            let good = record(1, started: 1_000)
            try history.save(good)
            try Data("{no es json".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))
            try expectEqual(history.all(), [good])
        },
        TestCase("history: un directorio inexistente da lista vacía") {
            let history = ReviewHistory(directory: FileManager.default.temporaryDirectory.appendingPathComponent("prbar-no-existe-\(UUID().uuidString)"))
            try expectEqual(history.all(), [])
        },
        TestCase("history: logURL queda dentro de logs/ con el uuid") {
            let dir = try temporaryDirectory()
            let id = UUID()
            let url = ReviewHistory(directory: dir).logURL(for: id)
            try expectEqual(url.deletingLastPathComponent().lastPathComponent, "logs")
            try expectEqual(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
            try expectEqual(url.lastPathComponent, "\(id.uuidString).jsonl")
        },
        TestCase("history: un mismo id se sobrescribe (ready pasa a published)") {
            let history = ReviewHistory(directory: try temporaryDirectory())
            var item = record(1, started: 1_000)
            try history.save(item)
            item.status = .published
            item.action = .comment
            try history.save(item)
            let all = history.all()
            try expectEqual(all.count, 1)
            try expectEqual(all[0].status, .published)
            try expectEqual(all[0].action, .comment)
        },
        TestCase("history: record(id:) lee un registro y devuelve nil si no existe") {
            let history = ReviewHistory(directory: try temporaryDirectory())
            let saved = record(1, started: 1_000)
            try history.save(saved)
            try history.save(record(2, started: 2_000))
            try expectEqual(history.record(id: saved.id), saved)
            try expectEqual(history.record(id: UUID()), nil)
        },
        TestCase("history: markAbandoned pasa un ready a abandoned y no toca los demás estados") {
            let history = ReviewHistory(directory: try temporaryDirectory())
            let ready = record(1, started: 1_000)
            let published = record(2, started: 2_000, status: .published)
            for item in [ready, published] { try history.save(item) }
            try history.markAbandoned(id: ready.id, at: Date(timeIntervalSince1970: 5_000))
            try history.markAbandoned(id: published.id)
            try history.markAbandoned(id: UUID())
            try expectEqual(history.record(id: ready.id)?.status, .abandoned)
            try expectEqual(history.record(id: ready.id)?.finishedAt, Date(timeIntervalSince1970: 5_000))
            try expectEqual(history.record(id: published.id), published)
        },
        TestCase("history: canReopen pide ready, sin review en curso y el PR en el mismo commit") {
            let ready = record(1, started: 1_000)
            try expect(ReviewHistory.canReopen(ready, among: [ready], currentHeadOid: "abc", reviewActive: false))
            try expect(!ReviewHistory.canReopen(ready, among: [ready], currentHeadOid: "otro", reviewActive: false))
            try expect(!ReviewHistory.canReopen(ready, among: [ready], currentHeadOid: nil, reviewActive: false))
            try expect(!ReviewHistory.canReopen(ready, among: [ready], currentHeadOid: "abc", reviewActive: true))
            for status in [ReviewRecord.Status.failed, .published, .abandoned] {
                let other = record(1, started: 1_000, status: status)
                try expect(!ReviewHistory.canReopen(other, among: [other], currentHeadOid: "abc", reviewActive: false), "\(status)")
            }
        },
        TestCase("history: canReopen es false si después se publicó una review del mismo PR y commit") {
            let ready = record(1, started: 1_000)
            var newer = record(1, started: 2_000, status: .published)
            newer.finishedAt = Date(timeIntervalSince1970: 2_100)
            try expect(!ReviewHistory.canReopen(ready, among: [newer, ready], currentHeadOid: "abc", reviewActive: false))
            // Una publicada anterior, de otro PR o de otro commit no lo impide.
            var older = record(1, started: 500, status: .published)
            older.finishedAt = Date(timeIntervalSince1970: 600)
            let otherPR = record(2, started: 2_000, status: .published)
            let base = draft(1)
            let otherCommit = ReviewRecord(
                draft: ReviewDraft(prID: base.prID, repo: base.repo, number: 1, title: base.title, url: base.url, author: base.author,
                                   headOid: "zzz", account: base.account, summary: base.summary, items: base.items),
                startedAt: Date(timeIntervalSince1970: 2_000), status: .published
            )
            try expect(ReviewHistory.canReopen(ready, among: [older, otherPR, otherCommit, ready], currentHeadOid: "abc", reviewActive: false))
        },
    ]
}
