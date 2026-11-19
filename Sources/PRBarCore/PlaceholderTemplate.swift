import Foundation

/// `{name}` placeholders, replaced in a single pass: a value that contains `{x}` is never expanded again, and an
/// unknown name stays as it is. Used by the editable prompts (spec E.6) and the fixes' templates (spec E.5).
public enum PlaceholderTemplate {
    public static func render(_ template: String, values: [String: String]) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "}"), let value = values[String(rest[afterOpen..<close])] {
                result += value
                rest = rest[rest.index(after: close)...]
            } else {
                result += "{"
                rest = rest[afterOpen...]
            }
        }
        return result + rest
    }

    /// The names between braces that look like variables (`[a-z0-9_]+`), in order and without repeating. JSON
    /// (`{"a": 1}`) and stray braces don't count.
    public static func names(in template: String) -> [String] {
        var names: [String] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { break }
            let name = String(rest[afterOpen..<close])
            if isName(name) {
                if !names.contains(name) { names.append(name) }
                rest = rest[rest.index(after: close)...]
            } else {
                rest = rest[afterOpen...]
            }
        }
        return names
    }

    static func isName(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }
}
