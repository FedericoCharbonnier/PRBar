import Foundation
import PRBarCore
import PRBarRemoteKit

/// Las notificaciones de la Mac → los pushes cifrados de los iPhones (spec P.9): el mismo título y cuerpo, y a dónde
/// lleva tocarlas (`deepLink`, spec R.3).
public enum RemotePushPlanner {
    public static func payloads(for notifications: [PlannedNotification], badge: Int?, now: Date) -> [PushPayload] {
        notifications.map { notification in
            PushPayload(createdAt: now, kind: notification.kind.rawValue, title: notification.title, body: notification.body,
                        threadId: notification.threadIdentifier, pr: notification.prID,
                        deepLink: deepLink(for: notification), badge: badge)
        }
    }

    /// `prbar://pr/<o>/<r>/<n>?screen=…`, `prbar://activity` o `prbar://home` (las agrupadas, sin PR).
    public static func deepLink(for notification: PlannedNotification) -> String {
        switch notification.kind {
        case .updateAvailable, .diskUsage:
            return "prbar://activity"
        default:
            break
        }
        guard let pr = notification.prID, let path = prPath(pr) else { return "prbar://home" }
        let screen: String? = switch notification.kind {
        case .newToReview, .reviewedPRUpdated: "review"
        case .myPRFeedback: "respond"
        case .readyToMerge: "merge"
        case .reviewFinished: notification.respondPRID != nil ? "respond" : "review"
        case .myPRApprovedOrCIFailed, .updateAvailable, .diskUsage: nil
        }
        return "prbar://pr/\(path)" + (screen.map { "?screen=\($0)" } ?? "")
    }

    /// `owner/repo#12` → `owner/repo/12` (con cada parte escapada).
    static func prPath(_ id: String) -> String? {
        let parts = id.split(separator: "#")
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        let repo = parts[0].split(separator: "/")
        guard repo.count == 2 else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        guard let owner = String(repo[0]).addingPercentEncoding(withAllowedCharacters: allowed),
              let name = String(repo[1]).addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "\(owner)/\(name)/\(number)"
    }
}
