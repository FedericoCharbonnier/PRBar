import Foundation

/// The path globs of `ignorePaths` (spec E.5). Without `/` the pattern is compared with the file name (`*.lock`);
/// with `/`, with the whole path (`generated/**`). `*` also crosses folders; a trailing `/` means the whole folder
/// and a leading `/` is ignored (paths are relative to the repo).
public enum PathGlob {
    public static func matches(_ pattern: String, path: String) -> Bool {
        var glob = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !glob.isEmpty else { return false }
        if glob.hasPrefix("/") { glob.removeFirst() }
        if glob.hasSuffix("/") { glob += "**" }
        if !glob.contains("/") {
            return fnmatch(glob, (path as NSString).lastPathComponent, 0) == 0
        }
        return fnmatch(glob, path, 0) == 0
    }
}

/// Spec E.5: hides findings according to the user's settings, after Claude's answer and deterministically. In
/// order: an ignored path, a category that's off, a severity under the minimum; then, among the visible ones the
/// filter kept, the least severe over `maxFindings` (same severity: Claude's order).
public enum ReviewOptionsFilter {
    public static func apply(_ items: [ReviewItem], options: ReviewOptions, repoIgnorePaths: [String] = []) -> [ReviewItem] {
        let patterns = ReviewOptions.normalizePatterns(options.ignorePaths + repoIgnorePaths)
        var result = items.map { item -> ReviewItem in
            guard !item.isHidden else { return item }
            if let pattern = patterns.first(where: { PathGlob.matches($0, path: item.finding.file) }) {
                return item.hiding("Ignored path (\(pattern))")
            }
            if !options.isEnabled(item.finding.category) {
                return item.hiding("Category off: \(item.finding.category.rawValue)")
            }
            if rank(item.finding.severity) < rank(options.minSeverity) {
                return item.hiding("Below the minimum severity (\(options.minSeverity.rawValue))")
            }
            return item
        }
        if let limit = options.effectiveMaxFindings {
            let visible = result.indices.filter { result[$0].keep && !result[$0].isHidden }
            let ranked = visible.sorted { a, b in
                let left = rank(result[a].finding.severity)
                let right = rank(result[b].finding.severity)
                return left != right ? left > right : a < b
            }
            for index in ranked.dropFirst(limit) {
                result[index] = result[index].hiding("Over your limit of \(limit) findings")
            }
        }
        return result
    }

    static func rank(_ severity: Severity) -> Int {
        switch severity {
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }
}
