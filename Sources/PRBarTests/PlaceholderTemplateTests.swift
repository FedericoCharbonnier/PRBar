import Foundation
import PRBarCore

enum PlaceholderTemplateTests {
    static let cases: [TestCase] = [
        TestCase("placeholder template: reemplaza en una pasada y deja las desconocidas") {
            let text = PlaceholderTemplate.render("Fix {comment} in {pr} ({unknown}) {", values: ["comment": "{pr}", "pr": "#7"])
            try expectEqual(text, "Fix {pr} in #7 ({unknown}) {")
        },
        TestCase("placeholder template: names lista las variables una vez, sin JSON ni llaves sueltas") {
            let names = PlaceholderTemplate.names(in: #"Use {skill} on {diff_path}, then {skill}. JSON: {"a": 1} {x-y} {} {n2}"#)
            try expectEqual(names, ["skill", "diff_path", "n2"])
        },
    ]
}
