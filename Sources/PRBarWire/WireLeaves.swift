import Foundation

// Los tipos hoja que referencian AppCommand y los resultados de los comandos. Solo la declaración y lo que no depende
// de Core; la lógica de Core sobre ellos queda como `extension` en PRBarCore.

public enum CommitMode: String, Codable, CaseIterable, Sendable {
    case perComment, single

    public var title: String { self == .perComment ? "One per Comment" : "Single Commit" }

    public init(from decoder: Decoder) throws {
        self = CommitMode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .perComment
    }
}

public struct DiskUsage: Codable, Equatable, Sendable {
    public var items: [DiskItem]
    public var scannedAt: Date

    public init(items: [DiskItem], scannedAt: Date) {
        self.items = items
        self.scannedAt = scannedAt
    }

    public var total: Int64 { items.map(\.bytes).reduce(0, +) }
    public func bytes(_ kind: DiskCategoryKind) -> Int64 { items.filter { $0.kind == kind }.map(\.bytes).reduce(0, +) }
    /// Worktrees por repo ("Other" sin repo conocido).
    public var worktreesByRepo: [(repo: String, bytes: Int64)] {
        Dictionary(grouping: items.filter { $0.kind == .worktrees }, by: { $0.repo ?? "Other" })
            .map { ($0.key, $0.value.map(\.bytes).reduce(0, +)) }
            .sorted { $0.bytes > $1.bytes }
    }
}

/// Lo que muestra la ventana de Merge (spec G.2/G.3): el PR tal como lo ve GitHub al abrirla. Lo pide
/// `GitHubAPI.mergeDetail` con el token de la cuenta. Todo `Codable` y tolerante: va tal cual a `prbar merge --json`.
public struct MergeDetail: Codable, Equatable, Sendable {
    public var number: Int
    public var title: String
    /// La descripción (Markdown, escrita por el autor: texto no confiable). Vacía si no tiene.
    public var body: String
    public var url: URL?
    public var author: String
    public var authorAvatarURL: URL?
    public var baseRef: String
    public var headRef: String
    /// El head que muestra la ventana: el `expectedHeadOid` del merge.
    public var headOid: String
    public var additions: Int
    public var deletions: Int
    public var commitCount: Int?
    public var mergeable: MergeableState
    public var status: MergeStateStatus
    public var reviewDecision: ReviewDecision
    /// La review vigente de cada reviewer (sin el autor del PR), la más nueva primero.
    public var reviews: [MergeReviewSummary]
    /// Reviews pedidas que todavía no llegaron (usuarios y equipos).
    public var pendingReviewers: [String]
    public var checks: [MergeCheck]
    /// `contexts.totalCount`: puede ser más que `checks` (se piden 100).
    public var checksTotal: Int
    /// Sin resolver entre los hilos que se miraron (`checkedThreads`).
    public var unresolvedThreads: Int
    public var totalThreads: Int
    /// Los hilos que trajo la consulta (los primeros 100) cuando son menos que `totalThreads`; `nil` = se miraron
    /// todos.
    public var checkedThreads: Int?
    /// Los primeros `maxFiles` archivos.
    public var files: [MergeChangedFile]
    /// Todos los archivos del PR (`changedFiles`).
    public var changedFiles: Int
    /// Las secciones que GitHub no pudo dar (respondió con datos y errores de algunos campos): se muestran con lo que
    /// llegó y la nota `incompleteNote`.
    public var incomplete: [Section] = []

    public static let maxFiles = 100

    /// Una parte del resumen, para decir cuál no se pudo cargar.
    public enum Section: String, Codable, Sendable, CaseIterable {
        case reviews, checks, conversations, files, details

        /// Las secciones de los errores de GraphQL según su `path` (sin repetir, en el orden de `allCases`). Un error
        /// sin path, o de un campo que no es una sección, cuenta como `details`.
        public static func sections(forErrorPaths paths: [[String]?]) -> [Section] {
            let found = Set(paths.map { path -> Section in
                guard let path, let index = path.firstIndex(of: "pullRequest"), index + 1 < path.count else { return .details }
                switch path[index + 1] {
                case "latestOpinionatedReviews", "latestReviews", "reviewRequests": return .reviews
                case "statusCheckRollup": return .checks
                case "reviewThreads": return .conversations
                case "files": return .files
                default: return .details
                }
            })
            return allCases.filter(found.contains)
        }
    }

    /// "Some checks and files couldn’t be loaded from GitHub." (`nil` si llegó todo).
    public var incompleteNote: String? {
        guard !incomplete.isEmpty else { return nil }
        let names = incomplete.map(\.rawValue)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "Some \(list) couldn’t be loaded from GitHub."
    }

