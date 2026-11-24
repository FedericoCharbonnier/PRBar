import Foundation
import os

/// A Claude Code session id and when PRBar heard of it (spec T.2).
public struct ClaudeSessionStamp: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var startedAt: Date

    public init(id: String, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }
}

/// Keeps the last session id `ClaudeInvocation.onSession` reported (the retry's, if there was one). Thread-safe:
/// the runner calls it from the process's reader thread.
public final class ClaudeSessionCapture: Sendable {
    private let state = OSAllocatedUnfairLock<ClaudeSessionStamp?>(initialState: nil)
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func record(_ id: String) {
        let stamp = ClaudeSessionStamp(id: id, startedAt: now())
        state.withLock { $0 = stamp }
    }

    public var stamp: ClaudeSessionStamp? { state.withLock { $0 } }
}
