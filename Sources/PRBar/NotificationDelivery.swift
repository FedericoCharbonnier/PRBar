import AppKit
import PRBarCore
import UserNotifications

/// Entrega notificaciones de macOS. Solo funciona si la app corre como bundle (`Scripts/bundle.sh`);
/// con `swift run` no hay bundle id y se registra en el log en vez de fallar.
@MainActor
final class NotificationDelivery: NSObject, UNUserNotificationCenterDelegate {
    /// Clic en una notificación (o en su botón "Open"): a dónde lleva (spec M.4; lo asigna `AppModel`).
    var onOpen: ((NotificationTarget) -> Void)?

    private nonisolated static let categoryID = "PR"
    private nonisolated static let openActionID = "open"

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// El delegado y las categorías van acá, antes de que termine de arrancar la app (se crea en
    /// `applicationWillFinishLaunching`): el clic en una notificación que abrió PRBar llega enseguida y, sin delegado,
    /// se pierde (M10). Pedir permiso sigue esperando a `requestAuthorization`.
    override init() {
        super.init()
        guard let center else { return }
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openActionID, title: "Open", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [open], intentIdentifiers: [])
        ])
    }

    func requestAuthorization() {
        guard let center else {
            AppLog.write("Notifications disabled: the app isn't running as a bundle.")
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { AppLog.write("Notification permission: \(error.localizedDescription)") }
            if !granted { AppLog.write("The user didn't allow notifications.") }
        }
    }

    /// `true` si el usuario negó las notificaciones en Ajustes del Sistema.
    func isDenied() async -> Bool {
        guard let center else { return false }
        return await center.notificationSettings().authorizationStatus == .denied
    }

    /// También a los iPhones emparejados (lo asigna `AppModel`, spec P.9). Corre aunque no haya bundle.
    var onDeliver: (([PlannedNotification]) -> Void)?

    func deliver(_ notifications: [PlannedNotification]) {
        onDeliver?(notifications)
        guard let center else { return }
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            content.threadIdentifier = notification.threadIdentifier
            let userInfo = NotificationRoute.userInfo(notification)
            content.userInfo = userInfo
            if !userInfo.isEmpty { content.categoryIdentifier = Self.categoryID }
            let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
            center.add(request) { error in
                if let error { AppLog.write("Couldn't show the notification: \(error.localizedDescription)") }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Click en la notificación o en su botón "Abrir": hacen lo mismo.
        guard [UNNotificationDefaultActionIdentifier, Self.openActionID].contains(response.actionIdentifier) else {
            completionHandler()
            return
        }
        let info = response.notification.request.content.userInfo.reduce(into: [String: String]()) {
            if let key = $1.key as? String, let value = $1.value as? String { $0[key] = value }
        }
        if let target = NotificationRoute.target(userInfo: info) {
            Task { @MainActor in self.onOpen?(target) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
