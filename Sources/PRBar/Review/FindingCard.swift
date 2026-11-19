import PRBarCore
import SwiftUI

/// Qué campo de texto de la ventana de Review tiene el foco.
enum ReviewFocus: Hashable {
    case general
    case finding(String)
}

/// Tarjeta de un hallazgo que el filtro mantuvo: checkbox, severidad, ubicación, título y el comentario editable.
struct FindingCard: View {
    let item: ReviewItem
    /// `#N`: the position in the window, the same the chat uses.
    let number: Int
    @Binding var isSelected: Bool
    @Binding var text: String
    let isEdited: Bool
    /// The chat changed it just now (3 s).
    let isHighlighted: Bool
    var focus: FocusState<ReviewFocus?>.Binding
    @State private var expanded: Bool

    init(item: ReviewItem, number: Int, isSelected: Binding<Bool>, text: Binding<String>, isEdited: Bool,
         isHighlighted: Bool = false, focus: FocusState<ReviewFocus?>.Binding, initiallyExpanded: Bool = false) {
        self.item = item
        self.number = number
        _isSelected = isSelected
        _text = text
        self.isEdited = isEdited
        self.isHighlighted = isHighlighted
        self.focus = focus
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var finding: ReviewFinding { item.finding }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(finding.title, isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(isSelected ? "Don’t post this comment" : "Post this comment")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    FindingNumber(number: number)
                    FindingMeta(finding: finding, dotColor: finding.severity.color, labelColor: finding.severity.textColor)
                }
                Text(finding.title)
                    .font(.body)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .help(finding.title)
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .imageScale(.small)
                            .fontWeight(.semibold)
                        Text(expanded ? "Hide comment" : "Show full comment")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded { editor }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .fill(isHighlighted ? Theme.tint(Theme.accent) : Color(nsColor: .controlBackgroundColor)))
        .animation(.easeInOut(duration: 0.3), value: isHighlighted)
        .cardBorder()
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused(focus, equals: .finding(item.id))
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(Color(nsColor: .textBackgroundColor)))
                .cardBorder(cornerRadius: Theme.Radius.button, opacity: 0.15)
                .focusRing(focus.wrappedValue == .finding(item.id))
            HStack {
                Text(finding.line.map { "Markdown · posted on line \($0)" } ?? "Markdown · posted in the general comment")
                Spacer()
                if isEdited { Text("Edited") }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}

/// Tarjeta gris de un hallazgo que el filtro descartó, con la razón y "Incluir igual" / "Quitar".
struct DiscardedFindingCard: View {
    let item: ReviewItem
    let number: Int
    @Binding var isSelected: Bool
    var isHighlighted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(item.finding.title, isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(isSelected ? "Don’t post this comment" : "Post this comment anyway")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    FindingNumber(number: number)
                    FindingMeta(finding: item.finding, dotColor: Color.secondary.opacity(0.6), labelColor: .secondary)
                }
                Text(item.finding.title)
                    .font(.body)
                    .lineLimit(1)
                    .help(item.finding.title)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease").imageScale(.small).fontWeight(.semibold)
                    Text(item.reason?.isEmpty == false ? item.reason! : "No reason given")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(isSelected ? "Remove" : "Include Anyway") { isSelected.toggle() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
                .font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .fill(isHighlighted ? Theme.tint(Theme.accent) : Color.primary.opacity(0.05)))
        .animation(.easeInOut(duration: 0.3), value: isHighlighted)
    }
}

/// `#N` before a finding's severity.
struct FindingNumber: View {
    let number: Int

    var body: some View {
        Text("#\(number)")
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Finding \(number)")
    }
}

/// Punto de severidad + etiqueta + `file:line` en mono.
struct FindingMeta: View {
    let finding: ReviewFinding
    let dotColor: Color
    let labelColor: Color

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(finding.severity.label)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(labelColor)
            Text(finding.location)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(finding.location)
        }
    }
}
