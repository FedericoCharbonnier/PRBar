import PRBarCore

/// Return in the chat fields (`ChatReturnKey`).
enum ChatInputTests {
    static let cases: [TestCase] = [
        TestCase("chat input: ↩ envía, ⇧↩ y ⌥↩ son un salto de línea") {
            try expectEqual(ChatReturnKey.action(shift: false, option: false, hasMarkedText: false), .send)
            try expectEqual(ChatReturnKey.action(shift: true, option: false, hasMarkedText: false), .newline)
            try expectEqual(ChatReturnKey.action(shift: false, option: true, hasMarkedText: false), .newline)
        },
        TestCase("chat input: con texto en composición (japonés, chino, coreano) ↩ es del método de entrada") {
            try expectEqual(ChatReturnKey.action(shift: false, option: false, hasMarkedText: true), .passThrough)
            try expectEqual(ChatReturnKey.action(shift: true, option: false, hasMarkedText: true), .passThrough)
        },
        TestCase("chat input: ⌘↩ escribiendo en un texto es del texto (manda el chat), no del botón Merge/Post/Implement") {
            // ⌘↩ en el chat: el texto se la queda (y la manda, como ↩ con ⌘).
            try expect(PrimaryShortcutScope.textKeepsKey(isReturn: true, command: true, shift: false, option: false,
                                                         control: false, editingText: true))
            try expectEqual(ChatReturnKey.action(shift: false, option: false, hasMarkedText: false), .send)
            // Sin un texto en edición, ⌘↩ sigue siendo la acción principal de la ventana.
            try expect(!PrimaryShortcutScope.textKeepsKey(isReturn: true, command: true, shift: false, option: false,
                                                          control: false, editingText: false))
            // Otras teclas y combinaciones no cambian.
            try expect(!PrimaryShortcutScope.textKeepsKey(isReturn: false, command: true, shift: false, option: false,
                                                          control: false, editingText: true))
            try expect(!PrimaryShortcutScope.textKeepsKey(isReturn: true, command: true, shift: true, option: false,
                                                          control: false, editingText: true))
            try expect(!PrimaryShortcutScope.textKeepsKey(isReturn: true, command: false, shift: false, option: false,
                                                          control: false, editingText: true))
        },
    ]
}
