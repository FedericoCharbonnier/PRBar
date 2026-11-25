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
        /// Lo decide `decide(_:)` mirando los argumentos (`remoteSetPresenceRequirement`: apagarlo es gated).
        case dependsOnArguments
    }

    public enum Decision: Equatable, Sendable {
        case allowed, gated, denied
    }

    public static let deniedMessage = "This can’t be done from iPhone. Use PRBar on your Mac."
    public static let presenceRequiredMessage = "Face ID is required for this on iPhone."
    /// El teléfono se emparejó sin passkey (W.4.6): nada gated hasta volver a emparejarlo.
    public static let presenceNotSetUpMessage = "Face ID isn't set up on this device. Pair it again."

    public static func classify(_ name: AppCommand.Name) -> Class {
        switch name {
        // Lectura
        case .status, .listPRs, .resolvePR, .history, .historyShow, .reviewShow, .respondShow, .respondDiff,
             .mergePreview, .chatShow, .resources, .usage, .ciList, .notifyList:
            return .allowed
        // Acciones (sin secretos, rutas ni destinos)
        case .refresh, .reviewStart, .reviewEdit, .reviewSetIncluded, .reviewSetComment, .reviewCancel,
             .reviewDismiss, .respondStart, .respondSelect, .respondReset, .respondImplement,
             .respondCancel, .respondDismiss, .mergeDismiss, .chatSend, .chatUndo, .chatStop,
             .notifySet, .notifySetEnabled, .ciFix:
            return .allowed
        // Face ID (`prbar ci push [--anyway]` es `respondPush`/`respondPushAnyway`: también gated). `respondTest` corre
        // el comando de tests del repo en el worktree que Claude pudo cambiar (decisión H1): ejecuta código en la Mac.
        // Todo lo que publica en GitHub como el usuario también: cualquier review (comment, request changes, approve),
        // las respuestas solas y el push (que publica las respuestas). Editar el borrador (`respondSelect`, el texto de
        // una respuesta) no publica nada: lo publica después un push o `respondReplyOnly`, que piden Face ID.
        case .merge, .respondPush, .respondPushAnyway, .respondTest, .reviewPublish, .respondReplyOnly:
            return .gated
        case .remoteSetPresenceRequirement:
            return .dependsOnArguments
        // Ventanas y app, cuentas y repos, herramientas, Slack, actualizaciones, destinos SSH, reglas, Claude, prompts,
        // limpieza y ajustes de la Mac: nada de eso desde el teléfono.
        case .historyReopen, .open, .openSettings, .openHistory, .quit, .configShow, .setRefreshInterval,
             .setLaunchAtLogin, .setAlwaysShowInDock, .accountList, .accountSetEnabled, .accountReload, .repoList, .repoAvailable, .repoAdd,
             // La terminal de las sesiones de Claude: el comando propio corre en la Mac (spec T.6).
             .setTerminal, .setTerminalCommand, .setKeepSessionFolders,
             // Abre una terminal en la Mac (spec T.4).
             .sessionList, .sessionOpen,
             .repoRemove, .repoSet, .repoBranches, .followList, .followAdd, .followRemove, .followSuggestions,
             .claudeShow, .claudeSet, .claudeReset, .claudeSkills, .toolsList, .toolsSet, .slackShow,
             .slackSetEnabled, .slackSetProvider, .slackTokenSet, .slackTokenClear, .slackSetToggle, .slackSetEmoji,
             .slackSetSearchDays, .slackTemplateList, .slackTemplateSet, .slackTemplateReset, .slackCheck,
             .slackSelfTest, .slackChannels, .updateCheck, .updateInstall, .updateCancel, .updateSkip,
             .setUpdateInterval, .rulesList, .rulesAdd, .rulesEdit, .rulesRemove, .rulesSetEnabled, .rulesChatSend,
             .rulesChatShow, .rulesChatUndo, .rulesChatStop, .rulesSuggestions, .rulesSuggestionAct, .chatProposal,
             // Resolve Conflicts (decisión C.9.9): solo desde la Mac.
             .conflictsList, .conflictsResolve,
             .claudeReviewSet, .claudeRespondSet, .claudeStageSet, .claudePromptShow, .claudePromptSet,
             .claudePromptReset, .openPopover, .cleanupPreview, .cleanup, .setDiskWarning, .runnersList, .runnerAdd,
             .runnerSet, .runnerRemove, .runnerTest, .runnerDefault,
             // El acceso remoto se maneja desde la Mac (salvo Face ID del propio teléfono, arriba).
             .remoteStatus, .remoteEnable, .remoteDisable, .remotePairStart, .remotePairWait, .remotePairConfirm,
             .remoteDevices, .remoteRevoke, .remoteSetKeepAwake, .remoteReset, .remoteSetMailbox:
            return .denied
        }
    }

    public static func decide(_ command: AppCommand) -> Decision {
        switch classify(command.name) {
        case .allowed: return .allowed
        case .gated: return .gated
        case .denied: return .denied
        case .dependsOnArguments:
            switch command {
            case .remoteSetPresenceRequirement(_, let enabled):
                // Prenderlo no; apagarlo es en sí gated (spec P.8, revisión L5).
                return enabled ? .allowed : .gated
            default:
                return .denied
            }
        }
    }

    /// Los comandos que pueden terminar ejecutando código del repo en la Mac (decisión H1): el comando de tests y el
    /// push (corre los hooks de git del usuario y, con "Run tests before pushing", los tests). Todos son gated; la Mac
    /// además lo vuelve a mirar con `CommandOrigin` en el lugar donde se ejecuta. Implementar, el chat, Undo y Fix CI
    /// solo editan (Claude no tiene `Bash`) y nunca corren los tests solos.
    public static let runsRepoCode: Set<AppCommand.Name> = [.respondTest, .respondPush, .respondPushAnyway]

    /// Los comandos que pueden pedir Face ID (para `presencePolicy`): los gated y los que lo son según los argumentos.
    public static var gatedNames: [AppCommand.Name] {
        AppCommand.Name.allCases.filter { [.gated, .dependsOnArguments].contains(classify($0)) }
    }
}
