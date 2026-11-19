import PRBarCore
import SwiftUI

/// Settings › General › Updates (spec D.2): versión instalada, chequeo automático y su frecuencia, y "Check for Updates".
struct UpdatesSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateController
    @ObservedObject var configStore: ConfigStore

    private var settings: UpdateSettings { configStore.config.updates }

    var body: some View {
        Section {
            LabeledContent("Installed version", value: updates.currentVersion)
            Toggle("Check automatically", isOn: Binding(
                get: { settings.checksAutomatically },
                set: { on in model.updateConfig(refresh: false) { $0.updates.setAutomaticChecks(on) } }
            ))
            Picker("Frequency", selection: Binding(
                get: { shownInterval },
                set: { hours in model.updateConfig(refresh: false) { $0.updates.checkIntervalHours = hours } }
            )) {
                ForEach(intervalChoices, id: \.self) { Text(Self.intervalTitle($0)).tag($0) }
            }
            .disabled(!settings.checksAutomatically)
            HStack(alignment: .firstTextBaseline) {
                status
                Spacer()
                Button("Check for Updates") { Task { await updates.check(manual: true) } }
                    .disabled(updates.isChecking || updates.isInstalling)
            }
        } header: {
            Text("Updates")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("New versions come from github.com/\(settings.effectiveRepo) and are built on this Mac.")
                if updates.installedApp == nil {
                    Text("PRBar isn’t running as PRBar.app, so updates can be checked but not installed.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Apagado muestra el default (el selector queda deshabilitado).
    private var shownInterval: Int {
        settings.checksAutomatically ? settings.checkIntervalHours : UpdateSettings.defaultCheckIntervalHours
    }

    /// Las opciones fijas más la guardada, si alguien puso otra en `config.json`.
    private var intervalChoices: [Int] {
        Array(Set(UpdateSettings.intervalChoices + [shownInterval])).sorted()
    }

    static func intervalTitle(_ hours: Int) -> String {
        switch hours {
        case 1: "Every hour"
        case 24: "Daily"
        case 168: "Weekly"
        default: "Every \(hours) hours"
        }
    }

    @ViewBuilder
    private var status: some View {
        if updates.isInstalling {
            Text("Updating…").foregroundStyle(.secondary)
        } else if updates.isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        } else if let release = updates.available {
            HStack(spacing: 8) {
                Text("PRBar \(release.version.description) is available").foregroundStyle(Theme.blueText)
                Button("Update…") { model.openUpdateWindow() }.controlSize(.small)
            }
        } else if case .failed(let message)? = updates.lastManualOutcome {
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.redText)
                .fixedSize(horizontal: false, vertical: true)
        } else if case .upToDate? = updates.lastManualOutcome {
            Text("PRBar is up to date").foregroundStyle(.secondary)
        } else if let last = settings.lastCheckAt {
            let age = RelativeAge.short(from: last)
            Text(age == "now" ? "Checked just now" : "Last checked \(age) ago").foregroundStyle(.secondary)
        } else {
            Text("Not checked yet").foregroundStyle(.secondary)
        }
    }
}
