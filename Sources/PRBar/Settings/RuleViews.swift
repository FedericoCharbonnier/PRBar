import PRBarCore
import SwiftUI

/// "Review" / "Fixes" as a toggleable chip.
struct StageChip: View {
    let stage: RuleStage
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(stage.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(isOn ? Theme.tint(Theme.accent) : Color.primary.opacity(0.06)))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(isOn ? "Applies to \(stage.title)" : "Doesn’t apply to \(stage.title)")
    }
}

/// A suggestion (spec E.4) with its proposed rule, editable, and Create Rule / Not Now / Never. Used in Settings ›
/// Instructions and in the posted-review screen.
struct RuleSuggestionCard: View {
    let model: AppModel
    let suggestion: RuleSuggestion

    @State private var text: String
    @State private var error: String?

    init(model: AppModel, suggestion: RuleSuggestion) {
        self.model = model
        self.suggestion = suggestion
        _text = State(initialValue: suggestion.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(LocalizedStringKey(suggestion.message)).font(.callout)
            } icon: {
                Image(systemName: "lightbulb.fill").foregroundStyle(Theme.orange)
            }
            TextField("Rule", text: $text, prompt: Text("Rule"), axis: .vertical)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            HStack(spacing: 8) {
                Button("Never") { perform { try model.neverSuggest(suggestion.id) } }
                    .help("Don’t suggest this again")
                Spacer()
                Button("Not Now") { perform { try model.snoozeSuggestion(suggestion.id) } }
                    .help("Hide it for 30 days")
                Button("Create Rule") { perform { try model.acceptSuggestion(suggestion.id, text: text) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.redText)
            }
        }
        .padding(.vertical, 4)
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
