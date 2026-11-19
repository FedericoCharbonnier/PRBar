import Foundation
import PRBarCore

private func decodeClaude(_ json: String) throws -> ClaudeSettings {
    try JSONCoding.decoder.decode(AppConfig.self, from: Data(#"{"claude":\#(json)}"#.utf8)).claude
}

private func object(_ value: some Encodable) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(value)) as! [String: Any]
}

enum ClaudeOptionsTests {
    static let cases: [TestCase] = [
        TestCase("claude options: los valores por defecto reproducen el comportamiento actual") {
            let settings = ClaudeSettings()
            try expectEqual(settings.review.minSeverity, .low)
            try expectEqual(settings.review.maxFindings, nil)
            try expectEqual(settings.review.ignorePaths, [])
            try expect(FindingCategory.allCases.allSatisfy { settings.review.isEnabled($0) })
            try expectEqual(settings.review.tone, .direct)
            try expectEqual(settings.review.stage1, StageSettings(mode: .skill, skill: ClaudeSettings.defaultReviewSkill))
            try expectEqual(settings.review.filter.enabled, true)
            try expectEqual(settings.respond.runTestsBeforePush, false)
            try expectEqual(settings.respond.commitMode, .perComment)
            try expectEqual(settings.respond.commitMessageTemplate, nil)
            try expectEqual(settings.respond.allowNewTests, true)
            try expectEqual(settings.respond.allowNewDependencies, false)
            try expectEqual(settings.respond.replyTemplate, nil)
            try expectEqual(settings.respond.analysis.skill, ClaudeSettings.defaultRespondSkill)
            try expectEqual(settings.respond.implementation, StageSettings(mode: .skill, skill: nil))
            try expectEqual(settings.respondSkills, ["superpowers:receiving-code-review"])
        },
        TestCase("claude options: migra los campos de antes y guarda solo la estructura nueva") {
            let old = try decodeClaude(#"{"reviewSkill":"a:b","filterEnabled":false,"filterSkill":"c:d","respondSkill":"e:f","model":"opus"}"#)
            try expectEqual(old.review.stage1.skill, "a:b")
            try expectEqual(old.review.filter.enabled, false)
            try expectEqual(old.review.filter.skill, "c:d")
            try expectEqual(old.respond.analysis.skill, "e:f")
            try expectEqual(old.model, .opus)
            let encoded = try object(old)
            for legacy in ["reviewSkill", "filterEnabled", "filterSkill", "respondSkill"] {
                try expect(encoded[legacy] == nil, legacy)
            }
            try expect(encoded["review"] != nil && encoded["respond"] != nil)
            try expectEqual(try JSONCoding.decoder.decode(ClaudeSettings.self, from: JSONCoding.encoder.encode(old)), old)
        },
        TestCase("claude options: si ya hay estructura nueva, los campos viejos no la pisan") {
            let settings = try decodeClaude(#"{"review":{"stage1":{"mode":"skill","skill":"new:one"}},"reviewSkill":"old:one"}"#)
            try expectEqual(settings.reviewSkill, "new:one")
        },
        TestCase("claude options: decodificación tolerante campo por campo") {
            let json = #"""
            {"review":{"minSeverity":"extreme","maxFindings":"ten","ignorePaths":["dist/**"],"categories":{"style":false,"bogus":true},
                       "tone":"sarcastic","stage1":{"mode":"weird","prompt":"P {diff_path}"},"filter":{"enabled":"no"}},
             "respond":{"runTestsBeforePush":true,"commitMode":"squash","commitMessageTemplate":"Fix {n}","allowNewDependencies":true,
                        "implementation":{"mode":"prompt","skill":"x:y","prompt":"Do {fix_plan}"}},
             "chatPrompts":{"review":"Be terse."}}
            """#
            let settings = try decodeClaude(json)
            try expectEqual(settings.review.minSeverity, .low)
            try expectEqual(settings.review.maxFindings, nil)
            try expectEqual(settings.review.ignorePaths, ["dist/**"])
            try expect(!settings.review.isEnabled(.style))
            try expect(settings.review.isEnabled(.docs))
            try expectEqual(settings.review.tone, .direct)
            try expectEqual(settings.review.stage1.mode, .skill)
            try expectEqual(settings.review.stage1.prompt, "P {diff_path}")
            try expectEqual(settings.reviewSkill, ClaudeSettings.defaultReviewSkill)
            try expectEqual(settings.review.filter.enabled, true)
            try expectEqual(settings.respond.runTestsBeforePush, true)
            try expectEqual(settings.respond.commitMode, .perComment)
            try expectEqual(settings.respond.commitMessageTemplate, "Fix {n}")
            try expectEqual(settings.respond.allowNewDependencies, true)
            try expectEqual(settings.respond.implementation.mode, .prompt)
            try expectEqual(settings.chatPrompts.review, "Be terse.")
        },
        TestCase("claude options: los skills que se cargan respetan el modo de cada etapa") {
            var settings = ClaudeSettings()
            settings.review.stage1.mode = .prompt
            settings.review.stage1.prompt = "Review {diff_path}."
            try expectEqual(settings.reviewSkills, ["superpowers:receiving-code-review"])
            settings.review.stage1.prompt = "Use {skill} on {diff_path}."
            try expectEqual(settings.reviewSkills, ["pr-review-toolkit:review-pr", "superpowers:receiving-code-review"])
            settings.respond.implementation.skill = "superpowers:test-driven-development"
            try expectEqual(settings.respondSkills, ["superpowers:receiving-code-review", "superpowers:test-driven-development"])
            settings.respond.implementation.skill = "bad skill"
            try expectEqual(settings.effectiveImplementationSkill, nil)
            try expectEqual(settings.respondSkills, ["superpowers:receiving-code-review"])
        },
        TestCase("claude options: patrones normalizados y rutas ignoradas por repo") {
            try expectEqual(ReviewOptions.normalizePatterns([" dist/** ", "", "dist/**", "*.lock\n"]), ["dist/**", "*.lock"])
            var config = AppConfig()
            config.accounts = [AccountConfig(login: "me", repos: [RepoConfig(owner: "o", name: "r")])]
            config.setIgnorePaths(["generated/**", " generated/** ", ""], repoID: "o/r", login: "me")
            try expectEqual(config.accounts[0].repos[0].ignorePaths, ["generated/**"])
            let decoded = try JSONCoding.decoder.decode(AppConfig.self, from: JSONCoding.encoder.encode(config))
            try expectEqual(decoded.accounts[0].repos[0].ignorePaths, ["generated/**"])
            let old = try JSONCoding.decoder.decode(RepoConfig.self, from: Data(#"{"owner":"o","name":"r"}"#.utf8))
            try expectEqual(old.ignorePaths, [])
        },
    ]
}
