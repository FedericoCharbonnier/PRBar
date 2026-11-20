import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteKit

/// Las tres claves de largo plazo de la Mac (spec P.2), solo en el llavero (servicio "PRBar Remote"): nunca en
/// `config.json`, `devices.json` ni los logs (revisión L5).
public struct RemoteKeyStore: Sendable {
    public static let service = "PRBar Remote"
    static let accounts = (relay: "mac-relay", noise: "mac-noise", seal: "mac-seal")

    public struct Failure: Error, LocalizedError {
        public var errorDescription: String? {
            "The iPhone access keys in Keychain are damaged. Use Reset iPhone Access… to create new ones."
        }
    }

    private let secrets: any SecretStore

    public init(secrets: any SecretStore = KeychainStore(service: RemoteKeyStore.service)) {
        self.secrets = secrets
    }

    /// Las claves guardadas; si no hay ninguna, crea y guarda unas nuevas. Una clave rota falla (no se reemplaza en
    /// silencio: cambiaría la identidad de la Mac sin que nadie lo pida).
    public func loadOrCreate() throws -> MacKeys {
        let stored = (try secrets.read(Self.accounts.relay), try secrets.read(Self.accounts.noise),
                      try secrets.read(Self.accounts.seal))
        if let relay = stored.0, let noise = stored.1, let seal = stored.2, !relay.isEmpty {
            guard let relay = Data(base64Encoded: relay), let noise = Data(base64Encoded: noise),
                  let seal = Data(base64Encoded: seal),
                  let keys = try? MacKeys(relay: .init(rawRepresentation: relay), noise: .init(rawRepresentation: noise),
                                          seal: .init(rawRepresentation: seal)) else { throw Failure() }
            return keys
        }
        let keys = MacKeys()
        try secrets.write(keys.relay.rawRepresentation.base64EncodedString(), for: Self.accounts.relay)
        try secrets.write(keys.noise.rawRepresentation.base64EncodedString(), for: Self.accounts.noise)
        try secrets.write(keys.seal.rawRepresentation.base64EncodedString(), for: Self.accounts.seal)
        return keys
    }

    /// "Reset iPhone Access…": borra las claves (la próxima `loadOrCreate` crea otras).
    public func reset() throws {
        try secrets.write(nil, for: Self.accounts.relay)
        try secrets.write(nil, for: Self.accounts.noise)
        try secrets.write(nil, for: Self.accounts.seal)
    }
}

/// Un iPhone emparejado y lo que la Mac recuerda de él.
public struct StoredDevice: Codable, Equatable, Sendable {
    public var device: PairedDevice
    public var lastSeen: Date?
    /// APNs dijo que el token ya no sirve (410): "Notifications off" en Settings.
    public var notificationsOff: Bool

    public init(device: PairedDevice, lastSeen: Date? = nil, notificationsOff: Bool = false) {
        self.device = device
        self.lastSeen = lastSeen
        self.notificationsOff = notificationsOff
    }

    enum CodingKeys: String, CodingKey { case device, lastSeen, notificationsOff }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decode(PairedDevice.self, forKey: .device)
        lastSeen = try? c.decodeIfPresent(Date.self, forKey: .lastSeen)
        notificationsOff = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsOff)) ?? false
    }
}

/// `remote/devices.json` (spec P.2): 0600 en una carpeta 0700, solo claves públicas. Un archivo roto se aparta
/// (`devices.json.broken-<fecha>`) y se arranca sin dispositivos.
/// Lo usa solo `RemoteAccessService` (en el hilo principal).
public final class RemoteDeviceStore {
    public let directory: URL
    public private(set) var devices: [StoredDevice] = []

    private var file: URL { directory.appendingPathComponent("devices.json") }

    public init(directory: URL = AppPaths.remoteDir) {
        self.directory = directory
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            devices = try decoder.decode([StoredDevice].self, from: data)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let broken = directory.appendingPathComponent("devices.json.broken-\(stamp)")
            try? FileManager.default.moveItem(at: file, to: broken)
            AppLog.write("iPhone access: devices.json was unreadable; moved it aside and started with no paired iPhones.")
            devices = []
        }
    }

    private func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(devices)
        // Se crea ya con 0600 (nunca queda legible por otros, ni un instante).
        let temp = directory.appendingPathComponent(".devices-\(UUID().uuidString).json")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try fm.replaceItemAt(file, withItemAt: temp)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func device(_ id: String) -> StoredDevice? { devices.first { $0.device.deviceId == id } }

    public func add(_ device: PairedDevice) throws {
        devices.removeAll { $0.device.deviceId == device.deviceId }
        devices.append(StoredDevice(device: device))
        try save()
    }

    public func remove(_ id: String) throws {
        devices.removeAll { $0.device.deviceId == id }
        try save()
    }

    public func removeAll() throws {
        devices = []
        try save()
    }

    public func update(lastSeen: Date, for id: String) throws {
        guard let index = devices.firstIndex(where: { $0.device.deviceId == id }) else { return }
        devices[index].lastSeen = lastSeen
        try save()
    }

    public func setRequirePresence(_ required: Bool, for id: String) throws {
        guard let index = devices.firstIndex(where: { $0.device.deviceId == id }) else { return }
        devices[index].device.requirePresence = required
        try save()
    }

    public func setNotificationsOff(_ off: Bool, for id: String) throws {
        guard let index = devices.firstIndex(where: { $0.device.deviceId == id }), devices[index].notificationsOff != off else { return }
        devices[index].notificationsOff = off
        try save()
    }
}
