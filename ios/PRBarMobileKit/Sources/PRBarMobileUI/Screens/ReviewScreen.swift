import SwiftUI
import PRBarMobileCore
import PRBarWire

/// `review` (+ `review:menu`, `review:faceid` via the system prompt, `edit` sheet, `review:posted`).
public struct ReviewScreen: View {
    @Bindable var model: ReviewModel
    let app: PhoneApp?
    @State private var editing: FindingInfo?
    @State private var confirmCancel = false
    @Environment(\.dismiss) private var dismiss

    public init(model: ReviewModel, app: PhoneApp?) {
        self.model = model
        self.app = app
    }

    public var body: some View {
        Group {
            if let posted = model.posted {
                ReviewPostedView(posted: posted, prRef: Format.shortRef(model.pr)) {
                    model.finishPosted()
                    dismiss()
                }
            } else {
                ZStack(alignment: .bottom) {
                    ScrollView {
                        ReviewContent(model: model, back: { dismiss() }, chat: openChat, more: AnyView(moreMenu()),
                                      edit: { editing = $0 })
                            .padding(.bottom, 140)
                    }
                    if model.review?.phase == "ready" { ReviewBottomBar(model: model) }
                }
            }
        }
        .background(Tokens.bg)
        .task { await model.appear() }
        .onDisappear { Task { await model.disappear() } }
        .sheet(item: $editing) { finding in
            EditCommentSheet(finding: finding, position: (model.findings.firstIndex(of: finding) ?? 0) + 1,
                             total: model.findings.count) { body in
                await model.saveEdit(finding, body: body)
            }
        }
        .alert(model.alert ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .repairAlert(isPresented: model.needsRepair, app: app)
        .confirmationDialog("Cancel this review?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Review", role: .destructive) { Task { await model.cancelReview() } }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("Claude stops and what it did so far is lost.")
        }
    }

    func openChat() { app?.push(.chat(model.pr, .review)) }

    @ViewBuilder func moreMenu() -> some View {
        if model.isRunning {
            Button("Cancel Review", role: .destructive) { confirmCancel = true }
        } else if model.review != nil {
            Button("Dismiss") { Task { await model.dismissReview() } }
        }
        if let url = model.info?.url { Link("Open in GitHub", destination: url) }
    }
}

struct ReviewContent: View {
    let model: ReviewModel
    var back: () -> Void = {}
    var chat: () -> Void = {}
    var more = AnyView(EmptyView())
    var edit: (FindingInfo) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            NavHeader {
                GlassCircleButton("chevron.left", label: "Back", action: back)
            } trailing: {
                HStack(spacing: 10) {
                    GlassCircleButton("bubble.left.and.bubble.right", label: "Chat with Claude", action: chat)
                    MoreButton { more }
                }
            }
            .padding(.horizontal, -Metrics.gutter)
            if model.isOffline { OfflineNotice() }
            PRHeader(prID: model.pr, info: model.info, authorName: model.authorName, trailingChip: nil)
            if let review = model.review {
                SummaryCard(review: review, running: model.isRunning)
                if !model.findings.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Findings").font(Typo.section).foregroundStyle(Tokens.fg)
                        Spacer()
                        Text(model.includedSummary).font(Typo.footnote).foregroundStyle(Tokens.fg2)
                    }
                    .padding(.top, 4)
                    ForEach(model.findings, id: \.id) { finding in
                        FindingCardView(finding: finding, disabled: model.isOffline,
                                        toggle: { included in Task { await model.setIncluded(finding, included) } },
                                        edit: { edit(finding) })
                    }
                }
            } else {
                PrimaryButton("Review with Claude", symbol: "sparkles", enabled: !model.isOffline) {
                    Task { await model.startReview() }
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
    }
}

/// `acme/api #317`, the title, the author line and the branch chips.
struct PRHeader: View {
    @Environment(\.clock) private var clock
    let prID: String
    let info: PRInfo?
    let authorName: String
    var trailingChip: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: Format.headerRef(prID)).font(Typo.mono).foregroundStyle(Tokens.fg2)
            if let info {
                Text(verbatim: info.title).font(Typo.title).foregroundStyle(Tokens.fg)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    Avatar(name: authorName, login: info.author, size: 22)
                    Text(verbatim: "\(authorName) · \(Format.age(info.updatedAt, now: clock()))")
                        .font(Typo.footnote).foregroundStyle(Tokens.fg2)
                    DiffCounts(info.additions, info.deletions, font: Typo.footnote)
                    if let files = info.changedFiles {
                        Text(verbatim: "· " + Format.count(files, "file")).font(Typo.footnote).foregroundStyle(Tokens.fg2)
                    }
                }
                BranchChips(head: info.headRef, base: info.baseRef, trailing: trailingChip)
            }
        }
    }
}

