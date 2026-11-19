import Foundation

/// The result of applying Claude's actions: the new state, what changed and why some actions were discarded.
public struct ChatApplication<State: Equatable & Sendable>: Equatable, Sendable {
    public var state: State
    public var changes: [ChatChange]
    public var notes: [String]
}

/// Validates and applies the actions of a chat turn (spec B.4). Pure: PRBar only writes what passed validation,
/// and every discarded action leaves a note for the message.
public enum ChatActions {
    /// The filter's `reason` of a finding the chat added.
    public static let addedReason = "Added in the chat"
    static let reviewTypes: Set<String> = ["editFinding", "addFinding", "setIncluded", "setGeneralComment"]
    static let respondTypes: Set<String> = ["draftReply", "setImplement"]

    // MARK: Review

    public static func applyReview(_ actions: [ChatAction], to edits: ReviewEdits, draft: ReviewDraft,
                                   diffFiles: Set<String>) -> ChatApplication<ReviewEdits> {
        var edits = edits
        var changes: [ChatChange] = []
        var notes: [String] = []
        for action in actions {
            let ids = Set(edits.items(of: draft).map(\.id))
            switch action.type {
            case "editFinding":
                guard let id = action.id, ids.contains(id) else {
                    notes.append("Ignored an edit: finding \(action.id ?? "?") doesn’t exist.")
                    continue
                }
                let title = nonBlank(action.title)
                let body = nonBlank(action.body)
                guard title != nil || body != nil else {
                    notes.append("Ignored an empty edit of \(id).")
                    continue
                }
                if let title { edits.titles[id] = singleLine(title) }
                if let body { edits.bodies[id] = body }
                changes.append(.findingEdited(id: id))
            case "addFinding":
                guard let severity = action.severity.flatMap(Severity.init(rawValue:)) else {
                    notes.append("Ignored a new finding: invalid severity \(action.severity ?? "(none)").")
                    continue
                }
                let file = nonBlank(action.file).map { DiffLineMap.normalizePath($0) } ?? ""
                guard diffFiles.contains(file) else {
                    notes.append("Ignored a new finding: \(file.isEmpty ? "no file" : file) isn’t in the PR’s diff.")
                    continue
                }
                guard let title = nonBlank(action.title), let body = nonBlank(action.body) else {
                    notes.append("Ignored a new finding without a title or text.")
                    continue
                }
                if let line = action.line, line < 1 {
                    notes.append("Ignored a new finding: invalid line \(line).")
                    continue
                }
                let id = nextAddedID(in: ids, after: &edits.addedCount)
                edits.added.append(ReviewItem(
                    finding: ReviewFinding(id: id, severity: severity, file: file, line: action.line,
                                           title: singleLine(title), body: body),
                    keep: true, reason: addedReason))
                edits.selected.insert(id)
                changes.append(.findingAdded(id: id))
            case "setIncluded":
                guard let id = action.id, ids.contains(id), let included = action.included else {
                    notes.append("Ignored a selection change: finding \(action.id ?? "?") doesn’t exist or no value was given.")
                    continue
                }
                if included { edits.selected.insert(id) } else { edits.selected.remove(id) }
                changes.append(.findingIncluded(id: id, included: included))
            case "setGeneralComment":
                guard let text = action.text else {
                    notes.append("Ignored a general comment without text.")
                    continue
                }
                edits.generalComment = text.trimmingCharacters(in: .whitespacesAndNewlines)
                changes.append(.generalCommentEdited)
            case "proposeRule":
                continue   // Not a change: `proposals(_:repo:stage:)` turns it into a card the user decides on.
            default:
                notes.append(otherKindNote(action.type, available: reviewTypes, here: "Review"))
            }
        }
        return ChatApplication(state: edits, changes: changes, notes: notes)
    }

    // MARK: Respond

