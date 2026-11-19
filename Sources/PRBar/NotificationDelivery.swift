import AppKit
import PRBarCore
import UserNotifications

/// Entrega notificaciones de macOS. Solo funciona si la app corre como bundle (`Scripts/bundle.sh`);
/// con `swift run` no hay bundle id y se registra en el log en vez de fallar.
@MainActor
final class NotificationDelivery: NSObject, UNUserNotificationCenterDelegate {
    /// Click en una notificación de review terminada: recibe el PR y, si la review falló, el id de su registro
    /// en el historial (lo asigna `AppModel`).
    var onOpenReview: ((String, UUID?) -> Void)?
    /// Click en una notificación de "Responder": recibe el PR (lo asigna `AppModel`).
    var onOpenRespond: ((String) -> Void)?
    /// Click en la notificación de una versión nueva (lo asigna `AppModel`).
    var onOpenUpdate: (() -> Void)?

    private nonisolated static let categoryID = "PR"
    private nonisolated static let openActionID = "open"

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center else {
            AppLog.write("Notifications disabled: the app isn't running as a bundle.")
            return
        }
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openActionID, title: "Open", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [open], intentIdentifiers: [])
        ])
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

    func deliver(_ notifications: [PlannedNotification]) {
        guard let center else { return }
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            content.threadIdentifier = notification.threadIdentifier
            var userInfo: [String: String] = [:]
            if let url = notification.url { userInfo["url"] = url.absoluteString }
            if let prID = notification.reviewPRID { userInfo["reviewPRID"] = prID }
            if let recordID = notification.reviewRecordID { userInfo["reviewRecordID"] = recordID.uuidString }
            if let prID = notification.respondPRID { userInfo["respondPRID"] = prID }
            if let version = notification.updateVersion { userInfo["updateVersion"] = version }
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
        let userInfo = response.notification.request.content.userInfo
        if userInfo["updateVersion"] is String {
            Task { @MainActor in self.onOpenUpdate?() }
        } else if let prID = userInfo["respondPRID"] as? String {
            Task { @MainActor in self.onOpenRespond?(prID) }
        } else if let prID = userInfo["reviewPRID"] as? String {
            let recordID = (userInfo["reviewRecordID"] as? String).flatMap(UUID.init(uuidString:))
            Task { @MainActor in self.onOpenReview?(prID, recordID) }
        } else if let string = userInfo["url"] as? String, let url = URL(string: string) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
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
