import PRBarCore
import SwiftUI

struct PRBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, prStore: model.prStore, configStore: model.configStore, slack: model.slack,
                        tabs: model.popoverTab)
        } label: {
            MenuBarLabel(prStore: model.prStore)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var prStore: PRStore

    var body: some View {
        Image(nsImage: BadgeIcon.image(for: state))
            .accessibilityLabel("PRBar, \(accessibilityState)")
    }

    private var accessibilityState: String {
        guard let snapshot = prStore.snapshot else { return "loading" }
        if snapshot.failedCompletely { return "offline" }
        return snapshot.badgeCount == 1 ? "1 PR needs your action" : "\(snapshot.badgeCount) PRs need your action"
    }

    private var state: MenuBarIconState {
        guard let snapshot = prStore.snapshot else { return .idle }
        if snapshot.failedCompletely { return .error }
        return .count(snapshot.badgeCount)
    }
}
