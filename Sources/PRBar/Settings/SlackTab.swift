import PRBarCore
import SwiftUI

struct SlackTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var slack: SlackAnnouncer

    @State private var tokenInput = ""
    @State private var status: String?
    @State private var statusOK = false
    @State private var busy = false
    @State private var confirmingDelete = false
    @State private var confirmingSelfTest = false
    @State private var selfTestRunning = false
    @State private var selfTestSteps: [SlackSelfTestStep] = []

    private var settings: SlackSettings { configStore.config.slack }

    var body: some View {
        Form {
            Section {
                Toggle("Use Slack", isOn: Binding(
                    get: { settings.enabled },
                    set: { enabled in model.setSlackEnabled(enabled) }
                ))
            } footer: {
                footer("Messages and reactions are posted as you. Each repo picks its channel in the Repos tab; only PRs and reviews from after you turn this on count.")
            }

            connectionSection
            if settings.provider == .userToken {
                tokenSection
                setupGuide
            }
            selfTestSection

            Section("My PRs") {
                Toggle("Announce new PRs in the channel", isOn: toggle(.announceNewPRs))
                templateEditor("Message", kind: .newPR)
                    .padding(.leading, 16)
                    .disabled(!settings.announceNewPRs)
                Toggle("Reply “Updated” in the thread after a review and a new push", isOn: toggle(.postUpdated))
                templateEditor("Reply", kind: .update)
                    .padding(.leading, 16)
                    .disabled(!settings.postUpdated)
            }
            .disabled(!settings.enabled)

            Section {
                reactionRows("When I start a review", toggle: .reactOnReviewStart, emoji: \.eyesEmoji,
                             placeholder: SlackSettings.defaultEyesEmoji)
                reactionRows("When I first comment", toggle: .reactOnFirstComment, emoji: \.commentEmoji,
                             placeholder: SlackSettings.defaultCommentEmoji)
                Toggle("Reply in the thread on each new round of comments", isOn: toggle(.postRoundMessages))
                templateEditor("Reply", kind: .round)
                    .padding(.leading, 16)
                    .disabled(!settings.postRoundMessages)
                reactionRows("When I approve", toggle: .reactOnApprove, emoji: \.approvedEmoji,
                             placeholder: SlackSettings.defaultApprovedEmoji)
                Stepper(value: Binding(
                    get: { min(max(settings.effectiveSearchDays, 7), 90) },
                    set: { days in model.updateSlackConfig { $0.slack.searchDays = days } }
                ), in: 7...90) {
                    Text("Search the last \(min(max(settings.effectiveSearchDays, 7), 90)) days of the channel")
                }
            } header: {
                Text("Reviews of other PRs")
            } footer: {
                footer("PRBar finds the message with the PR’s link in the repo’s channel and reacts to it as you. Emoji names go without colons.")
            }
            .disabled(!settings.enabled)
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    /// Texto explicativo de una sección, siempre con el mismo estilo.
    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Conexión

    private var connectionSection: some View {
        Section {
            Picker("Connect with", selection: Binding(
                get: { settings.provider },
                set: { provider in
                    status = nil
                    selfTestSteps = []
                    model.setSlackProvider(provider)
                }
            )) {
                Text("Claude’s Slack connector").tag(SlackProvider.claudeConnector)
                Text("Slack user token").tag(SlackProvider.userToken)
            }
            .pickerStyle(.radioGroup)

            if settings.provider == .claudeConnector {
                HStack {
                    Button("Test Connection") { test() }
                        .disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                statusLine
            }
        } header: {
            Text("Connection")
        } footer: {
            footer(settings.provider == .claudeConnector
                   ? "Uses your Claude account’s Slack connector — no Slack app needed. Each action takes a few seconds and uses a little of your Claude usage."
                   : "Instant and free, but needs a Slack app with a user token (sometimes an admin’s approval).")
        }
    }

    // MARK: - Prueba de escritura

    private var selfTestSection: some View {
        Section {
            HStack {
                Button("Send Test to My DM…") { confirmingSelfTest = true }
                    .disabled(selfTestRunning || (settings.provider == .userToken && !slack.hasToken))
                if selfTestRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Show Log") { showConnectorLog() }
                    .disabled(!FileManager.default.fileExists(atPath: AppPaths.slackConnectorLog.path))
            }
            ForEach(selfTestSteps) { step in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: icon(for: step.status))
                        .foregroundStyle(color(for: step.status))
                        .accessibilityLabel(label(for: step.status))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                        Text(step.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Test")
        } footer: {
            footer("Posts one message in your own DM, reacts with an emoji, replies once in its thread and reads it back, the same way PRBar does.")
        }
        .alert("Send a test to your DM?", isPresented: $confirmingSelfTest) {
            Button("Send Test") { runSelfTest() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SlackSelfTest.confirmation)
        }
    }

    private func icon(for status: SlackSelfTestStep.Status) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    private func color(for status: SlackSelfTestStep.Status) -> Color {
        switch status {
        case .ok: Theme.greenText
        case .failed: Theme.redText
        case .skipped: .secondary
        }
    }

    private func label(for status: SlackSelfTestStep.Status) -> String {
        switch status {
        case .ok: "Done"
        case .failed: "Failed"
        case .skipped: "Not run"
        }
    }

    private func runSelfTest() {
        selfTestRunning = true
        selfTestSteps = []
        Task {
            defer { selfTestRunning = false }
            selfTestSteps = await model.postings.track { await slack.sendSelfTest(logURL: AppPaths.slackConnectorLog) }
        }
    }

    private func showConnectorLog() {
        NSWorkspace.shared.open(AppPaths.slackConnectorLog)
    }

    private var tokenSection: some View {
        Section("User token") {
            if slack.needsUserToken {
                Label("PRBar now posts as you. Your old Slack token was removed: paste a User OAuth Token (xoxp-…), or connect with Claude’s Slack connector.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.redText)
            }
            SecureField(
                "User token", text: $tokenInput,
                prompt: Text(slack.hasToken ? "Saved in Keychain · paste a new one to replace it" : "xoxp-…")
            )
            HStack {
                Button("Save and Test") { saveAndTest() }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                Button("Test Connection") { test() }
                    .disabled(!slack.hasToken || busy)
                Spacer()
                if slack.hasToken {
                    Button("Delete Token…", role: .destructive) { confirmingDelete = true }
                }
            }
            statusLine
        }
        .confirmationDialog("Delete the Slack token?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: deleteToken)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’s removed from Keychain, and PRBar stops posting in Slack until you save a new one.")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let status {
            Label(status, systemImage: statusOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(statusOK ? Theme.greenText : Theme.redText)
        }
    }

    private var setupGuide: some View {
        Section {
            DisclosureGroup("How to get a user token") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. At api.slack.com/apps → Create New App → From scratch.")
                    Text("2. OAuth & Permissions → User Token Scopes: chat:write, reactions:write, channels:history, groups:history, channels:read, groups:read.")
                    Text("3. Install to Workspace (may require an admin’s approval).")
                    Text("4. Copy the User OAuth Token (xoxp-…) and paste it above.")
                    Text("5. Pick each repo’s channel in Repos. You must be a member of the channel.")
                    Link("Open api.slack.com/apps", destination: URL(string: "https://api.slack.com/apps")!)
                        .pointingHandCursor()
                        .padding(.top, 4)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Filas

    /// Un switch y, debajo y con sangría, el emoji de la reacción (deshabilitado con el switch apagado).
    @ViewBuilder
    private func reactionRows(_ title: String, toggle slackToggle: SlackToggle,
                              emoji keyPath: WritableKeyPath<SlackSettings, String>, placeholder: String) -> some View {
        Toggle(title, isOn: toggle(slackToggle))
        LabeledContent("Emoji") {
            TextField("Emoji", text: template(keyPath), prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .help("Emoji name, without colons (e.g. \(placeholder))")
        }
        .padding(.leading, 16)
        .disabled(!settings[keyPath: slackToggle.keyPath])
    }

    private func toggle(_ slackToggle: SlackToggle) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: slackToggle.keyPath] },
            set: { on in model.setSlackToggle(slackToggle, on) }
        )
    }

    private func templateEditor(_ title: String, kind: SlackTemplateKind) -> some View {
        SlackTemplateEditor(
            title: title, kind: kind, value: settings[keyPath: kind.keyPath],
            author: configStore.config.accounts.first(where: \.enabled)?.login ?? configStore.config.accounts.first?.login,
            onCommit: { value in model.updateSlackConfig { $0.slack[keyPath: kind.keyPath] = value } }
        )
    }

    private func template(_ keyPath: WritableKeyPath<SlackSettings, String>) -> Binding<String> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in model.updateSlackConfig { $0.slack[keyPath: keyPath] = value } }
        )
    }

    // MARK: - Acciones

    private func deleteToken() {
        do {
            try model.saveSlackToken(nil)
            show("Token deleted", ok: true)
        } catch {
            show(error.localizedDescription, ok: false)
        }
    }

    private func saveAndTest() {
        do {
            try model.saveSlackToken(tokenInput)
            tokenInput = ""
            test()
        } catch {
            show(error.localizedDescription, ok: false)
        }
    }

    private func test() {
        busy = true
        let provider = settings.provider
        Task {
            defer { busy = false }
            do {
                let identity = try await slack.testConnection()
                show(provider == .claudeConnector
                     ? "Connected as @\(identity.user) via Claude"
                     : "Connected as @\(identity.user) on \(identity.team)", ok: true)
            } catch {
                show(error.localizedDescription, ok: false)
            }
        }
    }

    private func show(_ message: String, ok: Bool) {
        status = message
        statusOK = ok
    }
}
