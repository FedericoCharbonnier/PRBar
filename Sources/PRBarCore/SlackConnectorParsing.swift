import Foundation

/// Lo que devolvió una herramienta de escritura del conector de Slack. Los formatos de `slack_send_message` y
/// `slack_add_reaction` no están verificados en vivo, así que se aceptan todos los plausibles y lo que no se
/// reconoce queda `uncertain`: nunca se da por hecho algo sin evidencia (spec §17.5).
public enum ConnectorWriteOutcome: Equatable, Sendable {
    /// Hecho. `ts` (del mensaje publicado) y `channel` cuando el resultado los trae.
    case done(ts: String?, channel: String?)
    case failed(PRBarError)
    /// No se sabe si se hizo.
    case uncertain
}

public enum ConnectorResultParser {
    /// Códigos de Slack que se reconocen en el texto de un error (los más específicos primero).
    public static let knownErrorCodes = [
        "already_reacted", "invalid_name", "message_not_found", "thread_not_found", "channel_not_found",
        "not_in_channel", "is_archived", "msg_too_long", "no_text", "restricted_action", "missing_scope",
        "invalid_auth", "token_revoked", "not_authed", "account_inactive", "too_many_reactions", "cant_update_message",
        "user_not_found", "invalid_ts", "invalid_thread_ts",
    ]

    // MARK: - Escrituras

    public static func parseSend(_ text: String, isError: Bool, now: Date) -> ConnectorWriteOutcome {
        let scan = Scan(text)
        if isError { return .failed(error(in: scan, now: now) ?? .slack("connector_error")) }
        if let explicit = scan.explicitError { return .failed(code(explicit, now: now)) }
        if let ts = scan.ts { return .done(ts: ts, channel: scan.channel) }
        if let error = error(in: scan, now: now) { return .failed(error) }
        if scan.ok == true { return .done(ts: nil, channel: scan.channel) }
        return .uncertain
    }

    public static func parseReaction(_ text: String, isError: Bool, now: Date) -> ConnectorWriteOutcome {
        let scan = Scan(text)
        let found = scan.explicitError.map { code($0, now: now) } ?? error(in: scan, now: now)
        if found == .slack("already_reacted") { return .done(ts: nil, channel: nil) }
        if let found { return .failed(found) }
        if isError { return .failed(.slack("connector_error")) }
        if scan.ok == true { return .done(ts: nil, channel: nil) }
        if matches(scan.plain, #"(?i)\b(fail(ed|ure)?|error|unable|could ?n[o']t|cannot|can't|denied|not allowed)\b"#) {
            return .failed(.slack("connector_error"))
        }
        if matches(scan.plain, #"(?i)\b(reaction (was )?added|added (the |a )?(reaction|emoji)|reacted|success(ful(ly)?)?)\b"#) {
            return .done(ts: nil, channel: nil)
        }
        return .uncertain
    }

    /// Error de una herramienta de lectura (o cualquier resultado marcado como error).
    public static func readError(_ text: String, now: Date) -> PRBarError {
        let scan = Scan(text)
        if let explicit = scan.explicitError { return code(explicit, now: now) }
        return error(in: scan, now: now) ?? .slack("connector_error")
    }

    /// El resultado de una lectura dice que falló aunque el MCP no lo marcó (`"ok": false` o una clave `error`).
    static func reportsError(_ text: String) -> Bool {
        let scan = Scan(text)
        return scan.explicitError != nil || scan.ok == false
    }

    // MARK: - Lecturas

    /// Mensajes de `slack_read_channel` / `slack_read_thread` en el formato real del conector (fixture grabado):
    /// `=== Message from Nombre <email> (Uxxx) at fecha ===`, `Message TS: …`, el texto y las líneas de metadatos.
    /// `nil` si el formato no se reconoce (quien llama usa otra vía); `[]` si es el formato pero sin mensajes.
    public static func parseMessages(_ text: String) -> [SlackMessage]? {
        let object = jsonObject(text)
        let body = (object?["messages"] as? String) ?? (object?["result"] as? String) ?? (object == nil ? text : "")
        let lines = body.components(separatedBy: "\n")
        var messages: [SlackMessage] = []
        var current: (user: String?, ts: String?, body: [String])?
        func flush() {
            guard let block = current, let ts = block.ts else { return }
            let content = block.body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(SlackMessage(ts: ts, text: content, linkedURLs: urls(in: content), user: block.user))
        }
        var sawHeader = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("==="), trimmed.hasSuffix("==="), trimmed.count > 6 {
                flush()
                sawHeader = true
                current = (firstMatch(trimmed, #"\(([UWB][A-Z0-9]{2,})\)"#), nil, [])
                continue
            }
            guard current != nil else { continue }
            if current?.ts == nil, let ts = firstMatch(trimmed, #"^(?:Message )?TS:\s*(\d{10}\.\d{6})$"#) {
                current?.ts = ts
                continue
            }
            if metadataPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }
            current?.body.append(line)
        }
        flush()
        if sawHeader { return messages }
        // El formato conocido, sin mensajes (`messages` vacío o un aviso sin bloques).
        return object?["messages"] != nil ? [] : nil
    }

    private static let metadataPrefixes = ["Thread:", "Reactions:", "Files:", "Thread TS:", "Reply Count:", "Replies:"]

