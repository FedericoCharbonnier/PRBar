import Foundation
import PRBarCore

enum ShellQuoteTests {
    /// Valores que vienen de PRs ajenos (ramas, rutas, prompts) y que no pueden cambiar ni ejecutar nada.
    static let hostile: [String] = [
        "", " ", "plain", "it's", "'", "''", "\\", "\\'", "'\\''", "$HOME", "${HOME}", "$(touch PWNED)", "`touch PWNED`",
        "; touch PWNED", "&& touch PWNED", "| touch PWNED", "> PWNED", "< /etc/passwd", "*", "?", "[a-z]", "~", "~root",
        "!!", "!$", "#comment", "line1\nline2", "tab\there", "\r\n", "-n", "--", "-e", "%s%n", "é", "日本語", "🙂",
        "a'b\"c\\d$e`f!g*h;i|j&k#l m\tn~o", "'; touch PWNED; '", "\"; touch PWNED; \"", "$'\\x41'", "\\$(touch PWNED)",
        "feature/$(touch PWNED)", "refs/heads/a;b", "x'$(touch PWNED)'y", String(repeating: "x'y", count: 20_000),
        // Una comilla seguida de una marca combinante es un solo grafema para `String`, pero su primer byte cierra la comilla.
        "x'\u{0301}; touch PWNED; echo '\u{0301}", "'\u{200D}; touch PWNED; '\u{200D}", "'\u{FE0F}; touch PWNED; '\u{FE0F}",
        "'\u{20E3}; touch PWNED; '\u{20E3}", "'\u{0301}\u{0302}$(touch PWNED)'\u{0301}", "\u{0301}'", "é'\u{0301}",
        "a\r\n'; touch PWNED; '", "\u{1F1E6}'\u{1F1E8}; touch PWNED; '",
    ]

    /// Cadenas pseudoaleatorias (semilla fija) sobre un alfabeto de caracteres especiales del shell.
    static func randomStrings(count: Int, seed: UInt64) -> [String] {
        let alphabet = Array("'\"\\$`!*?;&|<>()[]{}#~ \t\n\r%-=,.:/@^aZ09é🙂".unicodeScalars)
            + ["\u{0301}", "\u{200D}", "\u{FE0F}", "\u{20E3}", "\u{1F1E6}"].map { $0.unicodeScalars.first! }
        var state = seed
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: state >> 33)
        }
        return (0..<count).map { _ in
            var scalars = String.UnicodeScalarView()
            for _ in 0..<(next() % 40) { scalars.append(alphabet[next() % alphabet.count]) }
            return String(scalars)
        }
    }

    /// `printf '%s\0' <cada valor con comillas>` en `shell`, dentro de `directory`; devuelve lo impreso partido por NUL.
    /// `twoLayers`: como lo manda `SSHHost` (`/bin/sh -c '<script>'` adentro del shell de login).
    static func roundTrip(_ values: [String], shell: String, in directory: URL, twoLayers: Bool = false) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        let script = "printf '%s\\0' " + (try ShellQuote.command(values))
        process.arguments = ["-c", twoLayers ? "/bin/sh -c " + (try ShellQuote.posix(script)) : script]
        process.currentDirectoryURL = directory
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static let cases: [TestCase] = [
        TestCase("shell quote: forma") {
            try expectEqual(try ShellQuote.posix("a b"), "'a b'")
            try expectEqual(try ShellQuote.posix("it's"), #"'it'\''s'"#)
            try expectEqual(try ShellQuote.posix(""), "''")
            try expectEqual(try ShellQuote.command(["git", "-C", "/w/x y"]), "'git' '-C' '/w/x y'")
            let nul = try await expectThrows { _ = try ShellQuote.posix("a\u{0}b") }
            try expectEqual(nul as? ShellQuote.Failure, .nulByte)
            try expect(ShellQuote.isEnvironmentName("GIT_TERMINAL_PROMPT") && ShellQuote.isEnvironmentName("_X1"))
            try expect(!ShellQuote.isEnvironmentName("1X") && !ShellQuote.isEnvironmentName("A-B") && !ShellQuote.isEnvironmentName("A=B")
                       && !ShellQuote.isEnvironmentName(""))
        },
        TestCase("shell quote: sh, bash y zsh reciben cada valor hostil intacto y no ejecutan nada") {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let values = hostile + randomStrings(count: 400, seed: 42)
            for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
                let back = try roundTrip(values, shell: shell, in: directory)
                let pwned = FileManager.default.fileExists(atPath: directory.appendingPathComponent("PWNED").path)
                try expect(!pwned, "\(shell) ejecutó algo")
                try expectEqual(back.count, values.count)
                for (index, value) in values.enumerated() where back[index] != value {
                    throw TestFailure(description: "\(shell) cambió el valor #\(index): \(value.prefix(80).debugDescription) → \(back[index].prefix(80).debugDescription)")
                }
            }
        },
        TestCase("shell quote: dos capas (sh -c adentro de sh, bash y zsh) reciben cada valor hostil intacto") {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            // Sin el valor enorme: dos capas lo cuadruplican y pasan el límite de un argumento.
            let values = hostile.filter { $0.utf8.count < 1_000 } + randomStrings(count: 300, seed: 7)
            for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
                let back = try roundTrip(values, shell: shell, in: directory, twoLayers: true)
                let pwned = FileManager.default.fileExists(atPath: directory.appendingPathComponent("PWNED").path)
                try expect(!pwned, "\(shell) ejecutó algo")
                try expectEqual(back.count, values.count)
                for (index, value) in values.enumerated() where back[index] != value {
                    throw TestFailure(description: "\(shell) cambió el valor #\(index): \(value.prefix(80).debugDescription) → \(back[index].prefix(80).debugDescription)")
                }
            }
        },
        TestCase("shell quote: una comilla con una marca combinante se escapa byte a byte") {
            try expectEqual(try ShellQuote.posix("a'\u{0301}b"), "'a'\\''\u{0301}b'")
            try expectEqual(try ShellQuote.posix("'\u{200D}"), "''\\''\u{200D}'")
        },
    ]
}
