import AppKit
import PRBarCore
import SwiftUI

/// Ventana de Merge (spec G.2): el resumen del PR (descripción, reviews, checks, conversaciones y archivos) y, abajo, la
/// barra con el motivo si no se puede, el método, el head que se va a mergear y el botón. El head es fijo (spec G.3):
/// si llegan commits nuevos aparece un banner y Merge se deshabilita hasta recargar. Chat de solo lectura en el panel.
struct MergeWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prStore: PRStore
    @ObservedObject var merges: MergeQueue
    @ObservedObject var session: MergeSession
    @ObservedObject var window: MergeWindowModel

    @State private var showsChat: Bool
    @State private var descriptionExpanded = false
    /// The panel's width, remembered between windows (320–480), shared with Review and Respond.
    @AppStorage("ChatPanelWidth") private var chatWidth = 360.0

    static let size = NSSize(width: 760, height: 820)

    init(model: AppModel, session: MergeSession, showsChat: Bool = false) {
        self.model = model
        prStore = model.prStore
        merges = model.merges
        self.session = session
        window = session.window
        _showsChat = State(initialValue: showsChat)
    }

    private var prID: String { session.prID }
    private var record: MergeRecord { session.record }
    private var current: ClassifiedPR? { prStore.snapshot?.items.first { $0.id == prID } }
    private var phase: MergePhase? { merges.phases[prID] }

    var body: some View {
        VStack(spacing: 0) {
            MergeHeader(record: record, detail: window.detail, pr: current?.pr)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
            if window.isStale && !isFinished {
                StaleHeadBanner(disabled: window.isLoading || phase?.isActive == true) {
                    Task { await model.reloadMergeWindow(prID: prID) }
                }
            }
            Divider()
            content
        }
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity, alignment: .top)
        // The chat is made when the panel first opens (not while drawing it).
        .onChange(of: showsChat && model.chatEnabled, initial: true) { _, shown in
            if shown && session.chat == nil { _ = model.mergeChat(prID: prID) }
        }
        .inspector(isPresented: Binding(get: { showsChat && model.chatEnabled }, set: { showsChat = $0 })) {
            chatPanel
                .inspectorColumnWidth(min: 320, ideal: chatWidth, max: 480)
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.width) { _, width in chatWidth = min(max(width, 320), 480) }
                })
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshMergeWindow(prID: prID) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh (⌘R)")
                .disabled(window.isLoading || isFinished)
            }
            if model.chatEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button { showsChat.toggle() } label: {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Chat with Claude (⇧⌘C)")
                }
            }
        }
    }

    private var isFinished: Bool {
        if case .merged? = phase { return true }
        return false
    }

    // MARK: Contenido

    @ViewBuilder
    private var content: some View {
        if let detail = window.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = window.loadError {
                        ErrorBanner(messages: ["Couldn’t refresh: \(error)"], horizontalInset: 0)
                    }
                    if let note = detail.incompleteNote {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(Theme.orangeText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    descriptionSection(detail)
                    MergeReviewsSection(detail: detail)
                    MergeChecksSection(detail: detail, prURL: record.url)
                    MergeConversationsSection(detail: detail, prURL: record.url)
                    MergeFilesSection(detail: detail, prURL: record.url)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bar }
        } else if let error = window.loadError, !window.isLoading {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Couldn’t load the PR").font(.headline)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try Again") { Task { await window.load() } }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MergeSkeleton()
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func descriptionSection(_ detail: MergeDetail) -> some View {
        let body = detail.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLong = body.count > 600 || body.split(separator: "\n", omittingEmptySubsequences: false).count > 12
        return MergeSection(title: "Description", systemImage: "text.alignleft") {
            if body.isEmpty {
                Text("No description").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ChatMarkdown.attributed(body))
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(isLong && !descriptionExpanded ? 12 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isLong {
                        Button(descriptionExpanded ? "Show Less" : "Show More") { descriptionExpanded.toggle() }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            }
        }
    }

    // MARK: Barra

    private var methods: [MergeMethod] { current.map { model.mergeOptions($0).methods } ?? MergeMethod.allCases }

    private var methodBinding: Binding<MergeMethod> {
        Binding(get: { model.mergeWindowMethod(prID: prID) ?? methods.first ?? .merge },
                set: { window.method = $0 })
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .failed(_, let error)? = phase {
                HStack(alignment: .top, spacing: 8) {
                    ErrorBanner(messages: [error.localizedDescription], horizontalInset: 0)
                    VStack(spacing: 4) {
                        Button("Retry") { model.retryMergeInWindow(prID: prID) }
                        Button("Dismiss") { model.dismissMergeError(prID: prID) }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            HStack(spacing: 10) {
                statusLabel
                Spacer(minLength: 8)
                Picker("Method", selection: methodBinding) {
                    ForEach(methods) { Text($0.actionTitle).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(busy)
                .help("Merge method")
                if let head = window.shownHead {
                    Text(head.prefix(7))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                        .help("The commit that will be merged: \(head)")
                        .accessibilityLabel("Head \(head.prefix(7))")
                }
                mergeButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var busy: Bool {
        switch phase {
        case .merging?, .merged?: true
        default: false
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if case .merging? = phase {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Merging…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if case .merged? = phase {
            Label("Merged", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.greenText)
        } else if let problem = model.mergeWindowProblem(prID: prID) {
            Label(problem, systemImage: window.isStale ? "exclamationmark.triangle" : "lock")
                .font(.callout)
                .foregroundStyle(window.isStale ? Theme.orangeText : .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if let note = current.flatMap({ model.mergeOptions($0).availability.note }) {
            Label(note, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Theme.orangeText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("Ready to merge into \(window.detail?.baseRef ?? current?.pr.baseRef ?? "the base branch")",
                  systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(Theme.greenText)
                .lineLimit(1)
        }
    }

    private var mergeButton: some View {
        Button(methodBinding.wrappedValue.actionTitle) { model.mergeFromWindow(prID: prID) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(busy || model.mergeWindowProblem(prID: prID) != nil)
            .help("\(methodBinding.wrappedValue.actionTitle) (⌘↩)")
    }

    // MARK: Chat

    @ViewBuilder
    private var chatPanel: some View {
        if let chat = session.chat {
            ChatPanel(chat: chat, unavailableReason: model.chatUnavailableReason, notice: chatNotice(chat),
                      logURL: model.mergeHistory.logURL(for: record.id))
        } else {
            Text("The chat needs the PR in PRBar’s list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func chatNotice(_ chat: ChatCoordinator) -> String? {
        guard case .merge(let target) = chat.subject, let shown = window.shownHead, target.headOid != shown else { return nil }
        return "Claude sees an older commit (\(target.headOid.prefix(7)))."
    }
}

/// `repo#N` + "Open on GitHub", el título y autor · ramas · `+adds −dels` · commits.
private struct MergeHeader: View {
    let record: MergeRecord
    let detail: MergeDetail?
    let pr: PullRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PRReferenceLine(repo: record.repo, number: record.number, url: record.url, linkTitle: "Open on GitHub")
            Text(detail?.title ?? pr?.title ?? record.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                let author = detail?.author ?? pr?.author ?? record.account
                AvatarView(login: author, url: detail?.authorAvatarURL ?? pr?.authorAvatarURL, size: 16)
                Text(author).foregroundStyle(.primary)
                if let head = detail?.headRef ?? pr?.headRef, let base = detail?.baseRef ?? pr?.baseRef {
                    dot
                    Image(systemName: "arrow.triangle.branch").imageScale(.small).fontWeight(.semibold)
                    MergeBranchChip(name: head)
                    Image(systemName: "arrow.right").imageScale(.small).fontWeight(.semibold)
                    MergeBranchChip(name: base)
                }
                if let detail {
                    dot
                    (Text("+\(detail.additions)").foregroundColor(Theme.greenText)
                        + Text(" −\(detail.deletions)").foregroundColor(Theme.redText))
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

private struct MergeBranchChip: View {
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

/// Banner naranja cuando llegaron commits después de abrir la ventana (spec G.3).
private struct StaleHeadBanner: View {
    let disabled: Bool
    let reload: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("New commits were pushed since you opened this").font(.callout.weight(.medium))
            Spacer()
            Button("Reload", action: reload)
                .controlSize(.small)
                .disabled(disabled)
        }
        .foregroundStyle(Theme.orangeText)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Theme.tint(Theme.orange))
    }
}

/// Una sección de la ventana: título con ícono, un texto a la derecha y el contenido en una tarjeta.
private struct MergeSection<Content: View>: View {
    let title: String
    let systemImage: String
    var trailing: String?
    var trailingColor: Color = .secondary
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.callout)
                        .foregroundStyle(trailingColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

private struct MergeReviewsSection: View {
    let detail: MergeDetail

    private var decision: (String, Color)? {
        switch detail.reviewDecision {
        case .approved: ("Approved", Theme.greenText)
        case .changesRequested: ("Changes requested", Theme.redText)
        case .reviewRequired: ("Review required", Theme.orangeText)
        case .none: nil
        }
    }

    var body: some View {
        MergeSection(title: "Reviews", systemImage: "person.2", trailing: decision?.0, trailingColor: decision?.1 ?? .secondary) {
            VStack(alignment: .leading, spacing: 8) {
                if detail.reviews.isEmpty {
                    Text("No reviews yet").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(detail.reviews, id: \.author) { review in
                    HStack(spacing: 8) {
                        AvatarView(login: review.author, url: review.avatarURL, size: 18)
                        Text(review.author).font(.callout)
                        pill(review.state)
                        Spacer()
                        if let date = review.submittedAt {
                            Text(ReviewDates.ago(date)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !detail.pendingReviewers.isEmpty {
                    Label("Waiting for review: " + detail.pendingReviewers.joined(separator: ", "), systemImage: "clock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if detail.reviewDecision == .reviewRequired {
                    Label("More approvals are required by branch protection", systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(Theme.orangeText)
                }
            }
        }
    }

    private func pill(_ state: MergeReviewSummary.State) -> StatusPill {
        switch state {
        case .approved: StatusPill(text: state.title, color: Theme.greenText, background: Theme.tint(Theme.green))
        case .changesRequested: StatusPill(text: state.title, color: Theme.redText, background: Theme.tint(Theme.red))
        case .commented, .dismissed: StatusPill(text: state.title, color: .secondary, background: Color.primary.opacity(0.08))
        }
    }
}

private struct MergeChecksSection: View {
    let detail: MergeDetail
    let prURL: URL

    private var summaryColor: Color {
        if detail.checks.contains(where: { $0.state == .failed && $0.isRequired }) { return Theme.redText }
        if detail.checks.contains(where: { $0.state == .failed }) { return Theme.orangeText }
        if detail.checks.contains(where: { $0.state == .running }) { return .secondary }
        return detail.checks.isEmpty ? .secondary : Theme.greenText
    }

    var body: some View {
        MergeSection(title: "Checks", systemImage: "checklist", trailing: detail.checksSummary, trailingColor: summaryColor) {
            VStack(alignment: .leading, spacing: 7) {
                if detail.checks.isEmpty {
                    Text("This PR has no checks").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(detail.checks.enumerated()), id: \.offset) { _, check in
                    HStack(spacing: 8) {
                        icon(check.state)
                        if let url = check.url {
                            Link(check.name, destination: url)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .pointingHandCursor()
                                .help(url.absoluteString)
                        } else {
                            Text(check.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        }
                        if check.isRequired {
                            StatusPill(text: "Required", color: .secondary, background: Color.primary.opacity(0.08))
                        }
                        Spacer(minLength: 8)
                        Text(check.duration.map(MergeCheck.durationText) ?? check.state.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(check.name), \(check.state.title)\(check.isRequired ? ", required" : "")")
                }
                if detail.moreChecks > 0 {
                    ExternalLink("and \(detail.moreChecks) more on GitHub", destination: prURL.appendingPathComponent("checks"))
                        .font(.callout)
                }
            }
        }
    }

    private func icon(_ state: MergeCheck.State) -> some View {
        let (name, color): (String, Color) = switch state {
        case .passed: ("checkmark.circle.fill", Theme.green)
        case .failed: ("xmark.circle.fill", Theme.red)
        case .running: ("clock.fill", Theme.orange)
        case .skipped: ("minus.circle.fill", .secondary)
        }
        return Image(systemName: name).foregroundStyle(color).accessibilityHidden(true)
    }
}

private struct MergeConversationsSection: View {
    let detail: MergeDetail
    let prURL: URL

    var body: some View {
        let unresolved = detail.unresolvedThreads
        MergeSection(title: "Conversations", systemImage: "bubble.left.and.bubble.right") {
            if unresolved > 0 {
                HStack(spacing: 8) {
                    Label("\(unresolved) unresolved conversation\(unresolved == 1 ? "" : "s")",
                          systemImage: "exclamationmark.bubble.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.orangeText)
                    Spacer()
                    ExternalLink("View on GitHub", destination: prURL).font(.callout)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(Color.yellow.opacity(0.18)))
            } else {
                Label(detail.totalThreads == 0 ? "No review conversations" : "All conversations are resolved",
                      systemImage: "checkmark.bubble")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MergeFilesSection: View {
    let detail: MergeDetail
    let prURL: URL

    private var trailing: String {
        var parts: [String] = []
        if let commits = detail.commitCount { parts.append(commits == 1 ? "1 commit" : "\(commits) commits") }
        parts.append("\(detail.changedFiles) file\(detail.changedFiles == 1 ? "" : "s")")
        parts.append("+\(detail.additions) −\(detail.deletions)")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        MergeSection(title: "Files", systemImage: "doc.on.doc", trailing: trailing) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(detail.files.enumerated()), id: \.offset) { _, file in
                    HStack(spacing: 8) {
                        Text(file.change.letter)
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                            .foregroundStyle(color(file.change))
                            .frame(width: 14)
                            .help(file.change.rawValue.capitalized)
                        Text(file.path)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.path)
                        Spacer(minLength: 8)
                        (Text("+\(file.additions)").foregroundColor(Theme.greenText)
                            + Text(" −\(file.deletions)").foregroundColor(Theme.redText))
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
                if detail.files.isEmpty {
                    Text("No files").font(.callout).foregroundStyle(.secondary)
                }
                if detail.moreFiles > 0 {
                    ExternalLink("and \(detail.moreFiles) more on GitHub", destination: prURL.appendingPathComponent("files"))
                        .font(.callout)
                }
            }
        }
    }

    private func color(_ change: MergeChangedFile.Change) -> Color {
        switch change {
        case .added: Theme.greenText
        case .removed: Theme.redText
        case .renamed, .copied: Theme.blueText
        case .modified, .changed: Theme.orangeText
        }
    }
}

/// Mientras carga el detalle: bloques grises con la forma de las secciones.
private struct MergeSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach([70, 46, 110, 32, 90], id: \.self) { height in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(width: 110, height: 13)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.05)).frame(height: CGFloat(height))
                }
            }
        }
        .accessibilityLabel("Loading the PR")
    }
}
