import Foundation
import PRBarCore

/// `Scripts/release.sh` de verdad, pero en un repo descartable: `work` (clon con `Scripts/release.sh`,
/// `Resources/Info.plist` en 1.0.0 y `PRBarCore.swift`) con un `origin` bare, y `gh`/`swift` falsos en el PATH que
/// anotan cómo los llamaron en `calls.log`. Nunca toca el repo de PRBar ni GitHub.
struct ReleaseSandbox {
    let base: URL
    var origin: URL { base.appendingPathComponent("origin.git", isDirectory: true) }
    var work: URL { base.appendingPathComponent("work", isDirectory: true) }
    var stubs: URL { base.appendingPathComponent("stubs", isDirectory: true) }
    var callsLog: URL { base.appendingPathComponent("calls.log") }
    var plist: URL { work.appendingPathComponent("Resources/Info.plist") }

    static func make() throws -> ReleaseSandbox {
        let sandbox = ReleaseSandbox(base: try temporaryDirectory())
        let fileManager = FileManager.default
        try TempGitRepo.run(sandbox.base, ["init", "-q", "--bare", "-b", "main", sandbox.origin.path])
        try TempGitRepo.run(sandbox.base, ["init", "-q", "-b", "main", sandbox.work.path])
        let work = sandbox.work
        for dir in ["Scripts", "Resources", "Sources/PRBarCore"] {
            try fileManager.createDirectory(at: work.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try fileManager.copyItem(at: repoRoot.appendingPathComponent("Scripts/release.sh"),
                                 to: work.appendingPathComponent("Scripts/release.sh"))
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: sandbox.plist)
        try Data("public enum PRBarCore {\n    public static let version = \"1.0.0\"\n}\n".utf8)
            .write(to: work.appendingPathComponent("Sources/PRBarCore/PRBarCore.swift"))
        try TempGitRepo.run(work, ["add", "-A"])
        try TempGitRepo.run(work, ["commit", "-q", "-m", "Initial"])
        try TempGitRepo.run(work, ["tag", "-a", "v1.0.0", "-m", "PRBar 1.0.0"])
        try Data("x\n".utf8).write(to: work.appendingPathComponent("feature.txt"))
        try TempGitRepo.run(work, ["add", "-A"])
        try TempGitRepo.run(work, ["commit", "-q", "-m", "Add a feature"])
        try TempGitRepo.run(work, ["remote", "add", "origin", sandbox.origin.path])
        try TempGitRepo.run(work, ["push", "-q", "origin", "main", "v1.0.0"])
        try TempGitRepo.run(work, ["fetch", "-q", "origin"])

        try fileManager.createDirectory(at: sandbox.stubs, withIntermediateDirectories: true)
        let log = sandbox.callsLog.path
        try stub(sandbox.stubs, "gh", """
            echo "gh $*" >> '\(log)'
            case "$1 $2" in
                "auth status") exit 0 ;;
                "repo view") echo acme/PRBar ;;
                "release create") exit "${GH_RELEASE_STATUS:-0}" ;;
            esac
            """)
        try stub(sandbox.stubs, "swift", "echo \"swift $*\" >> '\(log)'")
        return sandbox
    }

    private static func stub(_ dir: URL, _ name: String, _ body: String) throws {
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/bash\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    /// Corre `work/Scripts/release.sh` con un entorno armado acá (sin la config de git del usuario).
    func run(_ arguments: [String], extraEnvironment: [String: String] = [:]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [work.appendingPathComponent("Scripts/release.sh").path] + arguments
        process.currentDirectoryURL = work
        process.environment = [
            "PATH": "\(stubs.path):/usr/bin:/bin:/usr/sbin:/sbin", "HOME": base.path, "TMPDIR": base.path + "/",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "EDITOR": "true", "VISUAL": "true",
            "GIT_AUTHOR_NAME": "PRBar Tests", "GIT_AUTHOR_EMAIL": "tests@prbar.invalid",
            "GIT_COMMITTER_NAME": "PRBar Tests", "GIT_COMMITTER_EMAIL": "tests@prbar.invalid",
        ].merging(extraEnvironment) { _, new in new }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
                             stderr: String(decoding: stderr, as: UTF8.self))
    }

    /// Lo que un dry run no puede cambiar: HEAD, tags, refs de origin (local y remoto), FETCH_HEAD, Info.plist y
    /// el árbol de trabajo.
    func state() throws -> [String] {
        let fetchHead = work.appendingPathComponent(".git/FETCH_HEAD")
        return [
            try TempGitRepo.run(work, ["rev-parse", "HEAD"]),
            try TempGitRepo.run(work, ["for-each-ref", "--format=%(refname) %(objectname)"]),
            try TempGitRepo.run(origin, ["for-each-ref", "--format=%(refname) %(objectname)"]),
            try TempGitRepo.run(work, ["status", "--porcelain"]),
            (try? Data(contentsOf: fetchHead)).map { String(decoding: $0, as: UTF8.self) } ?? "no FETCH_HEAD",
            String(decoding: try Data(contentsOf: plist), as: UTF8.self),
        ]
    }

    func calls() -> [String] {
        ((try? String(contentsOf: callsLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

enum ReleaseScriptTests {
    static let cases: [TestCase] = [
        TestCase("release.sh --dry-run (repo descartable): no cambia nada y compara con origin sin fetch") {
            let sandbox = try ReleaseSandbox.make()
            defer { sandbox.remove() }
            // Alguien pushea a origin: el clon local no se entera hasta un fetch.
            let other = sandbox.base.appendingPathComponent("other", isDirectory: true)
            try TempGitRepo.run(sandbox.base, ["clone", "-q", sandbox.origin.path, other.path])
            try TempGitRepo.run(other, ["commit", "-q", "--allow-empty", "-m", "Someone else"])
            try TempGitRepo.run(other, ["push", "-q", "origin", "main"])

            let before = try sandbox.state()
            let result = try sandbox.run(["--dry-run", "1.1.0"])
            try expectEqual(result.status, 0)
            try expectEqual(try sandbox.state(), before)
            // La comparación es con el origin real (ls-remote), no con el origin/main viejo.
            try expect(result.stderr.contains("main isn't the same as origin/main"), result.stderr)
            try expect(result.stdout.contains("Dry run finished"), result.stdout)
            try expect(result.stdout.contains("would run: git push"), result.stdout)
            try expect(result.stdout.contains("would run: gh release create"), result.stdout)
            let calls = sandbox.calls()
            try expect(calls.contains("swift build --product PRBar"), "\(calls)")
            try expect(calls.contains("swift build --product PRBarCLI"), "\(calls)")
            try expect(calls.contains("swift run PRBarTests"), "\(calls)")
            try expect(!calls.contains { $0.hasPrefix("gh release") }, "\(calls)")
        },
        TestCase("release.sh --dry-run (repo descartable): al día con origin no avisa de más") {
            let sandbox = try ReleaseSandbox.make()
            defer { sandbox.remove() }
            let before = try sandbox.state()
            let result = try sandbox.run(["--dry-run", "1.1.0"])
            try expectEqual(result.status, 0)
            try expectEqual(try sandbox.state(), before)
            try expect(!result.stderr.contains("a real release would stop here"), result.stderr)
        },
        TestCase("release.sh (repo descartable): si gh release create falla después del push, dice cómo seguir") {
            let sandbox = try ReleaseSandbox.make()
            defer { sandbox.remove() }
            let result = try sandbox.run(["1.1.0"], extraEnvironment: ["GH_RELEASE_STATUS": "1"])
            try expectEqual(result.status, 1)
            // El push se hizo: el tag y el commit están en origin.
            let tags = try TempGitRepo.run(sandbox.origin, ["tag", "--list"])
            try expect(tags.contains("v1.1.0"), tags)
            try expect(result.stderr.contains("gh release create v1.1.0 --repo acme/PRBar"), result.stderr)
            try expect(result.stderr.contains("--verify-tag"), result.stderr)
            try expect(result.stderr.contains("--notes-file"), result.stderr)
            // Las notas quedan guardadas para ese comando.
            let line = result.stderr.split(separator: "\n").first { $0.contains("--notes-file") } ?? ""
            let notes = line.components(separatedBy: "--notes-file ").last?
                .components(separatedBy: " ").first?.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) ?? ""
            try expect(FileManager.default.fileExists(atPath: notes), "notes: \(notes)\n\(result.stderr)")
            try expect((try? String(contentsOfFile: notes, encoding: .utf8))?.contains("Add a feature") == true)
        },
    ]
}
