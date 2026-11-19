import AppKit
import PRBarCore

/// Chequeo e instalación de actualizaciones (spec D). Lo crea `AppModel`; la UI (popover, Settings, ventana
/// "Update PRBar") y la CLI (Plan 7, por los métodos de `AppModel+Updates`) pasan por acá.
@MainActor
final class UpdateController: ObservableObject {
    enum InstallState: Equatable {
        case idle
        case running(UpdatePhase)
        case failed(String)
    }

    /// Cada cuánto se fija si toca chequear (el intervalo real es `updates.checkIntervalHours`).
    private static let schedulerTick: Duration = .seconds(3600)
    private static let maxLogLines = 2000

    /// Versión nueva que se ofrece (popover, Settings). `nil`: al día, salteada o sin chequear.
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var isChecking = false
    /// Resultado del último chequeo manual (Settings muestra "up to date" o el error).
    @Published private(set) var lastManualOutcome: UpdateCheckOutcome?
    @Published private(set) var installState: InstallState = .idle
    @Published private(set) var log: [String] = []
    /// Trabajos que se están esperando antes de reemplazar la app.
    @Published private(set) var waitingJobs = 0

    let currentVersion = AppVersion.current()

    private let configStore: ConfigStore
    private let transport: any HTTPTransport
    private let runner: SystemProcessRunner
    private let notifications: NotificationDelivery?
    private let gitPath: () -> String?
    private let activeJobs: () -> Int
    private let cancelJobs: () -> Void
    private var scheduler: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
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
        self.cancelJobs = cancelJobs
    }

    var installedVersion: SemanticVersion { SemanticVersion(currentVersion) ?? SemanticVersion(0, 0, 0) }

    /// El `.app` que está corriendo; `nil` con `swift run` (ahí se puede chequear pero no instalar).
    var installedApp: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    var isInstalling: Bool {
        if case .running = installState { return true }
        return false
    }

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

    /// Desde la ventana: corre `install` en una tarea propia y deja el error en `installState`.
    func startInstall(_ release: ReleaseInfo, whenBusy: UpdateBusyPolicy) {
        guard !isInstalling else { return }
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.install(release, whenBusy: whenBusy)
            } catch is CancellationError {
                self.installState = .idle
                self.appendLog("Update canceled.")
            } catch {
                self.installState = .failed(error.localizedDescription)
                self.appendLog("Update failed: \(error.localizedDescription)")
            }
        }
    }

    /// Solo antes de instalar (la ventana no ofrece Cancel en `installing`/`relaunching`).
    func cancelInstall() {
        installTask?.cancel()
    }

    /// Todo el flujo: esperar trabajos, bajar, compilar, verificar, reemplazar y reiniciar. Si sale bien no vuelve:
    /// la app termina y la versión nueva arranca sola.
    func install(_ release: ReleaseInfo, whenBusy: UpdateBusyPolicy, onEvent: ((UpdateEvent) -> Void)? = nil) async throws {
        guard !isInstalling else { throw UpdateError.alreadyInstalling }
        guard let installedApp else { throw UpdateError.notInstalledAsApp }
        guard let git = gitPath() else { throw PRBarError.toolNotFound("git") }
        let id = UUID()
        installID = id
        eventObserver = onEvent
        defer {
            if installID == id { installID = nil }
            eventObserver = nil
        }
        log = []
        UpdateLogFile.reset()
        appendLog("Updating PRBar \(currentVersion) → \(release.version)")
        // En el acto (los eventos llegan un instante después): un segundo click en "Update" no arranca otra instalación.
        installState = .running(.fetching)

        try await drainJobs(whenBusy)
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
            beforeReplace: { [weak self] in try await self?.drainJobs(whenBusy) },
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

    /// Espera a que no quede ningún trabajo; con `.cancelJobs` primero los cancela (las publicaciones y pushes en
    /// curso no se cancelan: se esperan).
    private func drainJobs(_ policy: UpdateBusyPolicy) async throws {
        guard activeJobs() > 0 else { return }
        if policy == .cancelJobs {
            appendLog("Canceling running jobs (posting and pushing finish first).")
            cancelJobs()
        }
        record(.phase(.waitingForJobs))
        while activeJobs() > 0 {
            waitingJobs = activeJobs()
            try await Task.sleep(for: .seconds(1))
        }
        waitingJobs = 0
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
            installState = .running(phase)
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
