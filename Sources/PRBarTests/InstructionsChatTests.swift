import Foundation
import PRBarCore

private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
private let ruleID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
private let newID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
private let oldSession = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
private let repos = ["acme/api", "acme/web-app"]

private func existing() -> [Rule] {
    [Rule(id: ruleID, scope: .global, appliesTo: [.review], text: "No console.log comments.", source: .manual, createdAt: t1)]
}

private func line(_ reply: String, _ actions: [[String: Any]] = []) -> String {
    let line: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "result": "",
                               "structured_output": ["reply": reply, "actions": actions]]
    return String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self)
}

private func arg(_ flag: String, _ call: FakeStreamingRunner.Call) -> String? {
    call.arguments.firstIndex(of: flag).map { call.arguments[$0 + 1] }
}

private func engine(_ runner: FakeStreamingRunner, dir: URL) throws -> InstructionsChatEngine {
    InstructionsChatEngine(
        claude: ClaudeRunner(runner: runner, claudePath: "/usr/local/bin/claude", pluginDirs: [],
                             environment: ClaudeRunner.environment(toolPaths: ["/usr/local/bin/claude"]),
                             logURL: dir.appendingPathComponent("chat.log"), redacting: []),
        workingDirectory: dir.appendingPathComponent("cwd"), newSessionID: { newID })
}

private func input(session: UUID? = nil, state: String? = nil) -> InstructionsTurnInput {
    InstructionsTurnInput(claudeSessionID: session, bootstrap: "BOOT", message: "no style comments", stateIfChanged: state,
                          transcript: [ChatMessage(role: .user, text: "Earlier"), ChatMessage(role: .assistant, text: "Done")], turn: 2)
}

