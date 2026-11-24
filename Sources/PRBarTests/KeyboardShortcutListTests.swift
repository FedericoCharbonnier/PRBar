import PRBarCore

/// Help › Keyboard Shortcuts lists the main window's, the popover's and the chat's shortcuts.
enum KeyboardShortcutListTests {
    static let cases: [TestCase] = [
        TestCase("atajos: la lista de Help tiene los de la ventana principal y los del popover, sin ⌘Y") {
            let keys = KeyboardShortcutList.groups.flatMap(\.shortcuts).map(\.keys)
            for expected in ["⌘0", "⌘1 · ⌘2 · ⌘3 · ⌘4", "⌥⌘1–3", "↑ ↓", "↩", "⌘↩", "⇧⌘M", "⌘.", "⌘Z", "⌥⌘I", "⌥⌘T", "⌃⌘S",
                             "⇧⌘O", "⌘R", "⌘F", "⌘[", "⌘,", "⌘Q", "esc", "⇧↩ or ⌥↩"] {
                try expect(keys.contains(expected), "falta \(expected)")
            }
            try expect(!keys.contains("⌘Y") && !keys.contains("⇧⌘C"))
        },
    ]
}
