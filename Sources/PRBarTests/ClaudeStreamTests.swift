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
    ]
}
