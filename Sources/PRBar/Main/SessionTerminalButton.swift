import PRBarCore
import SwiftUI

/// "Terminal" (spec T.4): Claude's session of the PR in the terminal of Settings › General. One session: a button;
/// several: a menu grouped as Review / Fixes / CI fix; none, or PRBar working in that folder: disabled, saying why.
/// History uses it as "Open in Terminal" with one record's sessions.
struct SessionTerminalButton: View {
    let model: AppModel
    /// The terminal's name in the help.
    @ObservedObject var configStore: ConfigStore
    let sessions: [ClaudeSessionRef]
    let title: String
    /// Kept by `SessionBusyWatcher`, not computed in `body` (see there).
    @State private var busy = false

    init(model: AppModel, sessions: [ClaudeSessionRef], title: String = "Terminal") {
        self.model = model
        configStore = model.configStore
        self.sessions = sessions
        self.title = title
    }

    var body: some View {
        Group {
            if sessions.count > 1 {
                Menu {
                    ForEach(SessionOffer.groups(sessions)) { group in
                        Section(group.title) {
                            ForEach(group.sessions) { session in
                                Button(session.label) { model.openClaudeSessionFromUI(session) }
                            }
                        }
                    }
                } label: {
                    Label(title, systemImage: "terminal")
                }
            } else {
                Button(title, systemImage: "terminal") {
                    if let session = sessions.first { model.openClaudeSessionFromUI(session) }
                }
            }
        }
        .disabled(sessions.isEmpty || busy)
        .help(SessionOffer.help(count: sessions.count, busy: busy, terminal: configStore.config.terminal.displayName))
        .modifier(SessionBusyWatcher(model: model, sessions: sessions, busy: $busy))
    }
}

/// Whether PRBar is working in one of `sessions`' folders, kept in view state. `AppModel.isSessionBusy` asks
/// `WorkspaceRegistry` (a stat per call, and it isn't observable): it runs when the Respond or review queue changes
/// and every 2 s, never on every render.
struct SessionBusyWatcher: ViewModifier {
    let model: AppModel
    let sessions: [ClaudeSessionRef]
    @Binding var busy: Bool

    func body(content: Content) -> some View {
        content
            .task(id: sessions.map(\.id)) {
                while !Task.isCancelled {
                    update()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            // `objectWillChange` comes before the change: checked on the next turn of the main loop.
            .onReceive(model.respond.objectWillChange.merge(with: model.reviews.objectWillChange)) { _ in
                Task { @MainActor in update() }
            }
    }

    private func update() {
        let now = sessions.contains { model.isSessionBusy($0) }
        if now != busy { busy = now }
    }
}
