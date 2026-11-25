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

    /// `git check-attr -z merge binary -- <rutas>` (`<ruta>\0<atributo>\0<valor>\0`…): las rutas que git mergea como
    /// binarias por `.gitattributes` (`binary`, `-merge` o `merge=binary`). Chocan sin marcadores: git deja la
    /// versión del PR en el árbol, y Claude no tendría nada que resolver (decisión C.9.17).
    public static func binaryByAttributes(fromCheckAttrZ output: String) -> Set<String> {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var binary = Set<String>()
        var index = 0
        while index + 2 < fields.count {
            let (path, attribute, value) = (fields[index], fields[index + 1], fields[index + 2])
            if (attribute == "binary" && value == "set") || (attribute == "merge" && (value == "unset" || value == "binary")) {
                binary.insert(path)
            }
            index += 3
        }
        return binary
    }

    /// Las rutas en conflicto que son el lado de un choque entre un archivo y una carpeta (decisión C.9.17): git
    /// guarda el archivo con otro nombre (`<ruta>~<rama>`), en el índice (`ort`: la etapa está en una ruta que no
    /// existe en ese lado) o suelto en el árbol (`untracked`, de `ls-files -o`: la ruta en conflicto es la original).
    /// `inHead`/`inBase`: las rutas en conflicto que existen en el head del PR y en la base (`ls-tree`).
    public static func directoryFileConflicts(_ entries: [IndexStageEntry], inHead: Set<String>, inBase: Set<String>,
                                              untracked: [String]) -> Set<String> {
        var found = Set<String>()
        for (path, stages) in Dictionary(grouping: entries, by: \.path) {
            let ours = stages.contains { $0.stage == 2 }, theirs = stages.contains { $0.stage == 3 }
            if (ours && !inHead.contains(path)) || (theirs && !inBase.contains(path)) { found.insert(path) }
            if untracked.contains(where: { $0.hasPrefix(path + "~") }) { found.insert(path) }
        }
        return found
    }

    /// Un `ConflictFile` por ruta, ordenados. `binary`: los candidatos que `isBinaryNumstat` marcó; `attributeBinary`:
    /// los de `binaryByAttributes`; `directoryFile`: los de `directoryFileConflicts`; `withoutMarkers`: los candidatos
    /// sin marcadores en el árbol después del merge (o sin el archivo): Claude no tendría qué resolver.
    public static func classify(_ entries: [IndexStageEntry], binary: Set<String>, attributeBinary: Set<String> = [],
                                directoryFile: Set<String> = [], withoutMarkers: Set<String> = []) -> [ConflictFile] {
        Dictionary(grouping: entries, by: \.path).map { path, group in
            let stages = Set(group.map(\.stage))
            let modes = Set(group.map(\.mode))
            let name = (path as NSString).lastPathComponent.lowercased()
            let reason: String? =
                if modes.contains("160000") { "submodule" }
                else if modes.contains("120000") { "symlink" }
                else if gitSettingsFiles.contains(name) { "git settings file" }
                else if directoryFile.contains(path) { "directory/file conflict" }
                else if !stages.contains(2) && !stages.contains(3) { "deleted on both sides" }
                else if !stages.contains(3) { stages.contains(1) ? "deleted in the base" : "added only in the PR" }
                else if !stages.contains(2) { stages.contains(1) ? "deleted in the PR" : "added only in the base" }
                else if !modes.isSubset(of: regularModes) { "file mode" }
                else if attributeBinary.contains(path) { "binary (attributes)" }
                else if binary.contains(path) { "binary" }
                else if withoutMarkers.contains(path) { "no conflict markers" }
                else { nil }
            return ConflictFile(path: path, kind: reason == nil ? .content : .byHand, reason: reason)
        }.sorted { $0.path < $1.path }
    }
}

/// Los marcadores de conflicto que quedaron (spec C.3.4, decisión C.9.4), contados con `git grep` en el índice y en
/// tres commits: así corre igual en esta Mac y en un host.
public enum ConflictMarkers {
    /// Para `git grep -E`: las líneas que git escribe en un conflicto. Siete caracteres o más: el atributo
    /// `conflict-marker-size` los agranda (decisión C.9.17). `=======` tolera espacios al final (CRLF).
    public static let patterns = ["^<{7,}( |$)", "^>{7,}( |$)", "^[|]{7,}( |$)", "^={7,}[[:space:]]*$"]

