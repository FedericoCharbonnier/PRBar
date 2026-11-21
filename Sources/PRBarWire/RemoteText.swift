import Foundation

/// Text that crosses between the Mac and the iPhone and that someone else may have written (PR titles, test output,
/// chat, the names in a pairing link): shown as plain text, never with terminal escapes or the invisible characters
/// that reorder or hide what is on screen (bidi controls, zero-width characters). Shared by the Mac (before anything
/// goes to the phone) and the iPhone (names it reads from a QR or a pairing link). Review M1/L1/L5.
public enum RemoteText {
    /// A name or a title: one line, without control, format or terminal escape characters, at most `limit` characters.
    /// Empty when nothing visible is left.
    public static func displayName(_ text: String, limit: Int = 64) -> String {
        let cleaned = clean(text).split(whereSeparator: { $0.isNewline || $0 == "\t" || $0 == " " }).joined(separator: " ")
        return String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespaces)
    }

    /// Multi-line text: terminal escapes (ANSI CSI/OSC) removed, `\r\n` and `\r` as `\n`, control characters other
    /// than `\n` and `\t` removed, format characters (bidi controls, zero width) removed except the zero-width joiner
    /// (emoji sequences), and runs of variation selectors (which can smuggle invisible text) cut to the one that
    /// follows a visible character.
    public static func clean(_ text: String) -> String {
        var text = text
        if text.contains("\r") {
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        if text.contains("\u{1B}") || text.unicodeScalars.contains(where: { $0.value == 0x9B || $0.value == 0x9D }) {
            text = ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        var scalars = String.UnicodeScalarView()
        var previousWasSelector = true
        for scalar in text.unicodeScalars {
            if let supplementary = variationSelector(scalar) {
                if !supplementary && !previousWasSelector { scalars.append(scalar) }
                previousWasSelector = true
                continue
            }
            previousWasSelector = false
            switch scalar.properties.generalCategory {
            case .control where scalar == "\n" || scalar == "\t": scalars.append(scalar)
            case .lineSeparator, .paragraphSeparator: scalars.append("\n")
            case .format where scalar.value == 0x200D: scalars.append(scalar)
            case .control, .format, .surrogate, .privateUse, .unassigned: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// CSI (`ESC [ … final`, or the 8-bit `0x9B`), OSC (`ESC ] … BEL|ST`, or `0x9D`) and the two-byte escapes.
    private static let ansi = try! NSRegularExpression(
        pattern: "(?:\u{1B}\\[|\u{9B})[0-?]*[ -/]*[@-~]|(?:\u{1B}\\]|\u{9D})[^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)?|\u{1B}[@-Z\\\\-_]")

    /// nil: not a variation selector; false: VS1–16 (U+FE00–FE0F); true: VS17–256 (U+E0100–E01EF).
    private static func variationSelector(_ scalar: Unicode.Scalar) -> Bool? {
        switch scalar.value {
        case 0xFE00...0xFE0F: false
        case 0xE0100...0xE01EF: true
        default: nil
        }
    }
}
