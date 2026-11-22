import Foundation

/// Links `prbar://` (spec M.4): `prbar://pr/<owner>/<repo>/<number>[/<tab>]`, `prbar://review`, `prbar://mine`,
/// `prbar://history`, `prbar://activity`. También entiende el `?screen=` de los links del iPhone.
public enum PRBarURL {
    public static let scheme = "prbar"

    /// nil: no es de PRBar o no se entiende (la app abre la ventana sin moverse).
    public static func destination(_ url: URL) -> MainDestination? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme, let host = components.host?.lowercased() else { return nil }
        let parts = components.path.split(separator: "/").compactMap { String($0).removingPercentEncoding }
        switch host {
        case "review": return parts.isEmpty ? .list(.toReview) : nil
        case "mine": return parts.isEmpty ? .list(.myPRs) : nil
        case "history": return parts.isEmpty ? .history(recordID: nil) : nil
        case "activity": return parts.isEmpty ? .activity : nil
        case "pr":
            guard parts.count == 3 || parts.count == 4, PRReference.isValidName(parts[0]),
                  PRReference.isValidName(parts[1]), let number = Int(parts[2]), number > 0 else { return nil }
            let screen = components.queryItems?.first { $0.name == "screen" }?.value
            let tabName = parts.count == 4 ? parts[3] : screen
            var tab: PRTab?
            if let tabName {
                guard let parsed = PRTab(urlName: tabName) else { return nil }
                tab = parsed
            }
            return .pr(prID: "\(parts[0])/\(parts[1])#\(number)", tab: tab)
        default:
            return nil
        }
    }

    public static func url(for destination: MainDestination) -> URL? {
        switch destination {
        case .list(.toReview): URL(string: "prbar://review")
        case .list(.myPRs): URL(string: "prbar://mine")
        case .history: URL(string: "prbar://history")
        case .activity: URL(string: "prbar://activity")
        case .pr(let prID, let tab):
            prURL(prID, tab: tab)
        }
    }

    /// `owner/repo#N` → `prbar://pr/owner/repo/N[/tab]`.
    private static func prURL(_ prID: String, tab: PRTab?) -> URL? {
        let parts = prID.split(separator: "#")
        guard parts.count == 2 else { return nil }
        return URL(string: "prbar://pr/\(parts[0])/\(parts[1])" + (tab.map { "/\($0.urlName)" } ?? ""))
    }
}
