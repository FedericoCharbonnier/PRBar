import PRBarCore
import SwiftUI

/// Las pestañas del PR en la toolbar (spec M.1): un segmentado en cápsula de vidrio (material antes de macOS 26), la
/// elegida con fondo de acento, un spinner violeta mientras Claude trabaja y un punto verde si hay algo listo.
struct PRTabBar: View {
    let tabs: [PRTabItem]
    let selected: PRTab
    let indicator: (PRTab) -> TabIndicator?
    let choose: (PRTab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.tab) { item in
                tabButton(item)
            }
        }
        .padding(3)
        .modifier(GlassCapsule())
    }

    private func tabButton(_ item: PRTabItem) -> some View {
        let isSelected = item.tab == selected
        let indicator = indicator(item.tab)
        return Button { choose(item.tab) } label: {
            HStack(spacing: 5) {
                Text(item.tab.title).fixedSize()
                switch indicator {
                case .running?:
                    ProgressView().controlSize(.mini).tint(isSelected ? .white : Theme.violet)
                case .ready?:
                    Circle().fill(isSelected ? Color.white : Theme.green).frame(width: 6, height: 6)
                case nil:
                    EmptyView()
                }
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white
                             : Color(nsColor: item.isEnabled ? .labelColor : .tertiaryLabelColor))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Capsule().fill(isSelected ? Theme.accent : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .accessibilityLabel(accessibilityLabel(item.tab, indicator))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(item.isEnabled ? item.tab.title : PRTabs.disabledReason(item.tab))
    }

    private func accessibilityLabel(_ tab: PRTab, _ indicator: TabIndicator?) -> String {
        switch indicator {
        case .running?: "\(tab.title), Claude is working"
        case .ready?: "\(tab.title), ready"
        case nil: tab.title
        }
    }
}

/// History's filter in the toolbar (All · Reviews · Responses · Merges): a native segmented control. It filters a
/// list rather than switching between a PR's tabs, so it doesn't borrow the PR tabs' accent capsules.
struct HistoryFilterBar: View {
    @Binding var selection: HistoryFilter

    var body: some View {
        Picker("Show", selection: $selection) {
            ForEach(HistoryFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Which records History shows")
    }
}

/// La cápsula de vidrio del boceto: Liquid Glass en macOS 26, material antes.
struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
