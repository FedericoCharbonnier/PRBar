import Foundation

/// What the chat is about: the Review window of someone else's PR or the Respond window of mine.
public enum ChatSubject: Equatable, Sendable {
    case review(ReviewDraft)
    case respond(RespondDraft)

    public var kind: ChatSession.Kind {
        switch self {
        case .review: .review
        case .respond: .respond
        }
    }

    public var prID: String {
        switch self {
        case .review(let draft): draft.prID
        case .respond(let draft): draft.prID
        }
    }

    public var draftID: UUID {
        switch self {
        case .review(let draft): draft.id
        case .respond(let draft): draft.id
        }
    }
}

/// One message of the chat (spec B.3).
public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, error }

    public let id: UUID
    public var role: Role
    public var text: String
    public var createdAt: Date
    /// What the message changed in the window or the worktree; empty if nothing.
    public var changes: [ChatChange]
    public var undone: Bool
    /// Faint notes under the message: "Context rebuilt", actions that were discarded, etc.
    public var notes: [String]
    /// How to undo the message (only messages with changes).
    public var restore: ChatRestorePoint?

    public init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date(), changes: [ChatChange] = [],
                undone: Bool = false, notes: [String] = [], restore: ChatRestorePoint? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.changes = changes
        self.undone = undone
        self.notes = notes
        self.restore = restore
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, createdAt, changes, undone, notes, restore }

    /// Lenient: only `id`, `role` and `text` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        changes = (try? c.decodeIfPresent(LossyArray<ChatChange>.self, forKey: .changes))?.elements ?? []
        undone = (try? c.decodeIfPresent(Bool.self, forKey: .undone)) ?? false
        notes = (try? c.decodeIfPresent([String].self, forKey: .notes)) ?? []
        restore = (try? c.decodeIfPresent(ChatRestorePoint.self, forKey: .restore)) ?? nil
    }
}

/// An array decoded element by element: the elements that don't decode are skipped, so one bad (or newer) entry
/// doesn't lose the others.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(Skip.self)
            }
        }
        self.elements = elements
    }
}

public enum ChatChange: Codable, Equatable, Sendable {
    case findingEdited(id: String)
    case findingAdded(id: String)
    case findingIncluded(id: String, included: Bool)
    case generalCommentEdited
    case replyDrafted(commentID: String)
    case implementSet(commentID: String, implement: Bool)
    /// Paths relative to the worktree.
    case filesChanged([String])

    /// The finding or comment the window highlights for this change.
    public var highlightID: String? {
        switch self {
        case .findingEdited(let id), .findingAdded(let id), .findingIncluded(let id, _): id
        case .replyDrafted(let id), .implementSet(let id, _): id
        case .generalCommentEdited, .filesChanged: nil
        }
    }
}

/// The worktree before a chat turn of Respond that changed files (spec B.6).
public struct ChatFileSnapshot: Codable, Equatable, Sendable {
    /// `refs/prbar/chat-<session>-<n>`: a commit, on no branch, with the tree before the turn.
    public let ref: String
    public let tree: String
    public let headBefore: String
    /// The commit PRBar made with the turn's changes.
    public let headAfter: String
    /// The fixes' result before the turn: undoing goes back to it.
    public let resultBefore: RespondResult

    public init(ref: String, tree: String, headBefore: String, headAfter: String, resultBefore: RespondResult) {
        self.ref = ref
        self.tree = tree
        self.headBefore = headBefore
        self.headAfter = headAfter
        self.resultBefore = resultBefore
    }
}

/// The state of the window before and after a turn (after = to detect later manual edits) and, in Respond, the
/// worktree's snapshot.
public struct ChatRestorePoint: Codable, Equatable, Sendable {
    public var reviewEdits: ReviewEdits?
    public var reviewEditsAfter: ReviewEdits?
    public var selections: [String: RespondSelection]?
    public var selectionsAfter: [String: RespondSelection]?
    public var files: ChatFileSnapshot?

