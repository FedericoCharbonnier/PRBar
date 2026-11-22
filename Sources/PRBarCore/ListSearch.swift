import Foundation

/// Búsqueda de la lista y de History (spec M.1, ⌘F): cada palabra tiene que aparecer en algún campo, sin distinguir
/// mayúsculas ni acentos. "#482" y "482" buscan también por número (prefijo).
public enum ListSearch {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func matches(fields: [String], number: Int?, query: String) -> Bool {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = fields.map(fold)
        return words.allSatisfy { word in
            if haystack.contains(where: { $0.contains(word) }) { return true }
            let digits = word.hasPrefix("#") ? String(word.dropFirst()) : word
            guard let number, !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return false }
            return String(number).hasPrefix(digits)
        }
    }

    /// Título, `repo#N`, `owner/repo`, autor (login y nombre) y rama.
    public static func matches(_ pr: PullRequest, query: String) -> Bool {
        matches(fields: [pr.title, "\(pr.repo.name)#\(pr.number)", pr.repo.fullName, pr.author, pr.authorName ?? "",
                         pr.headRef],
                number: pr.number, query: query)
    }
}