    /// Sin color (la config del usuario puede pedirlo siempre), todos los archivos como texto (`-a`: un `-diff` o
    /// `binary` en `.gitattributes`, como `yarn.lock -diff`, no los esconde), una cuenta por archivo (`-c`) y la
    /// ruta terminada en NUL (`--null`). Después va `--cached`, un commit o nada (el árbol de trabajo).
    public static var grepArguments: [String] {
        ["-c", "color.ui=never", "-c", "color.grep=never", "grep", "--no-color", "-a", "-c", "--null", "-E"]
            + patterns.flatMap { ["-e", $0] }
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

/// Una línea de `git diff-index`/`diff-tree --raw -z --no-renames --no-abbrev`: `:<modo> <modo> <sha> <sha> <estado>\0<ruta>\0`.
public struct RawDiffEntry: Equatable, Sendable {
    public let oldMode: String
    public let newMode: String
    public let oldOid: String
    public let newOid: String
    public let status: String
    public let path: String

    public static func parse(_ output: String) -> [RawDiffEntry] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var entries: [RawDiffEntry] = []
        var index = 0
        while index + 1 < fields.count {
            let header = fields[index].split(separator: " ").map(String.init)
            if header.count == 5, header[0].hasPrefix(":") {
                entries.append(RawDiffEntry(oldMode: String(header[0].dropFirst()), newMode: header[1], oldOid: header[2],
                                            newOid: header[3], status: header[4], path: fields[index + 1]))
                index += 2
            } else {
                index += 1
            }
        }
        return entries
    }

    /// El lado viejo o nuevo como entrada; nil si la ruta no está de ese lado (modo `000000`).
    var old: AutoMergeEntry? { Self.entry(path, oldMode, oldOid) }
    var new: AutoMergeEntry? { Self.entry(path, newMode, newOid) }

    private static func entry(_ path: String, _ mode: String, _ oid: String) -> AutoMergeEntry? {
        mode == "000000" ? nil : AutoMergeEntry(path: path, mode: mode, oid: oid)
    }
}

/// Decisión C.9.16: el combined diff (`diff-tree --cc`) no muestra un archivo que quedó igual a uno de los padres, así
/// que no ve, p. ej., a Claude devolviendo a la versión del PR un archivo que la base cambió sin conflicto. Antes de
/// Claude, PRBar guarda lo que dejó el merge automático (`record`); después, todo lo que difiere de eso fuera de los
/// archivos de contenido en conflicto es "un cambio fuera de los conflictos". Sin correr nada.
public enum OutsideConflicts {
    /// Una ruta fuera de los conflictos que no quedó como la dejó el merge automático. `nil` = la ruta no está.
    public struct Change: Equatable, Sendable {
        public let path: String
        public let expected: AutoMergeEntry?
        public let actual: AutoMergeEntry?

        public init(path: String, expected: AutoMergeEntry?, actual: AutoMergeEntry?) {
            self.path = path
            self.expected = expected
            self.actual = actual
        }
    }

    /// El registro, de `diff-index --cached --raw -z --no-renames --no-abbrev <startHeadOid>` justo después del merge
    /// (y de dejar la versión del PR en los "by hand"): lo que difiere del head, sin las rutas en conflicto (`U`).
    public static func record(fromDiffIndex output: String) -> [AutoMergeEntry] {
        RawDiffEntry.parse(output).filter { $0.status != "U" }.map { entry in
            entry.new ?? AutoMergeEntry(path: entry.path, mode: nil, oid: nil)
        }
    }

    /// Las rutas del registro que no aparecen en `startToHead` (`diff-tree --raw -z start HEAD`): ahí HEAD es igual
    /// al head del PR, así que no es lo del merge automático. Hay que leerlas de HEAD (`ls-tree`) para `changes`.
    public static func unlisted(record: [AutoMergeEntry]?, startToHead: String, conflicted: Set<String>) -> [String] {
        guard let record else { return [] }
        let listed = Set(RawDiffEntry.parse(startToHead).map(\.path))
        return record.map(\.path).filter { !listed.contains($0) && !conflicted.contains($0) }.sorted()
    }

    /// Lo que difiere del merge automático. Lo esperado de cada ruta es lo del registro o, si no está, lo del head del
    /// PR (el lado viejo de `startToHead`); lo que hay es el lado nuevo de `startToHead` o, para las rutas `unlisted`,
    /// lo de `headTree` (`ls-tree -z HEAD -- <esas rutas>`). Sin registro (un draft anterior) devuelve `[]`.
    public static func changes(record: [AutoMergeEntry]?, startToHead: String, headTree: String,
                               conflicted: Set<String>) -> [Change] {
        guard let record else { return [] }
        let recorded = Dictionary(record.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let raw = RawDiffEntry.parse(startToHead)
        var changes: [Change] = []
        for entry in raw where !conflicted.contains(entry.path) {
            let expected: AutoMergeEntry?
            if let automatic = recorded[entry.path] { expected = automatic.exists ? automatic : nil } else { expected = entry.old }
            let actual = entry.new
            if expected != actual { changes.append(Change(path: entry.path, expected: expected, actual: actual)) }
        }
        let inHead = Dictionary(treeEntries(headTree).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for path in unlisted(record: record, startToHead: startToHead, conflicted: conflicted) {
            let expected = recorded[path].flatMap { $0.exists ? $0 : nil }
            let actual = inHead[path]
            if expected != actual { changes.append(Change(path: path, expected: expected, actual: actual)) }
        }
        return changes.sorted { $0.path < $1.path }
    }

    /// `ls-tree -z`: `<modo> <tipo> <sha>\t<ruta>\0`.
    static func treeEntries(_ output: String) -> [AutoMergeEntry] {
        output.split(separator: "\0").compactMap { record in
            guard let tab = record.firstIndex(of: "\t") else { return nil }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3 else { return nil }
            return AutoMergeEntry(path: String(record[record.index(after: tab)...]), mode: String(fields[0]), oid: String(fields[2]))
        }
    }
}
