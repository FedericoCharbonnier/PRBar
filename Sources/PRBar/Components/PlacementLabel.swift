import AppKit
import SwiftUI

/// Where a job ran (spec J): "on devbox" in gray, or the fallback ("Ran on this Mac — devbox unreachable") in orange.
/// Used by the popover rows and the Review and Respond windows.
struct PlacementLabel: View {
    let text: String

    private var isFallback: Bool { !text.hasPrefix("on ") }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isFallback ? "exclamationmark.triangle.fill" : "server.rack").imageScale(.small)
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        // A plain color, not the hierarchical `.secondary`: under a window toolbar (the chat inspector) that one drew black in Dark Mode.
        .foregroundStyle(isFallback ? Theme.orangeText : Color(nsColor: .secondaryLabelColor))
        .help(isFallback ? "\(text). Settings › Repos shows which host each repo uses." : "Claude ran \(text).")
    }
}
