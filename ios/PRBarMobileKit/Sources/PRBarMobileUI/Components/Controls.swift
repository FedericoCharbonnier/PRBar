import SwiftUI
import PRBarMobileCore

/// The system switch on iPhone. On macOS (snapshot renders only) a drawn switch in the design's colors, because
/// AppKit-backed controls don't render into an image.
public struct DesignToggle: View {
    let label: String
    @Binding var isOn: Bool
    var disabled = false
    @Environment(\.colorScheme) private var scheme

    public init(_ label: String, isOn: Binding<Bool>, disabled: Bool = false) {
        self.label = label
        self._isOn = isOn
        self.disabled = disabled
    }

    public var body: some View {
        #if os(iOS)
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .tint(Tokens.accent.color(scheme))
            .disabled(disabled)
        #else
        Capsule()
            .fill(isOn ? AnyShapeStyle(Tokens.accent) : AnyShapeStyle(Tokens.fill2))
            .frame(width: 51, height: 31)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            .opacity(disabled ? 0.5 : 1)
            .onTapGesture { if !disabled { isOn.toggle() } }
            .accessibilityLabel(label)
        #endif
    }
}

/// A segmented control (merge method). System `Picker(.segmented)` on iPhone; drawn on macOS for snapshots.
public struct DesignSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    public init(_ options: [(Value, String)], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        #if os(iOS)
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { value, title in Text(title).tag(value) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        #else
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Text(title)
                    .font(Typo.footnoteBold)
                    .foregroundStyle(Tokens.fg)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(value == selection ? AnyShapeStyle(Tokens.bg2) : AnyShapeStyle(Color.clear),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: .black.opacity(value == selection ? 0.08 : 0), radius: 2, y: 1)
                    .onTapGesture { selection = value }
            }
        }
        .padding(2)
        .background(Tokens.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        #endif
    }
}

/// A small indeterminate spinner (Reviewing…, stage rows). Drawn on macOS for snapshots.
public struct Spinner: View {
    var tint: Token = Tokens.violet
    var size: CGFloat = 14
    @Environment(\.colorScheme) private var scheme

    public init(tint: Token = Tokens.violet, size: CGFloat = 14) {
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        #if os(iOS)
        ProgressView().controlSize(.small).tint(tint.color(scheme)).frame(width: size, height: size)
        #else
        Circle().trim(from: 0, to: 0.7)
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size - 2, height: size - 2)
            .rotationEffect(.degrees(-90))
        #endif
    }
}

/// A horizontal scroll view (file chips, diff lines). Scroll views don't draw into an image, so in snapshots the
/// content is laid out unscrolled and clipped.
public struct HorizontalScroll<Content: View>: View {
    let content: Content
    @Environment(\.isSnapshot) private var isSnapshot

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if isSnapshot {
            content.fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
        } else {
            ScrollView(.horizontal, showsIndicators: false) { content }
        }
    }
}

/// A vertical scroll view that lays its content out unscrolled in snapshots.
public struct VerticalScroll<Content: View>: View {
    let content: Content
    @Environment(\.isSnapshot) private var isSnapshot

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if isSnapshot {
            content.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { content }
        }
    }
}
