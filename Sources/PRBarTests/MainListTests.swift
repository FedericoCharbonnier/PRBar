import Foundation
import PRBarCore

private func item(_ category: PRCategory, author: String = "ana", number: Int = 1, ci: CIState = .success,
                  draft: Bool = false) -> ClassifiedPR {
    ClassifiedPR(pr: makePR(number: number, author: author, isDraft: draft, ci: ci), category: category, account: "me")
}

private let snapshot = Snapshot(items: [
    item(.toReview, number: 1),
    item(.updatedSinceMyReview, number: 2),
    item(.other, number: 3, draft: true),
    item(.myFeedback, author: "me", number: 4, ci: .failure),
    item(.readyToMerge, author: "me", number: 5),
    item(.other, author: "me", number: 6, ci: .failure),
    item(.other, author: "me", number: 7),
], fetchedAt: t0)

enum MainListTests {
    static let cases: [TestCase] = [
        TestCase("lista: secciones de To Review y de My PRs, en orden") {
            try expectEqual(MainList.sections(.toReview), [.toReview, .updatedSinceMyReview, .otherToReview])
            try expectEqual(MainList.sections(.myPRs), [.withFeedback, .ciFailing, .readyToMerge, .waitingForReview])
            try expectEqual(MainListSection.withFeedback.title, "With Feedback")
            try expectEqual(MainListSection.ciFailing.title, "CI Failing")
        },
        TestCase("lista: cada PR va a su sección; un PR mío con CI roto y sin feedback es CI Failing") {
            try expectEqual(MainList.items(.ciFailing, in: snapshot).map(\.pr.number), [6])
            try expectEqual(MainList.items(.withFeedback, in: snapshot).map(\.pr.number), [4])   // feedback gana
            try expectEqual(MainList.items(.waitingForReview, in: snapshot).map(\.pr.number), [7])
            try expectEqual(MainList.items(.otherToReview, in: snapshot).map(\.pr.number), [3])
            try expectEqual(MainList.mainSection(of: snapshot.items[3]), .myPRs)
            try expectEqual(MainList.mainSection(of: snapshot.items[0]), .toReview)
        },
        TestCase("lista: contador de la barra lateral = el del popover (solo accionables)") {
            try expectEqual(MainList.count(.toReview, in: snapshot), 2)
            try expectEqual(MainList.count(.myPRs, in: snapshot), 2)
            try expectEqual(MainList.count(.myPRs, in: nil), nil)
        },
        TestCase("lista: vacías y calladas empiezan plegadas; borradores ocultos") {
            try expect(MainList.initiallyCollapsed(.toReview, itemCount: 0))
            try expect(!MainList.initiallyCollapsed(.toReview, itemCount: 2))
            try expect(MainList.initiallyCollapsed(.otherToReview, itemCount: 3))
            try expectEqual(MainList.hiddenDraftCount(in: snapshot), 1)
        },
        TestCase("lista: la búsqueda filtra por título, repo#N, autor y rama, sin mayúsculas ni acentos") {
            let pr = PullRequest(repo: RepoRef(owner: "acme", name: "web"), number: 482, title: "Arreglá la redirección",
                                 url: URL(string: "https://github.com/acme/web/pull/482")!, isDraft: false, author: "laura",
                                 authorAvatarURL: nil, baseRef: "main", headRef: "fix/login-redirect", headOid: "a",
                                 additions: 1, deletions: 1, createdAt: t0, updatedAt: t0, lastCommitAt: t0, ciState: .success,
                                 reviewDecision: .none, reviews: [], comments: [], requestedReviewers: [],
                                 authorName: "Laura Méndez")
            for query in ["", "REDIRECCION", "web#482", "#482", "48", "laura", "mendez", "login-redirect", "acme/web",
                          "laura redirect"] {
                try expect(ListSearch.matches(pr, query: query), "debería encontrar \(query)")
            }
            for query in ["api#482", "#99", "carlos", "laura api"] {
                try expect(!ListSearch.matches(pr, query: query), "no debería encontrar \(query)")
            }
            try expectEqual(MainList.items(.toReview, in: snapshot, query: "pr 1").map(\.pr.number), [1])
        },
        TestCase("días: Today, Yesterday y la fecha") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let now = t0   // 2027-01-15 08:00 UTC
            try expectEqual(DayGrouping.title(for: now.addingTimeInterval(-3600), now: now, calendar: calendar), "Today")
            try expectEqual(DayGrouping.title(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar), "Yesterday")
            try expectEqual(DayGrouping.title(for: now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar),
                            "Tuesday, Jan 12")
            try expectEqual(DayGrouping.title(for: now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar),
                            "Dec 11, 2025")
            let dates = [now, now.addingTimeInterval(-60), now.addingTimeInterval(-86_400)]
            let groups = DayGrouping.group(dates, date: { $0 }, now: now, calendar: calendar)
            try expectEqual(groups.map(\.title), ["Today", "Yesterday"])
            try expectEqual(groups.map(\.items.count), [2, 1])
        },
        TestCase("pill: qué hace ↩ en cada fila y qué pestaña abre") {
            try expectEqual(PRPrimaryAction.of(item(.toReview), review: nil, respond: nil, respondMode: nil), .startReview)
            try expectEqual(PRPrimaryAction.of(item(.toReview), review: .reviewing(agents: 3), respond: nil, respondMode: nil),
                            .openReview)
            try expectEqual(PRPrimaryAction.of(item(.toReview), review: .failed("x", logURL: nil), respond: nil,
                                               respondMode: nil), .startReview)
            try expectEqual(PRPrimaryAction.of(item(.myFeedback, author: "me"), review: nil, respond: nil, respondMode: nil),
                            .startRespond)
            try expectEqual(PRPrimaryAction.of(item(.myFeedback, author: "me"), review: nil, respond: .pushing,
                                               respondMode: .ciFix), .openCIFix)
            try expectEqual(PRPrimaryAction.of(item(.readyToMerge, author: "me"), review: nil, respond: nil, respondMode: nil),
                            .openMerge)
            try expectEqual(PRPrimaryAction.of(item(.other, author: "me", ci: .failure), review: nil, respond: nil,
                                               respondMode: nil), .startCIFix)
            try expectEqual(PRPrimaryAction.of(item(.other), review: nil, respond: nil, respondMode: nil), .none)
            try expectEqual(PRPrimaryAction.startCIFix.tab, .fixCI)
            try expect(PRPrimaryAction.startReview.startsJob && !PRPrimaryAction.openMerge.startsJob)
        },
    ]
}
