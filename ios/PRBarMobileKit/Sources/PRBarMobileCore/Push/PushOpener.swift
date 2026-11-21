import CryptoKit
import Foundation
import PRBarRemoteKit
import PRBarWire

/// What a notification shows once the extension is done with it (spec P.9, R.5).
public struct PushContent: Equatable, Sendable {
    public var title: String
    public var body: String
    /// The Mac's thread (groups a PR's notifications); nil keeps the relay's opaque `thread-id`.
    public var threadIdentifier: String?
    public var badge: Int?
    /// `prbar://…`, what tapping it opens (`userInfo["deepLink"]`).
    public var deepLink: String?
    /// `owner/repo#n` (`userInfo["pr"]`): no banner while the app shows that PR.
    public var pr: String?
    public var categoryIdentifier: String

    /// What the relay put in the clear, and all that's left when the extension can't open the envelope.
    public static let generic = PushContent(title: "PRBar", body: "New activity on your Mac", threadIdentifier: nil,
                                            badge: nil, deepLink: nil, pr: nil,
                                            categoryIdentifier: PushCategory.generic)
}

/// Why a push stays generic. None of them shows anything that came in the push.
public enum PushRejection: Error, Equatable, Sendable {
    /// No `e` field, or not base64.
    case missingEnvelope
    /// No pairing (or keys) in the shared keychain: unpaired, revoked, or the extension can't read the group.
    case notPaired
    /// HPKE didn't open: another Mac's key, another device's push, a broken payload.
    case undecryptable
    case unsupportedVersion
    /// `createdAt` more than 24 h ago (or more than 10 min in the future): a push the relay kept and sent again.
    case stale
    /// An `id` already shown (the last 200 are kept): the relay replaying a push.
    case replayed
}

/// The ids of the pushes already shown (spec P.9: the last 200).
public protocol SeenPushStore: Sendable {
    /// Records `id`; false if it was already there.
    func insert(_ id: UUID) -> Bool
}

/// Opens the HPKE envelope of a push (spec P.9) with `devicePushKey` and the Mac's `macSealKey.pub` from the shared
/// keychain, checks its age and that it wasn't shown before, and turns it into what the notification shows. Used by the
/// notification service extension; everything here runs on macOS too, so `swift test` covers it.
public struct PushOpener: Sendable {
    /// A push is at most a day old (APNs keeps it that long: `apns-expiration` = now + 86 400).
    public static let maxAge: TimeInterval = 24 * 3600
    /// Clock difference tolerated between the Mac and the iPhone for a `createdAt` in the future.
    public static let maxClockSkew: TimeInterval = MailboxBlob.maxClockSkew

    let keychain: DeviceKeychain
    let seen: any SeenPushStore
    let now: @Sendable () -> Date

    public init(keychain: DeviceKeychain, seen: any SeenPushStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.keychain = keychain
        self.seen = seen
        self.now = now
    }

    /// The opened push, or why it stays generic.
    public func open(userInfo: [AnyHashable: Any]) -> Result<PushPayload, PushRejection> {
        guard let field = userInfo["e"] as? String, !field.isEmpty, Data(base64Encoded: field) != nil else {
            return .failure(.missingEnvelope)
        }
        guard let (mac, keys) = keychain.loadSession(),
              let macSeal = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: mac.macSeal) else {
            return .failure(.notPaired)
        }
        let payload: PushPayload
        do {
            payload = try PushPayload.open(apnsField: field, by: keys.push, from: macSeal,
                                           info: SealedInfo.push(account: mac.accountId, device: mac.deviceId))
        } catch {
            return .failure(.undecryptable)
        }
        guard payload.v == 1 else { return .failure(.unsupportedVersion) }
        let age = now().timeIntervalSince(payload.createdAt)
        guard age <= Self.maxAge, age >= -Self.maxClockSkew else { return .failure(.stale) }
        // Last, so a push rejected for another reason doesn't use up its id.
        guard seen.insert(payload.id) else { return .failure(.replayed) }
        return .success(payload)
    }

    /// What to show: the Mac's text, or `PushContent.generic` when anything is off.
    public func content(userInfo: [AnyHashable: Any]) -> PushContent {
        guard case .success(let payload) = open(userInfo: userInfo) else { return .generic }
        return Self.content(for: payload)
    }

    /// The decrypted payload as notification content. Titles and bodies are cleaned again (one line titles, no
    /// control or bidi characters) even though the Mac already did; a link that isn't a notification target is dropped.
    public static func content(for payload: PushPayload) -> PushContent {
        let link = URL(string: payload.deepLink).flatMap(DeepLink.init).flatMap { $0.isNotificationTarget ? $0 : nil }
        let title = RemoteText.displayName(payload.title, limit: 200)
        let body = RemoteText.clean(payload.body)
        let threadId = RemoteText.displayName(payload.threadId, limit: 200)
        return PushContent(title: title.isEmpty ? PushContent.generic.title : title,
                           body: body,
                           threadIdentifier: threadId.isEmpty ? nil : threadId,
                           badge: payload.badge.map { max(0, $0) },
                           deepLink: link == nil ? nil : payload.deepLink,
                           pr: payload.pr,
                           categoryIdentifier: PushCategory.identifier(for: link))
    }
}

/// The ids of the last pushes shown, in a JSON file in the App Group container (`Push/seen.json`), readable after the
/// first unlock like the keychain items (the extension runs on a locked phone).
public final class SeenPushFile: SeenPushStore, @unchecked Sendable {
    public static let limit = 200

    private let url: URL
    private let limit: Int
    private let lock = NSLock()

    public init(url: URL, limit: Int = SeenPushFile.limit) {
        self.url = url
        self.limit = limit
    }

    /// `<container>/Push/seen.json`.
    public convenience init(container: URL) {
        self.init(url: container.appendingPathComponent("Push", isDirectory: true).appendingPathComponent("seen.json"))
    }

    public func insert(_ id: UUID) -> Bool {
        lock.withLock {
            var ids = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([UUID].self, from: $0) } ?? []
            guard !ids.contains(id) else { return false }
            ids.append(id)
            if ids.count > limit { ids.removeFirst(ids.count - limit) }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(ids).write(to: url, options: Cache.writingOptions)
            } catch {
                // Can't remember it: show it anyway (a replay would then show the same text twice, nothing new).
            }
            return true
        }
    }
}

/// In memory, for tests.
public final class InMemorySeenPushes: SeenPushStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID> = []

    public init() {}

    public func insert(_ id: UUID) -> Bool { lock.withLock { ids.insert(id).inserted } }
}
