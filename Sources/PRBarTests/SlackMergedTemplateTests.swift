import Foundation
import PRBarCore

enum SlackMergedTemplateTests {
    static let cases: [TestCase] = [
        TestCase("slack merged: por defecto encendido con «Merged :white_check_mark:»") {
            let settings = SlackSettings()
            try expect(settings.postMerged)
            try expectEqual(settings.mergedTemplate, "Merged :white_check_mark:")
            try expectEqual(SlackSettings.defaultMergedTemplate, "Merged :white_check_mark:")
            var blank = settings
            blank.mergedTemplate = "  "
            try expectEqual(blank.effectiveMergedTemplate, "Merged :white_check_mark:")
            try expect(settings.isDefault(\.mergedTemplate))
        },
        TestCase("slack merged: una config vieja sin las claves nuevas") {
            let settings = try JSONCoding.decoder.decode(SlackSettings.self, from: Data(#"{"enabled":true,"postUpdated":false}"#.utf8))
            try expect(settings.postMerged)
            try expectEqual(settings.mergedTemplate, SlackSettings.defaultMergedTemplate)
            try expect(!settings.postUpdated)
        },
        TestCase("slack merged: {method} junto con las demás variables") {
            let text = SlackTemplate.render("Merged {repo}#{number} ({method}) {title}", pr: makePR(number: 42), method: "squash")
            try expectEqual(text, "Merged r#42 (squash) PR 42")
            try expectEqual(SlackTemplate.render("x {method}", pr: makePR()), "x {method}")
        },
        TestCase("slack merged: {method} solo existe en la plantilla de Merged") {
            try expect(SlackTemplateKind.merged.variables.contains(.method))
            try expect(!SlackTemplateKind.update.variables.contains(.method))
            try expectEqual(SlackTemplateVariable.method.token, "{method}")
            try expectEqual(SlackTemplatePreview.text("x {method}", kind: .merged), "x squash")
            try expectEqual(SlackTemplatePreview.text("x {method}", kind: .update), "x {method}")
            try expectEqual(SlackTemplatePreview.text("", kind: .merged), "Merged :white_check_mark:")
        },
        TestCase("slack merged: el interruptor no toca las reacciones a reviews") {
            var config = AppConfig()
            config.setSlackToggle(.postMerged, false, now: t0)
            try expect(!config.slack.postMerged)
            try expectEqual(config.slack.reviewReactionsEnabledAt, nil)
            try expectEqual(SlackToggle.postMerged.keyPath, \SlackSettings.postMerged)
        },
    ]
}
