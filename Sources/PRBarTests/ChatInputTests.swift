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
    ]
}