    /// `canSetImplement`: the fixes weren't implemented yet (after implementing, the code changes with Edit/Write).
    public static func applyRespond(_ actions: [ChatAction], to selections: [String: RespondSelection], draft: RespondDraft,
                                    canSetImplement: Bool) -> ChatApplication<[String: RespondSelection]> {
        var selections = selections
        var changes: [ChatChange] = []
        var notes: [String] = []
        let items = Dictionary(draft.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for action in actions {
            switch action.type {
            case "draftReply":
                guard let id = action.commentID, let item = items[id] else {
                    notes.append("Ignored a reply: comment \(action.commentID ?? "?") doesn’t exist.")
                    continue
                }
                guard let body = nonBlank(action.body) else {
                    notes.append("Ignored an empty reply to \(item.feedback.reviewer).")
                    continue
                }
                var selection = selections[id] ?? RespondSelection.defaults(for: item)
                selection.reply = true
                selection.replyText = body
                selections[id] = selection
                changes.append(.replyDrafted(commentID: id))
            case "setImplement":
                guard canSetImplement else {
                    notes.append("Ignored a fix choice: the fixes are already implemented.")
                    continue
                }
                guard let id = action.commentID, let item = items[id], let implement = action.implement else {
                    notes.append("Ignored a fix choice: comment \(action.commentID ?? "?") doesn’t exist or no value was given.")
                    continue
                }
                var selection = selections[id] ?? RespondSelection.defaults(for: item)
                selection.implement = implement
                if implement && selection.fixPlan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selection.fixPlan = item.fixPlan
                }
                selections[id] = selection
                changes.append(.implementSet(commentID: id, implement: implement))
            case "proposeRule":
                continue   // Not a change: `proposals(_:repo:stage:)` turns it into a card the user decides on.
            default:
                notes.append(otherKindNote(action.type, available: respondTypes, here: "Respond"))
            }
        }
        return ChatApplication(state: selections, changes: changes, notes: notes)
    }

    // MARK: Reglas

    public static let maxProposals = 3