    /// URLs del texto: `<url|label>`, `<url>` y URLs sueltas, sin repetir y en orden.
    static func urls(in text: String) -> [String] {
        var found: [String] = []
        for pattern in [#"<(https?://[^|>\s]+)(?:\|[^>]*)?>"#, #"(?<![<|])\bhttps?://[^\s<>|*]+"#] {
            for match in allMatches(text, pattern) where !found.contains(match) { found.append(match) }
        }
        return found
    }

    // MARK: - Búsqueda en el resultado

    /// Lo que se puede leer de un resultado, en cualquier formato: JSON (anidado en `result` u otras claves, incluso
    /// como string con JSON adentro) o texto.
    struct Scan {
        var ok: Bool?
        var explicitError: String?
        var ts: String?
        var channel: String?
        /// Todo el texto (crudo y strings del JSON, sin escapes `\/`).
        var plain: String

        init(_ text: String) {
            var strings: [String] = [text.replacingOccurrences(of: "\\/", with: "/")]
            var objects: [[String: Any]] = []
            func walk(_ value: Any, depth: Int) {
                guard depth < 5 else { return }
                if let object = value as? [String: Any] {
                    objects.append(object)
                    for key in object.keys.sorted() { walk(object[key] as Any, depth: depth + 1) }
                } else if let array = value as? [Any] {
                    for item in array { walk(item, depth: depth + 1) }
                } else if let string = value as? String {
                    strings.append(string)
                    if let nested = ConnectorResultParser.jsonValue(string) { walk(nested, depth: depth + 1) }
                }
            }
            if let root = ConnectorResultParser.jsonValue(text) { walk(root, depth: 0) }
            plain = strings.joined(separator: "\n")
            var tsCandidate: String?
            for object in objects {
                if ok == nil, let value = object["ok"] as? Bool { ok = value }
                if explicitError == nil, let value = object["error"] as? String, !value.isEmpty { explicitError = value }
                if explicitError == nil, object["error"] as? Bool == true { explicitError = "connector_error" }
                if tsCandidate == nil {
                    for key in ["ts", "message_ts"] {
                        if let value = ConnectorResultParser.tsValue(object[key]) { tsCandidate = value; break }
                    }
                }
                if channel == nil {
                    for key in ["channel", "channel_id"] {
                        if let value = object[key] as? String, ConnectorResultParser.isChannelID(value) { channel = value; break }
                    }
                }
            }
            if ok == false, explicitError == nil { explicitError = "connector_error" }
            // Permalink: `…/archives/<C>/p<16 dígitos>` → canal y ts (del mensaje, no el `thread_ts` del query).
            if let link = ConnectorResultParser.permalink(in: plain) {
                if tsCandidate == nil { tsCandidate = link.ts }
                if channel == nil { channel = link.channel }
            }
            if tsCandidate == nil {
                tsCandidate = ConnectorResultParser.firstMatch(
                    plain, #"(?i)(?<![A-Za-z0-9_])(?:message[ _]ts|ts|timestamp)"?\s*[:=]\s*"?(\d{10}\.\d{6})"#
                )
            }
            ts = tsCandidate
        }
    }

    static func permalink(in text: String) -> (channel: String, ts: String)? {
        let pattern = #"/archives/([A-Z0-9]{2,})/p(\d{10})(\d{6})(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let channel = Range(match.range(at: 1), in: text), let seconds = Range(match.range(at: 2), in: text),
              let micros = Range(match.range(at: 3), in: text) else { return nil }
        return (String(text[channel]), "\(text[seconds]).\(text[micros])")
    }

    static func tsValue(_ value: Any?) -> String? {
        if let string = value as? String, string.range(of: #"^\d{10}\.\d{6}$"#, options: .regularExpression) != nil { return string }
        return nil
    }

    static func isChannelID(_ value: String) -> Bool {
        value.range(of: #"^[CDG][A-Z0-9]+$"#, options: .regularExpression) != nil
    }

    private static func error(in scan: Scan, now: Date) -> PRBarError? {
        let lowered = scan.plain.lowercased()
        if let code = knownErrorCodes.first(where: { lowered.contains($0) }) { return .slack(code) }
        if lowered.contains("ratelimited") || lowered.contains("rate limit") || lowered.contains("rate_limited") {
            return .rateLimited(resetAt: now.addingTimeInterval(60))
        }
        return nil
    }

    /// Un código explícito (`"error": "…"`): los conocidos tal cual, cualquier otro con forma de código también;
    /// un texto libre cae en `connector_error`.
    private static func code(_ raw: String, now: Date) -> PRBarError {
        let lowered = raw.lowercased()
        if let known = knownErrorCodes.first(where: { lowered.contains($0) }) { return .slack(known) }
        if lowered.contains("ratelimited") || lowered.contains("rate_limited") { return .rateLimited(resetAt: now.addingTimeInterval(60)) }
        if raw.range(of: #"^[a-z_]{3,60}$"#, options: .regularExpression) != nil { return .slack(raw) }
        return .slack("connector_error")
    }

    static func jsonValue(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func jsonObject(_ text: String) -> [String: Any]? { jsonValue(text) as? [String: Any] }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: text) else { return nil }
        return String(text[range])
    }

    static func allMatches(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: text).map { String(text[$0]) }
        }
    }
}

/// Texto de Slack comparable con el que mandó PRBar: sin el formato de links (`<url|label>` → `url`), sin
/// entidades HTML y con los espacios colapsados.
public enum SlackText {
    public static func comparable(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: #"<((?:https?|mailto):[^|>]+)(?:\|[^>]*)?>"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1")
        }
        result = result.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
