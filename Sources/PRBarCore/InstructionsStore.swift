import Foundation

/// The user's decision about a suggestion (spec E.4): "Never", or "Not Now" until a date.
public struct SuggestionDecision: Codable, Equatable, Sendable {
    public let key: String
    public var never: Bool
    public var snoozedUntil: Date?

    public init(key: String, never: Bool, snoozedUntil: Date?) {
        self.key = key
        self.never = never
        self.snoozedUntil = snoozedUntil
    }
}

/// The instructions chat (spec E.2): the last 50 messages and the Claude session that `--resume` continues.
public struct InstructionsChat: Codable, Equatable, Sendable {
    public static let maxMessages = 50

    public var claudeSessionID: UUID?
    public var messages: [ChatMessage]
    /// A turn was running when this was saved; on the next launch it becomes "Interrupted".
    public var pending: Bool
    /// The repos and rules (JSON) as Claude last saw them: the next turn sends them only if they changed.
    public var lastState: String?

    public init() {
        claudeSessionID = nil
        messages = []
        pending = false
        lastState = nil
    }

    private enum CodingKeys: String, CodingKey { case claudeSessionID, messages, pending, lastState }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeSessionID = (try? c.decodeIfPresent(UUID.self, forKey: .claudeSessionID)) ?? nil
        // Element by element, like `ChatSession`: a broken message is skipped.
        messages = (try? c.decodeIfPresent(LossyArray<ChatMessage>.self, forKey: .messages))?.elements ?? []
        pending = (try? c.decodeIfPresent(Bool.self, forKey: .pending)) ?? false
        lastState = (try? c.decodeIfPresent(String.self, forKey: .lastState)) ?? nil
    }

    /// Like `ChatSession.undoableMessageID`: the last message with changes not undone.
    public var undoableMessageID: UUID? {
        messages.last { !$0.changes.isEmpty && !$0.undone }?.id
    }

    /// A turn left `pending` becomes an "Interrupted" error.
    public func recovered(now: Date = Date()) -> InstructionsChat {
        guard pending else { return self }
        var chat = self
        chat.pending = false
        chat.messages.append(ChatMessage(role: .error, text: ChatSession.interruptedText, createdAt: now))
        return chat
    }

    /// Keeps the last `maxMessages`.
    public mutating func trim() {
        if messages.count > Self.maxMessages { messages.removeFirst(messages.count - Self.maxMessages) }
    }
}

/// `instructions.json` (spec E.1).
public struct InstructionsFile: Codable, Equatable, Sendable {
    public var rules: [Rule]
    public var suggestionDecisions: [SuggestionDecision]
    public var chat: InstructionsChat

    public init(rules: [Rule] = [], suggestionDecisions: [SuggestionDecision] = [], chat: InstructionsChat = InstructionsChat()) {
        self.rules = rules
        self.suggestionDecisions = suggestionDecisions
        self.chat = chat
    }

    private enum CodingKeys: String, CodingKey { case rules, suggestionDecisions, chat }

    /// Skips anything that can be decoded. Used to skip a broken rule.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    /// Lenient: a broken rule is dropped and the rest stays; a broken section is empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var rules: [Rule] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .rules) {
            while !list.isAtEnd {
                if let rule = try? list.decode(Rule.self) {
                    rules.append(rule)
                } else {
                    _ = try? list.decode(Skip.self)
                }
            }
        }
        self.rules = rules
        suggestionDecisions = (try? c.decodeIfPresent([SuggestionDecision].self, forKey: .suggestionDecisions)) ?? []
        chat = (try? c.decodeIfPresent(InstructionsChat.self, forKey: .chat)) ?? InstructionsChat()
    }
}

/// Reads and writes `instructions.json`. Only the app writes it; every change is saved at once, atomically.
@MainActor
public final class InstructionsStore: ObservableObject {
    @Published public private(set) var file: InstructionsFile
    @Published public private(set) var loadError: String?
    private let fileURL: URL
    private let now: () -> Date

    public init(fileURL: URL = AppPaths.instructionsFile, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        let (file, error) = Self.loadOrRecover(fileURL)
        self.file = file
        loadError = error
        if let error { AppLog.write(error) }
    }

    public var rules: [Rule] { file.rules }

    @discardableResult
    public func addRule(_ text: String, scope: RuleScope, appliesTo: Set<RuleStage>, source: RuleSource,
                        category: FindingCategory? = nil) throws -> Rule {
        guard !appliesTo.isEmpty else { throw RuleError.noStage }
        let rule = Rule(scope: scope, appliesTo: appliesTo, text: try RuleText.validated(text), source: source,
                        createdAt: now(), category: category)
        try update { $0.rules.append(rule) }
        return rule
    }

    public func editRule(_ id: UUID, text: String? = nil, scope: RuleScope? = nil, appliesTo: Set<RuleStage>? = nil) throws {
        let validText = try text.map { try RuleText.validated($0) }
        if let appliesTo, appliesTo.isEmpty { throw RuleError.noStage }
        try updateRule(id) { rule in
            if let validText { rule.text = validText }
            if let scope { rule.scope = scope }
            if let appliesTo { rule.appliesTo = appliesTo }
        }
    }

    public func setRuleEnabled(_ id: UUID, _ enabled: Bool) throws {
        try updateRule(id) { $0.enabled = enabled }
    }

    public func removeRule(_ id: UUID) throws {
        guard file.rules.contains(where: { $0.id == id }) else { throw RuleError.notFound }
        try update { $0.rules.removeAll { $0.id == id } }
    }

    /// The instructions chat applies (and undoes) whole lists, already validated by `RuleActions`.
    public func replaceRules(_ rules: [Rule]) throws {
        try update { $0.rules = rules }
    }

    public func saveChat(_ chat: InstructionsChat) throws {
        var chat = chat
        chat.trim()
        try update { $0.chat = chat }
    }

    /// "Never" (`never: true`) or "Not Now" until `until` (spec E.4).
    public func decideSuggestion(_ key: String, never: Bool, until: Date?) throws {
        try update { file in
            file.suggestionDecisions.removeAll { $0.key == key }
            file.suggestionDecisions.append(SuggestionDecision(key: key, never: never, snoozedUntil: until))
        }
    }

    private func updateRule(_ id: UUID, _ mutate: (inout Rule) -> Void) throws {
        guard let index = file.rules.firstIndex(where: { $0.id == id }) else { throw RuleError.notFound }
        var rule = file.rules[index]
        mutate(&rule)
        guard rule != file.rules[index] else { return }
        rule.updatedAt = now()
        try update { $0.rules[index] = rule }
    }

    private func update(_ mutate: (inout InstructionsFile) -> Void) throws {
        var next = file
        mutate(&next)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(next).write(to: fileURL, options: .atomic)
        file = next
    }

    private static func loadOrRecover(_ url: URL) -> (InstructionsFile, String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (InstructionsFile(), nil) }
        do {
            return (try JSONCoding.decoder.decode(InstructionsFile.self, from: Data(contentsOf: url)), nil)
        } catch {
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return (InstructionsFile(), "Couldn't read instructions.json (\(error.localizedDescription)). A copy was saved to instructions.json.bak and PRBar started with no rules.")
        }
    }
}
