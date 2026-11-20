import Foundation

/// How a Claude stage is driven (spec E.5/E.6): with its skill, or with the user's own prompt.
public enum StageMode: String, Codable, CaseIterable, Sendable {
    case skill, prompt

    public var title: String { self == .skill ? "Skill" : "Custom Prompt" }

    public init(from decoder: Decoder) throws {
        self = StageMode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .skill
    }
}

/// One stage: the review (stage 1), the analysis or the implementation. The filter is `FilterSettings`.
public struct StageSettings: Hashable, Codable, Sendable {
    public var mode: StageMode
    /// `plugin:skill` or a bare name. `nil`: no skill (the implementation has none by default).
    public var skill: String?
    /// The user's prompt. It's kept when going back to `skill`, so switching modes doesn't lose it.
    public var prompt: String?

    public init(mode: StageMode = .skill, skill: String?, prompt: String? = nil) {
        self.mode = mode
        self.skill = skill
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey { case mode, skill, prompt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(StageMode.self, forKey: .mode)) ?? .skill
        skill = (try? c.decodeIfPresent(String.self, forKey: .skill)) ?? nil
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? nil
    }

    /// The skill, trimmed, if it's a valid name.
    public var validSkill: String? {
        guard let trimmed = skill?.trimmingCharacters(in: .whitespacesAndNewlines), ClaudeSettings.isValidSkill(trimmed) else {
            return nil
        }
        return trimmed
    }
}

/// The review's filter (stage 2): a stage that can be turned off.
public struct FilterSettings: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var mode: StageMode
    public var skill: String?
    public var prompt: String?

    public init(enabled: Bool = true, mode: StageMode = .skill, skill: String? = ClaudeSettings.defaultFilterSkill,
                prompt: String? = nil) {
        self.enabled = enabled
        self.mode = mode
        self.skill = skill
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey { case enabled, mode, skill, prompt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        mode = (try? c.decodeIfPresent(StageMode.self, forKey: .mode)) ?? .skill
        skill = (try? c.decodeIfPresent(String.self, forKey: .skill)) ?? nil
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? nil
    }

    public var stage: StageSettings {
        get { StageSettings(mode: mode, skill: skill, prompt: prompt) }
        set {
            mode = newValue.mode
            skill = newValue.skill
            prompt = newValue.prompt
        }
    }
}

public enum ReviewTone: String, Codable, CaseIterable, Sendable {
    case direct, friendly, withSuggestions

    public var title: String {
        switch self {
        case .direct: "Direct"
        case .friendly: "Friendly"
        case .withSuggestions: "With Suggestions"
        }
    }

    public init(from decoder: Decoder) throws {
        self = ReviewTone(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .direct
    }
}

public enum CommitMode: String, Codable, CaseIterable, Sendable {
    case perComment, single

    public var title: String { self == .perComment ? "One per Comment" : "Single Commit" }

    public init(from decoder: Decoder) throws {
        self = CommitMode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .perComment
    }
}

/// What the review reports (spec E.5). PRBar tells Claude and also applies them to its answer
/// (`ReviewOptionsFilter`).
public struct ReviewOptions: Hashable, Codable, Sendable {
    public var minSeverity: Severity = .low
    /// The most findings to keep visible (the most severe ones); nil = no limit.
    public var maxFindings: Int?
    /// Globs of files whose findings are hidden, on top of each repo's (`RepoConfig.ignorePaths`).
    public var ignorePaths: [String] = []
    /// On/off by category (raw value); a missing one is on.
    public var categories: [String: Bool] = [:]
    public var tone: ReviewTone = .direct
    public var stage1 = StageSettings(skill: ClaudeSettings.defaultReviewSkill)
    public var filter = FilterSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey { case minSeverity, maxFindings, ignorePaths, categories, tone, stage1, filter }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minSeverity = (try? c.decodeIfPresent(Severity.self, forKey: .minSeverity)) ?? .low
        maxFindings = (try? c.decodeIfPresent(Int.self, forKey: .maxFindings)) ?? nil
        ignorePaths = (try? c.decodeIfPresent([String].self, forKey: .ignorePaths)) ?? []
        categories = (try? c.decodeIfPresent([String: Bool].self, forKey: .categories)) ?? [:]
        tone = (try? c.decodeIfPresent(ReviewTone.self, forKey: .tone)) ?? .direct
        stage1 = (try? c.decodeIfPresent(StageSettings.self, forKey: .stage1))
            ?? StageSettings(skill: ClaudeSettings.defaultReviewSkill)
        filter = (try? c.decodeIfPresent(FilterSettings.self, forKey: .filter)) ?? FilterSettings()
    }

