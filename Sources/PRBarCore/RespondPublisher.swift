import Foundation

/// Una respuesta ya publicada en GitHub. `id` es el del ítem (`thread:<id>` | `review:<id>`).
public struct PostedReply: Codable, Equatable, Sendable {
    public let id: String
    public let url: URL

    public init(id: String, url: URL) {
        self.id = id
        self.url = url
    }
}

/// Última etapa de "Responder": pushea los fixes y contesta en cada hilo.
///
/// - Se pushea **el sha que vio el usuario** (`RespondResult.headOid`), nunca `HEAD` ni una rama:
///   `git push origin <sha>:refs/heads/<headRef>`. Justo antes se vuelve a verificar todo, en este orden y sin
///   correr git hasta el segundo paso: que no haya ningún `.git` anidado; que la config, los hooks y los `.git`
///   no hayan cambiado desde los fixes (`gitIntegrity`); que ninguna config de git venga de dentro del worktree;
///   que `origin` sea el repo del PR; que HEAD siga siendo ese sha; y que descienda de `startHeadOid`.
/// - El push corre **con los hooks del usuario** (pre-push), dentro del worktree de PRBar y sobre el código que
///   escribió Claude: solo después de que el usuario vio el diff completo y confirmó. Es el único `git` de
///   Responder sin `core.hooksPath=/dev/null` (sí lleva el resto de `GitHardening`). Nunca lleva `--force` ni
///   `--no-verify`, y git nunca pide credenciales (`GIT_TERMINAL_PROMPT=0`). El token de GitHub no se usa para
///   git: solo para la API.
/// - Las respuestas se publican de a una; cada una que sale bien se avisa con `onPosted` (para guardarla en el
///   registro en el acto) y nunca se vuelve a publicar si está en `alreadyPosted`.
public struct RespondPublisher: Sendable {
    public static let pushTimeout: TimeInterval = 120
    public static let rejectedMessage = "GitHub rejected the push: the branch moved ahead. Pull the changes and try again."
    static let maxQuoteLength = 200
    /// `GitHardening` sin `core.hooksPath`: el push corre los hooks del usuario.
    static let pushHardening = ["-c", "core.fsmonitor=false", "-c", "submodule.recurse=false", "-c", "core.untrackedCache=false"]

    private let runner: ProcessRunning
    private let gitPath: String
    private let api: GitHubAPI
    private let environment: [String: String]
    private let branches: WorktreeResolver

