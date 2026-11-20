import Foundation

/// Endurecimiento de los `git` que corre PRBar sobre árboles que no controla: el código de un PR ajeno (review,
/// spec §8.2) o lo que acaba de escribir Claude (Responder, spec §14). Ningún hook corre (ni los del usuario ni
/// los que un gestor como lefthook arme a partir del árbol), no corre `core.fsmonitor` (un comando de la config,
/// p. ej. la de un repo anidado), no se recorre ningún submódulo, no se usa la caché de archivos sin trackear,
/// LFS no baja nada y git nunca pide credenciales. `status` y `diff` además llevan `--ignore-submodules=all`.
/// El único `git` de PRBar sin esto es el push de Responder, que corre los hooks del usuario a propósito.
public enum GitHardening {
    public static let arguments = [
        "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
        "-c", "submodule.recurse=false", "-c", "core.untrackedCache=false",
    ]
    /// Para `status` y `diff`.
    public static let ignoreSubmodules = "--ignore-submodules=all"
    public static let environment = ["GIT_LFS_SKIP_SMUDGE": "1", "GIT_TERMINAL_PROMPT": "0"]
}

/// Lo que PRBar revisa en un worktree, sin correr git, antes de confiar en él después de una corrida de Claude
/// (spec §14.3): `.git` anidados (C2), cambios que git no muestra (archivos ignorados, C3), qué quedó en el índice
/// y de dónde sale la config de git (I5).
public enum WorktreeIntegrity {
    // MARK: - .git anidados

    /// Las rutas (relativas, ordenadas) de toda entrada llamada `.git` (archivo, carpeta o link) dentro de `root`,
    /// salvo el `.git` de arriba de todo. Un `.git` anidado convierte una carpeta en un repo (o, con `gitdir:`, la
    /// apunta a otro git dir) cuya config —`core.fsmonitor`, hooks— puede correr en cualquier `git` siguiente.
    /// No sigue symlinks.
    public static func nestedGitEntries(in root: URL) -> [String] {
        var found: [String] = []
        walk(root) { relative, isDirectory in
            if (relative as NSString).lastPathComponent == ".git" { found.append(relative) }
            return true
        }
        return found.sorted()
    }

    // MARK: - Snapshot

    /// Estado de cada archivo (y link) del worktree, sin el `.git` de arriba: tipo, tamaño, fecha de modificación
    /// (en nanosegundos) e inodo, con `lstat`. Sirve para ver cambios que `git status` no muestra.
    public struct Snapshot: Equatable, Sendable {
        public struct Entry: Equatable, Sendable {
            public let type: UInt16
            public let size: Int64
            public let modified: Int64
            public let inode: UInt64

            public init(type: UInt16, size: Int64, modified: Int64, inode: UInt64) {
                self.type = type
                self.size = size
                self.modified = modified
                self.inode = inode
            }
        }

        public let entries: [String: Entry]
        /// Las claves de `entries` van en NFC (para compararlas con lo que muestra git). En un disco que distingue
        /// formas (Linux), el nombre real en bytes puede ser otro: acá, por clave, cuando difiere.
        public let rawPaths: [String: String]

        public init(entries: [String: Entry], rawPaths: [String: String] = [:]) {
            self.entries = entries
            self.rawPaths = rawPaths
        }

        /// El nombre real de `key` (para borrarlo), o la clave misma.
        public func rawPath(_ key: String) -> String { rawPaths[key] ?? key }

        public static func take(_ root: URL) -> Snapshot {
            var entries: [String: Entry] = [:]
            let base = root.path
            walk(root) { relative, isDirectory in
                guard !isDirectory else { return true }
                var info = stat()
                guard lstat(base + "/" + relative, &info) == 0 else { return true }
                entries[relative] = Entry(
                    type: UInt16(info.st_mode & S_IFMT), size: Int64(info.st_size),
                    modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                    inode: UInt64(info.st_ino))
                return true
            }
            return Snapshot(entries: entries)
        }

        /// Altas, modificaciones y bajas desde `self`, cada una ordenada.
        public func changes(to after: Snapshot) -> Changes {
            Changes(
                added: after.entries.keys.filter { entries[$0] == nil }.sorted(),
                modified: after.entries.compactMap { key, value in entries[key].map { $0 == value ? nil : key } ?? nil }.sorted(),
                removed: entries.keys.filter { after.entries[$0] == nil }.sorted())
        }
    }

    public struct Changes: Equatable, Sendable {
        public let added: [String]
        public let modified: [String]
        public let removed: [String]

        public var all: [String] { (added + modified + removed).sorted() }
        public var isEmpty: Bool { added.isEmpty && modified.isEmpty && removed.isEmpty }
    }

    // MARK: - git status, índice y config

