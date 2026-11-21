#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// The notification service extension's work (spec P.9), apart from the extension class so `swift test` covers it:
/// replaces the relay's generic text with what the Mac encrypted, or keeps the generic text. The envelope (`e`) never
/// stays in `userInfo`, and nothing from it is shown unless it decrypted and passed the checks.
public struct PushNotificationProcessor: Sendable {
    public let opener: PushOpener

    public init(opener: PushOpener) {
        self.opener = opener
    }

    public func process(_ content: UNNotificationContent) -> UNNotificationContent {
        Self.apply(opener.content(userInfo: content.userInfo), to: content)
    }

    /// `content` with `push` applied: title, body, thread, badge, category and `userInfo["deepLink"]`/`["pr"]`.
    public static func apply(_ push: PushContent, to content: UNNotificationContent) -> UNNotificationContent {
        let out = (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        out.title = push.title
        out.subtitle = ""
        out.body = push.body
        if let thread = push.threadIdentifier { out.threadIdentifier = thread }
        out.badge = push.badge.map { NSNumber(value: $0) }
        out.categoryIdentifier = push.categoryIdentifier
        var info = content.userInfo
        info.removeValue(forKey: "e")
        info.removeValue(forKey: "deepLink")
        info.removeValue(forKey: "pr")
        if let link = push.deepLink { info["deepLink"] = link }
        if let pr = push.pr { info["pr"] = pr }
        out.userInfo = info
        return out
    }

    /// What `serviceExtensionTimeWillExpire` delivers: the relay's text, without the envelope.
    public static func generic(_ content: UNNotificationContent) -> UNNotificationContent {
        apply(.generic, to: content)
    }
}
#endif
