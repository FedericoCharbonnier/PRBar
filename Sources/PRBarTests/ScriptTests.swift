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
        TestCase("scripts: release.sh no tiene errores de sintaxis") {
            let result = try await bash(["-n", script("release.sh")])
            try expectEqual(result.status, 0)
        },
        TestCase("scripts: release.sh sin versión o con argumentos de más → uso (2)") {
            for arguments in [[String](), ["--dry-run"], ["--dry-run", "1.0.0", "1.0.1"], ["--bogus", "1.0.0"]] {
                let result = try await bash([script("release.sh")] + arguments)
                try expectEqual(result.status, 2)
                try expect(result.stderr.contains("Usage: Scripts/release.sh"), "\(arguments): \(result.stderr)")
            }
        },
        TestCase("scripts: release.sh rechaza una versión mal escrita (2)") {
            for version in ["banana", "1.2", "1.2.3-beta.1", "01.2.3"] {
                let result = try await bash([script("release.sh"), "--dry-run", version])
                try expectEqual(result.status, 2)
                try expect(result.stderr.contains("X.Y.Z"), "\(version): \(result.stderr)")
            }
        },
        TestCase("scripts: release.sh rechaza una versión que no es mayor que la actual (2)") {
            let result = try await bash([script("release.sh"), "--dry-run", "0.0.1"])
            try expectEqual(result.status, 2)
            try expect(result.stderr.contains("greater than the current version"), result.stderr)
        },
    ]
}
