import Foundation

public enum Severity: String, Codable, Sendable, CaseIterable {
    case high, medium, low

    public var label: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }
}

public struct ReviewFinding: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let severity: Severity
    public let file: String
    public let line: Int?
    public let title: String
    public let body: String

    public init(id: String, severity: Severity, file: String, line: Int?, title: String, body: String) {
        self.id = id
        self.severity = severity
        self.file = file
        self.line = line
        self.title = title
        self.body = body
    }

    public var location: String { line.map { "\(file):\($0)" } ?? file }
}

public struct ReviewStageOneOutput: Codable, Equatable, Sendable {
    public let summary: String
    public let findings: [ReviewFinding]
}

public struct ReviewVerdict: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case keep, discard }
    public let id: String
    public let verdict: Kind
    public let reason: String

    public init(id: String, verdict: Kind, reason: String) {
        self.id = id
        self.verdict = verdict
        self.reason = reason
    }
}

public struct ReviewStageTwoOutput: Codable, Equatable, Sendable {
    public let verdicts: [ReviewVerdict]
}

public struct ReviewItem: Codable, Equatable, Sendable, Identifiable {
    public let finding: ReviewFinding
    /// Veredicto del filtro (etapa 2). Un hallazgo sin veredicto se mantiene.
    public let keep: Bool
    public let reason: String?

    public init(finding: ReviewFinding, keep: Bool, reason: String?) {
        self.finding = finding
        self.keep = keep
        self.reason = reason
    }

    public var id: String { finding.id }

    public static func combine(findings: [ReviewFinding], verdicts: [ReviewVerdict]) -> [ReviewItem] {
        let byID = Dictionary(verdicts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return findings.map { finding in
            let verdict = byID[finding.id]
            return ReviewItem(finding: finding, keep: verdict?.verdict != .discard, reason: verdict?.reason)
        }
    }
}

public struct ReviewDraft: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public let prID: String
    public let repo: RepoRef
    public let number: Int
    public let title: String
    public let url: URL
    public let author: String
    /// Commit sobre el que se hizo la review (se usa como `commit_id` al publicar).
    public let headOid: String
    public let account: String
    public let summary: String
    public let items: [ReviewItem]
    /// The PR's language (from its description): the comments are published in it. English in old history files.
    public let language: PRLanguage

    public init(prID: String, repo: RepoRef, number: Int, title: String, url: URL, author: String,
                headOid: String, account: String, summary: String, items: [ReviewItem], language: PRLanguage = .english) {
        self.prID = prID
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.headOid = headOid
        self.account = account
        self.summary = summary
        self.items = items
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case id, prID, repo, number, title, url, author, headOid, account, summary, items, language
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            prID: try c.decode(String.self, forKey: .prID), repo: try c.decode(RepoRef.self, forKey: .repo),
            number: try c.decode(Int.self, forKey: .number), title: try c.decode(String.self, forKey: .title),
            url: try c.decode(URL.self, forKey: .url), author: try c.decode(String.self, forKey: .author),
            headOid: try c.decode(String.self, forKey: .headOid), account: try c.decode(String.self, forKey: .account),
            summary: try c.decode(String.self, forKey: .summary), items: try c.decode([ReviewItem].self, forKey: .items),
            language: (try? c.decodeIfPresent(PRLanguage.self, forKey: .language)) ?? .english)
        id = try c.decode(UUID.self, forKey: .id)
    }

    public var keptCount: Int { items.filter(\.keep).count }
}

public enum ReviewSchemas {
    public static let stageOne = """
    {"type":"object","additionalProperties":false,"required":["summary","findings"],
     "properties":{
      "summary":{"type":"string"},
      "findings":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["id","severity","file","line","title","body"],
        "properties":{
          "id":{"type":"string"},
          "severity":{"type":"string","enum":["high","medium","low"]},
          "file":{"type":"string"},
          "line":{"type":["integer","null"]},
          "title":{"type":"string"},
          "body":{"type":"string"}}}}}}
    """

    public static let stageTwo = """
    {"type":"object","additionalProperties":false,"required":["verdicts"],
     "properties":{"verdicts":{"type":"array","items":{"type":"object","additionalProperties":false,
       "required":["id","verdict","reason"],
       "properties":{"id":{"type":"string"},"verdict":{"type":"string","enum":["keep","discard"]},"reason":{"type":"string"}}}}}}
    """
}
