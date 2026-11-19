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
                let id = nextAddedID(in: ids)
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
            default:
                notes.append(otherKindNote(action.type, available: respondTypes, here: "Respond"))
            }
        }
        return ChatApplication(state: selections, changes: changes, notes: notes)
    }

    // MARK: Diff y resumen

    /// The paths of the new version in a unified diff (`+++ b/<path>`; deleted files have `/dev/null`).
    public static func files(inDiff diff: String) -> Set<String> {
        var files: Set<String> = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("+++ b/") {
            let path = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { files.insert(path) }
        }
        return files
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

    /// `c1`, `c2`…: the first one not in use.
    private static func nextAddedID(in ids: Set<String>) -> String {
        var n = 1
        while ids.contains("c\(n)") { n += 1 }
        return "c\(n)"
    }

    private static func otherKindNote(_ type: String, available: Set<String>, here: String) -> String {
        if reviewTypes.union(respondTypes).contains(type) {
            return "Ignored \(type): it isn’t available in \(here)."
        }
        return "Ignored an unknown action (\(type))."
    }
}
