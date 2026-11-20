import SwiftUI
import PRBarMobileCore

/// Every token and base component on one page, to compare with the design's StyleGuide/ComponentGuide.
public struct StyleGuideView: View {
    public init() {}

    static let swatches: [(String, Token)] = [
        ("bg", Tokens.bg), ("bg2", Tokens.bg2), ("bg3", Tokens.bg3), ("fg", Tokens.fg), ("fg2", Tokens.fg2),
        ("fg3", Tokens.fg3), ("sep", Tokens.sep), ("fill", Tokens.fill), ("fill2", Tokens.fill2), ("accent", Tokens.accent),
        ("accentfg", Tokens.accentfg), ("accentbg", Tokens.accentbg), ("green", Tokens.green), ("greenbg", Tokens.greenbg),
        ("orange", Tokens.orange), ("orangebg", Tokens.orangebg), ("red", Tokens.red), ("redbg", Tokens.redbg),
        ("violet", Tokens.violet), ("violetbg", Tokens.violetbg), ("blue", Tokens.blue), ("bluebg", Tokens.bluebg),
        ("codebg", Tokens.codebg), ("addbg", Tokens.addbg), ("delbg", Tokens.delbg),
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Style guide").font(Typo.largeTitle)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(Self.swatches, id: \.0) { name, token in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 10).fill(token).frame(height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.sep, lineWidth: 0.5))
                        Text(name).font(Typo.caption).foregroundStyle(Tokens.fg2)
                    }
                }
            }
            MacPill(name: Sample.macName, status: "Connected · updated just now", online: true, accessibility: "")
            HStack {
                ForEach([HomeModel.Action.review, .reviewing, .comments(4)], id: \.title) {
                    ActionCapsule(action: $0, disabled: false) {}
                }
            }
            HStack {
                ForEach([HomeModel.Action.respond, .merge, .fixCI], id: \.title) {
                    ActionCapsule(action: $0, disabled: false) {}
                }
                ActionCapsule(action: .review, disabled: true) {}
            }
            HStack(spacing: 8) {
                SeverityPill(label: "High", level: 0)
                SeverityPill(label: "Medium", level: 1)
                SeverityPill(label: "Low", level: 2)
                Avatar(name: "Laura Méndez", login: "lmendez")
                StateCircle(icon: .feedback)
                StateCircle(icon: .ready)
                StateCircle(icon: .ciFailing)
            }
            BranchChips(head: "fix/session-expiry", base: "main", trailing: "· 5 files")
            PrimaryButton("Post", symbol: "faceid") {}
            HStack {
                TintedButton("View on GitHub", symbol: "arrow.up.right") {}
                GlassCapsuleButton("Undo", symbol: "arrow.uturn.backward") {}
            }
        }
        .padding(Metrics.gutter)
    }
}

#Preview("Style guide · light") { ScrollView { StyleGuideView() }.background(Tokens.bg) }
#Preview("Style guide · dark") { ScrollView { StyleGuideView() }.background(Tokens.bg).preferredColorScheme(.dark) }
