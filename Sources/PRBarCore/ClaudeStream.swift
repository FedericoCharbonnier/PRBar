import Foundation

public enum ClaudeError: Error, Equatable, LocalizedError {
    case noResult
    case failed(String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .noResult: "Claude finished without returning a result."
        case .failed(let message): "Claude failed: \(message)"
        case .invalidOutput(let detail): "Claude returned a result in an invalid format: \(detail)"
        }
    }
}

public enum ClaudeStreamEvent: Equatable, Sendable {
    case agentStarted(total: Int)
    /// Text Claude wrote in an assistant message (not the structured output), trimmed and not empty.
    case text(String)
    /// A tool call: its name and its most telling input (`file_path`, `path`, `pattern`, `skill`, `description`).
    case toolUse(name: String, detail: String?)
}

public struct ClaudeResult: Equatable, Sendable {
    public let isError: Bool
    public let text: String
    /// JSON crudo de `structured_output`, si vino.
    public let structuredJSON: Data?
    public let costUSD: Double?
}

/// Lee el `--output-format stream-json` de `claude -p`, línea por línea.
public struct ClaudeStreamParser: Sendable {
    public private(set) var agentCount = 0
    public private(set) var result: ClaudeResult?

    public init() {}

    /// The tool the CLI uses to return the structured output (`--json-schema`): it isn't an activity to show.
    static let hiddenTools: Set<String> = ["StructuredOutput"]

    /// Only the subagent count (what the review and the analysis show); see `consumeAll`.
    public mutating func consume(_ line: String) -> ClaudeStreamEvent? {
        consumeAll(line).last { event in
            if case .agentStarted = event { return true }
            return false
        }
    }

    /// Every event of a line, in order: each text block and each tool call of an assistant message, and then,
    /// if it started subagents, `agentStarted` with the running total. A `result` line is stored in `result`.
    public mutating func consumeAll(_ line: String) -> [ClaudeStreamEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return [] }

        switch type {
        case "assistant":
            let content = ((object["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            var events: [ClaudeStreamEvent] = []
            var agents = 0
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { events.append(.text(text)) }
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    if ["Agent", "Task"].contains(name) { agents += 1 }
                    guard !name.isEmpty, !Self.hiddenTools.contains(name) else { continue }
                    events.append(.toolUse(name: name, detail: Self.detail(of: block["input"] as? [String: Any] ?? [:])))
                default:
                    continue
                }
            }
            if agents > 0 {
                agentCount += agents
                events.append(.agentStarted(total: agentCount))
            }
            return events
        case "result":
            let structured = object["structured_output"].flatMap { value -> Data? in
                guard !(value is NSNull) else { return nil }
                return try? JSONSerialization.data(withJSONObject: value)
            }
            // An error before any turn (e.g. `--resume` of a session that doesn't exist) has no `result`, only
            // `errors` (checked with the real CLI).
            let errors = (object["errors"] as? [Any])?.compactMap { $0 as? String }.joined(separator: "\n") ?? ""
            result = ClaudeResult(
                isError: object["is_error"] as? Bool ?? false,
                text: (object["result"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? errors,
                structuredJSON: structured,
                costUSD: object["total_cost_usd"] as? Double
            )
            return []
        default:
            return []
        }
    }

    static func detail(of input: [String: Any]) -> String? {
        for key in ["file_path", "path", "pattern", "skill", "description"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    public func decodeResult<T: Decodable>(_ type: T.Type) throws -> T {
        guard let result else { throw ClaudeError.noResult }
        if result.isError { throw ClaudeError.failed(result.text.isEmpty ? "error with no details" : result.text) }
        guard let json = result.structuredJSON ?? Self.lastJSONBlock(in: result.text) else {
            throw ClaudeError.invalidOutput("there is no JSON in the response")
        }
        do {
            return try JSONDecoder().decode(T.self, from: json)
        } catch {
            throw ClaudeError.invalidOutput("\(error)")
        }
    }

    static func lastJSONBlock(in text: String) -> Data? {
        let blocks = text.components(separatedBy: "```json").dropFirst()
        guard let last = blocks.last, let end = last.range(of: "```") else { return nil }
        return String(last[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)
    }
}

/// The "Claude is working…" line of the chat (spec B.2): what the last tool call does, with paths relative to the
/// worktree.
public enum ChatActivity {
    public static func describe(_ event: ClaudeStreamEvent, root: URL?) -> String? {
        guard case .toolUse(let name, let detail) = event else { return nil }
        let target = detail.map { relative($0, to: root) }
        switch name {
        case "Read": return target.map { "Reading \($0)" } ?? "Reading files"
        case "Grep": return target.map { "Searching for “\($0)”" } ?? "Searching the code"
        case "Glob": return target.map { "Looking for \($0)" } ?? "Listing files"
        case "Edit", "Write", "MultiEdit": return target.map { "Editing \($0)" } ?? "Editing files"
        case "Skill": return target.map { "Using the \($0) skill" } ?? "Using a skill"
        case "Agent", "Task": return "Running a subagent"
        default: return "Using \(name)"
        }
    }

    static func relative(_ path: String, to root: URL?) -> String {
        guard let root, path.hasPrefix("/") else { return path }
        let bases = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path, "/private" + root.standardizedFileURL.path]
        for base in bases where path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        return path
    }
}