enum InstructionsChatTests {
    static let cases: [TestCase] = [
        TestCase("instructions chat: agrega, edita, apaga y borra reglas válidas") {
            let actions = [RuleAction(type: "addRule", scope: "repo", repo: "web-app", appliesTo: ["respond"], text: " Use React Query. "),
                           RuleAction(type: "editRule", id: ruleID.uuidString, text: "No console.log or print comments."),
                           RuleAction(type: "setRuleEnabled", id: ruleID.uuidString, enabled: false)]
            let applied = RuleActions.apply(actions, to: existing(), repos: repos, now: t1.addingTimeInterval(60), newID: { newID })
            try expectEqual(applied.notes, [])
            try expectEqual(applied.changes, [.ruleAdded(id: newID.uuidString), .ruleEdited(id: ruleID.uuidString),
                                              .ruleToggled(id: ruleID.uuidString, enabled: false)])
            let added = applied.state[1]
            try expectEqual(added.scope, .repo("acme/web-app"))
            try expectEqual(added.appliesTo, [.respond])
            try expectEqual(added.text, "Use React Query.")
            try expectEqual(added.source, .settingsChat)
            try expectEqual(applied.state[0].text, "No console.log or print comments.")
            try expectEqual(applied.state[0].enabled, false)
            try expectEqual(applied.state[0].updatedAt, t1.addingTimeInterval(60))
            let removed = RuleActions.apply([RuleAction(type: "removeRule", id: ruleID.uuidString)], to: existing(), repos: repos)
            try expectEqual(removed.state, [])
            try expectEqual(removed.changes, [.ruleRemoved(id: ruleID.uuidString)])
            try expectEqual(ChatActions.summary(applied.changes + removed.changes) { _ in nil },
                            "Added 1 rule, edited 1 rule, removed 1 rule, turned off 1 rule")
        },
        TestCase("instructions chat: descarta repos no configurados, ids que no existen y textos inválidos") {
            let actions = [RuleAction(type: "addRule", scope: "repo", repo: "evil/repo", text: "x"),
                           RuleAction(type: "addRule", text: String(repeating: "x", count: 1001)),
                           RuleAction(type: "addRule", text: "  "),
                           RuleAction(type: "editRule", id: UUID().uuidString, text: "y"),
                           RuleAction(type: "removeRule", id: "nope"),
                           RuleAction(type: "setRuleEnabled", id: ruleID.uuidString),
                           RuleAction(type: "editRule", id: ruleID.uuidString, appliesTo: ["bogus"]),
                           RuleAction(type: "runCommand")]
            let applied = RuleActions.apply(actions, to: existing(), repos: repos)
            try expectEqual(applied.state, existing())
            try expectEqual(applied.changes, [])
            try expectEqual(applied.notes.count, actions.count)
        },
        TestCase("instructions chat: claude -p sin ninguna herramienta, sin plugins ni carpetas extra, cwd vacío") {
            let dir = try temporaryDirectory()
            let runner = FakeStreamingRunner { _, _, _ in ([line("Added.")], ok("")) }
            let output = try await engine(runner, dir: dir).send(input()) { _ in }
            try expectEqual(output, InstructionsTurnOutput(reply: "Added.", actions: [], claudeSessionID: newID, rebuiltContext: false))
            let call = runner.calls[0]
            try expectEqual(arg("--tools", call), "")
            try expectEqual(arg("--allowedTools", call), "")
            try expectEqual(arg("--disallowedTools", call), "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,mcp__*")
            try expectEqual(arg("--json-schema", call), InstructionsSchemas.turn)
            try expectEqual(arg("--session-id", call), newID.uuidString.lowercased())
            try expectEqual(arg("--setting-sources", call), "")
            try expectEqual(arg("--permission-mode", call), "dontAsk")
            try expect(!call.arguments.contains("--add-dir") && !call.arguments.contains("--plugin-dir"))
            try expectEqual(call.currentDirectory?.path, dir.appendingPathComponent("cwd").path)
            try expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cwd").path))
            // The message's budget (deadline) caps the run.
            try expect((call.timeout ?? 0) <= InstructionsChatEngine.timeout && (call.timeout ?? 0) > InstructionsChatEngine.timeout - 5)
            try expectEqual(arg("-p", call), "BOOT\n\n" + ChatPrompts.message("no style comments"))
        },
        TestCase("instructions chat: --resume con el estado si cambió; si falla, sesión nueva con transcript") {
            let dir = try temporaryDirectory()
            let resumed = FakeStreamingRunner { _, _, _ in ([line("Ok.")], ok("")) }
            _ = try await engine(resumed, dir: dir).send(input(session: oldSession, state: "{\"rules\":[]}")) { _ in }
            try expectEqual(arg("--resume", resumed.calls[0]), oldSession.uuidString.lowercased())
            try expectEqual(arg("-p", resumed.calls[0]), InstructionsPrompts.followUp(message: "no style comments", state: "{\"rules\":[]}"))
            let failing = FakeStreamingRunner { _, arguments, _ in
                arguments.contains("--resume") ? ([], fail("No conversation found with session ID: aaaaaaaa")) : ([line("Rebuilt.")], ok(""))
            }
            let output = try await engine(failing, dir: dir).send(input(session: oldSession)) { _ in }
            try expectEqual(output.rebuiltContext, true)
            try expectEqual(output.claudeSessionID, newID)
            try expectEqual(arg("-p", failing.calls[1]),
                            ChatPrompts.rebuilt(bootstrap: "BOOT", transcript: input().transcript) + "\n\n" + ChatPrompts.message("no style comments"))
        },
        TestCase("instructions chat: el prompt trae repos, reglas con id, acciones y la parte fija") {
            let state = InstructionsPrompts.state(rules: existing(), repos: repos)
            try expect(state.contains(ruleID.uuidString) && state.contains("acme/web-app"), state)
            let prompt = InstructionsPrompts.bootstrap(state: state, repos: repos)
            for needle in ["You have no tools", "addRule", "editRule", "removeRule", "setRuleEnabled", "acme/api, acme/web-app", state] {
                try expect(prompt.contains(needle), "missing \(needle)")
            }
            try expect(prompt.hasSuffix(PromptWrapper.closing), prompt)
            let custom = InstructionsPrompts.bootstrap(state: state, body: "Be brief. Repos: {repos}", repos: repos)
            try expect(custom.contains("Be brief. Repos: acme/api, acme/web-app") && custom.contains("You have no tools"), custom)
        },
        TestCase("instructions chat: un error que no es 'sesión inexistente' no reconstruye") {
            let dir = try temporaryDirectory()
            let failing = FakeStreamingRunner { _, _, _ in ([], fail("Invalid API key")) }
            _ = try? await engine(failing, dir: dir).send(input(session: oldSession)) { _ in }
            try expectEqual(failing.calls.count, 1)
        },
    ]
}
