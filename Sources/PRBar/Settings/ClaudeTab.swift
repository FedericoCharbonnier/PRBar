import PRBarCore
import SwiftUI

/// Settings → Claude: the skills of the review (and its filter) and of "Respond to feedback", and the model.
struct ClaudeTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var skills: ClaudeSkills

    private var settings: ClaudeSettings { configStore.config.claude }

    var body: some View {
        Form {
            Section {
                SkillPicker(title: "Review skill", selection: settings.effectiveReviewSkill, skills: skills) { skill in
                    update { $0.reviewSkill = skill }
                }
                Toggle("Filter findings", isOn: Binding(
                    get: { settings.filterEnabled },
                    set: { on in update { $0.filterEnabled = on } }
                ))
                SkillPicker(title: "Filter skill", selection: settings.effectiveFilterSkill, skills: skills) { skill in
                    update { $0.filterSkill = skill }
                }
                .padding(.leading, 16)
                .disabled(!settings.filterEnabled)
            } header: {
                Text("Review")
            } footer: {
                footer("The review skill reviews the PR’s diff. The filter then checks each finding against the code and drops the ones that don’t hold up; with it off, every finding is kept.")
            }

            Section {
                SkillPicker(title: "Skill", selection: settings.effectiveRespondSkill, skills: skills) { skill in
                    update { $0.respondSkill = skill }
                }
            } header: {
                Text("Respond to feedback")
            } footer: {
                footer("Evaluates each unresolved comment on your PRs and proposes a fix, a reply, or both.")
            }

            Section {
                Picker("Model", selection: Binding(
                    get: { settings.model },
                    set: { value in update { $0.model = value } }
                )) {
                    Text("Default").tag(ClaudeModel?.none)
                    ForEach(ClaudeModel.allCases, id: \.self) { Text($0.title).tag(ClaudeModel?.some($0)) }
                }
            } footer: {
                footer("Default uses Claude Code’s default model.")
            }

            Section {
                Toggle("Chat with Claude in Review and Respond windows", isOn: Binding(
                    get: { settings.chatEnabled },
                    set: { on in update { $0.chatEnabled = on } }
                ))
                Picker("Model", selection: Binding(
                    get: { settings.chatModel },
                    set: { value in update { $0.chatModel = value } }
                )) {
                    Text("Same as review").tag(ClaudeModel?.none)
                    ForEach(ClaudeModel.allCases, id: \.self) { Text($0.title).tag(ClaudeModel?.some($0)) }
                }
                .disabled(!settings.chatEnabled)
            } header: {
                Text("Chat")
            } footer: {
                footer("Ask Claude about a PR, have it adjust the findings, draft replies or change your fixes. It never posts, pushes or approves.")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { update { $0 = ClaudeSettings() } }
                        .disabled(settings == ClaudeSettings())
                }
            } footer: {
                footer("Reviews run Claude Code headless and isolated: only the plugins of the selected skills are loaded, no shell, no MCP, read-only for reviews.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .task(id: model.tools.claude) {
            await skills.refresh(claudePath: model.tools.claude, toolsResolved: model.toolsResolved, settings: settings)
        }
    }

    private func update(_ mutate: @escaping (inout ClaudeSettings) -> Void) {
        model.updateConfig(refresh: false) { mutate(&$0.claude) }
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A skill row: the label with the selected skill's status under it, and a button that opens a searchable list of
/// the available skills (name and description) with a "Custom…" field for any `plugin:skill`.
private struct SkillPicker: View {
    let title: String
    let selection: String
    @ObservedObject var skills: ClaudeSkills
    let onSelect: (String) -> Void

    @State private var showing = false

    var body: some View {
        LabeledContent {
            Button {
                showing = true
            } label: {
                HStack(spacing: 4) {
                    Text(selection)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            .help(selection)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                SkillList(selection: selection, skills: skills) { skill in
                    showing = false
                    onSelect(skill)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                status
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let entry = skills.entry(selection) {
            switch entry.availability {
            case .available:
                Text(entry.description ?? sourceText(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(entry.description ?? "")
            case .checking:
                Text("Checking whether it loads in isolated runs…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.orangeText)
            }
        } else if skills.loaded {
            if let plugin = ClaudeSettings.plugin(of: selection) {
                if skills.entries.contains(where: { pluginName($0) == plugin }) {
                    Label("Not found in the “\(plugin)” plugin", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.orangeText)
                } else {
                    Label("The “\(plugin)” plugin isn’t installed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.redText)
                }
            } else {
                Text("Custom skill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceText(_ entry: ClaudeSkillEntry) -> String {
        pluginName(entry).map { "From the “\($0)” plugin" } ?? "Your skill"
    }
}

private func pluginName(_ entry: ClaudeSkillEntry) -> String? {
    if case .plugin(let name, _) = entry.source { return name }
    return nil
}

/// The popover's content: a search field, the skills grouped by plugins and user skills, and "Custom…".
private struct SkillList: View {
    let selection: String
    @ObservedObject var skills: ClaudeSkills
    let onSelect: (String) -> Void

    @State private var query = ""
    @State private var editingCustom = false
    @State private var custom = ""
    @FocusState private var customFocused: Bool

    private var filtered: [ClaudeSkillEntry] {
        let terms = query.trimmingCharacters(in: .whitespaces)
        guard !terms.isEmpty else { return skills.entries }
        return skills.entries.filter {
            $0.id.localizedCaseInsensitiveContains(terms) || ($0.description?.localizedCaseInsensitiveContains(terms) ?? false)
        }
    }

    private var customSkill: String { custom.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search skills", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            List {
                let plugins = filtered.filter { $0.source != .user }
                let user = filtered.filter { $0.source == .user }
                if !plugins.isEmpty {
                    Section("Plugins") { ForEach(plugins) { row($0) } }
                }
                if !user.isEmpty {
                    Section("Your skills") { ForEach(user) { row($0) } }
                }
                if filtered.isEmpty {
                    Text(skills.loaded ? "No skills match." : "Loading skills…")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            Divider()
            customRow
                .padding(10)
        }
        .frame(width: 440, height: 400)
        .onAppear {
            custom = selection
        }
    }

    private func row(_ entry: ClaudeSkillEntry) -> some View {
        Button {
            onSelect(entry.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(entry.id == selection ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.id)
                        .font(.system(.callout, design: .monospaced))
                    if let detail = detail(entry) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entry.isAvailable)
        .help(entry.description ?? "")
    }

    private func detail(_ entry: ClaudeSkillEntry) -> String? {
        switch entry.availability {
        case .available: entry.description
        case .checking: "Checking whether it loads in isolated runs…"
        case .unavailable(let reason): reason
        }
    }

    @ViewBuilder
    private var customRow: some View {
        if editingCustom {
            HStack {
                TextField("plugin:skill", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($customFocused)
                    .onSubmit(useCustom)
                Button("Use", action: useCustom)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ClaudeSettings.isValidSkill(customSkill))
            }
        } else {
            HStack {
                Button("Custom…") {
                    editingCustom = true
                    customFocused = true
                }
                Spacer()
            }
        }
    }

    private func useCustom() {
        guard ClaudeSettings.isValidSkill(customSkill) else { return }
        onSelect(customSkill)
    }
}
