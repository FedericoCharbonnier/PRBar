import Foundation

// Lógica de Core sobre los tipos que viven en PRBarWire.

extension PromptStage {
    public func validate(_ prompt: String) -> [PromptIssue] {
        let used = PlaceholderTemplate.names(in: prompt)
        let known = Set(variables.map(\.name))
        return requiredVariables.filter { !used.contains($0) }.map(PromptIssue.missing)
            + used.filter { !known.contains($0) }.map(PromptIssue.unknown)
    }

    public func isUsable(_ prompt: String) -> Bool { !validate(prompt).contains(where: \.blocks) }
}

extension RuleScope {
    /// It applies to `repo` (GitHub names don't distinguish case).
    public func covers(_ repo: RepoRef) -> Bool {
        switch self {
        case .global: true
        case .repo(let name): name.caseInsensitiveCompare(repo.fullName) == .orderedSame
        }
    }
}

extension RunnerHostInfo {
    /// La columna Status de Settings › Claude › Run On y de `prbar runners list`:
    /// "✓ Linux · claude 2.1.318 · logged in · 5 min ago" o "⚠ <el primer problema> · 5 min ago".
    public func statusSummary(now: Date = Date()) -> String {
        let age = RelativeAge.short(from: checkedAt, now: now)
        let when = age == "now" ? "just now" : "\(age) ago"
        if let problem = problems.first { return "⚠ \(problem) · \(when)" }
        var parts = [os ?? "?"]
        let version = claudeVersion?.split(separator: " ").first.map(String.init)
        parts.append(version.map { "claude \($0)" } ?? "claude ?")
        if claudeLoggedIn == true { parts.append("logged in") }
        parts.append(when)
        return "✓ " + parts.joined(separator: " · ")
    }
}

/// Los filtros de `prbar prs` (`listPRs`): `--list` por categoría, `--tab` por pestaña del popover y `--account`.
/// `--list other --tab mine` es Waiting for Review; `--list other --tab to-review`, el Other de To Review.
public enum PRListing {
    public static func filter(_ items: [ClassifiedPR], list: PRListFilter?, tab: PopoverTab?,
                              account: String?) -> [ClassifiedPR] {
        items
            .filter { item in list.map { item.category == $0.category } ?? true }
            .filter { item in tab.map { PopoverTabs.tab(of: item) == $0 } ?? true }
            .filter { item in account.map { item.account.caseInsensitiveCompare($0) == .orderedSame } ?? true }
    }
}

extension NotificationSettingName {
    public var keyPath: WritableKeyPath<NotificationSettings, Bool> {
        switch self {
        case .newToReview: \.newToReview
        case .reviewedUpdated: \.reviewedPRUpdated
        case .myFeedback: \.myPRFeedback
        case .reviewFinished: \.reviewFinished
        case .approvedOrCI: \.myPRApprovedOrCIFailed
        case .readyToMerge: \.readyToMerge
        }
    }
}

extension ToolName {
    public var keyPath: WritableKeyPath<ToolPaths, String?> {
        switch self {
        case .gh: \.gh
        case .git: \.git
        case .claude: \.claude
        }
    }
}

extension SlackToggleName {
    public var toggle: SlackToggle {
        switch self {
        case .announce: .announceNewPRs
        case .updated: .postUpdated
        case .merged: .postMerged
        case .reactStart: .reactOnReviewStart
        case .reactComment: .reactOnFirstComment
        case .rounds: .postRoundMessages
        case .reactApprove: .reactOnApprove
        }
    }
}

extension SlackEmojiKind {
    public var keyPath: WritableKeyPath<SlackSettings, String> {
        switch self {
        case .eyes: \.eyesEmoji
        case .comment: \.commentEmoji
        case .approved: \.approvedEmoji
        }
    }
}

extension SlackTemplateName {
    public var kind: SlackTemplateKind {
        switch self {
        case .newPR: .newPR
        case .update: .update
        case .round: .round
        case .merged: .merged
        }
    }
}

extension RespondSelectionChange {
    public func apply(to selection: inout RespondSelection) {
        if let implement { selection.implement = implement }
        if let reply { selection.reply = reply }
        if let replyText {
            selection.replyText = replyText
            if reply != false { selection.reply = true }
        }
        if let fixPlan { selection.fixPlan = fixPlan }
    }
}
