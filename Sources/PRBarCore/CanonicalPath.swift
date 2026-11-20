import Foundation

/// Una sola forma de nombrar una carpeta de PRBar para compararla (revisión del plan 13): `realpath(3)` de la carpeta
/// que la contiene + su nombre. Así `/var/...` y `/private/var/...`, un `worktreeDir` que es un symlink o una ruta con
/// otras mayúsculas (APFS no las distingue; `realpath` de Darwin devuelve las del disco) dan la misma clave. Nunca
/// sigue un symlink en la **última** componente: el link y lo que apunta son cosas distintas.
public enum CanonicalPath {
    /// La clave canónica de `path`. Si la carpeta que la contiene no existe, la ruta estandarizada.
    public static func of(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path != "/" else { return "/" }
        if isLink(url.path) {
            guard let parent = realPath(url.deletingLastPathComponent().path) else { return url.path }
            return (parent as NSString).appendingPathComponent(url.lastPathComponent)
        }
        if let full = realPath(url.path) { return full }
        guard let parent = realPath(url.deletingLastPathComponent().path) else { return url.path }
        return (parent as NSString).appendingPathComponent(url.lastPathComponent)
    }

    /// `realpath(3)`, o nil si no existe.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `(st_dev, st_ino)` de `lstat`: identifica la carpeta aunque se la nombre por otra ruta.
    public struct Identity: Hashable, Sendable {
        let device: Int64
        let inode: UInt64
    }

    public static func identity(_ path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// Existe y es una carpeta de verdad (`lstat`: un symlink a una carpeta no cuenta).
    public static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Existe algo en `path` (sin seguir un symlink final).
    public static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }
}