    /// `environment` se suma al de cada `git` (los tests lo usan para aislar la configuración global);
    /// `GIT_TERMINAL_PROMPT=0` siempre se mantiene. `originMatches`: ver `WorktreeResolver`.
    public init(runner: ProcessRunning, gitPath: String, api: GitHubAPI, environment: [String: String] = [:],
                originMatches: @escaping @Sendable (String, RepoRef) -> Bool = { WorktreeResolver.originMatches($0, repo: $1) }) {
        self.runner = runner
        self.gitPath = gitPath
        self.api = api
        self.environment = environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, forced in forced }
        self.branches = WorktreeResolver(runner: runner, gitPath: gitPath, environment: environment, originMatches: originMatches)
    }

    // MARK: - Push

    /// Ver la documentación del tipo. Si el remoto avanzó lanza `PRBarError.respond(rejectedMessage + stderr)`;
    /// cualquier otro rechazo (p. ej. un pre-push que falla) también es `.respond`, con el stderr.
    public func push(draft: RespondDraft, result: RespondResult) async throws {
        let headRef = draft.headRef
        try await branches.validateBranchName(headRef)
        guard draft.worktree.origin == .dedicated, let reviewed = result.headOid, FixImplementer.isFullSHA(reviewed),
              let integrity = result.gitIntegrity, FixImplementer.isFullSHA(draft.startHeadOid) else {
            throw PRBarError.respond("This result is from an older version of PRBar and can't be pushed. Analyze the PR again.")
        }
        let path = draft.worktree.path
        let worktree = URL(fileURLWithPath: path, isDirectory: true)

        try FixImplementer.checkNoNestedGit(worktree, allowed: [])
        guard try await self.integrity(of: worktree) == integrity else {
            throw PRBarError.respond(
                "The git configuration or hooks changed since the fixes were implemented. Not pushing: check \(path).")
        }
        try FixImplementer.checkConfigOrigins(try await git(path, ["config", "--list", "--show-origin", "-z"]), worktree: worktree)
        try await branches.verifyOrigin(path, repo: draft.repo)
        let head = try await git(path, ["rev-parse", "--verify", "HEAD^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == reviewed else {
            throw PRBarError.respond(
                "The worktree changed since you reviewed the diff (HEAD is \(head.prefix(12)), you reviewed \(reviewed.prefix(12))). Not pushing.")
        }
        let ancestor = try await run(["-C", path] + GitHardening.arguments + ["merge-base", "--is-ancestor", draft.startHeadOid, reviewed],
                                     timeout: ProcessTimeouts.standard)
        guard ancestor.status == 0 else {
            throw PRBarError.respond("\(reviewed.prefix(12)) doesn't descend from \(draft.startHeadOid), the base of the analysis. Not pushing.")
        }

        let pushed = try await run(["-C", path] + Self.pushHardening + ["push", "origin", "\(reviewed):refs/heads/\(headRef)"],
                                   timeout: Self.pushTimeout)
        guard pushed.status == 0 else {
            let stderr = [pushed.stderr, pushed.stdout].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            throw PRBarError.respond(Self.pushFailureMessage(stderr: stderr))
        }
    }

    /// La huella de git del worktree (`GitPaths.securityDigest`), como la deja `FixImplementer` en `gitIntegrity`.
    public func integrity(of worktree: URL) async throws -> String {
        let output = try await git(worktree.path, ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"])
        return try FixImplementer.GitPaths.parse(output, worktree: worktree).securityDigest()
    }

    /// "La rama avanzó" solo cuando git lo dice (non-fast-forward / fetch first); si no, el stderr tal cual
    /// (un hook que falló, credenciales, red).
    static func pushFailureMessage(stderr: String) -> String {
        let advanced = ["[rejected]", "non-fast-forward", "fetch first"].contains { stderr.contains($0) }
        let head = advanced ? rejectedMessage : "Couldn't push (if you have a pre-push hook, it may have stopped it)."
        return stderr.isEmpty ? head : "\(head)\n\n\(stderr)"
    }

    private func run(_ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await runner.run(gitPath, arguments, environment: environment, currentDirectory: nil, timeout: timeout)
    }

    /// git endurecido en `path`; lanza si sale con error.
    private func git(_ path: String, _ arguments: [String]) async throws -> String {
        let result = try await run(["-C", path] + GitHardening.arguments + arguments, timeout: ProcessTimeouts.standard)
        guard result.status == 0 else {
            throw PRBarError.commandFailed(command: (["git"] + arguments.prefix(2)).joined(separator: " "), status: result.status,
                                           stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    // MARK: - Respuestas

    /// Publica, en el orden de `draft.items`, las respuestas marcadas (`reply == true`) que todavía no están en
    /// `alreadyPosted` y tienen texto (ver `replyText`). Los hilos van con `replyToReviewComment`; los cuerpos de
    /// review, como comentario del PR con `@reviewer` y la cita de la primera línea de su comentario.
    /// Corta en el primer error. Devuelve `alreadyPosted` más las nuevas, y ese error (o nil). `onPosted` se
    /// llama (y se espera) después de cada publicación exitosa, antes de la siguiente.
    /// `result` es nil cuando no se implementó nada (solo respuestas).
    public func postReplies(draft: RespondDraft, selections: [String: RespondSelection], result: RespondResult?,
                            alreadyPosted: [String: PostedReply], token: String, replyTemplate: String? = nil,
                            onPosted: @escaping @Sendable (String, PostedReply) async -> Void = { _, _ in })
        async -> (posted: [String: PostedReply], error: Error?) {
        var posted = alreadyPosted
        for item in draft.items {
            guard let selection = selections[item.id], selection.reply, posted[item.id] == nil else { continue }
            let fix = result?.items.first { $0.id == item.id && $0.status == .committed }
            let values = FixTemplates.values(draft: draft, item: item, count: 1, summary: fix?.summary)
            guard let text = Self.replyText(selection: selection, commit: fix?.commit, repo: draft.repo, language: draft.language,
                                            template: replyTemplate, values: values) else {
                continue
            }
            do {
                let url: URL
                switch item.feedback.kind {
                case .thread:
                    guard let commentID = item.feedback.replyToCommentID else {
                        throw PRBarError.respond("Thread \(item.id) has no comment to reply to.")
                    }
                    url = try await api.replyToReviewComment(repo: draft.repo, number: draft.number, commentID: commentID,
                                                             body: text, token: token)
                case .reviewBody:
                    url = try await api.addIssueComment(repo: draft.repo, number: draft.number,
                                                        body: Self.reviewBodyReply(item.feedback, text: text), token: token)
                }
                let reply = PostedReply(id: item.id, url: url)
                posted[item.id] = reply
                await onPosted(item.id, reply)
            } catch {
                return (posted, error)
            }
        }
        return (posted, nil)
    }

    /// With a commit: "Fixed in https://github.com/<o>/<r>/commit/<sha>." in the PR's language
    /// (`PublishedPhrases.fixedIn`) or, with `template` (spec E.5), the template with `{commit}` (the link) and
    /// `values`; then, if there is text, a space and the text. Without a commit: the text, or nil if it's empty.
    public static func replyText(selection: RespondSelection, commit: String?, repo: RepoRef, language: PRLanguage,
                                 template: String? = nil, values: [String: String] = [:]) -> String? {
        let text = selection.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commit, !commit.isEmpty else { return text.isEmpty ? nil : text }
        let link = "https://github.com/\(repo.owner)/\(repo.name)/commit/\(commit)"
        var prefix = PublishedPhrases.fixedIn(link, language: language)
        if let template, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var all = values
            all["commit"] = link
            let rendered = PlaceholderTemplate.render(template, values: all).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rendered.isEmpty { prefix = rendered }
        }
        return text.isEmpty ? prefix : "\(prefix) \(text)"
    }

    /// `@reviewer`, la cita de la primera línea no vacía de su comentario (hasta 200 caracteres) y el texto.
    static func reviewBodyReply(_ feedback: FeedbackItem, text: String) -> String {
        let body = feedback.comments.first?.body ?? ""
        let firstLine = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let quote = firstLine.count > maxQuoteLength ? String(firstLine.prefix(maxQuoteLength)) + "…" : firstLine
        return PublishedPhrases.reviewBodyReply(reviewer: feedback.reviewer, quote: quote, text: text)
    }
}
