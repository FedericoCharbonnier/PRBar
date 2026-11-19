import Foundation
import PRBarCore

private func makeDir(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

private func write(_ text: String, to url: URL) throws {
    try makeDir(url.deletingLastPathComponent())
    try Data(text.utf8).write(to: url)
}

private func setModified(_ url: URL, _ seconds: TimeInterval) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
}

private func decodeConfig(_ json: String) throws -> AppConfig {
    try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
}

private func skillFile(name: String?, description: String?) -> String {
    var lines = ["---"]
    if let name { lines.append("name: \(name)") }
    if let description { lines.append("description: \(description)") }
    lines += ["---", "", "# Body", "description: not frontmatter"]
    return lines.joined(separator: "\n")
}

/// `<cache>/<marketplace>/<plugin>/<version>`.
private func install(_ plugin: String, version: String = "1.0", marketplace: String = "official", in cache: URL) throws -> URL {
    let dir = cache.appendingPathComponent("\(marketplace)/\(plugin)/\(version)", isDirectory: true)
    try makeDir(dir.appendingPathComponent(".claude-plugin"))
    return dir
}

private let initLine = #"{"type":"system","subtype":"init","skills":["superpowers:receiving-code-review","humanizer"],"slash_commands":["pr-review-toolkit:review-pr","clear"]}"#
private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#

