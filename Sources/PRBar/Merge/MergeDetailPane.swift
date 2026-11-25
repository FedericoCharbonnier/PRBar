import AppKit
import PRBarCore
import SwiftUI

/// Qué muestra el detalle de merge: Details (PR ajeno, solo lectura) o Merge (PR propio, con el bloque de merge).
enum MergePaneMode { case details, merge }

/// Las pestañas Details y Merge (spec M.1, spec G.2): el resumen del PR (descripción, conversaciones y archivos a la
/// izquierda; reviews y checks a la derecha) y, en Merge, el bloque de merge en la columna derecha: método con su nota,
/// borrar la rama, aviso de Slack, el head que se va a mergear y el botón (⇧⌘M). El head es fijo (spec G.3): si llegan
/// commits nuevos aparece un banner y Merge se deshabilita hasta recargar.
struct MergeDetailPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prStore: PRStore
    @ObservedObject var merges: MergeQueue
    @ObservedObject var session: MergeSession
    @ObservedObject var window: MergeDetailModel
    let mode: MergePaneMode

    @State private var descriptionExpanded = false

    init(model: AppModel, session: MergeSession, mode: MergePaneMode) {
        self.model = model
        prStore = model.prStore
        merges = model.merges
        self.session = session
        window = session.window
        self.mode = mode
    }

    private var prID: String { session.prID }
    private var record: MergeRecord { session.record }
    private var current: ClassifiedPR? { prStore.snapshot?.items.first { $0.id == prID } }
    private var phase: MergePhase? { merges.phases[prID] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                MergeHeader(record: record, detail: window.detail, pr: current?.pr)
                if mode == .merge, let badge = statusBadge {
                    StatusPill(text: badge.text, color: badge.color, background: Theme.tint(badge.tint))
                        .padding(.top, 2)
                }
            }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // La primera vez carga el resumen; al volver a la pestaña lo refresca con el head fijo.
        .task(id: prID) { await model.loadMergeDetail(prID: prID) }
        // Pull Request › Merge… (⇧⌘M) en la pestaña Merge.
        .windowCommand(.merge, enabled: mode == .merge && canMerge) { model.mergeFromWindow(prID: prID) }
        // View › Refresh (⌘R) mientras se ve la pestaña.
        .windowCommand(.refresh, enabled: !(window.isLoading || isFinished)) {
            Task { await model.refreshMergeWindow(prID: prID) }
        }
    }

    private var isFinished: Bool {
        if case .merged? = phase { return true }
        return false
    }

    /// "Ready", "Blocked", "Checks failing", "Merging…", "Merged" arriba a la derecha.
    private var statusBadge: (text: String, color: Color, tint: Color)? {
        switch phase {
        case .merged?: return ("Merged", Theme.greenText, Theme.green)
        case .merging?: return ("Merging…", .secondary, .secondary)
        case .failed?: return ("Failed", Theme.redText, Theme.red)
        default: break
        }
        guard window.detail != nil || current != nil else { return nil }
        if window.isStale { return ("New commits", Theme.orangeText, Theme.orange) }
        if model.mergeWindowProblem(prID: prID) == nil { return ("Ready", Theme.greenText, Theme.green) }
        if window.detail?.checks.contains(where: { $0.state == .failed && $0.isRequired }) == true
            || current?.pr.ciState == .failure {
            return ("Checks failing", Theme.redText, Theme.red)
        }
        return ("Blocked", Theme.orangeText, Theme.orange)
    }

    // MARK: Contenido

    @ViewBuilder
    private var content: some View {
        if let detail = window.detail {
            GeometryReader { geometry in
                ScrollView {
                    columns(detail, twoColumns: geometry.size.width >= 600)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                }
            }
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

    /// Dos columnas (izquierda: descripción, conversaciones, archivos; derecha, 240 pt: reviews, checks y el bloque de
    /// merge); en un detalle angosto (con el chat abierto), una sola.
    @ViewBuilder
    private func columns(_ detail: MergeDetail, twoColumns: Bool) -> some View {
        if twoColumns {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) { mainSections(detail) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 14) { sideSections(detail) }
                    .frame(width: Theme.MainLayout.mergeSideColumnWidth)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if mode == .merge { mergeBlock }
                mainSections(detail)
                MergeReviewsSection(detail: detail)
                MergeChecksSection(detail: detail, prURL: record.url)
            }
        }
    }

    @ViewBuilder
    private func mainSections(_ detail: MergeDetail) -> some View {
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
        MergeConversationsSection(detail: detail, prURL: record.url)
        MergeFilesSection(detail: detail, prURL: record.url)
    }

    @ViewBuilder
    private func sideSections(_ detail: MergeDetail) -> some View {
        MergeReviewsSection(detail: detail)
        MergeChecksSection(detail: detail, prURL: record.url)
        if mode == .merge { mergeBlock }
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

    // MARK: Bloque de merge

    private var methods: [MergeMethod] { current.map { model.mergeOptions($0).methods } ?? MergeMethod.allCases }

    private var methodBinding: Binding<MergeMethod> {
        Binding(get: { model.mergeWindowMethod(prID: prID) ?? methods.first ?? .merge },
                set: { window.method = $0 })
    }

    private var baseRef: String { window.detail?.baseRef ?? current?.pr.baseRef ?? "the base branch" }

    /// Qué hace cada método (debajo del selector).
    private func methodNote(_ method: MergeMethod) -> String {
        switch method {
        case .squash: "Combines all commits into one on \(baseRef)."
        case .merge: "Adds all commits to \(baseRef) with a merge commit."
        case .rebase: "Adds all commits on top of \(baseRef), without a merge commit."
        }
    }

    private var mergeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(_, let error)? = phase {
                ErrorBanner(messages: [error.localizedDescription], horizontalInset: 0)
                HStack {
                    Button("Retry") { model.retryMergeInWindow(prID: prID) }
                    Button("Dismiss") { model.dismissMergeError(prID: prID) }
                }
                .controlSize(.small)
            }
            Picker("Method", selection: methodBinding) {
                ForEach(methods) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(busy)
            .help("Merge method")
            Text(methodNote(methodBinding.wrappedValue))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            infoRows
            statusLabel
            HStack(spacing: 8) {
                if let head = window.shownHead {
                    HStack(spacing: 5) {
                        Text("Head").foregroundStyle(.secondary)
                        Text(head.prefix(7))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                    .help("The merge is pinned to this commit (\(head)): if someone pushes after it, GitHub refuses the merge "
                          + "instead of merging code you didn’t see.")
                    .accessibilityLabel("Head commit \(head.prefix(7))")
                }
                Spacer(minLength: 0)
            }
            mergeButton
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color.primary.opacity(0.08)))
    }

    /// "Delete branch after merge" y "Post in #canal": informativas (el ajuste del repo y el aviso automático de Slack;
    /// decisión 6 del plan 21).
    @ViewBuilder
    private var infoRows: some View {
        if let item = current {
            let settings = prStore.snapshot?.repoMergeSettings[Snapshot.scope(account: item.account, repo: item.pr.repo)]
            let deletes = settings?.deleteBranchOnMerge == true
            Label(deletes ? "Delete branch after merge" : "Branch is kept after merge",
                  systemImage: deletes ? "checkmark.circle" : "minus.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("The repo’s setting on GitHub (Settings › General), not a choice made here")
            let config = model.configStore.config
            if config.slack.enabled, config.slack.postMerged,
               let channel = config.repoConfig(account: item.account, repo: item.pr.repo)?.slackChannelName {
                Label("Post in #\(channel)", systemImage: "number")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("PRBar replies “Merged” in the PR’s Slack thread")
            }
        }
    }

    private var canMerge: Bool { !busy && model.mergeWindowProblem(prID: prID) == nil }

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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(problem, systemImage: window.isStale ? "exclamationmark.triangle" : "lock")
                    .font(.callout)
                    .foregroundStyle(window.isStale ? Theme.orangeText : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Mi PR con conflictos: Claude los resuelve en la pestaña Respond (spec C.2).
                if problem == MergePolicy.conflicts, let item = current, model.isConflictsCandidate(item) {
                    Button("Resolve Conflicts") {
                        model.startConflicts(item)
                        model.navigate(to: .pr(prID: prID, tab: .respond))
                    }
                    .controlSize(.small)
                    .disabled(model.conflictsUnavailableReason(item) != nil)
                    .help(model.conflictsUnavailableReason(item) ?? "PRBar merges the base and Claude resolves the conflicts")
                }
            }
        } else if let note = current.flatMap({ model.mergeOptions($0).availability.note }) {
            Label(note, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Theme.orangeText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("Ready to merge into \(baseRef)", systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(Theme.greenText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mergeButton: some View {
        Button { model.mergeFromWindow(prID: prID) } label: {
            Text(methodBinding.wrappedValue.actionTitle).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        // ⇧⌘M es del menú Pull Request › Merge… (lo registra `body`): con los dos, el del menú gana.
        .disabled(!canMerge)
        .help("\(methodBinding.wrappedValue.actionTitle) (⇧⌘M)")
    }
}

/// El chat de la pestaña Merge (spec G.4): se crea la primera vez que se abre el inspector.
struct MergeChatPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: MergeSession
    @ObservedObject var window: MergeDetailModel

    init(model: AppModel, session: MergeSession) {
        self.model = model
        self.session = session
        window = session.window
    }

    var body: some View {
        Group {
            if let chat = session.chat {
                ChatPanel(chat: chat, unavailableReason: model.chatUnavailableReason(for: chat), notice: chatNotice(chat),
                          host: model.chatHost(chat), logURL: model.mergeHistory.logURL(for: session.record.id))
            } else {
                Text("The chat needs the PR in PRBar’s list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if session.chat == nil { _ = model.mergeChat(prID: session.prID) } }
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
    /// The trailing text's tooltip (the longer form).
    var trailingHelp: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .fixedSize()
                Spacer(minLength: 8)
                if let trailing {
                    // Wraps in the narrow side column rather than cutting the counts off.
                    Text(trailing)
                        .font(.callout)
                        .foregroundStyle(trailingColor)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(trailingHelp ?? trailing)
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
                        Text(review.author).font(.callout).lineLimit(1).truncationMode(.tail)
                        pill(review.state)
                        Spacer()
                        if let date = review.submittedAt {
                            // Short ("40 min", "2h", like the list's ages): "40 minutes ago" wrapped to three lines.
                            Text(RelativeAge.short(from: date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                                .help(ReviewDates.ago(date))
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
    /// Las primeras 5 y "Show N more" (spec M.1 "Merge").
    @State private var showsAll = false
    private static let limit = 5

    private var shownChecks: [MergeCheck] { showsAll ? detail.checks : Array(detail.checks.prefix(Self.limit)) }

    private var summaryColor: Color {
        if detail.checks.contains(where: { $0.state == .failed && $0.isRequired }) { return Theme.redText }
        if detail.checks.contains(where: { $0.state == .failed }) { return Theme.orangeText }
        if detail.checks.contains(where: { $0.state == .running }) { return .secondary }
        return detail.checks.isEmpty ? .secondary : Theme.greenText
    }

    var body: some View {
        MergeSection(title: "Checks", systemImage: "checklist", trailing: detail.checksShortSummary, trailingColor: summaryColor,
                     trailingHelp: detail.checksSummary) {
            VStack(alignment: .leading, spacing: 7) {
                if detail.checks.isEmpty {
                    Text("This PR has no checks").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(shownChecks.enumerated()), id: \.offset) { _, check in
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
                if detail.checks.count > Self.limit && !showsAll {
                    Button("Show \(detail.checks.count - Self.limit) more") { showsAll = true }
                        .buttonStyle(.link)
                        .font(.callout)
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
        MergeSection(title: "Conversations", systemImage: "bubble.left.and.bubble.right") {
            if detail.conversationsNeedAttention {
                HStack(spacing: 8) {
                    Label(detail.conversationsSummary, systemImage: "exclamationmark.bubble.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.orangeText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    ExternalLink("View on GitHub", destination: prURL).font(.callout)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(Color.yellow.opacity(0.18)))
            } else {
                Label(detail.conversationsSummary, systemImage: "checkmark.bubble")
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
