import Foundation

/// Cuándo empezó una tarea de Claude y si la pidió un iPhone (spec M.1 grupo Claude, M.4).
public struct ClaudeRunInfo: Equatable, Sendable {
    public var startedAt: Date
    public var requestedOnPhone: Bool

    public init(startedAt: Date, requestedOnPhone: Bool) {
        self.startedAt = startedAt
        self.requestedOnPhone = requestedOnPhone
    }
}

public struct ClaudeTaskInput: Sendable {
    public var prID: String
    public var review: ReviewPhase?
    public var reviewStartedAt: Date?
    public var respond: RespondPhase?
    public var respondMode: RespondMode
    public var runningTests: Bool
    public var respondStartedAt: Date?
    public var fromPhone: Bool

    public init(prID: String, review: ReviewPhase? = nil, reviewStartedAt: Date? = nil, respond: RespondPhase? = nil,
                respondMode: RespondMode = .feedback, runningTests: Bool = false, respondStartedAt: Date? = nil,
                fromPhone: Bool = false) {
        self.prID = prID
        self.review = review
        self.reviewStartedAt = reviewStartedAt
        self.respond = respond
        self.respondMode = respondMode
        self.runningTests = runningTests
        self.respondStartedAt = respondStartedAt
        self.fromPhone = fromPhone
    }
}

public struct ClaudeTaskRow: Equatable, Identifiable, Sendable {
    public var id: String { "\(prID)|\(tab.rawValue)" }
    public let prID: String
    /// "web#482".
    public let title: String
    /// "Reviewing · 1:12", "Fix CI · ready to push", "Review ready · 4 findings".
    public let subtitle: String
    public let tab: PRTab
    public let isRunning: Bool
    public let fromPhone: Bool
}

public enum TabIndicator: Equatable, Sendable { case running, ready }

/// "Tarea lista" = review lista sin publicar, Respond o Fix CI terminado sin pushear (o, en Respond, el análisis
/// esperando que el usuario elija). Sale cuando se publica, se pushea o se descarta.
public enum ClaudeTasksSidebar {
    public static func rows(_ inputs: [ClaudeTaskInput], now: Date) -> [ClaudeTaskRow] {
        let all = inputs.flatMap { [reviewRow($0, now: now), respondRow($0, now: now)].compactMap { $0 } }
        return all.filter(\.isRunning) + all.filter { !$0.isRunning }
    }

    static func reviewRow(_ input: ClaudeTaskInput, now: Date) -> ClaudeTaskRow? {
        let subtitle: String, running: Bool
        switch input.review {
        case .queued?: (subtitle, running) = ("Review · queued", true)
        case .preparing?, .reviewing?, .filtering?:
            (subtitle, running) = (timed("Reviewing", since: input.reviewStartedAt, now: now), true)
        case .ready(let draft)?:
            let count = draft.keptCount
            (subtitle, running) = ("Review ready · \(count) finding\(count == 1 ? "" : "s")", false)
        default: return nil
        }
        return ClaudeTaskRow(prID: input.prID, title: shortName(input.prID), subtitle: subtitle, tab: .review,
                             isRunning: running, fromPhone: input.fromPhone)
    }

    static func respondRow(_ input: ClaudeTaskInput, now: Date) -> ClaudeTaskRow? {
        let ci = input.respondMode == .ciFix
        let name = switch input.respondMode {
        case .ciFix: "Fix CI"
        case .conflicts: "Resolve Conflicts"
        case .feedback: "Respond"
        }
        // Fix CI y Resolve Conflicts implementan solos (K.6.3, C.3).
        let implementsAlone = ci || input.respondMode == .conflicts
        let since = input.respondStartedAt
        let subtitle: String, running: Bool
        switch input.respond {
        case .queued?: (subtitle, running) = ("\(name) · queued", true)
        case .preparing?, .analyzing?: (subtitle, running) = (timed("Analyzing", since: since, now: now), true)
        // Fix CI y Resolve Conflicts no tienen nada que elegir: su `ready` dura un instante antes de implementar.
        case .ready?: (subtitle, running) = implementsAlone ? (timed("Analyzing", since: since, now: now), true)
                                               : ("Respond · ready to choose", false)
        case .implementing?: (subtitle, running) = (timed("Implementing", since: since, now: now), true)
        case .readyToPush?:
            (subtitle, running) = input.runningTests ? (timed("Running tests", since: since, now: now), true)
                                                     : ("\(name) · ready to push", false)
        case .pushing?: (subtitle, running) = ("Pushing…", true)
        default: return nil
        }
        return ClaudeTaskRow(prID: input.prID, title: shortName(input.prID), subtitle: subtitle,
                             tab: ci ? .fixCI : .respond, isRunning: running, fromPhone: input.fromPhone)
    }

    public static func groupTitle(_ rows: [ClaudeTaskRow]) -> String {
        let running = rows.filter(\.isRunning).count
        return running > 0 || rows.isEmpty ? "Claude · \(running) running" : "Claude · \(rows.count) ready"
    }

    /// La franja del popover (spec M.3); nil sin tareas.
    public static func popoverStrip(_ rows: [ClaudeTaskRow]) -> String? {
        guard !rows.isEmpty else { return nil }
        let running = rows.filter(\.isRunning).count
        return "Claude · \(running) running · \(rows.count - running) ready"
    }

    /// Spinner violeta o punto verde en la pestaña del PR (spec M.1).
    public static func indicator(prID: String, tab: PRTab, rows: [ClaudeTaskRow]) -> TabIndicator? {
        guard let row = rows.first(where: { $0.prID == prID && $0.tab == tab }) else { return nil }
        return row.isRunning ? .running : .ready
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "acme/web#482" → "web#482".
    public static func shortName(_ prID: String) -> String {
        prID.split(separator: "/").last.map(String.init) ?? prID
    }

    static func timed(_ label: String, since: Date?, now: Date) -> String {
        since.map { "\(label) · \(clock(now.timeIntervalSince($0)))" } ?? label
    }
}
