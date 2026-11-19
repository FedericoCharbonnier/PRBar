import Foundation

/// Un JSON por corrida de "Responder" en `<historyDir>/respond/<uuid>.json` y su log (Claude, tests) en
/// `<historyDir>/respond/logs/<uuid>.log`. El id es el del draft.
public struct RespondHistory: Sendable {
    public let directory: URL

    /// `historyDir`: la carpeta del historial de reviews (`AppPaths.historyDir`); los registros van en `respond/`.
    public init(historyDir: URL = AppPaths.historyDir) {
        self.directory = historyDir.appendingPathComponent("respond", isDirectory: true)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Guarda el registro de forma atómica; un mismo id se sobrescribe.
    public func save(_ record: RespondRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(record).write(to: fileURL(for: record.id), options: .atomic)
    }

    /// Todos los registros, del más nuevo al más viejo. Los archivos ilegibles se ignoran y se loguean.
    public func all() -> [RespondRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var records: [RespondRecord] = []
        for file in files where file.pathExtension == "json" {
            do {
                records.append(try JSONCoding.decoder.decode(RespondRecord.self, from: Data(contentsOf: file)))
            } catch {
                AppLog.write("History: couldn't read respond/\(file.lastPathComponent): \(error)")
            }
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    /// El registro `id`, o nil si no existe o no se puede leer (se loguea).
    public func record(id: UUID) -> RespondRecord? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONCoding.decoder.decode(RespondRecord.self, from: Data(contentsOf: url))
        } catch {
            AppLog.write("History: couldn't read respond/\(url.lastPathComponent): \(error)")
            return nil
        }
    }

    public func logURL(for id: UUID) -> URL {
        directory.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("\(id.uuidString).log")
    }
}
