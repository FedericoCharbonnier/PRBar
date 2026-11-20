import Foundation
import PRBarCore

private func detail(_ head: String, checks: [MergeCheck] = []) -> MergeDetail {
    var detail = MergeDetail.empty(number: 7, headOid: head)
    detail.checks = checks
    return detail
}

/// Una ventana cuyo `fetch` devuelve, en orden, `results` (el último se repite).
@MainActor
private func window(_ results: [Result<MergeDetail, PRBarError>]) -> (MergeWindowModel, Box<Int>) {
    let calls = Box(0)
    let queue = Box(results)
    let model = MergeWindowModel(prID: "o/r#7", recordID: UUID()) {
        calls.value += 1
        let next = queue.value.count > 1 ? queue.value.removeFirst() : queue.value[0]
        return try next.get()
    }
    return (model, calls)
}

private let clean = PRMergeState(nodeID: "PR_7", mergeable: .mergeable, status: .clean)
private let ready = ClassifiedPR(pr: makePR(number: 7, author: "me", head: "aaa", decision: .approved, merge: clean),
                                 category: .readyToMerge, account: "me")
private let squashOnly = MergeOptions(availability: .enabled(note: nil), methods: [.squash], defaultMethod: .squash)

enum MergeWindowTests {
    static let cases: [TestCase] = [
        TestCase("merge window: la primera carga fija el head mostrado") { @MainActor in
            let (window, calls) = window([.success(detail("aaa"))])
            try expectEqual(window.shownHead, nil)
            await window.load()
            try expectEqual(window.shownHead, "aaa")
            try expectEqual(window.detail?.headOid, "aaa")
            try expect(!window.isStale)
            try expect(!window.isLoading)
            try expectEqual(calls.value, 1)
        },
        TestCase("merge window: refresh con otro head no reemplaza lo mostrado; Reload sí") { @MainActor in
            let (window, _) = window([.success(detail("aaa")), .success(detail("bbb"))])
            await window.load()
            await window.refresh()
            try expectEqual(window.shownHead, "aaa")
            try expectEqual(window.detail?.headOid, "aaa")
            try expectEqual(window.newerHead, "bbb")
            try expect(window.isStale)
            await window.reload()
            try expectEqual(window.shownHead, "bbb")
            try expectEqual(window.detail?.headOid, "bbb")
            try expect(!window.isStale)
        },
        TestCase("merge window: refresh con el mismo head actualiza el detalle") { @MainActor in
            let failing = MergeCheck(name: "lint", kind: .checkRun, state: .failed, isRequired: false)
            let (window, _) = window([.success(detail("aaa")), .success(detail("aaa", checks: [failing]))])
            await window.load()
            await window.refresh()
            try expectEqual(window.detail?.checks, [failing])
            try expect(!window.isStale)
        },
        TestCase("merge window: el popover con otro head pone el banner; con el mismo o antes de cargar, nada") { @MainActor in
            let (window, _) = window([.success(detail("aaa"))])
            window.noteHead("zzz")
            try expect(!window.isStale)
            await window.load()
            window.noteHead("aaa")
            window.noteHead(nil)
            try expect(!window.isStale)
            window.noteHead("bbb")
            try expectEqual(window.newerHead, "bbb")
            window.noteHead("aaa")
            try expect(window.isStale)
        },
        TestCase("merge window: un error de carga se muestra y no borra lo cargado") { @MainActor in
            let (window, _) = window([.success(detail("aaa")), .failure(.network("offline"))])
            await window.load()
            await window.refresh()
            try expectEqual(window.detail?.headOid, "aaa")
            try expectEqual(window.shownHead, "aaa")
            try expect(window.loadError != nil)
            try expect(!window.isStale)
        },
        TestCase("merge window: precargada (capturas, CLI) ya tiene head") { @MainActor in
            let window = MergeWindowModel(prID: "o/r#7", recordID: UUID(), detail: detail("ccc")) { detail("ccc") }
            try expectEqual(window.shownHead, "ccc")
        },
        TestCase("merge window: windowProblem, en orden") {
            func problem(current: ClassifiedPR? = ready, options: MergeOptions? = squashOnly, method: MergeMethod? = nil,
                         shown: String? = "aaa", stale: Bool = false, blocked: String? = nil) -> String? {
                MergeFlow.windowProblem(current: current, options: options, method: method, shownHead: shown, stale: stale,
                                        blockedReason: blocked)
            }
            try expectEqual(problem(), nil)
            try expectEqual(problem(method: .squash), nil)
            try expectEqual(problem(current: nil, blocked: "Installing an update"), "Installing an update")
            try expectEqual(problem(current: nil), "This PR isn’t in PRBar’s list anymore.")
            try expectEqual(problem(shown: nil), "Loading…")
            try expectEqual(problem(options: nil), "Loading…")
            try expectEqual(problem(stale: true), MergeWindowModel.staleText)
            try expectEqual(problem(method: .rebase), "This repo doesn’t allow Rebase and Merge")
            let blocked = MergeOptions(availability: .disabled(reason: "Blocked by branch protection or required checks"),
                                       methods: [.squash], defaultMethod: .squash)
            try expectEqual(problem(options: blocked), "Blocked by branch protection or required checks")
            let feedback = ClassifiedPR(pr: ready.pr, category: .myFeedback, account: "me")
            try expectEqual(problem(current: feedback), "This PR isn’t ready to merge")
        },
    ]
}
