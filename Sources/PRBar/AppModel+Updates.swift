import AppKit
import PRBarCore

/// Actualizaciones (spec D). La CLI (Plan 7: `prbar version`, `prbar update [--check] [--yes]`) llama a estos mismos
/// métodos desde `CommandServer`, así la UI y la CLI comparten el flujo.
extension AppModel {
    /// Sin `mode`, la versión que se ofrece; si no hay ninguna (p. ej. se salteó después de la notificación), abre
    /// Settings, donde está "Check for Updates".
    func openUpdateWindow(_ mode: UpdateWindowMode? = nil) {
        guard !Self.ignoresPhoneRequest("opening the Update sheet") else { return }
        guard let mode = mode ?? updates.available.map({ UpdateWindowMode.available($0) }) else {
            openSettings()
            return
        }
        // Una hoja sobre la ventana principal (spec M.2); la abre si estaba cerrada.
        main.updateSheet = mode
        openMainWindow()
    }

    /// The app menu's "Check for Updates…" / "Update to PRBar 1.3.0…": with a version offered, its Update window;
    /// otherwise a manual check, shown in Settings › General › Updates ("Checking…", then "up to date" or the error),
    /// and the Update window if it finds one.
    func checkForUpdatesFromMenu() {
        if updates.available != nil || updates.isInstalling {
            openUpdateWindow()
            return
        }
        openSettings(tab: .general)
        guard !updates.isChecking else { return }
        Task {
            if case .available(let release) = await checkForUpdates() { openUpdateWindow(.available(release)) }
        }
    }

    /// La versión instalada (`prbar version`).
    var appVersion: String { updates.currentVersion }

    /// Chequeo manual (botón "Check for Updates", `prbar update --check`). Nunca lanza.
    func checkForUpdates() async -> UpdateCheckOutcome {
        await updates.check(manual: true)
    }

    /// Instala `release` y reinicia la app. `onEvent` recibe las etapas y el log (la CLI los reenvía como eventos).
    func installUpdate(_ release: ReleaseInfo, whenBusy: UpdateBusyPolicy, onEvent: ((UpdateEvent) -> Void)? = nil) async throws {
        try await updates.install(release, whenBusy: whenBusy, onEvent: onEvent)
    }

    func skipUpdate(_ release: ReleaseInfo) {
        updates.skip(release)
    }

    /// Why new reviews, responds, fixes, test runs and chat turns can't start: an update is being installed (spec D.3).
    /// `nil` = they can.
    var jobsBlockedReason: String? { updates.jobsBlockedReason }

    /// "Implement N Fixes" (ventana) o `prbar respond implement`: los fixes elegidos en el coordinador del análisis,
    /// salvo que se esté instalando una actualización.
    func implementRespond(prID: String) {
        guard jobsBlockedReason == nil, let draft = respond.records[prID]?.draft else { return }
        respond.implement(prID: prID, selections: respondSelections(for: draft))
    }

    /// Reviews, análisis, implementaciones, tests y publicaciones de Responder en cola o corriendo, los turnos de
    /// chat y las publicaciones en GitHub (review) y Slack en curso.
    var activeJobCount: Int {
        reviews.phases.values.filter(\.isActive).count
            + respond.phases.values.filter(\.isActive).count
            + respond.runningTests.count
            + runningChats.count
            + (instructionsChat.isRunning ? 1 : 0)
            + postings.count
            + cleanups.count
    }

    /// "Cancel Jobs and Update": cancela todo salvo las publicaciones/pushes en curso (`RespondQueue.cancel` no las
    /// toca), que se esperan.
    func cancelJobsForUpdate() {
        reviews.cancelAll()
        for prID in Set(respond.phases.keys).union(respond.runningTests) {
            respond.cancel(prID: prID)
        }
        // Lo mismo que el botón Stop de cada chat.
        for chat in runningChats { chat.stop() }
        instructionsChat.stop()
    }
}
