import Foundation

/// Trae a la Mac los commits de un fix remoto, los verifica y pushea desde la Mac (decisión J.7.9). Lo que vuelve del
/// host no es de confianza: el diff que ve el usuario se calcula acá desde los objetos traídos, y antes del push se
/// verifica que nada cambió (ni la ref local, ni su árbol, ni el diff, ni el HEAD remoto).
public struct RemoteFixImport: Sendable {
    let spaces: RemoteWorkspaces
    let localGit: String
    let localRunner: FileIOProcessRunning & ProcessRunning
    let gitEnvironment: [String: String]
    let tempRoot: URL
    let originURL: @Sendable (RepoRef) -> String
    let originMatches: @Sendable (String, RepoRef) -> Bool
    /// Tope del bundle de un fix (lo que se baja del host).
    let maxBundleBytes: Int

    public init(spaces: RemoteWorkspaces, localGit: String, localRunner: FileIOProcessRunning & ProcessRunning = SystemProcessRunner(),
                gitEnvironment: [String: String] = [:],
                tempRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("PRBar/push", isDirectory: true),
                originURL: @escaping @Sendable (RepoRef) -> String = { "https://github.com/\($0.fullName).git" },
                originMatches: @escaping @Sendable (String, RepoRef) -> Bool = { WorktreeResolver.originMatches($0, repo: $1) },
                maxBundleBytes: Int = 200 * 1024 * 1024) {
        self.spaces = spaces
        self.localGit = localGit
        self.localRunner = localRunner
        self.gitEnvironment = gitEnvironment.merging(GitHardening.environment) { _, forced in forced }
        self.tempRoot = tempRoot
        self.originURL = originURL
        self.originMatches = originMatches
        self.maxBundleBytes = maxBundleBytes
    }

    static func ref(_ draft: RespondDraft) -> String { "refs/prbar/remote-\(draft.number)-\(draft.id.uuidString.lowercased().prefix(8))" }

    // MARK: Git local

