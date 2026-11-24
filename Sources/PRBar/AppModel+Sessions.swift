import AppKit
import Foundation
import PRBarCore

/// Claude's sessions in a terminal (spec T): the kept folders, what "Terminal" offers and opening it.
extension AppModel {
    // MARK: Settings (spec T.6)

    func configSetTerminal(_ terminal: TerminalChoice) throws {
        try applyConfig { $0.setTerminal(terminal) }
    }

    /// Empty clears it; otherwise the same check `TerminalOpener` runs before launching (has `{command}`, no quoted
    /// placeholders).
    func configSetTerminalCommand(_ command: String) throws {
        do {
            var probe = AppConfig()
            try probe.setTerminalCommand(validating: command)
        } catch {
            throw CommandFailure(.invalidUsage, "\(error.localizedDescription) {dir} is the PR’s folder, {command} runs Claude.")
        }
        try applyConfig { $0.setTerminalCommand(command) }
    }

    // MARK: Kept folders (spec T.3)

    /// `entry` becomes the kept folder of its (PR, job); the older one goes unless a process works inside or it holds
    /// work that isn't pushed (then it stays, `superseded`, for Clean Up). It stays in the list, `superseded`, until
    /// it's really gone: quitting meanwhile leaves it protected and retried at launch, never an orphan.
    func retain(_ entry: RetainedWorktree) {
        let (entries, replaced) = RetainedWorktreeRules.retain(entry, in: retainedWorktrees)
        setRetained(entries)
        guard !replaced.isEmpty else { return }
        let cleaner = retainedCleaner()
        Task { [weak self] in
            let left = await cleaner.removeUnlessBusy(replaced)
            self?.forgetRetained(replaced, keeping: left)
        }
    }

    /// A pushed Respond or Fix CI (`RespondQueue.onRetain`). The queue already released it (`RespondPipelineRunning
    /// .release(draft:)`: no longer in use, Mac-side copy of a runner's fixes gone); dismissing it doesn't delete it.
    func retainRespond(_ record: RespondRecord) {
        let draft = record.draft
        // Only PRBar's own worktree: never the user's clone or one of their worktrees.
        guard draft.worktree.origin == .dedicated else {
            AppLog.write("Retained worktrees: not keeping \(draft.worktree.path): it isn’t a PRBar worktree.")
            return
        }
        let location = WorktreeLocation(directory: draft.worktree.path, runner: draft.runner, repository: draft.worktree.localPath,
                                        refs: draft.worktree.ref.map { [$0] } ?? [])
        retain(RetainedWorktree(prID: draft.prID, account: draft.account, repo: draft.repo, number: draft.number, job: .respond,
                                recordID: draft.id, location: location, sessions: record.sessions ?? [], retainedAt: Date()))
    }

    /// Drops `removed` from the list and puts back `left` (folders still on disk, marked superseded).
    func forgetRetained(_ removed: [RetainedWorktree], keeping left: [RetainedWorktree]) {
        guard !removed.isEmpty || !left.isEmpty else { return }
        let removedDirectories = Set(removed.map(\.location))
        var entries = retainedWorktrees.filter { !removedDirectories.contains($0.location) }
        for entry in left where !entries.contains(where: { $0.location == entry.location }) {
            entries.append(entry)
        }
        setRetained(entries)
    }

    private func setRetained(_ entries: [RetainedWorktree]) {
        retainedWorktrees = entries
        do {
            try retainedStore.save(entries)
        } catch {
            AppLog.write("Retained worktrees: couldn't save: \(error)")
        }
    }

    /// The PRs that left the list: GitHub says whether they were merged or closed (spec T.3.1), at most hourly per PR.
    func pruneRetainedWorktrees(_ snapshot: Snapshot) {
        guard retainedPrune == nil else { return }
        let now = Date()
        let due = RetainedWorktreeRules.needsStateCheck(retainedWorktrees, listed: Set(snapshot.items.map(\.id)),
                                                        fetchedScopes: snapshot.fetchedScopes, checkedAt: retainedCheckedAt, now: now)
        guard !due.isEmpty else { return }
        for entry in due { retainedCheckedAt[entry.prID] = now }
        let api = self.api
        let tokens = self.accounts
        let cleaner = retainedCleaner()
        retainedPrune = Task { [weak self] in
            var states: [String: PRDetails.State] = [:]
            var asked: Set<String> = []   // Once per PR in a pass, also when it failed (asked again in an hour).
            for entry in due where asked.insert(entry.prID).inserted {
                do {
                    let token = try await tokens.token(for: entry.account)
                    let details = try await api.pullRequestDetails(repo: entry.repo, number: entry.number, token: token)
                    if let state = details.state {
                        states[entry.prID] = state
                    } else {
                        AppLog.write("Retained worktrees: GitHub didn’t say whether \(entry.prID) is open; its folder stays.")
                    }
                } catch {
                    AppLog.write("Retained worktrees: couldn’t check \(entry.prID) on GitHub; its folder stays: \(error.localizedDescription)")
                }
            }
            let closed = RetainedWorktreeRules.closedOnes(due, states: states)
            let left = await cleaner.removeUnlessBusy(closed)
            self?.forgetRetained(closed, keeping: left)
            self?.retainedPrune = nil
        }
    }

