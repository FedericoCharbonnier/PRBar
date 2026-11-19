import Foundation
import PRBarCore

private let workdir = URL(fileURLWithPath: "/tmp/wt/chat-api-317")
private let context = URL(fileURLWithPath: "/tmp/wt/chat-api-317.context")
private let newID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
private let oldID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

private func chatLine(_ reply: String, actions: [[String: Any]] = []) -> String {
    let line: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "result": "",
                               "structured_output": ["reply": reply, "actions": actions]]
    return String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self)
}

private func input(session: UUID? = nil, edits: Bool = false, state: String? = nil, kind: ChatSession.Kind = .review) -> ChatTurnInput {
    ChatTurnInput(
        kind: kind, claudeSessionID: session, bootstrap: "BOOTSTRAP", message: "Is #2 right?", stateIfChanged: state,
        transcript: [ChatMessage(role: .user, text: "Earlier question"), ChatMessage(role: .assistant, text: "Earlier answer")],
        canEditFiles: edits, workingDirectory: workdir, additionalDirectories: [context], turn: 3)
}

private func engine(_ runner: FakeStreamingRunner, log: URL) -> ChatEngine {
    ChatEngine(claude: ClaudeRunner(runner: runner, claudePath: "/usr/local/bin/claude", pluginDirs: ["/plugins/x"],
                                    environment: ClaudeRunner.environment(toolPaths: ["/usr/local/bin/claude"]),
                                    logURL: log, redacting: ["ghp_secret"]),
               newSessionID: { newID })
}

private func arg(_ flag: String, _ call: FakeStreamingRunner.Call) -> String? {
    call.arguments.firstIndex(of: flag).map { call.arguments[$0 + 1] }
}

enum ChatEngineTests {
    static let cases: [TestCase] = [
        TestCase("chat engine: el primer turno arranca una sesión con herramientas de solo lectura en Review") {
            let runner = FakeStreamingRunner { _, _, _ in
                ([chatLine("Yes, #2 holds.", actions: [["type": "setIncluded", "id": "f2", "included": false]])], ok(""))
            }
            let log = try temporaryDirectory().appendingPathComponent("review.jsonl")
            let output = try await engine(runner, log: log).send(input()) { _ in }
            try expectEqual(output, ChatTurnOutput(reply: "Yes, #2 holds.",
                                                   actions: [ChatAction(type: "setIncluded", id: "f2", included: false)],
                                                   claudeSessionID: newID, rebuiltContext: false))
            let call = runner.calls[0]
            try expectEqual(arg("--session-id", call), newID.uuidString.lowercased())
            try expectEqual(arg("--tools", call), "Read,Grep,Glob,Skill,Agent")
            try expectEqual(arg("--allowedTools", call), "Read(./**),Skill,Agent")
            try expectEqual(arg("--disallowedTools", call), "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,mcp__*")
            try expectEqual(arg("--json-schema", call), ChatSchemas.turn)
            try expectEqual(arg("--setting-sources", call), "")
            try expectEqual(arg("--add-dir", call), context.path)
            try expectEqual(call.currentDirectory, workdir)
            try expectEqual(call.timeout, ChatEngine.timeout)
            try expectEqual(arg("-p", call), "BOOTSTRAP\n\n" + ChatPrompts.message("Is #2 right?"))
            try expect(try String(contentsOf: log, encoding: .utf8).contains("=== chat 3 ==="))
        },
        TestCase("chat engine: Respond con edición suma Edit y Write acotados al cwd, nunca Bash") {
            let runner = FakeStreamingRunner { _, _, _ in ([chatLine("Done.")], ok("")) }
            _ = try await engine(runner, log: try temporaryDirectory().appendingPathComponent("r.log"))
                .send(input(edits: true, kind: .respond)) { _ in }
            let call = runner.calls[0]
            try expectEqual(arg("--tools", call), "Read,Grep,Glob,Edit,Write,Skill,Agent")
            try expectEqual(arg("--allowedTools", call), "Read(./**),Edit(./**),Skill,Agent")
            try expectEqual(arg("--disallowedTools", call), "Bash,NotebookEdit,WebFetch,WebSearch,mcp__*")
        },
        TestCase("chat engine: los turnos siguientes usan --resume con el mensaje y el estado si cambió") {
            let runner = FakeStreamingRunner { _, _, _ in ([chatLine("Sure.")], ok("")) }
            let output = try await engine(runner, log: try temporaryDirectory().appendingPathComponent("r.log"))
                .send(input(session: oldID, state: "{\"x\":1}")) { _ in }
            try expectEqual(output.claudeSessionID, oldID)
            try expectEqual(output.rebuiltContext, false)
            let call = runner.calls[0]
            try expectEqual(arg("--resume", call), oldID.uuidString.lowercased())
            try expect(!call.arguments.contains("--session-id"))
            try expectEqual(arg("-p", call), ChatPrompts.followUp(message: "Is #2 right?", state: "{\"x\":1}"))
        },
        TestCase("chat engine: si --resume falla, relanza con sesión nueva, arranque y transcript") {
            let runner = FakeStreamingRunner { _, arguments, _ in
                if arguments.contains("--resume") {
                    return ([], fail("No conversation found with session ID: aaaaaaaa"))
                }
                return ([chatLine("Rebuilt answer.")], ok(""))
            }
            let log = try temporaryDirectory().appendingPathComponent("r.log")
            let output = try await engine(runner, log: log).send(input(session: oldID)) { _ in }
            try expectEqual(output.reply, "Rebuilt answer.")
            try expectEqual(output.claudeSessionID, newID)
            try expectEqual(output.rebuiltContext, true)
            try expectEqual(runner.calls.count, 2)
            let retry = runner.calls[1]
            try expectEqual(arg("--session-id", retry), newID.uuidString.lowercased())
            try expectEqual(arg("-p", retry), ChatPrompts.rebuilt(bootstrap: "BOOTSTRAP", transcript: input().transcript)
                + "\n\n" + ChatPrompts.message("Is #2 right?"))
            try expect(try String(contentsOf: log, encoding: .utf8).contains("rebuilding"))
        },
        TestCase("chat engine: JSON inválido no activa el respaldo; reintenta dentro de la misma sesión") {
            let runner = FakeStreamingRunner { _, _, _ in
                ([#"{"type":"result","subtype":"success","is_error":false,"result":"no json"}"#], ok(""))
            }
            let error = try await expectThrows {
                _ = try await engine(runner, log: try temporaryDirectory().appendingPathComponent("r.log"))
                    .send(input(session: oldID)) { _ in }
            }
            guard case .invalidOutput? = error as? ClaudeError else { throw TestFailure(description: "\(error)") }
            try expectEqual(runner.calls.count, 2)
            try expect(runner.calls.allSatisfy { arg("--resume", $0) == oldID.uuidString.lowercased() })
        },
    ]
}
