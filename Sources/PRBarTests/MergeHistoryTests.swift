import Foundation
import PRBarCore

private func record(_ number: Int, startedAt: Date) -> MergeRecord {
    MergeRecord(prID: "acme/api#\(number)", account: "me", repo: RepoRef(owner: "acme", name: "api"), number: number,
                title: "PR \(number)", url: URL(string: "https://github.com/acme/api/pull/\(number)")!, startedAt: startedAt)
}

enum MergeHistoryTests {
    static let cases: [TestCase] = [
        TestCase("merge history: guarda, lista del más nuevo al más viejo y lee uno") {
            let history = MergeHistory(historyDir: try temporaryDirectory())
            var first = record(1, startedAt: t0)
            first.status = .merged
            first.method = .squash
            first.headOid = "abc"
            first.finishedAt = at(1)
            var chat = ChatSession(prID: "acme/api#1", kind: .review)
            chat.messages = [ChatMessage(role: .user, text: "hola", createdAt: t0)]
            first.chat = chat
            try history.save(first)
            try history.save(record(2, startedAt: at(60)))
            try expectEqual(history.all().map(\.number), [2, 1])
            try expectEqual(history.record(id: first.id), first)
            try expectEqual(history.record(id: UUID()), nil)
            try expectEqual(history.directory.lastPathComponent, "merge")
            try expectEqual(history.logURL(for: first.id).deletingLastPathComponent().lastPathComponent, "logs")
        },
        TestCase("merge history: un mismo id se sobrescribe") {
            let history = MergeHistory(historyDir: try temporaryDirectory())
            var item = record(3, startedAt: t0)
            try history.save(item)
            item.status = .failed
            item.errorMessage = "The PR changed since you looked at it — refresh and try again."
            try history.save(item)
            try expectEqual(history.all(), [item])
        },
        TestCase("merge history: decodificación tolerante (estado y método desconocidos, chat roto)") {
            let id = UUID()
            let json = #"{"id":"\#(id.uuidString)","prID":"o/r#1","account":"me","repo":{"owner":"o","name":"r"},"number":1,"url":"https://github.com/o/r/pull/1","startedAt":"2026-11-19T10:00:00Z","status":"queued","method":"octopus","chat":{"broken":true}}"#
            let decoded = try JSONCoding.decoder.decode(MergeRecord.self, from: Data(json.utf8))
            try expectEqual(decoded.id, id)
            try expectEqual(decoded.status, .open)
            try expectEqual(decoded.method, nil)
            try expectEqual(decoded.chat, nil)
            try expectEqual(decoded.title, "")
        },
        TestCase("merge history: el registro de un PR del snapshot") {
            let item = ClassifiedPR(pr: makePR(number: 9, author: "me"), category: .readyToMerge, account: "me")
            let made = MergeRecord(item: item, startedAt: t0)
            try expectEqual(made.prID, "o/r#9")
            try expectEqual(made.account, "me")
            try expectEqual(made.status, .open)
            try expectEqual(made.url, item.pr.url)
        },
        TestCase("merge history: la CLI ve el merge (lista, búsqueda y detalle con método, head y chat)") {
            var item = record(42, startedAt: t0)
            item.status = .merged
            item.method = .rebase
            item.headOid = "abcdef1234"
            var chat = ChatSession(prID: item.prID, kind: .merge)
            chat.messages = [ChatMessage(role: .user, text: "Safe?", createdAt: t0),
                             ChatMessage(role: .assistant, text: "Yes.", createdAt: t0)]
            item.chat = chat
            let info = HistoryEntryInfo(merge: item)
            try expectEqual(info.kind, .merge)
            try expectEqual(info.status, "merged")
            try expect(info.matches("#42"))
            try expect(info.matches("PR 42"))
            let detail = HistoryDetail(merge: item, logPath: nil)
            try expectEqual(detail.mergeMethod, .rebase)
            try expectEqual(detail.headOid, "abcdef1234")
            try expectEqual(detail.chat?.kind, "merge")
            try expectEqual(detail.chat?.messages.count, 2)
            try expectEqual(HistoryDetail(merge: record(43, startedAt: t0), logPath: nil).chat, nil)
        },
    ]
}
