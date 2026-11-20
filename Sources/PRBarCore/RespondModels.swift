import Foundation

public struct FeedbackComment: Codable, Equatable, Sendable {
    public let databaseID: Int
    public let author: String
    public let isBot: Bool
    public let body: String
    public let createdAt: Date
    public let url: URL

    public init(databaseID: Int, author: String, isBot: Bool, body: String, createdAt: Date, url: URL) {
        self.databaseID = databaseID
        self.author = author
        self.isBot = isBot
        self.body = body
        self.createdAt = createdAt
        self.url = url
    }
}

public struct FeedbackItem: Codable, Equatable, Sendable, Identifiable {
    /// `ciChecks`: los checks fallidos de un Fix CI (spec K.6.2); sus "comentarios" son los checks.
    public enum Kind: String, Codable, Sendable { case thread, reviewBody, ciChecks }

    /// "thread:<nodeID>" | "review:<databaseID>" | "ci:<headOid>"
    public let id: String
    public let kind: Kind
    public let path: String?
    public let line: Int?
    public let isOutdated: Bool
    /// Solo para hilos: GitHub lo marca como resuelto. `FeedbackFilter` descarta esos hilos.
    public let isResolved: Bool
    /// Hilo completo, en orden; para `reviewBody`, uno solo.
    public let comments: [FeedbackComment]

    public init(id: String, kind: Kind, path: String?, line: Int?, isOutdated: Bool, isResolved: Bool = false, comments: [FeedbackComment]) {
        self.id = id
        self.kind = kind
        self.path = path
        self.line = line
        self.isOutdated = isOutdated
        self.isResolved = isResolved
        self.comments = comments
    }

    public var reviewer: String { comments.first?.author ?? "?" }
    /// Comentario al que se responde (el primero del hilo). Nil para reviewBody.
    public var replyToCommentID: Int? { kind == .thread ? comments.first?.databaseID : nil }
}

public enum FeedbackAction: String, Codable, Sendable { case fix, reply, fixAndReply, skip }

public struct RespondItem: Codable, Equatable, Sendable, Identifiable {
    public let feedback: FeedbackItem
    public let assessment: String
    public let action: FeedbackAction
    public let fixPlan: String
    public let reply: String

    public init(feedback: FeedbackItem, assessment: String, action: FeedbackAction, fixPlan: String, reply: String) {
        self.feedback = feedback
        self.assessment = assessment
        self.action = action
        self.fixPlan = fixPlan
        self.reply = reply
    }

    public var id: String { feedback.id }
}

public struct ResolvedWorktree: Codable, Equatable, Sendable {
    /// `dedicated`: el worktree propio de PRBar, separado (detached), que crea `WorktreeResolver` (el único que
    /// se usa desde que se corrigió I1/I2). Los demás quedan para leer el historial de versiones anteriores.
    public enum Origin: String, Codable, Sendable { case mainClone, existingWorktree, created, dedicated }
    public let path: String
    public let origin: Origin
    /// El clone del usuario del que cuelga el worktree (solo `dedicated`).
    public let localPath: String?
    /// La ref propia con el commit que se trajo, `refs/prbar/respond-<N>-<runID>` (solo `dedicated`).
    public let ref: String?

    public init(path: String, origin: Origin, localPath: String? = nil, ref: String? = nil) {
        self.path = path
        self.origin = origin
        self.localPath = localPath
        self.ref = ref
    }
}

