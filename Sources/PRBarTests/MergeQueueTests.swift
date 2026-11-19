import Foundation
import PRBarCore

@MainActor
private func queue(_ api: FakeAPI, tokens: FakeTokens = FakeTokens(), merged: Box<[MergeCompletion]> = Box([])) -> MergeQueue {
    MergeQueue(api: api, tokens: tokens, now: { t0 }, onMerged: { merged.value.append($0) })
}

private func ready(nodeID: String? = "PR_7") -> ClassifiedPR {
    let pr = makePR(number: 7, author: "me", head: "cafe7", decision: .approved,
                    merge: PRMergeState(nodeID: nodeID, mergeable: .mergeable, status: .clean))
    return ClassifiedPR(pr: pr, category: .readyToMerge, account: "me")
}

enum MergeQueueTests {
    static let cases: [TestCase] = [
        TestCase("merge queue: mergea con el head que se mostró, con el token de la cuenta, y avisa") {
            var api = FakeAPI()
            api.mergeResult = .success(at(5))
            let merged = Box<[MergeCompletion]>([])
            let q = await queue(api, merged: merged)
            let result = await q.merge(ready(), method: .squash)
            try expectEqual(try result.get().mergedAt, at(5))
            let calls = api.mergeCalls.value
            try expectEqual(calls.count, 1)
            try expectEqual(calls[0].id, "PR_7")
            try expectEqual(calls[0].method, .squash)
            try expectEqual(calls[0].expectedHeadOid, "cafe7")
            try expectEqual(calls[0].token, "tok-me")
            let phases = await q.phases
            try expectEqual(phases["o/r#7"], .merged(.squash))
            try expectEqual(merged.value.map(\.item.id), ["o/r#7"])
            try expectEqual(merged.value.map(\.method), [.squash])
        },
        TestCase("merge queue: sin mergedAt usa la hora actual") {
            let q = await queue(FakeAPI())
            let result = await q.merge(ready(), method: .rebase)
            try expectEqual(try result.get().mergedAt, t0)
        },
        TestCase("merge queue: un error queda en la fila con el texto y no avisa") {
            var api = FakeAPI()
            api.mergeResult = .failure(MergeError.headChanged)
            let merged = Box<[MergeCompletion]>([])
            let q = await queue(api, merged: merged)
            let result = await q.merge(ready(), method: .squash)
            try expectEqual(result, .failure(.headChanged))
            let phases = await q.phases
            try expectEqual(phases["o/r#7"], .failed(method: .squash, message: MergeError.headChanged.localizedDescription))
            try expectEqual(merged.value.count, 0)
        },
        TestCase("merge queue: sin token no llama a GitHub") {
            let api = FakeAPI()
            let q = await queue(api, tokens: FakeTokens(failing: ["me"]))
            let result = await q.merge(ready(), method: .squash)
            try expectEqual(result, .failure(.github(.unauthorized)))
            try expectEqual(api.mergeCalls.value.count, 0)
        },
        TestCase("merge queue: sin node id no llama a GitHub") {
            let api = FakeAPI()
            let q = await queue(api)
            let result = await q.merge(ready(nodeID: nil), method: .squash)
            try expectEqual(result, .failure(.missingMergeData))
            try expectEqual(api.mergeCalls.value.count, 0)
            let phases = await q.phases
            try expectEqual(phases["o/r#7"], .failed(method: .squash, message: MergeError.missingMergeData.localizedDescription))
        },
        TestCase("merge queue: un segundo merge mientras corre el primero se rechaza; uno ya mergeado también") {
            let holder = Box<MergeQueue?>(nil)
            let second = Box<Result<MergeCompletion, MergeError>?>(nil)
            var api = FakeAPI()
            api.onMerge = {
                let result = await holder.value?.merge(ready(), method: .merge)
                second.value = result
            }
            let q = await queue(api)
            holder.value = q
            _ = await q.merge(ready(), method: .squash)
            try expectEqual(second.value, .failure(.alreadyInProgress))
            let again = await q.merge(ready(), method: .squash)
            try expectEqual(again, .failure(.alreadyMerged))
            try expectEqual(api.mergeCalls.value.count, 1)
        },
        TestCase("merge queue: dismiss borra un error; prune descarta los PRs que ya no están") {
            var api = FakeAPI()
            api.mergeResult = .failure(MergeError.forbidden("no"))
            let q = await queue(api)
            _ = await q.merge(ready(), method: .squash)
            await q.dismiss(prID: "o/r#7")
            let afterDismiss = await q.phases
            try expectEqual(afterDismiss, [:])
            _ = await q.merge(ready(), method: .squash)
            await q.prune(keeping: ["o/r#7"])
            let kept = await q.phases
            try expectEqual(kept.count, 1)
            await q.prune(keeping: [])
            let pruned = await q.phases
            try expectEqual(pruned, [:])
        },
    ]
}
