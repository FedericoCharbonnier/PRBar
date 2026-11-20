import AppKit
import PRBarCore
import SwiftUI

struct ReposTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var slack: SlackAnnouncer
    @ObservedObject var catalog: GitHubCatalog

    @State private var login = ""
    @State private var selectedRepoID: String?
    /// Repo que se pidió quitar, a la espera de confirmación.
    @State private var repoToRemove: String?
    @State private var pathMessage: String?
    @State private var pathValid = false
    @State private var slackChannels: [SlackChannel] = []
    @State private var slackError: String?
    @State private var slackChannelsTruncated = false
    @State private var loadingSlackChannels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if configStore.enabledLogins.count > 1 {
                AccountPicker(logins: configStore.enabledLogins, selection: $login)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }
            if let account = configStore.account(login) {
                HStack(alignment: .top, spacing: 0) {
                    repoList(account)
                        .frame(width: 200)
                        .padding(.leading, 20)
                        .padding(.vertical, 20)
                    detail(account).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                Text("Turn on an account in the Accounts tab.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if login.isEmpty { login = configStore.enabledLogins.first ?? "" }
            selectFirstRepo()
        }
        .onChange(of: login) { _, _ in selectFirstRepo() }
        .task(id: login) { await catalog.loadRepos(for: login) }
    }

    /// Si no hay un repo válido elegido, elige el primero (así el detalle nunca queda vacío sin motivo).
    private func selectFirstRepo() {
        let repos = configStore.account(login)?.repos ?? []
        if !repos.contains(where: { $0.id == selectedRepoID }) { selectedRepoID = repos.first?.id }
    }

    // MARK: Lista de repos

    private func repoList(_ account: AccountConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selectedRepoID) {
                ForEach(account.repos) { repo in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.id).lineLimit(1).truncationMode(.middle)
                        Text(meta(repo)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(repo.id)
                    .help(repo.id)
                    .contextMenu {
                        Button("Remove Repo…") { repoToRemove = repo.id }
                    }
                }
            }
            .listStyle(.bordered)
            .onDeleteCommand { repoToRemove = selectedRepoID }
            .overlay {
                if account.repos.isEmpty {
                    Text("No repos yet.\nAdd one below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            HStack(spacing: 6) {
                addRepoPicker(account)
                Spacer(minLength: 0)
                Button("Remove…") { repoToRemove = selectedRepoID }
                    .disabled(selectedRepoID == nil)
                    .help("Remove the selected repo (⌫)")
            }
        }
        .confirmationDialog(
            "Remove \(repoToRemove ?? "the repo")?",
            isPresented: Binding(get: { repoToRemove != nil }, set: { if !$0 { repoToRemove = nil } }),
            presenting: repoToRemove
        ) { repoID in
            Button("Remove", role: .destructive) { remove(repoID) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its PRs will stop showing up, and its branches, people, local folder, and Slack channel will be lost.")
        }
    }

    private func addRepoPicker(_ account: AccountConfig) -> some View {
        let entry = catalog.repos(for: login)
        let configured = Set(account.repos.map(\.id))
        return SearchablePickerPopover(
            mode: .single,
            items: Self.groupedByOwner(entry.value, me: login),
            loadState: entry.state,
            placeholder: "Search repos…",
            width: 440,
            maxListHeight: 480,
            title: \.name,
            section: \.owner,
            isSelected: { configured.contains($0.fullName) },
            isDisabled: { configured.contains($0.fullName) },
            onRetry: { Task { await catalog.loadRepos(for: login, force: true) } },
            onReload: { Task { await catalog.loadRepos(for: login, force: true) } },
            onPick: { repo in
                model.updateConfig { $0.addRepo(repo, to: login) }
                selectedRepoID = repo.fullName
            }
        ) {
            Label("Add Repo…", systemImage: "plus")
        }
        .help("Choose one of your GitHub repos")
    }

    /// Repos agrupados por dueño: primero los de la cuenta, después las orgs en orden alfabético.
    private static func groupedByOwner(_ repos: [RepoRef], me: String) -> [RepoRef] {
        repos.sorted { a, b in
            let aMine = a.owner.caseInsensitiveCompare(me) == .orderedSame
            let bMine = b.owner.caseInsensitiveCompare(me) == .orderedSame
            if aMine != bMine { return aMine }
            let owners = a.owner.localizedCaseInsensitiveCompare(b.owner)
            if owners != .orderedSame { return owners == .orderedAscending }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func remove(_ repoID: String) {
        model.updateConfig { $0.removeRepo(repoID, from: login) }
        if selectedRepoID == repoID { selectedRepoID = nil }
        selectFirstRepo()
    }

    private func meta(_ repo: RepoConfig) -> String {
        var parts = [repo.baseBranches.isEmpty ? "default branch" : repo.baseBranches.joined(separator: ", ")]
        let users = repo.watchedUsers.count
        parts.append(users == 1 ? "1 person" : "\(users) people")
        if repo.localPath == nil { parts.append("no local folder") }
        return parts.joined(separator: " · ")
    }

    // MARK: Detalle del repo

    @ViewBuilder
    private func detail(_ account: AccountConfig) -> some View {
        if let repo = account.repos.first(where: { $0.id == selectedRepoID }) {
            Form {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                        Text(repo.id).font(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        IconButton(systemImage: "arrow.up.right.square", help: "Open on GitHub") {
                            if let url = URL(string: "https://github.com/\(repo.id)") { NSWorkspace.shared.open(url) }
                        }
                    }
                }

                Section {
                    BaseBranchesPicker(model: model, catalog: catalog, login: login, repo: repo)
                } header: {
                    Text("Base branches")
                } footer: {
                    Text("Only PRs targeting these branches are shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                WatchedUsersSection(model: model, catalog: catalog, prStore: model.prStore, login: login, repo: repo)

                Section("Local folder") {
                    PathRow(
                        path: repo.localPath ?? "None: reviews use only the diff",
                        isPlaceholder: repo.localPath == nil,
                        reset: repo.localPath == nil ? nil : .init(title: "Remove") {
                            model.updateConfig(refresh: false) { $0.setLocalPath(nil, repoID: repo.id, login: login) }
                            pathMessage = nil
                        },
                        choose: { chooseFolder(for: repo) }
                    ) {
                        Text("Folder")
                    } status: {
                        if let pathMessage {
                            Label(pathMessage, systemImage: pathValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(pathValid ? Theme.greenText : Theme.redText)
                        }
                    }
                }

                Section {
                    PatternListField(title: "Ignore paths", saved: repo.ignorePaths) { patterns in
                        model.updateConfig(refresh: false) { $0.setIgnorePaths(patterns, repoID: repo.id, login: login) }
                    }
                    .id("\(login)|\(repo.id)|ignore")
                } header: {
                    Text("Review")
                } footer: {
                    Text("Findings in files matching these patterns are hidden from this repo’s reviews, on top of the ones in Settings › Claude.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                runOnSection(repo)

                respondSection(repo)

                slackSection(repo)

                mergeSection(repo)
            }
            .formStyle(.grouped)
            .task(id: "\(login)|\(repo.id)") {
                pathMessage = nil
                await catalog.loadBranches(for: login, repo: repo.repo)
            }
        } else {
            Text(account.repos.isEmpty ? "Add a repo to get started." : "Select a repo from the list.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// "Run Claude on" (spec J.4): un host, Default (con lo que resuelve hoy) o This Mac, y el aviso si el último
    /// trabajo del repo cayó a esta Mac. Pasa por `repoSet` como `prbar repo set --run-on`.
    private func runOnSection(_ repo: RepoConfig) -> some View {
        let runners = configStore.config.runners
        let resolved: String = switch runners.defaultTarget {
        case .local: "This Mac"
        case .runner(let name): runners.destination(named: name)?.name ?? "This Mac"
        }
        // Un nombre que ya no existe es This Mac (`RunTargetResolver`, J.7.18).
        let current: String = switch repo.runOn {
        case nil: "default"
        case .local?: "local"
        case .runner(let name)?: runners.destination(named: name)?.name ?? "local"
        }
        return Section {
            Picker("Run Claude on", selection: Binding(
                get: { current },
                set: { value in
                    let change: ValueChange = value == "default" ? .clear : .set(value: value)
                    Task {
                        do {
                            _ = try await model.repoSet(repo: repo.id, account: login, changes: RepoChanges(runOn: change))
                        } catch {
                            AppLog.write("Settings: couldn't set where \(repo.id) runs Claude: \(error.localizedDescription)")
                        }
                    }
                }
            )) {
                Text("Default (\(resolved))").tag("default")
                Text("This Mac").tag("local")
                if !runners.destinations.isEmpty {
                    Divider()
                    ForEach(runners.destinations) { Text($0.name).tag($0.name) }
                }
            }
            if let warning = model.placements.repoWarning(repo.repo) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.orangeText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Claude")
        } footer: {
            Text(runners.destinations.isEmpty
                 ? "Add an SSH host in Settings › Claude › Run On to run this repo’s reviews, fixes and chats there."
                 : "Where this repo’s reviews, fixes and PR chats run. A host uses its own git access to the repo and its own Claude login.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Dónde van los worktrees de "Responder" y qué comando de tests corre PRBar (a pedido, después del diff).
    private func respondSection(_ repo: RepoConfig) -> some View {
        Section {
            PathRow(
                path: worktreeDirText(repo),
                isPlaceholder: repo.worktreeDir == nil,
                reset: repo.worktreeDir == nil ? nil : .init(title: "Use Default") {
                    model.updateConfig(refresh: false) { $0.setWorktreeDir(nil, repoID: repo.id, login: login) }
                },
                choose: { chooseWorktreeDir(for: repo) }
            ) {
                Text("Worktrees")
            }
            TestCommandField(model: model, login: login, repoID: repo.id, saved: repo.testCommand)
                .id("\(login)|\(repo.id)")
        } header: {
            Text("Respond to feedback")
        } footer: {
            Text("PRBar runs this command in the worktree when you click “Run Tests” after reviewing the diff. Leave it empty to hide the button.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// La carpeta elegida o, en gris, la de por defecto (`<carpeta local>-worktrees`).
    private func worktreeDirText(_ repo: RepoConfig) -> String {
        if let dir = repo.worktreeDir { return dir }
        guard let local = repo.localPath, !local.isEmpty else { return "Default: next to the local folder" }
        return WorktreeResolver.defaultWorktreeDir(localPath: local)
    }

    @MainActor
    private func chooseWorktreeDir(for repo: RepoConfig) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to create worktrees for responding to feedback on \(repo.id)."
        panel.prompt = "Use This Folder"
        if let current = repo.worktreeDir ?? repo.localPath.map(WorktreeResolver.defaultWorktreeDir(localPath:)) {
            // Si la carpeta por defecto todavía no existe, el panel arranca en su carpeta padre.
            let url = URL(fileURLWithPath: current, isDirectory: true)
            panel.directoryURL = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        }
        OpenPanel.present(panel) { url in
            model.updateConfig(refresh: false) { $0.setWorktreeDir(url.path, repoID: repo.id, login: login) }
        }
    }

    private func slackSection(_ repo: RepoConfig) -> some View {
        Section("Slack channel") {
            if !configStore.config.slack.enabled || !slack.isConnected {
                Text("Turn on Slack and connect it in the Slack tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Picker("Channel", selection: Binding(
                        get: { repo.slackChannelID ?? "" },
                        set: { id in
                            let channel = slackChannels.first { $0.id == id }
                            model.updateSlackConfig {
                                $0.setSlackChannel(id: channel?.id, name: channel?.name, repoID: repo.id, login: login)
                            }
                        }
                    )) {
                        Text("No announcements").tag("")
                        if let id = repo.slackChannelID, !slackChannels.contains(where: { $0.id == id }) {
                            Label(repo.slackChannelName ?? id, systemImage: "number").tag(id)
                        }
                        ForEach(slackChannels) { channel in
                            Label(
                                channel.name + (channel.isMember ? "" : " · you’re not a member"),
                                systemImage: channel.isPrivate ? "lock.fill" : "number"
                            )
                            .tag(channel.id)
                        }
                    }
                    .labelsHidden()
                    if loadingSlackChannels {
                        ProgressView().controlSize(.small).frame(width: 22, height: 22)
                    } else {
                        IconButton(systemImage: "arrow.clockwise", help: "Reload Channels") {
                            Task { await loadSlackChannels(reload: true) }
                        }
                    }
                }
                if slackChannelsTruncated {
                    Text("Showing the first \(slack.provider == .claudeConnector ? ClaudeConnectorSlackAPI.channelLimit : SlackClient.channelLimit) channels")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let slackError {
                    Text(slackError).font(.caption).foregroundStyle(Theme.redText)
                }
            }
        }
        .task(id: "\(slack.tokenRevision)-\(slack.isConnected)-\(configStore.config.slack.enabled)") { await loadSlackChannels() }
    }

    /// Método de merge del repo (spec F.5): solo los que el repo permite según el último refresco de esta cuenta.
    private func mergeSection(_ repo: RepoConfig) -> some View {
        let settings = model.prStore.snapshot?.repoMergeSettings[Snapshot.scope(account: login, repo: repo.repo)]
        let allowed = MergePolicy.allowedMethods(settings)
        return Section {
            Picker("Merge method", selection: Binding(
                get: { repo.mergeMethod },
                set: { model.setMergeMethod($0, repoID: repo.id, login: login) }
            )) {
                Text(settings?.viewerDefault.map { "Repository default (\($0.title))" } ?? "Repository default")
                    .tag(MergeMethod?.none)
                ForEach(allowed) { method in
                    Text(method.title).tag(MergeMethod?.some(method))
                }
                if let current = repo.mergeMethod, !allowed.contains(current) {
                    Text("\(current.title) (not allowed)").tag(MergeMethod?.some(current))
                }
            }
        } header: {
            Text("Ready to Merge")
        } footer: {
            Text(settings == nil
                 ? "PRBar learns which methods this repo allows on the next refresh."
                 : "The Merge button uses this method; the menu next to it offers the others the repo allows.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loadSlackChannels(reload: Bool = false) async {
        guard configStore.config.slack.enabled, slack.isConnected else { return }
        loadingSlackChannels = true
        defer { loadingSlackChannels = false }
        do {
            let list = try await slack.channels(reload: reload)
            slackChannels = list.channels
            slackChannelsTruncated = list.truncated
            slackError = nil
        } catch {
            slackChannels = []
            slackChannelsTruncated = false
            slackError = "Couldn’t load channels: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func chooseFolder(for repo: RepoConfig) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        OpenPanel.present(panel) { url in
            Task {
                if let error = await model.validateRepoPath(url.path, repo: repo.repo) {
                    pathMessage = error
                    pathValid = false
                } else {
                    model.updateConfig(refresh: false) { $0.setLocalPath(url.path, repoID: repo.id, login: login) }
                    pathMessage = "Remote verified"
                    pathValid = true
                }
            }
        }
    }
}

/// Comando de tests del repo: se guarda al confirmar con Return o al salir del campo (vacío = sin tests).
private struct TestCommandField: View {
    let model: AppModel
    let login: String
    let repoID: String
    let saved: String?

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent("Test command") {
            TextField("Test command", text: $text, prompt: Text("e.g. bundle exec rspec"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit(commit)
                .help("Optional. Runs in the worktree only when you ask, after reviewing the diff.")
        }
        .onAppear { text = saved ?? "" }
        .onDisappear(perform: commit)
        .onChange(of: saved) { _, value in if !focused { text = value ?? "" } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    @MainActor
    private func commit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != (saved ?? "") else { return }
        model.updateConfig(refresh: false) { $0.setTestCommand(value, repoID: repoID, login: login) }
    }
}

/// Selector múltiple de ramas base: muestra las elegidas como chips, o la rama por defecto si no hay ninguna.
struct BaseBranchesPicker: View {
    struct BranchOption: Identifiable {
        let name: String
        var id: String { name }
    }

    let model: AppModel
    @ObservedObject var catalog: GitHubCatalog
    let login: String
    let repo: RepoConfig

    var body: some View {
        let entry = catalog.branches(for: login, repo: repo.repo)
        SearchablePickerPopover(
            mode: .multiple,
            items: options(entry.value),
            loadState: entry.state,
            triggerStyle: .accessory(title: "Choose…"),
            placeholder: "Search branches…",
            title: \.name,
            subtitle: { $0.name == entry.value.defaultBranch ? "Default branch" : nil },
            isSelected: { repo.baseBranches.contains($0.name) },
            onRetry: { Task { await catalog.loadBranches(for: login, repo: repo.repo, force: true) } },
            onPick: { toggle($0.name) }
        ) {
            if repo.baseBranches.isEmpty {
                Text(entry.value.defaultBranch.map { "Default branch (\($0))" } ?? "Default branch")
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout {
                    ForEach(repo.baseBranches, id: \.self) { branch in
                        RemovableChip(title: branch, systemImage: "arrow.triangle.branch", removeHelp: "Remove \(branch)") {
                            toggle(branch)
                        }
                    }
                }
            }
        }
        .help("Choose base branches")
    }

    /// La rama por defecto primero, después las ya elegidas que no vinieron de GitHub y el resto en orden.
    private func options(_ branches: GitHubCatalog.Branches) -> [BranchOption] {
        let main = branches.defaultBranch.flatMap { branches.names.contains($0) ? $0 : nil }
        let rest = branches.names.filter { $0 != main }
        let missing = repo.baseBranches.filter { !branches.names.contains($0) }
        return ((main.map { [$0] } ?? []) + missing + rest).map(BranchOption.init)
    }

    private func toggle(_ branch: String) {
        model.updateConfig { $0.toggleBaseBranch(branch, repoID: repo.id, login: login) }
    }
}