    /// At launch: superseded folders whose process ended (and whose work was pushed) go now.
    func retrySupersededRetained() {
        let superseded = retainedWorktrees.filter(\.superseded)
        guard !superseded.isEmpty else { return }
        let cleaner = retainedCleaner()
        Task { [weak self] in
            let left = await cleaner.removeUnlessBusy(superseded)
            self?.forgetRetained(superseded, keeping: left)
        }
    }

    /// `lsof` on this Mac or on the runner; removal with the same mechanism as each job's own cleanup (which only
    /// touches PRBar's folders: inside its worktree root, a Respond worktree name, the runner's root).
    func retainedCleaner() -> RetainedWorktreeCleaner {
        let runner = self.runner
        let git = tools.git
        let runners = self.runners
        let settings = configStore.config.runners
        return RetainedWorktreeCleaner(
            isBusy: { location in
                guard let name = location.runner else {
                    // Can't tell (no lsof, no output): busy, so the folder stays.
                    guard let output = await Self.localLsofOutput(runner) else { return true }
                    return ProcessCwd.anyInside([location.directory, CanonicalPath.of(location.directory)], lsofOutput: output)
                }
                guard let destination = settings.destination(named: name),
                      let placement = try? await runners.placement(for: destination),
                      let script = try? ProcessCwd.remoteScript(resolving: [location.directory]),
                      let result = try? await placement.host.runScript(script, timeout: 30),
                      result.status == 0 else { return true }
                return ProcessCwd.anyInside([location.directory], remoteOutput: result.stdout)
            },
            // Never lose work (T.3): a folder with uncommitted changes or unpushed commits stays, `superseded`, for
            // Clean Up (which skips it while the work is there). Diff-only folders aren't git worktrees.
            unpushedWork: { location in
                guard location.repository != nil else { return nil }
                guard let name = location.runner else {
                    guard let git else { return "couldn't be checked with git" }
                    return await WorktreeResolver(runner: runner, gitPath: git).unpushedWork(location.directory)
                }
                guard let destination = settings.destination(named: name),
                      let placement = try? await runners.placement(for: destination) else { return "\(name) isn’t reachable" }
                return await placement.workspaces.unpushedWork(location.directory)
            },
            // `true` only if the folder is gone afterwards: the cleanups never throw and refuse quietly (outside the root,
            // Claude maybe still running on the runner, git failing), so the result is checked on disk.
            remove: { entry in
                let location = entry.location
                if let name = location.runner {
                    guard let destination = settings.destination(named: name),
                          let placement = try? await runners.placement(for: destination) else {
                        AppLog.write("Retained worktree: \(name) isn’t reachable; \(location.directory) stays on it.")
                        return false
                    }
                    switch entry.job {
                    case .review: await placement.workspaces.cleanup(location.reviewWorkspace, localPath: location.repository)
                    case .respond: await placement.workspaces.cleanupRespond(location.respondWorktree)
                    }
                    guard let quoted = try? ShellQuote.posix(location.directory),
                          let result = try? await placement.host.runScript("[ -e \(quoted) ] || [ -L \(quoted) ]", timeout: 30) else {
                        return false
                    }
                    return result.status == 1
                }
                guard let git else { return false }
                switch entry.job {
                case .review:
                    await WorktreeManager(runner: runner, gitPath: git).cleanup(location.reviewWorkspace, localPath: location.repository)
                case .respond:
                    await WorktreeResolver(runner: runner, gitPath: git).cleanup(location.respondWorktree)
                }
                var info = stat()
                return lstat(location.directory, &info) != 0 && errno == ENOENT
            },
            // A runner removed from Settings: PRBar no longer manages that machine, so its entries are dropped.
            isManaged: { location in location.runner.map { settings.destination(named: $0) != nil } ?? true })
    }

