import Foundation
import PRBarCore

/// `prbar rules …`, `prbar claude review|respond set`, `prbar claude stage` y `prbar claude prompt …` (spec E.7): los
/// mismos métodos que Settings › Instructions, Settings › Claude y las tarjetas "Save as rule" del chat del PR.
extension AppModel: InstructionCommandActions {
    // MARK: Reglas

    /// Los errores de las reglas con el código de salida que corresponde y el comando que ayuda.
    private func ruleFailure(_ error: Error) -> Error {
        guard let error = error as? RuleError else { return error }
        let message = error.errorDescription ?? "\(error)"
        switch error {
        case .emptyText, .tooLong, .noStage: return CommandFailure(.invalidUsage, message)
        case .unknownRepo: return CommandFailure(.notFound, "\(message) Run `prbar repo list`.")
        case .notFound: return CommandFailure(.notFound, "\(message) Run `prbar rules list`.")
        case .unavailable: return CommandFailure(.failed, message)
        }
    }

    private func ruling<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw ruleFailure(error)
        }
    }

    /// El id completo o un prefijo único de 4 caracteres o más (como `history show`), sin distinguir mayúsculas.
    private func rule(_ id: String) throws -> Rule {
        let wanted = id.lowercased()
        if let exact = rules.first(where: { $0.id.uuidString.lowercased() == wanted }) { return exact }
        guard wanted.count >= 4 else {
            throw CommandFailure(.invalidUsage, "Use the rule’s id or its first 4+ characters (`prbar rules list`).")
        }
        let matches = rules.filter { $0.id.uuidString.lowercased().hasPrefix(wanted) }
        guard let first = matches.first else {
            throw CommandFailure(.notFound, "There’s no rule \(id). Run `prbar rules list`.")
        }
        guard matches.count == 1 else { throw CommandFailure(.invalidUsage, "\(id) matches several rules: use more characters.") }
        return first
    }

    /// Un repo configurado, con el nombre guardado.
    private func ruleRepo(_ name: String) throws -> String {
        guard let repo = configuredRepos.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw CommandFailure(.notFound, "\(name) isn’t one of your repos. Run `prbar repo list`.")
        }
        return repo
    }

    /// Sin `repo`, todas (como la pestaña Instructions); con `repo`, las que se aplican a sus PRs (las globales y las
    /// del repo).
    func rulesList(repo: String?) throws -> [RuleInfo] {
        guard let repo else { return rules.map(RuleInfo.init(rule:)) }
        let name = try ruleRepo(repo)
        guard let ref = RepoRef(fullName: name) else { throw CommandFailure(.invalidUsage, "Use owner/repo.") }
        return rules.filter { $0.scope.covers(ref) }.map(RuleInfo.init(rule:))
    }

    func rulesAdd(text: String, scope: RuleScope, appliesTo: [RuleStage]) throws -> RuleInfo {
        RuleInfo(rule: try ruling { try addRule(text, scope: scope, appliesTo: Set(appliesTo)) })
    }

    func rulesEdit(id: String, text: String?, scope: RuleScope?, appliesTo: [RuleStage]?) throws -> RuleInfo {
        let current = try rule(id)
        guard text != nil || scope != nil || appliesTo != nil else {
            throw CommandFailure(.invalidUsage, "Nothing to change. See `prbar rules edit --help`.")
        }
        try ruling { try editRule(current.id, text: text, scope: scope, appliesTo: appliesTo.map(Set.init)) }
        return RuleInfo(rule: try rule(current.id.uuidString))
    }

    func rulesRemove(id: String) throws {
        let current = try rule(id)
        try ruling { try removeRule(current.id) }
    }

    func rulesSetEnabled(id: String, enabled: Bool) throws {
        let current = try rule(id)
        try ruling { try setRuleEnabled(current.id, enabled) }
    }

    // MARK: Chat de instrucciones

    private func instructionsChatInfo(streamed: Bool = false) -> ChatInfo {
        let chat = instructionsChat
        return ChatInfo(pr: "", kind: "instructions", messages: chat.chat.messages, undoableMessageID: chat.chat.undoableMessageID,
                        canUndo: chat.canUndo, readOnly: false, running: chat.isRunning, lockReason: nil, streamed: streamed,
                        number: { _ in nil })
    }

    func rulesChatSend(message: String, events: CommandEventSink) async throws -> ChatInfo {
        if let reason = chatUnavailableReason { throw CommandFailure(.invalidState, reason) }
        let chat = instructionsChat
        if chat.isRunning { throw CommandFailure(.invalidState, "Claude is still answering. Wait, or stop it with `prbar rules chat --stop`.") }
        guard chat.send(message) else { throw CommandFailure(.invalidUsage, "Write a message.") }
        let streamed = try await streamTurn(isRunning: { chat.isRunning }, partial: { chat.partialText },
                                            activity: { chat.activity }, events: events)
        return instructionsChatInfo(streamed: streamed)
    }

    func rulesChatShow() -> ChatInfo {
        instructionsChatInfo()
    }

    func rulesChatUndo(confirmed: Bool) async throws -> ChatInfo {
        let chat = instructionsChat
        guard chat.canUndo, let message = chat.chat.undoableMessageID else {
            throw CommandFailure(.invalidState, "There’s nothing to undo.")
        }
        if !confirmed, chat.undoDiscardsLaterEdits(message) {
            throw CommandFailure(.confirmationRequired, "Undo will also discard your edits to those rules since then.")
        }
        if let error = chat.undo(message) { throw CommandFailure(.failed, error) }
        return instructionsChatInfo()
    }

    func rulesChatStop() throws -> ChatInfo {
        guard instructionsChat.isRunning else { throw CommandFailure(.invalidState, "Claude isn’t answering anything.") }
        instructionsChat.stop()
        return instructionsChatInfo()
    }

    // MARK: Sugerencias y tarjetas "Save as rule"

    func rulesSuggestions() -> [RuleSuggestionInfo] {
        ruleSuggestions().map(RuleSuggestionInfo.init(suggestion:))
    }

    func rulesSuggestionAct(id: String, action: SuggestionAction, text: String?) throws -> [RuleInfo] {
        guard ruleSuggestions().contains(where: { $0.id == id }) else {
            throw CommandFailure(.notFound, "There’s no suggestion \(id). Run `prbar rules suggestions`.")
        }
        if text != nil && action != .accept { throw CommandFailure(.invalidUsage, "--text only goes with accept.") }
        try ruling {
            switch action {
            case .accept: _ = try acceptSuggestion(id, text: text)
            case .dismiss: try snoozeSuggestion(id)
            case .never: try neverSuggest(id)
            }
        }
        return try rulesList(repo: nil)
    }

    func chatProposal(pr: String, number: Int, save: Bool, text: String?, scope: RuleScope?, appliesTo: [RuleStage]?) throws -> ChatInfo {
        let id = try resolvePRID(pr)
        let chat = try chatCoordinator(id)
        var pending: [(message: UUID, proposal: RuleProposal)] = []
        for message in chat.session.messages {
            for proposal in message.proposals where proposal.status == .pending { pending.append((message.id, proposal)) }
        }
        guard number >= 1, number <= pending.count else {
            throw CommandFailure(.notFound, "There’s no pending rule #\(number) in \(id)’s chat. Run `prbar chat \(id) --show`.")
        }
        let (messageID, proposal) = pending[number - 1]
        if save {
            if let scope, case .repo(let name) = scope, name.caseInsensitiveCompare(chat.subject.repo.fullName) != .orderedSame {
                throw CommandFailure(.invalidUsage, "A rule from this chat is global or for \(chat.subject.repo.fullName).")
            }
            if let error = chat.saveProposal(proposal.id, in: messageID, text: text ?? proposal.text, scope: scope ?? proposal.scope,
                                             appliesTo: appliesTo.map(Set.init) ?? proposal.appliesTo) {
                throw CommandFailure(.invalidUsage, error)
            }
        } else {
            chat.dismissProposal(proposal.id, in: messageID)
        }
        return chatInfo(id, chat)
    }

    // MARK: Opciones del review y de los fixes

    func claudeReviewSet(changes: ReviewOptionChanges) throws -> ClaudeSettings {
        guard !changes.isEmpty else { throw CommandFailure(.invalidUsage, "Nothing to change. See `prbar claude review set --help`.") }
        var maxFindings: Int??
        if let change = changes.maxFindings {
            switch change {
            case .clear:
                maxFindings = .some(nil)
            case .set(let value):
                guard let limit = Int(value), (1...50).contains(limit) else {
                    throw CommandFailure(.invalidUsage, "--max-findings takes a number from 1 to 50, or none.")
                }
                maxFindings = .some(limit)
            }
        }
        let known = Set(FindingCategory.allCases.map(\.rawValue))
        if let unknown = changes.categories.keys.sorted().first(where: { !known.contains($0) }) {
            throw CommandFailure(.invalidUsage, "Unknown category \(unknown): use \(FindingCategory.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        if (changes.addIgnore + changes.removeIgnore).contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw CommandFailure(.invalidUsage, "A path pattern can’t be empty.")
        }
        let current = configStore.config.claude.review
        let addIgnore = ReviewOptions.normalizePatterns(changes.addIgnore)
        let removeIgnore = ReviewOptions.normalizePatterns(changes.removeIgnore)
        if let unknown = removeIgnore.first(where: { !current.ignorePaths.contains($0) }) {
            throw CommandFailure(.notFound, "\(unknown) isn’t an ignored path. Run `prbar claude show`.")
        }
        try applyConfig { config in
            var review = config.claude.review
            if let severity = changes.minSeverity { review.minSeverity = severity }
            if let maxFindings { review.maxFindings = maxFindings }
            var ignore = review.ignorePaths + addIgnore
            ignore.removeAll { removeIgnore.contains($0) }
            review.ignorePaths = ReviewOptions.normalizePatterns(ignore)
            for (name, on) in changes.categories {
                if let category = FindingCategory(rawValue: name) { review.setCategory(category, enabled: on) }
            }
            if let tone = changes.tone { review.tone = tone }
            config.claude.review = review
        }
        return configStore.config.claude
    }

    func claudeRespondSet(changes: RespondOptionChanges) throws -> ClaudeSettings {
        guard !changes.isEmpty else { throw CommandFailure(.invalidUsage, "Nothing to change. See `prbar claude respond set --help`.") }
        /// Como el editor de la plantilla: vacía = la de por defecto.
        func template(_ change: ValueChange) -> String? {
            guard let value = change.value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        try applyConfig { config in
            var respond = config.claude.respond
            if let on = changes.runTestsBeforePush { respond.runTestsBeforePush = on }
            if let mode = changes.commitMode { respond.commitMode = mode }
            if let change = changes.commitMessageTemplate { respond.commitMessageTemplate = template(change) }
            if let on = changes.allowNewTests { respond.allowNewTests = on }
            if let on = changes.allowNewDependencies { respond.allowNewDependencies = on }
            if let change = changes.replyTemplate { respond.replyTemplate = template(change) }
            config.claude.respond = respond
        }
        return configStore.config.claude
    }

    // MARK: Etapas y prompts

    private func promptFailure(_ stage: PromptStage, _ text: String) -> CommandFailure? {
        let blocking = stage.validate(text).filter(\.blocks)
        guard !blocking.isEmpty else { return nil }
        return CommandFailure(.invalidUsage, blocking.map(\.message).joined(separator: " "))
    }

    func claudeStageSet(stage: PromptStage, change: StageChange) throws -> ClaudeSettings {
        guard stage.hasSkill else {
            throw CommandFailure(.invalidUsage, "Chat prompts have no skill: use `prbar claude prompt edit \(stage.cliName)`.")
        }
        switch change {
        case .skill(let name):
            let none = name.lowercased() == "none"
            if none && stage != .implementation {
                throw CommandFailure(.invalidUsage, "Only the implementation can run without a skill.")
            }
            if !none && !ClaudeSettings.isValidSkill(name) {
                throw CommandFailure(.invalidUsage, "“\(name)” isn’t a valid skill: use plugin:skill or skill. See `prbar claude skills`.")
            }
            try applyConfig { config in
                config.claude.setSkill(none ? nil : name, for: stage)
                config.claude.setMode(.skill, for: stage)
            }
        case .prompt(let text):
            if let failure = promptFailure(stage, text) { throw failure }
            try applyConfig { $0.claude.setCustomPrompt(text, for: stage) }
        case .useDefault:
            try applyConfig { config in
                config.claude.resetPrompt(for: stage)
                config.claude.setSkill(nil, for: stage)
            }
        }
        return configStore.config.claude
    }

    private func promptInfo(_ stage: PromptStage) -> PromptInfo {
        let settings = configStore.config.claude
        let custom = settings.customPrompt(for: stage)
        return PromptInfo(stage: stage, text: custom ?? stage.defaultBody(skill: settings.skill(for: stage)),
                          isDefault: custom == nil, requiredVariables: stage.requiredVariables)
    }

    func claudePromptShow(stage: PromptStage) -> PromptInfo {
        promptInfo(stage)
    }

    /// "Save" en el editor del prompt: con una etapa con skill, la pasa a "Custom Prompt".
    func claudePromptSet(stage: PromptStage, text: String) throws -> PromptInfo {
        if let failure = promptFailure(stage, text) { throw failure }
        try applyConfig { $0.claude.setCustomPrompt(text, for: stage) }
        return promptInfo(stage)
    }

    /// "Reset to Default".
    func claudePromptReset(stage: PromptStage) throws -> PromptInfo {
        try applyConfig { $0.claude.resetPrompt(for: stage) }
        return promptInfo(stage)
    }
}
