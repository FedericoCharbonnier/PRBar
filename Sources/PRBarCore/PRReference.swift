import Foundation

/// Cómo la CLI nombra un PR (spec C.4): `owner/repo#N`, `repo#N` (si es único) o la URL del PR.
public enum PRReference: Equatable, Sendable {
    case full(owner: String, repo: String, number: Int)
    case short(repo: String, number: Int)

    public enum ResolveError: Error, Equatable, Sendable {
        case notFound
        /// Varios PRs con el mismo `repo#N` en owners distintos (ordenados).
        case ambiguous([String])
    }

    public static func parse(_ text: String) -> PRReference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host?.lowercased() {
            guard host == "github.com" || host == "www.github.com" else { return nil }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]), number > 0,
                  isValidName(parts[0]), isValidName(parts[1]) else { return nil }
            return .full(owner: parts[0], repo: parts[1], number: number)
        }
        guard let hash = trimmed.lastIndex(of: "#"), let number = Int(trimmed[trimmed.index(after: hash)...]),
              number > 0 else { return nil }
        let pieces = trimmed[..<hash].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if pieces.count == 1, isValidName(pieces[0]) { return .short(repo: pieces[0], number: number) }
        if pieces.count == 2, isValidName(pieces[0]), isValidName(pieces[1]) {
            return .full(owner: pieces[0], repo: pieces[1], number: number)
        }
        return nil
    }

    /// Nombre de owner o repo de GitHub: letras, números, `-`, `_` y `.`.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// El id (`owner/repo#N`) entre `candidates`, sin distinguir mayúsculas.
    public func resolve(among candidates: [String]) -> Result<String, ResolveError> {
        let unique = Array(Set(candidates))
        switch self {
        case .full(let owner, let repo, let number):
            let wanted = "\(owner)/\(repo)#\(number)".lowercased()
            if let match = unique.first(where: { $0.lowercased() == wanted }) { return .success(match) }
            return .failure(.notFound)
        case .short(let repo, let number):
            let suffix = "/\(repo)#\(number)".lowercased()
            let matches = unique.filter { $0.lowercased().hasSuffix(suffix) }.sorted()
            switch matches.count {
            case 0: return .failure(.notFound)
            case 1: return .success(matches[0])
            default: return .failure(.ambiguous(matches))
            }
        }
    }

    /// `owner/repo#N` → `https://github.com/owner/repo/pull/N`.
    public static func githubURL(prID: String) -> URL? {
        guard case .full(let owner, let repo, let number)? = parse(prID) else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")
    }
}