    /// `lsof -d cwd` on this Mac; nil if it can't tell (then the folders count as busy).
    nonisolated static func localLsofOutput(_ runner: ProcessRunning) async -> String? {
        guard let result = try? await runner.run(ProcessCwd.lsofPath, ProcessCwd.lsofArguments, environment: nil,
                                                 currentDirectory: nil, timeout: 30),
              result.status == 0 || !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    // MARK: Sessions (spec T.1, T.4)

    /// What the PR's Terminal button offers.
    func offeredSessions(prID: String) -> [ClaudeSessionRef] {
        SessionOffer.offered(prID: prID, retained: retainedWorktrees)
    }

    /// PRBar is running something in that folder (a job, its tests or a chat turn): the button waits. A kept folder
    /// isn't busy for having been used: the job released it (`WorkspaceRegistry`) and its record is finished.
    func isSessionBusy(_ session: ClaudeSessionRef) -> Bool {
        if session.runner == nil, WorkspaceRegistry.shared.contains(session.directory) { return true }
        guard let record = respond.records.values.first(where: {
            $0.draft.worktree.path == session.directory && $0.draft.runner == session.runner
        }) else { return false }
        let prID = record.draft.prID
        return respond.phases[prID]?.isActive == true || respond.chatting.contains(prID) || respond.runningTests.contains(prID)
    }

    /// Opens `session` in Settings › General's terminal. Throws `CommandFailure` or `TerminalLaunchError`.
    func openClaudeSession(_ session: ClaudeSessionRef) async throws {
        guard !isSessionBusy(session) else {
            throw CommandFailure(.invalidState, "Claude is working on it: PRBar is running something in \(session.directory).")
        }
        let config = configStore.config
        guard TerminalApps.isInstalled(config.terminal) else { throw TerminalLaunchError.notInstalled(config.terminal.displayName) }
        let request = try await terminalRequest(for: session)
        try await TerminalOpener(runner: runner).open(request, choice: config.terminal, customCommand: config.terminalCommand)
    }

    private func terminalRequest(for session: ClaudeSessionRef) async throws -> TerminalRequest {
        let entry = retainedWorktrees.first { $0.sessions.contains(session) }
        let title = "\(entry?.prID ?? "PR") · \(session.label)"
        guard let runnerName = session.runner else {
            guard let claude = tools.claude else { throw PRBarError.toolNotFound("claude") }
            return TerminalRequest(command: try ClaudeSessionCommand.local(session: session, claudePath: claude),
                                   directory: session.directory, title: title)
        }
        guard let destination = configStore.config.runners.destination(named: runnerName) else {
            throw CommandFailure(.notFound, "The runner \(runnerName) isn’t set up any more (Settings › Claude › Run On).")
        }
        let placement = try await runners.placement(for: destination)
        let command = try ClaudeSessionCommand.remote(session: session, destination: destination, claudePath: placement.claudePath)
        // On this Mac, the repo's local folder: where the terminal starts and Orca's worktree (spec T.5).
        let localFolder = entry.flatMap { localPath(account: $0.account, repo: $0.repo) }
        return TerminalRequest(command: command, directory: localFolder, title: title)
    }

    /// The buttons and the menu item: errors in an alert with "Open Settings" (spec T.5).
    func openClaudeSessionFromUI(_ session: ClaudeSessionRef) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await openClaudeSession(session)
            } catch {
                let tab = SessionOffer.settingsTab(for: error, onRunner: session.runner != nil)
                ConfirmAlert.present(title: "Couldn’t open Claude’s session", message: error.localizedDescription,
                                     action: "Open Settings") { [weak self] in
                    self?.openSettings(tab: tab)
                }
            }
        }
    }
}

// MARK: - SessionActions (CLI)

extension AppModel: SessionActions {
    func sessionList(pr: String) throws -> [ClaudeSessionInfo] {
        let sessions = offeredSessions(prID: try resolvePRID(pr))
        return SessionOffer.info(sessions, busy: busyIDs(sessions))
    }

    /// Exit 6 (`invalidState`) when there's none or PRBar is working in its folder; exit 1 with the terminal's error.
    func sessionOpen(pr: String, job: SessionJob?, run: Int?) async throws -> ClaudeSessionInfo {
        let sessions = offeredSessions(prID: try resolvePRID(pr))
        let session = try SessionOffer.pick(sessions, job: job, run: run)
        // Its row of `session list`, taken before opening: the list may change while the terminal opens.
        guard let info = SessionOffer.info(sessions, busy: busyIDs(sessions)).first(where: { $0.sessionID == session.id }) else {
            throw CommandFailure(.failed, "The session isn’t listed any more. See prbar session list.")
        }
        do {
            try await openClaudeSession(session)
        } catch let failure as CommandFailure {
            throw failure
        } catch {
            throw CommandFailure(.failed, error.localizedDescription)
        }
        return info
    }

    private func busyIDs(_ sessions: [ClaudeSessionRef]) -> Set<String> {
        Set(sessions.filter { isSessionBusy($0) }.map(\.id))
    }
}
