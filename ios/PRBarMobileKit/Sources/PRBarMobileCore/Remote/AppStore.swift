import Foundation
import Observation
import PRBarRemoteKit
import PRBarWire

/// What the phone knows about the Mac (spec R.3): fed by `state` frames and the mailbox, persisted to the cache.
@MainActor @Observable
public final class AppStore {
    public private(set) var home: RemoteHome?
    public private(set) var details: [String: RemotePRDetail] = [:]
    public private(set) var activity: RemoteActivity?
    /// When the Mac last sent (or the mailbox last carried) `home`.
    public private(set) var lastUpdated: Date?
    /// Set by `RemoteConnection`.
    public internal(set) var link: LinkState = .connecting

    /// Cached/offline data is shown greyed out and actions are off.
    public var isStale: Bool { link != .online }

    /// Revisions seen in this session, per topic: a lower or equal `rev` is ignored. A new session starts over (the
    /// Mac may have restarted), except for `home`, whose last revision also gates the mailbox (spec Q.1: the relay
    /// cannot roll the state back).
    @ObservationIgnored private var sessionRevs: [String: Int] = [:]
    @ObservationIgnored public private(set) var homeRev: Int = -1
    @ObservationIgnored private let cache: Cache?
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(cache: Cache? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.cache = cache
        self.now = now
        if let entry = cache?.loadHome() {
            home = entry.value
            homeRev = entry.rev
            lastUpdated = entry.savedAt
        }
    }

    /// Seeds the store (previews, demo mode).
    public init(home: RemoteHome?, details: [String: RemotePRDetail] = [:], activity: RemoteActivity? = nil,
                link: LinkState = .online, lastUpdated: Date? = nil) {
        self.cache = nil
        self.now = Date.init
        self.home = home
        self.details = details
        self.activity = activity
        self.link = link
        self.lastUpdated = lastUpdated
    }

    public func beginSession() {
        sessionRevs = [:]
    }

    /// Applies a `state` frame. Returns false when it was ignored (old revision or undecodable).
    @discardableResult
    public func apply(_ update: RemoteStateUpdate) -> Bool {
        if let seen = sessionRevs[update.topic], update.rev <= seen { return false }
        do {
            switch update.topic {
            case Topic.home:
                let value = try update.data.decode(RemoteHome.self)
                setHome(value, rev: update.rev)
            case Topic.activity:
                activity = try update.data.decode(RemoteActivity.self)
            case let topic where topic.hasPrefix("pr:"):
                let detail = try update.data.decode(RemotePRDetail.self)
                details[String(topic.dropFirst(3))] = detail
                try? cache?.savePR(detail, rev: update.rev, at: now())
            default:
                return false
            }
        } catch {
            return false
        }
        sessionRevs[update.topic] = update.rev
        return true
    }

    /// The mailbox's `home`, used only when it is newer than what the phone already has.
    @discardableResult
    public func applyMailbox(_ update: RemoteStateUpdate) -> Bool {
        guard update.topic == Topic.home, update.rev > homeRev,
              let value = try? update.data.decode(RemoteHome.self) else { return false }
        setHome(value, rev: update.rev)
        return true
    }

    /// A PR's detail from memory or, offline, from the cache.
    public func detail(for id: String) -> RemotePRDetail? {
        if let detail = details[id] { return detail }
        guard let cached = cache?.loadPR(id)?.value else { return nil }
        details[id] = cached
        return cached
    }

    public func wipe() {
        home = nil
        details = [:]
        activity = nil
        lastUpdated = nil
        sessionRevs = [:]
        homeRev = -1
        try? cache?.wipe()
    }

    private func setHome(_ value: RemoteHome, rev: Int) {
        home = value
        homeRev = rev
        lastUpdated = now()
        try? cache?.saveHome(value, rev: rev, at: lastUpdated!)
    }
}