    public init(reviewEdits: ReviewEdits? = nil, reviewEditsAfter: ReviewEdits? = nil,
                selections: [String: RespondSelection]? = nil, selectionsAfter: [String: RespondSelection]? = nil,
                files: ChatFileSnapshot? = nil) {
        self.reviewEdits = reviewEdits
        self.reviewEditsAfter = reviewEditsAfter
        self.selections = selections
        self.selectionsAfter = selectionsAfter
        self.files = files
    }
}

/// One conversation per PR (spec B.3). It's saved inside the draft (`ReviewDraft.chat`, `RespondRecord.chat`).
public struct ChatSession: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case review, respond }

    public static let interruptedText = "Interrupted"

    public let id: UUID
    public let prID: String
    public let kind: Kind
    /// The Claude Code session that `--resume` continues.
    public var claudeSessionID: UUID?
    /// Where Claude runs (the same cwd, so `--resume` finds the session).
    public var worktreePath: String?
    /// PRBar's refs of the review chat's worktree, to delete them with it.
    public var worktreeRefs: [String]
    public var messages: [ChatMessage]
    /// True after posting or pushing.
    public var readOnly: Bool
    /// A turn was running when this was saved. If it still says so when the window opens, the app quit mid-turn.
    public var pending: Bool
    /// The window's state (JSON) as Claude last saw it: the next turn sends it again only if it changed.
    public var lastState: String?
    /// Whether Claude was last told it can edit files (Respond after implementing). When it differs from the
    /// window's, the next `--resume` turn says so (`ChatPrompts.followUp`). Nil = not known yet (the first turn, or
    /// a session saved before this field existed).
    public var canEditFiles: Bool?

    public init(id: UUID = UUID(), prID: String, kind: Kind) {
        self.id = id
        self.prID = prID
        self.kind = kind
        claudeSessionID = nil
        worktreePath = nil
        worktreeRefs = []
        messages = []
        readOnly = false
        pending = false
        lastState = nil
        canEditFiles = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, prID, kind, claudeSessionID, worktreePath, worktreeRefs, messages, readOnly, pending, lastState, canEditFiles
    }

    /// Lenient: only `id`, `prID` and `kind` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        prID = try c.decode(String.self, forKey: .prID)
        kind = try c.decode(Kind.self, forKey: .kind)
        claudeSessionID = (try? c.decodeIfPresent(UUID.self, forKey: .claudeSessionID)) ?? nil
        worktreePath = (try? c.decodeIfPresent(String.self, forKey: .worktreePath)) ?? nil
        worktreeRefs = (try? c.decodeIfPresent([String].self, forKey: .worktreeRefs)) ?? []
        messages = (try? c.decodeIfPresent(LossyArray<ChatMessage>.self, forKey: .messages))?.elements ?? []
        readOnly = (try? c.decodeIfPresent(Bool.self, forKey: .readOnly)) ?? false
        pending = (try? c.decodeIfPresent(Bool.self, forKey: .pending)) ?? false
        lastState = (try? c.decodeIfPresent(String.self, forKey: .lastState)) ?? nil
        canEditFiles = (try? c.decodeIfPresent(Bool.self, forKey: .canEditFiles)) ?? nil
    }

    /// The only message that offers Undo: the last one with changes that wasn't undone. Undoing goes backwards.
    public var undoableMessageID: UUID? {
        messages.last { !$0.changes.isEmpty && !$0.undone }?.id
    }

    /// A turn left `pending` (the app quit while it ran) becomes an "Interrupted" error.
    public func recovered(now: Date = Date()) -> ChatSession {
        guard pending else { return self }
        var session = self
        session.pending = false
        session.messages.append(ChatMessage(role: .error, text: Self.interruptedText, createdAt: now))
        return session
    }
}

/// The Review window's editable state (spec B.1): which findings are posted, their edited texts, the findings the
/// chat added and the general comment. The window and the chat edit the same value (`ChatCoordinator.reviewEdits`).
public struct ReviewEdits: Codable, Equatable, Sendable {
    public var selected: Set<String>
    /// Edited bodies, by finding id.
    public var bodies: [String: String]
    /// Edited titles, by finding id.
    public var titles: [String: String]
    /// Findings the chat added (ids `c1`, `c2`…), after the draft's.
    public var added: [ReviewItem]
    public var generalComment: String

