import PRBarCore
import SwiftUI

/// Globs separated by commas or new lines (spec E.5, `ignorePaths`). Saved on Return or when leaving the field.
struct PatternListField: View {
    let title: String
    let saved: [String]
    let onCommit: ([String]) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text("e.g. generated/**, *.lock"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit(commit)
                .help("Findings in files matching these patterns are hidden. Without “/” a pattern matches the file name.")
        }
        .onAppear { text = saved.joined(separator: ", ") }
        .onDisappear(perform: commit)
        .onChange(of: saved) { _, value in if !focused { text = value.joined(separator: ", ") } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    static func parse(_ text: String) -> [String] {
        ReviewOptions.normalizePatterns(text.split(whereSeparator: { $0 == "," || $0.isNewline }).map(String.init))
    }

    private func commit() {
        let patterns = Self.parse(text)
        guard patterns != saved else { return }
        onCommit(patterns)
    }
}
