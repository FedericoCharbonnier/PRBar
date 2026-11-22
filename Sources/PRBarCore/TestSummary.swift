import Foundation

/// "142 passed" / "140 passed, 2 failed" from the tail of a test run's output (the iPhone's Respond progress, spec R.7).
/// Recognizes the usual runners (Jest, Vitest, pytest, Mocha, XCTest, Swift Testing, `cargo test`); nil when the output
/// doesn't say.
public enum TestSummary {
    private static let passed = try! NSRegularExpression(pattern: "\\b(\\d+) (?:tests? )?(?:passed|passing)\\b",
                                                         options: [.caseInsensitive])
    private static let failed = try! NSRegularExpression(pattern: "\\b(\\d+) (?:tests? )?(?:failed|failing)\\b",
                                                         options: [.caseInsensitive])
    private static let xctest = try! NSRegularExpression(pattern: "Executed (\\d+) tests?, with (\\d+) failures?")
    private static let cargo = try! NSRegularExpression(pattern: "test result: \\w+\\. (\\d+) passed; (\\d+) failed")

    public static func extract(from output: String) -> String? {
        // The last count wins: runners print per-suite counts before the total.
        if let (pass, fail) = pair(cargo, output) ?? pair(xctest, output).map({ ($0.0 - $0.1, $0.1) }) {
            return format(passed: pass, failed: fail)
        }
        let pass = number(passed, output)
        let fail = number(failed, output)
        guard pass != nil || fail != nil else { return nil }
        return format(passed: pass ?? 0, failed: fail ?? 0)
    }

    private static func format(passed: Int, failed: Int) -> String {
        failed > 0 ? "\(passed) passed, \(failed) failed" : "\(passed) passed"
    }

    private static func number(_ regex: NSRegularExpression, _ line: String) -> Int? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.matches(in: line, range: range).last,
              let group = Range(match.range(at: 1), in: line) else { return nil }
        return Int(line[group])
    }

    private static func pair(_ regex: NSRegularExpression, _ line: String) -> (Int, Int)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.matches(in: line, range: range).last,
              let first = Range(match.range(at: 1), in: line), let second = Range(match.range(at: 2), in: line),
              let a = Int(line[first]), let b = Int(line[second]) else { return nil }
        return (a, b)
    }
}
