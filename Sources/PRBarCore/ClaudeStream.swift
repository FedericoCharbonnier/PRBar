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

    public mutating func consume(_ line: String) -> ClaudeStreamEvent? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return nil }

        switch type {
        case "assistant":
            let content = ((object["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            let agents = content.filter { ($0["type"] as? String) == "tool_use" && ["Agent", "Task"].contains($0["name"] as? String ?? "") }
            guard !agents.isEmpty else { return nil }
            agentCount += agents.count
            return .agentStarted(total: agentCount)
        case "result":
            let structured = object["structured_output"].flatMap { value -> Data? in
                guard !(value is NSNull) else { return nil }
                return try? JSONSerialization.data(withJSONObject: value)
            }
            result = ClaudeResult(
                isError: object["is_error"] as? Bool ?? false,
                text: object["result"] as? String ?? "",
                structuredJSON: structured,
                costUSD: object["total_cost_usd"] as? Double
            )
            return nil
        default:
            return nil
        }
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
