import PRBarCore
import SwiftUI

/// Settings › Claude › Run On (spec J.4): the default destination, a table with This Mac and each SSH host (folder,
/// last check, fallback) and Add / Test Connection / Remove for the selected host. Every change goes through the same
/// actions as `prbar runners …`.
struct RunOnSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore

    @State private var selected: String?
    @State private var adding = false
    @State private var testing: Set<String> = []
    @State private var error: String?

    private var settings: RunnerSettings { configStore.config.runners }
    private var selectedDestination: RunnerDestination? { selected.flatMap(settings.destination(named:)) }

    var body: some View {
        Section {
            Picker(selection: Binding(
                get: { settings.defaultTarget },
                set: { target in run { try model.runnerDefault(target: target.cliValue) } }
            )) {
                Text("This Mac").tag(RunTarget.local)
                ForEach(settings.destinations) { Text($0.name).tag(RunTarget.runner($0.name)) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default")
                    Text("Each repo can override this in Settings › Repos.").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                RunOnTable(model: model, settings: settings, selected: $selected, testing: testing) { name, on in
                    run { _ = try await model.runnerSet(name: name, dir: nil, fallback: on) }
                }
                // ⌫ removes the selected host, after the same confirmation as Remove.
                .onDeleteCommand { if let destination = selectedDestination { confirmRemove(destination) } }
                HStack(spacing: 8) {
                    Button("Add SSH Host…") { adding = true }
                    Button("Test Connection") { if let selected { test(selected) } }
                        .disabled(selectedDestination == nil || testing.contains(selected ?? ""))
                    Button(role: .destructive) {
                        if let destination = selectedDestination { confirmRemove(destination) }
                    } label: {
                        Text("Remove").foregroundStyle(selectedDestination == nil ? Color.secondary : Theme.redText)
                    }
                    .disabled(selectedDestination == nil)
                    Spacer(minLength: 0)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.redText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Run On")
        } footer: {
            Text("Reviews, fixes and PR chats run on the host: its own git access to the repo, its own Claude login and plugins. GitHub, posting, pushing, merging and Slack always stay on this Mac — no token leaves it. Fixes come back as a git bundle, are checked against the diff you saw and are pushed from here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $adding) {
            AddRunnerSheet(model: model, existing: settings.destinations.map(\.name)) { added in
                adding = false
                if let added { selected = added }
            }
        }
        .onAppear { if selectedDestination == nil { selected = settings.destinations.first?.name } }
        .onChange(of: settings.destinations.map(\.name)) { _, names in
            if !names.contains(where: { $0.caseInsensitiveCompare(selected ?? "") == .orderedSame }) { selected = names.first }
        }
        .task(id: model.tools) { await model.refreshLocalToolVersions() }
    }

    private func test(_ name: String) {
        testing.insert(name)
        run {
            defer { testing.remove(name) }
            _ = try await model.runnerTest(name: name)
        }
    }

    private func confirmRemove(_ destination: RunnerDestination) {
        ConfirmAlert.present(
            title: "Remove \(destination.name)?",
            message: "Repos that run on it go back to Default. PRBar’s folder on the host (\(destination.remoteDir)) isn’t deleted.",
            action: "Remove"
        ) {
            run { try await model.runnerRemove(name: destination.name) }
        }
    }

    /// Runs an action and shows its error under the buttons.
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task { @MainActor in
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

/// A row of the Run On table: This Mac or an SSH host. Its id is the selection (`""` for This Mac, which can't be
/// tested or removed; a host's name can't be empty).
private enum RunOnRow: Identifiable {
    case local
    case host(RunnerDestination)

    var id: String {
        switch self {
        case .local: ""
        case .host(let destination): destination.name
        }
    }
}

/// The destinations table: This Mac and each host, with its folder, its last check and whether it falls back. A real
/// `Table`: ↑/↓ and VoiceOver select a host, ⌫ removes it (with confirmation), and the columns have headers.
private struct RunOnTable: View {
    @ObservedObject var model: AppModel
    let settings: RunnerSettings
    @Binding var selected: String?
    let testing: Set<String>
    let setFallback: (String, Bool) -> Void

    private var rows: [RunOnRow] { [.local] + settings.destinations.map(RunOnRow.host) }

    var body: some View {
        // Status ages ("5 min ago") move on their own.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Table(rows, selection: $selected) {
                TableColumn("Destination") { row in destinationCell(row) }
                    .width(min: 110, ideal: 140)
                TableColumn("Folder") { row in folderCell(row) }
                    .width(min: 70, ideal: 100)
                TableColumn("Status") { row in statusCell(row, now: context.date) }
                    .width(min: 120, ideal: 220)
                TableColumn("Fallback") { row in fallbackCell(row) }
                    .width(56)
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: false))
            .scrollDisabled(true)
            .frame(height: Self.height(hosts: settings.destinations.count))
        }
        .font(.callout)
        .accessibilityLabel("Run On destinations")
    }

    /// Tall enough for every row (the table doesn't scroll inside the settings page).
    /// The header, This Mac's single line and two lines per host.
    private static func height(hosts: Int) -> CGFloat { 28 + 28 + CGFloat(hosts) * 40 }

    private var localStatus: String {
        let versions = model.localToolVersions
        return LocalTools.statusSummary(git: model.tools.git, claude: model.tools.claude,
                                        gitVersion: versions?.git, claudeVersion: versions?.claude)
    }

    @ViewBuilder
    private func destinationCell(_ row: RunOnRow) -> some View {
        switch row {
        case .local:
            Text("This Mac").fontWeight(.medium)
        case .host(let destination):
            VStack(alignment: .leading, spacing: 1) {
                (Text(destination.name).fontWeight(.medium) + Text(" (ssh)").foregroundColor(.secondary))
                    .lineLimit(1)
                if destination.endpoint.display != destination.name {
                    Text(destination.endpoint.display).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .help(destination.endpoint.display)
        }
    }

    @ViewBuilder
    private func folderCell(_ row: RunOnRow) -> some View {
        switch row {
        case .local:
            Text("—").foregroundStyle(.secondary).accessibilityLabel("None")
        case .host(let destination):
            Text(destination.remoteDir)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(destination.remoteDir)
        }
    }

    @ViewBuilder
    private func statusCell(_ row: RunOnRow, now: Date) -> some View {
        switch row {
        case .local:
            statusText(localStatus)
        case .host(let destination):
            if testing.contains(destination.name) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
            } else if let check = model.runnerChecks[destination.name] {
                statusText(check.statusSummary(now: now))
            } else {
                Text("not checked").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func fallbackCell(_ row: RunOnRow) -> some View {
        switch row {
        case .local:
            Text("—").foregroundStyle(.secondary).accessibilityLabel("Not applicable")
        case .host(let destination):
            Toggle("Fall back to this Mac", isOn: Binding(
                get: { destination.fallbackToLocal },
                set: { on in setFallback(destination.name, on) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help("If \(destination.name) is down or not ready, run on this Mac")
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(text.hasPrefix("✓") ? Theme.greenText : text.hasPrefix("⚠") ? Theme.orangeText : .secondary)
            .lineLimit(2)
            .help(text)
    }
}

/// "Add SSH Host…": a Host from ~/.ssh/config or user@host[:port], its name, the folder on the host and the fallback.
/// Adding also runs Test Connection (`prbar runners add` does the same); the host stays even if the check finds problems.
struct AddRunnerSheet: View {
    @ObservedObject var model: AppModel
    let existing: [String]
    /// The added host's name, or nil if cancelled.
    let close: (String?) -> Void

    @State private var known: [String] = []
    @State private var host = ""
    @State private var name = ""
    @State private var dir = RunnerDestination.defaultRemoteDir
    @State private var fallback = true
    @State private var error: String?
    @State private var working = false

    private var endpoint: SSHEndpoint? { try? SSHEndpoint.parse(host) }
    private var hostProblem: String? {
        do { _ = try SSHEndpoint.parse(host); return nil } catch { return error.localizedDescription }
    }
    /// The name typed, or the host's.
    private var effectiveName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? (endpoint?.host ?? "") : name.trimmingCharacters(in: .whitespaces) }
    private var nameProblem: String? {
        guard endpoint != nil else { return nil }
        if !RunnerDestination.isValidName(effectiveName) { return "Choose a name: letters, numbers, . _ and - (not “local” or “default”)." }
        if existing.contains(where: { $0.caseInsensitiveCompare(effectiveName) == .orderedSame }) { return "There’s already a host named \(effectiveName)." }
        return nil
    }
    private var canAdd: Bool {
        !working && endpoint != nil && nameProblem == nil && RunnerDestination.isValidRemoteDir(dir)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add SSH Host").font(.headline)
            Form {
                if !known.isEmpty {
                    Picker("From ~/.ssh/config", selection: Binding(
                        get: { known.contains(host) ? host : "" },
                        set: { if !$0.isEmpty { host = $0 } }
                    )) {
                        Text("Choose…").tag("")
                        ForEach(known, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Host", text: $host, prompt: Text("devbox or user@host:port"))
                TextField("Name", text: $name, prompt: Text(endpoint?.host ?? "Shown in Settings and in “on …”"))
                TextField("Folder on the host", text: $dir, prompt: Text(RunnerDestination.defaultRemoteDir))
                Toggle("Fall back to this Mac if it’s unreachable", isOn: $fallback)
                    .toggleStyle(.checkbox)
            }
            .formStyle(.columns)
            Group {
                if !host.isEmpty, let hostProblem {
                    Text(hostProblem)
                } else if let nameProblem {
                    Text(nameProblem)
                } else if !RunnerDestination.isValidRemoteDir(dir) {
                    Text(RunnerConfigError.invalidRemoteDir(dir).localizedDescription)
                } else if let error {
                    Text(error)
                } else {
                    Text("PRBar connects with your ssh setup (keys, ~/.ssh/config) and then checks git, Claude and its login on the host.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.redText)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Adding and checking the host…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { close(nil) }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { known = SSHConfigHosts.hosts() }
    }

    private func add() {
        working = true
        error = nil
        let typedName = name.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            do {
                let info = try await model.runnerAdd(host: host.trimmingCharacters(in: .whitespaces),
                                                     name: typedName.isEmpty ? nil : typedName, dir: dir, fallback: fallback)
                close(info.name)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
