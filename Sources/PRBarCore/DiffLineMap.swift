import Foundation

/// Líneas comentables (lado RIGHT) por archivo, a partir de los `patch` de `GET /pulls/{n}/files`.
/// En GitHub se puede comentar en líneas agregadas y de contexto dentro de un hunk. Los archivos se buscan
/// por su nombre actual (el nuevo, si se renombró); uno borrado no tiene líneas comentables.
public struct DiffLineMap: Equatable, Sendable {
    private var lines: [String: Set<Int>] = [:]

    public init(files: [PRFile]) {
        for file in files {
            guard let patch = file.patch else { continue }
            lines[file.filename] = Self.commentableLines(in: patch)
        }
    }

    /// `file` se normaliza con `normalizePath` (sin `./` adelante).
    public func contains(file: String, line: Int) -> Bool {
        lines[Self.normalizePath(file)]?.contains(line) ?? false
    }

    /// Ruta de un hallazgo tal como la espera GitHub (relativa al repo): sin espacios alrededor, sin `./`
    /// adelante y, si Claude devolvió una ruta absoluta dentro del worktree, sin ese prefijo (también con
    /// `/private` delante, como quedan las rutas reales de `/var` y `/tmp` en macOS).
    public static func normalizePath(_ path: String, worktree: URL? = nil) -> String {
        var result = Substring(path.trimmingCharacters(in: .whitespacesAndNewlines))
        if let worktree {
            let base = worktree.standardizedFileURL.path
            let prefixes = [base, "/private" + base, worktree.resolvingSymlinksInPath().path].map { $0 + "/" }
            if let prefix = prefixes.first(where: { result.hasPrefix($0) }) { result = result.dropFirst(prefix.count) }
        }
        while result.hasPrefix("./") { result = result.dropFirst(2) }
        return String(result)
    }

    /// Recorre el patch: lo anterior al primer `@@` (`diff --git`, `---`, `+++`, …) se ignora; dentro de un
    /// hunk cuentan las líneas `+` (agregadas) y las que empiezan con un espacio (contexto). Las `-`, las
    /// `\ No newline at end of file` y las vacías (como la que deja un `\n` final) no avanzan el número de línea.
    public static func commentableLines(in patch: String) -> Set<Int> {
        var result: Set<Int> = []
        var newLine = 0
        var inHunk = false
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                // @@ -a,b +c,d @@
                guard let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }),
                      let start = Int(plus.dropFirst().split(separator: ",").first ?? "") else {
                    inHunk = false
                    continue
                }
                newLine = start
                inHunk = true
            } else if line.hasPrefix("diff --git ") {
                inHunk = false
            } else if !inHunk {
                continue
            } else if line.hasPrefix("+") || line.hasPrefix(" ") {
                result.insert(newLine)
                newLine += 1
            }
        }
        return result
    }
}
