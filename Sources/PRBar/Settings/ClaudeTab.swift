import PRBarCore
import SwiftUI

/// Settings → Claude: the review and respond stages (skill or own prompt), what the review reports, the fixes' options, the model, the chat and the editable prompts (spec E.5/E.6).
/// A segmented control splits it into pages (it was one very long scroll).
struct ClaudeTab: View {
    enum Page: String, CaseIterable, Identifiable {
        case review, respond, chat, runOn, prompts

        var id: String { rawValue }
        var title: String {
            switch self {
            case .review: "Review"
            case .respond: "Respond"
            case .chat: "Model & Chat"
            case .runOn: "Run On"
            case .prompts: "Prompts"
            }
        }
    }

    /// The page it opens on (snapshot mode renders more than one).
    static var initialPage = Page.review

    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var skills: ClaudeSkills

    @State private var editing: PromptStage?
    @State private var page = ClaudeTab.initialPage

    private var settings: ClaudeSettings { configStore.config.claude }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $page) {
                ForEach(Page.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)
            .padding(.bottom, 2)
            form
        }
        .sheet(item: $editing) { stage in
            PromptEditorSheet(stage: stage, settings: settings,
                              save: { text in update { $0.setCustomPrompt(text, for: stage) } },
                              reset: { update { $0.resetPrompt(for: stage) } })
        }
        .task(id: model.tools.claude) {
            await skills.refresh(claudePath: model.tools.claude, toolsResolved: model.toolsResolved, settings: settings)
        }
    }

    private var form: some View {
        Form {
            switch page {
            case .review: reviewPage
            case .respond: respondPage
            case .chat: chatPage
            case .runOn: RunOnSection(model: model, configStore: configStore)
            case .prompts: promptsPage
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { update { $0 = ClaudeSettings() } }
                        .disabled(settings == ClaudeSettings())
                }
            } footer: {
                footer("Resets every Claude setting on all pages. Reviews run Claude Code headless and isolated: only the plugins of the selected skills are loaded, no shell, no MCP, read-only for reviews.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private var reviewPage: some View {
        Section {
            ClaudeStageRow(title: "Review", stage: .review, settings: settings, skills: skills, update: update) { editing = .review }
            Toggle("Filter findings", isOn: binding(\.review.filter.enabled))
            ClaudeStageRow(title: "Filter", stage: .filter, settings: settings, skills: skills, update: update) { editing = .filter }
                .disabled(!settings.filterEnabled)
        } header: {
            Text("Review")
        } footer: {
            footer("The review skill (or your prompt) reviews the PR’s diff. The filter then checks each finding against the code and drops the ones that don’t hold up; with it off, every finding is kept.")
        }

        Section {
            Picker("Minimum severity", selection: binding(\.review.minSeverity)) {
                Text("Low (everything)").tag(Severity.low)
                Text("Medium").tag(Severity.medium)
                Text("High").tag(Severity.high)
            }
            LabeledContent("Maximum findings") {
                HStack(spacing: 8) {
                    if let limit = settings.review.maxFindings {
                        Stepper("\(limit)", value: Binding(
                            get: { limit },
                            set: { value in update { $0.review.maxFindings = min(max(value, 1), 50) } }
                        ), in: 1...50)
                    }
                    Toggle("Limit", isOn: Binding(
                        get: { settings.review.maxFindings != nil },
                        set: { on in update { $0.review.maxFindings = on ? 10 : nil } }
                    ))
                    .labelsHidden()
                }
            }
            LabeledContent("Report") {
                HStack(spacing: 4) {
                    ForEach(FindingCategory.allCases, id: \.self) { category in
                        CategoryChip(title: category.label, isOn: settings.review.isEnabled(category)) {
                            update { $0.review.setCategory(category, enabled: !$0.review.isEnabled(category)) }
                        }
                    }
                }
            }
            PatternListField(title: "Ignore paths", saved: settings.review.ignorePaths) { patterns in
                update { $0.review.ignorePaths = patterns }
            }
            Picker("Tone", selection: binding(\.review.tone)) {
                ForEach(ReviewTone.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } header: {
            Text("What the review reports")
        } footer: {
            footer("PRBar tells Claude these settings and also applies them to its answer: what they hide goes to “Hidden by your settings”, where you can still include it. Each repo can ignore more paths in Settings › Repos.")
        }
    }

    @ViewBuilder
    private var respondPage: some View {
        Section {
            ClaudeStageRow(title: "Analysis", stage: .analysis, settings: settings, skills: skills, update: update) { editing = .analysis }
            ClaudeStageRow(title: "Implementation", stage: .implementation, settings: settings, skills: skills, allowsNoSkill: true,
                           update: update) { editing = .implementation }
        } header: {
            Text("Respond to feedback")
        } footer: {
            footer("The analysis evaluates each unresolved comment on your PRs and proposes a fix, a reply, or both. The implementation makes each fix you choose.")
        }

        Section {
            Toggle("Run tests before pushing", isOn: binding(\.respond.runTestsBeforePush))
            Picker("Commits", selection: binding(\.respond.commitMode)) {
                ForEach(CommitMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            FixTemplateEditor(title: "Commit message", kind: .commitMessage, commitMode: settings.respond.commitMode,
                              value: settings.respond.commitMessageTemplate ?? "") { text in
                update { $0.respond.commitMessageTemplate = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text }
            }
            Toggle("Allow new tests", isOn: binding(\.respond.allowNewTests))
            Toggle("Allow new dependencies", isOn: binding(\.respond.allowNewDependencies))
            FixTemplateEditor(title: "Reply to fixed comments", kind: .reply, value: settings.respond.replyTemplate ?? "") { text in
                update { $0.respond.replyTemplate = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text }
            }
        } header: {
            Text("Fixes")
        } footer: {
            footer("“Run tests before pushing” uses the repo’s test command and doesn’t push if it fails (you can still push anyway). With new dependencies off, PRBar warns you before pushing if Claude changed a dependency manifest. Empty templates use the defaults; without a reply template, “Fixed in …” follows the PR’s language.")
        }
    }

    @ViewBuilder
    private var chatPage: some View {
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
            Toggle("Chat with Claude in the Review, Respond and Merge tabs", isOn: Binding(
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
    }

    @ViewBuilder
    private var promptsPage: some View {
        Section {
            ForEach(PromptStage.allCases) { stage in
                LabeledContent(stage.title) {
                    HStack(spacing: 8) {
                        if settings.customPrompt(for: stage) != nil {
                            Text("Modified").font(.caption.weight(.semibold)).foregroundStyle(Theme.orangeText)
                        }
                        Button("Edit…") { editing = stage }
                    }
                }
            }
        } header: {
            Text("Prompts")
        } footer: {
            footer("PRBar always adds its fixed part around your prompt: the PR’s content is never an instruction, Claude has no shell and never posts, your rules (Settings › Instructions) and the output format.")
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ClaudeSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
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
    var allowsNone = false
    let onSelect: (String) -> Void

    @State private var showing = false

    var body: some View {
        LabeledContent {
            Button {
                showing = true
            } label: {
                HStack(spacing: 4) {
                    Text(selection.isEmpty ? "None" : selection)
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
                SkillList(selection: selection, skills: skills, allowsNone: allowsNone) { skill in
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
        if selection.isEmpty {
            Text("No skill: Claude follows the prompt only")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let entry = skills.entry(selection) {
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
    var allowsNone = false
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
                if allowsNone && query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Button {
                            onSelect("")
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .opacity(selection.isEmpty ? 1 : 0)
                                Text("None")
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
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

/// A stage with a skill (spec E.6): its mode, and then its skill or its custom prompt.
private struct ClaudeStageRow: View {
    let title: String
    let stage: PromptStage
    let settings: ClaudeSettings
    @ObservedObject var skills: ClaudeSkills
    var allowsNoSkill = false
    let update: (@escaping (inout ClaudeSettings) -> Void) -> Void
    let editPrompt: () -> Void

    private var mode: StageMode { settings.stage(stage)?.mode ?? .skill }

    var body: some View {
        Picker(title, selection: Binding(get: { mode }, set: { value in update { $0.setMode(value, for: stage) } })) {
            ForEach(StageMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if mode == .skill {
            SkillPicker(title: "Skill", selection: settings.skill(for: stage) ?? "", skills: skills, allowsNone: allowsNoSkill) { skill in
                update { $0.setSkill(skill.isEmpty ? nil : skill, for: stage) }
            }
            .padding(.leading, 16)
        } else {
            LabeledContent {
                Button("Edit Prompt…", action: editPrompt)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom prompt")
                    if settings.usesCustomPrompt(stage) {
                        Text("Used instead of the skill").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("No valid prompt yet: the default one runs", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.orangeText)
                    }
                }
            }
            .padding(.leading, 16)
        }
    }
}

/// A finding category, on or off.
private struct CategoryChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(isOn ? Theme.tint(Theme.accent) : Color.primary.opacity(0.06)))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .strikethrough(!isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(isOn ? "Claude reports \(title.lowercased()) findings" : "\(title) findings are hidden")
    }
}
