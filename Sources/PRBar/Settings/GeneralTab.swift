import AppKit
import PRBarCore
import SwiftUI

struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore

    private static let notificationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    var body: some View {
        Form {
            Section {
                Picker("Refresh every", selection: Binding(
                    get: { configStore.config.refreshIntervalMinutes },
                    set: { minutes in model.updateConfig(refresh: false) { $0.refreshIntervalMinutes = minutes } }
                )) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                }
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle("Always show in Dock", isOn: Binding(
                    get: { configStore.config.alwaysShowInDock },
                    set: { model.setAlwaysShowInDock($0) }
                ))
            }

            Section {
                ToolPathField(model: model, name: "gh", resolved: model.tools.gh, override: \.gh, saved: configStore.config.toolPaths.gh)
                ToolPathField(model: model, name: "git", resolved: model.tools.git, override: \.git, saved: configStore.config.toolPaths.git)
                ToolPathField(
                    model: model, name: "claude", resolved: model.tools.claude, override: \.claude, saved: configStore.config.toolPaths.claude
                )
            } header: {
                Text("Tools")
            } footer: {
                Text("PRBar finds these tools automatically. Choose a path to use a different copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Terminal", selection: Binding(
                    get: { configStore.config.terminal },
                    set: { choice in model.updateConfig(refresh: false) { $0.setTerminal(choice) } }
                )) {
                    ForEach(TerminalApps.offered(current: configStore.config.terminal), id: \.self) { choice in
                        Text(TerminalApps.menuTitle(choice)).tag(choice)
                    }
                }
                if configStore.config.terminal == .custom {
                    TextField("Command", text: Binding(
                        get: { configStore.config.terminalCommand ?? "" },
                        set: { text in model.updateConfig(refresh: false) { $0.setTerminalCommand(text) } }
                    ), prompt: Text("open -na Ghostty --args -e /bin/zsh -lc {command}"))
                    // The same check `TerminalOpener` runs before launching (empty, no {command}, quoted placeholder).
                    if let problem = customCommandProblem(configStore.config.terminalCommand) {
                        Text(problem).font(.caption).foregroundStyle(Theme.redText)
                    }
                }
            } header: {
                Text("Claude Sessions")
            } footer: {
                Text(configStore.config.terminal == .custom
                     ? "{dir} is the PR’s folder, {command} runs Claude. PRBar quotes both: don’t put them in quotes. PRBar runs the command in the background, so it should open the terminal and return."
                     : "Where the Terminal button opens Claude’s session of a PR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: notification(\.enabled)) {
                    Text("Show notifications")
                    Text("Uses the style set in System Settings")
                }
                Group {
                    Toggle("New PR to review", isOn: notification(\.newToReview))
                    Toggle("A PR I reviewed has new commits", isOn: notification(\.reviewedPRUpdated))
                    Toggle("My PR got change requests or comments", isOn: notification(\.myPRFeedback))
                    Toggle("Claude finished a review or a response", isOn: notification(\.reviewFinished))
                    Toggle("My PR was approved or CI failed", isOn: notification(\.myPRApprovedOrCIFailed))
                    Toggle("My PR is ready to merge", isOn: notification(\.readyToMerge))
                }
                .padding(.leading, 16)
                .disabled(!configStore.config.notifications.enabled)
            } header: {
                Text("Notifications")
            } footer: {
                if model.notificationsDenied {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Notifications for PRBar are turned off in macOS.", systemImage: "bell.slash")
                            .font(.caption)
                            .foregroundStyle(Theme.orangeText)
                        Spacer()
                        Button("Open System Settings…") { NSWorkspace.shared.open(Self.notificationSettingsURL) }
                            .controlSize(.small)
                    }
                }
            }

            Section {
                Toggle("Warn when PRBar uses more than", isOn: Binding(
                    get: { configStore.config.resources.diskWarningGB != nil },
                    set: { on in model.updateConfig(refresh: false) { $0.resources.setDiskWarning(gigabytes: on ? 5 : nil) } }
                ))
                // Always there (disabled while the warning is off), so the limit you'd get is visible before turning it on.
                let limit = configStore.config.resources.diskWarningGB
                Stepper("\(limit ?? 5) GB", value: Binding(
                    get: { limit ?? 5 },
                    set: { gigabytes in model.updateConfig(refresh: false) { $0.resources.setDiskWarning(gigabytes: gigabytes) } }
                ), in: ResourceSettings.gigabyteRange)
                .disabled(limit == nil)
            } header: {
                Text("Disk")
            } footer: {
                Text("A notification when PRBar’s worktrees, history and logs pass this size. See them in PRBar Activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            UpdatesSection(model: model, updates: model.updates, configStore: configStore)
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .task { await model.refreshNotificationPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshNotificationPermission() }
        }
    }

    /// What `TerminalLauncher.validateCustomCommand` says about the Custom command (nil = fine).
    private func customCommandProblem(_ command: String?) -> String? {
        do {
            try TerminalLauncher.validateCustomCommand(command ?? "")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func notification(_ keyPath: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { configStore.config.notifications[keyPath: keyPath] },
            set: { value in model.updateConfig(refresh: false) { $0.notifications[keyPath: keyPath] = value } }
        )
    }
}

/// Ruta de una herramienta: la detectada (en gris) o la elegida con "Choose…"; "Use Automatic" vuelve a buscarla.
private struct ToolPathField: View {
    let model: AppModel
    let name: String
    let resolved: String?
    let override: WritableKeyPath<ToolPaths, String?>
    /// Ruta personalizada guardada (`nil` = detectada automáticamente).
    let saved: String?

    var body: some View {
        PathRow(
            path: saved ?? resolved ?? "Not found",
            isPlaceholder: saved == nil,
            reset: saved == nil ? nil : .init(title: "Use Automatic") { setPath("") },
            choose: choose
        ) {
            Text(name).font(.system(.body, design: .monospaced))
        } status: {
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        if resolved != nil {
            Label(saved == nil ? "Found automatically" : "Custom path", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.greenText)
        } else {
            Label(saved == nil ? "Not found" : "Not found at this path", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.redText)
        }
    }

    private func setPath(_ path: String) {
        Task { await model.setToolPath(path, for: override) }
    }

    @MainActor
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the \(name) executable"
        panel.prompt = "Use"
        if let current = resolved ?? saved {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        OpenPanel.present(panel) { url in setPath(url.path) }
    }
}

enum OpenPanel {
    /// Muestra el panel como hoja de la ventana activa (o como ventana si no hay ninguna).
    @MainActor
    static func present(_ panel: NSOpenPanel, onChoose: @escaping (URL) -> Void) {
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            onChoose(url)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }
}
