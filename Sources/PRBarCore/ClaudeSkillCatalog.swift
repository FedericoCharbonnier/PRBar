import Foundation
import os

/// A skill that Settings → Claude offers: `plugin:skill` from an installed plugin, or a user skill
/// (`~/.claude/skills`), which only counts if it loads in PRBar's isolated runs (see `ClaudeSkillProbe`).
public struct ClaudeSkillEntry: Hashable, Sendable, Identifiable {
    public enum Source: Hashable, Sendable {
        /// A skill (`skills/*/SKILL.md`) or command (`commands/*.md`) of the plugin installed at `directory`.
        case plugin(name: String, directory: String)
        /// `~/.claude/skills/<name>/SKILL.md`.
        case user
    }

    public enum Availability: Hashable, Sendable {
        case available
        /// User skill whose probe hasn't finished.
        case checking
        /// Shown disabled, with the reason.
        case unavailable(String)
    }

    /// What goes in the config and the prompt: `plugin:skill` or `skill`.
    public let id: String
    /// The frontmatter's `description`, folded into one line.
    public let description: String?
    public let source: Source
    public var availability: Availability

    public init(id: String, description: String?, source: Source, availability: Availability) {
        self.id = id
        self.description = description
        self.source = source
        self.availability = availability
    }

    public var isAvailable: Bool { availability == .available }
}

/// Lists the skills that the review and respond flows can use, scanning the installed plugins and the user skills.
public enum ClaudeSkillCatalog {
    public static let notIsolatedReason = "Not available in isolated runs"

    /// `~/.claude/skills`.
    public static var defaultUserSkillsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true)
    }

    /// Plugin skills and commands (newest install of each plugin, sorted by id), then user skills (sorted, `checking`
    /// until `applying(probe:to:)`). A plugin skill with the same id as one of its commands wins.
    public static func scan(pluginCache: URL = ClaudePlugins.defaultCacheDirectory,
                            userSkills: URL = defaultUserSkillsDirectory) -> [ClaudeSkillEntry] {
        var pluginEntries: [String: ClaudeSkillEntry] = [:]
        for (plugin, directory) in ClaudePlugins.installed(in: pluginCache) {
            let source = ClaudeSkillEntry.Source.plugin(name: plugin, directory: directory.path)
            for command in markdownFiles(in: directory.appendingPathComponent("commands")) {
                let front = frontmatter(read(command))
                let id = "\(plugin):\(command.deletingPathExtension().lastPathComponent)"
                guard ClaudeSettings.isValidSkill(id) else { continue }
                pluginEntries[id] = ClaudeSkillEntry(id: id, description: front["description"], source: source, availability: .available)
            }
            for (name, description) in skills(in: directory.appendingPathComponent("skills")) {
                let id = "\(plugin):\(name)"
                guard ClaudeSettings.isValidSkill(id) else { continue }
                pluginEntries[id] = ClaudeSkillEntry(id: id, description: description, source: source, availability: .available)
            }
        }
        let user = skills(in: userSkills)
            .filter { ClaudeSettings.isValidSkill($0.name) && ClaudeSettings.plugin(of: $0.name) == nil }
            .map { ClaudeSkillEntry(id: $0.name, description: $0.description, source: .user, availability: .checking) }
        return pluginEntries.values.sorted { $0.id < $1.id } + unique(user).sorted { $0.id < $1.id }
    }

    /// Marks each user skill available only if it's in `probe` (what loaded in an isolated run).
    public static func applying(probe loaded: Set<String>, to entries: [ClaudeSkillEntry]) -> [ClaudeSkillEntry] {
        entries.map { entry in
            guard entry.source == .user else { return entry }
            var entry = entry
            entry.availability = loaded.contains(entry.id) ? .available : .unavailable(notIsolatedReason)
            return entry
        }
    }

    public static func hasUserSkills(_ entries: [ClaudeSkillEntry]) -> Bool {
        entries.contains { $0.source == .user }
    }

    // MARK: - Frontmatter

    /// The top-level `key: value` pairs of a YAML frontmatter (between `---` lines). Quotes are removed and block
    /// scalars (`|`, `>`) are folded into one line. Without frontmatter, empty.
    public static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return [:] }
        let body = Array(lines[1..<end])
        var result: [String: String] = [:]
        var index = 0
        while index < body.count {
            let line = body[index]
            index += 1
            guard let first = line.first, !first.isWhitespace, first != "-", first != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if ["|", "|-", "|+", ">", ">-", ">+"].contains(value) {
                var block: [String] = []
                while index < body.count, body[index].first?.isWhitespace ?? true {
                    block.append(body[index])
                    index += 1
                }
                value = block.joined(separator: " ")
            } else if value.count >= 2, let quote = value.first, ["\"", "'"].contains(quote), value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            let folded = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !folded.isEmpty { result[key] = folded }
        }
        return result
    }

    // MARK: - Private

    /// `<dir>/*/SKILL.md`: the name (`name:` or the folder) and the description.
    private static func skills(in directory: URL) -> [(name: String, description: String?)] {
        ClaudePlugins.subdirectories(of: directory).compactMap { folder in
            let file = folder.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let front = frontmatter(read(file))
            let declared = front["name"].flatMap { ClaudeSettings.isValidSkill($0) ? $0 : nil }
            return (declared ?? folder.lastPathComponent, front["description"])
        }
    }

    private static func markdownFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .map { directory.appendingPathComponent($0) }
            .filter { !ClaudePlugins.isDirectory($0) }
    }

    private static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func unique(_ entries: [ClaudeSkillEntry]) -> [ClaudeSkillEntry] {
        var seen: Set<String> = []
        return entries.filter { seen.insert($0.id).inserted }
    }
}

