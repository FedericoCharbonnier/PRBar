import SwiftUI
import PRBarMobileCore

/// `settings`.
public struct SettingsScreen: View {
    let model: SettingsModel
    var app: PhoneApp?

    public init(model: SettingsModel, app: PhoneApp? = nil) {
        self.model = model
        self.app = app
    }

    public var body: some View {
        ScrollView {
            SettingsContent(model: model).padding(.bottom, 100)
        }
        .background(Tokens.bg)
        .task { await model.load() }
        .alert(model.alert ?? "", isPresented: .constant(model.alert != nil)) {
            Button("OK", role: .cancel) { model.alert = nil }
        }
        .repairAlert(isPresented: model.needsRepair, app: app)
    }
}

struct SettingsContent: View {
    let model: SettingsModel
    @State private var confirmUnpair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(Typo.largeTitle).foregroundStyle(Tokens.fg).accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)
            group {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Tokens.appTile).frame(width: 40, height: 40)
                        .overlay { Image(systemName: "laptopcomputer").font(.system(size: 18, weight: .medium)).foregroundStyle(.white) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: model.macName).font(Typo.headline).foregroundStyle(Tokens.fg)
                        HStack(spacing: 5) {
                            StatusDot(online: model.isOnline)
                            Text(model.connectionText).font(Typo.footnote).foregroundStyle(Tokens.fg2)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).frame(minHeight: 64)
                Hairline(inset: 16)
                Button { confirmUnpair = true } label: {
                    Text("Unpair This Mac").font(Typo.body).foregroundStyle(Tokens.red)
                        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading).padding(.horizontal, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .confirmationDialog("Unpair This Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                    Button("Unpair This Mac", role: .destructive) { Task { await model.unpair() } }
                } message: {
                    Text("This iPhone forgets its keys and cached data. Pair it again from PRBar on your Mac.")
                }
            }
            caption("NOTIFICATIONS")
            group {
                ForEach(Array(model.toggles.enumerated()), id: \.element.id) { index, toggle in
                    if index > 0 { Hairline(inset: 16) }
                    toggleRow(toggle.title, isOn: toggle.isOn) { on in Task { await model.set(toggle.kind, on) } }
                }
            }
            caption("SECURITY")
            group {
                toggleRow("Require Face ID for merge, push, approve and tests", isOn: model.requirePresence) { on in
                    Task { await model.setRequirePresence(on) }
                }
            }
            Text(verbatim: "PRBar \(model.appVersion)").font(Typo.footnote).foregroundStyle(Tokens.fg3)
                .frame(maxWidth: .infinity).padding(.top, 18)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
    }

    func caption(_ text: String) -> some View {
        Text(text).font(Typo.footnote).foregroundStyle(Tokens.fg2).padding(.leading, 16).padding(.top, 18)
    }

    func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    func toggleRow(_ title: String, isOn: Bool, set: @escaping @Sendable (Bool) -> Void) -> some View {
        HStack {
            Text(title).font(Typo.body).foregroundStyle(Tokens.fg)
            Spacer()
            DesignToggle(title, isOn: Binding(get: { isOn }, set: set), disabled: !model.isOnline)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}
