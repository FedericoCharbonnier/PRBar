import Foundation
import PRBarCore

private let agentLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}"#
private let taskLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hola"},{"type":"tool_use","name":"Task","input":{}}]}}"#
private let readLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#
private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"ok","structured_output":{"summary":"s","findings":[]},"total_cost_usd":0.12}"#

enum ClaudeStreamTests {
    static let cases: [TestCase] = [
        TestCase("claude stream: cuenta subagentes y ignora otras herramientas") {
            var parser = ClaudeStreamParser()
            try expectEqual(parser.consume(agentLine), .agentStarted(total: 1))
            try expectEqual(parser.consume(readLine), nil)
            try expectEqual(parser.consume(taskLine), .agentStarted(total: 2))
        },
        TestCase("claude stream: ignora líneas que no son JSON o eventos de sistema") {
            var parser = ClaudeStreamParser()
            try expectEqual(parser.consume("not json"), nil)
            try expectEqual(parser.consume(#"{"type":"system","subtype":"init"}"#), nil)
            try expectEqual(parser.result, nil)
        },
        TestCase("claude stream: guarda el resultado con structured_output") {
            var parser = ClaudeStreamParser()
            _ = parser.consume(resultLine)
            let result = try parser.decodeResult(ReviewStageOneOutput.self)
            try expectEqual(result.summary, "s")
            try expectEqual(parser.result?.costUSD, 0.12)
        },
        TestCase("claude stream: sin structured_output usa el último bloque json del texto") {
            var parser = ClaudeStreamParser()
            let text = "bla\\n```json\\n{\\\"verdicts\\\":[]}\\n```\\notro\\n```json\\n{\\\"verdicts\\\":[{\\\"id\\\":\\\"f1\\\",\\\"verdict\\\":\\\"keep\\\",\\\"reason\\\":\\\"r\\\"}]}\\n```"
            _ = parser.consume(#"{"type":"result","subtype":"success","is_error":false,"result":"\#(text)"}"#)
            let output = try parser.decodeResult(ReviewStageTwoOutput.self)
            try expectEqual(output.verdicts.count, 1)
        },
        TestCase("claude stream: un resultado de error sin `result` usa `errors` (p. ej. --resume de una sesión que no existe)") {
            var parser = ClaudeStreamParser()
            _ = parser.consumeAll(#"{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"errors":["No conversation found with session ID: 7fa8"]}"#)
            try expectEqual(parser.result?.text, "No conversation found with session ID: 7fa8")
            let error = try await expectThrows { _ = try parser.decodeResult(ChatOutput.self) }
            try expectEqual(error as? ClaudeError, .failed("No conversation found with session ID: 7fa8"))
        },
        TestCase("claude stream: error o sin resultado → ClaudeError") {
            var failed = ClaudeStreamParser()
            _ = failed.consume(#"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Se cortó"}"#)
            let error = try await expectThrows { _ = try failed.decodeResult(ReviewStageTwoOutput.self) }
            try expect(error as? ClaudeError == .failed("Se cortó"))
            let empty = ClaudeStreamParser()
            let missing = try await expectThrows { _ = try empty.decodeResult(ReviewStageTwoOutput.self) }
            try expect(missing as? ClaudeError == .noResult)
        },
        TestCase("claude stream: JSON que no respeta el schema → invalidOutput") {
            var parser = ClaudeStreamParser()
            _ = parser.consume(#"{"type":"result","is_error":false,"result":"x","structured_output":{"nope":1}}"#)
            let error = try await expectThrows { _ = try parser.decodeResult(ReviewStageOneOutput.self) }
            guard case .invalidOutput = error as? ClaudeError else { throw TestFailure(description: "esperaba invalidOutput, fue \(error)") }
        },
        TestCase("claude stream: consumeAll da texto, herramientas y subagentes en orden; oculta StructuredOutput") {
            var parser = ClaudeStreamParser()
            let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"  Let me look.  "},{"type":"tool_use","name":"Read","input":{"file_path":"/wt/src/a.ts"}},{"type":"tool_use","name":"Agent","input":{"description":"check callers"}},{"type":"tool_use","name":"StructuredOutput","input":{"reply":"x"}}]}}"#
            try expectEqual(parser.consumeAll(line), [
                .text("Let me look."), .toolUse(name: "Read", detail: "/wt/src/a.ts"),
                .toolUse(name: "Agent", detail: "check callers"), .agentStarted(total: 1),
            ])
            try expectEqual(parser.consumeAll(#"{"type":"assistant","message":{"content":[{"type":"text","text":"  "}]}}"#), [])
            try expectEqual(parser.consumeAll("not json"), [])
            // `consume` keeps its old meaning: only the subagent count.
            try expectEqual(parser.consume(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"x"}}]}}"#), nil)
        },
        TestCase("claude stream: ChatActivity describe la herramienta con rutas relativas al worktree") {
            let root = URL(fileURLWithPath: "/tmp/wt/chat-api-7")
            try expectEqual(ChatActivity.describe(.toolUse(name: "Read", detail: "/tmp/wt/chat-api-7/src/a.ts"), root: root), "Reading src/a.ts")
            try expectEqual(ChatActivity.describe(.toolUse(name: "Grep", detail: "returnTo"), root: root), "Searching for “returnTo”")
            try expectEqual(ChatActivity.describe(.toolUse(name: "Edit", detail: "/elsewhere/b.ts"), root: root), "Editing /elsewhere/b.ts")
            try expectEqual(ChatActivity.describe(.toolUse(name: "Agent", detail: "x"), root: root), "Running a subagent")
            try expectEqual(ChatActivity.describe(.toolUse(name: "Skill", detail: "superpowers:receiving-code-review"), root: nil),
                            "Using the superpowers:receiving-code-review skill")
            try expectEqual(ChatActivity.describe(.text("hi"), root: root), nil)
        },
        TestCase("claude stream: lee el session_id del evento init; sin init no hay ID") {
            var parser = ClaudeStreamParser()
            try expectEqual(parser.sessionID, nil)
            _ = parser.consumeAll(readLine)
            _ = parser.consumeAll(resultLine)
            try expectEqual(parser.sessionID, nil)
            let initLine = #"{"type":"system","subtype":"init","session_id":"1b4e28ba-2fa1-11d2-883f-0016d3cca427","tools":["Read"]}"#
            try expectEqual(parser.consumeAll(initLine), [])
            try expectEqual(parser.sessionID, "1b4e28ba-2fa1-11d2-883f-0016d3cca427")
            // Otros eventos de sistema (hooks, compactación) traen session_id: no lo pisan.
            _ = parser.consumeAll(#"{"type":"system","subtype":"hook_response","session_id":"otro"}"#)
            try expectEqual(parser.sessionID, "1b4e28ba-2fa1-11d2-883f-0016d3cca427")
        },
    ]
}
