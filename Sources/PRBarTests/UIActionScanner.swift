import Foundation

/// Encuentra los controles de la UI en el código de la app (ver la Task 21 del plan 7).
enum UIActionScanner {
    struct Key: Hashable, Comparable, CustomStringConvertible {
        let file: String
        let kind: String
        let label: String

        static func < (a: Key, b: Key) -> Bool { a.description < b.description }
        var description: String { "\(file)|\(kind)|\(label)" }
    }

    /// `Sources/PRBar`, a partir de este archivo (`Sources/PRBarTests/UIActionScanner.swift`).
    static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PRBar", isDirectory: true)

    private static let patterns: [(kind: String, regex: String)] = [
        ("Button", #"(?<![A-Za-z])Button\s*(\(|\{)"#),
        ("IconButton", #"(?<![A-Za-z])IconButton\s*\("#),
        ("Toggle", #"(?<![A-Za-z])Toggle\s*\("#),
        ("Picker", #"(?<![A-Za-z])Picker\s*\("#),
        ("Stepper", #"(?<![A-Za-z])Stepper\s*\("#),
        ("TextField", #"(?<![A-Za-z])TextField\s*\("#),
        ("SecureField", #"(?<![A-Za-z])SecureField\s*\("#),
        ("TextEditor", #"(?<![A-Za-z])TextEditor\s*\("#),
        ("Link", #"(?<![A-Za-z])Link\s*\("#),
        ("ExternalLink", #"(?<![A-Za-z])ExternalLink\s*\("#),
        ("ClosureMenuItem", #"(?<![A-Za-z])ClosureMenuItem\s*\(title:"#),
        ("MenuItem", #"(?<![A-Za-z.])item\((?=")"#),
        ("onPick", #"(?<![A-Za-z])onPick:"#),
        ("freeform", #"(?<![A-Za-z])freeform:"#),
        ("onRetry", #"(?<![A-Za-z])onRetry:"#),
        ("onReload", #"(?<![A-Za-z])onReload:"#),
        ("onDeleteCommand", #"\.onDeleteCommand"#),
        ("searchable", #"\.searchable\("#),
        ("DisclosureGroup", #"(?<![A-Za-z])DisclosureGroup\s*\("#),
        ("onTapGesture", #"\.onTapGesture"#),
        ("accessibilityAction", #"\.accessibilityAction\(named:"#),
        ("NotificationAction", #"UNNotificationAction\("#),
        ("ListSelection", #"(?<![A-Za-z])List\(selection:"#),
    ]

    /// Declaraciones (p. ej. `struct IconButton`): no son usos. Los parámetros `onPick:`… sí cuentan siempre.
    private static let declaration = try! NSRegularExpression(
        pattern: #"^\s*(private |fileprivate )?(struct|init|func|enum|class|static func)\b"#)
    private static let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
    private static let alwaysCounted: Set<String> = ["onPick", "freeform", "onRetry", "onReload"]

    static func scan(root: URL = appSources) throws -> [Key: Int] {
        let compiled = try patterns.map { ($0.kind, try NSRegularExpression(pattern: $0.regex)) }
        var counts: [Key: Int] = [:]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Snapshots/") } ?? []
        for file in files {
            let relative = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                let isDeclaration = declaration.firstMatch(in: line, range: range) != nil
                for (kind, regex) in compiled {
                    guard let match = regex.firstMatch(in: line, range: range) else { continue }
                    if isDeclaration && !alwaysCounted.contains(kind) { continue }
                    let restStart = match.range.location + match.range.length
                    let rest = NSRange(location: restStart, length: range.length - restStart)
                    var label = "-"
                    if let found = literal.firstMatch(in: line, range: rest), let text = Range(found.range(at: 1), in: line) {
                        label = String(line[text])
                    }
                    counts[Key(file: relative, kind: kind, label: label), default: 0] += 1
                }
            }
        }
        return counts
    }
}