    public init(number: Int, title: String, body: String, url: URL?, author: String, authorAvatarURL: URL?,
                baseRef: String, headRef: String, headOid: String, additions: Int, deletions: Int, commitCount: Int?,
                mergeable: MergeableState, status: MergeStateStatus, reviewDecision: ReviewDecision,
                reviews: [MergeReviewSummary], pendingReviewers: [String], checks: [MergeCheck], checksTotal: Int,
                unresolvedThreads: Int, totalThreads: Int, checkedThreads: Int? = nil, files: [MergeChangedFile],
                changedFiles: Int) {
        self.number = number
        self.title = title
        self.body = body
        self.url = url
        self.author = author
        self.authorAvatarURL = authorAvatarURL
        self.baseRef = baseRef
        self.headRef = headRef
        self.headOid = headOid
        self.additions = additions
        self.deletions = deletions
        self.commitCount = commitCount
        self.mergeable = mergeable
        self.status = status
        self.reviewDecision = reviewDecision
        self.reviews = reviews
        self.pendingReviewers = pendingReviewers
        self.checks = checks
        self.checksTotal = checksTotal
        self.unresolvedThreads = unresolvedThreads
        self.totalThreads = totalThreads
        self.checkedThreads = checkedThreads
        self.files = files
        self.changedFiles = changedFiles
    }

    /// Un detalle sin nada (tests y valores iniciales).
    public static func empty(number: Int, headOid: String) -> MergeDetail {
        MergeDetail(number: number, title: "", body: "", url: nil, author: "", authorAvatarURL: nil, baseRef: "",
                    headRef: "", headOid: headOid, additions: 0, deletions: 0, commitCount: nil, mergeable: .unknown,
                    status: .unknown, reviewDecision: .none, reviews: [], pendingReviewers: [], checks: [], checksTotal: 0,
                    unresolvedThreads: 0, totalThreads: 0, files: [], changedFiles: 0)
    }

    /// "8 passed · 1 failed (not required) · 1 running" (spec G.2.3). Los fallidos dicen cuáles no son requeridos.
    public var checksSummary: String {
        guard !checks.isEmpty else { return "No checks" }
        var parts: [String] = []
        let passed = checks.filter { $0.state == .passed }.count
        if passed > 0 { parts.append("\(passed) passed") }
        let failed = checks.filter { $0.state == .failed }
        if !failed.isEmpty {
            let optional = failed.filter { !$0.isRequired }.count
            let qualifier = optional == 0 ? "" : optional == failed.count ? " (not required)" : " (\(optional) not required)"
            parts.append("\(failed.count) failed\(qualifier)")
        }
        let running = checks.filter { $0.state == .running }.count
        if running > 0 { parts.append("\(running) running") }
        let skipped = checks.filter { $0.state == .skipped }.count
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: " · ")
    }

    /// The Checks header: "4 passed · 1 failed · 1 running", without the "(not required)" qualifiers (the rows mark
    /// the required checks; `checksSummary` goes in the header's help).
    public var checksShortSummary: String {
        guard !checks.isEmpty else { return "No checks" }
        let counts: [(Int, String)] = [
            (checks.filter { $0.state == .passed }.count, "passed"), (checks.filter { $0.state == .failed }.count, "failed"),
            (checks.filter { $0.state == .running }.count, "running"), (checks.filter { $0.state == .skipped }.count, "skipped"),
        ]
        return counts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    /// Hilos que no se miraron (había más de los que trae la consulta).
    public var uncheckedThreads: Int { checkedThreads.map { max(totalThreads - $0, 0) } ?? 0 }

    /// Lo que dice la sección Conversations (y la CLI): nunca "todas resueltas" si hubo hilos sin mirar.
    public var conversationsSummary: String {
        func plural(_ n: Int) -> String { n == 1 ? "" : "s" }
        if incomplete.contains(.conversations) { return "Couldn’t check the review conversations — see GitHub" }
        let unresolved = unresolvedThreads
        if unresolved > 0 {
            return (uncheckedThreads > 0 ? "At least " : "") + "\(unresolved) unresolved conversation\(plural(unresolved))"
        }
        if uncheckedThreads > 0 {
            return "\(totalThreads - uncheckedThreads) of \(totalThreads) conversations are resolved — check the other \(uncheckedThreads) on GitHub"
        }
        return totalThreads == 0 ? "No review conversations" : "All conversations are resolved"
    }

    /// Hay conversaciones sin resolver, o no se sabe.
    public var conversationsNeedAttention: Bool {
        unresolvedThreads > 0 || uncheckedThreads > 0 || incomplete.contains(.conversations)
    }

    /// Archivos que no entraron (spec G.2.5: "and N more on GitHub").
    public var moreFiles: Int { max(changedFiles - files.count, 0) }
    /// Checks que no entraron.
    public var moreChecks: Int { max(checksTotal - checks.count, 0) }

    private enum CodingKeys: String, CodingKey {
        case number, title, body, url, author, authorAvatarURL, baseRef, headRef, headOid, additions, deletions, commitCount
        case mergeable, status, reviewDecision, reviews, pendingReviewers, checks, checksTotal, unresolvedThreads
        case totalThreads, checkedThreads, files, changedFiles, incomplete
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        headOid = try c.decode(String.self, forKey: .headOid)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
        url = (try? c.decodeIfPresent(URL.self, forKey: .url)) ?? nil
        author = (try? c.decodeIfPresent(String.self, forKey: .author)) ?? ""
        authorAvatarURL = (try? c.decodeIfPresent(URL.self, forKey: .authorAvatarURL)) ?? nil
        baseRef = (try? c.decodeIfPresent(String.self, forKey: .baseRef)) ?? ""
        headRef = (try? c.decodeIfPresent(String.self, forKey: .headRef)) ?? ""
        additions = (try? c.decodeIfPresent(Int.self, forKey: .additions)) ?? 0
        deletions = (try? c.decodeIfPresent(Int.self, forKey: .deletions)) ?? 0
        commitCount = (try? c.decodeIfPresent(Int.self, forKey: .commitCount)) ?? nil
        mergeable = (try? c.decodeIfPresent(MergeableState.self, forKey: .mergeable)) ?? .unknown
        status = (try? c.decodeIfPresent(MergeStateStatus.self, forKey: .status)) ?? .unknown
        reviewDecision = (try? c.decodeIfPresent(ReviewDecision.self, forKey: .reviewDecision)) ?? .none
        reviews = (try? c.decodeIfPresent(LossyArray<MergeReviewSummary>.self, forKey: .reviews))?.elements ?? []
        pendingReviewers = (try? c.decodeIfPresent([String].self, forKey: .pendingReviewers)) ?? []
        checks = (try? c.decodeIfPresent(LossyArray<MergeCheck>.self, forKey: .checks))?.elements ?? []
        checksTotal = (try? c.decodeIfPresent(Int.self, forKey: .checksTotal)) ?? checks.count
        unresolvedThreads = (try? c.decodeIfPresent(Int.self, forKey: .unresolvedThreads)) ?? 0
        totalThreads = (try? c.decodeIfPresent(Int.self, forKey: .totalThreads)) ?? 0
        checkedThreads = (try? c.decodeIfPresent(Int.self, forKey: .checkedThreads)) ?? nil
        files = (try? c.decodeIfPresent(LossyArray<MergeChangedFile>.self, forKey: .files))?.elements ?? []
        changedFiles = (try? c.decodeIfPresent(Int.self, forKey: .changedFiles)) ?? files.count
        incomplete = (try? c.decodeIfPresent(LossyArray<Section>.self, forKey: .incomplete))?.elements ?? []
    }
}

