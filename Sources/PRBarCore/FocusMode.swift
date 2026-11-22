/// Modo foco del detalle (spec M.1 "Modo foco y chat"): mientras Claude trabaja en Respond o Fix CI del PR que se ve,
/// la lista se oculta y el chat se abre; al terminar vuelve la lista y el chat se cierra, salvo que el usuario lo haya
/// abierto o cerrado a mano durante la tarea.
public struct FocusModeState: Equatable, Sendable {
    public private(set) var isFocused = false
    public private(set) var chatShown: Bool
    private var userChoseChat = false

    public init(chatShown: Bool = false) { self.chatShown = chatShown }

    public mutating func setClaudeWorking(_ working: Bool) {
        if working, !isFocused {
            isFocused = true
            userChoseChat = false
            chatShown = true
        } else if !working, isFocused {
            isFocused = false
            if !userChoseChat { chatShown = false }
            userChoseChat = false
        }
    }

    /// ⌥⌘I, el botón de la toolbar o el cierre del inspector.
    public mutating func toggleChat() { setChatShown(!chatShown) }

    public mutating func setChatShown(_ shown: Bool) {
        guard shown != chatShown else { return }
        chatShown = shown
        if isFocused { userChoseChat = true }
    }
}
