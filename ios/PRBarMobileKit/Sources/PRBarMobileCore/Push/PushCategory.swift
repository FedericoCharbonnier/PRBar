import Foundation

/// Notification categories and their actions (spec P.9, R.5). The relay always sends category `PR` (it can't know
/// more); the extension switches to the one matching the decrypted deep link. Every action opens the app on that PR
/// (`.foreground`): nothing gated ever runs from a notification, Merge opens the merge sheet with its Face ID step.
public enum PushCategory {
    /// What the relay sends, and what a push the extension couldn't open keeps: no actions, tapping opens the app.
    public static let generic = "PR"
    public static let review = "PR.review"
    public static let respond = "PR.respond"
    public static let merge = "PR.merge"

    public struct Action: Equatable, Sendable {
        public var identifier: String
        public var title: String
        public var systemImage: String
    }

    public static let openAction = Action(identifier: "open", title: "Open", systemImage: "arrow.up.forward.app")
    public static let reviewAction = Action(identifier: "review", title: "Review", systemImage: "text.magnifyingglass")
    public static let respondAction = Action(identifier: "respond", title: "Respond", systemImage: "arrowshape.turn.up.left")
    public static let mergeAction = Action(identifier: "merge", title: "Merge", systemImage: "arrow.triangle.merge")
    public static let chatAction = Action(identifier: "chat", title: "Chat with Claude", systemImage: "bubble.left.and.text.bubble.right")

    /// Every category the app registers, with its actions in order.
    public static let all: [(identifier: String, actions: [Action])] = [
        (generic, []),
        (review, [reviewAction, chatAction]),
        (respond, [respondAction, chatAction]),
        (merge, [mergeAction]),
    ]

    /// The category for a decrypted deep link.
    public static func identifier(for link: DeepLink?) -> String {
        guard case .pr(_, let screen)? = link else { return generic }
        return switch screen {
        case .review?: review
        case .respond?: respond
        case .merge?: merge
        case .chat?, nil: generic
        }
    }

    /// What tapping the notification (or one of its actions) opens. `deepLink` is the one the extension put in
    /// `userInfo`; without it (a push that stayed generic) the app opens on Home.
    public static func link(forAction actionIdentifier: String, deepLink: String?) -> DeepLink {
        guard let link = deepLink.flatMap(URL.init(string:)).flatMap(DeepLink.init), link.isNotificationTarget else {
            return .home
        }
        switch actionIdentifier {
        case chatAction.identifier: return link.with(screen: .chat)
        case reviewAction.identifier: return link.with(screen: .review)
        case respondAction.identifier: return link.with(screen: .respond)
        case mergeAction.identifier: return link.with(screen: .merge)
        default: return link
        }
    }
}
