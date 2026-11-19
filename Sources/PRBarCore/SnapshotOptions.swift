import Foundation

/// Arguments of the snapshot mode: `PRBar --snapshots <dir> [--appearance light|dark|both]`. The app renders its
/// screens with sample data into PNGs in `<dir>` and exits. Without `--snapshots` it's a normal launch.
public struct SnapshotOptions: Equatable, Sendable {
    public enum Appearance: String, CaseIterable, Sendable {
        case light, dark
    }

    public struct ParseError: Error, Equatable, Sendable {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }
    }

    public static let usage = "Usage: PRBar --snapshots <output-dir> [--appearance light|dark|both]"

    public let outputDirectory: URL
    /// In rendering order. Light only unless `--appearance` says otherwise.
    public let appearances: [Appearance]

    public init(outputDirectory: URL, appearances: [Appearance]) {
        self.outputDirectory = outputDirectory
        self.appearances = appearances
    }

    /// `popover.png` with one appearance; `popover-light.png` and `popover-dark.png` with both.
    public func fileName(_ base: String, appearance: Appearance) -> String {
        appearances.count > 1 ? "\(base)-\(appearance.rawValue).png" : "\(base).png"
    }

    /// `nil` if the arguments don't ask for snapshots. `arguments[0]` is the executable. A relative directory is
    /// resolved against `currentDirectory`. Arguments that macOS adds to a launch (`-psn_…`, `-NS… value`) are ignored.
    public static func parse(
        _ arguments: [String],
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> Result<SnapshotOptions, ParseError>? {
        let args = Array(arguments.dropFirst())
        guard args.contains(where: { $0 == "--snapshots" || $0.hasPrefix("--snapshots=") }) else { return nil }
        var directory: String?
        var appearance = "light"
        var index = 0
        func value(_ name: String, _ argument: String) -> String? {
            if argument.hasPrefix("\(name)=") { return String(argument.dropFirst(name.count + 1)) }
            index += 1
            return index < args.count && !args[index].hasPrefix("--") ? args[index] : nil
        }
        while index < args.count {
            let argument = args[index]
            if argument == "--snapshots" || argument.hasPrefix("--snapshots=") {
                guard let path = value("--snapshots", argument), !path.isEmpty else {
                    return .failure(ParseError("--snapshots needs an output directory."))
                }
                directory = path
            } else if argument == "--appearance" || argument.hasPrefix("--appearance=") {
                guard let name = value("--appearance", argument) else {
                    return .failure(ParseError("--appearance needs light, dark or both."))
                }
                appearance = name
            } else if argument.hasPrefix("-psn_") {
                // Process serial number from older LaunchServices.
            } else if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") {
                index += 1   // `-NSSomething value`
            } else {
                return .failure(ParseError("Unknown argument: \(argument)"))
            }
            index += 1
        }
        let appearances: [Appearance]
        switch appearance {
        case "light": appearances = [.light]
        case "dark": appearances = [.dark]
        case "both": appearances = [.light, .dark]
        default: return .failure(ParseError("Unknown appearance “\(appearance)”: use light, dark or both."))
        }
        guard let directory else { return .failure(ParseError("--snapshots needs an output directory.")) }
        let expanded = (directory as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded, isDirectory: true)
            : currentDirectory.appendingPathComponent(expanded, isDirectory: true)
        return .success(SnapshotOptions(outputDirectory: url.standardizedFileURL, appearances: appearances))
    }
}
