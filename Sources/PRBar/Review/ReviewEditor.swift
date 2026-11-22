import PRBarCore
import SwiftUI

/// El editor de la pestaña Review (spec M.1 "Review"): elegir y editar los hallazgos de Claude y publicarlos como una
/// sola review. Lo que se elige vive en el coordinador del draft (`chat.reviewEdits`): cambiar de PR o cerrar la
/// ventana no lo pierde (spec M.7).
struct ReviewEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prStore: PRStore
    let draft: ReviewDraft
    /// nil: sin "Close" después de publicar (la pestaña de la ventana principal).
    let close: (() -> Void)?
    /// The window's editable state (selection, texts, added findings, general comment), shared with the chat.
    @ObservedObject var chat: ChatCoordinator

    /// Esta ventana pidió publicar (hasta que termina).
    @State private var requestedPublish = false
    @State private var error: String?
    /// El último intento falló con un 422 por los comentarios inline: se ofrece publicar todo en el cuerpo.
    @State private var inlineRejected: ReviewEvent?
    @State private var result: PublishedReview?
    @State private var showDiscarded: Bool
    @State private var showHidden: Bool
    /// La decisión de la barra inferior (Approve / Comment / Request Changes).
    @State private var decision: ReviewEvent = .comment
    /// Findings whose comment starts expanded (snapshot mode).
    private let initiallyExpanded: Set<String>
    @FocusState private var focus: ReviewFocus?

    init(
        model: AppModel, draft: ReviewDraft, chat: ChatCoordinator, published: PublishedReview?, close: (() -> Void)?,
        initialState: InitialState = InitialState()
    ) {
        self.model = model
        prStore = model.prStore
        self.draft = draft
        self.chat = chat
        self.close = close
        _result = State(initialValue: published)
        // Reopened with discarded or hidden findings chosen to post: their section starts open.
        _showDiscarded = State(initialValue: initialState.showsDiscarded || chat.reviewEdits.selectedInDiscarded(of: draft))
        _showHidden = State(initialValue: chat.reviewEdits.selectedInHidden(of: draft))
        initiallyExpanded = initialState.expandedFindings
    }

    /// How the editor opens. The app always uses the defaults; snapshot mode opens the discarded section and an
    /// expanded finding (its general comment goes in the coordinator's `reviewEdits`).
    struct InitialState {
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

    /// Publicando desde esta ventana o desde `prbar review publish` (`AppModel.publishingReviews`): los botones de
    /// publicar se deshabilitan en los dos casos.
    private var publishing: Bool { requestedPublish || model.publishingReviews.contains(draft.id) }

    /// Publicado desde esta ventana o desde la CLI (`prbar review publish`).
    private var shownResult: PublishedReview? { result ?? model.publishedReviews[draft.id] }

    private var items: [ReviewItem] { chat.reviewEdits.items(of: draft) }
    private var kept: [ReviewItem] { items.filter { $0.keep && !$0.isHidden } }
    private var discarded: [ReviewItem] { items.filter { !$0.keep && !$0.isHidden } }
    /// Spec E.5: hidden by the user's settings (severity, categories, paths, maximum).
    private var hiddenBySettings: [ReviewItem] { items.filter(\.isHidden) }
    private var selected: Set<String> { chat.reviewEdits.selected }
    private var general: String { chat.reviewEdits.generalComment }

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(draft: draft, pr: currentPR?.pr, placement: model.placements.label(prID: draft.prID))
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 6) {
                ClaudeSummary(summary: draft.summary)
                if let usage = draft.usage, usage.runs > 0 {
                    // "3 agents · 1:12 · $0.42"
                    Text([usage.runs == 1 ? "1 agent" : "\(usage.runs) agents",
                          ClaudeTasksSidebar.clock(usage.durationSeconds), UsageFormat.cost(usage)].joined(separator: " · "))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(UsageFormat.note)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.tint(Theme.violet)))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            if let result = shownResult {
                ReviewPublishedView(result: result, close: close, model: model, repo: draft.repo)
            } else {
                editor
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Spec B.2: the chat waits while posting (`AppModel.publishReview` locks it); after posting it stays read only
        // and its worktree goes away.
        .onChange(of: shownResult != nil, initial: true) { _, posted in if posted { chat.markReadOnly() } }
    }

    // MARK: Edición

    private var editor: some View {
        VStack(spacing: 0) {
            if let pr = currentPR, isOutdated {
                OutdatedReviewBanner(disabled: publishing || model.jobsBlockedReason != nil) {
                    model.startReview(pr)
                    close?()
                }
            }
            Divider()
            selectionBar
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(kept) { item in
                        FindingCard(
                            item: item, number: chat.number(of: item.id) ?? 0, isSelected: selection(item.id),
                            text: text(for: item), isEdited: chat.reviewEdits.isEdited(item),
                            isHighlighted: chat.highlighted.contains(item.id), focus: $focus,
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
                    if !hiddenBySettings.isEmpty { hiddenSection }
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
            footer
        }
    }

    /// "Findings · 3 of 4 included" con All / None (entre los que mantuvo el filtro).
    private var selectionBar: some View {
        HStack {
            (Text("Findings").fontWeight(.semibold).foregroundColor(.primary)
                + Text(" · \(selected.count) of \(kept.count + selectedDiscardedCount) included"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("All") { chat.reviewEdits.selected.formUnion(kept.map(\.id)) }
                .help("Include every finding")
            Button("None") { chat.reviewEdits.selected.subtract(kept.map(\.id)) }
                .help("Include no findings")
        }
        .controlSize(.small)
        .disabled(publishing)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var selectedDiscardedCount: Int { (discarded + hiddenBySettings).filter { selected.contains($0.id) }.count }

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
                    DiscardedFindingCard(item: item, number: chat.number(of: item.id) ?? 0, isSelected: selection(item.id),
                                         isHighlighted: chat.highlighted.contains(item.id))
                }
            }
        }
    }

    private var hiddenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showHidden.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showHidden ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                        .fontWeight(.semibold)
                    Text("Hidden by your settings (\(hiddenBySettings.count))").fontWeight(.semibold)
                    Text("· Settings › Claude").foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            if showHidden {
                ForEach(hiddenBySettings) { item in
                    DiscardedFindingCard(item: item, number: chat.number(of: item.id) ?? 0, isSelected: selection(item.id),
                                         isHighlighted: chat.highlighted.contains(item.id), note: item.hiddenBy)
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
            TextField("General comment (optional)", text: $chat.reviewEdits.generalComment, axis: .vertical)
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
                    .lineLimit(1)
                Spacer(minLength: 4)
                if decision == .approve {
                    Button("Approve Without Comments…") { confirmApproval(withComments: false) }
                        .buttonStyle(.link)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
            // Its own row: next to the chat inspector the detail can be ~440 pt wide.
            HStack(spacing: 8) {
                Picker("Decision", selection: $decision) {
                    Text("Approve").tag(ReviewEvent.approve)
                    Text("Comment").tag(ReviewEvent.comment)
                    Text("Request Changes").tag(ReviewEvent.requestChanges)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)
                Spacer(minLength: 0)
                if publishing { ProgressView().controlSize(.small) }
                // Return never posts: Post Review is ⌘↩, and Approve asks for confirmation.
                Button("Post Review") { post() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(decision != .approve && nothingToPublish)
                    .help("Post Review (⌘↩)")
                    .fixedSize()
            }
            .disabled(publishing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .windowBar()
    }

    /// Sin hallazgos elegidos ni comentario general, Comentar y Pedir cambios no publicarían nada.
    private var nothingToPublish: Bool {
        selected.isEmpty && general.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasGeneralComment: Bool { !general.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Post Review con la decisión elegida. Approve siempre pide confirmación.
    private func post() {
        if decision == .approve {
            confirmApproval(withComments: true)
        } else {
            publish(decision)
        }
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
            get: { chat.reviewEdits.selected.contains(id) },
            set: { isOn in
                if isOn { chat.reviewEdits.selected.insert(id) } else { chat.reviewEdits.selected.remove(id) }
            }
        )
    }

    private func text(for item: ReviewItem) -> Binding<String> {
        Binding(get: { chat.reviewEdits.body(of: item) }, set: { chat.reviewEdits.bodies[item.id] = $0 })
    }

    /// Si falla, el error se muestra y la selección y lo editado quedan como estaban (spec §8.7).
    /// `withComments: false` publica solo el veredicto (sin comentarios inline ni cuerpo) y deja la selección y
    /// los textos de la ventana como están. `AppModel.publishReview` arma lo publicado (lo mismo que usa la CLI).
    private func publish(_ event: ReviewEvent, allInBody: Bool = false, withComments: Bool = true) {
        guard !publishing else { return }
        requestedPublish = true
        error = nil
        inlineRejected = nil
        Task { @MainActor in
            do {
                result = try await model.publishReview(draft: draft, event: event, withComments: withComments,
                                                       allInBody: allInBody)
            } catch {
                self.error = error.localizedDescription
                if error is InlineCommentsRejected { inlineRejected = event }
            }
            requestedPublish = false
        }
    }
}

/// Encabezado (spec M.1 "Review"): `owner/repo #N` + Open on GitHub, título de 20 pt y autor · ramas · `+/−` ·
/// archivos.
struct ReviewHeader: View {
    let draft: ReviewDraft
    let pr: PullRequest?
    /// Where the review ran (spec J): "on devbox" or "Ran on this Mac — devbox unreachable"; nil = this Mac.
    let placement: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(draft.repo.fullName) #\(draft.number)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                ExternalLink("Open on GitHub", destination: draft.url)
                    .font(.callout)
            }
            Text(draft.title)
                .font(.system(size: 20, weight: .semibold))
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
                    if let files = pr.changedFiles {
                        dot
                        Text(files == 1 ? "1 file" : "\(files) files")
                    }
                }
                if let placement {
                    dot
                    PlacementLabel(text: placement)
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
