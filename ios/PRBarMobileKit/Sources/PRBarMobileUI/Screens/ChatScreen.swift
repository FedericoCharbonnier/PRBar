import SwiftUI
import PRBarMobileCore

/// `chat:review`, `chat:respond`, `chat:merge`.
public struct ChatScreen: View {
    @Bindable var model: ChatModel
    @Environment(\.dismiss) private var dismiss

    public init(model: ChatModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            ChatHeader(model: model, back: { dismiss() })
            ScrollViewReader { proxy in
                ScrollView {
                    ChatMessages(model: model).padding(.bottom, 12)
                }
                .onChange(of: model.bubbles.last?.text) { _, _ in
                    if let id = model.bubbles.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            ChatInput(model: model)
        }
        .background(Tokens.bg2)
        .task { await model.open() }
        .onDisappear { model.close() }
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
    }
}

struct ChatHeader: View {
    let model: ChatModel
    var back: () -> Void = {}

    var body: some View {
        NavHeader {
            GlassCircleButton("chevron.left", label: "Back", action: back)
        } center: {
            VStack(spacing: 1) {
                Label("Claude", systemImage: "sparkles").font(Typo.headline).foregroundStyle(Tokens.fg)
                    .labelStyle(VioletIconLabel())
                Text(verbatim: model.subtitle).font(Typo.footnote).foregroundStyle(Tokens.fg2)
            }
        } trailing: {
            EmptyView()
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

struct VioletIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(Tokens.violet)
            configuration.title
        }
    }
}

struct ChatMessages: View {
    let model: ChatModel

    var body: some View {
        let bubbles = model.visibleBubbles
        VStack(alignment: .leading, spacing: 0) {
            if model.isReadOnly {
                Label(ChatModel.readOnlyNotice, systemImage: "lock.fill")
                    .font(Typo.footnote).foregroundStyle(Tokens.fg2)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.bottom, 12)
            }
            if let first = bubbles.first {
                Text(verbatim: "Today \(Format.time(first.createdAt))").font(Typo.footnote).foregroundStyle(Tokens.fg3)
                    .frame(maxWidth: .infinity).padding(.bottom, 10)
            }
            ForEach(Array(bubbles.enumerated()), id: \.element.id) { index, bubble in
                let speakerChanged = index > 0 && bubbles[index - 1].role != bubble.role
                VStack(alignment: bubble.role == .me ? .trailing : .leading, spacing: 6) {
                    if !bubble.text.isEmpty { BubbleView(bubble: bubble) }
                    if let change = bubble.change {
                        ActionCard(change: change, undoable: bubble.undoable && !bubble.undone && !model.isReadOnly) {
                            Task { await model.undo() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: bubble.role == .me ? .trailing : .leading)
                .padding(.top, index == 0 ? 0 : speakerChanged ? 10 : 3)
                .id(bubble.id)
            }
            if model.showsTyping {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { _ in Circle().fill(Tokens.fg3).frame(width: 7, height: 7) }
                    }
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Tokens.bg3, in: Capsule())
                    Text("Claude is typing").font(Typo.footnote).foregroundStyle(Tokens.fg2)
                }
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}

struct BubbleView: View {
    let bubble: ChatModel.Bubble

    var body: some View {
        Text(verbatim: bubble.text)
            .font(Typo.large)
            .foregroundStyle(bubble.role == .me ? AnyShapeStyle(Color.white) : AnyShapeStyle(Tokens.fg))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(bubble.role == .me ? AnyShapeStyle(Tokens.accent) : AnyShapeStyle(Tokens.bg3),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: bubble.role == .me ? 270 : 290, alignment: bubble.role == .me ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Claude made a change" card with Undo.
struct ActionCard: View {
    let change: ChatModel.Change
    let undoable: Bool
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Tokens.violet).frame(width: 34, height: 34)
                .overlay { Image(systemName: "pencil").font(.system(size: 14, weight: .bold)).foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: change.title).font(Typo.bodyBold).foregroundStyle(Tokens.fg)
                if let detail = change.detail { Text(verbatim: detail).font(Typo.footnote).foregroundStyle(Tokens.fg2) }
            }
            Spacer(minLength: 8)
            if undoable {
                TintedButton("Undo", height: 32, fullWidth: false, action: undo)
            }
        }
        .padding(12)
        .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Tokens.sep, lineWidth: 1))
        .frame(maxWidth: 320)
    }
}

struct ChatInput: View {
    @Bindable var model: ChatModel
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 8) {
            if isSnapshot {
                Text(model.placeholder).font(Typo.large).foregroundStyle(Tokens.fg3).padding(.leading, 18)
                Spacer()
            } else {
                TextField(model.placeholder, text: $model.draft, axis: .vertical)
                    .font(Typo.large)
                    .lineLimit(1...5)
                    .padding(.leading, 18)
                    .onSubmit { Task { await model.send() } }
            }
            if model.isStreaming {
                Button { Task { await model.stop() } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(Tokens.red, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            } else {
                Button { Task { await model.send() } } label: {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(model.canSend ? AnyShapeStyle(Color.white) : AnyShapeStyle(Tokens.fg3))
                        .frame(width: 34, height: 34)
                        .background(model.canSend ? AnyShapeStyle(Tokens.accent) : AnyShapeStyle(Tokens.fill), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.trailing, 7)
        .frame(minHeight: 48)
        .glassCapsule()
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 8)
    }
}