/// Cómo se mergea un PR (spec F.3). En `config.json` va en minúsculas (`"squash"`); en GraphQL, en mayúsculas.
public enum MergeMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case squash, merge, rebase

    public var id: String { rawValue }

    /// `PullRequestMergeMethod` de GraphQL.
    public var graphQLValue: String { rawValue.uppercased() }

    public init?(graphQL: String?) {
        guard let graphQL, let method = MergeMethod(rawValue: graphQL.lowercased()) else { return nil }
        self = method
    }

    /// Botón por defecto del diálogo y los ítems de "Merge With…".
    public var actionTitle: String {
        switch self {
        case .squash: "Squash and Merge"
        case .merge: "Merge"
        case .rebase: "Rebase and Merge"
        }
    }

    /// Nombre corto (Settings › Repos).
    public var title: String {
        switch self {
        case .squash: "Squash"
        case .merge: "Merge"
        case .rebase: "Rebase"
        }
    }
}

/// Una sección del popover. Las de siempre (una por `PRCategory` accionable) más las dos "calladas": Other (PRs
/// ajenos sin nada que hacer) y Waiting for Review (mis PRs sin nada que hacer). Spec H.1.
public enum PopoverSection: String, Codable, CaseIterable, Sendable, Identifiable {
    case toReview
    case updatedSinceMyReview
    case otherToReview
    case myFeedback
    case readyToMerge
    case waitingForReview

    public var id: String { rawValue }

    public var category: PRCategory {
        switch self {
        case .toReview: .toReview
        case .updatedSinceMyReview: .updatedSinceMyReview
        case .otherToReview, .waitingForReview: .other
        case .myFeedback: .myFeedback
        case .readyToMerge: .readyToMerge
        }
    }

    public var tab: PopoverTab {
        switch self {
        case .toReview, .updatedSinceMyReview, .otherToReview: .toReview
        case .myFeedback, .readyToMerge, .waitingForReview: .mine
        }
    }

    /// The section's title in the popover and the main window's list (inside the My PRs tab, "My PRs with
    /// Feedback" would say "My PRs" twice).
    public var title: String {
        switch self {
        case .otherToReview: "Other"
        case .waitingForReview: "Waiting for Review"
        case .myFeedback: "With Feedback"
        default: category.title
        }
    }

    public var subtitle: String? {
        switch self {
        case .otherToReview: "drafts and nothing to do"
        case .waitingForReview: "nothing to do right now"
        default: nil
        }
    }

    /// Colapsada al abrir, atenuada y sin contar en el badge ni en el contador de la pestaña.
    public var isQuiet: Bool { self == .otherToReview || self == .waitingForReview }
}

