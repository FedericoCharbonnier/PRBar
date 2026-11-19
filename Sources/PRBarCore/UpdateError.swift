import Foundation

/// Por qué no se pudo instalar una actualización (spec D.3). Si pasa cualquiera de estos, el `.app` instalado
/// queda como estaba (salvo `relaunchFailed`, que llega cuando la versión nueva ya está instalada).
public enum UpdateError: Error, Equatable, Sendable, LocalizedError {
    case notInstalledAsApp
    case alreadyInstalling
    case notWritable(String)
    case invalidTag(String)
    case tagMissing(String)
    case tagNotOnMain(String)
    case buildFailed(status: Int32)
    case appMissing(String)
    case versionMismatch(expected: String, found: String)
    case bundleIdentifierMismatch(expected: String, found: String)
    case launchCheckFailed(String)
    /// El texto ya dice qué pasó y en qué estado quedó la app.
    case replaceFailed(String)
    case relaunchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalledAsApp:
            "Updates need PRBar.app. Install it with Scripts/bundle.sh --install."
        case .alreadyInstalling:
            "An update is already being installed."
        case .notWritable(let folder):
            "PRBar can't replace itself in \(folder). Move PRBar.app to ~/Applications and try again."
        case .invalidTag(let tag):
            "The release tag \"\(tag)\" isn't a version."
        case .tagMissing(let tag):
            "The tag \(tag) isn't in the repository."
        case .tagNotOnMain(let tag):
            "The tag \(tag) isn't on the main branch, so PRBar won't install it."
        case .buildFailed(let status):
            "The build failed (code \(status)). Show Log has the details."
        case .appMissing(let path):
            "The build didn't produce a usable PRBar.app (\(path))."
        case .versionMismatch(let expected, let found):
            "The new app says it's version \(found.isEmpty ? "unknown" : found), not \(expected)."
        case .bundleIdentifierMismatch(let expected, let found):
            "The new app's bundle identifier is \(found.isEmpty ? "missing" : found), not \(expected)."
        case .launchCheckFailed(let detail):
            "The new app didn't start correctly (\(detail))."
        case .replaceFailed(let message):
            message
        case .relaunchFailed(let version):
            "PRBar \(version) is installed. Quit PRBar and open it again to finish."
        }
    }
}
