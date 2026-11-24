import Combine
import PRBarCore
import SwiftUI

/// "Terminal" (spec T.4): Claude's session of the PR in the terminal of Settings › General. One session: a button;
/// several: a menu grouped as Review / Fixes / CI fix, where a session whose folder PRBar is working in is disabled
/// (the others still open); none, or every folder busy: disabled, saying why. History uses it as "Open in Terminal"
/// with one record's sessions.
struct SessionTerminalButton: View {
    let model: AppModel
    /// The terminal's name in the help.
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var monitor: SessionBusyMonitor
    let sessions: [ClaudeSessionRef]
    let title: String

    init(model: AppModel, sessions: [ClaudeSessionRef], title: String = "Terminal") {
        self.model = model
        configStore = model.configStore
        monitor = model.sessionBusy
        self.sessions = sessions
        self.title = title
    }

    var body: some View {
        let busyIDs = monitor.busyIDs
        let state = SessionOffer.buttonState(sessions, busyIDs: busyIDs, terminal: configStore.config.terminal.displayName)
        Group {
            if sessions.count > 1 {
                Menu {
                    ForEach(SessionOffer.groups(sessions)) { group in
                        Section(group.title) {
                            ForEach(group.sessions) { session in
                                Button(session.label) { model.openClaudeSessionFromUI(session) }
                                    .disabled(busyIDs.contains(session.id))
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
        .disabled(!state.enabled)
        .help(state.help)
        .watchingSessionBusy(monitor)
    }
}

/// The ids of the offered sessions whose folder PRBar is working in (`AppModel.isSessionBusy`), one for the whole app.
/// `isSessionBusy` asks `WorkspaceRegistry` (a stat per call, and it isn't observable), so it never runs in a view's
/// `body`: here, while some view watches, every 2 s and right after the Respond or review queue or the kept folders
/// change (at most every 250 ms).
@MainActor
final class SessionBusyMonitor: ObservableObject {
    @Published private(set) var busyIDs: Set<String> = []
    private weak var model: AppModel?
    private var watchers = 0
    private var loop: Task<Void, Never>?
    private var changes: AnyCancellable?

    init(model: AppModel) {
        self.model = model
    }

    func watch() {
        watchers += 1
        guard watchers == 1, let model else { return }
        refresh()
        // `objectWillChange` and `@Published` fire before the change: `receive(on:)` checks after it.
        changes = model.respond.objectWillChange
            .merge(with: model.reviews.objectWillChange, model.$retainedWorktrees.map { _ in () })
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        loop?.cancel()
        loop = nil
        changes = nil
    }

    private func refresh() {
        guard let model else { return }
        let sessions = Set(model.retainedWorktrees.map(\.prID)).flatMap { model.offeredSessions(prID: $0) }
        let busy = Set(sessions.filter { model.isSessionBusy($0) }.map(\.id))
        if busy != busyIDs { busyIDs = busy }
    }
}

extension View {
    /// Keeps `monitor` running while this view is on screen.
    func watchingSessionBusy(_ monitor: SessionBusyMonitor) -> some View {
        onAppear { monitor.watch() }.onDisappear { monitor.unwatch() }
    }
}
