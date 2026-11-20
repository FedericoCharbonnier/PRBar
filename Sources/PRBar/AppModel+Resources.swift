import AppKit
import PRBarCore
import SwiftUI

extension AppModel: ResourceActions {
    static let activityWindowID = "activity"

    func makeResourceMonitor() -> ResourceMonitor {
        // Lo que se mide se lee en el main actor; el escaneo corre fuera (lo lanza `ResourceMonitor` en segundo plano).
        let readInput: @MainActor @Sendable () -> DiskScanInput? = { [weak self] in self?.diskScanInput() }
        let monitor = ResourceMonitor(sampler: ProcessSampler(provider: LiveProcessInfoProvider()),
                                      diskScan: {
                                          guard let input = await readInput() else { return DiskUsage(items: [], scannedAt: Date()) }
                                          return DiskScanner.scan(input)
                                      })
        monitor.onDisk = { [weak self] disk in self?.checkDiskWarning(disk) }
        // Con umbral, el disco se mide también sin nada abierto (al terminar un trabajo, a lo sumo cada 20 min).
        monitor.backgroundDiskScans = { [weak self] in self?.configStore.config.resources.diskWarningGB != nil }
        return monitor
    }

    /// Las carpetas a medir y lo que está en uso, leído en el main actor.
    func diskScanInput() -> DiskScanInput {
        var respondDirs: [DiskScanInput.RespondDir] = []
        var repoByClone: [String: String] = [:]
        for account in configStore.config.accounts {
            for repo in account.repos {
                guard let localPath = repo.localPath else { continue }
                repoByClone[localPath] = repo.id
                respondDirs.append(.init(repo: repo.id, path: repo.worktreeDir ?? WorktreeResolver.defaultWorktreeDir(localPath: localPath),
                                         localPath: localPath))
            }
        }
        var active = WorkspaceRegistry.shared.all()
        for record in respond.records.values { active.insert(record.draft.worktree.path) }
        return .live(respondDirs: respondDirs, activePaths: active, repoByClone: repoByClone)
    }

    func checkDiskWarning(_ disk: DiskUsage) {
        let limit = configStore.config.resources.diskWarningGB
        guard diskWarning.update(total: disk.total, limitGB: limit), let limit,
              let planned = NotificationPlanner.diskWarning(totalBytes: disk.total, limitGB: limit,
                                                            settings: configStore.config.notifications) else { return }
        notifications?.deliver([planned])
    }

    func openActivityWindow() {
        WindowPresenter.shared.show(
            id: Self.activityWindowID, title: "PRBar Activity", size: ActivityWindow.size,
            options: WindowOptions(autosaveName: "ActivityWindow", miniaturizable: true, resizable: true, allowsTabbing: false,
                                   kind: .utility, bridgesToolbar: true, toolbarStyle: .unified),
            contentID: "activity"
        ) {
            ActivityWindow(model: self, monitor: self.resources)
        }
    }

    /// Stop de una tarea de la ventana Activity (decisión I.1.10). `nil` = no se puede parar. Se llama desde el body
    /// de la vista: no tiene efectos; lo que para se resuelve al tocar el botón.
    func stopAction(for activity: ProcessActivity) -> (() -> Void)? {
        switch activity.kind {
        case .review: activity.prID.map { prID in { self.cancelReview(prID: prID) } }
        case .respond, .ciFix: activity.prID.map { prID in { self.cancelRespond(prID: prID) } }
        // El chat de esa sesión, buscado al tocar Stop entre los que ya existen (nunca crea un coordinador).
        case .chat: activity.chatSessionID.map { id in { self.runningChats.first { $0.session.id == id }?.stop() } }
        case .instructions: { self.instructionsChat.stop() }
        case .update: updates.canCancelInstall ? { self.updates.cancelInstall() } : nil
        case .slack, .merge: nil
        }
    }

    // MARK: ResourceActions (CLI)

    func resources() async -> ResourcesInfo {
        let usage = await resources.freshUsage()
        let disk = await resources.freshDisk()
        let month = usageLedger.month(UsageSummary.monthKey(Date()))
        return ResourcesInfo(usage: usage, disk: disk, claudeThisMonth: month.usage.runs > 0 ? month.usage : nil)
    }

    func cleanupPreview(olderThanDays: Int?) async -> CleanupPlan {
        let input = diskScanInput()
        // El escaneo y la búsqueda de archivos viejos (recorren carpetas enteras) fuera del main actor.
        let (disk, old) = await Task.detached(priority: .utility) {
            (DiskScanner.scan(input),
             olderThanDays.map { DiskCleanup.oldFiles(in: [AppPaths.historyDir, AppPaths.logFile.deletingLastPathComponent()],
                                                     olderThanDays: $0) } ?? [])
        }.value
        return DiskCleanup.plan(usage: disk, oldFiles: old, updateInProgress: updates.session.isInstalling)
    }

    func cleanup(olderThanDays: Int?, confirmed: Bool, paths: [String]?) async throws -> CleanupResult {
        // Solo lo que se confirmó y sigue en el plan nuevo (re-verificado otra vez al borrar cada ítem).
        let plan = await cleanupPreview(olderThanDays: olderThanDays).limited(to: paths)
        guard !plan.isEmpty else { return CleanupResult() }
        guard confirmed else { throw CommandFailure(.confirmationRequired, "Clean Up needs confirmation: run it again with --yes.") }
        guard let git = tools.git else { throw CommandFailure(.failed, PRBarError.toolNotFound("git").localizedDescription) }
        let session = updates.session
        let executor = DiskCleanupExecutor(runner: runner, gitPath: git,
                                           worktreeRoots: [AppPaths.worktreesDir, AppPaths.legacyWorktreesDir],
                                           repos: diskScanInput().respondDirs,
                                           isUpdateInProgress: { await MainActor.run { session.isInstalling } })
        // Cuenta como trabajo: una actualización que empiece ahora espera a que termine (`activeJobCount`).
        let result = await cleanups.track { await executor.run(plan) }
        AppLog.write("Clean Up freed \(result.freedBytes) bytes; skipped \(result.skipped.count); failed \(result.failed.count)")
        resources.jobFinished()
        return result
    }

    func configSetDiskWarning(gigabytes: Int?) throws {
        try applyConfig { $0.resources.setDiskWarning(gigabytes: gigabytes) }
    }
}