    /// Las rutas que `git status --porcelain -z --no-renames --untracked-files=all --ignored=matching` muestra como
    /// cambios (todo menos `!!`, los ignorados). En NFC, como las del snapshot.
    public static func visibleChanges(fromStatusZ output: String) -> Set<String> {
        Set(output.split(separator: "\0", omittingEmptySubsequences: true).compactMap { entry -> String? in
            guard entry.count > 3, !entry.hasPrefix("!!") else { return nil }
            return String(entry.dropFirst(3)).precomposedStringWithCanonicalMapping
        })
    }

    /// Las rutas que `git status --porcelain -z ... --ignored=matching` muestra como ignoradas (`!!`), en NFC. Una
    /// carpeta ignorada entera viene como una sola entrada con `/` al final (`build/`).
    public static func ignoredPaths(fromStatusZ output: String) -> Set<String> {
        Set(output.split(separator: "\0", omittingEmptySubsequences: true).compactMap { entry -> String? in
            guard entry.count > 3, entry.hasPrefix("!!") else { return nil }
            return String(entry.dropFirst(3)).precomposedStringWithCanonicalMapping
        })
    }

    /// Si `path` está en `ignored` (de `ignoredPaths`) o dentro de una carpeta que está.
    public static func isIgnored(_ path: String, in ignored: Set<String>) -> Bool {
        if ignored.contains(path) { return true }
        var components = path.split(separator: "/").dropLast()
        while !components.isEmpty {
            if ignored.contains(components.joined(separator: "/") + "/") { return true }
            components = components.dropLast()
        }
        return false
    }

    /// Archivos que macOS crea solo (Finder, Spotlight): `.DS_Store`, AppleDouble (`._*`) e `Icon\r`.
    public static func isMacMetadata(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == "Icon\r"
    }

    /// Las rutas que `git diff --cached --raw -z --no-renames` deja con modo nuevo `160000` (gitlink: un repo
    /// anidado) o `120000` (symlink: puede apuntar fuera del repo). Formato: `:<modo> <modo> <sha> <sha> <estado>\0<ruta>\0`.
    public static func specialStagedPaths(fromRawZ output: String) -> [String] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var paths: [String] = []
        var index = 0
        while index + 1 < fields.count {
            let header = fields[index].split(separator: " ")
            if header.count >= 2, ["160000", "120000"].contains(header[1]) { paths.append(fields[index + 1]) }
            index += 2
        }
        return paths
    }

    /// Los archivos de config de `git config --list --show-origin -z` que están dentro de `worktree` (sin contar su
    /// `.git`): config que se puede cambiar editando el árbol (p. ej. un `include.path` que apunta a un archivo
    /// del repo). Las rutas relativas son relativas a `worktree` (el `-C` del comando).
    public static func configOriginsInside(_ output: String, worktree: URL) -> [String] {
        let root = worktree.standardizedFileURL.path
        let realRoot = worktree.resolvingSymlinksInPath().standardizedFileURL.path
        var found: [String] = []
        for field in output.split(separator: "\0", omittingEmptySubsequences: true) where field.hasPrefix("file:") {
            let raw = String(field.dropFirst("file:".count))
            let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : worktree.appendingPathComponent(raw)
            let paths = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
            let inside = paths.contains { path in
                [root, realRoot].contains { root in
                    path.hasPrefix(root + "/") && !path.hasPrefix(root + "/.git/") && path != root + "/.git"
                }
            }
            if inside && !found.contains(paths[0]) { found.append(paths[0]) }
        }
        return found
    }

    // MARK: - Recorrido

    /// Todos los nombres de una carpeta salvo `.` y `..`, con `readdir`: `FileManager.contentsOfDirectory` esconde
    /// los que empiezan con `._` (AppleDouble), y ahí puede haber un `._x/.git` o un archivo plantado.
    static func directoryNames(_ path: String) -> [String]? {
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let bytes = raw.prefix(Int(entry.pointee.d_namlen))
                return String(decoding: bytes, as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Recorre `root` sin seguir symlinks ni entrar en el `.git` de arriba. `visit(relativa, esCarpeta)`; si
    /// devuelve false no se entra en esa carpeta. Las rutas van en NFC (git en macOS usa precomposeunicode).
    static func walk(_ root: URL, visit: (String, Bool) -> Bool) {
        var stack: [String] = [""]
        let base = root.path
        while let relative = stack.popLast() {
            let path = relative.isEmpty ? base : base + "/" + relative
            guard let names = directoryNames(path) else { continue }
            for name in names {
                if relative.isEmpty && name == ".git" { continue }
                let child = (relative.isEmpty ? name : relative + "/" + name).precomposedStringWithCanonicalMapping
                var info = stat()
                guard lstat(path + "/" + name, &info) == 0 else { continue }
                let isDirectory = info.st_mode & S_IFMT == S_IFDIR
                if visit(child, isDirectory) && isDirectory {
                    stack.append(relative.isEmpty ? name : relative + "/" + name)
                }
            }
        }
    }
}
