import SwiftUI
import PRBarMobileCore
import PRBarWire

/// `respond` / `respond:fixci` (+ `respond:diff`).
public struct RespondScreen: View {
    @Bindable var model: RespondModel
    let app: PhoneApp?
    @State private var showingDiff = false
    @Environment(\.dismiss) private var dismiss

    public init(model: RespondModel, app: PhoneApp?) {
        self.model = model
        self.app = app
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                if showingDiff {
                    RespondDiffContent(model: model, back: { showingDiff = false }, chat: openChat)
                        .padding(.bottom, 140)
                } else {
                    RespondContent(model: model, back: { dismiss() }, chat: openChat, openDiff: openDiff)
                        .padding(.bottom, 140)
                }
            }
            if model.respond != nil { RespondBottomBar(model: model) }
        }
        .background(Tokens.bg)
        .task { await model.appear() }
        .onDisappear { Task { await model.disappear() } }
        .alert(model.alert ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .alert("Undo Claude’s changes?", isPresented: Binding(get: { model.undoConfirmation != nil },
                                                              set: { if !$0 { model.undoConfirmation = nil } })) {
            Button("Undo", role: .destructive) { Task { await model.confirmUndo() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: model.undoConfirmation ?? "")
        }
        .repairAlert(isPresented: model.needsRepair, app: app)
    }

    func openChat() { app?.push(.chat(model.pr, .respond)) }

    func openDiff() {
        showingDiff = true
        Task { await model.loadDiff() }
    }
}

struct RespondContent: View {
    let model: RespondModel
    var back: () -> Void = {}
    var chat: () -> Void = {}
    var openDiff: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            NavHeader {
                GlassCircleButton("chevron.left", label: "Back", action: back)
            } center: {
                Text(model.title).font(Typo.headline).foregroundStyle(Tokens.fg)
            } trailing: {
                GlassCircleButton("bubble.left.and.bubble.right", label: "Chat with Claude", action: chat)
            }
            .padding(.horizontal, -Metrics.gutter)
            if model.isOffline { OfflineNotice() }
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: Format.headerRef(model.pr)).font(Typo.mono).foregroundStyle(Tokens.fg2)
                if let info = model.info {
                    Text(verbatim: info.title).font(Typo.title).foregroundStyle(Tokens.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                headerStatus
            }
            if model.respond == nil {
                PrimaryButton(model.mode == .feedback ? "Respond with Claude" : "Fix CI with Claude", symbol: "sparkles",
                              enabled: !model.isOffline) {
                    Task { await model.start() }
                }
            } else {
                if model.isRunning || model.isDone { ProgressCard(model: model) }
                if model.mode == .feedback { feedback } else { checks }
                if model.isDone {
                    ChangedFilesCard(stat: model.respond?.diffStat, open: openDiff)
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
    }

    var headerStatus: some View {
        let status = model.headerStatus
        let style: (String, Token) = switch status.tone {
        case .orange: ("exclamationmark.triangle.fill", Tokens.orange)
        case .red: ("xmark.octagon.fill", Tokens.red)
        case .green: ("checkmark.circle.fill", Tokens.green)
        }
        return Label { Text(verbatim: status.text) } icon: { Image(systemName: style.0) }
            .font(Typo.footnoteMedium).foregroundStyle(style.1).labelStyle(TightLabel())
    }

    @ViewBuilder var feedback: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Feedback").font(Typo.section).foregroundStyle(Tokens.fg)
            Spacer()
            Text(model.selectionSummary).font(Typo.footnote).foregroundStyle(Tokens.fg2)
        }
        .padding(.top, 4)
        ForEach(model.items, id: \.id) { item in
            CommentCard(item: item, name: model.displayName(item.reviewer), disabled: model.isOffline || model.isRunning) {
                Task { await model.toggle(item) }
            }
        }
    }

    @ViewBuilder var checks: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Failed checks").font(Typo.section).foregroundStyle(Tokens.fg)
            Spacer()
            if let summary = model.checksSummary { Text(summary).font(Typo.footnote).foregroundStyle(Tokens.fg2) }
        }
        .padding(.top, 4)
        ForEach(model.checks) { check in CheckCard(check: check) }
    }
}

