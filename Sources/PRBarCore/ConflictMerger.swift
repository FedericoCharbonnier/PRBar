import Foundation

/// Corre en el worktree de PRBar el merge de la base del PR (spec C.3.2) y junta el contexto para Claude. Todo git va
/// por `run` (endurecido, con `GitHardening.environment`, en esta Mac o en el host); nunca corre código del repo: el
/// merge no tiene hooks (`core.hooksPath=/dev/null`) ni commitea, y `rerere` está apagado (decisión C.9.14).
struct ConflictMerger: Sendable {
    /// git en el worktree; devuelve el resultado sin mirar el código de salida.
    let run: @Sendable ([String]) async throws -> ProcessResult

    static let maxContentFiles = 50
    static let maxDiffLines = 3_000
    static let maxDiffBytes = 200_000
    static let mergeConfig = ["-c", "merge.conflictStyle=merge", "-c", "rerere.enabled=false"]

    struct Outcome: Sendable {
        let context: ConflictsContext
        let incomingLog: String
        let prDiff: String
        let prDiffTruncated: Bool
    }

    func merge(baseRef: String, baseOid: String, startHeadOid: String) async throws -> Outcome {
        if try await run(["merge-base", "--is-ancestor", baseOid, startHeadOid]).status == 0 {
            throw PRBarError.respond(RespondPipeline.alreadyContainsBaseMessage)
        }
        let mergeBase = try await output(["merge-base", startHeadOid, baseOid]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard FixImplementer.isFullSHA(mergeBase) else {
            throw PRBarError.respond("The PR and \(baseRef) have no common history: PRBar can’t merge them.")
        }
        let merged = try await run(Self.mergeConfig + ["merge", "--no-ff", "--no-commit", "-q", baseOid])
        let unmerged = ConflictClassifier.entries(fromLsFilesUZ: try await output(["ls-files", "-u", "-z"]))
        // 0: sin conflictos; 1: con conflictos. Un 1 sin entradas en conflicto (o cualquier otro código) es que git no pudo.
        guard merged.status == 0 || (merged.status == 1 && !unmerged.isEmpty) else {
            throw PRBarError.commandFailed(command: "git merge", status: merged.status,
                                           stderr: merged.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var binary = Set<String>()
        for candidate in ConflictClassifier.contentCandidates(unmerged) {
            let numstat = try await output(["diff", "--numstat", "--no-ext-diff", "--no-textconv", candidate.ours, candidate.theirs])
            if ConflictClassifier.isBinaryNumstat(numstat) { binary.insert(candidate.path) }
        }
        let files = ConflictClassifier.classify(unmerged, binary: binary)
        let content = files.filter { $0.kind == .content }
        if !files.isEmpty && content.isEmpty {
            let names = CILogs.nameList(files.map { UntrustedText.singleLine($0.path) })
            throw PRBarError.respond("Only conflicts PRBar can’t give to Claude (\(names)): resolve them by hand. Nothing was changed.")
        }
        if content.count > Self.maxContentFiles {
            throw PRBarError.respond("Too many files with conflicts (\(content.count)) for one run: resolve them by hand.")
        }
        try await keepPRVersion(files.filter { $0.kind == .byHand }, entries: unmerged)
        // Decisión C.9.16: lo que dejó el merge automático fuera de los conflictos, antes de que Claude toque nada.
        let automatic = OutsideConflicts.record(fromDiffIndex: try await output(
            ["diff-index", "--cached", "--raw", "-z", "--no-renames", "--no-abbrev", "--ignore-submodules=none", startHeadOid]))
        let count = Int(try await output(["rev-list", "--count", "\(mergeBase)..\(baseOid)"])
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let log = try await output(["log", "--no-decorate", "--no-color", "--format=%h %s", "-n", "\(ConflictsItem.maxIncomingCommits)",
                                    "\(mergeBase)..\(baseOid)"])
        let diff = try await output(["diff", GitHardening.ignoreSubmodules, "--text", "--no-textconv", "--no-ext-diff", "--no-color",
                                     mergeBase, startHeadOid])
        let (capped, truncated) = Self.cap(diff)
        return Outcome(context: ConflictsContext(baseRef: baseRef, baseOid: baseOid, mergeBase: mergeBase, files: files,
                                                 incomingCommits: count, automaticMerge: automatic),
                       incomingLog: log, prDiff: capped, prDiffTruncated: truncated)
    }

    /// Decisión C.9.3: la versión del PR (etapa 2) queda en el índice y en el árbol; si el PR no tiene el archivo, sale.
    /// Un submódulo solo cambia en el índice (su carpeta no se toca). `update-index --cacheinfo` deja la ruta en la
    /// etapa 0 (borra las etapas 1–3), así que el `checkout` ya no la ve en conflicto.
    private func keepPRVersion(_ files: [ConflictFile], entries: [IndexStageEntry]) async throws {
        for file in files {
            let stages = entries.filter { $0.path == file.path }
            if let ours = stages.first(where: { $0.stage == 2 }) {
                try await output(["update-index", "--cacheinfo", "\(ours.mode),\(ours.sha),\(file.path)"])
                if ours.mode != "160000" { try await output(["checkout", "-q", "--", file.path]) }
            } else {
                try await output(["rm", "-q", "--cached", "--", file.path])
                try await output(["clean", "-q", "-f", "--", file.path])
            }
        }
    }

    static func cap(_ text: String) -> (String, Bool) {
        var lines = TextLines.split(text, strippingCarriageReturns: false)
        var truncated = false
        if lines.count > maxDiffLines { lines = Array(lines.prefix(maxDiffLines)); truncated = true }
        var result = lines.joined(separator: "\n")
        if result.utf8.count > maxDiffBytes {
            result = String(decoding: Array(result.utf8.prefix(maxDiffBytes)), as: UTF8.self)
            truncated = true
        }
        return (result, truncated)
    }

    @discardableResult
    private func output(_ arguments: [String]) async throws -> String {
        let result = try await run(arguments)
        guard result.status == 0 else {
            throw PRBarError.commandFailed(command: (["git"] + arguments.prefix(2)).joined(separator: " "), status: result.status,
                                           stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }
}
