import AppKit
import PRBarCore
import SwiftUI

/// Settings › Instructions (spec E.2): the rules PRBar adds to Claude's prompts, grouped (Global, one section per
/// configured repo and "Other repos" for the rest: `RuleSections`), the suggestions from what you discard (E.4) and
/// the instructions chat.
struct InstructionsTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: InstructionsStore
    @ObservedObject var chat: InstructionsChatCoordinator
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        VStack(spacing: 0) {
            Form {
                notices
                let suggestions = model.ruleSuggestions()
                if !suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggestions) { RuleSuggestionCard(model: model, suggestion: $0) }
                    }
                }
                let sections = RuleSections(store.rules, configuredRepos: model.configuredRepos)
                ruleSection(.global, rules: sections.global)
                ForEach(sections.repos, id: \.repo) { ruleSection(.repo($0.repo), rules: $0.rules) }
                if !sections.other.isEmpty { otherReposSection(sections.other) }
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            Divider()
            InstructionsChatPanel(chat: chat, unavailableReason: model.chatUnavailableReason)
                .frame(height: 220)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let error = store.loadError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.orangeText)
            }
        }
        let dropped = RulesPrompt.droppedAnywhere(store.rules, repos: model.configuredRepos.compactMap(RepoRef.init(fullName:)))
        if !dropped.isEmpty {
            Section {
                Label("Some prompts would get more than \(RulesPrompt.maxCharacters) characters of rules: the \(dropped.count) least recently edited aren’t sent. Shorten or turn off some rules.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.orangeText)
            }
        }
    }

    private func ruleSection(_ scope: RuleScope, rules: [Rule]) -> some View {
        Section {
            ForEach(rules) { rule in
                RuleRow(rule: rule, isHighlighted: chat.highlighted.contains(rule.id.uuidString), model: model)
            }
            NewRuleField(scope: scope, model: model)
        } header: {
            Text(scope.title)
        } footer: {
            if scope == .global {
                Text("Rules go into every Claude prompt for reviews (Review) or for fixing feedback on your PRs (Fixes). They never change what Claude can do: no shell, no posting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Rules of repos that aren't configured (or whose account is off): they still apply to that repo's PRs.
    private func otherReposSection(_ rules: [Rule]) -> some View {
        Section {
            ForEach(rules) { rule in
                RuleRow(rule: rule, isHighlighted: chat.highlighted.contains(rule.id.uuidString), model: model, showsRepo: true)
            }
        } header: {
            Text("Other Repos")
        } footer: {
            Text("These repos aren’t in your settings, or their account is off. Their rules still apply to those repos’ PRs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One rule: text editable inline, Review/Fixes chips, the switch, delete, its origin and date.
private struct RuleRow: View {
    let rule: Rule
    let isHighlighted: Bool
    let model: AppModel
    /// "Other Repos": the rule's repo, which no section header says.
    var showsRepo = false

    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: rule.source.symbol)
                    .foregroundStyle(.secondary)
                    .help(rule.source.title)
                    .accessibilityLabel(rule.source.title)
                TextField("Rule", text: $text, prompt: Text("Rule"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(commit)
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                Toggle("Enabled", isOn: Binding(
                    get: { rule.enabled },
                    set: { on in perform { try model.setRuleEnabled(rule.id, on) } }
                ))
                .labelsHidden()
                .controlSize(.mini)
                .help(rule.enabled ? "Turn off" : "Turn on")
                Button {
                    perform { try model.removeRule(rule.id) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete Rule")
                .accessibilityLabel("Delete Rule")
            }
            HStack(spacing: 6) {
                ForEach(RuleStage.allCases, id: \.self) { stage in
                    StageChip(stage: stage, isOn: rule.appliesTo.contains(stage)) { toggle(stage) }
                }
                Spacer()
                if showsRepo, let repo = rule.scope.repo {
                    Text(repo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(ReviewDates.ago(rule.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.redText)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isHighlighted ? Theme.tint(Theme.accent) : nil)
        .animation(.easeInOut(duration: 0.3), value: isHighlighted)
        .onAppear { text = rule.text }
        .onChange(of: rule.text) { _, value in if !focused { text = value } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func toggle(_ stage: RuleStage) {
        var stages = rule.appliesTo
        if stages.contains(stage) { stages.remove(stage) } else { stages.insert(stage) }
        perform { try model.editRule(rule.id, appliesTo: stages) }
    }

    private func commit() {
        guard text != rule.text else { return }
        perform { try model.editRule(rule.id, text: text) }
        if error != nil { text = rule.text }
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// "Add a rule…" at the end of each section.
private struct NewRuleField: View {
    let scope: RuleScope
    let model: AppModel

    @State private var text = ""
    @State private var stages: Set<RuleStage> = [.review, .respond]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("New Rule", text: $text, prompt: Text("Add a rule…"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...4)
                    .onSubmit(add)
                ForEach(RuleStage.allCases, id: \.self) { stage in
                    StageChip(stage: stage, isOn: stages.contains(stage)) {
                        if stages.contains(stage) { stages.remove(stage) } else { stages.insert(stage) }
                    }
                }
                Button("Add", action: add)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.redText)
            }
        }
    }

    private func add() {
        do {
            try model.addRule(text, scope: scope, appliesTo: stages)
            text = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The instructions chat (spec E.2): Claude has no tools here; it only changes your rules, and you can undo it.
struct InstructionsChatPanel: View {
    @ObservedObject var chat: InstructionsChatCoordinator
    let unavailableReason: String?

    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Instructions Chat").font(.headline)
                Spacer()
                Text("Claude has no tools here: it only edits your rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.chat.messages.isEmpty && !chat.isRunning {
                            Text("Tell Claude what to remember: “don’t comment on style”, “in web-app use React Query”, “delete the console.log one”.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(chat.chat.messages) { message in
                            ChatMessageRow(
                                message: message, summary: ChatActions.summary(message.changes) { _ in nil },
                                canUndo: message.id == chat.chat.undoableMessageID && chat.canUndo,
                                undo: { undo(message.id) }, logURL: AppPaths.instructionsChatLog
                            )
                            .id(message.id)
                        }
                        if chat.isRunning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(chat.activity.map { "Claude is working… · \($0)" } ?? "Claude is working…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .id("working")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                .onChange(of: chat.chat.messages.count) { _, _ in
                    if let last = chat.chat.messages.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .disabled(!canType)
                    .onKeyPress(.return, phases: .down) { press in ChatInputKeys.handleReturn(press, send: send) }
                if chat.isRunning {
                    Button("Stop") { chat.stop() }.controlSize(.small)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canType || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (↩)")
                    .accessibilityLabel("Send")
                }
            }
            .padding(10)
            .background(.bar)
        }
    }

    private var canType: Bool { unavailableReason == nil && chat.canSend }

    private var placeholder: String {
        if let unavailableReason { return unavailableReason }
        if chat.isRunning { return "Claude is working…" }
        return "Ask Claude to add, change or remove rules… (↩ to send)"
    }

    private func send() {
        guard canType, chat.send(text) else { return }
        text = ""
    }

    private func undo(_ id: UUID) {
        if chat.undoDiscardsLaterEdits(id) {
            ConfirmAlert.present(title: "Undo Claude’s changes?",
                                 message: "Undo will also discard your edits to those rules since then.", action: "Undo") {
                chat.undo(id)
            }
        } else {
            chat.undo(id)
        }
    }
}
