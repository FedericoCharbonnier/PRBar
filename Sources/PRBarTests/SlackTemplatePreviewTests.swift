import Foundation
import PRBarCore

enum SlackTemplatePreviewTests {
    static let cases: [TestCase] = [
        TestCase("slack preview: PR de ejemplo acme/web#123, autor de la cuenta o «you»") {
            let pr = SlackTemplatePreview.sample(author: "fede")
            try expectEqual(pr.repo.fullName, "acme/web")
            try expectEqual(pr.number, 123)
            try expectEqual(pr.title, "Fix login redirect")
            try expectEqual(pr.author, "fede")
            try expectEqual(SlackTemplatePreview.sample().author, "you")
            try expectEqual(SlackTemplatePreview.sample(author: "  ").author, "you")
        },
        TestCase("slack preview: las plantillas por defecto se ven como las manda PRBar") {
            try expectEqual(SlackTemplatePreview.text(SlackSettings.defaultNewPRTemplate, kind: .newPR),
                            "https://github.com/acme/web/pull/123")
            try expectEqual(SlackTemplatePreview.text(SlackSettings.defaultUpdateTemplate, kind: .update),
                            "Updated https://github.com/acme/web/pull/123")
            try expectEqual(SlackTemplatePreview.text(SlackSettings.defaultRoundTemplate, kind: .round), "commented x2")
        },
        TestCase("slack preview: plantilla propia con todas las variables") {
            let template = "{author} opened {repo}#{number}: {title} {link}"
            try expectEqual(SlackTemplatePreview.text(template, kind: .newPR, author: "fede"),
                            "fede opened web#123: Fix login redirect https://github.com/acme/web/pull/123")
            try expectEqual(SlackTemplatePreview.text("Round {n} by {author}", kind: .round), "Round 2 by you")
        },
        TestCase("slack preview: {n} solo se reemplaza en la ronda") {
            try expectEqual(SlackTemplatePreview.text("x{n}", kind: .update), "x{n}")
            try expectEqual(SlackTemplatePreview.text("x{n}", kind: .round), "x2")
            try expect(SlackTemplateKind.round.variables.contains(.round))
            try expect(!SlackTemplateKind.newPR.variables.contains(.round))
            try expect(!SlackTemplateKind.update.variables.contains(.round))
            try expectEqual(SlackTemplateVariable.round.token, "{n}")
        },
        TestCase("slack preview: vacía o solo espacios cae en la de por defecto") {
            for kind in SlackTemplateKind.allCases {
                let expected = SlackTemplatePreview.text(kind.defaultTemplate, kind: kind)
                try expectEqual(SlackTemplatePreview.text("", kind: kind), expected)
                try expectEqual(SlackTemplatePreview.text("  \n ", kind: kind), expected)
                try expectEqual(kind.effective(" "), kind.defaultTemplate)
                try expectEqual(kind.effective("hola {link}"), "hola {link}")
            }
        },
        TestCase("slack preview: links de Slack como texto plano y sin escapes") {
            try expectEqual(SlackTemplatePreview.plainText(fromSlack: "<https://x.io/a|PR 7> ok"), "PR 7 ok")
            try expectEqual(SlackTemplatePreview.plainText(fromSlack: "<https://x.io/a>"), "https://x.io/a")
            try expectEqual(SlackTemplatePreview.plainText(fromSlack: "hi <@U123> in <#C1|general>"), "hi @U123 in #general")
            try expectEqual(SlackTemplatePreview.plainText(fromSlack: "a &lt;b&gt; &amp; c"), "a <b> & c")
            try expectEqual(SlackTemplatePreview.plainText(fromSlack: "1 < 2 and {x}"), "1 < 2 and {x}")
            try expectEqual(SlackTemplatePreview.text("<{link}|{title}>", kind: .newPR), "Fix login redirect")
        },
        TestCase("slack preview: isDefault según la plantilla guardada") {
            var settings = SlackSettings()
            for keyPath in [\SlackSettings.newPRTemplate, \.updateTemplate, \.roundTemplate] {
                try expect(settings.isDefault(keyPath))
            }
            settings.newPRTemplate = "New: {link}"
            settings.roundTemplate = ""
            try expect(!settings.isDefault(\.newPRTemplate))
            try expect(settings.isDefault(\.updateTemplate))
            try expect(!settings.isDefault(\.roundTemplate))
            try expect(!settings.isDefault(\.eyesEmoji))
        },
    ]
}
