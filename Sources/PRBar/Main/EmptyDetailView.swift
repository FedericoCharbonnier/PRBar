import AppKit
import SwiftUI

/// El detalle sin PR elegido (spec M.1 "Lista").
struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 0) {
            MessageView(icon: Self.icon, title: "No PR Selected",
                        text: "Pick a PR from the list, or press ↓ to select the first one.")
            Text("⌘1 To Review · ⌘2 My PRs · ⌘F Search")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A page (`text.page` from macOS 15; `doc.text` before).
    private static let icon = NSImage(systemSymbolName: "text.page", accessibilityDescription: nil) != nil ? "text.page" : "doc.text"
}
