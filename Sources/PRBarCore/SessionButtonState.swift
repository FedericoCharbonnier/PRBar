import Foundation

/// The Terminal control and ⌥⌘T (spec T.4), per folder: PRBar working in one folder doesn't block the sessions of
/// another (Respond running doesn't stop the review's session from opening).
extension SessionOffer {
    public struct ButtonState: Equatable, Sendable {
        public let enabled: Bool
        public let help: String
    }

    /// Off with nothing to offer or when every session's folder is busy (`busyIDs`: session ids).
    public static func buttonState(_ sessions: [ClaudeSessionRef], busyIDs: Set<String>, terminal: String) -> ButtonState {
        let allBusy = !sessions.isEmpty && sessions.allSatisfy { busyIDs.contains($0.id) }
        return ButtonState(enabled: !sessions.isEmpty && !allBusy,
                           help: help(count: sessions.count, busy: allBusy, terminal: terminal))
    }

    /// What ⌥⌘T opens: the most recent session, unless PRBar is working in its folder.
    public static func commandSession(_ sessions: [ClaudeSessionRef], busyIDs: Set<String>) -> ClaudeSessionRef? {
        guard let latest = mostRecent(sessions), !busyIDs.contains(latest.id) else { return nil }
        return latest
    }
}