    @discardableResult
    func local(_ repository: String, _ arguments: [String], config: [String] = [], environment extra: [String: String] = [:],
               hardened: Bool = true, timeout: TimeInterval = WorktreeManager.slowTimeout) async throws -> String {
        let args = ["-C", repository] + (hardened ? GitHardening.arguments : []) + config + arguments
        let result = try await localRunner.run(localGit, args, environment: gitEnvironment.merging(extra) { _, new in new },
                                               currentDirectory: nil, timeout: timeout)
        guard result.status == 0 else {
            throw PRBarError.commandFailed(command: (["git"] + arguments.prefix(2)).joined(separator: " "), status: result.status,
                                           stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    /// El token de la cuenta para el clone temporal (decisión 4): ni en los argumentos ni en el entorno (`ps` los
    /// muestra). Va en un archivo de `credential-store` 0600, en una carpeta 0700 propia, que se borra al terminar;
    /// `credential.helper=` vacío descarta los helpers del usuario.
    public struct CredentialFile: Sendable {
        public let path: String

        public init(token: String, in base: URL) throws {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let directory = base.appendingPathComponent(".credentials-\(UUID().uuidString.lowercased())").path
            guard mkdir(directory, 0o700) == 0, chmod(directory, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
            let file = directory + "/credentials"
            let fd = open(file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else {
                rmdir(directory)
                throw CocoaError(.fileWriteUnknown)
            }
            defer { close(fd) }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let line = Array("https://x-access-token:\(encoded)@github.com\n".utf8)
            guard !encoded.isEmpty, write(fd, line, line.count) == line.count else {
                unlink(file)
                rmdir(directory)
                throw CocoaError(.fileWriteUnknown)
            }
            path = file
        }

        /// Antes del subcomando de git. La ruta va con comillas: git corre el helper con el shell.
        public var arguments: [String] {
            ["-c", "credential.helper=", "-c", "credential.helper=store --file=" + ((try? ShellQuote.posix(path)) ?? "/dev/null")]
        }

        public func remove() {
            unlink(path)
            rmdir((path as NSString).deletingLastPathComponent)
        }
    }

    /// Corre `body` con los argumentos de `CredentialFile` si hay token (y solo en el clone temporal); lo borra después.
    @discardableResult
    func withCredentials<T>(_ token: String?, temporary: Bool, _ body: ([String]) async throws -> T) async throws -> T {
        guard temporary, let token, !token.isEmpty else { return try await body([]) }
        let file = try CredentialFile(token: token, in: tempRoot)
        defer { file.remove() }
        return try await body(file.arguments)
    }

    // MARK: Import

    /// Bundle remoto → Mac → verificación → `refs/prbar/remote-…` → resumen calculado en la Mac.
    public func importFixes(draft: RespondDraft, localPath: String?, items: [ItemResult], integrity: String?,
                            token: String? = nil) async throws -> RespondResult {
        let worktree = draft.worktree.path
        guard spaces.root.isRemovable(worktree), FixImplementer.isFullSHA(draft.startHeadOid) else {
            throw RemoteRunnerError.importMismatch("the worktree or its base isn’t PRBar’s.")
        }
        let remoteHead = try await spaces.git(worktree, ["rev-parse", "--verify", "HEAD^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard FixImplementer.isFullSHA(remoteHead) else { throw RemoteRunnerError.malformedOutput(host: spaces.host.name, what: "HEAD") }

        // El repo local: el clone del usuario (verificando su origin) o uno temporal mínimo.
        let (repository, temporary, created) = try await localRepository(draft: draft, localPath: localPath)
        do {
            if (try? await local(repository, ["cat-file", "-e", "\(draft.startHeadOid)^{commit}"])) == nil {
                // `--depth=1` solo en el clone temporal: en el del usuario lo volvería shallow.
                try await withCredentials(token, temporary: temporary) { credentials in
                    try await local(repository, ["fetch", "--no-write-fetch-head", "--no-tags"] + (temporary ? ["--depth=1"] : [])
                                        + ["origin", draft.startHeadOid], config: credentials)
                }
            }
            // Resolve Conflicts (decisión C.9.11): la base se trae aparte, desde GitHub, y queda fuera del bundle (que no
            // viaje todo lo que trajo la base). `bundle verify` exige que sus prerequisitos ya estén en el clone.
            if let base = draft.conflicts?.baseOid {
                guard FixImplementer.isFullSHA(base) else { throw RemoteRunnerError.importMismatch("the merged base isn’t a commit id.") }
                if (try? await local(repository, ["cat-file", "-e", "\(base)^{commit}"])) == nil {
                    try await withCredentials(token, temporary: temporary) { credentials in
                        try await local(repository, ["fetch", "--no-write-fetch-head", "--no-tags"] + (temporary ? ["--depth=1"] : [])
                                            + ["origin", base], config: credentials)
                    }
                }
            }
            guard remoteHead != draft.startHeadOid else {
                try await local(repository, ["update-ref", Self.ref(draft), remoteHead])
                return try await summary(draft: draft, repository: repository, temporary: temporary, head: remoteHead, items: items, integrity: integrity)
            }
            let remoteBundle = try spaces.root.child(["tmp", "\(draft.id.uuidString.lowercased()).bundle"])
            let exclusions = ["^\(draft.startHeadOid)"] + (draft.conflicts.map { ["^\($0.baseOid)"] } ?? [])
            try await spaces.git(worktree, ["bundle", "create", remoteBundle, "HEAD"] + exclusions)
            let bundle = try LocalScratch.newFile()
            defer { try? FileManager.default.removeItem(at: bundle) }
            do {
                // El tamaño antes de bajarlo (y de nuevo después: el host puede mentir).
                let quoted = try ShellQuote.posix(remoteBundle)
                let sized = try spaces.host.checked(try await spaces.host.runScript("[ -f \(quoted) ] && wc -c < \(quoted)", timeout: 30), "wc")
                guard let size = Int(sized.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw RemoteRunnerError.malformedOutput(host: spaces.host.name, what: "file size")
                }
                guard size <= maxBundleBytes else { throw tooBig(size) }
                try await spaces.host.download(remoteBundle, to: bundle, root: spaces.root)
            } catch {
                await spaces.host.removeFiles([remoteBundle], root: spaces.root)
                throw error
            }
            await spaces.host.removeFiles([remoteBundle], root: spaces.root)
            let downloaded = (try? FileManager.default.attributesOfItem(atPath: bundle.path)[.size] as? Int) ?? Int.max
            guard downloaded <= maxBundleBytes else { throw tooBig(downloaded) }

            try await local(repository, ["bundle", "verify", "-q", bundle.path])
            let heads = try await local(repository, ["bundle", "list-heads", bundle.path])
                .split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
            guard heads.count == 1, heads[0].first == remoteHead else {
                throw RemoteRunnerError.importMismatch("the bundle’s commit isn’t the server’s HEAD.")
            }
            // `fetch` del bundle (y no `bundle unbundle`) para que git revise cada objeto (fsck) antes de guardarlo
            // en el clone; uno corrupto o malicioso corta sin dejar nada.
            // `+`: la ref propia también vuelve atrás (deshacer un turno del chat); se verifica justo después.
            try await local(repository, ["fetch", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", bundle.path,
                                         "+\(remoteHead):\(Self.ref(draft))"],
                            config: ["-c", "transfer.fsckObjects=true", "-c", "fetch.fsckObjects=true"])
            let fetched = try await local(repository, ["rev-parse", "--verify", "\(Self.ref(draft))^{commit}"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard fetched == remoteHead else { throw RemoteRunnerError.importMismatch("the bundle’s commit isn’t the server’s HEAD.") }
            return try await summary(draft: draft, repository: repository, temporary: temporary, head: remoteHead, items: items, integrity: integrity)
        } catch {
            if created {
                try? FileManager.default.removeItem(atPath: repository)
                WorkspaceRegistry.shared.remove(repository)
            }
            throw error
        }
    }

    private func tooBig(_ bytes: Int) -> Error {
        RemoteRunnerError.importMismatch("the fixes are too big to bring back (\(bytes / 1_048_576) MB, the limit is \(maxBundleBytes / 1_048_576) MB).")
    }

    /// El repo, si es el clone temporal y si se creó recién (solo ese se borra si el import falla).
    private func localRepository(draft: RespondDraft, localPath: String?) async throws -> (String, Bool, Bool) {
        if let localPath {
            let url = try await local(localPath, ["remote", "get-url", "origin"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard originMatches(url, draft.repo) else {
                throw PRBarError.respond("The origin remote of \(localPath) is \(url), not github.com/\(draft.repo.fullName): not using it.")
            }
            return (localPath, false, false)
        }
        let path = temporaryClonePath(draft)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Ocupa disco de la Mac mientras dura la corrida: Clean Up no lo toca (spec I).
        WorkspaceRegistry.shared.insert(path)
        if FileManager.default.fileExists(atPath: path + "/objects") {
            // Un import anterior de la misma corrida (otro turno del chat): se reusa.
            return (path, true, false)
        }
        let initialized = try await localRunner.run(localGit, ["init", "--bare", "-q", path], environment: gitEnvironment,
                                                    currentDirectory: nil, timeout: 60)
        do {
            guard initialized.status == 0 else { throw PRBarError.respond("Couldn’t create a temporary clone to push from.") }
            try await local(path, ["remote", "add", "origin", originURL(draft.repo)])
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            WorkspaceRegistry.shared.remove(path)
            throw error
        }
        return (path, true, true)
    }

    private func summary(draft: RespondDraft, repository: String, temporary: Bool, head: String,
                         items: [ItemResult], integrity: String?) async throws -> RespondResult {
        guard (try? await local(repository, ["merge-base", "--is-ancestor", draft.startHeadOid, head])) != nil else {
            throw RemoteRunnerError.importMismatch("\(head.prefix(12)) doesn’t descend from \(draft.startHeadOid.prefix(12)).")
        }
        if let conflicts = draft.conflicts {
            guard (try? await local(repository, ["merge-base", "--is-ancestor", conflicts.baseOid, head])) != nil else {
                throw RemoteRunnerError.importMismatch("\(head.prefix(12)) doesn’t contain \(conflicts.baseRef).")
            }
        }
        let tree = try await local(repository, ["rev-parse", "--verify", "\(head)^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = try await FixImplementer.summarize(repository: URL(fileURLWithPath: repository), start: draft.startHeadOid, head: head,
                                                        items: items, integrity: integrity, conflicts: draft.conflicts) { _, arguments in
            try await self.local(repository, arguments)
        }
        result.remoteObjects = RemoteObjects(repoPath: repository, temporary: temporary, ref: Self.ref(draft), treeOid: tree)
        return result
    }

    // MARK: Push

    /// Verifica todo de nuevo y pushea `<sha>:refs/heads/<rama>` desde la Mac (decisión J.7.9).
    public func push(draft: RespondDraft, result: RespondResult, token: String?) async throws {
        try await pushReviewed(draft: draft, result: result, token: token)
        if let reviewed = result.headOid { await spaces.markPushed(draft.worktree, sha: reviewed) }
    }

    private func pushReviewed(draft: RespondDraft, result: RespondResult, token: String?) async throws {
        guard let objects = result.remoteObjects, let reviewed = result.headOid, FixImplementer.isFullSHA(reviewed) else {
            throw PRBarError.respond("This result can’t be pushed. Analyze the PR again.")
        }
        let repository = objects.repoPath
        func mismatch(_ detail: String) -> Error { RemoteRunnerError.importMismatch(detail) }
        let resolver = WorktreeResolver(runner: localRunner, gitPath: localGit, environment: gitEnvironment, originMatches: originMatches)
        try await resolver.validateBranchName(draft.headRef)
        let atRef = try await local(repository, ["rev-parse", "--verify", "\(objects.ref)^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard atRef == reviewed else { throw mismatch("the local copy moved to \(atRef.prefix(12)).") }
        let tree = try await local(repository, ["rev-parse", "--verify", "\(reviewed)^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard tree == objects.treeOid else { throw mismatch("the tree isn’t the one that was imported.") }
        // El mismo diff que se revisó: el combined del merge en Resolve Conflicts (C.9.11), `start..reviewed` si no.
        let fullDiff: String
        let specialPaths: [String]
        let raw = try await local(repository, ["diff", "--raw", "-z", "--no-renames", "--no-abbrev", "\(draft.startHeadOid)..\(reviewed)"])
        if let conflicts = draft.conflicts {
            // El combined diff más los cambios fuera de los conflictos (decisión C.9.16), calculados acá otra vez.
            let review = try await FixImplementer.mergeReview(repository: URL(fileURLWithPath: repository), start: draft.startHeadOid,
                                                              head: reviewed, context: conflicts) { _, arguments in
                try await self.local(repository, arguments)
            }
            fullDiff = review.diff
            guard review.oneSided.map(\.resolution) == (result.oneSidedResolutions ?? []) else {
                throw mismatch("the files resolved with one side aren’t the ones you reviewed.")
            }
            let reviewedPaths = Set(review.paths)
            specialPaths = WorktreeIntegrity.specialStagedPaths(fromRawZ: raw).filter(reviewedPaths.contains)
            guard (try? await local(repository, ["merge-base", "--is-ancestor", conflicts.baseOid, reviewed])) != nil else {
                throw mismatch("\(reviewed.prefix(12)) doesn’t contain \(conflicts.baseRef).")
            }
        } else {
            fullDiff = try await local(repository, ["diff", GitHardening.ignoreSubmodules, "--text", "--no-textconv", "--no-ext-diff",
                                                    "--no-color", "\(draft.startHeadOid)..\(reviewed)"])
            specialPaths = WorktreeIntegrity.specialStagedPaths(fromRawZ: raw)
        }
        let (diff, truncated) = FixImplementer.capDiff(fullDiff)
        guard diff == result.diff, truncated == (result.diffTruncated ?? false) else { throw mismatch("the diff isn’t the one you reviewed.") }
        guard specialPaths.isEmpty else { throw mismatch("it adds a symlink or a nested repo.") }
        guard (try? await local(repository, ["merge-base", "--is-ancestor", draft.startHeadOid, reviewed])) != nil else {
            throw mismatch("\(reviewed.prefix(12)) doesn’t descend from \(draft.startHeadOid.prefix(12)).")
        }
        let remoteHead = try await spaces.git(draft.worktree.path, ["rev-parse", "--verify", "HEAD^{commit}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard remoteHead == reviewed else { throw mismatch("the server’s worktree is now at \(remoteHead.prefix(12)).") }

        // El clone puede haber cambiado desde el import: cada URL de fetch y de push (con `pushurl` y
        // `pushInsteadOf` ya aplicados) tiene que ser la del repo.
        let fetchURLs = try await local(repository, ["remote", "get-url", "--all", "origin"])
        let pushURLs = try await local(repository, ["remote", "get-url", "--push", "--all", "origin"])
        let urls = (fetchURLs + "\n" + pushURLs).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if urls.isEmpty || urls.contains(where: { !originMatches($0, draft.repo) }) {
            throw PRBarError.respond("The origin remote of \(repository) no longer points only to github.com/\(draft.repo.fullName) "
                                     + "(\(urls.joined(separator: ", "))): not pushing.")
        }
        let localRunner = self.localRunner, localGit = self.localGit, gitEnvironment = self.gitEnvironment
        let pushed = try await withCredentials(token, temporary: objects.temporary) { credentials -> ProcessResult? in
            // Un push anterior que se cortó tarde (o este, cortado) ya dejó la rama en lo revisado (M6).
            let alreadyPushed: @Sendable () async -> Bool = {
                await Task.detached {
                    let args = ["-C", repository] + GitHardening.arguments + credentials
                        + RespondPublisher.lsRemoteArguments(headRef: draft.headRef)
                    guard let result = try? await localRunner.run(localGit, args, environment: gitEnvironment, currentDirectory: nil,
                                                                  timeout: ProcessTimeouts.standard), result.status == 0 else { return false }
                    return RespondPublisher.remoteHead(fromLsRemote: result.stdout, headRef: draft.headRef) == reviewed
                }.value
            }
            let args = ["-C", repository] + RespondPublisher.pushHardening + credentials
                + RespondPublisher.pushArguments(reviewed: reviewed, headRef: draft.headRef, startHeadOid: draft.startHeadOid)
            let result: ProcessResult
            do {
                result = try await localRunner.run(localGit, args, environment: gitEnvironment, currentDirectory: nil,
                                                   timeout: RespondPublisher.pushTimeout)
            } catch {
                if await alreadyPushed() { return nil }
                throw error
            }
            if result.status != 0, await alreadyPushed() { return nil }
            return result
        }
        guard let pushed else { return }
        guard pushed.status == 0 else {
            let stderr = [pushed.stderr, pushed.stdout].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            throw PRBarError.respond(RespondPublisher.pushFailureMessage(stderr: Redactor.redact(stderr, secrets: [token].compactMap { $0 })))
        }
    }

    func temporaryClonePath(_ draft: RespondDraft) -> String {
        tempRoot.appendingPathComponent(draft.id.uuidString.lowercased()).path
    }

    /// Lo mismo que `discard(_:)` sin el resultado (al descartar una corrida): la ref de la corrida en el clone del
    /// usuario y el clone temporal. Nunca lanza.
    public func discard(draft: RespondDraft) async {
        if let localPath = draft.localPath {
            _ = try? await local(localPath, ["update-ref", "-d", Self.ref(draft)])
        }
        let temporary = temporaryClonePath(draft)
        await discard(RespondResult(items: [], diffStat: "", tests: nil,
                                    remoteObjects: RemoteObjects(repoPath: temporary, temporary: true, ref: Self.ref(draft), treeOid: "")))
    }

    /// Borra la ref local (y el clone temporal). Nunca lanza.
    public func discard(_ result: RespondResult) async {
        guard let objects = result.remoteObjects else { return }
        if objects.temporary {
            // Solo un clone de `localRepository`: `<tempRoot>/<uuid>` (el resultado viene de disco y pudo cambiar).
            let url = URL(fileURLWithPath: objects.repoPath).standardizedFileURL
            let name = url.lastPathComponent
            guard url.deletingLastPathComponent().standardizedFileURL.path == tempRoot.standardizedFileURL.path,
                  RemoteInstallation.isValidID(name) else {
                AppLog.write("Remote fixes: not deleting \(objects.repoPath): it isn’t one of PRBar’s temporary clones.")
                return
            }
            try? FileManager.default.removeItem(at: url)
            WorkspaceRegistry.shared.remove(url.path)
        } else if objects.ref.hasPrefix("refs/prbar/remote-") {
            _ = try? await local(objects.repoPath, ["update-ref", "-d", objects.ref])
        }
    }
}
