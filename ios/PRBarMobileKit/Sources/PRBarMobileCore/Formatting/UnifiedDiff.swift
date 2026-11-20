import Foundation

/// A unified diff split into files and lines for `respond:diff`.
public struct DiffFile: Identifiable, Equatable, Sendable {
    public enum LineKind: Equatable, Sendable { case context, addition, deletion, hunk }

    public struct Line: Identifiable, Equatable, Sendable {
        public var id: Int
        public var kind: LineKind
        /// The new file's line number (the old one for a deletion); nil for a hunk header.
        public var number: Int?
        public var text: String
    }

    public var id: String { path }
    public var path: String
    public var additions: Int
    public var deletions: Int
    public var lines: [Line]
    public var isSensitive: Bool

    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

public enum UnifiedDiff {
    public static func parse(_ text: String, sensitive: [String] = []) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var oldLine = 0
        var newLine = 0
        var counter = 0

        func flush() {
            if let file = current { files.append(file) }
            current = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flush()
                let path = line.components(separatedBy: " b/").last ?? line
                current = DiffFile(path: path, additions: 0, deletions: 0, lines: [],
                                   isSensitive: sensitive.contains { path.hasSuffix($0) || $0.hasSuffix(path) })
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("index ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity")
                || line.hasPrefix("rename ") || line.hasPrefix("\\ No newline") {
                continue
            }
            counter += 1
            if line.hasPrefix("@@") {
                (oldLine, newLine) = hunkStarts(line)
                current!.lines.append(.init(id: counter, kind: .hunk, number: nil, text: line))
            } else if line.hasPrefix("+") {
                current!.additions += 1
                current!.lines.append(.init(id: counter, kind: .addition, number: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-") {
                current!.deletions += 1
                current!.lines.append(.init(id: counter, kind: .deletion, number: oldLine, text: String(line.dropFirst())))
                oldLine += 1
            } else {
                current!.lines.append(.init(id: counter, kind: .context, number: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            }
        }
        flush()
        return files
    }

    /// `@@ -52,10 +52,15 @@ …` → (52, 52).
    static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start("-"), start("+"))
    }
}
