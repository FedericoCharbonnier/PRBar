import Foundation

/// What a running job is doing right now (spec LP.2): PRBar's own step or Claude's tool, as a short text already built
/// (in English, like the rest of the UI). Plain text everywhere: never interpreted.
public struct JobActivity: Codable, Equatable, Sendable {
    /// Who does it. Lenient: an unknown value (a newer PRBar) is `prbar`.
    public enum Kind: String, Codable, Sendable {
        case prbar, claude

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .prbar
        }
    }

    public var kind: Kind
    /// "Creating the worktree…", "Reading src/shop/tax.py".
    public var text: String
    /// When this step started.
    public var startedAt: Date

    public init(kind: Kind, text: String, startedAt: Date = Date()) {
        self.kind = kind
        self.text = text
        self.startedAt = startedAt
    }

    /// "12 s", "2 min 5 s", "1 h 3 min" (spec LP.5).
    public static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min \(total % 60) s" }
        return "\(total / 3600) h \(total % 3600 / 60) min"
    }

    /// How long this step has been going on at `now`.
    public func elapsedText(now: Date) -> String { Self.elapsedText(now.timeIntervalSince(startedAt)) }
}
