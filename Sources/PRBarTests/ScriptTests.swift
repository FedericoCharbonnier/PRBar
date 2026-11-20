import Foundation
import PRBarCLIKit
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
        TestCase("scripts: bundle.sh copia prbar a Helpers y lo enlaza con --install") {
            let text = try String(contentsOfFile: script("bundle.sh"), encoding: .utf8)
            try expect(text.contains("--product PRBarCLI"))
            try expect(text.contains("Contents/Helpers/prbar"))
            try expect(text.contains("PRBAR_BIN_DIR"))
        },
        TestCase("scripts: link-cli.sh crea el link y reemplaza uno viejo a PRBar") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let target = dir.appendingPathComponent("Applications/PRBar.app/Contents/Helpers/prbar").path
            let bin = dir.appendingPathComponent("bin").path
            let created = try await bash([script("link-cli.sh"), target, bin])
            try expectEqual(created.status, 0)
            try expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: bin + "/prbar"), target)
            // Un link a otro PRBar.app (p. ej. build/) se reemplaza.
            try FileManager.default.removeItem(atPath: bin + "/prbar")
            try FileManager.default.createSymbolicLink(atPath: bin + "/prbar", withDestinationPath: "/old/build/PRBar.app/Contents/Helpers/prbar")
            let replaced = try await bash([script("link-cli.sh"), target, bin])
            try expectEqual(replaced.status, 0)
            try expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: bin + "/prbar"), target)
        },
        TestCase("scripts: link-cli.sh no pisa un prbar ajeno (archivo, link a otra cosa o carpeta)") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let target = dir.appendingPathComponent("Applications/PRBar.app/Contents/Helpers/prbar").path
            let bin = dir.appendingPathComponent("bin").path
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            let link = bin + "/prbar"

            try Data("#!/bin/sh\necho other\n".utf8).write(to: URL(fileURLWithPath: link))
            let file = try await bash([script("link-cli.sh"), target, bin])
            try expectEqual(file.status, 0)
            try expect(file.stderr.contains("isn’t a link to PRBar"), file.stderr)
            try expectEqual(try String(contentsOfFile: link, encoding: .utf8), "#!/bin/sh\necho other\n")

            try FileManager.default.removeItem(atPath: link)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/usr/local/bin/other-prbar")
            let foreign = try await bash([script("link-cli.sh"), target, bin])
            try expectEqual(foreign.status, 0)
            try expect(foreign.stderr.contains("isn’t a link to PRBar"), foreign.stderr)
            try expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "/usr/local/bin/other-prbar")

            try FileManager.default.removeItem(atPath: link)
            try FileManager.default.createDirectory(atPath: link, withIntermediateDirectories: true)
            let folder = try await bash([script("link-cli.sh"), target, bin])
            try expectEqual(folder.status, 0)
            try expect(folder.stderr.contains("isn’t a link to PRBar"), folder.stderr)
            try expect(!FileManager.default.fileExists(atPath: link + "/prbar"), "creó el link adentro de la carpeta")
        },
        TestCase("scripts: bundle.sh enlaza la CLI con link-cli.sh, nunca con ln -sf") {
            let text = try String(contentsOfFile: script("bundle.sh"), encoding: .utf8)
            try expect(text.contains("Scripts/link-cli.sh"), "bundle.sh no usa link-cli.sh")
            try expect(!text.contains("ln -sf "), "bundle.sh todavía usa ln -sf")
        },
        TestCase("doctor: el link de prbar tiene que apuntar al helper de un PRBar.app") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let bin = dir.appendingPathComponent("bin").path
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            let environment = ["PRBAR_BIN_DIR": bin, "PATH": "/usr/bin:\(bin)"]
            try expect(!DoctorChecks.link(environment: environment).ok, "sin link")
            try FileManager.default.createSymbolicLink(atPath: bin + "/prbar", withDestinationPath: "/somewhere/else/prbar")
            let foreign = DoctorChecks.link(environment: environment)
            try expect(!foreign.ok && foreign.detail.contains("/somewhere/else/prbar"), foreign.detail)
            try FileManager.default.removeItem(atPath: bin + "/prbar")
            try FileManager.default.createSymbolicLink(atPath: bin + "/prbar", withDestinationPath: "/Users/x/Applications/PRBar.app/Contents/Helpers/prbar")
            try expect(DoctorChecks.link(environment: environment).ok)
            try expect(!DoctorChecks.link(environment: ["PRBAR_BIN_DIR": bin, "PATH": "/usr/bin"]).ok, "fuera del PATH")
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
