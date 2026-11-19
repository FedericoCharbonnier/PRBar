import PRBarCore
import SwiftUI

/// Ventana de Review: elegir y editar los hallazgos de Claude y publicarlos como una sola review
/// (ver `docs/design/ReviewWindow.dc.html`).
struct ReviewWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prStore: PRStore
    let draft: ReviewDraft
    /// Avisa si hay cambios sin publicar (selección, textos editados o comentario general).
    let reportUnsaved: (Bool) -> Void
    let close: () -> Void
    private let initialSelection: Set<String>

    @State private var selected: Set<String>
    @State private var edited: [String: String] = [:]
    @State private var general = ""
    @State private var publishing = false
    @State private var error: String?
    /// El último intento falló con un 422 por los comentarios inline: se ofrece publicar todo en el cuerpo.
    @State private var inlineRejected: ReviewEvent?
    @State private var result: PublishedReview?
    @State private var showDiscarded: Bool
    /// Findings whose comment starts expanded (snapshot mode).
    private let initiallyExpanded: Set<String>
    @FocusState private var focus: ReviewFocus?

    static let size = NSSize(width: 720, height: 640)

    init(
        model: AppModel, draft: ReviewDraft, published: PublishedReview?,
        reportUnsaved: @escaping (Bool) -> Void = { _ in }, close: @escaping () -> Void,
        initialState: InitialState = InitialState()
    ) {
        self.model = model
        prStore = model.prStore
        self.draft = draft
        self.reportUnsaved = reportUnsaved
        self.close = close
        initialSelection = Set(draft.items.filter(\.keep).map(\.id))
        _selected = State(initialValue: initialSelection)
        _result = State(initialValue: published)
        _general = State(initialValue: initialState.generalComment)
        _showDiscarded = State(initialValue: initialState.showsDiscarded)
        initiallyExpanded = initialState.expandedFindings
    }

    /// How the window opens. The app always uses the defaults; snapshot mode presets a general comment, an
    /// expanded finding and the discarded section.
    struct InitialState {
        var generalComment = ""
        var showsDiscarded = false
        var expandedFindings: Set<String> = []
    }

    /// El PR tal como está en el último snapshot (`nil` si ya no aparece, p. ej. se mergeó).
    private var currentPR: ClassifiedPR? {
        prStore.snapshot?.items.first { $0.id == draft.prID }
    }

    /// El PR recibió commits después de la review: el diff de ahora no es el que vio Claude, así que todos
    /// los comentarios van al cuerpo (`AppModel.publish` hace lo mismo).
    private var isOutdated: Bool {
        guard let pr = currentPR else { return false }
        return pr.pr.headOid != draft.headOid
    }

    /// Hay algo que se perdería si se reemplaza la ventana: no se publicó y cambió la selección, algún texto
    /// o el comentario general.
    private var hasUnsavedChanges: Bool {
        guard result == nil else { return false }
        let editedText = draft.items.contains { item in edited[item.id].map { $0 != item.finding.body } ?? false }
        return editedText || selected != initialSelection
            || !general.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var kept: [ReviewItem] { draft.items.filter(\.keep) }
    private var discarded: [ReviewItem] { draft.items.filter { !$0.keep } }

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(draft: draft, pr: currentPR?.pr)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
            ClaudeSummary(summary: draft.summary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.tint(Theme.violet)))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            if let result {
                ReviewPublishedView(result: result, close: close)
            } else {
                editor
            }
        }
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity, alignment: .top)
        .onChange(of: hasUnsavedChanges, initial: true) { _, unsaved in reportUnsaved(unsaved) }
    }

    // MARK: Edición

    private var editor: some View {
        VStack(spacing: 0) {
            if let pr = currentPR, isOutdated {
                OutdatedReviewBanner(disabled: publishing) {
                    model.startReview(pr)
                    close()
                }
            }
            Divider()
            selectionBar
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(kept) { item in
                        FindingCard(
                            item: item, isSelected: selection(item.id), text: text(for: item),
                            isEdited: edited[item.id].map { $0 != item.finding.body } ?? false, focus: $focus,
                            initiallyExpanded: initiallyExpanded.contains(item.id)
                        )
                    }
                    if kept.isEmpty {
                        Text("Claude didn’t leave any findings to post.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                    if !discarded.isEmpty { discardedSection }
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        }
    }

    private var selectionBar: some View {
        HStack {
            (Text("\(selected.count) of \(kept.count + selectedDiscardedCount)").foregroundStyle(.primary).fontWeight(.semibold)
                + Text(" selected"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select All") { selected.formUnion(kept.map(\.id)) }
            Button("Select None") { selected.removeAll() }
        }
        .controlSize(.small)
        .disabled(publishing)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var selectedDiscardedCount: Int { discarded.filter { selected.contains($0.id) }.count }

    private var discardedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showDiscarded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showDiscarded ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                        .fontWeight(.semibold)
                    Text("Discarded by the filter (\(discarded.count))").fontWeight(.semibold)
                    Text("· Claude marked them as not applicable").foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            if showDiscarded {
                ForEach(discarded) { item in
                    DiscardedFindingCard(item: item, isSelected: selection(item.id))
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                ErrorBanner(messages: [error]).padding(.horizontal, -10)
            }
            if let rejected = inlineRejected {
                HStack {
                    Spacer()
                    Button("Post Everything in the Review Body") { publish(rejected, allInBody: true) }
                        .controlSize(.small)
                        .disabled(publishing)
                }
            }
            TextField("General comment (optional)", text: $general, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .general)
            Label("Comments will be posted in \(draft.language.displayName)", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Detected from the PR description. Your general comment is posted exactly as you write it.")
            HStack(spacing: 8) {
                Text("Posting as @\(draft.account) · \(selected.count) comment\(selected.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if publishing { ProgressView().controlSize(.small) }
                // Return never posts: the only action with a shortcut is Comment (⌘↩), and Approve asks for confirmation.
                Button("Request Changes") { publish(.requestChanges) }
                    .disabled(nothingToPublish)
                approveMenu
                Button("Comment") { publish(.comment) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(nothingToPublish)
            }
            .disabled(publishing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Sin hallazgos elegidos ni comentario general, Comentar y Pedir cambios no publicarían nada.
    private var nothingToPublish: Bool {
        selected.isEmpty && general.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasGeneralComment: Bool { !general.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Approve como menú desplegable con un título fijo: el botón principal aprueba con lo elegido y el menú ofrece
    /// las dos variantes con la cantidad de comentarios, o aprobar sin comentarios (sin tocar la selección ni lo editado). Siempre pide confirmación; Return nunca publica.
    private var approveMenu: some View {
        Menu {
            Button(ReviewSummaryText.approveWithCommentsItem(inline: selected.count, hasGeneral: hasGeneralComment)) {
                confirmApproval(withComments: true)
            }
            Button("Approve Without Comments…") { confirmApproval(withComments: false) }
                .disabled(nothingToPublish)
        } label: {
            Text("Approve")
        } primaryAction: {
            confirmApproval(withComments: true)
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .accessibilityLabel("Approve")
        .accessibilityHint("Opens a menu to approve with or without your comments")
    }

    private func confirmApproval(withComments: Bool) {
        let message = ReviewSummaryText.approval(
            repo: draft.repo.name, number: draft.number, account: draft.account,
            inline: withComments ? selected.count : 0, hasGeneral: withComments && hasGeneralComment
        )
        ConfirmAlert.present(title: "Approve this PR?", message: message, action: "Approve") {
            publish(.approve, withComments: withComments)
        }
    }

    // MARK: Bindings y acciones

    private func selection(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    private func text(for item: ReviewItem) -> Binding<String> {
        Binding(get: { edited[item.id] ?? item.finding.body }, set: { edited[item.id] = $0 })
    }

    /// Si falla, el error se muestra y la selección y lo editado quedan como estaban (spec §8.7).
    /// `withComments: false` publica solo el veredicto (sin comentarios inline ni cuerpo) y deja la selección y
    /// los textos de la ventana como están.
    private func publish(_ event: ReviewEvent, allInBody: Bool = false, withComments: Bool = true) {
        guard !publishing else { return }
        publishing = true
        error = nil
        inlineRejected = nil
        let comments = !withComments ? [] : draft.items.filter { selected.contains($0.id) }.map {
            SelectedComment(finding: $0.finding, body: edited[$0.id] ?? $0.finding.body)
        }
        let general = withComments ? self.general : ""
        Task { @MainActor in
            do {
                result = try await model.publish(
                    draft: draft, selected: comments, general: general, event: event, allInBody: allInBody || isOutdated
                )
            } catch {
                self.error = error.localizedDescription
                if error is InlineCommentsRejected { inlineRejected = event }
            }
            publishing = false
        }
    }
}

/// Encabezado: `repo#N` + "Abrir en GitHub", título y autor · ramas · `+adds −dels`.
private struct ReviewHeader: View {
    let draft: ReviewDraft
    let pr: PullRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PRReferenceLine(draft: draft, linkTitle: "Open on GitHub")
            Text(draft.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                AvatarView(login: draft.author, url: pr?.authorAvatarURL, size: 16)
                Text(draft.author).foregroundStyle(.primary)
                if let pr {
                    dot
                    Image(systemName: "arrow.triangle.branch").imageScale(.small).fontWeight(.semibold)
                    BranchChip(name: pr.headRef)
                    Image(systemName: "arrow.right").imageScale(.small).fontWeight(.semibold)
                    BranchChip(name: pr.baseRef)
                    dot
                    (Text("+\(pr.additions)").foregroundColor(Theme.greenText)
                        + Text(" −\(pr.deletions)").foregroundColor(Theme.redText))
                        .monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dot: some View { Text("·").foregroundStyle(.tertiary) }
}

private struct BranchChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.primary)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            .help(name)
    }
}

/// Barra naranja cuando el PR recibió commits después de la review: los comentarios van al cuerpo.
private struct OutdatedReviewBanner: View {
    let disabled: Bool
    let reReview: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("The PR changed: comments will be posted in the review body").font(.callout.weight(.medium))
            Spacer()
            Button("Review Again", action: reReview)
                .controlSize(.small)
                .disabled(disabled)
        }
        .foregroundStyle(Theme.orangeText)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Theme.tint(Theme.orange))
    }
}
