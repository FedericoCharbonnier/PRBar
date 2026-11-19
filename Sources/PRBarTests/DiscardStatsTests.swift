import Foundation
import PRBarCore

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let day: TimeInterval = 24 * 3600

private func event(_ repo: String, _ pr: String, _ category: FindingCategory = .style, daysAgo: Double = 1) -> DiscardEvent {
    DiscardEvent(repo: repo, prID: pr, category: category, title: "t", date: now.addingTimeInterval(-daysAgo * day))
}

private func draft(_ items: [ReviewItem]) -> ReviewDraft {
    ReviewDraft(prID: "PR_9", repo: RepoRef(owner: "acme", name: "web-app"), number: 9, title: "T",
                url: URL(string: "https://github.com/acme/web-app/pull/9")!, author: "a", headOid: "h", account: "me",
                summary: "S", items: items)
}

enum DiscardStatsTests {
    static let cases: [TestCase] = [
        TestCase("discard stats: registra los descartes y borra lo de más de 90 días") {
            let stats = DiscardStatsStore(fileURL: try temporaryDirectory().appendingPathComponent("discard-stats.json"))
            try stats.record([event("acme/api", "PR_1", daysAgo: 120), event("acme/api", "PR_2", daysAgo: 10)], now: now)
            let item = ReviewItem(finding: ReviewFinding(id: "f1", severity: .low, file: "a.ts", line: 1, title: "Naming",
                                                         body: "B", category: .docs), keep: true, reason: nil)
            try stats.record(items: [item], draft: draft([item]), now: now)
            let all = stats.all()
            try expectEqual(all.map(\.prID), ["PR_2", "PR_9"])
            try expectEqual(all[1], DiscardEvent(repo: "acme/web-app", prID: "PR_9", category: .docs, title: "Naming", date: now))
        },
        TestCase("discard stats: un archivo roto se lee vacío") {
            let url = try temporaryDirectory().appendingPathComponent("discard-stats.json")
            try Data("nope".utf8).write(to: url)
            try expectEqual(DiscardStatsStore(fileURL: url).all(), [])
        },
        TestCase("rule suggestions: 3 PRs del mismo repo en 30 días; 'other' y lo viejo no cuentan") {
            let events = [event("acme/api", "PR_1"), event("acme/api", "PR_2"), event("acme/api", "PR_2"),
                          event("acme/api", "PR_3", daysAgo: 40), event("acme/api", "PR_4", .other), event("acme/api", "PR_5", .other),
                          event("acme/api", "PR_6", .other)]
            try expectEqual(RuleSuggestions.compute(events: events, rules: [], decisions: [], now: now), [])
            let suggestions = RuleSuggestions.compute(events: events + [event("acme/api", "PR_7")], rules: [], decisions: [], now: now)
            try expectEqual(suggestions.map(\.id), ["repo:acme/api:style"])
            try expectEqual(suggestions[0].scope, .repo("acme/api"))
            try expectEqual(suggestions[0].prCount, 3)
            try expect(suggestions[0].message.contains("*style* comments in acme/api"), suggestions[0].message)
            try expectEqual(suggestions[0].text, RuleSuggestions.proposedText(.style))
        },
        TestCase("rule suggestions: en 2 o más repos la sugerencia es global y reemplaza a la del repo") {
            let events = [event("acme/api", "PR_1"), event("acme/api", "PR_2"), event("acme/api", "PR_3"), event("acme/web-app", "PR_4")]
            let suggestions = RuleSuggestions.compute(events: events, rules: [], decisions: [], now: now)
            try expectEqual(suggestions.map(\.id), ["global:style"])
            try expect(suggestions[0].message.contains("across your repos"), suggestions[0].message)
        },
        TestCase("rule suggestions: Never, Not Now y una regla de esa categoría la ocultan") {
            let events = [event("acme/api", "PR_1"), event("acme/api", "PR_2"), event("acme/api", "PR_3")]
            let never = SuggestionDecision(key: "repo:acme/api:style", never: true, snoozedUntil: nil)
            try expectEqual(RuleSuggestions.compute(events: events, rules: [], decisions: [never], now: now), [])
            let snoozed = SuggestionDecision(key: "repo:acme/api:style", never: false, snoozedUntil: now.addingTimeInterval(day))
            try expectEqual(RuleSuggestions.compute(events: events, rules: [], decisions: [snoozed], now: now), [])
            let expired = SuggestionDecision(key: "repo:acme/api:style", never: false, snoozedUntil: now.addingTimeInterval(-day))
            try expectEqual(RuleSuggestions.compute(events: events, rules: [], decisions: [expired], now: now).count, 1)
            let global = Rule(scope: .global, appliesTo: [.review], text: "x", source: .suggestion, createdAt: now,
                              enabled: false, category: .style)
            try expectEqual(RuleSuggestions.compute(events: events, rules: [global], decisions: [], now: now), [])
            let otherRepo = Rule(scope: .repo("acme/web-app"), appliesTo: [.review], text: "x", source: .suggestion, createdAt: now,
                                 category: .style)
            try expectEqual(RuleSuggestions.compute(events: events, rules: [otherRepo], decisions: [], now: now).count, 1)
        },
    ]
}
