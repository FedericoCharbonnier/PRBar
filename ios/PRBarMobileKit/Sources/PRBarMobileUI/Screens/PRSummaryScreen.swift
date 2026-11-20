import SwiftUI
import PRBarMobileCore

/// A PR with nothing to do here (Waiting for Review, Other): read-only, with "Open in GitHub".
struct PRSummaryScreen: View {
    let app: PhoneApp
    let pr: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        let info = app.connection.store.home?.prs.first { $0.id == pr }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                NavHeader { GlassCircleButton("chevron.left", label: "Back") { dismiss() } } trailing: { EmptyView() }
                    .padding(.horizontal, -Metrics.gutter)
                PRHeader(prID: pr, info: info,
                         authorName: info.map { app.connection.store.home?.displayName($0.author) ?? $0.author } ?? "")
                if let url = info?.url {
                    TintedButton("Open in GitHub", symbol: "arrow.up.right", height: 54) { openURL(url) }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 8)
        }
        .background(Tokens.bg)
    }
}