/// Las dos pestañas del popover (spec H.1). El `rawValue` es el de la CLI (`--tab`) y el de `UserDefaults`.
public enum PopoverTab: String, Codable, CaseIterable, Sendable, Identifiable {
    case toReview = "to-review"
    case mine

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toReview: "To Review"
        case .mine: "My PRs"
        }
    }
}

/// The stages whose prompt the user can edit (spec E.6). Each has a default editable part and variables; PRBar
/// always wraps it with the fixed part (`PromptWrapper`), so editing it never changes tools, permissions or schema.
public enum PromptStage: String, CaseIterable, Codable, Identifiable, Sendable {
    case review, filter, analysis, implementation, reviewChat, respondChat, mergeChat, instructionsChat
    /// Fix CI (spec K.3): diagnoses the failing checks and fixes the code in one run.
    case ciFix

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .review: "Review"
        case .filter: "Review filter"
        case .analysis: "Feedback analysis"
        case .implementation: "Fix implementation"
        case .reviewChat: "Review chat"
        case .respondChat: "Respond chat"
        case .mergeChat: "Merge chat"
        case .instructionsChat: "Instructions chat"
        case .ciFix: "CI fix"
        }
    }

    /// The rules that apply to it (the instructions chat has none).
    public var ruleStage: RuleStage? {
        switch self {
        case .review, .filter, .reviewChat: .review
        case .analysis, .implementation, .respondChat, .mergeChat, .ciFix: .respond
        case .instructionsChat: nil
        }
    }

    /// It has a skill and a mode (the chats don't).
    public var hasSkill: Bool { [.review, .filter, .analysis, .implementation].contains(self) }

    static let pr = PromptVariable(name: "pr", summary: "PR number")
    static let repo = PromptVariable(name: "repo", summary: "Repository (owner/name)")
    static let title = PromptVariable(name: "title", summary: "PR title (written by its author)")
    static let author = PromptVariable(name: "author", summary: "PR author")
    static let language = PromptVariable(name: "language", summary: "The PR’s language, e.g. Spanish (es)")
    static let rules = PromptVariable(name: "rules", summary: "Your rules (PRBar also adds them after the prompt)")
    static let skill = PromptVariable(name: "skill", summary: "The stage’s skill")
    static let diffPath = PromptVariable(name: "diff_path", summary: "Path of the PR’s diff")
    static let prMDPath = PromptVariable(name: "pr_md_path", summary: "Path of the PR’s data and description")
    static let codeLocation = PromptVariable(name: "code_location", summary: "Where the code is (or that there’s only the diff)")
    static let headRef = PromptVariable(name: "head_ref", summary: "PR branch")
    static let baseRef = PromptVariable(name: "base_ref", summary: "Base branch")
    static let findingsJSON = PromptVariable(name: "findings_json", summary: "The review’s findings, as JSON")
    static let feedbackPath = PromptVariable(name: "feedback_path", summary: "Path of the review comments (JSON)")
    static let location = PromptVariable(name: "location", summary: "File and line of the comment")
    static let assessment = PromptVariable(name: "assessment", summary: "Claude’s assessment of the comment")
    static let fixPlan = PromptVariable(name: "fix_plan", summary: "The plan you approved")
    static let repos = PromptVariable(name: "repos", summary: "Your configured repos")
    static let checks = PromptVariable(name: "checks", summary: "The names of the failing checks")

    public var variables: [PromptVariable] {
        switch self {
        case .review:
            [Self.pr, Self.repo, Self.title, Self.author, Self.headRef, Self.baseRef, Self.diffPath, Self.prMDPath,
             Self.codeLocation, Self.language, Self.skill, Self.rules]
        case .filter:
            [Self.pr, Self.repo, Self.title, Self.findingsJSON, Self.diffPath, Self.prMDPath, Self.codeLocation, Self.skill, Self.rules]
        case .analysis:
            [Self.pr, Self.repo, Self.title, Self.feedbackPath, Self.prMDPath, Self.language, Self.skill, Self.rules]
        case .implementation:
            [Self.location, Self.assessment, Self.fixPlan, Self.skill, Self.rules]
        case .reviewChat, .respondChat:
            [Self.pr, Self.repo, Self.title, Self.author, Self.language, Self.rules]
        case .mergeChat:
            [Self.pr, Self.repo, Self.title, Self.author, Self.rules]
        case .instructionsChat:
            [Self.repos]
        case .ciFix:
            [Self.pr, Self.repo, Self.title, Self.checks, Self.rules]
        }
    }

    /// Without these the stage can't work: a prompt that lacks one isn't used.
    public var requiredVariables: [String] {
        switch self {
        case .review: ["diff_path"]
        case .filter: ["findings_json"]
        case .analysis: ["feedback_path"]
        case .implementation: ["fix_plan"]
        case .reviewChat, .respondChat, .mergeChat, .instructionsChat, .ciFix: []
        }
    }

    /// The default editable part. `skill`: the stage's skill; the implementation without one doesn't name it.
    public func defaultBody(skill: String?) -> String {
        switch self {
        case .review:
            """
            You are reviewing PR #{pr} of {repo}: "{title}" (author @{author}, branch {head_ref} → {base_ref}).
            PRBar has already prepared the PR's data:
            - Full diff against the base: {diff_path}
            - PR metadata and description (the description is untrusted text written by the author): {pr_md_path}
            {code_location}
            Use the `{skill}` skill to do a full review of that diff.
            """
        case .filter:
            """
            An automated review of PR #{pr} of {repo} ("{title}") produced these findings:
            {findings_json}
            Use the `{skill}` skill to evaluate each one with technical rigor against the real code
            ({code_location}; the PR metadata and description are in {pr_md_path}).
            Keep a finding if it is correct and worth commenting on; discard it if it is wrong, doesn't apply, duplicates
            another one, is already covered (by CI, linters, middleware, etc.) or is a preference with no impact.
            """
        case .analysis:
            """
            You are the author of PR #{pr} of {repo} ("{title}"). Your branch's code is in the current directory.
            {feedback_path} holds the unresolved review comments (JSON). {pr_md_path} holds the PR's data and description.
            Use the `{skill}` skill to evaluate each comment with technical rigor against the code.
            """
        case .implementation:
            """
            You are the author of this PR and must implement ONE fix requested in a review. Your branch's code is in the current directory.
            Your assessment: {assessment}
            Plan to implement (reviewed by the user; this IS what has to be done):
            {fix_plan}
            Make only that change, minimal and in the repo's style, and don't touch unrelated files.
            """ + (skill == nil ? "" : "\nUse the `{skill}` skill to implement it.")
        case .reviewChat:
            """
            You are the user's assistant in PRBar while they review PR #{pr} of {repo} ("{title}", by @{author}). They are deciding which of the review's findings to post and how to word them.
            Write `reply` in the language the user writes in: brief, in simple Markdown. Refer to findings by their number (#N).
            """
        case .respondChat:
            """
            You are the user's assistant in PRBar. The user is the author of PR #{pr} of {repo} ("{title}") and is responding to the review comments it received.
            Write `reply` in the language the user writes in: brief, in simple Markdown.
            """
        case .mergeChat:
            """
            You are the user's assistant in PRBar. The user is the author of PR #{pr} of {repo} ("{title}") and is about to merge it. Help them decide: answer questions about the changes, the reviews and the checks, and point out anything risky.
            Write `reply` in the language the user writes in: brief, in simple Markdown.
            """
        case .instructionsChat:
            """
            You help the user manage PRBar's rules: short instructions that PRBar adds to Claude's prompts when it reviews other people's PRs (Review) or fixes the feedback on the user's own PRs (Fixes). The user's repos: {repos}.
            Turn what the user asks into rule changes. Keep each rule short, concrete and in the user's words and language. Before adding a rule, check whether an existing one already covers it and edit that one instead.
            Write `reply` in the language the user writes in: brief, in simple Markdown.
            """
        case .ciFix:
            """
            You are the author of PR #{pr} of {repo} ("{title}"). Its CI failed on these checks: {checks}. Your branch's code is in the current directory, at the commit whose checks failed.
            Read the failure output below, find the root cause in the code and fix it with a minimal change in the repo's style.
            Fix the code, not the CI: don't disable, skip or weaken tests, checks or linters to make them pass, and don't edit the CI configuration unless the failure is clearly caused by it.
            If the failure isn't caused by this branch's code (a flaky test, the CI infrastructure, an outage, missing secrets), change nothing and answer `skipped` explaining why.
            """
        }
    }
}

