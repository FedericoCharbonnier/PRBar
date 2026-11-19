import AppKit
import PRBarCore
import SwiftUI

/// A fixes template (spec E.5): a monospaced field, "Insert Variable" (with "Reset to Default") and a preview with
/// sample values. Edits a local copy and saves after typing stops or when leaving the field, like
/// `SlackTemplateEditor`. Empty = the default.
struct FixTemplateEditor: View {
    let title: String
    let kind: FixTemplateKind
    /// Saved value ("" = none).
    let value: String
    let onCommit: (String) -> Void

    static let saveDelay: Duration = .milliseconds(500)

    @State private var draft: String
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(title: String, kind: FixTemplateKind, value: String, onCommit: @escaping (String) -> Void) {
        self.title = title
        self.kind = kind
        self.value = value
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                Menu("Insert Variable") {
                    ForEach(kind.variables, id: \.name) { variable in
                        Button("\(variable.token)  \(variable.summary)") { insert(variable.token) }
                    }
                    Divider()
                    Button("Reset to Default") {
                        draft = ""
                        flush()
                    }
                    .disabled(draft.isEmpty)
                }
                .fixedSize()
            }
            TextField(title, text: $draft, prompt: Text(kind.placeholder), axis: .vertical)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...3)
                .focused($focused)
            (Text("Preview: ") + Text(FixTemplates.preview(draft, kind: kind)).foregroundColor(.primary))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .onChange(of: draft) { scheduleSave() }
        .onChange(of: focused) { _, isFocused in if !isFocused { flush() } }
        .onChange(of: value) { _, newValue in if saveTask == nil, !focused, newValue != draft { draft = newValue } }
        .onDisappear { flush() }
    }

    private func insert(_ token: String) {
        if focused, let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isFieldEditor, textView.string == draft {
            textView.insertText(token, replacementRange: textView.selectedRange())
            draft = textView.string
        } else {
            draft += token
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func flush() {
        saveTask?.cancel()
        commit()
    }

    private func commit() {
        saveTask = nil
        if draft != value { onCommit(draft) }
    }
}
