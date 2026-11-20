import Foundation
import PRBarCLIKit

/// Código de app de mentira con un control de cada tipo que tiene que ver el escáner (se escribe en una carpeta
/// temporal: no es parte de ningún target).
private let scannerFixture: [String: String] = [
    "Banner.swift": #"""
    struct Banner: View {
        let title: String
        let action: () -> Void
        var body: some View { Text(title) }
    }

    struct Plain: View {
        let title: String
        var body: some View { Text(title) }
    }
    """#,
    "Screen.swift": #"""
    struct Screen: View {
        var body: some View {
            Banner(title: "Outdated") { }
            Banner(title: "Other", action: reload)
            Plain(title: "No actions")
            TextField("Name", text: $name).onSubmit(save)
            Text("x").onKeyPress(.return) { .handled }
            Row().swipeActions { }
            Slider(value: $volume)
            DatePicker("When", selection: $date)
            Menu("More") { } primaryAction: { approve() }
            Color.clear.onDrop(of: [.url], isTargeted: nil) { _ in true }
            Color.clear.dropDestination(for: URL.self) { _, _ in true }
            ForEach(items) { Text($0) }.onMove { _, _ in }.onDelete { _ in }
            Button("Twice") { }; Button("Twice") { }
        }
    }

    func inline() { Button("Inline") { } }
    // Button("Commented out")

    enum Alerts {
        static func ask() {
            alert.addButton(withTitle: "OK")
            let item = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q")
            ConfirmAlert.present(title: "Sure?", message: "", action: "Do") { }
            OpenPanel.present(panel) { _ in }
        }
    }

    struct MyApp: App {
        var body: some Scene { WindowGroup { Screen() }.commands { } }
    }
    """#,
]

enum UIParityTests {
    static let cases: [TestCase] = [
        TestCase("paridad UI: el escáner ve cada tipo de control (fixture)") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            for (name, text) in scannerFixture { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
            try expectEqual(try UIActionScanner.actionComponents(root: root), ["Banner"])
            let scanned = try UIActionScanner.scan(root: root)
            let expected: [UIActionScanner.Key: Int] = [
                .init(file: "Screen.swift", kind: "Component:Banner", label: "Outdated"): 1,
                .init(file: "Screen.swift", kind: "Component:Banner", label: "Other"): 1,
                .init(file: "Screen.swift", kind: "TextField", label: "Name"): 1,
                .init(file: "Screen.swift", kind: "onSubmit", label: "-"): 1,
                .init(file: "Screen.swift", kind: "onKeyPress", label: "-"): 1,
                .init(file: "Screen.swift", kind: "swipeActions", label: "-"): 1,
                .init(file: "Screen.swift", kind: "Slider", label: "-"): 1,
                .init(file: "Screen.swift", kind: "DatePicker", label: "When"): 1,
                .init(file: "Screen.swift", kind: "primaryAction", label: "-"): 1,
                .init(file: "Screen.swift", kind: "onDrop", label: "-"): 1,
                .init(file: "Screen.swift", kind: "dropDestination", label: "-"): 1,
                .init(file: "Screen.swift", kind: "onMove", label: "-"): 1,
                .init(file: "Screen.swift", kind: "onDelete", label: "-"): 1,
                .init(file: "Screen.swift", kind: "Button", label: "Twice"): 2,
                .init(file: "Screen.swift", kind: "Button", label: "Inline"): 1,
                .init(file: "Screen.swift", kind: "NSAlertButton", label: "OK"): 1,
                .init(file: "Screen.swift", kind: "NSMenuItem", label: "Quit"): 1,
                .init(file: "Screen.swift", kind: "ConfirmAlert", label: "Sure?"): 1,
                .init(file: "Screen.swift", kind: "OpenPanel", label: "-"): 1,
                .init(file: "Screen.swift", kind: "commands", label: "-"): 1,
            ]
            let missing = expected.filter { scanned[$0.key] != $0.value }
            let extra = scanned.filter { expected[$0.key] == nil }
            try expect(missing.isEmpty && extra.isEmpty,
                       "faltan: \(missing.keys.sorted()) · sobran: \(extra.keys.sorted()) · encontró: \(scanned.sorted { $0.key < $1.key })")
        },
        TestCase("paridad UI: cada control de la app tiene su comando (o una razón)") {
            let scanned = try UIActionScanner.scan()
            try expect(!scanned.isEmpty, "el escáner no encontró nada en \(UIActionScanner.appSources.path)")
            var expected: [UIActionScanner.Key: UIAction] = [:]
            for entry in UIActionInventory.entries {
                try expect(expected[entry.key] == nil, "entrada repetida: \(entry.key)")
                expected[entry.key] = entry
            }
            var problems: [String] = []
            for (key, count) in scanned.sorted(by: { $0.key < $1.key }) {
                guard let entry = expected[key] else {
                    problems.append("NUEVO, sin entrada:  .init(\"\(key.file)\", \"\(key.kind)\", \"\(key.label)\", \(count), .cli([\"…\"])),")
                    continue
                }
                if entry.count != count { problems.append("CANTIDAD: \(key) tiene \(count), el inventario dice \(entry.count)") }
            }
            for key in expected.keys.sorted() where scanned[key] == nil {
                problems.append("YA NO EXISTE: \(key) (borrar la entrada)")
            }
            for entry in UIActionInventory.entries {
                if case .cli(let paths) = entry.mapping {
                    for path in paths where !CLIRouter.allPaths.contains(path) {
                        problems.append("COMANDO INEXISTENTE: \(entry.key) → `\(path)`")
                    }
                }
            }
            try expect(problems.isEmpty, "\n" + problems.joined(separator: "\n"))
        },
    ]
}
