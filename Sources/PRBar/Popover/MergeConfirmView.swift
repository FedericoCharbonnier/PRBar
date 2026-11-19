import AppKit
import PRBarCore
import SwiftUI

/// "Merge #42 into main?" (spec F.3): el título del PR, repo, commits y ramas, un popup con el método y el botón del
/// método elegido. Lo abre `AppModel.requestMerge` en una ventana chica cuando `merge.confirm` está encendido.
struct MergeConfirmView: View {
    static let size = NSSize(width: 440, height: 230)

    let item: ClassifiedPR
    let methods: [MergeMethod]
    /// Aviso que no impide mergear (p. ej. checks no requeridos fallando).
    let note: String?
    /// El repo borra la rama al mergear (lo hace GitHub; PRBar no la toca).
    let deletesBranch: Bool
    let onMerge: (MergeMethod) -> Void
    let onCancel: () -> Void
    @State private var method: MergeMethod

    init(
        item: ClassifiedPR, methods: [MergeMethod], initialMethod: MergeMethod, note: String?, deletesBranch: Bool,
        onMerge: @escaping (MergeMethod) -> Void, onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.methods = methods
        self.note = note
        self.deletesBranch = deletesBranch
        self.onMerge = onMerge
        self.onCancel = onCancel
        _method = State(initialValue: initialMethod)
    }

    private var pr: PullRequest { item.pr }

    /// `acme/api · 3 commits · feat/x → main`.
    private var details: String {
        var parts = [pr.repo.fullName]
        if let count = pr.merge.commitCount { parts.append(count == 1 ? "1 commit" : "\(count) commits") }
        parts.append("\(pr.headRef) → \(pr.baseRef)")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Theme.violet)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Merge #\(pr.number) into \(pr.baseRef)?").font(.headline)
                    Text(pr.title)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Picker("Method", selection: $method) {
                ForEach(methods) { Text($0.actionTitle).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if let note {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.orangeText)
            }
            if deletesBranch {
                Label("GitHub will delete the branch (repo setting)", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(method.actionTitle) { onMerge(method) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }
}
