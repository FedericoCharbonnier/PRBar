import Foundation
import PRBarCore

private func detail(_ head: String, checks: [MergeCheck] = []) -> MergeDetail {
    var detail = MergeDetail.empty(number: 7, headOid: head)
    detail.checks = checks
    return detail
}

/// Una ventana cuyo `fetch` devuelve, en orden, `results` (el último se repite).
@MainActor
private func window(_ results: [Result<MergeDetail, PRBarError>]) -> (MergeDetailModel, Box<Int>) {
    let calls = Box(0)
    let queue = Box(results)
    let model = MergeDetailModel(prID: "o/r#7", recordID: UUID()) {
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

extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

enum MergeWindowTests {
    /// Carga A y después ve B.
    @MainActor static func window2() -> (MergeDetailModel, Box<Int>) {
        window([.success(detail("aaa")), .success(detail("bbb"))])
    }

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
            window.noteHead(nil)
            try expectEqual(window.newerHead, "bbb")
        },
        TestCase("merge window: reabrir refresca (mantiene el head; uno nuevo da el banner); abierta, no") { @MainActor in
            let failing = MergeCheck(name: "lint", kind: .checkRun, state: .failed, isRequired: false)
            let (window, calls) = window([.success(detail("aaa")), .success(detail("aaa", checks: [failing])),
                                          .success(detail("bbb"))])
            await window.opened(alreadyOpen: false)
            try expectEqual(calls.value, 1)
            try expectEqual(window.shownHead, "aaa")
            // Ya abierta (otro "Merge…" sobre la misma ventana): no vuelve a pedir.
            await window.opened(alreadyOpen: true)
            try expectEqual(calls.value, 1)
            // Cerrada y reabierta: el resumen se refresca (checks nuevos)…
            await window.opened(alreadyOpen: false)
            try expectEqual(calls.value, 2)
            try expectEqual(window.detail?.checks, [failing])
            // …y un head nuevo no reemplaza lo mostrado: banner.
            await window.opened(alreadyOpen: false)
            try expectEqual(window.shownHead, "aaa")
            try expectEqual(window.newerHead, "bbb")
        },
        TestCase("merge window: un snapshot más viejo que GitHub no deja la ventana en un loop de Reload") { @MainActor in
            // La ventana cargó B de GitHub; el snapshot del popover todavía tiene A.
            let (window, _) = window([.success(detail("bbb"))])
            await window.load()
            window.noteHead("aaa")
            try expect(window.isStale)
            // Reload: GitHub vuelve a decir B, que desmiente A.
            await window.reload()
            try expect(!window.isStale)
            window.noteHead("aaa")
            try expect(!window.isStale)
            // El snapshot se pone al día: nada.
            window.noteHead("bbb")
            try expect(!window.isStale)
            // Un push real después sí da el banner.
            window.noteHead("ccc")
            try expectEqual(window.newerHead, "ccc")
        },
        TestCase("merge window: el snapshot que se pone al día borra el banner que él mismo puso") { @MainActor in
            let (window, _) = window([.success(detail("bbb"))])
            await window.load()
            window.noteHead("aaa")
            try expect(window.isStale)
            window.noteHead("bbb")
            try expect(!window.isStale)
            // Pero un head nuevo que vio GitHub (⌘R) no lo borra un snapshot atrasado.
            let (fetched, _) = MergeWindowTests.window2()
            await fetched.load()
            await fetched.refresh()
            try expectEqual(fetched.newerHead, "bbb")
            fetched.noteHead("aaa")
            try expectEqual(fetched.newerHead, "bbb")
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
            let window = MergeDetailModel(prID: "o/r#7", recordID: UUID(), detail: detail("ccc")) { detail("ccc") }
            try expectEqual(window.shownHead, "ccc")
        },
        TestCase("merge window: el botón mergea el head que muestra la ventana, aunque el snapshot tenga otro") {
            let options = squashOnly
            func merge(current: ClassifiedPR = ready, method: MergeMethod? = nil, shown: String? = "shown", stale: Bool = false,
                       blocked: String? = nil) -> Result<MergeFlow.WindowMerge, MergeError> {
                MergeFlow.windowMerge(current: current, options: options, method: method, shownHead: shown, stale: stale,
                                      blockedReason: blocked)
            }
            // El snapshot tiene "aaa"; la ventana mostró "shown": se mergea "shown", con el método por defecto.
            guard case .success(let request) = merge() else { throw TestFailure(description: "\(merge())") }
            try expectEqual(request.item.pr.headOid, "shown")
            try expectEqual(request.item.id, ready.id)
            try expectEqual(request.method, .squash)
            try expectEqual(try merge(method: .squash).get().method, .squash)
            try expectEqual(merge(stale: true).failureValue, .unavailable(MergeDetailModel.staleText))
            try expectEqual(merge(blocked: "Installing an update").failureValue, .blocked("Installing an update"))
            try expectEqual(merge(shown: nil).failureValue, .unavailable("Loading…"))
            try expectEqual(merge(method: .rebase).failureValue, .unavailable("This repo doesn’t allow Rebase and Merge"))
            let feedback = ClassifiedPR(pr: ready.pr, category: .myFeedback, account: "me")
            try expectEqual(merge(current: feedback).failureValue, .unavailable("This PR isn’t ready to merge"))
        },
        TestCase("merge window: el chat sin mensajes se rehace con el head que muestra la ventana") {
            func rebuilds(chat: String = "aaa", shown: String? = "bbb", messages: Bool = false, running: Bool = false) -> Bool {
                MergeFlow.rebuildsChat(chatHead: chat, shownHead: shown, hasMessages: messages, isRunning: running)
            }
            try expect(rebuilds())
            try expect(!rebuilds(shown: "aaa"))
            try expect(!rebuilds(shown: nil))
            try expect(!rebuilds(messages: true))
            try expect(!rebuilds(running: true))
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
            try expectEqual(problem(stale: true), MergeDetailModel.staleText)
            try expectEqual(problem(method: .rebase), "This repo doesn’t allow Rebase and Merge")
            let blocked = MergeOptions(availability: .disabled(reason: "Blocked by branch protection or required checks"),
                                       methods: [.squash], defaultMethod: .squash)
            try expectEqual(problem(options: blocked), "Blocked by branch protection or required checks")
            let feedback = ClassifiedPR(pr: ready.pr, category: .myFeedback, account: "me")
            try expectEqual(problem(current: feedback), "This PR isn’t ready to merge")
        },
    ]
}
