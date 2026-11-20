import Foundation
import Observation
import PRBarWire

/// `home`, `home:mine`, `home:offline` (design §home): the two tabs of the Mac's popover, live.
@MainActor @Observable
public final class HomeModel {
    public enum Tab: String, CaseIterable, Sendable { case toReview, mine }

    public enum Leading: Equatable, Sendable {
        case avatar(initials: String, colorIndex: Int)
        case state(StateIcon)
    }

    public enum StateIcon: Equatable, Sendable { case feedback, ready, ciFailing, waiting }

    public enum Status: Equatable, Sendable {
        case working(String)
        case changesRequested(String)
        case approved(String)
        case checksFailed(String)

        public var text: String {
            switch self {
            case .working(let t), .changesRequested(let t), .approved(let t), .checksFailed(let t): t
            }
        }
    }

    public enum Action: Equatable, Sendable {
        case review, reviewing, comments(Int), reviewReady, respond, responding, merge, fixCI, fixing

        public var title: String {
            switch self {
            case .review: "Review"
            case .reviewing: "Reviewing…"
            case .comments(let n): Format.count(n, "comment")
            case .reviewReady: "Review Ready"
            case .respond: "Respond"
            case .responding: "Responding…"
            case .merge: "Merge…"
            case .fixCI: "Fix CI"
            case .fixing: "Fixing…"
            }
        }

        public var isRunning: Bool { self == .reviewing || self == .responding || self == .fixing }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String { pr.id }
        public var pr: PRInfo
        public var title: String
        public var meta: String
        public var age: String
        public var leading: Leading
        public var status: Status?
        public var action: Action?
        public var authorName: String

        public var accessibilityLabel: String {
            "\(title), \(Format.shortRef(pr.id)), \(age), \(pr.additions) additions, \(pr.deletions) deletions"
        }
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var rows: [Row]
        public var isQuiet: Bool
    }

    public static let ciFailingID = "ciFailing"

    public let connection: RemoteConnection
    public var store: AppStore { connection.store }
    public var collapsed: Set<String> = [PopoverSection.otherToReview.rawValue, PopoverSection.waitingForReview.rawValue]
    public var lastError: String?
    @ObservationIgnored private let runner: ActionRunner
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let timeZone: TimeZone

    public init(connection: RemoteConnection, runner: ActionRunner, now: @escaping () -> Date = Date.init,
                locale: Locale = .current, timeZone: TimeZone = .current) {
        self.connection = connection
        self.runner = runner
        self.now = now
        self.locale = locale
        self.timeZone = timeZone
    }

    // MARK: Lists

    public var isOffline: Bool { store.isStale }

    public func sections(_ tab: Tab) -> [Section] {
        guard let home = store.home else { return [] }
        let failing = Set(home.ci.map(\.pr))
        let wanted: PopoverTab = tab == .toReview ? .toReview : .mine
        let prs = home.prs.filter { pr in (pr.tab ?? pr.section?.tab) == wanted }
        var result: [Section] = []
        let order: [PopoverSection] = tab == .toReview
            ? [.toReview, .updatedSinceMyReview, .otherToReview]
            : [.myFeedback, .readyToMerge, .waitingForReview]
        for section in order {
            // My PRs with failing CI get their own section ("CI Failing"), before Waiting for Review.
            if section == .waitingForReview {
                let ci = prs.filter { failing.contains($0.id) }
                if !ci.isEmpty {
                    result.append(Section(id: Self.ciFailingID, title: "CI Failing",
                                          rows: ci.map { row($0, section: nil, home: home) }, isQuiet: false))
                }
            }
            let members = prs.filter { $0.section == section && !(tab == .mine && failing.contains($0.id)) }
            guard !members.isEmpty else { continue }
            result.append(Section(id: section.rawValue, title: section.title,
                                  rows: members.map { row($0, section: section, home: home) }, isQuiet: section.isQuiet))
        }
        return result
    }

    /// The tab bar's counts (`tabCounts`; the To Review tab shows it as a red badge).
    public func count(_ tab: Tab) -> Int {
        let key = tab == .toReview ? PopoverTab.toReview.rawValue : PopoverTab.mine.rawValue
        if let count = store.home?.status.tabCounts?[key] { return count }
        return sections(tab).filter { !$0.isQuiet }.map(\.rows.count).reduce(0, +)
    }

