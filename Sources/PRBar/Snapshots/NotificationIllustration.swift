import AppKit
import SwiftUI

/// An approximation of a macOS notification banner, for `notification.png`. It isn't the system's banner (that
/// can't be rendered offscreen): just a close look-alike with PRBar's icon and the real notification text.
struct NotificationIllustration: View {
    let title: String
    let message: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("now").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(message)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(width: 356)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.16, opacity: 0.96) : Color(white: 0.97, opacity: 0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 14, y: 5)
        .padding(28)
    }
}
