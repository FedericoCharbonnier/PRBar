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
        ("onSubmit", #"\.onSubmit\b"#),
        ("onKeyPress", #"\.onKeyPress\b"#),
        ("swipeActions", #"\.swipeActions\b"#),
        ("onDrop", #"\.onDrop\b"#),
        ("dropDestination", #"\.dropDestination\b"#),
        ("onMove", #"\.onMove\b"#),
        ("onDelete", #"\.onDelete\b"#),
        ("Slider", #"(?<![A-Za-z])Slider\s*\("#),
        ("DatePicker", #"(?<![A-Za-z])DatePicker\s*\("#),
        ("primaryAction", #"(?<![A-Za-z])primaryAction:"#),
        ("NSMenuItem", #"(?<![A-Za-z])NSMenuItem\("#),
        ("NSAlertButton", #"\.addButton\(withTitle:"#),
        ("commands", #"\.commands\s*\{"#),
        ("ConfirmAlert", #"(?<![A-Za-z])ConfirmAlert\.present\("#),
        ("OpenPanel", #"(?<![A-Za-z])OpenPanel\.present\("#),
    ]

    /// Declaraciones (p. ej. `struct IconButton`): lo que está antes de la primera `{` de la línea no es un uso (lo de
    /// después sí: `func x() { Button(…) }`). Los parámetros `onPick:`… sí cuentan siempre.
    private static let declaration = try! NSRegularExpression(
        pattern: #"^\s*((private|fileprivate|public|@MainActor|static|mutating) )*(struct|init|func|enum|class)\b"#)
    private static let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
    private static let alwaysCounted: Set<String> = ["onPick", "freeform", "onRetry", "onReload"]

    /// Un `struct` de la app (a cualquier nivel) y sus miembros, un nivel más adentro.
    private static let structDeclaration = try! NSRegularExpression(
        pattern: #"^(\s*)((private|fileprivate|public) )?struct (\w+)"#)
    /// Otro tipo al mismo nivel (o más afuera) que el `struct` de antes: sus miembros ya no son del `struct`.
    private static let otherTypeDeclaration = try! NSRegularExpression(
        pattern: #"^(\s*)((private|fileprivate|public|final|@MainActor) )*(class|enum|extension|actor) \w+"#)
    /// Una acción que recibe un componente: una propiedad o un parámetro del `init` que es un closure (`-> Void`).
    private static let actionMember = try! NSRegularExpression(
        pattern: #"^(\s*)((private|fileprivate|public) )?((let|var) \w+: .*-> Void|init\(.*-> Void)"#)
    /// Componentes que ya tienen su propio patrón.
    private static let componentsWithPattern: Set<String> = ["IconButton", "ExternalLink", "ClosureMenuItem"]

    private static func swiftFiles(_ root: URL) -> [URL] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Snapshots/") } ?? [])
            .sorted { $0.path < $1.path }
    }

    /// Los componentes de la app que reciben acciones (`MergeButtonActions`, `OutdatedReviewBanner`, `TestsSection`…):
    /// cada lugar que los arma es un control más, aunque los botones estén en otro archivo.
    static func actionComponents(root: URL = appSources) throws -> Set<String> {
        var names: Set<String> = []
        for file in swiftFiles(root) {
            var current: (name: String, indent: Int)?
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                if let match = structDeclaration.firstMatch(in: line, range: range),
                   let name = Range(match.range(at: 4), in: line) {
                    current = (String(line[name]), match.range(at: 1).length)
                    continue
                }
                if let open = current, let match = otherTypeDeclaration.firstMatch(in: line, range: range),
                   match.range(at: 1).length <= open.indent {
                    current = nil
                    continue
                }
                if let current, let match = actionMember.firstMatch(in: line, range: range),
                   match.range(at: 1).length == current.indent + 4 {
                    names.insert(current.name)
                }
            }
        }
        return names.subtracting(componentsWithPattern)
    }

    static func scan(root: URL = appSources) throws -> [Key: Int] {
        let components = try actionComponents(root: root).sorted().map {
            ("Component:\($0)", #"(?<![A-Za-z.])\#($0)\s*(\(|\{)"#)
        }
        let compiled = try (patterns + components).map { ($0.0, try NSRegularExpression(pattern: $0.1)) }
        var counts: [Key: Int] = [:]
        for file in swiftFiles(root) {
            let relative = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                // En una declaración, lo que va antes de la `{` (el nombre, los parámetros) no es un uso.
                var headerEnd = 0
                if declaration.firstMatch(in: line, range: range) != nil {
                    headerEnd = (line as NSString).range(of: "{").location
                    if headerEnd == NSNotFound { headerEnd = range.length }
                }
                for (kind, regex) in compiled {
                    for match in regex.matches(in: line, range: range) {
                        if match.range.location < headerEnd && !alwaysCounted.contains(kind) { continue }
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
        }
        return counts
    }
}
