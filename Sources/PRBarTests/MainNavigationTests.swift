import Foundation
import PRBarCore

private func context(mine: Bool, feedback: Bool = false, ci: Bool = false, task: RespondMode? = nil) -> PRTabContext {
    PRTabContext(isMine: mine, hasFeedback: feedback, ciFailing: ci, respondTask: task)
}

/// Un PR propio con esa categoría, CI y conflictos con su base (o sin ellos).
private func mine(category: PRCategory, conflicts: Bool, ci: CIState = .success) -> ClassifiedPR {
    let merge = conflicts ? PRMergeState(nodeID: "PR_1", mergeable: .conflicting, status: .dirty)
        : PRMergeState(nodeID: "PR_1", mergeable: .mergeable, status: .clean)
    return ClassifiedPR(pr: makePR(number: 1, author: "me", ci: ci, merge: merge), category: category, account: "me")
}

private func sectionOf(_ prID: String) -> MainSection? {
    prID.hasPrefix("me/") ? .myPRs : (prID.hasPrefix("o/") ? .toReview : nil)
}

enum MainNavigationTests {
    static let cases: [TestCase] = [
        TestCase("primary action: Resolve Conflicts en mis PRs con conflictos; prima sobre Fix CI; With Feedback sigue con Respond") {
            let ready = mine(category: .readyToMerge, conflicts: true)
            try expectEqual(PRPrimaryAction.of(ready, review: nil, respond: nil, respondMode: nil), .startConflicts)
            let failing = mine(category: .other, conflicts: true, ci: .failure)
            try expectEqual(PRPrimaryAction.of(failing, review: nil, respond: nil, respondMode: nil), .startConflicts)
            let feedback = mine(category: .myFeedback, conflicts: true)
            try expectEqual(PRPrimaryAction.of(feedback, review: nil, respond: nil, respondMode: nil), .startRespond)
            try expectEqual(PRPrimaryAction.of(feedback, review: nil, respond: .preparing, respondMode: .conflicts), .openConflicts)
            try expectEqual(PRPrimaryAction.of(mine(category: .readyToMerge, conflicts: false), review: nil, respond: nil, respondMode: nil), .openMerge)
            try expectEqual(PRPrimaryAction.startConflicts.tab, .respond)
            try expectEqual(PRPrimaryAction.openConflicts.title, "Open Resolve Conflicts")
            try expect(PRPrimaryAction.startConflicts.startsJob)
        },
        TestCase("pr tabs: una corrida de conflictos se ve en Respond (habilitada e inicial)") {
            let c = PRTabContext(isMine: true, hasFeedback: false, ciFailing: true, respondTask: .conflicts)
            try expect(PRTabs.tabs(c).contains { $0.tab == .respond && $0.isEnabled })
            try expectEqual(PRTabs.initial(c), .respond)
        },
        TestCase("navegación: PR ajeno tiene Review y Details y empieza en Review") {
            let c = context(mine: false)
            try expectEqual(PRTabs.tabs(c).map(\.tab), [.review, .details])
            try expect(PRTabs.tabs(c).allSatisfy(\.isEnabled))
            try expectEqual(PRTabs.initial(c), .review)
        },
        TestCase("navegación: PR propio — cambios pedidos → Respond; CI roto → Fix CI; si no, Merge") {
            try expectEqual(PRTabs.tabs(context(mine: true)).map(\.tab), [.merge, .respond, .fixCI])
            try expectEqual(PRTabs.initial(context(mine: true, feedback: true, ci: true)), .respond)
            try expectEqual(PRTabs.initial(context(mine: true, ci: true)), .fixCI)
            try expectEqual(PRTabs.initial(context(mine: true)), .merge)
            // Sin feedback ni CI roto pero con una tarea abierta: la de la tarea.
            try expectEqual(PRTabs.initial(context(mine: true, task: .ciFix)), .fixCI)
            try expectEqual(PRTabs.initial(context(mine: true, task: .feedback)), .respond)
        },
        TestCase("navegación: Respond y Fix CI deshabilitadas sin nada que hacer, salvo con tarea") {
            let idle = PRTabs.tabs(context(mine: true))
            try expectEqual(idle.map(\.isEnabled), [true, false, false])
            let withTask = PRTabs.tabs(context(mine: true, task: .feedback))
            try expectEqual(withTask.map(\.isEnabled), [true, true, false])
            let ciTask = PRTabs.tabs(context(mine: true, task: .ciFix))
            try expectEqual(ciTask.map(\.isEnabled), [true, false, true])
        },
        TestCase("navegación: la pestaña recordada vale si está habilitada; si no, la inicial") {
            try expectEqual(PRTabs.resolve(remembered: .fixCI, context: context(mine: true, ci: true)), .fixCI)
            try expectEqual(PRTabs.resolve(remembered: .respond, context: context(mine: true)), .merge)
            try expectEqual(PRTabs.resolve(remembered: .merge, context: context(mine: false)), .review)
            try expectEqual(PRTabs.resolve(remembered: nil, context: context(mine: false)), .review)
        },
        TestCase("navegación: ⌥⌘N es la N-ésima pestaña, si está habilitada") {
            try expectEqual(PRTabs.tab(atShortcut: 2, context(mine: false)), .details)
            try expectEqual(PRTabs.tab(atShortcut: 3, context(mine: false)), nil)
            try expectEqual(PRTabs.tab(atShortcut: 2, context(mine: true)), nil)   // Respond deshabilitada
            try expectEqual(PRTabs.tab(atShortcut: 3, context(mine: true, ci: true)), .fixCI)
        },
        TestCase("navegación: el contexto sale del PR clasificado") {
            let mine = ClassifiedPR(pr: makePR(number: 3, author: "me", ci: .failure), category: .myFeedback, account: "me")
            try expectEqual(PRTabContext(item: mine, respondTask: nil),
                            context(mine: true, feedback: true, ci: true))
            let other = ClassifiedPR(pr: makePR(number: 4, author: "ana"), category: .toReview, account: "me")
            try expectEqual(PRTabContext(item: other, respondTask: nil), context(mine: false))
        },
        TestCase("navegación: go(to:) elige la sección del PR, recuerda la pestaña pedida y empuja el lugar anterior") {
            var nav = MainNavigationState()
            try expectEqual(nav.place, .start)
            nav.go(to: .pr(prID: "me/r#3", tab: .fixCI), sectionOf: sectionOf)
            try expectEqual(nav.place, MainPlace(sidebar: .section(.myPRs), prID: "me/r#3"))
            try expectEqual(nav.rememberedTabs["me/r#3"], .fixCI)
            try expectEqual(nav.back.places, [.start])
            // Un PR que no está en el snapshot queda en la sección de ahora.
            nav.go(to: .pr(prID: "x/gone#9", tab: nil), sectionOf: sectionOf)
            try expectEqual(nav.place.sidebar, .section(.myPRs))
            nav.go(to: .history(recordID: nil), sectionOf: sectionOf)
            nav.go(to: .activity, sectionOf: sectionOf)
            try expectEqual(nav.back.places.count, 4)
            // Ir adonde ya se está no empuja nada.
            nav.go(to: .activity, sectionOf: sectionOf)
            try expectEqual(nav.back.places.count, 4)
        },
        TestCase("navegación: Back vuelve al lugar anterior y guarda como mucho 20") {
            var nav = MainNavigationState()
            for i in 0..<25 { nav.go(to: i.isMultiple(of: 2) ? .activity : .history(recordID: nil), sectionOf: sectionOf) }
            try expectEqual(nav.back.places.count, BackStack.limit)
            try expectEqual(nav.place.sidebar, .activity)   // i = 24
            nav.goBack()
            try expectEqual(nav.place.sidebar, .history)    // i = 23
            try expectEqual(nav.back.places.count, BackStack.limit - 1)
            var fresh = MainNavigationState()
            fresh.goBack()
            try expectEqual(fresh.place, .start)
        },
        TestCase("navegación: elegir en la lista no va a Back; ⌘1/⌘2 vuelven al PR elegido de cada sección") {
            var nav = MainNavigationState()
            nav.select(prID: "o/r#1")
            try expect(!nav.back.canGoBack)
            nav.go(to: .list(.myPRs), sectionOf: sectionOf)
            try expectEqual(nav.place, MainPlace(sidebar: .section(.myPRs), prID: nil))
            nav.select(prID: "me/r#3")
            nav.go(to: .list(.toReview), sectionOf: sectionOf)
            try expectEqual(nav.place.prID, "o/r#1")
            nav.go(to: .list(.myPRs), sectionOf: sectionOf)
            try expectEqual(nav.place.prID, "me/r#3")
        },
        TestCase("navegación: la pestaña elegida se recuerda por PR") {
            var nav = MainNavigationState()
            nav.choose(.details, for: "o/r#1")
            try expectEqual(nav.tab(for: "o/r#1", context: context(mine: false)), .details)
            try expectEqual(nav.tab(for: "o/r#2", context: context(mine: false)), .review)
            try expect(!nav.back.canGoBack)
        },
        TestCase("navegación: History con registro y Back dentro de History") {
            var nav = MainNavigationState()
            let id = UUID()
            nav.go(to: .history(recordID: id), sectionOf: sectionOf)
            try expectEqual(nav.place, MainPlace(sidebar: .history, historyRecordID: id))
            nav.select(historyRecord: nil)
            try expectEqual(nav.place.historyRecordID, nil)
            // ⌘3 estando en History conserva el registro elegido.
            nav.select(historyRecord: id)
            nav.go(to: .history(recordID: nil), sectionOf: sectionOf)
            try expectEqual(nav.place.historyRecordID, id)
        },
        TestCase("navegación: un PR elegido antes del primer snapshot pasa a su sección cuando llega") {
            var nav = MainNavigationState()
            // Sin snapshot todavía: cae en la sección de ahora (To Review).
            nav.go(to: .pr(prID: "me/r#3", tab: .fixCI), sectionOf: { _ in nil })
            try expectEqual(nav.place, MainPlace(sidebar: .section(.toReview), prID: "me/r#3"))
            let back = nav.back
            nav.reconcile(ids: ["me/r#3", "o/r#1"], sectionOf: sectionOf)
            try expectEqual(nav.place, MainPlace(sidebar: .section(.myPRs), prID: "me/r#3"))
            try expectEqual(nav.back, back)   // no empuja nada
            // ⌘1 no vuelve al PR que estaba mal puesto; ⌘2 sí lo tiene.
            nav.go(to: .list(.toReview), sectionOf: sectionOf)
            try expectEqual(nav.place.prID, nil)
            nav.go(to: .list(.myPRs), sectionOf: sectionOf)
            try expectEqual(nav.place.prID, "me/r#3")
        },
        TestCase("navegación: reconcile no mueve un PR que ya está en su sección, que no está o fuera de una sección") {
            var nav = MainNavigationState()
            nav.go(to: .pr(prID: "o/r#1", tab: nil), sectionOf: sectionOf)
            let before = nav
            nav.reconcile(ids: ["o/r#1"], sectionOf: sectionOf)
            try expectEqual(nav, before)
            nav.go(to: .pr(prID: "x/gone#9", tab: nil), sectionOf: sectionOf)
            let gone = nav
            nav.reconcile(ids: ["o/r#1"], sectionOf: sectionOf)
            try expectEqual(nav, gone)
            nav.go(to: .activity, sectionOf: sectionOf)
            let activity = nav
            nav.reconcile(ids: ["o/r#1"], sectionOf: sectionOf)
            try expectEqual(nav, activity)
        },
        TestCase("navegación: el id de un link prbar:// se busca sin distinguir mayúsculas") {
            let ids = ["Acme/API#12", "o/r#1"]
            try expectEqual(MainDestination.pr(prID: "acme/api#12", tab: .merge).canonicalized(among: ids),
                            .pr(prID: "Acme/API#12", tab: .merge))
            try expectEqual(MainDestination.pr(prID: "acme/api#13", tab: nil).canonicalized(among: ids),
                            .pr(prID: "acme/api#13", tab: nil))
            try expectEqual(MainDestination.activity.canonicalized(among: ids), .activity)
            // Llegó antes del snapshot: reconcile le pone el id del snapshot y le pasa la pestaña recordada.
            var nav = MainNavigationState()
            nav.go(to: .pr(prID: "ME/R#3", tab: .merge), sectionOf: { _ in nil })
            nav.reconcile(ids: ["me/r#3"], sectionOf: sectionOf)
            try expectEqual(nav.place, MainPlace(sidebar: .section(.myPRs), prID: "me/r#3"))
            try expectEqual(nav.rememberedTabs, ["me/r#3": .merge])
        },
        TestCase("navegación: el ancho de la lista es el 32 % entre 280 y 340") {
            try expect(abs(MainLayout.listWidth(windowWidth: 1000) - 320) < 0.001)
            try expectEqual(MainLayout.listWidth(windowWidth: 600), 280)
            try expectEqual(MainLayout.listWidth(windowWidth: 1280), 340)
            try expectEqual(MainLayout.listWidth(windowWidth: 700, chatOpen: true), 260)
            try expectEqual(MainLayout.listWidth(windowWidth: 1280, chatOpen: true), 340)
        },
    ]
}
