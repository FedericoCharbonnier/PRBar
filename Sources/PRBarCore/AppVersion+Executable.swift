import Foundation

extension AppVersion {
    /// La del `PRBar.app` que contiene a `executable` (`…/PRBar.app/Contents/Helpers/prbar`, resolviendo el link de
    /// `~/.local/bin/prbar`); fuera de un bundle (`swift run PRBarCLI`), `PRBarCore.version`, como `current()`.
    public static func forExecutable(_ executable: URL) -> String {
        let contents = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else { return PRBarCore.version }
        return version
    }
}
