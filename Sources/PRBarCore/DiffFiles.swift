import Foundation

/// Piezas del diff de un Respond / Fix CI para la pestaña (spec M.1 "Respond / Fix CI"): los chips de archivos, el
/// fragmento de un archivo y la cola del log de Claude.
public enum DiffFiles {
    /// Los archivos de un `git diff --stat`, en orden. Un renombre (`a => b`) da el nombre nuevo; la línea de resumen
    /// ("3 files changed…") no cuenta.
    public static func files(stat: String) -> [String] {
        stat.split(separator: "\n").compactMap { line in
            guard let bar = line.range(of: " | ") else { return nil }
            var path = line[..<bar.lowerBound].trimmingCharacters(in: .whitespaces)
            if let arrow = path.range(of: " => ") { path = String(path[arrow.upperBound...]) }
            return path.isEmpty ? nil : path
        }
    }

    /// El fragmento de `diff` de un archivo (desde su `diff --git` hasta el próximo); "" si no está.
    public static func section(of diff: String, file: String) -> String {
        var kept: [Substring] = []
        var inside = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { inside = line.hasSuffix(" b/\(file)") }
            if inside { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// Las últimas `lines` líneas de `text` (sin el salto final).
    public static func tail(_ text: String, lines: Int) -> String {
        var all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if all.last == "" { all.removeLast() }
        return all.suffix(lines).joined(separator: "\n")
    }
}
