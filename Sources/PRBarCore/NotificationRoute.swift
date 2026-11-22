import Foundation

/// A dónde lleva el clic en una notificación (spec M.4).
public enum NotificationTarget: Equatable, Sendable {
    case destination(MainDestination)
    case updateSheet
    case url(URL)
}

public enum NotificationRoute {
    /// Lo que viaja en `UNNotificationContent.userInfo` (antes lo armaba `NotificationDelivery`).
    public static func userInfo(_ n: PlannedNotification) -> [String: String] {
        var info: [String: String] = [:]
        if let url = n.url { info["url"] = url.absoluteString }
        if let prID = n.reviewPRID { info["reviewPRID"] = prID }
        if let recordID = n.reviewRecordID { info["reviewRecordID"] = recordID.uuidString }
        if let prID = n.respondPRID { info["respondPRID"] = prID }
        if let version = n.updateVersion { info["updateVersion"] = version }
        if let prID = n.prID { info["prID"] = prID }
        if let prID = n.mergePRID { info["mergePRID"] = prID }
        if let tab = n.tab { info["tab"] = tab.rawValue }
        if n.kind == .diskUsage { info["activity"] = "1" }
        return info
    }

    public static func target(userInfo info: [String: String]) -> NotificationTarget? {
        if info["activity"] != nil { return .destination(.activity) }
        if info["updateVersion"] != nil { return .updateSheet }
        if let id = info["reviewRecordID"].flatMap(UUID.init(uuidString:)) { return .destination(.history(recordID: id)) }
        if let prID = info["mergePRID"] ?? info["respondPRID"] ?? info["reviewPRID"] ?? info["prID"] {
            return .destination(.pr(prID: prID, tab: info["tab"].flatMap(PRTab.init(rawValue:))))
        }
        if let url = info["url"].flatMap(URL.init(string:)) { return .url(url) }
        return nil
    }
}
