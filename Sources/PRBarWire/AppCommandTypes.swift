import Foundation

/// `prbar prs --list`.
public enum PRListFilter: String, Codable, CaseIterable, Sendable {
    case toReview = "to-review", updated, mine
    case readyToMerge = "ready-to-merge"
    case other

    public var category: PRCategory {
        switch self {
        case .toReview: .toReview
        case .updated: .updatedSinceMyReview
        case .mine: .myFeedback
        case .readyToMerge: .readyToMerge
        case .other: .other
        }
    }
}

public enum HistoryKind: String, Codable, CaseIterable, Sendable {
    case review, respond, merge
    /// Fix CI (spec K): a Respond run in CI mode.
    case ciFix = "ci-fix"
}

/// `prbar open <pr> --…`.
public enum OpenTarget: String, Codable, CaseIterable, Sendable {
    /// El PR en el navegador.
    case browser
    /// Ventana de Review (listo o publicado).
    case review
    /// Ventana de Responder.
    case respond
    /// La review publicada, en el navegador.
    case posted
    /// El worktree de Responder, en Finder.
    case worktree
    /// La ventana de Merge de un PR propio en Ready to Merge (spec G.5).
    case merge
}

/// Las pestañas de Configuración (`SettingsWindow.Tab`).
public enum SettingsTabName: String, Codable, CaseIterable, Sendable {
    case general, claude, instructions, accounts, repos, slack, iphone
}

/// Where "Terminal" opens Claude's session of a PR (Settings › General, spec T.6).
public enum TerminalChoice: String, Codable, CaseIterable, Sendable {
    case terminal, iterm, warp, ghostty, orca, custom

    public var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .warp: "Warp"
        case .ghostty: "Ghostty"
        case .orca: "Orca"
        case .custom: "Custom"
        }
    }
}

public enum NotificationSettingName: String, Codable, CaseIterable, Sendable {
    case newToReview = "new-to-review"
    case reviewedUpdated = "reviewed-updated"
    case myFeedback = "my-feedback"
    case reviewFinished = "review-finished"
    case approvedOrCI = "approved-or-ci"
    case readyToMerge = "ready-to-merge"

}

public enum ToolName: String, Codable, CaseIterable, Sendable {
    case gh, git, claude

}

/// `prbar slack set <toggle>`: los interruptores de la pestaña Slack.
public enum SlackToggleName: String, Codable, CaseIterable, Sendable {
    case announce, updated, merged
    case reactStart = "react-start"
    case reactComment = "react-comment"
    case rounds
    case reactApprove = "react-approve"

}

public enum SlackEmojiKind: String, Codable, CaseIterable, Sendable {
    case eyes, comment, approved

}

public enum SlackTemplateName: String, Codable, CaseIterable, Sendable {
    case newPR = "new-pr", update, round, merged

}

/// Cambiar un valor opcional: ponerle uno o sacarlo (`--path none`, `--model default`).
public enum ValueChange: Codable, Equatable, Sendable {
    case set(value: String)
    case clear

    public var value: String? {
        if case .set(let value) = self { return value }
        return nil
    }
}

/// `prbar repo set`. `nil` = no se toca.
public struct RepoChanges: Codable, Equatable, Sendable {
    public var localPath: ValueChange?
    public var worktreeDir: ValueChange?
    public var testCommand: ValueChange?
    /// Reemplaza la lista entera (`--branches a,b`; vacía = la rama por defecto).
    public var baseBranches: [String]?
    public var addBranches: [String]
    public var removeBranches: [String]
    /// `#nombre` o id del canal; `.clear` = sin anuncios.
    public var channel: ValueChange?
    /// Globs cuyos hallazgos se ocultan en los reviews de este repo (spec E.5).
    public var addIgnore: [String]
    public var removeIgnore: [String]
    /// `squash`, `merge` o `rebase` (spec F.5); `.clear` = el de GitHub.
    public var mergeMethod: ValueChange?
    /// `local`, el nombre de un destino SSH, o `.clear` = "Default" (spec J.1).
    public var runOn: ValueChange?

    public init(localPath: ValueChange? = nil, worktreeDir: ValueChange? = nil, testCommand: ValueChange? = nil,
                baseBranches: [String]? = nil, addBranches: [String] = [], removeBranches: [String] = [],
                channel: ValueChange? = nil, addIgnore: [String] = [], removeIgnore: [String] = [],
                mergeMethod: ValueChange? = nil, runOn: ValueChange? = nil) {
        self.localPath = localPath
        self.worktreeDir = worktreeDir
        self.testCommand = testCommand
        self.baseBranches = baseBranches
        self.addBranches = addBranches
        self.removeBranches = removeBranches
        self.channel = channel
        self.addIgnore = addIgnore
        self.removeIgnore = removeIgnore
        self.mergeMethod = mergeMethod
        self.runOn = runOn
    }

    public var isEmpty: Bool { self == RepoChanges() }
    public var changesBranches: Bool { baseBranches != nil || !addBranches.isEmpty || !removeBranches.isEmpty }
}

