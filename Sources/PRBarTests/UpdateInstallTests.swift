import Foundation
import PRBarCore

/// Un `.app` mínimo: Info.plist, un ejecutable que imprime `PRBar <version>`, `Contents/Helpers/prbar` y
/// `Contents/Resources/marker.txt` para saber cuál es. `signed`: firmado ad-hoc (como `bundle.sh` cuando no puede usar el certificado local).
func makeFakeApp(at app: URL, version: String, identifier: String = "com.federico.prbar", marker: String,
                 helper: Bool = true, signed: Bool = false) throws {
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": identifier, "CFBundleExecutable": "PRBar"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let executable = macOS.appendingPathComponent("PRBar")
    try Data("#!/bin/sh\necho \"PRBar \(version)\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let resources = contents.appendingPathComponent("Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try Data(marker.utf8).write(to: resources.appendingPathComponent("marker.txt"))
    if helper {
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let cli = helpers.appendingPathComponent("prbar")
        try Data("#!/bin/sh\necho \"prbar \(version)\"\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    }
    if signed {
        for path in (helper ? [contents.appendingPathComponent("Helpers/prbar").path] : []) + [app.path] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--force", "--sign", "-", path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
    }
}

func marker(of app: URL) -> String? {
    try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
}

enum UpdateInstallTests {
    static let cases: [TestCase] = verifierCases + replacerCases + installerCases + relaunchCases

    static let verifierCases: [TestCase] = [
        TestCase("update verifier: versión, bundle id y --version correctos") {
            let app = try temporaryDirectory().appendingPathComponent("PRBar.app", isDirectory: true)
            try makeFakeApp(at: app, version: "1.3.0", marker: "new", signed: true)
            try await UpdateVerifier.verify(app: app, expectedVersion: SemanticVersion(1, 3, 0),
                                            bundleIdentifier: "com.federico.prbar", runner: SystemProcessRunner())
        },
        TestCase("update verifier: rechaza un .app sin prbar en Helpers o sin firma válida") {
            let dir = try temporaryDirectory()
            let noHelper = dir.appendingPathComponent("a/PRBar.app", isDirectory: true)
            try makeFakeApp(at: noHelper, version: "1.3.0", marker: "x", helper: false, signed: true)
            let e1 = try await expectThrows {
                try await UpdateVerifier.verify(app: noHelper, expectedVersion: SemanticVersion(1, 3, 0),
                                                bundleIdentifier: "com.federico.prbar", runner: SystemProcessRunner())
            }
            try expectEqual(e1 as? UpdateError, .appMissing(noHelper.appendingPathComponent("Contents/Helpers/prbar").path))

            let unsigned = dir.appendingPathComponent("b/PRBar.app", isDirectory: true)
            try makeFakeApp(at: unsigned, version: "1.3.0", marker: "x")
            let e2 = try await expectThrows {
                try await UpdateVerifier.verify(app: unsigned, expectedVersion: SemanticVersion(1, 3, 0),
                                                bundleIdentifier: "com.federico.prbar", runner: SystemProcessRunner())
            }
            guard case .signatureInvalid? = e2 as? UpdateError else { throw TestFailure(description: "\(e2)") }

            let tampered = dir.appendingPathComponent("c/PRBar.app", isDirectory: true)
            try makeFakeApp(at: tampered, version: "1.3.0", marker: "x", signed: true)
            let handle = try FileHandle(forWritingTo: tampered.appendingPathComponent("Contents/Helpers/prbar"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("echo evil\n".utf8))
            try handle.close()
            let e3 = try await expectThrows {
                try await UpdateVerifier.verify(app: tampered, expectedVersion: SemanticVersion(1, 3, 0),
                                                bundleIdentifier: "com.federico.prbar", runner: SystemProcessRunner())
            }
            guard case .signatureInvalid? = e3 as? UpdateError else { throw TestFailure(description: "\(e3)") }
        },
        TestCase("update verifier: rechaza versión, bundle id, app faltante y --version distinto") {
            let dir = try temporaryDirectory()
            let wrongVersion = dir.appendingPathComponent("a/PRBar.app", isDirectory: true)
            try makeFakeApp(at: wrongVersion, version: "1.2.9", marker: "x")
            let e1 = try await expectThrows {
                try await UpdateVerifier.verify(app: wrongVersion, expectedVersion: SemanticVersion(1, 3, 0),
                                                bundleIdentifier: "com.federico.prbar", runner: SystemProcessRunner())
            }
            try expectEqual(e1 as? UpdateError, .versionMismatch(expected: "1.3.0", found: "1.2.9"))

            let wrongID = dir.appendingPathComponent("b/PRBar.app", isDirectory: true)
            try makeFakeApp(at: wrongID, version: "1.3.0", identifier: "com.evil.app", marker: "x")
            let e2 = try await expectThrows {
                try await UpdateVerifier.verify(app: wrongID, expectedVersion: SemanticVersion(1, 3, 0),
                                                bundleIdentifier: "com.federico.prbar", runner: SystemProcessRunner())
            }
            try expectEqual(e2 as? UpdateError, .bundleIdentifierMismatch(expected: "com.federico.prbar", found: "com.evil.app"))

            let missing = dir.appendingPathComponent("c/PRBar.app", isDirectory: true)
            let e3 = try await expectThrows {
                try await UpdateVerifier.verify(app: missing, expectedVersion: SemanticVersion(1, 3, 0),
                                                bundleIdentifier: "com.federico.prbar", runner: SystemProcessRunner())
            }
            try expectEqual(e3 as? UpdateError, .appMissing(missing.path))

            let liar = dir.appendingPathComponent("d/PRBar.app", isDirectory: true)
            try makeFakeApp(at: liar, version: "1.3.0", marker: "x")
            let runner = FakeProcessRunner { _, _ in ProcessResult(status: 0, stdout: "PRBar 1.2.0\n", stderr: "") }
            let e4 = try await expectThrows {
                try await UpdateVerifier.verify(app: liar, expectedVersion: SemanticVersion(1, 3, 0),
                                                bundleIdentifier: "com.federico.prbar", runner: runner)
            }
            guard case .launchCheckFailed? = e4 as? UpdateError else { throw TestFailure(description: "\(e4)") }
            try expectEqual(runner.calls.last?.arguments, ["--version"])
        },
    ]

    static let replacerCases: [TestCase] = [
        TestCase("app replacer: mueve el actual a .previous y el nuevo a su lugar") {
            let dir = try temporaryDirectory()
            let installed = dir.appendingPathComponent("Applications/PRBar.app", isDirectory: true)
            try makeFakeApp(at: installed, version: "1.2.0", marker: "old")
            let staged = AppReplacer.candidateURL(for: installed)
            try makeFakeApp(at: staged, version: "1.3.0", marker: "new")
            // Un .previous de una actualización anterior se reemplaza.
            try makeFakeApp(at: AppReplacer.previousURL(for: installed), version: "1.1.0", marker: "older")
            try AppReplacer().replace(installed: installed, with: staged)
            try expectEqual(marker(of: installed), "new")
            try expectEqual(marker(of: AppReplacer.previousURL(for: installed)), "old")
            try expectEqual(AppReplacer.previousURL(for: installed).lastPathComponent, "PRBar.app.previous")
            try expect(!FileManager.default.fileExists(atPath: staged.path))
        },
        TestCase("app replacer: si falla mover el nuevo, vuelve a poner el anterior") {
            let dir = try temporaryDirectory()
            let installed = dir.appendingPathComponent("Applications/PRBar.app", isDirectory: true)
            try makeFakeApp(at: installed, version: "1.2.0", marker: "old")
            let staged = AppReplacer.candidateURL(for: installed)
            try makeFakeApp(at: staged, version: "1.3.0", marker: "new")
            let moves = Box(0)
            let replacer = AppReplacer(move: { from, to in
                moves.value += 1
                if moves.value == 2 { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: from, to: to)
            })
            let error = try await expectThrows { try replacer.replace(installed: installed, with: staged) }
            guard case .replaceFailed(let message)? = error as? UpdateError else { throw TestFailure(description: "\(error)") }
            try expect(message.contains("wasn't changed"), message)
            try expectEqual(marker(of: installed), "old")
            try expect(!FileManager.default.fileExists(atPath: AppReplacer.previousURL(for: installed).path))
            try expectEqual(moves.value, 3)
        },
        TestCase("app replacer: el candidato va oculto al lado del instalado, con nombre único") {
            let installed = URL(fileURLWithPath: "/Users/me/Applications/PRBar.app", isDirectory: true)
            let a = AppReplacer.candidateURL(for: installed)
            let b = AppReplacer.candidateURL(for: installed)
            try expectEqual(a.deletingLastPathComponent().path, "/Users/me/Applications")
            try expect(a.lastPathComponent.hasPrefix(".PRBar.app.new-"), a.lastPathComponent)
            try expect(a != b)
        },
        TestCase("app replacer: un nuevo que no está en la misma carpeta se rechaza sin tocar nada") {
            let dir = try temporaryDirectory()
            let installed = dir.appendingPathComponent("Applications/PRBar.app", isDirectory: true)
            let staged = dir.appendingPathComponent("staging/PRBar.app", isDirectory: true)
            try makeFakeApp(at: installed, version: "1.2.0", marker: "old")
            try makeFakeApp(at: staged, version: "1.3.0", marker: "new")
            let error = try await expectThrows { try AppReplacer().replace(installed: installed, with: staged) }
            guard case .replaceFailed? = error as? UpdateError else { throw TestFailure(description: "\(error)") }
            try expectEqual(marker(of: installed), "old")
            try expectEqual(marker(of: staged), "new")
        },
        TestCase("app replacer: removePrevious también borra candidatos que quedaron de una instalación cortada") {
            let dir = try temporaryDirectory()
            let installed = dir.appendingPathComponent("PRBar.app", isDirectory: true)
            try makeFakeApp(at: installed, version: "1.3.0", marker: "cur")
            let leftover = AppReplacer.candidateURL(for: installed)
            try makeFakeApp(at: leftover, version: "1.3.0", marker: "x")
            let other = dir.appendingPathComponent(".Other.app.new-1", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            AppReplacer.removePrevious(nextTo: installed)
            try expect(!FileManager.default.fileExists(atPath: leftover.path))
            try expect(FileManager.default.fileExists(atPath: other.path))
            try expectEqual(marker(of: installed), "cur")
        },
        TestCase("app replacer: carpeta sin permiso de escritura → notWritable") {
            let dir = try temporaryDirectory().appendingPathComponent("ro", isDirectory: true)
            let installed = dir.appendingPathComponent("PRBar.app", isDirectory: true)
            try makeFakeApp(at: installed, version: "1.2.0", marker: "old")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
            let error = try await expectThrows { try AppReplacer.checkWritable(installed) }
            try expectEqual(error as? UpdateError, .notWritable(dir.path))
        },
        TestCase("app replacer: removePrevious borra PRBar.app.previous y no falla si no está") {
            let dir = try temporaryDirectory()
            let installed = dir.appendingPathComponent("PRBar.app", isDirectory: true)
            try makeFakeApp(at: AppReplacer.previousURL(for: installed), version: "1.2.0", marker: "old")
            AppReplacer.removePrevious(nextTo: installed)
            try expect(!FileManager.default.fileExists(atPath: AppReplacer.previousURL(for: installed).path))
            AppReplacer.removePrevious(nextTo: installed)
        },
    ]

    static let sha = String(repeating: "a", count: 40)

    /// git falso (sha en rev-parse, merge-base con `mergeBaseStatus`) y `--version` que dice `versionLine`.
    static func fakeRunner(mergeBaseStatus: Int32 = 0, versionLine: String = "PRBar 1.3.0") -> FakeProcessRunner {
        FakeProcessRunner { _, arguments in fakeResult(arguments, mergeBaseStatus: mergeBaseStatus, versionLine: versionLine) }
    }

    static func fakeResult(_ arguments: [String], mergeBaseStatus: Int32 = 0, versionLine: String = "PRBar 1.3.0") -> ProcessResult {
        if arguments.contains("rev-parse") { return ProcessResult(status: 0, stdout: sha + "\n", stderr: "") }
        if arguments.contains("merge-base") { return ProcessResult(status: mergeBaseStatus, stdout: "", stderr: "") }
        if arguments == ["--version"] { return ProcessResult(status: 0, stdout: versionLine + "\n", stderr: "") }
        return ProcessResult(status: 0, stdout: "", stderr: "")
    }

    /// `bundle.sh` falso: arma `<--output>/PRBar.app` con `version` y sale con `status`.
    static func fakeBuilder(version: String = "1.3.0", status: Int32 = 0) -> FakeStreamingRunner {
        FakeStreamingRunner { _, arguments, _ in
            if status == 0 {
                let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
                try makeFakeApp(at: output.appendingPathComponent("PRBar.app", isDirectory: true), version: version, marker: "new")
            }
            return (lines: ["Compiling PRBar", "Bundle listo"],
                    result: ProcessResult(status: status, stdout: "", stderr: status == 0 ? "" : "error: boom\n"))
        }
    }

    static func makeInstaller(base: URL, runner: FakeProcessRunner, builder: FakeStreamingRunner) -> UpdateInstaller {
        UpdateInstaller(
            source: UpdateSource(runner: runner, gitPath: "/usr/bin/git", directory: base.appendingPathComponent("source", isDirectory: true),
                                 remoteURL: "https://github.com/acme/PRBar.git"),
            builder: builder, runner: runner, stagingRoot: base.appendingPathComponent("staging", isDirectory: true),
            bundleIdentifier: "com.federico.prbar"
        )
    }

    static func phases(_ events: [UpdateEvent]) -> [UpdatePhase] {
        events.compactMap { event -> UpdatePhase? in
            if case .phase(let phase) = event { return phase }
            return nil
        }
    }

    static func setUp() throws -> (base: URL, installed: URL) {
        let base = try temporaryDirectory()
        let installed = base.appendingPathComponent("Applications/PRBar.app", isDirectory: true)
        try makeFakeApp(at: installed, version: "1.2.0", marker: "old")
        return (base, installed)
    }

    static let installerCases: [TestCase] = [
        TestCase("update installer: baja, compila, verifica y reemplaza; eventos en orden") {
            let (base, installed) = try setUp()
            let runner = fakeRunner()
            let builder = fakeBuilder()
            let events = Box<[UpdateEvent]>([])
            let replaces = Box(0)
            try await makeInstaller(base: base, runner: runner, builder: builder).install(
                makeRelease("1.3.0"), replacing: installed,
                beforeReplace: { replaces.value += 1 }, onEvent: { events.value.append($0) }
            )
            try expectEqual(marker(of: installed), "new")
            try expectEqual(marker(of: AppReplacer.previousURL(for: installed)), "old")
            try expectEqual(replaces.value, 1)
            try expectEqual(phases(events.value), [.fetching, .building, .verifying, .installing])
            try expect(events.value.contains(.log("Compiling PRBar")))
            try expectEqual(builder.calls.count, 1)
            try expectEqual(builder.calls[0].executable, "/bin/bash")
            try expectEqual(Array(builder.calls[0].arguments.prefix(2)),
                            [base.appendingPathComponent("source/Scripts/bundle.sh").path, "--output"])
            try expectEqual(builder.calls[0].currentDirectory?.path, base.appendingPathComponent("source").path)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("staging").path)
            try expectEqual(leftovers, [])
        },
        TestCase("update installer: verifica y reemplaza desde un candidato al lado del instalado") {
            let (base, installed) = try setUp()
            let verifiedPaths = Box<[String]>([])
            let runner = FakeProcessRunner { executable, arguments in
                if arguments == ["--version"] { verifiedPaths.value.append(executable) }
                return fakeResult(arguments)
            }
            try await makeInstaller(base: base, runner: runner, builder: fakeBuilder()).install(
                makeRelease("1.3.0"), replacing: installed, onEvent: { _ in }
            )
            try expectEqual(marker(of: installed), "new")
            try expectEqual(verifiedPaths.value.count, 2)
            let folder = installed.deletingLastPathComponent().path
            for path in verifiedPaths.value {
                try expect(path.hasPrefix(folder + "/.PRBar.app.new-"), path)
            }
            let siblings = try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
            try expectEqual(siblings, ["PRBar.app", "PRBar.app.previous"])
        },
        TestCase("update installer: vuelve a verificar después de beforeReplace") {
            let (base, installed) = try setUp()
            let error = try await expectThrows {
                try await makeInstaller(base: base, runner: fakeRunner(), builder: fakeBuilder()).install(
                    makeRelease("1.3.0"), replacing: installed,
                    beforeReplace: {
                        // Algo cambió el candidato mientras se esperaban los trabajos.
                        let folder = installed.deletingLastPathComponent()
                        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix(".PRBar.app.new-") {
                            try makeFakeApp(at: folder.appendingPathComponent(name), version: "6.6.6", marker: "evil")
                        }
                    },
                    onEvent: { _ in }
                )
            }
            try expectEqual(error as? UpdateError, .versionMismatch(expected: "1.3.0", found: "6.6.6"))
            try expectEqual(marker(of: installed), "old")
            let siblings = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
            try expectEqual(siblings, ["PRBar.app"])
        },
        TestCase("update installer: vacía la carpeta de staging al empezar") {
            let (base, installed) = try setUp()
            let stale = base.appendingPathComponent("staging/old-run/PRBar.app", isDirectory: true)
            try makeFakeApp(at: stale, version: "1.0.0", marker: "stale")
            _ = try await expectThrows {
                try await makeInstaller(base: base, runner: fakeRunner(), builder: fakeBuilder(status: 1)).install(
                    makeRelease("1.3.0"), replacing: installed, onEvent: { _ in }
                )
            }
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("staging").path)
            try expectEqual(leftovers, [])
        },
        TestCase("update installer: el build corre con un entorno mínimo (allowlist)") {
            let (base, installed) = try setUp()
            let builder = fakeBuilder()
            try await makeInstaller(base: base, runner: fakeRunner(), builder: builder).install(
                makeRelease("1.3.0"), replacing: installed, onEvent: { _ in }
            )
            try expectEqual(builder.isolated, [true])
            let environment = builder.calls[0].environment ?? [:]
            try expect(environment["PATH"]?.isEmpty == false)
            try expect(environment["HOME"]?.isEmpty == false)
            try expect(Set(environment.keys).isSubset(of: UpdateInstaller.buildEnvironmentKeys), "\(environment.keys)")
            let built = UpdateInstaller.buildEnvironment(inherited: [
                "PATH": "/opt/bin:/usr/bin", "HOME": "/Users/me", "TMPDIR": "/tmp/x", "LANG": "en_US.UTF-8",
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer", "GITHUB_TOKEN": "secret",
                "DYLD_INSERT_LIBRARIES": "/evil.dylib", "SWIFTPM_X": "y",
            ])
            try expectEqual(built["PATH"], "/opt/bin:/usr/bin")
            try expectEqual(built["DEVELOPER_DIR"], "/Applications/Xcode.app/Contents/Developer")
            try expectEqual(built["TMPDIR"], "/tmp/x")
            try expectEqual(built["GITHUB_TOKEN"], nil)
            try expectEqual(built["DYLD_INSERT_LIBRARIES"], nil)
            try expectEqual(built["SWIFTPM_X"], nil)
            try expectEqual(UpdateInstaller.buildEnvironment(inherited: [:])["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
            // El build baja swift-argument-parser: detrás de un proxy lo necesita.
            let proxied = UpdateInstaller.buildEnvironment(inherited: [
                "HTTPS_PROXY": "http://proxy:3128", "http_proxy": "http://proxy:3128", "NO_PROXY": "localhost",
                "https_proxy": "http://p", "HTTP_PROXY": "http://p", "no_proxy": "x", "ALL_PROXY": "socks5://evil",
            ])
            for key in ["HTTPS_PROXY", "http_proxy", "NO_PROXY", "https_proxy", "HTTP_PROXY", "no_proxy"] {
                try expect(proxied[key] != nil, "falta \(key)")
            }
        },
        TestCase("update installer: build que falla → no toca el .app") {
            let (base, installed) = try setUp()
            let runner = fakeRunner()
            let events = Box<[UpdateEvent]>([])
            let error = try await expectThrows {
                try await makeInstaller(base: base, runner: runner, builder: fakeBuilder(status: 1)).install(
                    makeRelease("1.3.0"), replacing: installed, onEvent: { events.value.append($0) }
                )
            }
            try expectEqual(error as? UpdateError, .buildFailed(status: 1))
            try expectEqual(marker(of: installed), "old")
            try expect(!FileManager.default.fileExists(atPath: AppReplacer.previousURL(for: installed).path))
            try expectEqual(phases(events.value), [.fetching, .building])
            try expect(events.value.contains(.log("error: boom")))
            try expect(!runner.calls.contains { $0.arguments == ["--version"] })
        },
        TestCase("update installer: verificación que falla → no toca el .app") {
            let (base, installed) = try setUp()
            let error = try await expectThrows {
                try await makeInstaller(base: base, runner: fakeRunner(), builder: fakeBuilder(version: "1.2.9")).install(
                    makeRelease("1.3.0"), replacing: installed, onEvent: { _ in }
                )
            }
            try expectEqual(error as? UpdateError, .versionMismatch(expected: "1.3.0", found: "1.2.9"))
            try expectEqual(marker(of: installed), "old")
        },
        TestCase("update installer: tag fuera de main → no compila") {
            let (base, installed) = try setUp()
            let builder = fakeBuilder()
            let error = try await expectThrows {
                try await makeInstaller(base: base, runner: fakeRunner(mergeBaseStatus: 1), builder: builder).install(
                    makeRelease("1.3.0"), replacing: installed, onEvent: { _ in }
                )
            }
            try expectEqual(error as? UpdateError, .tagNotOnMain("v1.3.0"))
            try expectEqual(builder.calls.count, 0)
            try expectEqual(marker(of: installed), "old")
        },
        TestCase("update installer: cancelado antes de reemplazar → no toca el .app") {
            let (base, installed) = try setUp()
            let error = try await expectThrows {
                try await makeInstaller(base: base, runner: fakeRunner(), builder: fakeBuilder()).install(
                    makeRelease("1.3.0"), replacing: installed, beforeReplace: { throw CancellationError() }, onEvent: { _ in }
                )
            }
            try expect(error is CancellationError, "\(error)")
            try expectEqual(marker(of: installed), "old")
        },
        TestCase("update installer: carpeta de la app sin escritura → falla antes de git") {
            let (base, installed) = try setUp()
            let folder = installed.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            let runner = fakeRunner()
            let error = try await expectThrows {
                try await makeInstaller(base: base, runner: runner, builder: fakeBuilder()).install(
                    makeRelease("1.3.0"), replacing: installed, onEvent: { _ in }
                )
            }
            try expectEqual(error as? UpdateError, .notWritable(folder.path))
            try expectEqual(runner.calls.count, 0)
        },
    ]

    static let relaunchCases: [TestCase] = [
        TestCase("relaunch: argumentos de /bin/sh") {
            try expectEqual(Relauncher.arguments(waitingFor: 4242, appPath: "/Users/me/Applications/PRBar.app"), [
                "-c",
                "while kill -0 4242 2>/dev/null; do sleep 0.2; done; "
                    + "for attempt in 1 2 3 4 5; do /usr/bin/open \"$0\" && exit 0; sleep 1; done; exit 1",
                "/Users/me/Applications/PRBar.app",
            ])
        },
        TestCase("relaunch: espera al pid y pasa la ruta tal cual (espacios y comillas)") {
            let target = try temporaryDirectory().appendingPathComponent("Pr Bar 'x\" $HOME.app").path
            let finished = Process()
            finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try finished.run()
            finished.waitUntilExit()
            let arguments = Relauncher.arguments(waitingFor: finished.processIdentifier, appPath: target, openCommand: "/usr/bin/touch")
            let result = try await SystemProcessRunner().run("/bin/sh", arguments, timeout: 10)
            try expectEqual(result.status, 0)
            try expect(FileManager.default.fileExists(atPath: target))
        },
        TestCase("pending update: se lee una sola vez y solo si es la versión que corre") {
            let url = try temporaryDirectory().appendingPathComponent("update-installed.json")
            let update = PendingUpdate(version: "1.3.0", notes: "- Chat", installedAt: Date(timeIntervalSince1970: 1_800_000_000))
            try PendingUpdate.save(update, to: url)
            try expectEqual(PendingUpdate.take(currentVersion: "1.3.0", from: url), update)
            try expectEqual(PendingUpdate.take(currentVersion: "1.3.0", from: url), nil)

            try PendingUpdate.save(update, to: url)
            try expectEqual(PendingUpdate.take(currentVersion: "1.2.0", from: url), nil)
            try expect(!FileManager.default.fileExists(atPath: url.path))

            try Data("{".utf8).write(to: url)
            try expectEqual(PendingUpdate.take(currentVersion: "1.3.0", from: url), nil)
            try expect(!FileManager.default.fileExists(atPath: url.path))
        },
    ]
}