public struct ResourceUsage: Codable, Equatable, Sendable {
    /// % de un núcleo (como Activity Monitor; puede pasar 100).
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var processes: [ProcessUsage]
    public var sampledAt: Date

    public init(cpuPercent: Double, memoryBytes: UInt64, processes: [ProcessUsage], sampledAt: Date) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.processes = processes
        self.sampledAt = sampledAt
    }
}

public enum ReviewEvent: String, Codable, Sendable {
    case comment = "COMMENT"
    case requestChanges = "REQUEST_CHANGES"
    case approve = "APPROVE"
}

public enum ReviewTone: String, Codable, CaseIterable, Sendable {
    case direct, friendly, withSuggestions

    public var title: String {
        switch self {
        case .direct: "Direct"
        case .friendly: "Friendly"
        case .withSuggestions: "With Suggestions"
        }
    }

    public init(from decoder: Decoder) throws {
        self = ReviewTone(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .direct
    }
}

/// Global or one repo (`owner/name`). JSON: `{"kind": "global"}` or `{"kind": "repo", "repo": "acme/web-app"}`.
public enum RuleScope: Hashable, Codable, Sendable {
    case global
    case repo(String)

    public var title: String {
        switch self {
        case .global: "Global"
        case .repo(let name): name
        }
    }

    public var repo: String? {
        if case .repo(let name) = self { return name }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case kind, repo }

