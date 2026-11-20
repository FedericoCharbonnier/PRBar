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

            UpdatesSection(model: model, updates: model.updates, configStore: configStore)
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .task { await model.refreshNotificationPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshNotificationPermission() }
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
