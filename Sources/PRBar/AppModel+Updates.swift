import AppKit
import PRBarCore

/// Actualizaciones (spec D). La CLI (Plan 7: `prbar version`, `prbar update [--check] [--yes]`) llama a estos mismos
/// métodos desde `CommandServer`, así la UI y la CLI comparten el flujo.
extension AppModel {
    static let updateWindowID = "update"

    /// Sin `mode`, la versión que se ofrece; si no hay ninguna (p. ej. se salteó después de la notificación), abre
    /// Settings, donde está "Check for Updates".
    func openUpdateWindow(_ mode: UpdateWindowMode? = nil) {
        guard let mode = mode ?? updates.available.map({ UpdateWindowMode.available($0) }) else {
            openSettings()
            return
        }
        WindowPresenter.shared.show(
            id: Self.updateWindowID, title: mode.title, size: UpdateWindow.size,
            options: WindowOptions(autosaveName: "UpdateWindow", miniaturizable: false, resizable: false, allowsTabbing: false),
            contentID: mode.id
        ) {
            UpdateWindow(updates: self.updates, mode: mode, close: { WindowPresenter.shared.close(id: Self.updateWindowID) })
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

    /// Reviews, análisis, implementaciones, tests y publicaciones de Responder en cola o corriendo, los turnos de
    /// chat y las publicaciones en GitHub (review) y Slack en curso.
    var activeJobCount: Int {
        reviews.phases.values.filter(\.isActive).count
            + respond.phases.values.filter(\.isActive).count
            + respond.runningTests.count
            + runningChats.count
            + (instructionsChat.isRunning ? 1 : 0)
            + postings.count
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
