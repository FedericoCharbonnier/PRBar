import PRBarCore

/// Help › Keyboard Shortcuts lists the View menu's and the popover's shortcuts.
enum KeyboardShortcutListTests {
    static let cases: [TestCase] = [
        TestCase("atajos: la lista de Help tiene los del menú View y los del popover") {
            let keys = KeyboardShortcutList.groups.flatMap(\.shortcuts).map(\.keys)
            for expected in ["⇧⌘C", "⌘R", "⌃⌘F", "↑ ↓", "↩", "⌘1 / ⌘2", "⌘Y", "⌘,", "⌘Q", "esc", "⇧↩ or ⌥↩"] {
                try expect(keys.contains(expected), "falta \(expected)")
            }
        },
    ]
}
