import PRBarCore

enum FocusModeTests {
    static let cases: [TestCase] = [
        TestCase("modo foco: entra al empezar Claude (lista oculta, chat abierto) y sale al terminar") {
            var focus = FocusModeState()
            focus.setClaudeWorking(true)
            try expect(focus.isFocused && focus.chatShown)
            focus.setClaudeWorking(false)
            try expect(!focus.isFocused && !focus.chatShown)
        },
        TestCase("modo foco: si el usuario toca el chat durante la tarea, al terminar se respeta") {
            var focus = FocusModeState()
            focus.setClaudeWorking(true)
            focus.toggleChat()   // lo cierra a mano
            focus.setClaudeWorking(false)
            try expect(!focus.chatShown)
            focus.setClaudeWorking(true)
            focus.toggleChat(); focus.toggleChat()   // lo cierra y lo vuelve a abrir
            focus.setClaudeWorking(false)
            try expect(focus.chatShown && !focus.isFocused)
        },
        TestCase("modo foco: fuera de una tarea el chat es solo del usuario") {
            var focus = FocusModeState()
            focus.toggleChat()
            try expect(focus.chatShown && !focus.isFocused)
            focus.setClaudeWorking(false)
            try expect(focus.chatShown)
        },
    ]
}
