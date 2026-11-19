import Foundation

/// Encuentra `gh`, `git` y `claude`. Las apps de GUI no heredan el PATH del usuario (spec §3).
public struct ToolLocator: Sendable {
    private let runner: ProcessRunning
    private let home: String
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        runner: ProcessRunning,
        home: String = NSHomeDirectory(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.runner = runner
        self.home = home
        self.isExecutable = isExecutable
    }

    public func locate(_ tool: String, override: String?) async -> String? {
        if let override, !override.isEmpty {
            return isExecutable(override) ? override : nil
        }
        guard !tool.isEmpty, tool.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }

        if let result = try? await runner.run("/bin/zsh", ["-lc", "command -v \(tool)"], timeout: ProcessTimeouts.standard), result.status == 0 {
            let path = result.stdout
                .split(separator: "\n")
                .last
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if path.hasPrefix("/"), isExecutable(path) { return path }
        }
        return fallbackCandidates(for: tool).first(where: isExecutable)
    }

    private func fallbackCandidates(for tool: String) -> [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/.local/bin", "\(home)/.claude/local"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted(by: >).map { "\(nvm)/\($0)/bin" }
        }
        return dirs.map { "\($0)/\(tool)" }
    }
}
