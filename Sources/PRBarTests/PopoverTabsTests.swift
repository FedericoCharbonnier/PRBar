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
        TestCase("popover tabs: secciones de cada pestaña, en orden, con las calladas al final") {
            try expectEqual(PopoverTabs.sections(.toReview), [.toReview, .updatedSinceMyReview, .otherToReview])
            try expectEqual(PopoverTabs.sections(.mine), [.myFeedback, .readyToMerge, .waitingForReview])
            try expect(PopoverSection.otherToReview.isQuiet && PopoverSection.waitingForReview.isQuiet)
            try expect(!PopoverSection.readyToMerge.isQuiet)
            try expectEqual(PopoverSection.waitingForReview.title, "Waiting for Review")
            try expectEqual(PopoverSection.otherToReview.title, "Other")
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
        TestCase("popover tabs: estados vacíos y etiquetas del control") {
            try expectEqual(PopoverTabs.emptyState(.toReview).title, "Nothing to review 🎉")
            try expectEqual(PopoverTabs.emptyState(.mine).title, "No PRs of yours need anything")
            try expectEqual(PopoverTabs.label(.mine, count: 2, selected: false), "My PRs 2 •")
            try expectEqual(PopoverTabs.label(.mine, count: 2, selected: true), "My PRs 2")
            try expectEqual(PopoverTabs.label(.toReview, count: 0, selected: false), "To Review 0")
            try expectEqual(PopoverTabs.accessibilityLabel(.mine, count: 1), "My PRs, 1 needs your action")
            try expectEqual(PopoverTabs.accessibilityLabel(.toReview, count: 3), "To Review, 3 need your action")
        },
        TestCase("popover tabs: la pestaña elegida se guarda en UserDefaults (popoverTab)") {
            try await MainActor.run {
                let suite = "prbar-tests-\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let first = PopoverTabState(defaults: defaults)
                try expectEqual(first.selected, .toReview)
                first.selected = .mine
                try expectEqual(defaults.string(forKey: "popoverTab"), "mine")
                let second = PopoverTabState(defaults: defaults)
                try expectEqual(second.selected, .mine)
            }
        },
        TestCase("popover tabs: un valor guardado desconocido vuelve a To Review") {
            try await MainActor.run {
                let suite = "prbar-tests-\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set("everything", forKey: PopoverTabState.defaultsKey)
                try expectEqual(PopoverTabState(defaults: defaults).selected, .toReview)
            }
        },
        TestCase("popover tabs: sin UserDefaults la pestaña se recuerda solo en memoria") {
            try await MainActor.run {
                let state = PopoverTabState(defaults: nil)
                try expectEqual(state.selected, .toReview)
                state.selected = .mine
                try expectEqual(state.selected, .mine)
                try expectEqual(PopoverTabState(defaults: nil).selected, .toReview)
            }
        },
    ]
}
