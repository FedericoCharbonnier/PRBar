import PRBarMobileCore
import PRBarMobileUI
import UIKit
import UserNotifications

/// Push notifications (spec P.9, R.5, plan 19 Task 8): the categories and their actions, the APNs token for the
/// relay, and what tapping a notification opens. The notification service extension decrypts the text; this side
/// only reads the deep link it left in `userInfo`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let app = AppBootstrap.make()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.categories)
        guard !AppBootstrap.isDemo else { return true }
        // Apple hands out a token on every launch (it can change); only once the user allowed notifications, which
        // the app asks right after pairing (`SystemNotificationPermission`).
        Task {
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: application.registerForRemoteNotifications()
            default: break
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let registration = PushRegistration(deviceToken: deviceToken, environment: AppBootstrap.pushEnvironment)
        Task { await app.connection.setPushRegistration(registration) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No token (simulator, no aps-environment entitlement in an unsigned build): the app works without pushes.
    }

    static var categories: Set<UNNotificationCategory> {
        Set(PushCategory.all.map { category in
            UNNotificationCategory(
                identifier: category.identifier,
                actions: category.actions.map { action in
                    // `.foreground` only: a notification never runs anything by itself (merge opens the sheet with
                    // its Face ID step).
                    UNNotificationAction(identifier: action.identifier, title: action.title, options: [.foreground],
                                         icon: UNNotificationActionIcon(systemImageName: action.systemImage))
                },
                intentIdentifiers: [], options: [])
        })
    }

    // MARK: UNUserNotificationCenterDelegate

    /// With the app open on that PR, no banner (it's already on screen). Only strings cross to the main actor.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let pr = notification.request.content.userInfo["pr"] as? String
        let onScreen = await MainActor.run {
            pr != nil && pr == app.visiblePR && UIApplication.shared.applicationState == .active
        }
        return onScreen ? [] : [.banner, .list, .sound, .badge]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let deepLink = response.notification.request.content.userInfo["deepLink"] as? String
        let link = PushCategory.link(forAction: response.actionIdentifier, deepLink: deepLink)
        await MainActor.run { app.open(link) }
    }
}
