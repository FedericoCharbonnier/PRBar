import Foundation

/// `prbar://pr/<owner>/<repo>/<n>[?screen=review|respond|merge|chat]`, `prbar://home` and `prbar://activity`
/// (notifications, spec Q.4 "Pushes") and `prbar://pair?…` (the Camera app), spec R.3.
public enum DeepLink: Equatable, Sendable {
    public enum Screen: String, Sendable { case review, respond, merge, chat }

    case pr(id: String, screen: Screen?)
    case home
    case activity
    case pair(URL)

    public init?(_ url: URL) {
        guard url.scheme == "prbar" else { return nil }
        switch url.host() {
        case "pair":
            self = .pair(url)
        case "home":
            self = .home
        case "activity":
            self = .activity
        case "pr":
            let parts = url.path().split(separator: "/").map(String.init)
            guard parts.count == 3, let number = Int(parts[2]), number > 0,
                  parts[0].allSatisfy(Self.isNameCharacter), parts[1].allSatisfy(Self.isNameCharacter) else { return nil }
            let screen = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "screen" }?.value.flatMap(Screen.init(rawValue:))
            self = .pr(id: "\(parts[0])/\(parts[1])#\(number)", screen: screen)
        default:
            return nil
        }
    }

    /// What a notification may open: anything but pairing (a push never starts a pairing, even one from the Mac).
    public var isNotificationTarget: Bool {
        if case .pair = self { return false }
        return true
    }

    /// The same PR on another screen (a notification action: "Chat" on a review notification).
    public func with(screen: Screen) -> DeepLink {
        if case .pr(let id, _) = self { return .pr(id: id, screen: screen) }
        return self
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_" || c == ".")
    }
}
