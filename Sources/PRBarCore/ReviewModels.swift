import Foundation

/// What a finding is about (spec E.4). Lenient: a missing or unknown category is `other`.
public enum FindingCategory: String, Codable, Sendable, CaseIterable {
    case bug, security, performance, tests, style, docs, other

    public var label: String {
        switch self {
        case .bug: "Bugs"
        case .security: "Security"
        case .performance: "Performance"
        case .tests: "Tests"
        case .style: "Style"
        case .docs: "Docs"
        case .other: "Other"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FindingCategory(rawValue: raw) ?? .other
    }
}

public struct ReviewFinding: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let severity: Severity
    public let file: String
    public let line: Int?
    public let title: String
    public let body: String
    /// Spec E.4. Old history files and answers without it: `other`.
    public let category: FindingCategory

    public init(id: String, severity: Severity, file: String, line: Int?, title: String, body: String,
                category: FindingCategory = .other) {
        self.id = id
        self.severity = severity
        self.file = file
        self.line = line
        self.title = title
        self.body = body
        self.category = category
    }

    private enum CodingKeys: String, CodingKey { case id, severity, file, line, title, body, category }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        severity = try c.decode(Severity.self, forKey: .severity)
        file = try c.decode(String.self, forKey: .file)
        line = try c.decodeIfPresent(Int.self, forKey: .line)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        category = (try? c.decodeIfPresent(FindingCategory.self, forKey: .category)) ?? .other
    }

    public var location: String { line.map { "\(file):\($0)" } ?? file }
}

public struct ReviewStageOneOutput: Codable, Equatable, Sendable {
    public let summary: String
    public let findings: [ReviewFinding]
    /// Spec RM.4: only with memory.
    public var previous: [PreviousVerdict]? = nil
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
    /// Spec E.5: why the user's settings (minimum severity, categories, ignored paths, maximum) hide it; nil = shown.
    public let hiddenBy: String?

    public init(finding: ReviewFinding, keep: Bool, reason: String?, hiddenBy: String? = nil) {
        self.finding = finding
        self.keep = keep
        self.reason = reason
        self.hiddenBy = hiddenBy
    }

    public var id: String { finding.id }
    public var isHidden: Bool { hiddenBy != nil }

    /// The same item, hidden by the user's settings.
    public func hiding(_ why: String) -> ReviewItem {
        ReviewItem(finding: finding, keep: keep, reason: reason, hiddenBy: why)
    }

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
    /// The chat about this review (spec B.3). Nil until the first message.
    public var chat: ChatSession?
    /// The window's state as the chat last left it (selection, edited texts, added findings, general comment).
    public var edits: ReviewEdits?
    /// Claude's usage for the review (stage 1 and the filter, spec O). Nil in older history files.
    public var usage: ClaudeUsage?
    /// The Claude sessions of this run's stages (spec T.2), until `AppModel` saves them in the record. Not encoded.
    public var sessions: [ClaudeSessionRef] = []
    /// The review's folder kept for "Open in Terminal" (spec T.3, Task 5); nil = it was removed. Not encoded.
    public var retainedLocation: WorktreeLocation? = nil
    /// Spec RM.4: what Claude said about each comment PRBar posted before; empty in a first review and in old files.
    public var previous: [PreviousCommentStatus] = []
    /// The commit of the last posted review this one started from (spec RM.4); nil in a first review.
    public var reviewedSince: String? = nil

    public init(prID: String, repo: RepoRef, number: Int, title: String, url: URL, author: String,
                headOid: String, account: String, summary: String, items: [ReviewItem], language: PRLanguage = .english,
                chat: ChatSession? = nil, edits: ReviewEdits? = nil, usage: ClaudeUsage? = nil) {
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
        self.chat = chat
        self.edits = edits
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case id, prID, repo, number, title, url, author, headOid, account, summary, items, language, chat, edits, usage
        case previous, reviewedSince
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
        chat = (try? c.decodeIfPresent(ChatSession.self, forKey: .chat)) ?? nil
        edits = (try? c.decodeIfPresent(ReviewEdits.self, forKey: .edits)) ?? nil
        usage = (try? c.decodeIfPresent(ClaudeUsage.self, forKey: .usage)) ?? nil
        previous = (try? c.decodeIfPresent([PreviousCommentStatus].self, forKey: .previous)) ?? []
        reviewedSince = (try? c.decodeIfPresent(String.self, forKey: .reviewedSince)) ?? nil
    }

    /// The review and its chat (spec O.4.4); nil if neither has data (older history files).
    public var totalUsage: ClaudeUsage? { ClaudeUsage.sum([usage, chat?.usage]) }

    /// Findings to choose from: the filter kept them and the user's settings don't hide them.
    public var keptCount: Int { items.filter { $0.keep && !$0.isHidden }.count }
}

public enum ReviewSchemas {
    public static let stageOne = """
    {"type":"object","additionalProperties":false,"required":["summary","findings"],
     "properties":{
      "summary":{"type":"string"},
      "findings":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["id","severity","category","file","line","title","body"],
        "properties":{
          "id":{"type":"string"},
          "severity":{"type":"string","enum":["high","medium","low"]},
          "category":{"type":"string","enum":["bug","security","performance","tests","style","docs","other"]},
          "file":{"type":"string"},
          "line":{"type":["integer","null"]},
          "title":{"type":"string"},
          "body":{"type":"string"}}}}}}
    """

    /// Stage 1 with memory (spec RM.4): `findings` as always plus `previous`, one per previous comment.
    public static let stageOneWithMemory = """
    {"type":"object","additionalProperties":false,"required":["summary","findings","previous"],
     "properties":{
      "summary":{"type":"string"},
      "findings":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["id","severity","category","file","line","title","body"],
        "properties":{
          "id":{"type":"string"},
          "severity":{"type":"string","enum":["high","medium","low"]},
          "category":{"type":"string","enum":["bug","security","performance","tests","style","docs","other"]},
          "file":{"type":"string"},
          "line":{"type":["integer","null"]},
          "title":{"type":"string"},
          "body":{"type":"string"}}}},
      "previous":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["id","status","note"],
        "properties":{
          "id":{"type":"string"},
          "status":{"type":"string","enum":["fixed","notFixed","partially","unclear"]},
          "note":{"type":"string"}}}}}}
    """

    public static let stageTwo = """
    {"type":"object","additionalProperties":false,"required":["verdicts"],
     "properties":{"verdicts":{"type":"array","items":{"type":"object","additionalProperties":false,
       "required":["id","verdict","reason"],
       "properties":{"id":{"type":"string"},"verdict":{"type":"string","enum":["keep","discard"]},"reason":{"type":"string"}}}}}}
    """
}
