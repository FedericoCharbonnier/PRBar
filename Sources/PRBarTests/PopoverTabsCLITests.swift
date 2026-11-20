import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

/// Lo que imprimen `prbar prs`, `prbar status` y `prbar app popover` con las pestañas del popover (spec H.2).
private func rendered(_ arguments: [String], _ result: some Encodable) throws -> String {
    guard let command = try PRBarCommand.parseAsRoot(arguments) as? any RemoteCommand else {
        throw TestFailure(description: "\(arguments) no es un comando remoto")
    }
    var out = ""
    let output = Output(terminal: .plain, json: false, out: { out += $0 }, err: { _ in })
    try command.render(try JSONValue(encoding: result), output)
    return out
}

private func classified(_ category: PRCategory, author: String, number: Int) -> ClassifiedPR {
    ClassifiedPR(pr: makePR(number: number, author: author), category: category, account: "me")
}

enum PopoverTabsCLITests {
    static let cases: [TestCase] = [
        TestCase("cli pestañas: prbar prs muestra la sección del popover") {
            let prs = [
                PRInfo(item: classified(.other, author: "me", number: 6), review: nil, respond: nil),
                PRInfo(item: classified(.other, author: "ana", number: 5), review: nil, respond: nil),
                PRInfo(item: classified(.readyToMerge, author: "me", number: 4), review: nil, respond: nil),
            ]
            let text = try rendered(["prs"], prs)
            let lines = text.split(separator: "\n").map(String.init)
            try expect(lines[0].contains("Section"), text)
            try expect(lines[1].contains("o/r#6") && lines[1].contains("Waiting for Review"), text)
            try expect(lines[2].contains("o/r#5") && lines[2].contains("Other"), text)
            try expect(lines[3].contains("o/r#4") && lines[3].contains("Ready to Merge"), text)
        },
        TestCase("cli pestañas: prbar prs con una app vieja (sin sección) muestra la categoría") {
            var old = PRInfo(item: classified(.other, author: "me", number: 6), review: nil, respond: nil)
            old.section = nil
            old.tab = nil
            let text = try rendered(["prs"], [old])
            try expect(text.contains("other") && !text.contains("Waiting"), text)
        },
        TestCase("cli pestañas: prbar status muestra los totales por pestaña y separa Other de Waiting for Review") {
            let status = StatusInfo(
                appVersion: "1.0.0", badgeCount: 4,
                counts: ["toReview": 1, "updatedSinceMyReview": 1, "myFeedback": 1, "readyToMerge": 1, "other": 3],
                tabCounts: ["to-review": 2, "mine": 2],
                sectionCounts: ["toReview": 1, "updatedSinceMyReview": 1, "otherToReview": 2, "myFeedback": 1,
                                "readyToMerge": 1, "waitingForReview": 1])
            let lines = try rendered(["status"], status).split(separator: "\n").map { $0.replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression) }
            try expectEqual(lines[1], "To Review 2 · My PRs 2")
            try expectEqual(Array(lines[2...8]), [
                "Section PRs", "To Review 1", "Updated Since My Review 1", "Other 2", "My PRs with Feedback 1",
                "Ready to Merge 1", "Waiting for Review 1",
            ])
        },
        TestCase("cli pestañas: prbar status de una app sin secciones muestra las categorías") {
            let status = StatusInfo(appVersion: "1.0.0", counts: ["other": 3])
            let text = try rendered(["status"], status)
            try expect(!text.contains("To Review 0 · My PRs 0"), text)
            try expect(text.contains("Other") && !text.contains("Waiting"), text)
        },
        TestCase("cli pestañas: prbar app popover dice si lo mostró o qué hacer") {
            try expectEqual(try rendered(["app", "popover"], PopoverInfo(tab: .mine, shown: true)), "Showing My PRs.\n")
            try expectEqual(try rendered(["app", "popover", "--tab", "to-review"], PopoverInfo(tab: .toReview, shown: false)),
                            "Selected To Review. Click PRBar in the menu bar to see it.\n")
        },
    ]
}