struct SummaryCard: View {
    let review: ReviewInfo
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Claude's summary", systemImage: "sparkles").font(Typo.bodyBold).foregroundStyle(Tokens.violet)
                Spacer()
                if running { Spinner() }
                if let detail = review.detail {
                    Text(verbatim: detail).font(Typo.footnoteBold).foregroundStyle(Tokens.violet)
                }
            }
            if let summary = review.summary {
                Text(verbatim: summary).font(Typo.body).foregroundStyle(Tokens.fg).fixedSize(horizontal: false, vertical: true)
            } else if running {
                Text("Reviewing…").font(Typo.body).foregroundStyle(Tokens.fg2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.violetbg, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

struct FindingCardView: View {
    let finding: FindingInfo
    let disabled: Bool
    let toggle: @Sendable (Bool) -> Void
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SeverityPill(label: finding.severity.label, level: finding.severity.level)
                Text(verbatim: finding.location).font(Typo.monoSmall).foregroundStyle(Tokens.fg2)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                DesignToggle("Include finding \(finding.number), \(finding.severity.label)",
                             isOn: Binding(get: { finding.included }, set: toggle), disabled: disabled)
            }
            Text(verbatim: finding.title).font(Typo.bodyBold)
                .foregroundStyle(finding.included ? Tokens.fg : Tokens.fg2)
            Text(verbatim: finding.body).font(Typo.body)
                .foregroundStyle(finding.included ? Tokens.fg : Tokens.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: edit) {
                Label("Edit comment", systemImage: "pencil").font(Typo.bodyBold).foregroundStyle(Tokens.accentfg)
                    .frame(minHeight: 40)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
        .card()
    }
}

extension FindingInfo: @retroactive Identifiable {}

extension Severity {
    var level: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 2
        }
    }
}

/// The decision picker + "Post" (with `faceid` for Approve).
struct ReviewBottomBar: View {
    @Bindable var model: ReviewModel
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        BottomActionBar {
            decisionMenu.frame(maxWidth: .infinity)
        } primary: {
            PrimaryButton("Post", symbol: model.decision.needsFaceID ? "faceid" : nil, enabled: model.canPost) {
                Task { await model.post() }
            }
            .frame(width: 130)
            .accessibilityLabel(model.decision.needsFaceID ? "Post review, requires Face ID" : "Post review")
        }
    }

    var label: some View {
        HStack(spacing: 8) {
            Image(systemName: model.decision.symbol).foregroundStyle(color(model.decision))
            Text(model.decision.title).font(Typo.headline).foregroundStyle(Tokens.fg)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(Tokens.fg3)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: Metrics.bottomBarButton)
        .glassCapsule()
    }

    @ViewBuilder var decisionMenu: some View {
        if isSnapshot {
            label
        } else {
            Menu {
                Picker("Review decision", selection: $model.decision) {
                    ForEach(ReviewModel.Decision.allCases) { decision in
                        Label(decision.title, systemImage: decision.symbol).tag(decision)
                    }
                }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Review decision: \(model.decision.title)")
        }
    }

    func color(_ decision: ReviewModel.Decision) -> Token {
        switch decision {
        case .comment: Tokens.fg2
        case .requestChanges: Tokens.orange
        case .approve: Tokens.green
        }
    }
}

/// `review:posted`.
public struct ReviewPostedView: View {
    let posted: ReviewModel.Posted
    let prRef: String
    let done: () -> Void
    @Environment(\.openURL) private var openURL

    public init(posted: ReviewModel.Posted, prRef: String, done: @escaping () -> Void) {
        self.posted = posted
        self.prRef = prRef
        self.done = done
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                ResultBadge(symbol: "checkmark", size: 92)
                Text(posted.headline).font(Typo.title1).foregroundStyle(Tokens.fg)
                Text(verbatim: posted.message(prRef: prRef)).font(Typo.callout).foregroundStyle(Tokens.fg2)
                    .multilineTextAlignment(.center)
                VStack(spacing: 0) {
                    row("Decision") {
                        Text(posted.decision.title).font(Typo.bodyBold)
                            .foregroundStyle(posted.decision == .approve ? Tokens.green : posted.decision == .requestChanges ? Tokens.orange : Tokens.fg)
                    }
                    Hairline(inset: 16)
                    row("Inline comments") { Text("\(posted.comments)").font(Typo.body).foregroundStyle(Tokens.fg2) }
                    Hairline(inset: 16)
                    row("Posted from") { Text(verbatim: posted.macName).font(Typo.body).foregroundStyle(Tokens.fg2) }
                }
                .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                .padding(.top, 10)
            }
            .padding(.horizontal, 24)
            Spacer()
            VStack(spacing: 12) {
                TintedButton("View on GitHub", symbol: "arrow.up.right", height: 54) { openURL(posted.url) }
                PrimaryButton("Done", action: done)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Tokens.bg)
    }

    func row<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            Text(title).font(Typo.body).foregroundStyle(Tokens.fg)
            Spacer()
            value()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}