enum ClaudeSkillsTests {
    static let cases: [TestCase] = [
        // MARK: Config
        TestCase("claude settings: chat on by default, same model as the review") {
            let settings = ClaudeSettings()
            try expectEqual(settings.chatEnabled, true)
            try expectEqual(settings.chatModel, nil)
            try expectEqual(settings.effectiveChatModel, nil)
            var sonnet = settings
            sonnet.model = .sonnet
            try expectEqual(sonnet.effectiveChatModel, .sonnet)
            sonnet.chatModel = .haiku
            try expectEqual(sonnet.effectiveChatModel, .haiku)
        },
        TestCase("claude settings: chat keys decode leniently and round-trip") {
            try expectEqual(try decodeConfig(#"{"claude":{"model":"opus"}}"#).claude.chatEnabled, true)
            let off = try decodeConfig(#"{"claude":{"chatEnabled":false,"chatModel":"haiku"}}"#).claude
            try expectEqual(off.chatEnabled, false)
            try expectEqual(off.chatModel, .haiku)
            let bad = try decodeConfig(#"{"claude":{"chatEnabled":"no","chatModel":"gpt-9"}}"#).claude
            try expectEqual(bad.chatEnabled, true)
            try expectEqual(bad.chatModel, nil)
            var config = AppConfig()
            config.claude.chatEnabled = false
            config.claude.chatModel = .sonnet
            let data = try JSONCoding.encoder.encode(config)
            try expectEqual(try JSONCoding.decoder.decode(AppConfig.self, from: data), config)
        },

        TestCase("claude settings: the defaults reproduce the hard-coded skills") {
            let settings = ClaudeSettings()
            try expectEqual(settings.reviewSkill, "pr-review-toolkit:review-pr")
            try expectEqual(settings.filterEnabled, true)
            try expectEqual(settings.filterSkill, "superpowers:receiving-code-review")
            try expectEqual(settings.respondSkill, "superpowers:receiving-code-review")
            try expectEqual(settings.model, nil)
            try expectEqual(AppConfig().claude, settings)
            try expectEqual(settings.reviewSkills, ["pr-review-toolkit:review-pr", "superpowers:receiving-code-review"])
            try expectEqual(settings.respondSkills, ["superpowers:receiving-code-review"])
        },
        TestCase("claude settings: an old config without `claude` decodes with the defaults") {
            try expectEqual(try decodeConfig(#"{"refreshIntervalMinutes":5}"#).claude, ClaudeSettings())
        },
        TestCase("claude settings: decodes leniently (missing keys, unknown model)") {
            let config = try decodeConfig(#"{"claude":{"filterEnabled":false,"model":"gpt-9","respondSkill":"me:mine"}}"#)
            try expectEqual(config.claude.filterEnabled, false)
            try expectEqual(config.claude.model, nil)
            try expectEqual(config.claude.respondSkill, "me:mine")
            try expectEqual(config.claude.reviewSkill, ClaudeSettings.defaultReviewSkill)
            try expectEqual(config.claude.filterSkill, ClaudeSettings.defaultFilterSkill)
            try expectEqual(try decodeConfig(#"{"claude":{"model":"sonnet"}}"#).claude.model, .sonnet)
            // A wrong type in one field doesn't lose the whole config.
            try expectEqual(try decodeConfig(#"{"claude":{"filterEnabled":"yes","reviewSkill":7}}"#).claude, ClaudeSettings())
        },
        TestCase("claude settings: round-trips through JSON") {
            var config = AppConfig()
            config.claude.reviewSkill = "my-plugin:deep-review"
            config.claude.filterEnabled = false
            config.claude.model = .haiku
            let data = try JSONCoding.encoder.encode(config)
            try expectEqual(try JSONCoding.decoder.decode(AppConfig.self, from: data), config)
        },
        TestCase("claude settings: only filter skills when the filter is on; blank or invalid skills fall back to the default") {
            var settings = ClaudeSettings()
            settings.filterEnabled = false
            try expectEqual(settings.reviewSkills, ["pr-review-toolkit:review-pr"])
            settings.reviewSkill = "  my-plugin:deep-review \n"
            settings.respondSkill = "   "
            settings.filterSkill = "bad`skill"
            try expectEqual(settings.effectiveReviewSkill, "my-plugin:deep-review")
            try expectEqual(settings.effectiveRespondSkill, ClaudeSettings.defaultRespondSkill)
            try expectEqual(settings.effectiveFilterSkill, ClaudeSettings.defaultFilterSkill)
        },
        TestCase("claude settings: valid skill names and their plugin") {
            for valid in ["pr-review-toolkit:review-pr", "humanizer", "a.b_c:d-e", "x:y:z"] {
                try expect(ClaudeSettings.isValidSkill(valid), valid)
            }
            for invalid in ["", " ", "a b", "a`b", "../x:y", ":x", "x:", "a/b:c", "a\nb", ".x:y"] {
                try expect(!ClaudeSettings.isValidSkill(invalid), invalid)
            }
            try expectEqual(ClaudeSettings.plugin(of: "pr-review-toolkit:review-pr"), "pr-review-toolkit")
            try expectEqual(ClaudeSettings.plugin(of: "x:y:z"), "x")
            try expectEqual(ClaudeSettings.plugin(of: "humanizer"), nil)
        },
        TestCase("claude settings: the model maps to --model") {
            try expectEqual(ClaudeModel.allCases.map(\.rawValue), ["opus", "sonnet", "haiku"])
            try expectEqual(ClaudeModel.allCases.map(\.title), ["Opus", "Sonnet", "Haiku"])
        },

        // MARK: Plugins

        TestCase("claude plugins: one dir per plugin of the skills, newest version across marketplaces, no repeats") {
            let cache = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: cache) }
            let toolkit = try install("pr-review-toolkit", version: "unknown", in: cache)
            let old = try install("superpowers", version: "5.0.6", in: cache)
            let new = try install("superpowers", version: "5.0.7", marketplace: "other", in: cache)
            try setModified(old, 1_000)
            try setModified(new, 2_000)
            let dirs = try ClaudePlugins.locate(
                skills: ["pr-review-toolkit:review-pr", "superpowers:receiving-code-review", "superpowers:x", "humanizer"],
                in: cache
            )
            try expectEqual(dirs, [toolkit.path, new.path])
            try expectEqual(try ClaudePlugins.locate(skills: ["humanizer"], in: cache), [])
        },
        TestCase("claude plugins: a skill whose plugin isn't installed fails naming the skill and how to install it") {
            let cache = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: cache) }
            _ = try install("pr-review-toolkit", in: cache)
            let error = try await expectThrows {
                _ = try ClaudePlugins.locate(skills: ["pr-review-toolkit:review-pr", "my-plugin:deep-review"], in: cache)
            }
            try expectEqual(error as? PRBarError, .claudePluginMissing(plugin: "my-plugin", skill: "my-plugin:deep-review"))
            let message = (error as? PRBarError)?.errorDescription ?? ""
            try expect(message.contains("my-plugin:deep-review"), message)
            try expect(message.contains("/plugin install my-plugin"), message)
            try expect(message.contains("Settings"), message)
        },

        // MARK: Catalog

        TestCase("skill catalog: lists skills and commands of the newest install of each plugin, with descriptions") {
            let cache = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: cache) }
            let powers = try install("superpowers", version: "5.0.7", in: cache)
            let stale = try install("superpowers", version: "5.0.6", in: cache)
            try setModified(stale, 1_000)
            try write(skillFile(name: "old-only", description: "Stale"), to: stale.appendingPathComponent("skills/old-only/SKILL.md"))
            try write(skillFile(name: "receiving-code-review", description: "Use when receiving code review feedback"),
                      to: powers.appendingPathComponent("skills/receiving-code-review/SKILL.md"))
            // No `name:`: the folder.
            try write(skillFile(name: nil, description: "\"Quoted: with colon\""),
                      to: powers.appendingPathComponent("skills/folder-name/SKILL.md"))
            try write("no frontmatter", to: powers.appendingPathComponent("skills/bare/SKILL.md"))
            try makeDir(powers.appendingPathComponent("skills/empty-dir"))
            try write(skillFile(name: nil, description: "Deprecated"), to: powers.appendingPathComponent("commands/brainstorm.md"))
            try write("x", to: powers.appendingPathComponent("commands/notes.txt"))
            let toolkit = try install("pr-review-toolkit", version: "unknown", marketplace: "mkt", in: cache)
            try write(skillFile(name: nil, description: "Comprehensive PR review using specialized agents"),
                      to: toolkit.appendingPathComponent("commands/review-pr.md"))
            let toolkitDir = cache.appendingPathComponent("mkt/pr-review-toolkit/unknown")

            let entries = ClaudeSkillCatalog.scan(pluginCache: cache, userSkills: cache.appendingPathComponent("none"))
            try expectEqual(entries.map(\.id), [
                "pr-review-toolkit:review-pr",
                "superpowers:bare", "superpowers:brainstorm", "superpowers:folder-name", "superpowers:receiving-code-review",
            ])
            let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            try expectEqual(byID["pr-review-toolkit:review-pr"]?.description, "Comprehensive PR review using specialized agents")
            try expectEqual(byID["pr-review-toolkit:review-pr"]?.source, .plugin(name: "pr-review-toolkit", directory: toolkitDir.path))
            try expectEqual(byID["superpowers:folder-name"]?.description, "Quoted: with colon")
            try expectEqual(byID["superpowers:bare"]?.description, nil)
            try expectEqual(byID["superpowers:receiving-code-review"]?.availability, .available)
        },
        TestCase("skill catalog: block-scalar descriptions are folded into one line") {
            let text = """
                ---
                name: humanizer
                version: 2.1.1
                description: |
                  Remove signs of AI-generated writing.
                  Based on a guide.
                allowed-tools:
                  - Read
                ---
                body
                """
            let front = ClaudeSkillCatalog.frontmatter(text)
            try expectEqual(front["name"], "humanizer")
            try expectEqual(front["description"], "Remove signs of AI-generated writing. Based on a guide.")
            try expectEqual(ClaudeSkillCatalog.frontmatter("---\ndescription: >-\n  a\n  b\n---\n")["description"], "a b")
            try expectEqual(ClaudeSkillCatalog.frontmatter("description: no fences"), [:])
            try expectEqual(ClaudeSkillCatalog.frontmatter("---\nname: 'single'\n---")["name"], "single")
        },
        TestCase("skill catalog: user skills are checking until probed, then available only if they load in isolated runs") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let user = root.appendingPathComponent("skills")
            try write(skillFile(name: "humanizer", description: "Remove signs of AI writing"), to: user.appendingPathComponent("humanizer/SKILL.md"))
            try write(skillFile(name: nil, description: "Review a PR"), to: user.appendingPathComponent("pr-review/SKILL.md"))
            try makeDir(user.appendingPathComponent("synced"))
            let entries = ClaudeSkillCatalog.scan(pluginCache: root.appendingPathComponent("cache"), userSkills: user)
            try expectEqual(entries.map(\.id), ["humanizer", "pr-review"])
            try expectEqual(entries.map(\.source), [.user, .user])
            try expectEqual(entries.map(\.availability), [.checking, .checking])
            try expect(ClaudeSkillCatalog.hasUserSkills(entries))

            let probed = ClaudeSkillCatalog.applying(probe: ["humanizer", "superpowers:x"], to: entries)
            try expectEqual(probed.map(\.availability), [.available, .unavailable(ClaudeSkillCatalog.notIsolatedReason)])
            try expectEqual(ClaudeSkillCatalog.notIsolatedReason, "Not available in isolated runs")
            // A failed probe (nothing loaded) leaves them all disabled.
            try expectEqual(ClaudeSkillCatalog.applying(probe: [], to: entries).map(\.isAvailable), [false, false])
        },

        // MARK: Probe

        TestCase("skill probe: a cheap read-only isolated run (haiku, no tools, no MCP, no user settings)") {
            let args = ClaudeSkillProbe.arguments(pluginDirs: ["/p/superpowers/5.0.7"])
            try expectEqual(args, [
                "-p", "Reply ok", "--model", "haiku", "--output-format", "stream-json", "--verbose",
                "--setting-sources", "",
                "--settings", ClaudeRunner.settings(additionalDirectories: []),
                "--plugin-dir", "/p/superpowers/5.0.7",
                "--permission-mode", "dontAsk",
                "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                "--tools", "",
                "--disallowedTools", "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,mcp__*",
            ])
        },
        TestCase("skill probe: reads skills and slash commands from the init event") {
            let runner = FakeStreamingRunner { _, _, _ in (["not json", initLine, resultLine], ok("")) }
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let loaded = try await ClaudeSkillProbe.run(runner: runner, claudePath: "/usr/local/bin/claude",
                                                        pluginDirs: [], directory: directory)
            try expectEqual(loaded, ["superpowers:receiving-code-review", "humanizer", "pr-review-toolkit:review-pr", "clear"])
            try expectEqual(runner.isolated, [true])
            let call = runner.calls[0]
            try expectEqual(call.currentDirectory, directory)
            try expectEqual(call.timeout, ClaudeSkillProbe.timeout)
            try expect(Set(call.environment?.keys ?? [:].keys).isSubset(of: Set(ClaudeRunner.environmentAllowlist)))
            try expectEqual(call.environment?["PATH"], "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        },
        TestCase("skill probe: without an init event it fails") {
            let runner = FakeStreamingRunner { _, _, _ in ([resultLine], fail("boom", status: 1)) }
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = try await expectThrows {
                _ = try await ClaudeSkillProbe.run(runner: runner, claudePath: "/c", pluginDirs: [], directory: directory)
            }
        },
    ]
}
