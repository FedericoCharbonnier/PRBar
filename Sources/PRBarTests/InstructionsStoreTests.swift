import Foundation
import PRBarCore

private let t1 = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
private func store(_ dir: URL, now: Date = t1) -> InstructionsStore {
    InstructionsStore(fileURL: dir.appendingPathComponent("instructions.json"), now: { now })
}

enum InstructionsStoreTests {
    static let cases: [TestCase] = [
        TestCase("instructions store: sin archivo arranca vacío; agregar, editar, apagar y borrar se guardan") { @MainActor in
            let dir = try temporaryDirectory()
            let instructions = store(dir)
            try expectEqual(instructions.rules, [])
            try expectEqual(instructions.loadError, nil)
            let rule = try instructions.addRule("  No style comments. ", scope: .global, appliesTo: [.review], source: .manual)
            try expectEqual(rule.text, "No style comments.")
            try expectEqual(rule.createdAt, t1)
            let later = store(dir, now: t1.addingTimeInterval(60))
            try expectEqual(later.rules, [rule])
            try later.editRule(rule.id, text: "No style or format comments.", appliesTo: [.review, .respond])
            try later.setRuleEnabled(rule.id, false)
            let edited = store(dir).rules[0]
            try expectEqual(edited.text, "No style or format comments.")
            try expectEqual(edited.appliesTo, [.review, .respond])
            try expectEqual(edited.enabled, false)
            try expectEqual(edited.updatedAt, t1.addingTimeInterval(60))
            try later.removeRule(rule.id)
            try expectEqual(store(dir).rules, [])
        },
        TestCase("instructions store: valida texto, etapas e id") { @MainActor in
            let instructions = store(try temporaryDirectory())
            let empty = try await expectThrows { _ = try instructions.addRule("  ", scope: .global, appliesTo: [.review], source: .manual) }
            try expectEqual(empty as? RuleError, .emptyText)
            let noStage = try await expectThrows { _ = try instructions.addRule("x", scope: .global, appliesTo: [], source: .manual) }
            try expectEqual(noStage as? RuleError, .noStage)
            let missing = try await expectThrows { try instructions.removeRule(UUID()) }
            try expectEqual(missing as? RuleError, .notFound)
            let rule = try instructions.addRule("token ghp_abcdefghijklmnopqrstuvwxyz0123", scope: .global, appliesTo: [.review], source: .manual)
            try expectEqual(rule.text, "token ***")
        },
        TestCase("instructions store: un archivo roto queda en .bak y se arranca vacío con aviso") { @MainActor in
            let dir = try temporaryDirectory()
            let url = dir.appendingPathComponent("instructions.json")
            try Data("{ not json".utf8).write(to: url)
            let instructions = store(dir)
            try expectEqual(instructions.rules, [])
            try expect(instructions.loadError?.contains("instructions.json.bak") == true, instructions.loadError ?? "")
            try expectEqual(try String(contentsOf: url.appendingPathExtension("bak"), encoding: .utf8), "{ not json")
        },
        TestCase("instructions store: una regla rota se descarta y el resto queda") { @MainActor in
            let dir = try temporaryDirectory()
            let json = #"""
            {"rules":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","scope":{"kind":"global"},"text":"ok"},
                      {"id":"not-a-uuid","scope":{"kind":"global"},"text":"broken"},
                      {"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","scope":{"kind":"planet"},"text":"broken too"}],
             "suggestionDecisions":"oops"}
            """#
            try Data(json.utf8).write(to: dir.appendingPathComponent("instructions.json"))
            let instructions = store(dir)
            try expectEqual(instructions.rules.map(\.text), ["ok"])
            try expectEqual(instructions.file.suggestionDecisions, [])
            try expectEqual(instructions.loadError, nil)
        },
        TestCase("instructions store: el chat guarda los últimos 50 mensajes y las decisiones se recuerdan") { @MainActor in
            let dir = try temporaryDirectory()
            let instructions = store(dir)
            var chat = InstructionsChat()
            chat.messages = (1...60).map { ChatMessage(role: .user, text: "m\($0)", createdAt: t1) }
            try instructions.saveChat(chat)
            try instructions.decideSuggestion("repo:acme/api:docs", never: true, until: nil)
            let reloaded = store(dir)
            try expectEqual(reloaded.file.chat.messages.count, 50)
            try expectEqual(reloaded.file.chat.messages.first?.text, "m11")
            try expectEqual(reloaded.file.suggestionDecisions, [SuggestionDecision(key: "repo:acme/api:docs", never: true, snoozedUntil: nil)])
        },
    ]
}