    public func isCollapsed(_ section: Section) -> Bool { collapsed.contains(section.id) }

    public func toggle(_ section: Section) {
        if collapsed.contains(section.id) { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
    }

    func displayName(_ login: String, home: RemoteHome) -> String { home.displayName(login) }

    func row(_ pr: PRInfo, section: PopoverSection?, home: RemoteHome) -> Row {
        let name = displayName(pr.author, home: home)
        var leading = Leading.avatar(initials: Format.initials(name), colorIndex: Format.avatarIndex(pr.author, count: 8))
        var status: Status?
        var action: Action?
        let job = home.status.jobs.first { $0.pr == pr.id }
        if pr.tab == .toReview || section?.tab == .toReview {
            switch pr.review {
            case "queued", "preparing", "reviewing", "filtering":
                action = .reviewing
                status = .working(job?.phase ?? "Reviewing")
            case "ready":
                action = home.findingCounts?[pr.id].map { .comments($0) } ?? .reviewReady
            default:
                action = .review
            }
        } else if section == nil {
            leading = .state(.ciFailing)
            let entry = home.ci.first { $0.pr == pr.id }
            status = .checksFailed(entry?.failedChecks.map { Format.count($0, "check") + " failed" } ?? "Checks failed")
            action = entry?.phase != nil ? .fixing : .fixCI
            if let job, entry?.phase != nil { status = .working(job.phase) }
        } else {
            switch section {
            case .myFeedback:
                leading = .state(.feedback)
                let comments = store.details[pr.id]?.respond?.items.count
                status = .changesRequested(comments.map { "Changes requested · " + Format.count($0, "comment") }
                                           ?? "Changes requested")
                let running = pr.respond.map { !["ready", "done", "failed", "readyToPush"].contains($0) } ?? false
                action = running ? .responding : .respond
                if running, let job { status = .working(job.phase) }
            case .readyToMerge:
                leading = .state(.ready)
                let approvals = pr.approvals
                status = .approved((approvals.map { "Approved by \($0)" } ?? "Approved") + " · checks passing")
                action = .merge
            default:
                leading = .state(.waiting)
            }
        }
        return Row(pr: pr, title: pr.title, meta: "\(Format.shortRef(pr.id)) · \(pr.baseRef)",
                   age: Format.age(pr.updatedAt, now: now()), leading: leading, status: status, action: action,
                   authorName: name)
    }

    // MARK: Mac pill and offline card

    public var macName: String { connection.macName ?? "Your Mac" }

    public var pillStatus: String {
        if isOffline {
            guard let date = store.lastUpdated else { return "Offline" }
            return "Offline · last seen \(Format.time(date, locale: locale, timeZone: timeZone))"
        }
        guard let date = store.lastUpdated, now().timeIntervalSince(date) >= 60 else { return "Connected · updated just now" }
        return "Connected · updated \(Format.ago(date, now: now()))"
    }

    public var pillAccessibilityLabel: String {
        "\(macName), \(isOffline ? "offline" : "connected"), \(pillStatus.components(separatedBy: " · ").last ?? "")"
    }

    /// The relay can't be reached or refused the connection (not the Mac being away).
    public var isConnectionProblem: Bool { store.link == .relayUnreachable }

    public var offlineTitle: String {
        isConnectionProblem ? "Can't connect to \(macName)" : "\(macName) is offline or asleep"
    }

    public var offlineMessage: String {
        if isConnectionProblem {
            return "There's a problem reaching the relay. You're seeing cached data, and actions are off until the connection is back."
        }
        let when = store.lastUpdated.map { "Last connected \(Format.dayAndTime($0, now: now(), locale: locale, timeZone: timeZone)). " } ?? ""
        return when + "You're seeing cached data, and actions are off until your Mac is back."
    }

    // MARK: Actions

    public func refresh() async {
        guard !isOffline else { return }
        await perform(.refresh)
    }

    public func tryAgain() async {
        await connection.enterForeground()
    }

    public func startReview(_ pr: PRInfo) async {
        await perform(.reviewStart(pr: pr.id, wait: false))
    }

    public func fixCI(_ pr: PRInfo) async {
        await perform(.ciFix(pr: pr.id, wait: false))
    }

    private func perform(_ command: AppCommand) async {
        do {
            try await runner.run(command)
        } catch {
            lastError = error.message
        }
    }
}