    public func isEnabled(_ category: FindingCategory) -> Bool { categories[category.rawValue] ?? true }

    public mutating func setCategory(_ category: FindingCategory, enabled: Bool) {
        categories[category.rawValue] = enabled
    }

    public var disabledCategories: [FindingCategory] { FindingCategory.allCases.filter { !isEnabled($0) } }

    /// `maxFindings` if it's at least 1.
    public var effectiveMaxFindings: Int? { maxFindings.flatMap { $0 >= 1 ? $0 : nil } }

    /// Trimmed, without empty ones or repeats, in order.
    public static func normalizePatterns(_ patterns: [String]) -> [String] {
        var result: [String] = []
        for pattern in patterns.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !pattern.isEmpty {
            if !result.contains(pattern) { result.append(pattern) }
        }
        return result
    }
}

/// Responding to feedback (spec E.5): the fixes' options and the analysis and implementation stages.
public struct RespondOptions: Hashable, Codable, Sendable {
    public static let defaultCommitMessageTemplate = "Address review feedback ({n} comments)"

    /// Runs the repo's test command before pushing and stops the push if it fails ("Push Anyway").
    public var runTestsBeforePush = false
    public var commitMode: CommitMode = .perComment
    /// nil: a single commit uses `defaultCommitMessageTemplate`; one per comment uses Claude's message.
    public var commitMessageTemplate: String?
    public var allowNewTests = true
    public var allowNewDependencies = false
    /// Replaces "Fixed in <commit>." (`{commit}`, `{summary}`, …); nil = that, in the PR's language.
    public var replyTemplate: String?
    public var analysis = StageSettings(skill: ClaudeSettings.defaultRespondSkill)
    public var implementation = StageSettings(skill: nil)

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case runTestsBeforePush, commitMode, commitMessageTemplate, allowNewTests, allowNewDependencies, replyTemplate
        case analysis, implementation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runTestsBeforePush = (try? c.decodeIfPresent(Bool.self, forKey: .runTestsBeforePush)) ?? false
        commitMode = (try? c.decodeIfPresent(CommitMode.self, forKey: .commitMode)) ?? .perComment
        commitMessageTemplate = (try? c.decodeIfPresent(String.self, forKey: .commitMessageTemplate)) ?? nil
        allowNewTests = (try? c.decodeIfPresent(Bool.self, forKey: .allowNewTests)) ?? true
        allowNewDependencies = (try? c.decodeIfPresent(Bool.self, forKey: .allowNewDependencies)) ?? false
        replyTemplate = (try? c.decodeIfPresent(String.self, forKey: .replyTemplate)) ?? nil
        analysis = (try? c.decodeIfPresent(StageSettings.self, forKey: .analysis))
            ?? StageSettings(skill: ClaudeSettings.defaultRespondSkill)
        implementation = (try? c.decodeIfPresent(StageSettings.self, forKey: .implementation)) ?? StageSettings(skill: nil)
    }

    /// The commit template if it isn't blank.
    public var effectiveCommitTemplate: String? { Self.nonBlank(commitMessageTemplate) }
    /// The reply template if it isn't blank.
    public var effectiveReplyTemplate: String? { Self.nonBlank(replyTemplate) }

    static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// The chats' own prompts (spec E.6); nil = the default.
public struct ChatPromptSettings: Hashable, Codable, Sendable {
    public var review: String?
    public var respond: String?
    /// The merge window's chat (spec G.4).
    public var merge: String?
    public var instructions: String?

    public init(review: String? = nil, respond: String? = nil, merge: String? = nil, instructions: String? = nil) {
        self.review = review
        self.respond = respond
        self.merge = merge
        self.instructions = instructions
    }

    private enum CodingKeys: String, CodingKey { case review, respond, merge, instructions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        review = (try? c.decodeIfPresent(String.self, forKey: .review)) ?? nil
        respond = (try? c.decodeIfPresent(String.self, forKey: .respond)) ?? nil
        merge = (try? c.decodeIfPresent(String.self, forKey: .merge)) ?? nil
        instructions = (try? c.decodeIfPresent(String.self, forKey: .instructions)) ?? nil
    }
}