public struct RespondDraft: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public let prID: String
    public let repo: RepoRef
    public let number: Int
    public let title: String
    public let url: URL
    public let headRef: String
    public let account: String
    public let worktree: ResolvedWorktree
    /// El commit de `headRef` que se trajo para el worktree: la base de los fixes y del diff que revisa el usuario.
    public let startHeadOid: String
    public let items: [RespondItem]
    /// The PR's language (from its description): the replies are published in it. English in old history files.
    public let language: PRLanguage
    /// Destino remoto donde vive el worktree (spec J); nil = esta Mac.
    public var runner: String?
    /// El clone local del repo al analizar (para traer los fixes, J.7.9); nil sin carpeta local.
    public var localPath: String?
    /// Responder el feedback o arreglar el CI (spec K.6.1). `feedback` en registros de versiones anteriores.
    public var mode: RespondMode
    /// Los checks que fallaron (solo un Fix CI).
    public var ci: CIFixContext?

    public init(
        id: UUID = UUID(), prID: String, repo: RepoRef, number: Int, title: String, url: URL, headRef: String,
        account: String, worktree: ResolvedWorktree, startHeadOid: String, items: [RespondItem],
        language: PRLanguage = .english, runner: String? = nil, localPath: String? = nil,
        mode: RespondMode = .feedback, ci: CIFixContext? = nil
    ) {
        self.id = id
        self.prID = prID
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.headRef = headRef
        self.account = account
        self.worktree = worktree
        self.startHeadOid = startHeadOid
        self.items = items
        self.language = language
        self.runner = runner
        self.localPath = localPath
        self.mode = mode
        self.ci = ci
    }

    public var isCIFix: Bool { mode == .ciFix }

    private enum CodingKeys: String, CodingKey {
        case id, prID, repo, number, title, url, headRef, account, worktree, startHeadOid, items, language
        case runner, localPath, mode, ci
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id), prID: try c.decode(String.self, forKey: .prID),
            repo: try c.decode(RepoRef.self, forKey: .repo), number: try c.decode(Int.self, forKey: .number),
            title: try c.decode(String.self, forKey: .title), url: try c.decode(URL.self, forKey: .url),
            headRef: try c.decode(String.self, forKey: .headRef), account: try c.decode(String.self, forKey: .account),
            worktree: try c.decode(ResolvedWorktree.self, forKey: .worktree),
            startHeadOid: try c.decode(String.self, forKey: .startHeadOid), items: try c.decode([RespondItem].self, forKey: .items),
            language: (try? c.decodeIfPresent(PRLanguage.self, forKey: .language)) ?? .english,
            runner: try c.decodeIfPresent(String.self, forKey: .runner),
            localPath: try c.decodeIfPresent(String.self, forKey: .localPath),
            mode: (try? c.decodeIfPresent(RespondMode.self, forKey: .mode)) ?? .feedback,
            ci: (try? c.decodeIfPresent(CIFixContext.self, forKey: .ci)) ?? nil)
    }
}

public struct RespondSelection: Codable, Equatable, Sendable {
    public var implement: Bool
    public var fixPlan: String
    public var reply: Bool
    public var replyText: String

    public init(implement: Bool, fixPlan: String, reply: Bool, replyText: String) {
        self.implement = implement
        self.fixPlan = fixPlan
        self.reply = reply
        self.replyText = replyText
    }

    /// Valores por defecto según la acción de Claude: fix → implement + reply ("" = solo "Arreglado en …"),
    /// reply → reply, fixAndReply → los dos, skip → nada. El plan y la respuesta de Claude se conservan
    /// para que el usuario pueda activar la casilla que Claude no marcó.
    public static func defaults(for item: RespondItem) -> RespondSelection {
        // Un Fix CI nunca responde nada (spec K.6.5).
        if item.feedback.kind == .ciChecks {
            return RespondSelection(implement: item.action != .skip && item.action != .reply, fixPlan: item.fixPlan,
                                    reply: false, replyText: "")
        }
        switch item.action {
        case .fix:
            return RespondSelection(implement: true, fixPlan: item.fixPlan, reply: true, replyText: "")
        case .reply:
            return RespondSelection(implement: false, fixPlan: item.fixPlan, reply: true, replyText: item.reply)
        case .fixAndReply:
            return RespondSelection(implement: true, fixPlan: item.fixPlan, reply: true, replyText: item.reply)
        case .skip:
            return RespondSelection(implement: false, fixPlan: item.fixPlan, reply: false, replyText: item.reply)
        }
    }
}

/// Cuentas que muestra la UI de "Responder" antes de cada paso.
public enum RespondCounts {
    /// Ítems con "Implementar fix" marcado.
    public static func fixes(_ draft: RespondDraft, _ selections: [String: RespondSelection]) -> Int {
        draft.items.filter { selections[$0.id]?.implement == true }.count
    }

    /// Respuestas que se publicarían si todos los fixes elegidos terminan en un commit: las marcadas con texto, y
    /// las marcadas con fix aunque no tengan texto (van con "Arreglado en …").
    public static func plannedReplies(_ draft: RespondDraft, _ selections: [String: RespondSelection]) -> Int {
        draft.items.filter { item in
            guard let selection = selections[item.id], selection.reply else { return false }
            return selection.implement || !selection.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    /// Respuestas que todavía publicaría `RespondPublisher.postReplies` con este resultado.
    public static func pendingReplies(_ record: RespondRecord) -> Int {
        record.draft.items.filter { item in
            guard let selection = record.selections[item.id], selection.reply, record.posted[item.id] == nil else { return false }
            let commit = record.result?.items.first { $0.id == item.id && $0.status == .committed }?.commit
            return RespondPublisher.replyText(selection: selection, commit: commit, repo: record.draft.repo,
                                              language: record.draft.language) != nil
        }.count
    }

    /// Commits que hizo PRBar (uno por fix que cambió algo).
    public static func commits(_ result: RespondResult) -> Int {
        result.items.filter { $0.status == .committed && $0.commit != nil }.count
    }
}

public struct ItemResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case committed, noChanges, failed }
    public let id: String
    public let status: Status
    public let commit: String?
    public let summary: String

    public init(id: String, status: Status, commit: String?, summary: String) {
        self.id = id
        self.status = status
        self.commit = commit
        self.summary = summary
    }
}

