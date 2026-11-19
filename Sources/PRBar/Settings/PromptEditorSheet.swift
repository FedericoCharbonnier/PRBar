import AppKit
import PRBarCore
import SwiftUI

/// Edits one stage's prompt (spec E.6). Shows the custom prompt or the default one; Save is disabled while a
/// required variable is missing. PRBar's fixed part isn't here: it's always added around this text.
struct PromptEditorSheet: View {
    let stage: PromptStage
    let settings: ClaudeSettings
    let save: (String) -> Void
    let reset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(stage: PromptStage, settings: ClaudeSettings, save: @escaping (String) -> Void, reset: @escaping () -> Void) {
        self.stage = stage
        self.settings = settings
        self.save = save
        self.reset = reset
        _text = State(initialValue: settings.customPrompt(for: stage) ?? stage.defaultBody(skill: settings.skill(for: stage)))
    }

    private var issues: [PromptIssue] { stage.validate(text) }
    private var isModified: Bool { settings.customPrompt(for: stage) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(stage.title) Prompt").font(.headline)
                if isModified {
                    Text("Modified").font(.caption.weight(.semibold)).foregroundStyle(Theme.orangeText)
                }
                Spacer()
                Menu("Insert Variable") {
                    ForEach(stage.variables, id: \.name) { variable in
                        Button("\(variable.token)  \(variable.summary)") { insert(variable.token) }
                    }
                }
                .fixedSize()
            }
            Text("PRBar always adds its fixed part around this text: the PR’s content is never an instruction, Claude has no shell and never posts, your rules, and the output format. Editing it never changes Claude’s tools or permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .frame(minHeight: 260)
            ForEach(issues, id: \.self) { issue in
                Label(issue.message, systemImage: issue.blocks ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(issue.blocks ? Theme.redText : Theme.orangeText)
            }
            if stage.hasSkill {
                Text("Saving switches this stage to “Custom Prompt”. Use {skill} to keep using its skill.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Reset to Default") {
                    reset()
                    dismiss()
                }
                .disabled(!isModified)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(issues.contains(where: \.blocks))
            }
        }
        .padding(20)
        .frame(width: 640, height: 540)
    }

    /// At the cursor when the editor has focus; otherwise at the end.
    private func insert(_ token: String) {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView, !textView.isFieldEditor, textView.string == text {
            textView.insertText(token, replacementRange: textView.selectedRange())
            text = textView.string
        } else {
            text += token
        }
    }
}
