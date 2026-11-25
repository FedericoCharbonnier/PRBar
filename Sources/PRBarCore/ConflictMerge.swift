import Foundation

/// Una entrada del índice como la imprimen `git ls-files -s -z` y `git ls-files -u -z`: `<modo> <sha> <etapa>\t<ruta>`.
public struct IndexStageEntry: Equatable, Sendable {
    public let mode: String
    public let sha: String
    public let stage: Int
    public let path: String

    public static func parse(_ output: String) -> [IndexStageEntry] {
        output.split(separator: "\0").compactMap { record in
            guard let tab = record.firstIndex(of: "\t") else { return nil }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3, let stage = Int(fields[2]) else { return nil }
            return IndexStageEntry(mode: String(fields[0]), sha: String(fields[1]), stage: stage,
                                   path: String(record[record.index(after: tab)...]))
        }
    }
}

/// Qué conflictos resuelve Claude y cuáles quedan a mano (spec C.3.2, decisión C.9.3). Sin correr nada.
public enum ConflictClassifier {
    /// Cambian cómo git lee y escribe los demás archivos: el guardián cortaría si Claude los tocara.
    static let gitSettingsFiles: Set<String> = [".gitattributes", ".lfsconfig", ".gitmodules"]
    static let regularModes: Set<String> = ["100644", "100755"]

    public static func entries(fromLsFilesUZ output: String) -> [IndexStageEntry] { IndexStageEntry.parse(output) }

    /// Los que tienen las etapas 2 (PR) y 3 (base) con modo de archivo normal: hay que mirar si son binarios
    /// (`git diff --numstat <ours> <theirs>`). Ordenados por ruta.
    public static func contentCandidates(_ entries: [IndexStageEntry]) -> [(path: String, ours: String, theirs: String)] {
        Dictionary(grouping: entries, by: \.path).compactMap { path, stages in
            guard let ours = stages.first(where: { $0.stage == 2 }), let theirs = stages.first(where: { $0.stage == 3 }),
                  stages.allSatisfy({ regularModes.contains($0.mode) }) else { return nil }
            return (path, ours.sha, theirs.sha)
        }.sorted { $0.path < $1.path }
    }

    /// `git diff --numstat` de dos blobs dice `-\t-\t…` si alguno es binario.
    public static func isBinaryNumstat(_ output: String) -> Bool { output.hasPrefix("-\t-\t") }

    /// Un `ConflictFile` por ruta, ordenados. `binary`: los candidatos que `isBinaryNumstat` marcó.
    public static func classify(_ entries: [IndexStageEntry], binary: Set<String>) -> [ConflictFile] {
        Dictionary(grouping: entries, by: \.path).map { path, group in
            let stages = Set(group.map(\.stage))
            let modes = Set(group.map(\.mode))
            let name = (path as NSString).lastPathComponent.lowercased()
            let reason: String? =
                if modes.contains("160000") { "submodule" }
                else if modes.contains("120000") { "symlink" }
                else if gitSettingsFiles.contains(name) { "git settings file" }
                else if !stages.contains(2) && !stages.contains(3) { "deleted on both sides" }
                else if !stages.contains(3) { stages.contains(1) ? "deleted in the base" : "added only in the PR" }
                else if !stages.contains(2) { stages.contains(1) ? "deleted in the PR" : "added only in the base" }
                else if !modes.isSubset(of: regularModes) { "file mode" }
                else if binary.contains(path) { "binary" }
                else { nil }
            return ConflictFile(path: path, kind: reason == nil ? .content : .byHand, reason: reason)
        }.sorted { $0.path < $1.path }
    }
}

/// Los marcadores de conflicto que quedaron (spec C.3.4, decisión C.9.4), contados con `git grep` en el índice y en
/// tres commits: así corre igual en esta Mac y en un host.
public enum ConflictMarkers {
    /// Para `git grep -E`: las líneas que git escribe en un conflicto. `=======` tolera espacios al final (CRLF).
    public static let patterns = ["^<<<<<<<( |$)", "^>>>>>>>( |$)", "^[|]{7}( |$)", "^=======[[:space:]]*$"]

    /// Sin binarios (`-I`), una cuenta por archivo (`-c`) y la ruta terminada en NUL (`--null`). Después va
    /// `--cached` o un commit.
    public static var grepArguments: [String] {
        ["grep", "-I", "-c", "--null", "-E"] + patterns.flatMap { ["-e", $0] }
    }

    /// `ruta\0cuenta\n` por línea; contra un commit la ruta viene como `<rev>:<ruta>` y se le saca el prefijo.
    public static func counts(fromGrep output: String, revision: String?) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let count = Int(parts[1]) else { continue }
            var path = String(parts[0])
            if let revision, path.hasPrefix(revision + ":") { path.removeFirst(revision.count + 1) }
            counts[path] = count
        }
        return counts
    }

    /// Los archivos con más líneas de marcador que `max(head, base, head + base − mergeBase)`, ordenados.
    public static func leftover(after: [String: Int], head: [String: Int], base: [String: Int],
                                mergeBase: [String: Int]) -> [String] {
        after.compactMap { path, count in
            let h = head[path] ?? 0, b = base[path] ?? 0, m = mergeBase[path] ?? 0
            return count > max(h, b, h + b - m) ? path : nil
        }.sorted()
    }
}

/// Qué cambió Claude en el índice después de `add -A` (spec C.3.4): `before` es `ls-files -s -z` justo antes de Claude.
public enum ConflictIndex {
    /// Entradas de etapa 0 nuevas o con otro modo/contenido. Una ruta que antes estaba en conflicto cuenta como cambiada.
    public static func changed(before: String, after: String) -> [IndexStageEntry] {
        let old = Dictionary(IndexStageEntry.parse(before).filter { $0.stage == 0 }.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return IndexStageEntry.parse(after).filter { entry in
            guard entry.stage == 0 else { return false }
            guard let previous = old[entry.path] else { return true }
            return previous.mode != entry.mode || previous.sha != entry.sha
        }.sorted { $0.path < $1.path }
    }

    /// Symlinks y gitlinks entre los cambios: Claude no puede crearlos (como en un fix).
    public static func special(_ changed: [IndexStageEntry]) -> [String] {
        changed.filter { $0.mode == "120000" || $0.mode == "160000" }.map(\.path)
    }

    /// De `paths` (los "resolve by hand"), los que no tienen las mismas entradas que antes.
    public static func touched(_ paths: [String], before: String, after: String) -> [String] {
        func entries(_ output: String, _ path: String) -> [String] {
            IndexStageEntry.parse(output).filter { $0.path == path }.map { "\($0.mode) \($0.sha) \($0.stage)" }.sorted()
        }
        return paths.filter { entries(before, $0) != entries(after, $0) }.sorted()
    }

    /// Las rutas que siguen en conflicto (alguna etapa ≠ 0).
    public static func unmerged(_ output: String) -> [String] {
        Array(Set(IndexStageEntry.parse(output).filter { $0.stage != 0 }.map(\.path))).sorted()
    }
}