struct CommentCard: View {
    let item: RespondItemInfo
    let name: String
    let disabled: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                ZStack {
                    Circle().stroke(item.implement ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Tokens.fg3), lineWidth: 1.5)
                    if item.implement {
                        Circle().fill(Tokens.accent)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 26, height: 26)
                .frame(width: Metrics.touch, height: Metrics.touch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .padding(-9)
            .accessibilityLabel("Implement comment \(item.number)")
            .accessibilityValue(item.implement ? "selected" : "not selected")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Avatar(name: name, login: item.reviewer, size: 20)
                    Text(verbatim: name).font(Typo.bodyBold).foregroundStyle(Tokens.fg)
                }
                Text(verbatim: item.location).font(Typo.monoSmall).foregroundStyle(Tokens.fg2).lineLimit(1)
                    .truncationMode(.head)
                Text(verbatim: item.thread.first ?? "").font(Typo.body).foregroundStyle(Tokens.fg)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }
}

struct CheckCard: View {
    let check: CICheckFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Tokens.red)
                Text(verbatim: check.name).font(Typo.bodyBold).foregroundStyle(Tokens.fg)
                Spacer()
                if let duration = RespondModel.duration(check) { Text(verbatim: duration).font(Typo.footnote).foregroundStyle(Tokens.fg2) }
            }
            if let lines = check.logExcerpt, !lines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).font(Typo.code)
                            .foregroundStyle(Self.isFailure(line) ? Tokens.red : Tokens.fg2)
                            .lineLimit(1)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.codebg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .card()
    }

    static func isFailure(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("fail") || lower.contains("error") || line.contains("✕")
    }
}

/// Claude's progress: Analyzing / Implementing / Running tests.
struct ProgressCard: View {
    let model: RespondModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(model.progressTitle, systemImage: model.isDone ? "checkmark.circle.fill" : "sparkles")
                    .font(Typo.bodyBold).foregroundStyle(model.isDone ? Tokens.green : Tokens.violet)
                Spacer()
                if let elapsed = model.elapsed { Text(elapsed).font(Typo.footnote.monospacedDigit()).foregroundStyle(Tokens.fg2) }
            }
            .padding(.bottom, 4)
            ForEach(model.stages) { stage in
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        switch stage.state {
                        case .current: Spinner(size: 18)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.green)
                        case .pending: Image(systemName: "circle.dashed").foregroundStyle(Tokens.fg3)
                        }
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.title).font(stage.state == .current ? Typo.callout.weight(.semibold) : Typo.callout)
                            .foregroundStyle(stage.state == .pending ? Tokens.fg3 : Tokens.fg)
                        if let detail = stage.detail {
                            Text(verbatim: detail).font(Typo.monoSmall).foregroundStyle(Tokens.fg2)
                        }
                    }
                    Spacer()
                }
                .frame(minHeight: 44)
            }
        }
        .card()
    }
}

struct ChangedFilesCard: View {
    let stat: String?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(Tokens.fg2)
                Text(verbatim: stat ?? "Changes").font(Typo.body).foregroundStyle(Tokens.fg).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Tokens.fg3)
            }
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Changes, \(stat ?? "")")
    }
}

/// `respond:diff`: file chips, the diff (horizontal scroll), and the drafted reply.
struct RespondDiffContent: View {
    @Bindable var model: RespondModel
    var back: () -> Void = {}
    var chat: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NavHeader {
                GlassCircleButton("chevron.left", label: "Back", action: back)
            } center: {
                Text("Changes").font(Typo.headline).foregroundStyle(Tokens.fg)
            } trailing: {
                GlassCircleButton("bubble.left.and.bubble.right", label: "Chat with Claude", action: chat)
            }
            .padding(.horizontal, -Metrics.gutter)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: Format.headerRef(model.pr)).font(Typo.mono).foregroundStyle(Tokens.fg2)
                if let info = model.info {
                    Text(verbatim: info.title).font(Typo.title).foregroundStyle(Tokens.fg)
                }
                let status = model.headerStatus
                Label { Text(verbatim: status.text) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .font(Typo.footnoteMedium).foregroundStyle(Tokens.green).labelStyle(TightLabel())
            }
            HorizontalScroll {
                HStack(spacing: 8) {
                    ForEach(model.diffFiles) { file in
                        FileChip(file: file, selected: file.path == model.selectedDiff?.path) { model.selectedFile = file.path }
                    }
                }
            }
            if model.diffTruncated {
                NoticeBanner("The diff is too long to show in full.")
            }
            if let file = model.selectedDiff { DiffCard(file: file) }
            if model.mode == .feedback, let reply = model.items.first(where: \.reply) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "Reply to \(model.displayName(reply.reviewer))").font(Typo.bodyBold).foregroundStyle(Tokens.fg)
                    Text(verbatim: reply.replyText).font(Typo.body).foregroundStyle(Tokens.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .card()
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
    }
}

