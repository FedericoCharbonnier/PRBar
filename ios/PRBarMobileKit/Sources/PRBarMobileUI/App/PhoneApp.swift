import Foundation
import Observation
import PRBarMobileCore
import PRBarRemoteKit
import PRBarWire

public enum AppTab: String, Hashable, Sendable { case toReview, mine, activity, settings }

/// A pushed detail screen.
public enum Route: Hashable, Sendable {
    case review(String)
    case respond(String, RespondModel.Mode)
    case merge(String)
    case chat(String, ChatModel.Kind)
    case pr(String)
}

/// The app's object graph: the connection, the action runner and the navigation state. The app target builds it with
/// the real keychain and Face ID; `demo()` builds it on a `FakeTransport` with the design's sample data.
@MainActor @Observable
public final class PhoneApp {
    public let connection: RemoteConnection
    public let runner: ActionRunner
    public let keychain: DeviceKeychain
    public let appVersion: String
    public var tab: AppTab = .toReview
    public var paths: [AppTab: [Route]] = [:]
    /// A pairing link opened while already paired: the pairing flow over the tabs, starting at the confirmation.
    public var isPairingSheetPresented = false
    public private(set) var pairing: PairingModel!
    public private(set) var home: HomeModel
    @ObservationIgnored private let now: () -> Date

    public init(connection: RemoteConnection, authorizer: any PresenceAuthorizer, keychain: DeviceKeychain,
                pairingService: any PairingService,
                makePresenceKey: @escaping @Sendable () throws -> (keyData: Data, publicKey: Data),
                notifications: any NotificationPermission, appVersion: String, now: @escaping () -> Date = Date.init) {
        self.connection = connection
        self.keychain = keychain
        self.appVersion = appVersion
        self.now = now
        runner = ActionRunner(connection: connection, authorizer: authorizer)
        home = HomeModel(connection: connection, runner: runner, now: now)
        pairing = PairingModel(service: pairingService, keychain: keychain, makePresenceKey: makePresenceKey,
                               notifications: notifications) { [weak self] mac in
            self?.didPair(mac)
        }
    }

    public var needsPairing: Bool {
        switch connection.state {
        case .unpaired, .revoked: true
        default: false
        }
    }

    func didPair(_ mac: StoredPairedMac) {
        isPairingSheetPresented = false
        connection.didPair(macName: mac.macName)
        Task { await connection.enterForeground() }
    }

    public func didUnpair() {
        tab = .toReview
        paths = [:]
        pairing.cancelScanning()
    }

    public func path(_ tab: AppTab) -> [Route] { paths[tab] ?? [] }

    public func push(_ route: Route, on tab: AppTab? = nil) {
        let target = tab ?? self.tab
        paths[target, default: []].append(route)
    }

    /// A notification or Camera link.
    public func open(_ link: DeepLink) {
        switch link {
        case .pair(let url):
            // Never straight to joining, and never silently over an existing pairing (L4).
            if needsPairing {
                pairing.open(url)
            } else {
                pairing.open(url, replacing: connection.macName ?? "your Mac")
                isPairingSheetPresented = true
            }
        case .pr(let id, let screen):
            guard !needsPairing else { return }
            let info = connection.store.home?.prs.first { $0.id == id }
            let mine = info?.tab == .mine
            tab = mine ? .mine : .toReview
            let route: Route = switch screen {
            case .review: .review(id)
            case .respond: .respond(id, .feedback)
            case .merge: .merge(id)
            case .chat: .chat(id, mine ? .respond : .review)
            case nil: defaultRoute(for: id)
            }
            paths[tab] = [route]
        }
    }

    /// Where tapping a row goes.
    public func defaultRoute(for id: String) -> Route {
        guard let info = connection.store.home?.prs.first(where: { $0.id == id }) else { return .pr(id) }
        if connection.store.home?.ci.contains(where: { $0.pr == id }) == true { return .respond(id, .ciFix) }
        switch info.section {
        case .toReview, .updatedSinceMyReview, .otherToReview: return .review(id)
        case .myFeedback: return .respond(id, .feedback)
        case .readyToMerge: return .merge(id)
        default: return .pr(id)
        }
    }

    // MARK: Models for screens

    public func reviewModel(_ pr: String) -> ReviewModel { ReviewModel(pr: pr, connection: connection, runner: runner) }
    public func respondModel(_ pr: String, _ mode: RespondModel.Mode) -> RespondModel {
        RespondModel(pr: pr, mode: mode, connection: connection, runner: runner, now: now)
    }
    public func mergeModel(_ pr: String) -> MergeModel { MergeModel(pr: pr, connection: connection, runner: runner) }
    public func chatModel(_ pr: String, _ kind: ChatModel.Kind) -> ChatModel {
        ChatModel(pr: pr, kind: kind, connection: connection, runner: runner)
    }
    public func activityModel() -> ActivityModel { ActivityModel(connection: connection, runner: runner, now: now) }
    public func settingsModel() -> SettingsModel {
        SettingsModel(connection: connection, runner: runner, appVersion: appVersion) { [weak self] in self?.didUnpair() }
    }
}
