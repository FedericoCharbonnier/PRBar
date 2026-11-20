import AppKit
import Combine
import PRBarCore

/// Chequeo e instalación de actualizaciones (spec D). Lo crea `AppModel`; la UI (popover, Settings, ventana
/// "Update PRBar") y la CLI (Plan 7, por los métodos de `AppModel+Updates`) pasan por acá.
@MainActor
final class UpdateController: ObservableObject {
    /// Cada cuánto se fija si toca chequear (el intervalo real es `updates.checkIntervalHours`).
    private static let schedulerTick: Duration = .seconds(3600)
    private static let maxLogLines = 2000

    /// Versión nueva que se ofrece (popover, Settings). `nil`: al día, salteada o sin chequear.
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var isChecking = false
    /// Resultado del último chequeo manual (Settings muestra "up to date" o el error).
    @Published private(set) var lastManualOutcome: UpdateCheckOutcome?
    @Published private(set) var log: [String] = []
    /// Estado de la instalación y espera de trabajos (lo comparten la ventana y la CLI).
    let session: UpdateInstallSession
    private var sessionObserver: AnyCancellable?

    let currentVersion = AppVersion.current()

    private let configStore: ConfigStore
    private let transport: any HTTPTransport
    private let runner: SystemProcessRunner
    private let notifications: NotificationDelivery?
    private let gitPath: () -> String?
    private let activeJobs: () -> Int
    private var scheduler: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    /// La instalación que pidió la CLI (`install`): "Cancel" (ventana o `prbar update --cancel`) también la cancela.
    private var requestedInstall: Task<Void, Error>?
    /// Id de la instalación en curso: los eventos de una instalación vieja (que llegan tarde al hilo principal) se ignoran.
    private var installID: UUID?
    /// Quien pidió la instalación por `install(_:whenBusy:onEvent:)` (la CLI) recibe también los eventos.
    private var eventObserver: ((UpdateEvent) -> Void)?

