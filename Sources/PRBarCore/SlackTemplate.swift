import Foundation

/// Plantillas de mensajes de Slack. Variables: {link} {title} {number} {repo} {author} y, en los mensajes de
/// ronda, {n} (el número de ronda) y, en «Merged», {method}.
/// Los valores de texto se escapan para mrkdwn (&, <, >); el texto fijo de la plantilla no,
/// así el usuario puede usar sintaxis de Slack como <@U123>.
public enum SlackTemplate {
    public static func render(_ template: String, pr: PullRequest, n: Int? = nil, method: String? = nil) -> String {
        var values: [String: String] = [
            "link": pr.url.absoluteString,
            "title": escape(pr.title),
            "number": "\(pr.number)",
            "repo": escape(pr.repo.name),
            "author": escape(pr.author),
        ]
        if let n { values["n"] = "\(n)" }
        if let method { values["method"] = escape(method) }
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

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
