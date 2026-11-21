import SwiftUI
import PRBarMobileUI
import UserNotifications

@main
struct PRBarMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView(app: delegate.app)
                // The app icon's badge follows the Mac's (the extension sets it from each push; spec R.5).
                .onChange(of: delegate.app.connection.store.home?.status.badgeCount, initial: true) { _, count in
                    guard !AppBootstrap.isDemo else { return }
                    UNUserNotificationCenter.current().setBadgeCount(count ?? 0)
                }
        }
    }
}