    /// A broken scope throws: a repo rule must never become global.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "global":
            self = .global
        case "repo":
            let name = try c.decode(String.self, forKey: .repo).trimmingCharacters(in: .whitespaces)
            guard name.split(separator: "/").count == 2 else {
                throw DecodingError.dataCorruptedError(forKey: .repo, in: c, debugDescription: "Not owner/name: \(name)")
            }
            self = .repo(name)
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown scope \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try c.encode("global", forKey: .kind)
        case .repo(let name):
            try c.encode("repo", forKey: .kind)
            try c.encode(name, forKey: .repo)
        }
    }
}

/// The flow a rule applies to (spec E.1): `review` (review, filter and review chat) or `respond` (analysis,
/// implementation and respond chat). The UI calls the second one "Fixes".
public enum RuleStage: String, Codable, CaseIterable, Comparable, Sendable {
    case review, respond

    public var title: String { self == .review ? "Review" : "Fixes" }

    public static func < (lhs: RuleStage, rhs: RuleStage) -> Bool { lhs == .review && rhs == .respond }
}

/// Lo que se sabe de un host después de verificarlo (spec J.3).
public struct RunnerHostInfo: Codable, Equatable, Sendable {
    public var host: String
    public var os: String?
    public var arch: String?
    /// El `HOME` del usuario en el host (para `~/` en los includes de git del guardián).
    public var home: String?
    public var gitPath: String?
    public var gitVersion: String?
    public var claudePath: String?
    public var claudeVersion: String?
    public var perl: Bool
    public var quotingOK: Bool
    /// La raíz verificada (`pwd -P`).
    public var root: String?
    public var problems: [String]
    public var checkedAt: Date
    /// Solo "Test Connection" lo prueba (`nil` = no se probó).
    public var claudeLoggedIn: Bool?

    public init(host: String, os: String? = nil, arch: String? = nil, home: String? = nil, gitPath: String? = nil, gitVersion: String? = nil,
                claudePath: String? = nil, claudeVersion: String? = nil, perl: Bool = false, quotingOK: Bool = false,
                root: String? = nil, problems: [String] = [], checkedAt: Date = Date(), claudeLoggedIn: Bool? = nil) {
        self.host = host
        self.os = os
        self.arch = arch
        self.home = home
        self.gitPath = gitPath
        self.gitVersion = gitVersion
        self.claudePath = claudePath
        self.claudeVersion = claudeVersion
        self.perl = perl
        self.quotingOK = quotingOK
        self.root = root
        self.problems = problems
        self.checkedAt = checkedAt
        self.claudeLoggedIn = claudeLoggedIn
    }

    /// Una verificación que ni siquiera pudo correr (host caído, ssh mal configurado).
    public init(host: String, problem: String) {
        self.init(host: host, problems: [problem])
    }

    public var isUsable: Bool { problems.isEmpty && root != nil && gitPath != nil && claudePath != nil }

    /// Carpetas de `git` y `claude` del host (para el `PATH` remoto).
    public var toolDirectories: [String] {
        [claudePath, gitPath].compactMap { $0 }.map { ($0 as NSString).deletingLastPathComponent }
    }
}

public enum Severity: String, Codable, Sendable, CaseIterable {
    case high, medium, low

    public var label: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }
}

/// Cómo PRBar habla con Slack (spec §17.5). En los dos casos los mensajes y las reacciones salen como el usuario.
public enum SlackProvider: String, Codable, CaseIterable, Sendable {
    /// API Web de Slack directa, con el User OAuth Token (`xoxp-…`) del Llavero.
    case userToken
    /// El conector de Slack de la cuenta de Claude del usuario, vía `claude -p` (sin token en PRBar).
    case claudeConnector
}

/// `MergeableState` de GitHub. `UNKNOWN` = GitHub todavía lo está calculando.
public enum MergeableState: String, Codable, Sendable {
    case mergeable, conflicting, unknown

    public init(graphQL: String?) {
        switch graphQL {
        case "MERGEABLE": self = .mergeable
        case "CONFLICTING": self = .conflicting
        default: self = .unknown
        }
    }
}

/// `MergeStateStatus` de GitHub. `DRAFT` está deprecado en la API (se usa `isDraft`), pero todavía puede llegar.
public enum MergeStateStatus: String, Codable, Sendable {
    case clean, hasHooks, unstable, blocked, behind, dirty, draft, unknown

    public init(graphQL: String?) {
        switch graphQL {
        case "CLEAN": self = .clean
        case "HAS_HOOKS": self = .hasHooks
        case "UNSTABLE": self = .unstable
        case "BLOCKED": self = .blocked
        case "BEHIND": self = .behind
        case "DIRTY": self = .dirty
        case "DRAFT": self = .draft
        default: self = .unknown
        }
    }
}

public enum ReviewDecision: String, Codable, Sendable {
    case approved, changesRequested, reviewRequired, none
}

