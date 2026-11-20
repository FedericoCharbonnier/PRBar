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
