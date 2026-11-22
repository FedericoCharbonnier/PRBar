import Foundation

@MainActor
public final class ConfigStore: ObservableObject {
    @Published public private(set) var config: AppConfig
    @Published public private(set) var loadError: String?
    private let fileURL: URL

    private let now: () -> Date

    /// Se guarda solo lo que el usuario cambia. Los guardados automáticos (una migración, el provider de Slack por
    /// defecto) se saltean si el archivo no se pudo leer: pisarían el archivo del usuario con los defaults sin que lo
    /// pida (y el próximo arranque ya no mostraría el error).
    public var savesAutomatically: Bool { loadError == nil }

    public init(fileURL: URL = AppPaths.configFile, now: @escaping () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        let (config, error, migrated) = Self.loadOrRecover(fileURL, now: now())
        self.config = config
        self.loadError = error
        if let error { AppLog.write(error) }
        if migrated {
            do {
                try JSONCoding.encoder.encode(config).write(to: fileURL, options: .atomic)
                AppLog.write("config.json: watched users moved from the account to each repo")
            } catch {
                AppLog.write("config.json: couldn't save the watched-users migration: \(error)")
            }
        }
    }

    public func update(_ mutate: (inout AppConfig) -> Void) throws {
        var next = config
        mutate(&next)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(next).write(to: fileURL, options: .atomic)
        config = next
    }

    /// Devuelve también si el archivo estaba en el formato viejo y hay que reescribirlo migrado.
    private static func loadOrRecover(_ url: URL, now: Date) -> (AppConfig, String?, Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (AppConfig(), nil, false) }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: data)
            return (config, nil, AccountConfig.hasLegacyWatchedUsers(data))
        } catch {
            let reason = error.localizedDescription
            guard let copy = keepBrokenCopy(of: url, now: now) else {
                return (AppConfig(), "Couldn't read config.json (\(reason)) and couldn't copy it aside. The defaults are being used; config.json changes only when you change a setting.", false)
            }
            return (AppConfig(), "Couldn't read config.json (\(reason)). A copy was saved to \(copy) and the defaults are being used; config.json changes only when you change a setting.", false)
        }
    }

    /// Copia el archivo que no se pudo leer a `config.json.broken-<fecha>` (con `-2`, `-3`… si ese nombre existe):
    /// nunca pisa una copia anterior. Si la última copia ya tiene el mismo contenido, no hace otra. Devuelve el nombre.
    static func keepBrokenCopy(of url: URL, now: Date) -> String? {
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".broken-"
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: url) else { return nil }
        let existing = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(prefix) }
        if let same = existing.first(where: { (try? Data(contentsOf: directory.appendingPathComponent($0))) == data }) {
            return same
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = prefix + formatter.string(from: now)
        for attempt in 1...100 {
            let name = attempt == 1 ? stamp : "\(stamp)-\(attempt)"
            // `copyItem` falla si el destino existe: nunca pisa.
            do {
                try fm.copyItem(at: url, to: directory.appendingPathComponent(name))
                return name
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }
}