struct FileChip: View {
    let file: DiffFile
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                if file.isSensitive { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.orange) }
                Text(verbatim: file.name).foregroundStyle(selected ? Tokens.bg : Tokens.fg)
                Text(verbatim: "+\(file.additions)").foregroundStyle(selected ? Tokens.bg : Tokens.green)
                Text(verbatim: "−\(file.deletions)").foregroundStyle(selected ? Tokens.bg : Tokens.red)
            }
            .font(Typo.monoSmall)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(selected ? AnyShapeStyle(Tokens.fg) : AnyShapeStyle(Tokens.bg2), in: Capsule())
            .frame(minHeight: Metrics.touch)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(file.name), \(file.additions) additions, \(file.deletions) deletions\(file.isSensitive ? ", sensitive" : "")")
    }
}

struct DiffCard: View {
    let file: DiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(Tokens.fg2)
                Text(verbatim: file.path).font(Typo.monoSmall).foregroundStyle(Tokens.fg).lineLimit(1).truncationMode(.head)
                Spacer()
                DiffCounts(file.additions, file.deletions)
            }
            .padding(14)
            Hairline()
            HorizontalScroll {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(file.lines) { line in DiffLineView(line: line) }
                }
                .padding(.vertical, 6)
            }
            .accessibilityLabel("Diff, scrolls horizontally")
        }
        .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

struct DiffLineView: View {
    let line: DiffFile.Line

    var body: some View {
        HStack(spacing: 0) {
            Text(line.number.map(String.init) ?? "").foregroundStyle(Tokens.fg3).frame(width: 34, alignment: .trailing)
            Text(sign).foregroundStyle(signColor).frame(width: 18)
            Text(verbatim: line.text).foregroundStyle(line.kind == .hunk ? Tokens.accentfg : Tokens.fg)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
        }
        .font(Typo.code)
        .frame(minHeight: 21)
        .padding(.trailing, 12)
        .background(background)
    }

    var sign: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        default: ""
        }
    }

    var signColor: Token {
        line.kind == .addition ? Tokens.green : Tokens.red
    }

    var background: AnyShapeStyle {
        switch line.kind {
        case .addition: AnyShapeStyle(Tokens.addbg)
        case .deletion: AnyShapeStyle(Tokens.delbg)
        case .hunk: AnyShapeStyle(Tokens.accentbg)
        case .context: AnyShapeStyle(Color.clear)
        }
    }
}

/// Stop while running / Undo when done; the primary push with `faceid`.
struct RespondBottomBar: View {
    let model: RespondModel

    var body: some View {
        BottomActionBar {
            if model.isRunning {
                GlassCapsuleButton("Stop", symbol: "stop.fill", tint: Tokens.red, enabled: !model.isOffline) {
                    Task { await model.stop() }
                }
            } else if model.isDone {
                GlassCapsuleButton("Undo", symbol: "arrow.uturn.backward", enabled: !model.isOffline) {
                    Task { await model.undo() }
                }
            } else if model.mode == .feedback {
                GlassCapsuleButton("Implement", symbol: "sparkles", enabled: !model.isOffline) {
                    Task { await model.implement() }
                }
            }
        } primary: {
            PrimaryButton(model.primaryTitle, symbol: model.primaryNeedsFaceID ? "faceid" : nil, enabled: model.canPush) {
                Task { await model.push() }
            }
            .accessibilityLabel(model.primaryNeedsFaceID ? "\(model.primaryTitle), requires Face ID" : model.primaryTitle)
        }
    }
}