public struct TestRun: Codable, Equatable, Sendable {
    public let command: String
    public let passed: Bool
    /// Últimas ~80 líneas.
    public let outputTail: String

    public init(command: String, passed: Bool, outputTail: String) {
        self.command = command
        self.passed = passed
        self.outputTail = outputTail
    }
}

public struct RespondResult: Codable, Equatable, Sendable {
    public let items: [ItemResult]
    public let diffStat: String
    /// Nil al terminar los fixes: los tests corren solo si el usuario los pide después de ver el diff
    /// (`FixImplementer.runTests`), y ahí se completa.
    public var tests: TestRun?
    /// Archivos cambiados desde `startHeadOid` que pueden ejecutar código (hooks, scripts, CI, manifiestos de
    /// dependencias; ver `FixImplementer.isSensitive`). La UI los marca en rojo.
    public let sensitiveChanges: [String]
    /// HEAD del worktree al terminar los fixes: lo que muestra el diff y lo único que se pushea (se vuelve a
    /// verificar justo antes del push). Nil en registros de versiones anteriores.
    public let headOid: String?
    /// Huella de la config, los hooks y los `.git` del worktree al terminar los fixes (ver
    /// `GitPaths.securityDigest`); el push se niega si cambió.
    public let gitIntegrity: String?
    /// El diff completo `startHeadOid..headOid` (`--text`, sin textconv ni diff externo), hasta
    /// `FixImplementer.maxDiffLines` líneas. Es lo que el usuario revisa antes de correr tests o pushear.
    public let diff: String?
    /// El diff se cortó: el resto hay que verlo en el worktree.
    public let diffTruncated: Bool?
    /// Los commits nuevos, del más viejo al más nuevo, con el mensaje completo tal como se va a pushear.
    public let commits: [CommitInfo]?
    /// Dependency manifests changed since `startHeadOid` (spec E.5): any change, except `package.json`, which
    /// counts only if a dependency section changed. Nil in records of earlier versions.
    public let dependencyChanges: [String]?
    /// Los commits de un fix remoto ya traídos a la Mac (spec J); nil = el worktree está en esta Mac.
    public var remoteObjects: RemoteObjects?

    public init(items: [ItemResult], diffStat: String, tests: TestRun?, sensitiveChanges: [String] = [],
                headOid: String? = nil, gitIntegrity: String? = nil, diff: String? = nil, diffTruncated: Bool? = nil,
                commits: [CommitInfo]? = nil, dependencyChanges: [String]? = nil, remoteObjects: RemoteObjects? = nil) {
        self.items = items
        self.diffStat = diffStat
        self.tests = tests
        self.sensitiveChanges = sensitiveChanges
        self.headOid = headOid
        self.gitIntegrity = gitIntegrity
        self.diff = diff
        self.diffTruncated = diffTruncated
        self.commits = commits
        self.dependencyChanges = dependencyChanges
        self.remoteObjects = remoteObjects
    }
}

/// Los commits de un fix remoto, ya traídos a la Mac (decisión J.7.9).
public struct RemoteObjects: Codable, Equatable, Sendable {
    /// El repo local donde están los objetos: el clone del usuario o un clone temporal de PRBar.
    public var repoPath: String
    /// `true` si `repoPath` es un clone temporal (se borra al terminar).
    public var temporary: Bool
    public var ref: String
    /// El árbol del commit traído (`<sha>^{tree}`): se re-verifica antes del push.
    public var treeOid: String

    public init(repoPath: String, temporary: Bool, ref: String, treeOid: String) {
        self.repoPath = repoPath
        self.temporary = temporary
        self.ref = ref
        self.treeOid = treeOid
    }
}

/// Un commit de los fixes: sha y mensaje completo.
public struct CommitInfo: Codable, Equatable, Sendable {
    public let sha: String
    public let message: String

    public init(sha: String, message: String) {
        self.sha = sha
        self.message = message
    }
}

public enum RespondSchemas {
    /// {"items":[{"id","assessment","action":"fix|reply|fixAndReply|skip","fixPlan","reply"}]}
    public static let analysis = """
    {"type":"object","additionalProperties":false,"required":["items"],
     "properties":{"items":{"type":"array","items":{"type":"object","additionalProperties":false,
       "required":["id","assessment","action","fixPlan","reply"],
       "properties":{
         "id":{"type":"string"},
         "assessment":{"type":"string"},
         "action":{"type":"string","enum":["fix","reply","fixAndReply","skip"]},
         "fixPlan":{"type":"string"},
         "reply":{"type":"string"}}}}}}
    """

    /// {"status":"done|skipped|failed","summary","commitMessage"}
    public static let fix = """
    {"type":"object","additionalProperties":false,"required":["status","summary","commitMessage"],
     "properties":{
       "status":{"type":"string","enum":["done","skipped","failed"]},
       "summary":{"type":"string"},
       "commitMessage":{"type":"string"}}}
    """
}
