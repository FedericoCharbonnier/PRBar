import SwiftUI
import PRBarMobileCore
import PRBarWire

/// `merge` (+ `merge:faceid` via the system prompt, `merge:merged`).
public struct MergeScreen: View {
    @Bindable var model: MergeModel
    let app: PhoneApp?
    @Environment(\.dismiss) private var dismiss

    public init(model: MergeModel, app: PhoneApp?) {
        self.model = model
        self.app = app
    }

    public var body: some View {
        Group {
            if model.merged != nil {
                MergedView(model: model, close: { dismiss() }, chat: openChat)
            } else {
                ScrollView {
                    MergeContent(model: model, back: { dismiss() }, chat: openChat).padding(.bottom, 40)
                }
            }
        }
        .background(Tokens.bg)
        .task { await model.load() }
        .alert(model.alert ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .repairAlert(isPresented: model.needsRepair, app: app)
    }

    func openChat() { app?.push(.chat(model.pr, .merge)) }
}

struct MergeContent: View {
    @Bindable var model: MergeModel
    var back: () -> Void = {}
    var chat: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            NavHeader {
                GlassCircleButton("chevron.left", label: "Back", action: back)
            } trailing: {
                GlassCircleButton("bubble.left.and.bubble.right", label: "Ask Claude about this PR", action: chat)
            }
            .padding(.horizontal, -Metrics.gutter)
            if model.isOffline { OfflineNotice() }
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: Format.headerRef(model.pr)).font(Typo.mono).foregroundStyle(Tokens.fg2)
                Text(verbatim: model.preview?.title ?? "").font(Typo.title).foregroundStyle(Tokens.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if let preview = model.preview {
                    HStack(spacing: 8) {
                        BranchChips(head: preview.headRef, base: preview.baseRef)
                        if let detail = preview.detail { DiffCounts(detail.additions, detail.deletions, font: Typo.footnote) }
                    }
                }
            }
            if let problem = model.preview?.problem ?? model.preview?.previousError {
                NoticeBanner(problem, symbol: "xmark.octagon.fill", tone: Tokens.red, background: Tokens.redbg)
            }
            if let body = model.detail?.body, !body.isEmpty {
                Text(verbatim: body).font(Typo.body).foregroundStyle(Tokens.fg).fixedSize(horizontal: false, vertical: true)
                    .card()
            }
            if model.preview != nil { summary }
            if model.preview != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MERGE METHOD").font(Typo.footnote).foregroundStyle(Tokens.fg2).padding(.leading, 4)
                    DesignSegmented(MergeMethod.allCases.map { ($0, $0.title) }, selection: $model.method)
                    Text(model.methodNote(model.method)).font(Typo.footnote).foregroundStyle(Tokens.fg2).padding(.leading, 4)
                }
                PrimaryButton("Merge", symbol: "faceid", height: 58, enabled: model.canMerge) {
                    Task { await model.merge() }
                }
                .accessibilityLabel("Merge, requires Face ID")
            } else if model.isLoading {
                HStack { Spacer(); Spinner(tint: Tokens.fg2, size: 22); Spacer() }.padding(.top, 40)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
    }

    var summary: some View {
        VStack(spacing: 0) {
            ForEach(model.reviewers) { reviewer in
                row {
                    Avatar(name: reviewer.name, login: reviewer.login, size: 26)
                } title: {
                    Text(verbatim: reviewer.name)
                } value: {
                    Text(verbatim: reviewer.approved ? "✓ \(reviewer.state)" : reviewer.state)
                        .font(Typo.bodyBold).foregroundStyle(reviewer.approved ? Tokens.green : Tokens.orange)
                }
                Hairline(inset: 52)
            }
            row { icon("checklist") } title: { Text("Checks") } value: {
                Text(model.checksText).font(Typo.bodyBold).foregroundStyle(model.checksPassing ? Tokens.green : Tokens.red)
            }
            Hairline(inset: 52)
            row { icon("text.bubble") } title: { Text("Unresolved conversations") } value: {
                Text(model.conversationsText).font(Typo.body).foregroundStyle(Tokens.fg2)
            }
            Hairline(inset: 52)
            row { icon("doc.text") } title: { Text("Files") } value: {
                HStack(spacing: 6) {
                    Text(model.filesText).font(Typo.body).foregroundStyle(Tokens.fg2)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Tokens.fg3)
                }
            }
        }
        .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16)).foregroundStyle(Tokens.fg2).frame(width: 26)
    }

    func row<L: View, T: View, V: View>(@ViewBuilder leading: () -> L, @ViewBuilder title: () -> T,
                                        @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 12) {
            leading()
            title().font(Typo.body).foregroundStyle(Tokens.fg).lineLimit(1)
            Spacer(minLength: 8)
            value()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .accessibilityElement(children: .combine)
    }
}

/// `merge:merged`.
struct MergedView: View {
    let model: MergeModel
    let close: () -> Void
    let chat: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            NavHeader {
                GlassCircleButton("xmark", label: "Close", action: close)
            } trailing: {
                GlassCircleButton("bubble.left.and.bubble.right", label: "Ask Claude about this PR", action: chat)
            }
            .padding(.top, 8)
            Spacer()
            VStack(spacing: 14) {
                ResultBadge(symbol: "arrow.triangle.merge", size: 96, fill: Tokens.accent)
                Text("Merged").font(.system(size: 30, weight: .bold)).foregroundStyle(Tokens.fg)
                Text(verbatim: model.mergedMessage).font(Typo.callout).foregroundStyle(Tokens.fg2)
                    .multilineTextAlignment(.center)
                if let channel = model.slackChannel {
                    Label { Text(verbatim: "Posted in \(channel)") } icon: { Image(systemName: "number") }
                        .font(Typo.footnote).foregroundStyle(Tokens.fg2)
                }
            }
            .padding(.horizontal, 24)
            Spacer()
            VStack(spacing: 12) {
                TintedButton("View on GitHub", symbol: "arrow.up.right", height: 54) {
                    if let url = model.merged?.url { openURL(url) }
                }
                PrimaryButton("Done", action: close)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Tokens.bg)
    }
}
