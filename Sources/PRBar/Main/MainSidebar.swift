import PRBarCore
import PRBarRemoteMac
import SwiftUI

/// La barra lateral de la ventana principal (spec M.1 "Barra lateral"): Pull Requests, el grupo Claude (solo con
/// tareas), History · Activity y el pie (iPhone, Settings).
struct MainSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    @ObservedObject var prStore: PRStore
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue

    init(model: AppModel, state: MainWindowState, prStore: PRStore) {
        self.model = model
        self.state = state
        self.prStore = prStore
        reviews = model.reviews
        respond = model.respond
    }

    var body: some View {
        List(selection: selection) {
            Section("Pull Requests") {
                sectionRow(.toReview, icon: "tray")
                sectionRow(.myPRs, icon: "arrow.triangle.pull")
            }
            claudeGroup
            Section {
                row("History", icon: "clock.arrow.circlepath", item: .history)
                row("Activity", icon: "gauge", item: .activity)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MainSidebarFooter(model: model, remote: model.remoteAccess, updates: model.updates)
        }
    }

    /// Elegir en la barra lateral es navegar (empuja a Back).
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { state.nav.place.sidebar },
            set: { item in
                switch item {
                case .section(let section)?: model.navigate(to: .list(section))
                case .history?: model.navigate(to: .history(recordID: nil))
                case .activity?: model.navigate(to: .activity)
                case nil: break
                }
            }
        )
    }

    private func sectionRow(_ section: MainSection, icon: String) -> some View {
        let count = MainList.count(section, in: prStore.snapshot) ?? 0
        return label(section.title, icon: icon, item: .section(section))
            .badge(count)
            .help(count == 1 ? "1 PR needs your action" : "\(count) PRs need your action")
            .tag(SidebarItem.section(section))   // el tag, lo último: si no, la `List` no marca la fila elegida
    }

    /// Una fila de navegación: el ícono en el acento (como el boceto, también con la ventana inactiva) y la elegida en
    /// negrita.
    private func row(_ title: String, icon: String, item: SidebarItem) -> some View {
        label(title, icon: icon, item: item).tag(item)
    }

    private func label(_ title: String, icon: String, item: SidebarItem) -> some View {
        let selected = state.nav.place.sidebar == item
        return Label {
            Text(title).fontWeight(selected ? .semibold : .regular)
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.accent)
        }
    }

    // MARK: Claude

    @ViewBuilder
    private var claudeGroup: some View {
        let rows = model.claudeTaskRows()
        if !rows.isEmpty {
            Section(ClaudeTasksSidebar.groupTitle(rows)) {
                ForEach(rows) { row in
                    // El reloj de las que corren avanza cada segundo (un `TimelineView` por fila: alrededor de una
                    // `Section` rompe la `List`).
                    TimelineView(.periodic(from: .now, by: row.isRunning ? 1 : 3600)) { context in
                        let current = model.claudeTaskRows(now: context.date).first { $0.id == row.id } ?? row
                        ClaudeTaskSidebarRow(row: current) { model.navigate(to: .pr(prID: row.prID, tab: row.tab)) }
                    }
                }
            }
        }
    }
}

/// Una fila del grupo Claude: `repo#N`, la etapa con su reloj, spinner violeta o check verde e iPhone si la pidió uno.
private struct ClaudeTaskSidebarRow: View {
    let row: ClaudeTaskRow
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Group {
                    if row.isRunning {
                        ProgressView().controlSize(.mini).tint(Theme.violet)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).lineLimit(1)
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if row.fromPhone {
                    Image(systemName: "iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Requested from iPhone")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// "api#317, Reviewing, 1 minute 12 seconds, requested from iPhone".
    private var accessibilityLabel: String {
        var parts = [row.title]
        for (index, piece) in row.subtitle.components(separatedBy: " · ").enumerated() {
            parts.append(index > 0 ? Self.spokenClock(piece) ?? piece : piece)
        }
        if row.fromPhone { parts.append("requested from iPhone") }
        return parts.joined(separator: ", ")
    }

    /// "1:12" → "1 minute 12 seconds"; nil si no es un reloj.
    private static func spokenClock(_ text: String) -> String? {
        let numbers = text.split(separator: ":").compactMap { Int($0) }
        guard numbers.count >= 2, numbers.count == text.split(separator: ":").count else { return nil }
        let units = numbers.count == 3 ? ["hour", "minute", "second"] : ["minute", "second"]
        return zip(numbers, units).filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
            .joined(separator: " ").nonEmpty ?? "0 seconds"
    }
}

/// El pie de la barra lateral: el iPhone vinculado (con un punto verde si está en línea) y el engranaje de Settings.
private struct MainSidebarFooter: View {
    let model: AppModel
    @ObservedObject var remote: RemoteAccessService
    @ObservedObject var updates: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            updateNotice
            Divider().padding(.bottom, 4)
            if let device = remote.devices.first {
                let online = remote.online.contains(device.device.deviceId)
                Button { model.openSettings(tab: .iphone) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone").frame(width: 16)
                        Text(device.device.name).lineLimit(1)
                        Spacer(minLength: 0)
                        Circle()
                            .fill(online ? Theme.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .hoverHighlight(cornerRadius: Theme.Radius.button)
                .accessibilityLabel("\(device.device.name), \(online ? "online" : "offline")")
                .help("iPhone settings")
            }
            HStack {
                Spacer()
                IconButton(systemImage: "gearshape", help: "Settings (⌘,)", size: 14) { model.openSettings() }
                    .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 4)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

extension MainSidebarFooter {
    /// "PRBar X available · What's new · Install" (spec M.1 "Pie"); los dos botones abren la hoja de Update, donde está
    /// la política con trabajos en curso (plan 21, decisión 9). Mientras instala, el progreso compacto de `UpdateButton`.
    @ViewBuilder
    var updateNotice: some View {
        if updates.isInstalling {
            UpdateButton(updates: updates) { model.openUpdateWindow() }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        } else if let release = updates.available {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("PRBar \(release.version.description) available").foregroundStyle(Color(nsColor: .labelColor))
                } icon: {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                }
                .font(.callout.weight(.semibold))
                HStack(spacing: 8) {
                    Button("What’s New") { model.openUpdateWindow() }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.accent)
                    Spacer(minLength: 0)
                    Button("Install") { model.openUpdateWindow() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Shows what’s new and installs it")
                }
                .font(.callout)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.tint(Theme.accent)))
            .padding(.bottom, 8)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
