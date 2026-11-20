import Foundation

/// Una sesión de merge de un PR desde PRBar (spec G.4): el merge (o el intento) y la conversación de su ventana. Se
/// guarda cuando hay algo que guardar: un mensaje del chat o un intento de merge.
public struct MergeRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Todavía no se mergeó (la ventana tiene un chat, o se cerró sin mergear).
        case open
        case merged
        /// El último intento falló.
        case failed
    }

    public let id: UUID
    public var prID: String
    public var account: String
    public var repo: RepoRef
    public var number: Int
    public var title: String
    public var url: URL
    public var method: MergeMethod?
    /// El head mergeado (o intentado): el que mostró la ventana o la CLI.
    public var headOid: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var errorMessage: String?
    public var chat: ChatSession?

    public init(id: UUID = UUID(), prID: String, account: String, repo: RepoRef, number: Int, title: String, url: URL,
                method: MergeMethod? = nil, headOid: String? = nil, startedAt: Date, finishedAt: Date? = nil,
                status: Status = .open, errorMessage: String? = nil, chat: ChatSession? = nil) {
        self.id = id
        self.prID = prID
        self.account = account
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.method = method
        self.headOid = headOid
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.errorMessage = errorMessage
        self.chat = chat
    }

    /// El registro de una sesión nueva del PR `item`.
    public init(item: ClassifiedPR, startedAt: Date) {
        self.init(prID: item.id, account: item.account, repo: item.pr.repo, number: item.pr.number, title: item.pr.title,
                  url: item.pr.url, startedAt: startedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, prID, account, repo, number, title, url, method, headOid, startedAt, finishedAt, status, errorMessage, chat
    }

    /// Tolerante: un estado o un método desconocidos, o un chat ilegible, no pierden el registro.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        prID = try c.decode(String.self, forKey: .prID)
        account = try c.decode(String.self, forKey: .account)
        repo = try c.decode(RepoRef.self, forKey: .repo)
        number = try c.decode(Int.self, forKey: .number)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        url = try c.decode(URL.self, forKey: .url)
        method = (try? c.decodeIfPresent(MergeMethod.self, forKey: .method)) ?? nil
        headOid = (try? c.decodeIfPresent(String.self, forKey: .headOid)) ?? nil
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = (try? c.decodeIfPresent(Date.self, forKey: .finishedAt)) ?? nil
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .open
        errorMessage = (try? c.decodeIfPresent(String.self, forKey: .errorMessage)) ?? nil
        chat = (try? c.decodeIfPresent(ChatSession.self, forKey: .chat)) ?? nil
    }
}

/// Un JSON por sesión de merge en `<historyDir>/merge/<uuid>.json` y el log del chat en
/// `<historyDir>/merge/logs/<uuid>.log`.
public struct MergeHistory: Sendable {
    public let directory: URL

    /// `historyDir`: la carpeta del historial de reviews (`AppPaths.historyDir`); los registros van en `merge/`.
    public init(historyDir: URL = AppPaths.historyDir) {
        directory = historyDir.appendingPathComponent("merge", isDirectory: true)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Guarda el registro de forma atómica; un mismo id se sobrescribe.
    public func save(_ record: MergeRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(record).write(to: fileURL(for: record.id), options: .atomic)
    }

    /// Todos los registros, del más nuevo al más viejo. Los archivos ilegibles se ignoran y se loguean.
    public func all() -> [MergeRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var records: [MergeRecord] = []
        for file in files where file.pathExtension == "json" {
            do {
                records.append(try JSONCoding.decoder.decode(MergeRecord.self, from: Data(contentsOf: file)))
            } catch {
                AppLog.write("History: couldn't read merge/\(file.lastPathComponent): \(error)")
            }
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    /// El registro `id`, o nil si no existe o no se puede leer (se loguea).
    public func record(id: UUID) -> MergeRecord? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONCoding.decoder.decode(MergeRecord.self, from: Data(contentsOf: url))
        } catch {
            AppLog.write("History: couldn't read merge/\(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// El intento fallido más nuevo de `prID`: un merge que se confirma después (p. ej. Retry encontró que GitHub lo
    /// mergeó) completa ese registro en vez de crear otro.
    public func lastFailed(prID: String) -> MergeRecord? {
        all().first { $0.prID == prID && $0.status == .failed }
    }

    public func logURL(for id: UUID) -> URL {
        directory.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("\(id.uuidString).log")
    }
}
