import Foundation
import PRBarCore

@MainActor
private func queue(_ api: FakeAPI, tokens: FakeTokens = FakeTokens(), merged: Box<[MergeCompletion]> = Box([])) -> MergeQueue {
    MergeQueue(api: api, tokens: tokens, now: { t0 }, onMerged: { merged.value.append($0) })
}

private func ready(nodeID: String? = "PR_7", head: String = "cafe7") -> ClassifiedPR {
    let pr = makePR(number: 7, author: "me", head: head, decision: .approved,
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
        TestCase("merge queue: lo que corre el merge queda anotado como \"Merge r#7\" (fila de PRBar Activity)") {
            var api = FakeAPI()
            let seen = Box<ProcessActivity?>(nil)
            api.onMerge = { seen.value = ProcessActivity.current }
            let q = await queue(api)
            _ = await q.merge(ready(), method: .squash)
            try expectEqual(seen.value?.kind, .merge)
            try expectEqual(seen.value?.title, "Merge r#7")
            try expectEqual(seen.value?.prID, "o/r#7")
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
            try expectEqual(phases["o/r#7"], .failed(method: .squash, error: .headChanged))
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
            try expectEqual(phases["o/r#7"], .failed(method: .squash, error: .missingMergeData))
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
        TestCase("merge queue: el error queda con el PR que se intentó (para Retry) y su texto") {
            var api = FakeAPI()
            api.mergeResult = .failure(MergeError.headChanged)
            let q = await queue(api)
            _ = await q.merge(ready(head: "old"), method: .merge)
            let failure = await q.failure(prID: "o/r#7")
            try expectEqual(failure, MergeFailure(item: ready(head: "old"), method: .merge, error: .headChanged))
            let phase = await q.phases["o/r#7"]
            try expectEqual(phase?.message, MergeError.headChanged.localizedDescription)
            await q.dismiss(prID: "o/r#7")
            let cleared = await q.failure(prID: "o/r#7")
            try expectEqual(cleared, nil)
        },
        TestCase("merge queue: precheck rechaza sin llamar a GitHub") {
            let api = FakeAPI()
            let q = await queue(api)
            let result = await q.merge(ready(), method: .squash, precheck: .unavailable("This PR isn’t ready to merge"))
            try expectEqual(result, .failure(.unavailable("This PR isn’t ready to merge")))
            try expectEqual(api.mergeCalls.value.count, 0)
            let phase = await q.phases["o/r#7"]
            try expectEqual(phase, .failed(method: .squash, error: .unavailable("This PR isn’t ready to merge")))
        },
        TestCase("merge queue: reject muestra el error salvo con un merge en curso o hecho") {
            let q = await queue(FakeAPI())
            await q.reject(ready(), method: nil, error: .blocked("Installing an update"))
            let failed = await q.phases["o/r#7"]
            try expectEqual(failed, .failed(method: nil, error: .blocked("Installing an update")))
            await q.dismiss(prID: "o/r#7")
            _ = await q.merge(ready(), method: .squash)
            await q.reject(ready(), method: .squash, error: .unavailable("x"))
            let merged = await q.phases["o/r#7"]
            try expectEqual(merged, .merged(.squash))
        },
        TestCase("merge queue: un PR que ya no está y GitHub dice mergeado → Merged y avisa (Slack)") {
            var api = FakeAPI()
            api.details = .success(PRDetails(title: "PR", body: "", headOid: "cafe7", state: .merged, mergedAt: at(3)))
            let merged = Box<[MergeCompletion]>([])
            let q = await queue(api, merged: merged)
            await q.resolveMissing(MergeFailure(item: ready(), method: .rebase, error: .github(.network("offline"))))
            let phase = await q.phases["o/r#7"]
            try expectEqual(phase, .merged(.rebase))
            try expectEqual(merged.value, [MergeCompletion(item: ready(), method: .rebase, mergedAt: at(3))])
            try expectEqual(api.detailsTokens.value, ["tok-me"])
            try expectEqual(api.mergeCalls.value.count, 0)
        },
        TestCase("merge queue: un PR que ya no está, cerrado o abierto, o sin respuesta → error visible") {
            let cases: [(Result<PRDetails, PRBarError>, MergeError)] = [
                (.success(PRDetails(title: "", body: "", headOid: nil, state: .closed)), .noLongerOpen),
                (.success(PRDetails(title: "", body: "", headOid: nil, state: .open)),
                 .unavailable("This PR isn’t in PRBar’s list anymore — refresh and try again.")),
                (.failure(.network("offline")), .github(.network("offline"))),
            ]
            for (details, expected) in cases {
                var api = FakeAPI()
                api.details = details
                let merged = Box<[MergeCompletion]>([])
                let q = await queue(api, merged: merged)
                await q.resolveMissing(MergeFailure(item: ready(), method: .squash, error: .other("x")))
                let phase = await q.phases["o/r#7"]
                try expectEqual(phase, .failed(method: .squash, error: expected))
                try expectEqual(merged.value.count, 0)
            }
        },
        TestCase("merge queue: mientras se instala una actualización no llama a GitHub") {
            let api = FakeAPI()
            let reason = Box<String?>("Installing an update")
            let q = await MergeQueue(api: api, tokens: FakeTokens(), now: { t0 }, blockedReason: { reason.value })
            let result = await q.merge(ready(), method: .squash)
            try expectEqual(result, .failure(.blocked("Installing an update")))
            try expectEqual(api.mergeCalls.value.count, 0)
            let phases = await q.phases
            try expectEqual(phases["o/r#7"], .failed(method: .squash, error: .blocked("Installing an update")))
            reason.value = nil
            await q.dismiss(prID: "o/r#7")
            _ = await q.merge(ready(), method: .squash)
            try expectEqual(api.mergeCalls.value.count, 1)
        },
    ]
}
