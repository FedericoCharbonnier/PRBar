import Foundation

public struct ReviewRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case ready, failed, published, abandoned }
    public enum Action: String, Codable, Sendable { case approve, requestChanges, comment, none }

    public var id: UUID { draft.id }
    public var draft: ReviewDraft
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var errorMessage: String?
    /// Textos finales publicados, por id de hallazgo.
    public var published: [String: String]
    public var generalComment: String?
    public var action: Action
    public var reviewURL: URL?
    public var kind: String = "review"   // "respond" en el Plan 3
    /// La pidió un iPhone (spec M.4); nil = desde la Mac o un registro viejo.
    public var requestedOnPhone: Bool?

    public init(
        draft: ReviewDraft, startedAt: Date, finishedAt: Date? = nil, status: Status, errorMessage: String? = nil,
        published: [String: String] = [:], generalComment: String? = nil, action: Action = .none,
        reviewURL: URL? = nil, kind: String = "review", requestedOnPhone: Bool? = nil
    ) {
        self.draft = draft
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.errorMessage = errorMessage
        self.published = published
        self.generalComment = generalComment
        self.action = action
        self.reviewURL = reviewURL
        self.kind = kind
        self.requestedOnPhone = requestedOnPhone
    }
}

/// Un JSON por review en `<dir>/<uuid>.json` y el log del stream de Claude en `<dir>/logs/<uuid>.jsonl`.
public struct ReviewHistory: Sendable {
    private let directory: URL

    public init(directory: URL = AppPaths.historyDir) {
        self.directory = directory
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Guarda el registro de forma atómica; un mismo id se sobrescribe.
    public func save(_ record: ReviewRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(record).write(to: fileURL(for: record.id), options: .atomic)
    }

    /// Todos los registros, del más nuevo al más viejo. Los archivos ilegibles se ignoran y se loguean.
    public func all() -> [ReviewRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var records: [ReviewRecord] = []
        for file in files where file.pathExtension == "json" {
            do {
                records.append(try JSONCoding.decoder.decode(ReviewRecord.self, from: Data(contentsOf: file)))
            } catch {
                AppLog.write("History: couldn't read \(file.lastPathComponent): \(error)")
            }
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    /// El registro `id`, o nil si no existe o no se puede leer (se loguea).
    public func record(id: UUID) -> ReviewRecord? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONCoding.decoder.decode(ReviewRecord.self, from: Data(contentsOf: url))
        } catch {
            AppLog.write("History: couldn't read \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Un review `ready` que se reemplaza por uno nuevo del mismo PR pasa a `abandoned` (ya no se puede reabrir
    /// para publicar). Cualquier otro estado no se toca.
    public func markAbandoned(id: UUID, at date: Date = Date()) throws {
        guard var record = record(id: id), record.status == .ready else { return }
        record.status = .abandoned
        record.finishedAt = record.finishedAt ?? date
        try save(record)
    }

    /// "Abrir para publicar" (§10): el registro está `ready`, no hay un review en curso del PR, el PR sigue en
    /// el mismo commit que cuando se revisó (`currentHeadOid`) y no hay una review publicada del mismo PR y
    /// el mismo commit después de que empezó este registro (publicarlo la duplicaría).
    public static func canReopen(_ record: ReviewRecord, among records: [ReviewRecord], currentHeadOid: String?, reviewActive: Bool) -> Bool {
        guard record.status == .ready, !reviewActive, let currentHeadOid, currentHeadOid == record.draft.headOid else { return false }
        return !records.contains { other in
            other.id != record.id && other.status == .published
                && other.draft.prID == record.draft.prID && other.draft.headOid == record.draft.headOid
                && (other.finishedAt ?? other.startedAt) > record.startedAt
        }
    }

    public func logURL(for id: UUID) -> URL {
        directory.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("\(id.uuidString).jsonl")
    }
}