    public init(selected: Set<String>, bodies: [String: String] = [:], titles: [String: String] = [:],
                added: [ReviewItem] = [], generalComment: String = "") {
        self.selected = selected
        self.bodies = bodies
        self.titles = titles
        self.added = added
        self.generalComment = generalComment
    }

    /// What the window shows when a review opens: the findings the filter kept, selected.
    public static func initial(for draft: ReviewDraft) -> ReviewEdits {
        ReviewEdits(selected: Set(draft.items.filter(\.keep).map(\.id)))
    }

    /// The draft's findings and then the added ones, with edited titles. Position + 1 is the number (#N).
    public func items(of draft: ReviewDraft) -> [ReviewItem] {
        (draft.items + added).map { item in
            guard let title = titles[item.id] else { return item }
            let f = item.finding
            return ReviewItem(finding: ReviewFinding(id: f.id, severity: f.severity, file: f.file, line: f.line,
                                                     title: title, body: f.body),
                              keep: item.keep, reason: item.reason)
        }
    }

    /// `#N` of a finding (from 1), or nil if it doesn't exist.
    public func number(of id: String, in draft: ReviewDraft) -> Int? {
        (draft.items + added).firstIndex { $0.id == id }.map { $0 + 1 }
    }

    public func body(of item: ReviewItem) -> String { bodies[item.id] ?? item.finding.body }

    public func isEdited(_ item: ReviewItem) -> Bool {
        titles[item.id] != nil || (bodies[item.id].map { $0 != item.finding.body } ?? false)
    }

    /// What would be posted: the selected findings, in order, with their final title and text.
    public func selectedComments(of draft: ReviewDraft) -> [SelectedComment] {
        items(of: draft).filter { selected.contains($0.id) }.map { SelectedComment(finding: $0.finding, body: body(of: $0)) }
    }
}

/// One action of Claude's answer (`ChatSchemas.turn`). `type` is a string, so an unknown type doesn't break the
/// decoding: `ChatActions` discards it with a note.
public struct ChatAction: Codable, Equatable, Sendable {
    public static let allTypes = ["editFinding", "addFinding", "setIncluded", "setGeneralComment", "draftReply", "setImplement"]

    public var type: String
    public var id: String?
    public var title: String?
    public var body: String?
    public var severity: String?
    public var file: String?
    public var line: Int?
    public var included: Bool?
    public var text: String?
    public var commentID: String?
    public var implement: Bool?

    public init(type: String, id: String? = nil, title: String? = nil, body: String? = nil, severity: String? = nil,
                file: String? = nil, line: Int? = nil, included: Bool? = nil, text: String? = nil,
                commentID: String? = nil, implement: Bool? = nil) {
        self.type = type
        self.id = id
        self.title = title
        self.body = body
        self.severity = severity
        self.file = file
        self.line = line
        self.included = included
        self.text = text
        self.commentID = commentID
        self.implement = implement
    }
}

/// Claude's structured answer in each turn.
public struct ChatOutput: Codable, Equatable, Sendable {
    public var reply: String
    public var actions: [ChatAction]

    public init(reply: String, actions: [ChatAction]) {
        self.reply = reply
        self.actions = actions
    }
}

public enum ChatSchemas {
    /// `{"reply": "...", "actions": [{"type": ..., ...}]}`. Which actions apply is checked by `ChatActions`.
    public static let turn = """
    {"type":"object","additionalProperties":false,"required":["reply","actions"],
     "properties":{
      "reply":{"type":"string"},
      "actions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["type"],
        "properties":{
          "type":{"type":"string","enum":["editFinding","addFinding","setIncluded","setGeneralComment","draftReply","setImplement"]},
          "id":{"type":"string"},
          "title":{"type":"string"},
          "body":{"type":"string"},
          "severity":{"type":"string","enum":["high","medium","low"]},
          "file":{"type":"string"},
          "line":{"type":["integer","null"]},
          "included":{"type":"boolean"},
          "text":{"type":"string"},
          "commentID":{"type":"string"},
          "implement":{"type":"boolean"}}}}}}
    """
}
