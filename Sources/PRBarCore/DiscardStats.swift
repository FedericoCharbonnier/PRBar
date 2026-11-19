import Foundation

/// A finding the user chose not to post (spec E.4).
public struct DiscardEvent: Codable, Equatable, Sendable {
    public let repo: String
    public let prID: String
    public let category: FindingCategory
    public let title: String
    public let date: Date

    public init(repo: String, prID: String, category: FindingCategory, title: String, date: Date) {
        self.repo = repo
        self.prID = prID
        self.category = category
        self.title = title
        self.date = date
    }
}

/// `discard-stats.json`: the last 90 days of findings the user discarded when posting. Only the app writes it.
public struct DiscardStatsStore: Sendable {
    public static let retention: TimeInterval = 90 * 24 * 3600

    private struct File: Codable { var events: [DiscardEvent] }

    private let fileURL: URL

    public init(fileURL: URL = AppPaths.discardStatsFile) {
        self.fileURL = fileURL
    }

    /// Every event, oldest first. A broken file reads as empty (and is rewritten on the next post).
    public func all() -> [DiscardEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONCoding.decoder.decode(File.self, from: data).events
        } catch {
            AppLog.write("discard-stats.json couldn't be read (\(error.localizedDescription)); starting over.")
            return []
        }
    }

    /// Adds the findings of `draft` the user didn't post (`ReviewEdits.userDiscarded`) and drops what's older than
    /// 90 days.
    public func record(items: [ReviewItem], draft: ReviewDraft, now: Date = Date()) throws {
        try record(items.map { DiscardEvent(repo: draft.repo.fullName, prID: draft.prID, category: $0.finding.category,
                                            title: $0.finding.title, date: now) }, now: now)
    }

    public func record(_ events: [DiscardEvent], now: Date = Date()) throws {
        let kept = (all() + events).filter { now.timeIntervalSince($0.date) <= Self.retention }.sorted { $0.date < $1.date }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(File(events: kept)).write(to: fileURL, options: .atomic)
    }
}

/// "You usually discard *style* comments in acme/web-app. Create a rule?" (spec E.4).
public struct RuleSuggestion: Equatable, Identifiable, Sendable {
    /// `global:<category>` or `repo:<owner/name>:<category>`; also the key of the user's decision.
    public let id: String
    public let scope: RuleScope
    public let category: FindingCategory
    /// Distinct PRs with a discard of this category in the window.
    public let prCount: Int
    /// The proposed rule (editable before creating it).
    public let text: String

    public var message: String {
        let category = "*\(self.category.rawValue)*"
        switch scope {
        case .global: return "You usually discard \(category) comments across your repos. Create a rule?"
        case .repo(let name): return "You usually discard \(category) comments in \(name). Create a rule?"
        }
    }
}

public enum RuleSuggestions {
    public static let window: TimeInterval = 30 * 24 * 3600
    public static let minPRs = 3
    /// "Not Now" hides a suggestion for this long.
    public static let snooze: TimeInterval = 30 * 24 * 3600

    public static func key(_ scope: RuleScope, _ category: FindingCategory) -> String {
        switch scope {
        case .global: "global:\(category.rawValue)"
        case .repo(let name): "repo:\(name):\(category.rawValue)"
        }
    }

    public static func proposedText(_ category: FindingCategory) -> String {
        switch category {
        case .bug: "Only report bugs you can point to in the code, with the case that fails."
        case .security: "Only report security issues with a concrete way to exploit them."
        case .performance: "Only comment on performance when the impact is real and measurable."
        case .tests: "Don't ask for more tests unless a change is risky and clearly untested."
        case .style: "Don't comment on code style or formatting."
        case .docs: "Don't comment on documentation or code comments unless they're wrong."
        case .other: ""
        }
    }

    /// For each category (not `other`): distinct PRs with a discard in the last 30 days. 3 or more across 2 or more
    /// repos → a global suggestion (and none per repo for that category); otherwise, or if the global one is hidden
    /// ("Never" or "Not Now"), one per repo with 3 or more. Hidden by "Never", by "Not Now" until it expires, and by a
    /// rule created from a suggestion of that category (global, or of the same repo). Repos are compared without case.
    /// `configuredRepos`: only these get a suggestion of their own, named as configured (nil = any repo).
    public static func compute(events: [DiscardEvent], rules: [Rule], decisions: [SuggestionDecision],
                               configuredRepos: [String]? = nil, now: Date = Date()) -> [RuleSuggestion] {
        let recent = events.filter { $0.category != .other && now.timeIntervalSince($0.date) <= window }
        var result: [RuleSuggestion] = []
        for category in FindingCategory.allCases where category != .other {
            let ofCategory = recent.filter { $0.category == category }
            var prsByRepo: [String: Set<String>] = [:]
            var names: [String: String] = [:]
            for event in ofCategory {
                let key = event.repo.lowercased()
                prsByRepo[key, default: []].insert(event.prID)
                names[key] = names[key] ?? event.repo
            }
            let total = Set(ofCategory.map(\.prID)).count
            if prsByRepo.count >= 2 && total >= minPRs,
               allowed(.global, category, rules: rules, decisions: decisions, now: now) {
                result.append(RuleSuggestion(id: key(.global, category), scope: .global, category: category,
                                             prCount: total, text: proposedText(category)))
                continue
            }
            for (repoKey, prs) in prsByRepo.sorted(by: { $0.key < $1.key }) where prs.count >= minPRs {
                let name: String
                if let configuredRepos {
                    guard let configured = configuredRepos.first(where: { $0.lowercased() == repoKey }) else { continue }
                    name = configured
                } else {
                    name = names[repoKey] ?? repoKey
                }
                let scope = RuleScope.repo(name)
                if allowed(scope, category, rules: rules, decisions: decisions, now: now) {
                    result.append(RuleSuggestion(id: key(scope, category), scope: scope, category: category,
                                                 prCount: prs.count, text: proposedText(category)))
                }
            }
        }
        return result
    }

    static func allowed(_ scope: RuleScope, _ category: FindingCategory, rules: [Rule], decisions: [SuggestionDecision],
                        now: Date) -> Bool {
        let wanted = key(scope, category).lowercased()
        if decisions.contains(where: { $0.key.lowercased() == wanted
            && ($0.never || ($0.snoozedUntil.map { $0 > now } ?? false)) }) {
            return false
        }
        return !rules.contains { rule in
            guard rule.category == category else { return false }
            switch (rule.scope, scope) {
            case (.global, _): return true
            case (.repo(let a), .repo(let b)): return a.caseInsensitiveCompare(b) == .orderedSame
            case (.repo, .global): return false
            }
        }
    }
}
