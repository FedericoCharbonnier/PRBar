import Foundation

/// Encuentra los plugins de Claude Code de los skills configurados (`ClaudeSettings`). Como las corridas usan
/// `--setting-sources ""` (sin la configuración del usuario), los plugins no se cargan solos: se pasan con
/// `--plugin-dir`, solo los de los skills elegidos.
public enum ClaudePlugins {
    /// `~/.claude/plugins/cache`: un plugin vive en `<cache>/<marketplace>/<plugin>/<versión>`.
    public static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plugins/cache", isDirectory: true)
    }

    /// Un directorio por plugin de `skills` (el prefijo `plugin:`), sin repetir y en el orden de los skills. Los
    /// skills sin prefijo no cargan ningún plugin. Lanza `claudePluginMissing` con el primero que falte.
    public static func locate(skills: [String], in cache: URL = defaultCacheDirectory) throws -> [String] {
        let installs = installed(in: cache)
        var directories: [String] = []
        var seen: Set<String> = []
        for skill in skills {
            guard let plugin = ClaudeSettings.plugin(of: skill), seen.insert(plugin).inserted else { continue }
            guard let directory = installs[plugin] else { throw PRBarError.claudePluginMissing(plugin: plugin, skill: skill) }
            directories.append(directory.path)
        }
        return directories
    }

    /// Cada plugin instalado (en cualquier marketplace) con su instalación más reciente.
    public static func installed(in cache: URL = defaultCacheDirectory) -> [String: URL] {
        var newest: [String: URL] = [:]
        for marketplace in subdirectories(of: cache) {
            for plugin in subdirectories(of: marketplace) {
                guard let install = newestInstall(of: plugin.lastPathComponent, in: marketplace) else { continue }
                let name = plugin.lastPathComponent
                if let current = newest[name], !isNewer(install, than: current) { continue }
                newest[name] = install
            }
        }
        return newest
    }

    /// La versión instalada modificada más recientemente (`<marketplace>/<name>/<versión>`) que tenga
    /// `.claude-plugin`, `skills`, `commands` o `agents`. Las versiones cambian con cada actualización.
    static func newestInstall(of name: String, in marketplace: URL) -> URL? {
        let installs = subdirectories(of: marketplace.appendingPathComponent(name, isDirectory: true)).filter { child in
            [".claude-plugin", "skills", "commands", "agents"].contains { isDirectory(child.appendingPathComponent($0)) }
        }
        return installs.max { b, a in isNewer(a, than: b) }
    }

    private static func isNewer(_ a: URL, than b: URL) -> Bool {
        (modified(a), a.lastPathComponent) > (modified(b), b.lastPathComponent)
    }

    /// Las carpetas (no ocultas) de `parent`, con rutas armadas desde `parent` para conservar su forma
    /// (`contentsOfDirectory` resuelve `/var` → `/private/var`).
    static func subdirectories(of parent: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.sorted().filter { !$0.hasPrefix(".") }
            .map { parent.appendingPathComponent($0, isDirectory: true) }
            .filter(isDirectory)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
