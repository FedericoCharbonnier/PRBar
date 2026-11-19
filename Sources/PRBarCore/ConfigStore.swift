import Foundation

@MainActor
public final class ConfigStore: ObservableObject {
    @Published public private(set) var config: AppConfig
    @Published public private(set) var loadError: String?
    private let fileURL: URL

    public init(fileURL: URL = AppPaths.configFile) {
        self.fileURL = fileURL
        let (config, error, migrated) = Self.loadOrRecover(fileURL)
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
    private static func loadOrRecover(_ url: URL) -> (AppConfig, String?, Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (AppConfig(), nil, false) }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: data)
            return (config, nil, AccountConfig.hasLegacyWatchedUsers(data))
        } catch {
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return (AppConfig(), "Couldn't read config.json (\(error.localizedDescription)). A copy was saved to config.json.bak and the defaults are being used.", false)
        }
    }
}
