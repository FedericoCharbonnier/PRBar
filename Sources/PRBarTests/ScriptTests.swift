import Foundation
import PRBarCore

enum ScriptTests {
    static func script(_ name: String) -> String { repoRoot.appendingPathComponent("Scripts/\(name)").path }

    static func bash(_ arguments: [String]) async throws -> ProcessResult {
        try await SystemProcessRunner().run("/bin/bash", arguments, environment: nil, currentDirectory: repoRoot, timeout: 30)
    }

    static let cases: [TestCase] = [
        TestCase("scripts: bundle.sh no tiene errores de sintaxis") {
            let result = try await bash(["-n", script("bundle.sh")])
            try expectEqual(result.status, 0)
        },
        TestCase("scripts: bundle.sh rechaza argumentos inválidos sin compilar") {
            for arguments in [["--bogus"], ["--output"], ["--output", ""], ["--install", "--output", "/tmp/x"]] {
                let result = try await bash([script("bundle.sh")] + arguments)
                try expectEqual(result.status, 2)
                try expect(result.stderr.contains("Usage: Scripts/bundle.sh"), "\(arguments): \(result.stderr)")
            }
        },
    ]
}