    /// Spec E.3: the `proposeRule` actions as proposals, validated (text trimmed, redacted, 1–1000 characters).
    /// `repo` scope = the PR's repo; without stages, `stage` (the chat's). At most `maxProposals`.
    public static func proposals(_ actions: [ChatAction], repo: RepoRef, stage: RuleStage) -> (proposals: [RuleProposal], notes: [String]) {
        var proposals: [RuleProposal] = []
        var notes: [String] = []
        for action in actions where action.type == "proposeRule" {
            guard proposals.count < maxProposals else {
                notes.append("Ignored a rule proposal: at most \(maxProposals) per answer.")
                continue
            }
            let text: String
            do {
                text = try RuleText.validated(action.text ?? "")
            } catch {
                notes.append("Ignored a rule proposal: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                continue
            }
            let stages = Set((action.appliesTo ?? []).compactMap(RuleStage.init(rawValue:)))
            proposals.append(RuleProposal(scope: action.scope == "repo" ? .repo(repo.fullName) : .global,
                                          appliesTo: stages.isEmpty ? [stage] : stages, text: text))
        }
        return (proposals, notes)
    }

    // MARK: Diff y resumen

    /// The paths of the new version in a unified diff (`+++ b/<path>`; deleted files have `/dev/null`).
    public static func files(inDiff diff: String) -> Set<String> {
        var files: Set<String> = []
        // Per file: the header (`diff --git` up to the first `@@`) says the new path; hunk lines are content, even
        // when they look like `+++ b/x`. `+++ /dev/null` (deleted) adds nothing.
        var inHeader = false
        var headerPath: String?
        var newPath: String?
        var deleted = false
        func finish() {
            if inHeader, !deleted, let path = newPath ?? headerPath, !path.isEmpty { files.insert(path) }
            inHeader = false
        }
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = Substring(raw.hasSuffix("\r") ? raw.dropLast() : raw)
            if line.hasPrefix("diff --git ") {
                finish()
                inHeader = true
                headerPath = newSide(ofHeader: line.dropFirst("diff --git ".count))
                newPath = nil
                deleted = false
                continue
            }
            guard inHeader else { continue }
            if line.hasPrefix("@@") {
                finish()
            } else if line.hasPrefix("+++ ") {
                let value = gitPath(line.dropFirst(4))
                if value == "/dev/null" { deleted = true } else if value.hasPrefix("b/") { newPath = String(value.dropFirst(2)) }
            } else if line.hasPrefix("deleted file mode") {
                deleted = true
            } else if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
                newPath = gitPath(line.drop { $0 != " " }.dropFirst().drop { $0 != " " }.dropFirst())
            }
        }
        finish()
        return files
    }

    /// The `b/` path of `a/X b/Y` (both quoted or not). Unquoted, only when X == Y (otherwise the split is ambiguous).
    private static func newSide(ofHeader rest: Substring) -> String? {
        if rest.hasPrefix("\"") {
            // `"a/X" "b/Y"` or `"a/X" b/Y`: the second token starts after the first closing quote.
            var escaped = false
            var index = rest.index(after: rest.startIndex)
            while index < rest.endIndex {
                let character = rest[index]
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { break }
                index = rest.index(after: index)
            }
            guard index < rest.endIndex else { return nil }
            let second = gitPath(rest[rest.index(after: index)...].drop { $0 == " " })
            return second.hasPrefix("b/") ? String(second.dropFirst(2)) : nil
        }
        if let quote = rest.range(of: " \"b/") {
            return String(gitPath(rest[rest.index(after: quote.lowerBound)...]).dropFirst(2))
        }
        let text = String(rest)
        guard text.hasPrefix("a/"), (text.count - 5) % 2 == 0 else { return nil }
        let length = (text.count - 5) / 2
        let old = String(text.dropFirst(2).prefix(length))
        return text == "a/\(old) b/\(old)" ? old : nil
    }

    /// A path as git writes it in a diff: C-quoted (`"sp\303\251cial"`) if it has special characters, otherwise
    /// as is, without the tab git appends to paths with spaces.
    private static func gitPath(_ raw: Substring) -> String {
        guard raw.hasPrefix("\""), raw.count >= 2, let close = raw.lastIndex(of: "\""), close > raw.startIndex else {
            return String(raw.hasSuffix("\t") ? raw.dropLast() : raw)
        }
        var bytes: [UInt8] = []
        var iterator = Array(raw[raw.index(after: raw.startIndex)..<close].utf8).makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\\"), let next = iterator.next() else { bytes.append(byte); continue }
            switch next {
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = iterator.next() else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// "Edited #2, added #4, changed 2 files" (spec B.1). `number` gives `#N` of a finding (nil = show the id).
    public static func summary(_ changes: [ChatChange], number: (String) -> Int?) -> String {
        var edited: [String] = [], added: [String] = [], included: [String] = [], excluded: [String] = []
        var general = false
        var replies = 0, marked = 0, unmarked = 0
        var files: Set<String> = []
        func append(_ id: String, to list: inout [String]) { if !list.contains(id) { list.append(id) } }
        for change in changes {
            switch change {
            case .findingEdited(let id): append(id, to: &edited)
            case .findingAdded(let id): append(id, to: &added)
            case .findingIncluded(let id, let on): on ? append(id, to: &included) : append(id, to: &excluded)
            case .generalCommentEdited: general = true
            case .replyDrafted: replies += 1
            case .implementSet(_, let on): if on { marked += 1 } else { unmarked += 1 }
            case .filesChanged(let paths): files.formUnion(paths)
            }
        }
        func refs(_ ids: [String]) -> String { ids.map { number($0).map { "#\($0)" } ?? $0 }.joined(separator: ", ") }
        var parts: [String] = []
        if !edited.isEmpty { parts.append("edited \(refs(edited))") }
        if !added.isEmpty { parts.append("added \(refs(added))") }
        if !included.isEmpty { parts.append("included \(refs(included))") }
        if !excluded.isEmpty { parts.append("excluded \(refs(excluded))") }
        if general { parts.append("edited the general comment") }
        if replies > 0 { parts.append("drafted \(replies) repl\(replies == 1 ? "y" : "ies")") }
        if marked > 0 { parts.append("marked \(marked) fix\(marked == 1 ? "" : "es") to implement") }
        if unmarked > 0 { parts.append("unmarked \(unmarked) fix\(unmarked == 1 ? "" : "es")") }
        if !files.isEmpty { parts.append("changed \(files.count) file\(files.count == 1 ? "" : "s")") }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: Privado

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `c1`, `c2`…: the one after the last handed out (`ReviewEdits.addedCount`, which it advances), never one in use.
    private static func nextAddedID(in ids: Set<String>, after count: inout Int) -> String {
        var n = count + 1
        while ids.contains("c\(n)") { n += 1 }
        count = n
        return "c\(n)"
    }

    private static func otherKindNote(_ type: String, available: Set<String>, here: String) -> String {
        if reviewTypes.union(respondTypes).contains(type) {
            return "Ignored \(type): it isn’t available in \(here)."
        }
        return "Ignored an unknown action (\(type))."
    }
}