/// La review vigente de un reviewer.
public struct MergeReviewSummary: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case approved, changesRequested, commented, dismissed

        public init?(graphQL: String?) {
            switch graphQL {
            case "APPROVED": self = .approved
            case "CHANGES_REQUESTED": self = .changesRequested
            case "COMMENTED": self = .commented
            case "DISMISSED": self = .dismissed
            default: return nil
            }
        }

        public var title: String {
            switch self {
            case .approved: "Approved"
            case .changesRequested: "Changes requested"
            case .commented: "Commented"
            case .dismissed: "Dismissed"
            }
        }
    }

    public var author: String
    public var avatarURL: URL?
    public var state: State
    public var submittedAt: Date?

    public init(author: String, avatarURL: URL?, state: State, submittedAt: Date?) {
        self.author = author
        self.avatarURL = avatarURL
        self.state = state
        self.submittedAt = submittedAt
    }
}

/// Un check del CI: un `CheckRun` (GitHub Actions, apps) o un `StatusContext` (la API de estados vieja).
public struct MergeCheck: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case checkRun, status }

    public enum State: String, Codable, Sendable {
        case passed, failed, running, skipped

        /// `CheckRun`: sin terminar = running; terminado, según la conclusión (una desconocida cuenta como fallida).
        public init(checkStatus: String?, conclusion: String?) {
            guard checkStatus == "COMPLETED" else { self = .running; return }
            switch conclusion {
            case "SUCCESS": self = .passed
            case "NEUTRAL", "SKIPPED", "CANCELLED", "STALE": self = .skipped
            default: self = .failed
            }
        }

        /// `StatusContext` (`StatusState`).
        public init(statusState: String?) {
            switch statusState {
            case "SUCCESS": self = .passed
            case "FAILURE", "ERROR": self = .failed
            default: self = .running
            }
        }

        public var title: String {
            switch self {
            case .passed: "Passed"
            case .failed: "Failed"
            case .running: "Running"
            case .skipped: "Skipped"
            }
        }
    }

    public var name: String
    public var kind: Kind
    public var state: State
    public var isRequired: Bool
    public var url: URL?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(name: String, kind: Kind, state: State, isRequired: Bool, url: URL? = nil, startedAt: Date? = nil,
                completedAt: Date? = nil) {
        self.name = name
        self.kind = kind
        self.state = state
        self.isRequired = isRequired
        self.url = url
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// Segundos entre `startedAt` y `completedAt` (solo checks terminados).
    public var duration: TimeInterval? {
        guard let startedAt, let completedAt, completedAt >= startedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }

    /// "1m 30s", "45s", "2h 5m".
    public static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }
}

/// Un archivo del PR.
public struct MergeChangedFile: Codable, Equatable, Sendable {
    public enum Change: String, Codable, Sendable {
        case added, modified, removed, renamed, copied, changed

        /// `PatchStatus` de GitHub.
        public init(patchStatus: String?) {
            switch patchStatus {
            case "ADDED": self = .added
            case "DELETED": self = .removed
            case "RENAMED": self = .renamed
            case "COPIED": self = .copied
            case "CHANGED": self = .changed
            default: self = .modified
            }
        }

        /// La letra de la lista (A, M, D, R, C).
        public var letter: String {
            switch self {
            case .added: "A"
            case .modified, .changed: "M"
            case .removed: "D"
            case .renamed: "R"
            case .copied: "C"
            }
        }
    }

    public var path: String
    public var additions: Int
    public var deletions: Int
    public var change: Change

    public init(path: String, additions: Int, deletions: Int, change: Change) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.change = change
    }
}

public struct DiskItem: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var bytes: Int64
    public var kind: DiskCategoryKind
    public var state: DiskItemState
    public var repo: String?
    /// El clone del usuario al que pertenece el worktree (para sacarlo con git).
    public var clone: String?
    public var title: String

    public var id: String { path }

    public init(path: String, bytes: Int64, kind: DiskCategoryKind, state: DiskItemState, repo: String? = nil,
                clone: String? = nil, title: String) {
        self.path = path
        self.bytes = bytes
        self.kind = kind
        self.state = state
        self.repo = repo
        self.clone = clone
        self.title = title
    }
}

public enum DiskCategoryKind: String, Codable, CaseIterable, Sendable {
    case worktrees, updater, history, logs, appData

    public var title: String {
        switch self {
        case .worktrees: "Worktrees"
        case .updater: "Updater"
        case .history: "History"
        case .logs: "Logs"
        case .appData: "App data"
        }
    }
}

/// A variable of an editable prompt or template (spec E.5/E.6).
public struct PromptVariable: Hashable, Sendable {
    public let name: String
    public let summary: String
    public var token: String { "{\(name)}" }

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

/// A problem in a custom prompt.
public enum PromptIssue: Hashable, Sendable {
    /// A variable the stage needs is missing: the prompt can't be used.
    case missing(String)
    /// A name between braces that isn't a variable of the stage: it's sent as is.
    case unknown(String)