/// `edit`: the finding's comment in a large sheet.
struct EditCommentSheet: View {
    let finding: FindingInfo
    let position: Int
    let total: Int
    let save: (String) async -> Bool
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(finding: FindingInfo, position: Int, total: Int, save: @escaping (String) async -> Bool) {
        self.finding = finding
        self.position = position
        self.total = total
        self.save = save
        _text = State(initialValue: finding.body)
    }

    var body: some View {
        EditCommentContent(finding: finding, position: position, total: total, text: $text,
                           discard: { dismiss() },
                           save: { Task { if await save(text) { dismiss() } } })
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Tokens.sheet)
    }
}

struct EditCommentContent: View {
    @Environment(\.isSnapshot) private var isSnapshot
    let finding: FindingInfo
    let position: Int
    let total: Int
    @Binding var text: String
    let discard: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: discard) {
                    Text("Discard").font(Typo.headline).foregroundStyle(Tokens.red).padding(.horizontal, 16)
                        .frame(minHeight: Metrics.touch)
                }
                .buttonStyle(.plain).glassCapsule()
                Spacer()
                VStack(spacing: 1) {
                    Text("Edit Comment").font(Typo.headline).foregroundStyle(Tokens.fg)
                    Text("Finding \(position) of \(total)").font(Typo.footnote).foregroundStyle(Tokens.fg2)
                }
                Spacer()
                Button(action: save) {
                    Text("Save").font(Typo.headline).foregroundStyle(.white).padding(.horizontal, 18)
                        .frame(minHeight: Metrics.touch).background(Tokens.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                SeverityPill(label: finding.severity.label, level: finding.severity.level)
                Text(verbatim: finding.location).font(Typo.monoSmall).foregroundStyle(Tokens.fg2).lineLimit(1)
            }
            Text("COMMENT").font(Typo.footnote).foregroundStyle(Tokens.fg2).padding(.top, 4)
            Group {
                if isSnapshot {
                    Text(verbatim: text).font(Typo.large).foregroundStyle(Tokens.fg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(5)
                } else {
                    TextEditor(text: $text).font(Typo.large).scrollContentBackground(.hidden)
                }
            }
                .padding(12)
                .frame(minHeight: 250)
                .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(footer).font(Typo.footnote).foregroundStyle(Tokens.fg2)
            Spacer(minLength: 0)
        }
        .padding(Metrics.gutter)
        .padding(.top, 8)
    }

    var footer: String {
        Format.line(of: finding.location).map { "Markdown supported · posts on line \($0)" } ?? "Markdown supported"
    }
}

/// "More" (`ellipsis`): a system menu.
struct MoreButton<Content: View>: View {
    let content: () -> Content
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            GlassCircleButton("ellipsis", label: "More") {}
        } else {
            Menu(content: content) {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(Tokens.fg)
                    .frame(width: Metrics.touch, height: Metrics.touch)
            }
            .buttonStyle(.plain)
            .glassCircle()
            .accessibilityLabel("More")
        }
    }
}

/// A slim "offline" line on detail screens: cached data, actions off.
struct OfflineNotice: View {
    var body: some View {
        Label("Your Mac is offline. You're seeing cached data, and actions are off until your Mac is back.",
              systemImage: "moon.zzz")
            .font(Typo.footnote).foregroundStyle(Tokens.fg2)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension View {
    /// "Face ID changed. Pair this iPhone again from your Mac." with the way back to pairing.
    func repairAlert(isPresented: Bool, app: PhoneApp?) -> some View {
        alert("Face ID changed", isPresented: .constant(isPresented)) {
            Button("Pair Again") { Task { await app?.connection.unpair(); app?.didUnpair() } }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(PresenceFailure.keyInvalidMessage)
        }
    }
}
