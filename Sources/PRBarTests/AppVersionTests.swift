import Foundation
import PRBarCore

enum AppVersionTests {
    static let cases: [TestCase] = [
        TestCase("version: lee CFBundleShortVersionString y CFBundleVersion del bundle") {
            let app = try temporaryDirectory().appendingPathComponent("Fake.app", isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "42",
                "CFBundleIdentifier": "com.example.fake", "CFBundlePackageType": "APPL",
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            guard let bundle = Bundle(url: app) else { throw TestFailure(description: "Bundle(url:) returned nil") }
            try expectEqual(AppVersion.current(bundle: bundle), "9.8.7")
            try expectEqual(AppVersion.build(bundle: bundle), "42")
        },
        TestCase("version: sin Info.plist usa PRBarCore.version") {
            guard let bundle = Bundle(url: try temporaryDirectory()) else { throw TestFailure(description: "no bundle") }
            try expectEqual(AppVersion.current(bundle: bundle), PRBarCore.version)
            try expectEqual(AppVersion.build(bundle: bundle), nil)
        },
        TestCase("version: --version se reconoce en cualquier posición después del ejecutable") {
            try expect(AppVersion.isVersionRequest(["/Applications/PRBar.app/Contents/MacOS/PRBar", "--version"]))
            try expect(AppVersion.isVersionRequest(["PRBar", "-psn_0_12345", "--version"]))
            try expect(!AppVersion.isVersionRequest(["PRBar"]))
            try expect(!AppVersion.isVersionRequest(["--version"]))
            try expect(!AppVersion.isVersionRequest(["PRBar", "--snapshots", "out"]))
        },
        TestCase("version: la línea de --version es 'PRBar X.Y.Z'") {
            try expectEqual(AppVersion.versionLine("1.3.0"), "PRBar 1.3.0")
        },
    ]
}
