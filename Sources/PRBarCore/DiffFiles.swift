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

    /// El fragmento de `diff` de un archivo (desde su encabezado hasta el próximo); "" si no está. Entiende los
    /// encabezados de un diff común (`diff --git a/x b/x`) y de un combined diff (`diff --cc x`, `diff --combined x`):
    /// el de Resolve Conflicts trae los dos (decisión C.9.16).
    public static func section(of diff: String, file: String) -> String {
        var kept: [String] = []
        var inside = false
        // Las líneas quedan como están (con el `\r` de un CRLF); el encabezado se compara sin él.
        for line in TextLines.split(diff, strippingCarriageReturns: false) {
            let header = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            if header.hasPrefix("diff --git ") {
                inside = header.hasSuffix(" b/\(file)")
            } else if header.hasPrefix("diff --cc ") {
                inside = header.dropFirst("diff --cc ".count) == file
            } else if header.hasPrefix("diff --combined ") {
                inside = header.dropFirst("diff --combined ".count) == file
            }
            if inside { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// Las últimas `lines` líneas de `text` (sin el salto final).
    public static func tail(_ text: String, lines: Int) -> String {
        var all = TextLines.split(text, strippingCarriageReturns: true)
        if all.last == "" { all.removeLast() }
        return all.suffix(lines).joined(separator: "\n")
    }
}

/// Remembers the last `DiffFiles.section` so a view body that re-renders (on every chat chunk or queue change)
/// doesn't split a large diff again while the same file stays selected.
public final class DiffSectionMemo {
    private var last: (diff: String, file: String, section: String)?
    public private(set) var computations = 0

    public init() {}

    public func section(of diff: String, file: String) -> String {
        if let last, last.file == file, last.diff == diff { return last.section }
        let section = DiffFiles.section(of: diff, file: file)
        computations += 1
        last = (diff, file, section)
        return section
    }
}
