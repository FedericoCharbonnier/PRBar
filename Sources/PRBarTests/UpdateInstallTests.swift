import Foundation
import PRBarCore

/// Un `.app` mínimo: Info.plist, un ejecutable que imprime `PRBar <version>` y `Contents/marker.txt` para saber cuál es.
func makeFakeApp(at app: URL, version: String, identifier: String = "com.federico.prbar", marker: String) throws {
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": identifier, "CFBundleExecutable": "PRBar"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let executable = macOS.appendingPathComponent("PRBar")
    try Data("#!/bin/sh\necho \"PRBar \(version)\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try Data(marker.utf8).write(to: contents.appendingPathComponent("marker.txt"))
}

func marker(of app: URL) -> String? {
    try? String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
}

enum UpdateInstallTests {
    static let cases: [TestCase] = verifierCases + replacerCases

    static let verifierCases: [TestCase] = [
        TestCase("update verifier: versión, bundle id y --version correctos") {
            let app = try temporaryDirectory().appendingPathComponent("PRBar.app", isDirectory: true)
            try makeFakeApp(at: app, version: "1.3.0", marker: "new")
            try await UpdateVerifier.verify(app: app, expectedVersion: SemanticVersion(1, 3, 0),
                                            bundleIdentifier: "com.federico.prbar", runner: SystemProcessRunner())
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
            try expectEqual(runner.calls.first?.arguments, ["--version"])
        },
    ]

    static let replacerCases: [TestCase] = [
        TestCase("app replacer: mueve el actual a .previous y el nuevo a su lugar") {
            let dir = try temporaryDirectory()
            let installed = dir.appendingPathComponent("Applications/PRBar.app", isDirectory: true)
            let staged = dir.appendingPathComponent("staging/PRBar.app", isDirectory: true)
            try makeFakeApp(at: installed, version: "1.2.0", marker: "old")
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
            let staged = dir.appendingPathComponent("staging/PRBar.app", isDirectory: true)
            try makeFakeApp(at: installed, version: "1.2.0", marker: "old")
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
}