/// Checks which skills load in PRBar's isolated runs: a cheap, read-only `claude -p "Reply ok"` with Haiku, no tools,
/// no MCP and no user settings, reading the `skills` and `slash_commands` of its `init` event.
public enum ClaudeSkillProbe {
    public static let timeout: TimeInterval = 90

    public static func arguments(pluginDirs: [String]) -> [String] {
        var arguments = [
            "-p", "Reply ok", "--model", ClaudeModel.haiku.rawValue,
            "--output-format", "stream-json", "--verbose",
            "--setting-sources", "",
            "--settings", ClaudeRunner.settings(additionalDirectories: []),
        ]
        for dir in pluginDirs { arguments += ["--plugin-dir", dir] }
        arguments += [
            "--permission-mode", "dontAsk",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--tools", "",
            "--disallowedTools", ClaudeRunner.disallowedTools(for: []).joined(separator: ","),
        ]
        return arguments
    }

    /// The skill and command names that loaded. `directory` is Claude's cwd (an empty folder). Throws if there
    /// was no `init` event.
    public static func run(runner: StreamingProcessRunning, claudePath: String, pluginDirs: [String],
                           directory: URL) async throws -> Set<String> {
        let found = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)
        let result = try await runner.runStreamingIsolated(
            claudePath, arguments(pluginDirs: pluginDirs),
            environment: ClaudeRunner.environment(toolPaths: [claudePath]), currentDirectory: directory, timeout: timeout
        ) { line in
            guard let loaded = loaded(fromInit: line) else { return }
            found.withLock { $0 = ($0 ?? []).union(loaded) }
        }
        if let loaded = found.withLock({ $0 }) { return loaded }
        if result.status != 0 {
            throw PRBarError.commandFailed(command: "claude", status: result.status,
                                           stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw ClaudeError.invalidOutput("there was no init event")
    }

    /// `skills` ∪ `slash_commands` if `line` is the `system`/`init` event.
    static func loaded(fromInit line: String) -> Set<String>? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "system", object["subtype"] as? String == "init" else { return nil }
        let skills = object["skills"] as? [String] ?? []
        let commands = object["slash_commands"] as? [String] ?? []
        return Set(skills + commands)
    }
}
