import Foundation
import PRBarCore

/// `prbar update …` y `prbar config set update-interval` (spec D.4): los mismos métodos que la ventana "Update PRBar"
/// y Settings › General › Updates.
extension AppModel: UpdateCommandActions {
    private func updateInfo(_ outcome: UpdateCheckOutcome) throws -> UpdateInfo {
        switch outcome {
        case .upToDate(let installed):
            return UpdateInfo(installed: installed.description)
        case .available(let release):
            return UpdateInfo(installed: appVersion, release: release,
                              skipped: configStore.config.updates.skippedVersion == release.version.description)
        case .failed(let message):
            throw CommandFailure(.failed, message)
        }
    }

    /// "Check for Updates".
    func updateCheck() async throws -> UpdateInfo {
        try updateInfo(await checkForUpdates())
    }

    /// "Update" / "Update When Done" / "Cancel Jobs and Update". Si sale bien la app se reinicia (la CLI pierde la
    /// conexión y espera a la versión nueva).
    func updateInstall(cancelJobs: Bool, events: @escaping CommandEventSink) async throws -> UpdateInfo {
        if updates.isInstalling { throw CommandFailure(.invalidState, "PRBar is already installing an update.") }
        guard updates.installedApp != nil else {
            throw CommandFailure(.invalidState, "PRBar isn’t running as PRBar.app, so it can check for updates but not install them.")
        }
        let outcome = await checkForUpdates()
        guard case .available(let release) = outcome else {
            _ = try updateInfo(outcome)
            throw CommandFailure(.invalidState, "PRBar is up to date (\(appVersion)).")
        }
        let sink = events
        try await installUpdate(release, whenBusy: cancelJobs ? .cancelJobs : .wait) { event in
            switch event {
            case .phase(let phase): sink(.progress(message: phase.title))
            case .log(let line): sink(.progress(message: line))
            }
        }
        return UpdateInfo(installed: appVersion, release: release)
    }

    /// "Cancel" en la ventana de actualización: solo antes de reemplazar la app.
    func updateCancel() throws {
        guard case .running(let phase) = updates.installState else {
            throw CommandFailure(.invalidState, "No update is being installed.")
        }
        guard phase != .installing && phase != .relaunching else {
            throw CommandFailure(.invalidState, "It’s too late to cancel: PRBar is already being replaced.")
        }
        updates.cancelInstall()
    }

    /// "Skip This Version".
    func updateSkip(version: String?) async throws -> UpdateInfo {
        let outcome = await checkForUpdates()
        guard case .available(let release) = outcome else {
            _ = try updateInfo(outcome)
            throw CommandFailure(.invalidState, "There’s no new version to skip.")
        }
        if let version, version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) != release.version.description {
            throw CommandFailure(.notFound, "The available version is \(release.version.description), not \(version).")
        }
        skipUpdate(release)
        return try updateInfo(.available(release))
    }

    /// "Check automatically" + "Frequency": 0 (solo a mano) o una de las frecuencias del selector.
    func configSetUpdateInterval(hours: Int) throws {
        let choices = UpdateSettings.intervalChoices
        guard hours == 0 || choices.contains(hours) else {
            throw CommandFailure(.invalidUsage, "The update interval is 0 (manual only) or \(choices.map(String.init).joined(separator: ", ")) hours.")
        }
        try applyConfig { $0.updates.checkIntervalHours = hours }
    }
}
