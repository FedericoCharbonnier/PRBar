import Combine
import Foundation

/// Spec LP.2: at most one change every `interval` per PR, the last one wins; a PRBar step is published at once (and is
/// never lost to a Claude step that comes right after it; SwiftUI may still coalesce two publications into one redraw). Pure: the caller passes the clock.
public struct ActivityThrottle: Sendable {
    public static let defaultInterval: TimeInterval = 0.5

    public enum Decision: Equatable, Sendable {
        /// Show it now.
        case show(JobActivity)
        /// Kept as the pending one: call `due(now:)` at that time.
        case hold(until: Date)
        /// Nothing changes (it's the step already shown).
        case ignore
    }

    public let interval: TimeInterval
    /// What's on screen.
    public private(set) var shown: JobActivity?
    /// A Claude step waiting for its turn.
    public private(set) var pending: JobActivity?
    private var lastChange: Date?

    public init(interval: TimeInterval = ActivityThrottle.defaultInterval) {
        self.interval = interval
    }

    public mutating func offer(_ activity: JobActivity, now: Date) -> Decision {
        if let shown, shown.kind == activity.kind, shown.text == activity.text {
            // The same step again (e.g. the same file read twice): it keeps its startedAt, and the newer pending one
            // is older news than this.
            pending = nil
            return .ignore
        }
        guard activity.kind != .prbar, let lastChange, now < lastChange.addingTimeInterval(interval) else {
            pending = nil
            shown = activity
            lastChange = now
            return .show(activity)
        }
        pending = activity
        return .hold(until: lastChange.addingTimeInterval(interval))
    }

    /// When the pending step is due (nil without one): `lastChange + interval`.
    public var pendingDue: Date? {
        guard pending != nil, let lastChange else { return nil }
        return lastChange.addingTimeInterval(interval)
    }

    /// The pending step once its time came (it becomes the one shown); nil if there's none or it's still early.
    public mutating func due(now: Date) -> JobActivity? {
        guard let next = pending, let lastChange, now >= lastChange.addingTimeInterval(interval) else { return nil }
        pending = nil
        shown = next
        self.lastChange = now
        return next
    }
}

/// The steps of a queue's running jobs (spec LP.2), one per PR. Its own `ObservableObject`: what only looks at the phases
/// doesn't redraw twice a second.
@MainActor
public final class JobActivityFeed: ObservableObject {
    /// The step each PR's job is on (the `activity[prID]` of the spec).
    @Published public private(set) var current: [String: JobActivity] = [:]

    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private var throttles: [String: ActivityThrottle] = [:]
    /// At most one per PR, armed for its pending step's due time.
    private var timers: [String: (due: Date, task: Task<Void, Never>)] = [:]
    /// Goes up with each `clear`: what an older job's sink sends is ignored.
    private var generations: [String: Int] = [:]
    /// The current job's inbox of each PR: `clear` delivers what it still has first (a job that ends right after a
    /// PRBar step still publishes it once; a view may coalesce that with the clear).
    private var inboxes: [String: ActivityInbox] = [:]

    public init(interval: TimeInterval = ActivityThrottle.defaultInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.interval = interval
        self.now = now
    }

    /// The sink of the job that starts now on `prID`: callable from any thread, delivered in order on the main actor.
    /// Once `clear(prID:)` runs, what it sends is ignored.
    public func sink(prID: String) -> JobActivitySink {
        let generation = generations[prID, default: 0]
        let inbox = ActivityInbox { [weak self] activities in
            self?.receive(activities, prID: prID, generation: generation)
        }
        inboxes[prID] = inbox
        return { inbox.post($0) }
    }

    /// The job ended, failed or was cancelled: no step (spec LP.6). What its sink already sent is published first.
    public func clear(prID: String) {
        inboxes.removeValue(forKey: prID)?.drainNow()
        generations[prID, default: 0] += 1
        throttles[prID] = nil
        timers.removeValue(forKey: prID)?.task.cancel()
        if current[prID] != nil { current[prID] = nil }
    }

    public func clearAll() {
        for prID in Set(current.keys).union(throttles.keys).union(timers.keys).union(inboxes.keys) { clear(prID: prID) }
    }

    private func receive(_ activities: [JobActivity], prID: String, generation: Int) {
        guard generations[prID, default: 0] == generation else { return }
        for activity in activities {
            var throttle = throttles[prID] ?? ActivityThrottle(interval: interval)
            switch throttle.offer(activity, now: now()) {
            case .show(let shown):
                current[prID] = shown
                // What was pending is older news now: its timer has nothing to show.
                timers.removeValue(forKey: prID)?.task.cancel()
            case .hold(let until):
                schedule(prID, at: until, generation: generation)
            case .ignore:
                break
            }
            throttles[prID] = throttle
        }
    }

    /// One timer per PR, for the pending step's due time: when it fires it shows what's pending then (the last one).
    /// If the due time moved, it's re-armed for the new one; if it fired early, for the same one (not a whole
    /// `interval` later).
    private func schedule(_ prID: String, at date: Date, generation: Int) {
        if let timer = timers[prID] {
            guard timer.due != date else { return }
            timer.task.cancel()
        }
        let delay = max(0, date.timeIntervalSince(now()))
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000) + 1))
            guard !Task.isCancelled, let self else { return }
            self.timers[prID] = nil
            guard self.generations[prID, default: 0] == generation, var throttle = self.throttles[prID] else { return }
            if let next = throttle.due(now: self.now()) { self.current[prID] = next }
            self.throttles[prID] = throttle
            if let due = throttle.pendingDue { self.schedule(prID, at: due, generation: generation) }
        }
        timers[prID] = (date, task)
    }
}

/// What a sink posted from any thread, until the main actor takes it: one drain at a time, so the order holds.
private final class ActivityInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [JobActivity] = []
    private var scheduled = false
    private let deliver: @MainActor ([JobActivity]) -> Void

    init(deliver: @escaping @MainActor ([JobActivity]) -> Void) {
        self.deliver = deliver
    }

    func post(_ activity: JobActivity) {
        let start = lock.withLock { () -> Bool in
            buffer.append(activity)
            defer { scheduled = true }
            return !scheduled
        }
        guard start else { return }
        Task { @MainActor in self.drain() }
    }

    /// What's buffered, now (`JobActivityFeed.clear`).
    @MainActor func drainNow() { drain() }

    @MainActor private func drain() {
        let batch = lock.withLock { () -> [JobActivity] in
            defer { buffer = []; scheduled = false }
            return buffer
        }
        deliver(batch)
    }
}
