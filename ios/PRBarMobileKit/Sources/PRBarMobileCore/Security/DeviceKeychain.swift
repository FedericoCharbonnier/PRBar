import CryptoKit
import Foundation
import Security

/// Where keychain items go. The system one uses `SecItem*`; tests use `InMemoryKeychain`.
public protocol KeychainBackend: Sendable {
    /// Adds or replaces the item for `account` with exactly these attributes (besides class, service and account).
    func set(_ data: Data, account: String, attributes: [String: KeychainValue]) throws
    func get(account: String) throws -> Data?
    func delete(account: String) throws
}

/// The attribute values PRBar uses, so attributes can be compared in tests and are `Sendable`.
public enum KeychainValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
}

public enum KeychainError: Error, Equatable, Sendable {
    case status(OSStatus)
}

/// This iPhone's long-term keys (spec P.2). Private keys never leave the device: the presence key is a Secure Enclave
/// handle (`dataRepresentation`), the rest are raw CryptoKit representations.
public struct StoredDeviceKeys: Codable, Equatable, Sendable {
    /// Ed25519 (`deviceRelayKey`): authenticates to the relay.
    public var relayKey: Data
    /// X25519 (`deviceStatic`): Noise.
    public var staticKey: Data
    /// X25519 (`devicePushKey`): opens pushes and the mailbox (the notification extension reads it too).
    public var pushKey: Data
    /// The Secure Enclave P-256 key's `dataRepresentation` (or a software key's raw bytes in simulator builds).
    public var presenceKey: Data

    public init(relayKey: Data, staticKey: Data, pushKey: Data, presenceKey: Data) {
        self.relayKey = relayKey
        self.staticKey = staticKey
        self.pushKey = pushKey
        self.presenceKey = presenceKey
    }

    public static func generate(presenceKey: Data) -> StoredDeviceKeys {
        StoredDeviceKeys(relayKey: Curve25519.Signing.PrivateKey().rawRepresentation,
                         staticKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                         pushKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                         presenceKey: presenceKey)
    }
}

/// The Mac this iPhone is paired with (what the pairing session hands over, spec P.11 step 6).
public struct StoredPairedMac: Codable, Equatable, Sendable {
    public var accountId: String
    public var deviceId: String
    public var relayHost: String
    public var macName: String
    public var macStatic: Data
    public var macSealKey: Data
    public var pairedAt: Date

    public init(accountId: String, deviceId: String, relayHost: String, macName: String, macStatic: Data,
                macSealKey: Data, pairedAt: Date) {
        self.accountId = accountId
        self.deviceId = deviceId
        self.relayHost = relayHost
        self.macName = macName
        self.macStatic = macStatic
        self.macSealKey = macSealKey
        self.pairedAt = pairedAt
    }
}

/// The keychain items shared by the app and its notification extension (spec P.2): after first unlock, this device
/// only, never synced, in the shared access group.
public struct DeviceKeychain: CredentialWiping {
    public static let service = "PRBar Remote"
    public static let defaultAccessGroup = "com.federico.prbar.ios.shared"
    static let keysAccount = "device-keys"
    static let macAccount = "paired-mac"

    public let backend: any KeychainBackend
    /// With the team prefix (`$(AppIdentifierPrefix)…`), as the entitlement has it. Nil: the app's default group.
    public let accessGroup: String?

    public init(backend: any KeychainBackend, accessGroup: String?) {
        self.backend = backend
        self.accessGroup = accessGroup
    }

    public var itemAttributes: [String: KeychainValue] {
        var attributes: [String: KeychainValue] = [
            kSecAttrAccessible as String: .string(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
            kSecAttrSynchronizable as String: .bool(false),
        ]
        if let accessGroup { attributes[kSecAttrAccessGroup as String] = .string(accessGroup) }
        return attributes
    }

    public func save(keys: StoredDeviceKeys) throws {
        try backend.set(try JSONEncoder().encode(keys), account: Self.keysAccount, attributes: itemAttributes)
    }

    public func loadKeys() throws -> StoredDeviceKeys? {
        try backend.get(account: Self.keysAccount).map { try JSONDecoder().decode(StoredDeviceKeys.self, from: $0) }
    }

    public func save(mac: StoredPairedMac) throws {
        try backend.set(try JSONEncoder().encode(mac), account: Self.macAccount, attributes: itemAttributes)
    }

    public func loadMac() throws -> StoredPairedMac? {
        try backend.get(account: Self.macAccount).map { try JSONDecoder().decode(StoredPairedMac.self, from: $0) }
    }

    public func wipe() throws {
        try backend.delete(account: Self.keysAccount)
        try backend.delete(account: Self.macAccount)
    }
}

/// For tests and previews: remembers the attributes each item was stored with.
public final class InMemoryKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (Data, [String: KeychainValue])] = [:]

    public init() {}

    public func set(_ data: Data, account: String, attributes: [String: KeychainValue]) throws {
        lock.withLock { items[account] = (data, attributes) }
    }

    public func get(account: String) throws -> Data? { lock.withLock { items[account]?.0 } }

    public func delete(account: String) throws { _ = lock.withLock { items.removeValue(forKey: account) } }

    public func attributes(account: String) -> [String: KeychainValue]? { lock.withLock { items[account]?.1 } }

    public var isEmpty: Bool { lock.withLock { items.isEmpty } }
}

/// `SecItem*` on the real keychain (generic passwords under `DeviceKeychain.service`).
public struct SystemKeychain: KeychainBackend {
    public init() {}

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: DeviceKeychain.service,
         kSecAttrAccount as String: account]
    }

    private func plain(_ attributes: [String: KeychainValue]) -> [String: Any] {
        attributes.mapValues { value -> Any in
            switch value {
            case .string(let text): text
            case .bool(let flag): flag
            }
        }
    }

    public func set(_ data: Data, account: String, attributes: [String: KeychainValue]) throws {
        try delete(account: account)
        var query = base(account).merging(plain(attributes)) { $1 }
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func get(account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
