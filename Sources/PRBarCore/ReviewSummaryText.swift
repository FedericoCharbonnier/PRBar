import Foundation

/// Textos de la ventana de Review que dependen de qué se va a publicar (puros, para poder testearlos).
public enum ReviewSummaryText {
    /// Cantidad de comentarios que se publicarían: los hallazgos elegidos más 1 si hay comentario general.
    public static func commentCount(inline: Int, hasGeneral: Bool) -> Int {
        max(inline, 0) + (hasGeneral ? 1 : 0)
    }

    /// El ítem "aprobar con lo elegido" del menú Approve (el botón siempre dice "Approve"): "Approve…" sin nada
    /// para publicar, o "Approve with N Comment(s)…". Termina en "…" porque pide confirmación.
    public static func approveWithCommentsItem(inline: Int, hasGeneral: Bool) -> String {
        switch commentCount(inline: inline, hasGeneral: hasGeneral) {
        case 0: "Approve…"
        case 1: "Approve with 1 Comment…"
        case let count: "Approve with \(count) Comments…"
        }
    }

    /// El mensaje de la confirmación de Approve, p. ej. "Approve r#123 as @me with 3 inline comments and a
    /// general comment?".
    public static func approval(repo: String, number: Int, account: String, inline: Int, hasGeneral: Bool) -> String {
        var parts: [String] = []
        if inline > 0 { parts.append(inline == 1 ? "1 inline comment" : "\(inline) inline comments") }
        if hasGeneral { parts.append("a general comment") }
        let what = parts.isEmpty ? "no comments" : parts.joined(separator: " and ")
        return "Approve \(repo)#\(number) as @\(account) with \(what)?"
    }
}
