import Foundation
import PRBarMobileCore
import UserNotifications

/// Opens the Mac's encrypted push (spec P.9): the relay and Apple only ever see "PRBar — New activity on your Mac" and
/// an HPKE envelope in `e`. With `devicePushKey` and the paired Mac from the shared keychain, the extension replaces
/// title, body, thread, badge and category and leaves the deep link in `userInfo`. A push it can't open (no pairing,
/// another key, broken, older than a day, already shown) keeps the generic text; so does running out of time.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (handler: (UNNotificationContent) -> Void, original: UNNotificationContent)?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.withLock { pending = (contentHandler, request.content) }
        let content = Self.processor.map { $0.process(request.content) }
            ?? PushNotificationProcessor.generic(request.content)
        deliver(content)
    }

    override func serviceExtensionTimeWillExpire() {
        let original = lock.withLock { pending?.original }
        if let original { deliver(PushNotificationProcessor.generic(original)) }
    }

    /// Calls the handler once, whichever comes first.
    private func deliver(_ content: UNNotificationContent) {
        let handler = lock.withLock { () -> ((UNNotificationContent) -> Void)? in
            defer { pending = nil }
            return pending?.handler
        }
        handler?(content)
    }

    /// Nil when the App Group container is missing (an unsigned build): then every push stays generic.
    static var processor: PushNotificationProcessor? {
        let info = Bundle.main.infoDictionary
        guard let group = info?["PRBarAppGroup"] as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return nil
        }
        let accessGroup = (info?["PRBarKeychainAccessGroup"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        let keychain = DeviceKeychain(backend: SystemKeychain(), accessGroup: accessGroup)
        return PushNotificationProcessor(opener: PushOpener(keychain: keychain, seen: SeenPushFile(container: container)))
    }
}