    public var message: String {
        switch self {
        case .missing(let name): "The prompt must use {\(name)}."
        case .unknown(let name): "{\(name)} isn’t a variable of this prompt: it will be sent as is."
        }
    }

    public var blocks: Bool {
        if case .missing = self { return true }
        return false
    }
}

public enum PRCategory: String, Codable, Sendable, CaseIterable, Comparable, Identifiable {
    case toReview, updatedSinceMyReview, myFeedback, readyToMerge, other

    public var id: String { rawValue }
    public var countsForBadge: Bool { self != .other }

    public var title: String {
        switch self {
        case .toReview: "To Review"
        case .updatedSinceMyReview: "Updated Since My Review"
        case .myFeedback: "My PRs with Feedback"
        case .readyToMerge: "Ready to Merge"
        case .other: "Other"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self)! }

    public static func < (lhs: PRCategory, rhs: PRCategory) -> Bool { lhs.order < rhs.order }
}

public struct ProcessUsage: Codable, Equatable, Sendable, Identifiable {
    public var pid: Int32
    public var name: String
    public var activity: ProcessActivity?
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var startedAt: Date?
    public var isApp: Bool

    public init(pid: Int32, name: String, activity: ProcessActivity?, cpuPercent: Double, memoryBytes: UInt64,
                startedAt: Date?, isApp: Bool) {
        self.pid = pid
        self.name = name
        self.activity = activity
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.startedAt = startedAt
        self.isApp = isApp
    }

    public var id: Int32 { pid }
    /// Los trabajos remotos (Plan 14) se muestran "on <host>" y sin CPU/RAM locales.
    public var remoteHost: String? { activity?.host }
    public var label: String { isApp ? "PRBar" : "\(activity?.title ?? "PRBar") · \(name)" }
}

/// An array decoded element by element: the elements that don't decode are skipped, so one bad (or newer) entry
/// doesn't lose the others.
public struct LossyArray<Element: Decodable>: Decodable {
    public let elements: [Element]

    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(Skip.self)
            }
        }
        self.elements = elements
    }
}

public enum DiskItemState: String, Codable, Sendable {
    /// Un worktree o carpeta de una corrida en curso (o de un draft que la app tiene).
    case active
    /// Con nombre de PRBar y sin corrida: Clean Up lo puede borrar.
    case orphan
    /// Reconstruible (staging y builds del updater).
    case cache
    /// Datos (historial, logs, config): solo se borra lo viejo, a pedido.
    case data
}

/// La tarea de PRBar a la que pertenece un proceso (spec I: "Review api#317 · claude"). Se propaga con un
/// `@TaskLocal`: quien arranca una tarea (`JobScheduler`, el updater, Slack) la pone y `SystemProcessRunner` la anota
/// junto al pid de cada proceso que lanza.
public struct ProcessActivity: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case review, respond, chat, instructions, update, slack, merge
        /// Fix CI (spec K): an analysis-and-fix run of the Respond queue in CI mode.
        case ciFix
    }

    public var kind: Kind
    public var prID: String?
    public var title: String
    /// El host remoto donde corre el trabajo (Plan 14); `nil` = esta Mac.
    public var host: String?
    /// El chat (`ChatSession.id`) de un trabajo `.chat`: Stop busca ese coordinador, no "el chat del PR" (un PR puede
    /// tener el de Review, el de Respond y el de Merge).
    public var chatSessionID: UUID?

    public init(kind: Kind, prID: String? = nil, title: String, host: String? = nil, chatSessionID: UUID? = nil) {
        self.kind = kind
        self.prID = prID
        self.title = title
        self.host = host
        self.chatSessionID = chatSessionID
    }

    @TaskLocal public static var current: ProcessActivity?

    public static func review(_ prID: String) -> ProcessActivity { .init(kind: .review, prID: prID, title: "Review \(shortPR(prID))") }
    public static func respond(_ prID: String) -> ProcessActivity { .init(kind: .respond, prID: prID, title: "Respond \(shortPR(prID))") }
    public static func chat(_ prID: String, sessionID: UUID? = nil) -> ProcessActivity {
        .init(kind: .chat, prID: prID, title: "Chat \(shortPR(prID))", chatSessionID: sessionID)
    }
    public static func ciFix(_ prID: String) -> ProcessActivity { .init(kind: .ciFix, prID: prID, title: "Fix CI \(shortPR(prID))") }
    public static func merge(_ prID: String) -> ProcessActivity { .init(kind: .merge, prID: prID, title: "Merge \(shortPR(prID))") }
    public static let instructions = ProcessActivity(kind: .instructions, title: "Instructions chat")
    public static let update = ProcessActivity(kind: .update, title: "Update build")
    public static let slack = ProcessActivity(kind: .slack, title: "Slack")

    /// `acme/api#317` → `api#317`.
    public static func shortPR(_ prID: String) -> String {
        prID.split(separator: "/").last.map(String.init) ?? prID
    }

    public func on(host: String?) -> ProcessActivity {
        var copy = self
        copy.host = host
        return copy
    }
}
