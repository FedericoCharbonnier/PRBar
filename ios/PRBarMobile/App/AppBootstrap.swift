import CryptoKit
import Foundation
import PRBarMobileCore
import PRBarMobileUI
import PRBarRemoteKit
import UIKit
import UserNotifications

/// Builds the app's object graph with the real keychain, cache and Face ID.
///
/// The link to the Mac is the `RemoteTransport` seam (spec R.3, R.7): `LiveTransport` (RemoteKit's `RemoteClient`
/// through the relay) and `LivePairingService`. Launched with `-demo` (screenshots, App Review), the app runs on
/// `FakeTransport` with the design's sample data instead and never touches the network or the keychain.
@MainActor
enum AppBootstrap {
    static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    static func make() -> PhoneApp {
        isDemo ? PhoneApp.demo() : live()
    }

    static func live() -> PhoneApp {
        let keychain = DeviceKeychain(backend: SystemKeychain(), accessGroup: keychainAccessGroup)
        let paired = try? keychain.loadMac()
        let cache = Cache(directory: cacheDirectory)
        let store = AppStore(cache: cache)
        let configuration = RemoteClient.Configuration(appVersion: shortVersion, deviceName: UIDevice.current.name,
                                                       model: deviceModel)
        let transport = LiveTransport(session: { keychain.loadSession() },
                                      makeClient: LiveTransport.clientFactory(configuration: configuration))
        let connection = RemoteConnection(transport: transport, store: store, credentials: keychain,
                                          paired: paired != nil, macName: paired?.macName)
        let app = PhoneApp(connection: connection, authorizer: authorizer(keychain: keychain), keychain: keychain,
                           pairingService: LivePairingService(configuration: configuration),
                           makePresenceKey: makePresenceKey, notifications: SystemNotificationPermission(),
                           appVersion: appVersion)
        connection.start()
        return app
    }

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// "iPhone17,1" (what the Mac lists next to the name).
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// `$(AppIdentifierPrefix)com.federico.prbar.ios.shared`, expanded at build time into Info.plist.
    static var keychainAccessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PRBarKeychainAccessGroup") as? String,
              !group.isEmpty, !group.hasPrefix("$(") else { return nil }
        return group
    }

    /// The App Group container (shared with the notification extension), or Application Support without it.
    static var cacheDirectory: URL {
        let group = Bundle.main.object(forInfoDictionaryKey: "PRBarAppGroup") as? String ?? ""
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Cache", isDirectory: true)
    }

    /// The Secure Enclave key; a software key only in DEBUG simulator builds (no Secure Enclave there).
    static func authorizer(keychain: DeviceKeychain) -> any PresenceAuthorizer {
        #if DEBUG && targetEnvironment(simulator)
        if let data = try? keychain.loadKeys()?.presenceKey, let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return SoftwarePresenceAuthorizer(key: key)
        }
        return SoftwarePresenceAuthorizer()
        #else
        return KeychainPresenceAuthorizer(keychain: keychain)
        #endif
    }

    static let makePresenceKey: @Sendable () throws -> (keyData: Data, publicKey: Data) = {
        #if DEBUG && targetEnvironment(simulator)
        let key = P256.Signing.PrivateKey()
        return (key.rawRepresentation, key.publicKey.x963Representation)
        #else
        let data = try SecureEnclavePresence.createKey()
        return (data, try SecureEnclavePresence.publicKey(of: data))
        #endif
    }
}

/// Reads the Secure Enclave key from the keychain each time, so a key created by pairing is used right away.
struct KeychainPresenceAuthorizer: PresenceAuthorizer {
    let keychain: DeviceKeychain

    func signer(reason: String) -> any PresenceSigner {
        guard let data = try? keychain.loadKeys()?.presenceKey else { return MissingKeySigner() }
        return SecureEnclavePresence(keyData: data, reason: reason)
    }

    private struct MissingKeySigner: PresenceSigner {
        func sign(_ message: Data) async throws -> Data { throw PresenceFailure.keyInvalid }
    }
}

struct SystemNotificationPermission: NotificationPermission {
    func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }
}
