/// What Return does in a chat's message field (the PR chat and Settings › Instructions).
public enum ChatReturnKey {
    public enum Action: Equatable, Sendable {
        /// Sends the message.
        case send
        /// Inserts a line break where the cursor is.
        case newline
        /// Left to the text system: an input method (Japanese, Chinese, Korean…) is composing, and Return confirms
        /// the composition instead of sending.
        case passThrough
    }

    /// - Parameters:
    ///   - shift: ⇧ is down (⇧↩ is a new line).
    ///   - option: ⌥ is down (⌥↩ is a new line, as in the system's text fields).
    ///   - hasMarkedText: the field has text an input method is still composing.
    public static func action(shift: Bool, option: Bool, hasMarkedText: Bool) -> Action {
        if hasMarkedText { return .passThrough }
        return shift || option ? .newline : .send
    }
}

/// ⌘↩ is the primary action of the Merge, Review and Respond windows (Merge, Post Review, Implement…). While the user
/// is typing in an editable text (a chat composer, a finding's text) the key belongs to the text: in the chat it
/// sends, as in most chat apps, and the window's button never sees it (AppKit runs key equivalents before the text
/// view's `keyDown`, so without this a ⌘↩ typed out of habit in the Merge chat would merge).
public enum PrimaryShortcutScope {
    /// Whether the window skips its key equivalents for this key so the editing text gets it as a normal key.
    /// - Parameters:
    ///   - isReturn: the key is Return or Enter.
    ///   - command/shift/option/control: the modifiers held.
    ///   - editingText: the first responder is an editable text view (a text field's field editor or a text editor).
    public static func textKeepsKey(isReturn: Bool, command: Bool, shift: Bool, option: Bool, control: Bool,
                                    editingText: Bool) -> Bool {
        isReturn && command && !shift && !option && !control && editingText
    }
}
