import Foundation
import PRBarCore

/// `Scripts/release.sh` de verdad, pero en un repo descartable: `work` (clon con `Scripts/release.sh`, un
/// `Scripts/bundle.sh` falso que arma un PRBar.app mínimo firmado ad-hoc, `Resources/Info.plist` en 1.0.0,
/// `PRBarCore.swift` y un `Package.resolved`) con un `origin` bare, y `gh`/`swift` falsos en el PATH que anotan cómo
/// los llamaron en `calls.log`. Nunca toca el repo de PRBar ni GitHub.
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
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1",
                                    "CFBundleExecutable": "PRBar", "CFBundleIdentifier": "invalid.prbar.release-tests"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: sandbox.plist)
        try Data("{}\n".utf8).write(to: work.appendingPathComponent("Package.resolved"))
        let log = sandbox.callsLog.path
        // Lo que arma el bundle.sh de verdad, en chico: la versión de `prbar --version` sale del Info.plist del bundle.
        // Con `STUB_DIRTY=1` además cambia Package.resolved (como un build que resolvió otras versiones).
        try stub(work.appendingPathComponent("Scripts"), "bundle.sh", """
            set -euo pipefail
            echo "bundle $*" >> '\(log)'
            [[ "$1" == "--output" ]]
            app="$2/PRBar.app"
            mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
            cp Resources/Info.plist "$app/Contents/Info.plist"
            printf '#!/bin/bash\\nexit 0\\n' > "$app/Contents/MacOS/PRBar"
            version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
            printf '#!/bin/bash\\n[[ "$1" == --version ]] && echo %s\\nexit 0\\n' "$version" > "$app/Contents/Helpers/prbar"
            chmod +x "$app/Contents/MacOS/PRBar" "$app/Contents/Helpers/prbar"
            codesign --force --sign - "$app/Contents/Helpers/prbar" 2>/dev/null
            codesign --force --sign - "$app" 2>/dev/null
            if [[ "${STUB_DIRTY:-0}" == 1 ]]; then echo '{"changed": true}' > Package.resolved; fi
            """)
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
        try fileManager.createDirectory(at: sandbox.stubs.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try stub(sandbox.stubs, "gh", """
            echo "gh $*" >> '\(log)'
            case "$1 $2" in
                "auth status") exit 0 ;;
                "repo view") echo acme/PRBar ;;
                "release create") exit "${GH_RELEASE_STATUS:-0}" ;;
            esac
            """)
        try stub(sandbox.stubs, "swift", """
            echo "swift $*" >> '\(log)'
            case " $* " in *" --show-bin-path "*) echo '\(sandbox.stubs.path)/bin' ;; esac
            """)
        // Fuera del bundle, `--version` es la de PRBarCore (la que quedó en el archivo).
        try stub(sandbox.stubs.appendingPathComponent("bin"), "PRBarCLI", """
            [[ "$1" == --version ]] && sed -n 's/.*static let version = "\\(.*\\)".*/\\1/p' Sources/PRBarCore/PRBarCore.swift
            """)
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
            // Arma la app como el actualizador (bundle.sh --output), no un build de debug.
            try expect(calls.contains { $0.hasPrefix("bundle --output ") }, "\(calls)")
            try expect(calls.contains("swift build -c release --force-resolved-versions --show-bin-path"), "\(calls)")
            try expect(!calls.contains("swift build --product PRBar"), "\(calls)")
            try expect(calls.contains("swift run PRBarTests"), "\(calls)")
            try expect(result.stdout.contains("PRBar.app 1.0.0 and prbar 1.0.0 look right."), result.stdout)
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
        TestCase("release.sh (repo descartable): si el build cambia otro archivo (Package.resolved) no publica y revierte") {
            let sandbox = try ReleaseSandbox.make()
            defer { sandbox.remove() }
            let head = try TempGitRepo.run(sandbox.work, ["rev-parse", "HEAD"])
            let result = try sandbox.run(["1.1.0"], extraEnvironment: ["STUB_DIRTY": "1"])
            try expectEqual(result.status, 1)
            try expect(result.stderr.contains("building changed files that wouldn't be released"), result.stderr)
            try expect(result.stderr.contains("Package.resolved"), result.stderr)
            try expect(result.stderr.contains("the version change was reverted"), result.stderr)
            try expectEqual(try TempGitRepo.run(sandbox.work, ["rev-parse", "HEAD"]), head)
            try expect(try TempGitRepo.run(sandbox.work, ["tag", "--list"]).contains("v1.1.0") == false)
            let plist = String(decoding: try Data(contentsOf: sandbox.plist), as: UTF8.self)
            try expect(plist.contains("<string>1.0.0</string>"), plist)
        },
        TestCase("release.sh (repo descartable): publica lo que armó y probó como el actualizador") {
            let sandbox = try ReleaseSandbox.make()
            defer { sandbox.remove() }
            let result = try sandbox.run(["1.1.0"])
            try expectEqual(result.status, 0)
            try expect(result.stdout.contains("PRBar.app 1.1.0 and prbar 1.1.0 look right."), result.stdout)
            let tags = try TempGitRepo.run(sandbox.origin, ["tag", "--list"])
            try expect(tags.contains("v1.1.0"), tags)
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
