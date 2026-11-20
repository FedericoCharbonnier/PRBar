import Foundation
import Observation
import PRBarWire

/// `settings` (design §settings, spec R.6): the Mac's notification switches (allowed commands), the Face ID
/// requirement (turning it off is itself gated), and what is local to the phone (paired Mac, unpair, version).
@MainActor @Observable
public final class SettingsModel {
    public struct Toggle: Identifiable, Equatable, Sendable {
        public var id: String { kind.rawValue }
        public var title: String
        public var kind: NotificationSettingName
        public var isOn: Bool
    }

    /// The design's NOTIFICATIONS rows and the Mac switch each one drives.
    public static let rows: [(String, NotificationSettingName)] = [
        ("Review ready", .reviewFinished),
        ("New PR to review", .newToReview),
        ("Changes requested on my PRs", .myFeedback),
        ("Ready to merge", .readyToMerge),
        ("CI failed on my PRs", .approvedOrCI),
    ]

    public let connection: RemoteConnection
    public private(set) var notifications: NotificationsInfo?
    public var alert: String?
    public private(set) var needsRepair = false
    public private(set) var isUnpairing = false
    public let appVersion: String
    @ObservationIgnored private let runner: ActionRunner
    @ObservationIgnored private let onUnpaired: @MainActor () -> Void

    public init(connection: RemoteConnection, runner: ActionRunner, appVersion: String,
                onUnpaired: @escaping @MainActor () -> Void) {
        self.connection = connection
        self.runner = runner
        self.appVersion = appVersion
        self.onUnpaired = onUnpaired
    }

    public var macName: String { connection.macName ?? "Your Mac" }
    public var isOnline: Bool { connection.state == .online }
    public var connectionText: String { isOnline ? "Connected · end-to-end encrypted" : "Offline · end-to-end encrypted" }
    public var requirePresence: Bool { connection.requirePresence }

    public var toggles: [Toggle] {
        Self.rows.map { title, kind in
            Toggle(title: title, kind: kind, isOn: notifications?.kinds[kind.rawValue] ?? false)
        }
    }

    public func load() async {
        do {
            notifications = try await runner.run(.notifyList).decoded(NotificationsInfo.self)
        } catch {
            alert = error.message
        }
    }

    public func set(_ kind: NotificationSettingName, _ enabled: Bool) async {
        let previous = notifications
        notifications?.kinds[kind.rawValue] = enabled
        do {
            try await runner.run(.notifySet(kind: kind, enabled: enabled))
        } catch {
            notifications = previous
            alert = error.message
        }
    }

    /// On: no Face ID. Off: Face ID first (spec P.8). The Mac answers with a new `presencePolicy`.
    public func setRequirePresence(_ enabled: Bool) async {
        do {
            try await runner.run(.remoteSetPresenceRequirement(enabled: enabled),
                                 reason: "Turn off Face ID for merge, push and approve")
        } catch .presenceCancelled {
            return
        } catch .presenceKeyInvalid {
            needsRepair = true
        } catch {
            alert = error.message
        }
    }

    /// "Unpair This Mac": tells the Mac (`unpair`), wipes keys and cache, back to `pair:welcome`.
    public func unpair() async {
        isUnpairing = true
        defer { isUnpairing = false }
        await connection.unpair()
        onUnpaired()
    }
}
