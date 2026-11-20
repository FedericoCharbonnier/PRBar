import AppKit
import PRBarCore
import SwiftUI

/// The chat panel of the Review and Respond windows (spec B.2): the messages, Claude's answer as it streams with
/// the last tool it used, and a multi-line field (↩ sends, ⇧↩ new line; Stop while it runs).
struct ChatPanel: View {
    @ObservedObject var chat: ChatCoordinator
    /// Why the chat can't run at all (claude not found…), shown as the field's placeholder.
    let unavailableReason: String?
    /// A warning on top, e.g. that the review is for an older commit.
    let notice: String?
    let logURL: URL

    @State private var text = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.orangeText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.tint(Theme.orange))
            }
            messages
            Divider()
            input
        }
        .frame(minWidth: 320, maxHeight: .infinity)
        .onAppear { inputFocused = true }
    }

    // MARK: Mensajes

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.session.messages.isEmpty && !chat.isRunning { emptyState }
                    ForEach(chat.session.messages) { message in
                        ChatMessageRow(
                            message: message, summary: summary(message),
                            canUndo: message.id == chat.session.undoableMessageID && chat.canUndo,
                            undo: { undo(message.id) }, logURL: logURL,
                            proposalActions: RuleProposalActions(
                                repo: chat.subject.repo.fullName,
                                save: { id, text, scope, stages in
                                    chat.saveProposal(id, in: message.id, text: text, scope: scope, appliesTo: stages)
                                },
                                dismiss: { id in chat.dismissProposal(id, in: message.id) }
                            )
                        )
                        .id(message.id)
                    }
                    if chat.isRunning {
                        workingRow.id("working")
                    }
                }
                .padding(12)
            }
            .onChange(of: chat.session.messages.count) { _, _ in
                if let last = chat.session.messages.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
            .onChange(of: chat.partialText) { _, _ in proxy.scrollTo("working", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        let examples: String
        switch chat.subject {
        case .review:
            examples = "Ask about the code or a finding (“is #2 right?”), or ask for changes: reword, add, drop or bring back findings, or write the general comment."
        case .respond:
            examples = "Ask about the comments you received, have Claude draft replies or choose which fixes to make. After implementing, it can also change the fixes’ code."
        case .merge:
            examples = "Ask about the changes, the reviews or the checks before merging (“is anything risky here?”, “why did lint fail?”). Claude can’t change anything here."
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Chat with Claude").font(.headline)
            Text(examples).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Claude never posts, pushes or approves: you do.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private var workingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chat.partialText.isEmpty {
                Text(ChatMarkdown.attributed(chat.partialText))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(chat.activity.map { "Claude is working… · \($0)" } ?? "Claude is working…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func summary(_ message: ChatMessage) -> String {
        ChatActions.summary(message.changes) { chat.number(of: $0) }
    }

    private func undo(_ id: UUID) {
        Task { @MainActor in
            if await chat.undoDiscardsLaterEdits(id) {
                ConfirmAlert.present(title: "Undo Claude’s changes?",
                                     message: "Undo will also discard your manual edits since then.", action: "Undo") {
                    chat.undo(id)
                }
            } else {
                chat.undo(id)
            }
        }
    }

    // MARK: Campo de texto

    private var canType: Bool { unavailableReason == nil && chat.canSend }

    private var placeholder: String {
        if let unavailableReason { return unavailableReason }
        if chat.session.readOnly { return "This conversation is read-only." }
        if let lock = chat.lockReason { return lock }
        if chat.isRunning { return "Claude is working…" }
        return "Ask Claude… (↩ to send, ⇧↩ for a new line)"
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($inputFocused)
                .disabled(!canType)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        text += "\n"
                        return .handled
                    }
                    send()
                    return .handled
                }
            if chat.isRunning {
                Button("Stop") { chat.stop() }
                    .controlSize(.small)
                    .help("Stop Claude. In Respond, the files it touched in this message are restored.")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(!canType || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (↩)")
                .accessibilityLabel("Send")
            }
        }
        .padding(10)
        .background(.bar)
    }

    private func send() {
        guard canType, chat.send(text) else { return }
        text = ""
    }
}

/// One message: the user's (on the right, tinted), Claude's (Markdown, with its changes and Undo) or an error (red,
/// with Show Log). Also used, read only, in History.
struct ChatMessageRow: View {
    let message: ChatMessage
    /// "Edited #2, added #4…" for Claude's messages with changes.
    let summary: String
    let canUndo: Bool
    let undo: (() -> Void)?
    let logURL: URL?
    var proposalActions: RuleProposalActions? = nil

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.tint(Theme.accent)))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                Text(ChatMarkdown.attributed(message.text))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.changes.isEmpty { changes }
                ForEach(message.proposals) { proposal in
                    RuleProposalCard(proposal: proposal, actions: proposalActions)
                }
                ForEach(message.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.tertiary)
                }
            }
        case .error:
            VStack(alignment: .leading, spacing: 4) {
                Label(message.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.redText)
                    .fixedSize(horizontal: false, vertical: true)
                if let logURL, FileManager.default.fileExists(atPath: logURL.path) {
                    Button("Show Log") {
                        if !NSWorkspace.shared.open(logURL) { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: message.undone ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                    .foregroundStyle(message.undone ? Color.secondary : Theme.green)
                Text(message.undone ? "Undone: \(summary)" : summary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(message.undone ? .secondary : .primary)
                Spacer(minLength: 4)
                if canUndo, let undo {
                    Button("Undo", action: undo)
                        .controlSize(.small)
                        .help("Undo this message’s changes")
                }
            }
            ForEach(files, id: \.self) { path in
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var files: [String] {
        message.changes.flatMap { change -> [String] in
            if case .filesChanged(let paths) = change { return paths }
            return []
        }
    }
}

/// History: the conversation, read only, in a collapsed section (spec B.7).
struct ChatTranscriptSection: View {
    let session: ChatSession
    let summary: (ChatMessage) -> String
    let logURL: URL
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.messages) { message in
                    ChatMessageRow(message: message, summary: summary(message), canUndo: false, undo: nil, logURL: logURL)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Chat (\(session.messages.count) message\(session.messages.count == 1 ? "" : "s"))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

enum ChatMarkdown {
    /// Simple Markdown (bold, italics, code, links), keeping line breaks.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// What a rule proposal card can do (spec E.3). Without it (History), the card is read only.
struct RuleProposalActions {
    /// The chat's repo, for the scope menu.
    let repo: String
    let save: (_ proposalID: UUID, _ text: String, _ scope: RuleScope, _ stages: Set<RuleStage>) -> String?
    let dismiss: (_ proposalID: UUID) -> Void
}

/// "Save as rule — Global — Review": a rule Claude proposed. Editable before saving; nothing is saved without Save.
struct RuleProposalCard: View {
    let proposal: RuleProposal
    let actions: RuleProposalActions?

    @State private var text: String
    @State private var scope: RuleScope
    @State private var stages: Set<RuleStage>
    @State private var error: String?

    init(proposal: RuleProposal, actions: RuleProposalActions?) {
        self.proposal = proposal
        self.actions = actions
        _text = State(initialValue: proposal.text)
        _scope = State(initialValue: proposal.scope)
        _stages = State(initialValue: proposal.appliesTo)
    }

    private var editable: Bool { proposal.status == .pending && actions != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bookmark.fill").foregroundStyle(Color.accentColor)
                Text("Save as rule").font(.caption.weight(.semibold))
                Text("— \(scope.title) — \(stages.sorted().map(\.title).joined(separator: " + "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if editable, let actions {
                TextField("Rule", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .lineLimit(1...4)
                HStack(spacing: 6) {
                    Picker("Scope", selection: $scope) {
                        Text("Global").tag(RuleScope.global)
                        Text(actions.repo).tag(RuleScope.repo(actions.repo))
                    }
                    .labelsHidden()
                    .fixedSize()
                    ForEach(RuleStage.allCases, id: \.self) { stage in
                        StageChip(stage: stage, isOn: stages.contains(stage)) {
                            if stages.contains(stage) { stages.remove(stage) } else { stages.insert(stage) }
                        }
                    }
                    Spacer(minLength: 4)
                    Button("Dismiss") { actions.dismiss(proposal.id) }
                    Button("Save") { error = actions.save(proposal.id, text, scope, stages) }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || stages.isEmpty)
                }
                .controlSize(.small)
                if let error {
                    Text(error).font(.caption).foregroundStyle(Theme.redText)
                }
            } else {
                Text(proposal.text)
                    .font(.callout)
                    .foregroundStyle(proposal.status == .dismissed ? .secondary : .primary)
                    .strikethrough(proposal.status == .dismissed)
                    .fixedSize(horizontal: false, vertical: true)
                switch proposal.status {
                case .saved:
                    Label("Saved as a rule (Settings › Instructions)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.green)
                case .dismissed:
                    Text("Dismissed").font(.caption).foregroundStyle(.tertiary)
                case .pending:
                    Text("Not saved").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.tint(Theme.accent).opacity(0.5)))
    }
}
