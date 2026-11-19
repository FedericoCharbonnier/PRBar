import Foundation

/// Resultado de un chequeo, tal como lo ven la UI y la CLI (`prbar update --check`, Plan 7).
public enum UpdateCheckOutcome: Codable, Equatable, Sendable {
    case upToDate(installed: SemanticVersion)
    /// Hay una versión mayor que la instalada (aunque esté salteada).
    case available(ReleaseInfo)
    case failed(String)
}

/// Todo lo que deja un chequeo: qué mostrar, qué notificar y qué guardar en la config.
public struct UpdateCheckReport: Equatable, Sendable {
    public var outcome: UpdateCheckOutcome
    /// La versión que se ofrece en el popover y Settings (`nil` = ninguna). Si el chequeo falló es `nil` y la UI
    /// conserva lo que ofrecía antes.
    public var offered: ReleaseInfo?
    public var notification: PlannedNotification?
    /// Error para mostrar: solo en el chequeo manual (el automático solo lo loguea).
    public var visibleError: String?
    /// `lastCheckAt` y `notifiedVersion` actualizados.
    public var settings: UpdateSettings
}

/// Decisiones puras del chequeo de actualizaciones (spec D.2).
public enum UpdatePolicy {
    /// Chequeo automático: si está prendido y pasó el intervalo (o nunca se chequeó, o el reloj volvió para atrás).
    public static func isCheckDue(_ settings: UpdateSettings, now: Date) -> Bool {
        guard settings.checksAutomatically else { return false }
        guard let last = settings.lastCheckAt, last <= now else { return true }
        return now.timeIntervalSince(last) >= TimeInterval(settings.checkIntervalHours) * 3600
    }

    /// La versión a ofrecer: mayor que la instalada y, salvo en el chequeo manual, no salteada.
    public static func offer(latest: ReleaseInfo?, installed: SemanticVersion, settings: UpdateSettings, manual: Bool) -> ReleaseInfo? {
        guard let latest, latest.version > installed else { return nil }
        if !manual, let skipped = settings.skippedVersion.flatMap({ SemanticVersion($0) }), skipped == latest.version {
            return nil
        }
        return latest
    }
}

extension UpdateChecker {
    /// Chequea y decide. Nunca lanza: un error vuelve como `.failed` (y en `visibleError` si es manual).
    public func check(
        installed: SemanticVersion, settings: UpdateSettings, notifications: NotificationSettings, manual: Bool, now: Date
    ) async -> UpdateCheckReport {
        var next = settings
        do {
            let latest = try await latestRelease()
            next.lastCheckAt = now
            let outcome: UpdateCheckOutcome
            if let latest, latest.version > installed {
                outcome = .available(latest)
            } else {
                outcome = .upToDate(installed: installed)
            }
            let offered = UpdatePolicy.offer(latest: latest, installed: installed, settings: settings, manual: manual)
            var notification: PlannedNotification?
            if !manual, let offered, settings.notifiedVersion.flatMap({ SemanticVersion($0) }) != offered.version,
               let planned = NotificationPlanner.updateAvailable(offered, settings: notifications) {
                notification = planned
                next.notifiedVersion = offered.version.description
            }
            return UpdateCheckReport(outcome: outcome, offered: offered, notification: notification, visibleError: nil, settings: next)
        } catch {
            let message = "Couldn't check for updates: \(error.localizedDescription)"
            AppLog.write(message)
            return UpdateCheckReport(outcome: .failed(message), offered: nil, notification: nil,
                                     visibleError: manual ? message : nil, settings: next)
        }
    }
}
