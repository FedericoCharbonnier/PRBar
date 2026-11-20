import Foundation
import PRBarWire

/// Qué se puede pedir desde el teléfono (spec P.7). Cada `AppCommand.Name` está clasificado en un `switch` sin
/// `default`: un comando nuevo no compila hasta que alguien decide. Por defecto, en la duda, se deniega.
public enum RemotePolicy {
    public enum Class: Equatable, Sendable {
        case allowed
        /// Pide Face ID (atestación de presencia, P.8).
        case gated
        case denied
        /// Lo decide `decide(_:)` mirando los argumentos (`reviewPublish`: approve es gated).
        case dependsOnArguments
    }

    public enum Decision: Equatable, Sendable {
        case allowed, gated, denied
    }

    public static let deniedMessage = "This can’t be done from iPhone. Use PRBar on your Mac."
    public static let presenceRequiredMessage = "Face ID is required for this on iPhone."

    public static func classify(_ name: AppCommand.Name) -> Class {
        switch name {
        // Lectura
        case .status, .listPRs, .resolvePR, .history, .historyShow, .reviewShow, .respondShow, .respondDiff,
             .mergePreview, .chatShow, .resources, .usage, .ciList, .notifyList:
            return .allowed
        // Acciones (sin secretos, rutas ni destinos)
        case .refresh, .reviewStart, .reviewEdit, .reviewSetIncluded, .reviewSetComment, .reviewCancel,
             .reviewDismiss, .respondStart, .respondSelect, .respondReset, .respondImplement, .respondTest,
             .respondReplyOnly, .respondCancel, .respondDismiss, .mergeDismiss, .chatSend, .chatUndo, .chatStop,
             .notifySet, .notifySetEnabled, .ciFix:
            return .allowed
        // Face ID (`prbar ci push [--anyway]` es `respondPush`/`respondPushAnyway`: también gated)
        case .merge, .respondPush, .respondPushAnyway:
            return .gated
        case .reviewPublish:
            return .dependsOnArguments
        // Ventanas y app, cuentas y repos, herramientas, Slack, actualizaciones, destinos SSH, reglas, Claude, prompts,
        // limpieza y ajustes de la Mac: nada de eso desde el teléfono.
        case .historyReopen, .open, .openSettings, .openHistory, .quit, .configShow, .setRefreshInterval,
             .setLaunchAtLogin, .accountList, .accountSetEnabled, .accountReload, .repoList, .repoAvailable, .repoAdd,
             .repoRemove, .repoSet, .repoBranches, .followList, .followAdd, .followRemove, .followSuggestions,
             .claudeShow, .claudeSet, .claudeReset, .claudeSkills, .toolsList, .toolsSet, .slackShow,
             .slackSetEnabled, .slackSetProvider, .slackTokenSet, .slackTokenClear, .slackSetToggle, .slackSetEmoji,
             .slackSetSearchDays, .slackTemplateList, .slackTemplateSet, .slackTemplateReset, .slackCheck,
             .slackSelfTest, .slackChannels, .updateCheck, .updateInstall, .updateCancel, .updateSkip,
             .setUpdateInterval, .rulesList, .rulesAdd, .rulesEdit, .rulesRemove, .rulesSetEnabled, .rulesChatSend,
             .rulesChatShow, .rulesChatUndo, .rulesChatStop, .rulesSuggestions, .rulesSuggestionAct, .chatProposal,
             .claudeReviewSet, .claudeRespondSet, .claudeStageSet, .claudePromptShow, .claudePromptSet,
             .claudePromptReset, .openPopover, .cleanupPreview, .cleanup, .setDiskWarning, .runnersList, .runnerAdd,
             .runnerSet, .runnerRemove, .runnerTest, .runnerDefault:
            return .denied
        }
    }

    public static func decide(_ command: AppCommand) -> Decision {
        switch classify(command.name) {
        case .allowed: return .allowed
        case .gated: return .gated
        case .denied: return .denied
        case .dependsOnArguments:
            if case .reviewPublish(_, let event, _, _, _, _) = command {
                return event == .approve ? .gated : .allowed
            }
            return .denied
        }
    }

    /// Los comandos que pueden pedir Face ID (para `presencePolicy`): los gated y los que lo son según los argumentos.
    public static var gatedNames: [AppCommand.Name] {
        AppCommand.Name.allCases.filter { [.gated, .dependsOnArguments].contains(classify($0)) }
    }
}
