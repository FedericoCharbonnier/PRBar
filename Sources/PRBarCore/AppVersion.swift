import Foundation

/// La versión de PRBar que está corriendo y el pedido `PRBar --version` (spec D.1, D.3 paso 4).
public enum AppVersion {
    /// `CFBundleShortVersionString` del bundle; sin bundle (`swift run`), `PRBarCore.version`.
    public static func current(bundle: Bundle = .main) -> String {
        guard let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !short.isEmpty else { return PRBarCore.version }
        return short
    }

    /// `CFBundleVersion` (número de build creciente); `nil` sin bundle.
    public static func build(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// `arguments[0]` es el ejecutable. macOS puede agregar argumentos propios (`-psn_…`), por eso se busca en todos.
    public static func isVersionRequest(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains("--version")
    }

    /// Lo que imprime `PRBar --version`. `UpdateVerifier` exige exactamente esta línea.
    public static func versionLine(_ version: String) -> String {
        "PRBar \(version)"
    }
}