    init(
        configStore: ConfigStore, transport: any HTTPTransport, runner: SystemProcessRunner, notifications: NotificationDelivery?,
        gitPath: @escaping () -> String?, activeJobs: @escaping () -> Int, cancelJobs: @escaping () -> Void
    ) {
        self.configStore = configStore
        self.transport = transport
        self.runner = runner
        self.notifications = notifications
        self.gitPath = gitPath
        self.activeJobs = activeJobs
        session = UpdateInstallSession(activeJobs: activeJobs, cancelJobs: cancelJobs)
        sessionObserver = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var installState: UpdateInstallState { session.state }
    /// Trabajos que se están esperando antes de seguir.
    var waitingJobs: Int { session.waitingJobs }
    /// Por qué no se puede empezar un trabajo nuevo mientras se instala; `nil` = se puede.
    var jobsBlockedReason: String? { session.blockedReason }

    var installedVersion: SemanticVersion { SemanticVersion(currentVersion) ?? SemanticVersion(0, 0, 0) }

    /// El `.app` que está corriendo; `nil` con `swift run` (ahí se puede chequear pero no instalar).
    var installedApp: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    var isInstalling: Bool { session.isInstalling }

    var runningJobs: Int { activeJobs() }

    static func openLog() {
        NSWorkspace.shared.open(AppPaths.updateLog)
    }

    // MARK: Chequeo

    /// Al arrancar y después cada hora: chequea si pasó el intervalo.
    func startAutomaticChecks() {
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: Self.schedulerTick)
            }
        }
    }

    func checkIfDue() async {
        guard !isChecking, UpdatePolicy.isCheckDue(configStore.config.updates, now: Date()) else { return }
        await check(manual: false)
    }

    @discardableResult
    func check(manual: Bool) async -> UpdateCheckOutcome {
        isChecking = true
        defer { isChecking = false }
        let settings = configStore.config.updates
        let checker = UpdateChecker(transport: transport, repo: settings.effectiveRepo)
        let report = await checker.check(
            installed: installedVersion, settings: settings, notifications: configStore.config.notifications,
            manual: manual, now: Date()
        )
        save { updates in
            updates.lastCheckAt = report.settings.lastCheckAt
            updates.notifiedVersion = report.settings.notifiedVersion
        }
        if case .failed = report.outcome {} else { available = report.offered }
        if let notification = report.notification { notifications?.deliver([notification]) }
        if manual { lastManualOutcome = report.outcome }
        return report.outcome
    }

    func skip(_ release: ReleaseInfo) {
        save { $0.skippedVersion = release.version.description }
        if available?.version == release.version { available = nil }
    }

    // MARK: Instalación

    /// Desde la ventana: marca "instalando" en el acto (un doble click no arranca dos) y corre la instalación en una
    /// tarea propia; el error queda en `installState`.
    func startInstall(_ release: ReleaseInfo, whenBusy: UpdateBusyPolicy) {
        guard (try? beginInstall(release)) != nil else { return }
        installTask = Task { [weak self] in
            try? await self?.runInstall(release, whenBusy: whenBusy, onEvent: nil)
        }
    }

    /// Solo antes de instalar (la ventana no ofrece Cancel en `installing`/`relaunching`).
    func cancelInstall() {
        installTask?.cancel()
        requestedInstall?.cancel()
    }

    /// Todo el flujo: esperar trabajos, bajar, compilar, verificar, reemplazar y reiniciar. Si sale bien no vuelve:
    /// la app termina y la versión nueva arranca sola. Si falla, `installState` queda `.failed` (o `.idle` si se
    /// canceló) y se relanza el error (la CLI lo reporta).
    func install(_ release: ReleaseInfo, whenBusy: UpdateBusyPolicy, onEvent: ((UpdateEvent) -> Void)? = nil) async throws {
        try beginInstall(release)
        let task = Task { try await self.runInstall(release, whenBusy: whenBusy, onEvent: onEvent) }
        requestedInstall = task
        defer { requestedInstall = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func beginInstall(_ release: ReleaseInfo) throws {
        try session.begin()
        log = []
        UpdateLogFile.reset()
        appendLog("Updating PRBar \(currentVersion) → \(release.version)")
    }

    private func runInstall(_ release: ReleaseInfo, whenBusy: UpdateBusyPolicy, onEvent: ((UpdateEvent) -> Void)?) async throws {
        let id = UUID()
        installID = id
        eventObserver = onEvent
        defer {
            if installID == id { installID = nil }
            eventObserver = nil
        }
        do {
            try await session.run(whenBusy, onEvent: { [weak self] event in self?.record(event, install: id) }) { beforeReplace in
                try await self.performInstall(release, install: id, beforeReplace: beforeReplace)
            }
        } catch is CancellationError {
            appendLog("Update canceled.")
            throw CancellationError()
        } catch {
            appendLog("Update failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func performInstall(
        _ release: ReleaseInfo, install id: UUID, beforeReplace: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard let installedApp else { throw UpdateError.notInstalledAsApp }
        guard let git = gitPath() else { throw PRBarError.toolNotFound("git") }
        let installer = UpdateInstaller(
            source: UpdateSource(
                runner: runner, gitPath: git,
                remoteURL: UpdateSource.remoteURL(forRepo: configStore.config.updates.effectiveRepo)
            ),
            builder: runner, runner: runner,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.federico.prbar"
        )
        try await installer.install(
            release, replacing: installedApp,
            beforeReplace: beforeReplace,
            onEvent: { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.record(event, install: id) } }
            }
        )

        do {
            try PendingUpdate.save(PendingUpdate(version: release.version.description, notes: release.notes, installedAt: Date()))
        } catch {
            AppLog.write("Couldn't save update-installed.json: \(error.localizedDescription)")
        }
        record(.phase(.relaunching))
        do {
            try Relauncher.launch(waitingFor: ProcessInfo.processInfo.processIdentifier, appPath: installedApp.path)
        } catch {
            throw UpdateError.relaunchFailed(release.version.description)
        }
        NSApp.terminate(nil)
    }

    // MARK: Arranque

    /// Al arrancar: borra `PRBar.app.previous` y devuelve la actualización recién instalada (para "Updated to …").
    func finishPendingInstall() -> PendingUpdate? {
        if let installedApp { AppReplacer.removePrevious(nextTo: installedApp) }
        return PendingUpdate.take(currentVersion: currentVersion)
    }

    /// Modo de capturas.
    func applySnapshotState(available: ReleaseInfo?) {
        self.available = available
    }

    // MARK: Log y estado

    private func record(_ event: UpdateEvent, install id: UUID) {
        guard installID == id else { return }
        record(event)
    }

    private func record(_ event: UpdateEvent) {
        switch event {
        case .phase(let phase):
            session.enter(phase)
            appendLog("== \(phase.title)")
        case .log(let line):
            appendLog(line)
        }
        eventObserver?(event)
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
        UpdateLogFile.append(line)
    }

    private func save(_ mutate: (inout UpdateSettings) -> Void) {
        var next = configStore.config.updates
        mutate(&next)
        guard next != configStore.config.updates else { return }
        do {
            try configStore.update { $0.updates = next }
        } catch {
            AppLog.write("Couldn't save the update settings: \(error.localizedDescription)")
        }
    }
}

/// `~/Library/Logs/PRBar/update.log`: el log de la última actualización ("Show Log").
private enum UpdateLogFile {
    static func reset() {
        let url = AppPaths.updateLog
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    static func append(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: AppPaths.updateLog) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
