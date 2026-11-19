import Foundation
import Security

public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> String?
    /// Si hay un valor guardado, sin leerlo (en el Llavero no pide permiso).
    func exists(_ key: String) throws -> Bool
    /// `nil` o vacío borra el secreto.
    func write(_ value: String?, for key: String) throws
}

/// Secretos en el Llavero de macOS (generic password). Nunca se loguean.
public struct KeychainStore: SecretStore {
    private let service: String

    public init(service: String = "com.federico.prbar.slack") {
        self.service = service
    }

    public func read(_ key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw PRBarError.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func exists(_ key: String) throws -> Bool {
        var query = baseQuery(key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw PRBarError.keychain(status) }
        return true
    }

    /// Actualiza el ítem existente (conserva su lista de acceso) y lo crea si no existe. Solo borra con `nil` o vacío.
    public func write(_ value: String?, for key: String) throws {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(baseQuery(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PRBarError.keychain(status) }
            return
        }
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(baseQuery(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw PRBarError.keychain(updateStatus) }
        var attributes = baseQuery(key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw PRBarError.keychain(status) }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
