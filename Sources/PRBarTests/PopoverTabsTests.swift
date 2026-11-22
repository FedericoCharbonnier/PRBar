import Foundation
import PRBarCore

private func item(_ category: PRCategory, author: String = "ana", account: String = "me", number: Int = 1) -> ClassifiedPR {
    ClassifiedPR(pr: makePR(number: number, author: author), category: category, account: account)
}

private let mixed = Snapshot(items: [
    item(.toReview, number: 1),
    item(.updatedSinceMyReview, number: 2),
    item(.myFeedback, author: "me", number: 3),
    item(.readyToMerge, author: "me", number: 4),
    item(.other, number: 5),
    item(.other, author: "Me", number: 6),
], fetchedAt: t0)

private final class MemoryTabStore: PopoverTabStore {
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value as? String }
}

enum PopoverTabsTests {
    static let cases: [TestCase] = [
        TestCase("popover tabs: cada categoría va a su pestaña; Other mío es Waiting for Review") {
            try expectEqual(PopoverTabs.tab(of: item(.toReview)), .toReview)
            try expectEqual(PopoverTabs.tab(of: item(.updatedSinceMyReview)), .toReview)
            try expectEqual(PopoverTabs.tab(of: item(.myFeedback, author: "me")), .mine)
            try expectEqual(PopoverTabs.tab(of: item(.readyToMerge, author: "me")), .mine)
            try expectEqual(PopoverTabs.tab(of: item(.other)), .toReview)
            try expectEqual(PopoverTabs.tab(of: item(.other, author: "ME")), .mine)
            try expectEqual(PopoverTabs.section(of: item(.other)), .otherToReview)
            try expectEqual(PopoverTabs.section(of: item(.other, author: "me")), .waitingForReview)
            try expectEqual(PopoverTabs.section(of: item(.readyToMerge, author: "me")), .readyToMerge)
        },
        TestCase("popover tabs: \"mío\" es solo de la cuenta desde la que se ve (H.4.1)") {
            // Un PR de mi otra cuenta visto desde esta es ajeno: va a To Review.
            let fromOtherAccount = item(.other, author: "dev-sam-work", account: "dev-sam")
            try expect(!PopoverTabs.isMine(fromOtherAccount))
            try expectEqual(PopoverTabs.section(of: fromOtherAccount), .otherToReview)
            try expectEqual(PopoverTabs.tab(of: item(.toReview, author: "dev-sam-work", account: "dev-sam")), .toReview)
            try expect(PopoverTabs.isMine(item(.other, author: "Dev-Sam-Work", account: "dev-sam-work")))
        },
        TestCase("popover tabs: con dos cuentas, los PRs de cada una van a My PRs") {
            let snapshot = Snapshot(items: [
                item(.readyToMerge, author: "dev-sam", account: "dev-sam", number: 1),
                item(.myFeedback, author: "dev-sam-work", account: "dev-sam-work", number: 2),
                item(.other, author: "dev-sam-work", account: "dev-sam-work", number: 3),
                item(.toReview, author: "dev-sam", account: "dev-sam-work", number: 4),
                item(.other, author: "ana", account: "dev-sam", number: 5),
            ], fetchedAt: t0)
            try expectEqual(PopoverTabs.counts(in: snapshot), [.toReview: 1, .mine: 2])
            try expectEqual(PopoverTabs.items(.waitingForReview, in: snapshot).map(\.pr.number), [3])
            try expectEqual(PopoverTabs.items(.otherToReview, in: snapshot).map(\.pr.number), [5])
            try expectEqual(PopoverTabs.items(.toReview, in: snapshot).map(\.pr.number), [4])
        },
        TestCase("popover tabs: prbar prs filtra por --list, --tab y --account") {
            let items = mixed.items
            func numbers(_ list: PRListFilter?, _ tab: PopoverTab?, _ account: String? = nil) -> [Int] {
                PRListing.filter(items, list: list, tab: tab, account: account).map(\.pr.number)
            }
            try expectEqual(numbers(nil, nil), [1, 2, 3, 4, 5, 6])
            try expectEqual(numbers(nil, .toReview), [1, 2, 5])
            try expectEqual(numbers(nil, .mine), [3, 4, 6])
            try expectEqual(numbers(.other, nil), [5, 6])
            try expectEqual(numbers(.other, .mine), [6])
            try expectEqual(numbers(.other, .toReview), [5])
            try expectEqual(numbers(.readyToMerge, .mine), [4])
            try expectEqual(numbers(nil, nil, "ME"), [1, 2, 3, 4, 5, 6])
            try expectEqual(numbers(nil, nil, "other"), [])
        },
        TestCase("popover tabs: secciones de cada pestaña, en orden, con las calladas al final") {
            try expectEqual(PopoverTabs.sections(.toReview), [.toReview, .updatedSinceMyReview, .otherToReview])
            try expectEqual(PopoverTabs.sections(.mine), [.myFeedback, .readyToMerge, .waitingForReview])
            try expect(PopoverSection.otherToReview.isQuiet && PopoverSection.waitingForReview.isQuiet)
            try expect(!PopoverSection.readyToMerge.isQuiet)
            try expectEqual(PopoverSection.waitingForReview.title, "Waiting for Review")
            try expectEqual(PopoverSection.otherToReview.title, "Other")
            try expectEqual(PopoverSection.waitingForReview.subtitle, "nothing to do right now")
            for section in PopoverSection.allCases { try expect(PopoverTabs.sections(section.tab).contains(section)) }
        },
        TestCase("popover tabs: items por sección") {
            try expectEqual(PopoverTabs.items(.waitingForReview, in: mixed).map(\.pr.number), [6])
            try expectEqual(PopoverTabs.items(.otherToReview, in: mixed).map(\.pr.number), [5])
            try expectEqual(PopoverTabs.items(.myFeedback, in: mixed).map(\.pr.number), [3])
            try expectEqual(PopoverTabs.items(.toReview, in: mixed).map(\.pr.number), [1])
        },
        TestCase("popover tabs: los contadores suman el badge y no cuentan Other ni Waiting") {
            try expectEqual(PopoverTabs.count(.toReview, in: mixed), 2)
            try expectEqual(PopoverTabs.count(.mine, in: mixed), 2)
            try expectEqual(PopoverTabs.count(.toReview, in: mixed) + PopoverTabs.count(.mine, in: mixed), mixed.badgeCount)
            try expectEqual(PopoverTabs.counts(in: mixed), [.toReview: 2, .mine: 2])
            try expectEqual(PopoverTabs.counts(in: nil), [.toReview: 0, .mine: 0])
            let quiet = Snapshot(items: [item(.other, number: 5), item(.other, author: "me", number: 6)], fetchedAt: t0)
            try expectEqual(PopoverTabs.counts(in: quiet), [.toReview: 0, .mine: 0])
        },
        TestCase("popover tabs: PRs por sección (lo que muestra prbar status)") {
            try expectEqual(PopoverTabs.sectionCounts(in: mixed), [
                .toReview: 1, .updatedSinceMyReview: 1, .otherToReview: 1, .myFeedback: 1, .readyToMerge: 1,
                .waitingForReview: 1,
            ])
            try expectEqual(PopoverTabs.sectionCounts(in: nil)[.waitingForReview], 0)
        },
        TestCase("popover tabs: estados vacíos y etiquetas del control") {
            try expectEqual(PopoverTabs.emptyState(.toReview).title, "Nothing to review 🎉")
            try expectEqual(PopoverTabs.emptyState(.mine).title, "No PRs of yours need anything")
            try expectEqual(PopoverTabs.label(.mine, count: 2, selected: false), "My PRs 2 •")
            try expectEqual(PopoverTabs.label(.mine, count: 2, selected: true), "My PRs 2")
            try expectEqual(PopoverTabs.label(.toReview, count: 0, selected: false), "To Review 0")
            try expectEqual(PopoverTabs.accessibilityLabel(.mine, count: 1, selected: true), "My PRs, 1 needs your action")
            try expectEqual(PopoverTabs.accessibilityLabel(.toReview, count: 3, selected: true), "To Review, 3 need your action")
            try expectEqual(PopoverTabs.accessibilityLabel(.mine, count: 2, selected: false),
                            "My PRs, 2 need your action, has pending items")
            try expectEqual(PopoverTabs.accessibilityLabel(.mine, count: 0, selected: false), "My PRs, 0 need your action")
        },
        TestCase("popover tabs: el valor de accesibilidad del control describe las dos pestañas") {
            try expectEqual(PopoverTabs.accessibilityValue(counts: [.toReview: 3, .mine: 2], selected: .toReview),
                            "To Review selected, 3 need your action; My PRs, 2 need your action, has pending items")
            try expectEqual(PopoverTabs.accessibilityValue(counts: [.toReview: 0, .mine: 1], selected: .mine),
                            "To Review, 0 need your action; My PRs selected, 1 needs your action")
            try expectEqual(PopoverTabs.accessibilityValue(counts: [:], selected: .toReview),
                            "To Review selected, 0 need your action; My PRs, 0 need your action")
        },
        TestCase("popover tabs: la pestaña elegida se guarda (popoverTab)") {
            try await MainActor.run {
                let store = MemoryTabStore()
                let first = PopoverTabState(store: store)
                try expectEqual(first.selected, .toReview)
                first.selected = .mine
                try expectEqual(store.values["popoverTab"], "mine")
                let second = PopoverTabState(store: store)
                try expectEqual(second.selected, .mine)
            }
        },
        TestCase("popover tabs: un valor guardado desconocido vuelve a To Review") {
            try await MainActor.run {
                let store = MemoryTabStore()
                store.values[PopoverTabState.defaultsKey] = "everything"
                try expectEqual(PopoverTabState(store: store).selected, .toReview)
            }
        },
        TestCase("popover tabs: UserDefaults sirve de almacén (sin escribir en disco)") {
            // Solo el dominio de registro, que no se guarda: escribir en un suite deja un .plist en
            // ~/Library/Preferences que cfprefsd vuelve a crear aunque se lo borre al terminar.
            try await MainActor.run {
                let defaults = UserDefaults(suiteName: "prbar-tests-registration-only")!
                defaults.register(defaults: [PopoverTabState.defaultsKey: "mine"])
                try expectEqual(PopoverTabState(store: defaults).selected, .mine)
            }
        },
        TestCase("popover tabs: sin UserDefaults la pestaña se recuerda solo en memoria") {
            try await MainActor.run {
                let state = PopoverTabState(store: nil)
                try expectEqual(state.selected, .toReview)
                state.selected = .mine
                try expectEqual(state.selected, .mine)
                try expectEqual(PopoverTabState(store: nil).selected, .toReview)
            }
        },
    ]
}
