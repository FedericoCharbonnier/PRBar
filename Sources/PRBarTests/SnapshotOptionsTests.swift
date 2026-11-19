import Foundation
import PRBarCore

enum SnapshotOptionsTests {
    private static let cwd = URL(fileURLWithPath: "/tmp/work", isDirectory: true)

    private static func parse(_ args: [String]) -> Result<SnapshotOptions, SnapshotOptions.ParseError>? {
        SnapshotOptions.parse(["PRBar"] + args, currentDirectory: cwd)
    }

    private static func options(_ args: [String]) throws -> SnapshotOptions {
        guard case .success(let options)? = parse(args) else { throw TestFailure(description: "expected options for \(args)") }
        return options
    }

    private static func error(_ args: [String]) throws -> String {
        guard case .failure(let error)? = parse(args) else { throw TestFailure(description: "expected an error for \(args)") }
        return error.message
    }

    static let cases: [TestCase] = [
        TestCase("snapshots: a normal launch isn't snapshot mode") {
            try expect(parse([]) == nil)
            try expect(parse(["-psn_0_12345"]) == nil)
            try expect(parse(["-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        },
        TestCase("snapshots: directory and appearance") {
            let light = try options(["--snapshots", "docs/screenshots"])
            try expectEqual(light.outputDirectory.path, "/tmp/work/docs/screenshots")
            try expectEqual(light.appearances, [.light])

            let both = try options(["--snapshots", "/var/out", "--appearance", "both"])
            try expectEqual(both.outputDirectory.path, "/var/out")
            try expectEqual(both.appearances, [.light, .dark])

            let dark = try options(["--appearance=dark", "--snapshots=out", "-NSDocumentRevisionsDebugMode", "YES"])
            try expectEqual(dark.outputDirectory.path, "/tmp/work/out")
            try expectEqual(dark.appearances, [.dark])
        },
        TestCase("snapshots: file names get a suffix only with both appearances") {
            let both = try options(["--snapshots", "out", "--appearance", "both"])
            try expectEqual(both.fileName("popover", appearance: .light), "popover-light.png")
            try expectEqual(both.fileName("popover", appearance: .dark), "popover-dark.png")
            let dark = try options(["--snapshots", "out", "--appearance", "dark"])
            try expectEqual(dark.fileName("popover", appearance: .dark), "popover.png")
        },
        TestCase("snapshots: invalid arguments") {
            try expect(try error(["--snapshots"]).contains("output directory"))
            try expect(try error(["--snapshots", "--appearance", "dark"]).contains("output directory"))
            try expect(try error(["--snapshots", "out", "--appearance", "sepia"]).contains("sepia"))
            try expect(try error(["--snapshots", "out", "--appearance"]).contains("light, dark or both"))
            try expect(try error(["--snapshots", "out", "--verbose"]).contains("--verbose"))
        },
    ]
}