/// `prbar claude set`. `nil` = no se toca; `model: .clear` = el modelo por defecto de Claude Code;
/// `chatModel: .clear` = el mismo modelo del review.
public struct ClaudeChanges: Codable, Equatable, Sendable {
    public var reviewSkill: String?
    public var filterEnabled: Bool?
    public var filterSkill: String?
    public var respondSkill: String?
    public var model: ValueChange?
    public var chatEnabled: Bool?
    public var chatModel: ValueChange?

    public init(reviewSkill: String? = nil, filterEnabled: Bool? = nil, filterSkill: String? = nil,
                respondSkill: String? = nil, model: ValueChange? = nil, chatEnabled: Bool? = nil,
                chatModel: ValueChange? = nil) {
        self.reviewSkill = reviewSkill
        self.filterEnabled = filterEnabled
        self.filterSkill = filterSkill
        self.respondSkill = respondSkill
        self.model = model
        self.chatEnabled = chatEnabled
        self.chatModel = chatModel
    }

    public var isEmpty: Bool { self == ClaudeChanges() }
}

/// `prbar respond select`: qué cambiar de la decisión de cada comentario. Se aplica en este orden: `implement`,
/// `reply`, `replyText` (que enciende "Reply", salvo que `reply` sea `false`) y `fixPlan`.
public struct RespondSelectionChange: Codable, Equatable, Sendable {
    public var implement: Bool?
    public var reply: Bool?
    public var replyText: String?
    public var fixPlan: String?

    public init(implement: Bool? = nil, reply: Bool? = nil, replyText: String? = nil, fixPlan: String? = nil) {
        self.implement = implement
        self.reply = reply
        self.replyText = replyText
        self.fixPlan = fixPlan
    }

    public var isEmpty: Bool { self == RespondSelectionChange() }

}

// MARK: - Instrucciones, opciones y prompts (spec E.7)

/// Las sugerencias de reglas (E.4): "Create Rule", "Not Now" y "Never".
public enum SuggestionAction: String, Codable, CaseIterable, Sendable {
    case accept, dismiss, never
}

extension PromptStage {
    /// El nombre en la CLI: `review`, `filter`, `analysis`, `implementation`, `chat-review`, `chat-respond`,
    /// `chat-merge`, `chat-instructions`, `ci-fix`.
    public var cliName: String {
        switch self {
        case .ciFix: "ci-fix"
        case .reviewChat: "chat-review"
        case .respondChat: "chat-respond"
        case .mergeChat: "chat-merge"
        case .instructionsChat: "chat-instructions"
        case .review, .filter, .analysis, .implementation: rawValue
        }
    }

    public init?(cliName: String) {
        guard let stage = Self.allCases.first(where: { $0.cliName == cliName }) else { return nil }
        self = stage
    }
}

/// `prbar claude stage <stage>`: la etapa usa un skill, un prompt propio o vuelve a lo de fábrica.
public enum StageChange: Codable, Equatable, Sendable {
    case skill(name: String)
    case prompt(text: String)
    case useDefault
}

/// `prbar claude review set` (E.5). `nil` = no se toca.
public struct ReviewOptionChanges: Codable, Equatable, Sendable {
    public var minSeverity: Severity?
    /// Entero ≥ 1; `.clear` = sin máximo. Lo valida la app.
    public var maxFindings: ValueChange?
    public var addIgnore: [String]
    public var removeIgnore: [String]
    /// Por `FindingCategory.rawValue` (lo valida la app).
    public var categories: [String: Bool]
    public var tone: ReviewTone?

    public init(minSeverity: Severity? = nil, maxFindings: ValueChange? = nil, addIgnore: [String] = [],
                removeIgnore: [String] = [], categories: [String: Bool] = [:], tone: ReviewTone? = nil) {
        self.minSeverity = minSeverity
        self.maxFindings = maxFindings
        self.addIgnore = addIgnore
        self.removeIgnore = removeIgnore
        self.categories = categories
        self.tone = tone
    }

    public var isEmpty: Bool { self == ReviewOptionChanges() }
}

/// `prbar claude respond set` (E.5). `nil` = no se toca.
public struct RespondOptionChanges: Codable, Equatable, Sendable {
    public var runTestsBeforePush: Bool?
    public var commitMode: CommitMode?
    /// `.clear` = el mensaje de commit por defecto.
    public var commitMessageTemplate: ValueChange?
    public var allowNewTests: Bool?
    public var allowNewDependencies: Bool?
    /// `.clear` = el "Fixed in …" por defecto.
    public var replyTemplate: ValueChange?

    public init(runTestsBeforePush: Bool? = nil, commitMode: CommitMode? = nil, commitMessageTemplate: ValueChange? = nil,
                allowNewTests: Bool? = nil, allowNewDependencies: Bool? = nil, replyTemplate: ValueChange? = nil) {
        self.runTestsBeforePush = runTestsBeforePush
        self.commitMode = commitMode
        self.commitMessageTemplate = commitMessageTemplate
        self.allowNewTests = allowNewTests
        self.allowNewDependencies = allowNewDependencies
        self.replyTemplate = replyTemplate
    }

    public var isEmpty: Bool { self == RespondOptionChanges() }
}
