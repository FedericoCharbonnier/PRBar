import Foundation

/// Actualizaciones desde los GitHub Releases (spec D.2): `config.json` → `"updates"`.
public struct UpdateSettings: Hashable, Codable, Sendable {
    public static let defaultRepo = "FedericoCharbonnier/PRBar"
    public static let defaultCheckIntervalHours = 24
    /// Las opciones del selector de Settings › General (horas).
    public static let intervalChoices = [6, 12, 24, 168]

    /// `owner/name` del repo de donde salen los releases. Un fork lo cambia en `config.json`.
    public var repo = Self.defaultRepo
    /// Cada cuántas horas se chequea solo; 0 = solo a mano.
    public var checkIntervalHours = Self.defaultCheckIntervalHours
    /// Último chequeo que salió bien (automático o manual).
    public var lastCheckAt: Date?
    /// Última versión de la que se mandó notificación: se avisa una sola vez por versión.
    public var notifiedVersion: String?
    /// Versión que el usuario eligió saltear: no se vuelve a ofrecer sola hasta que salga otra.
    public var skippedVersion: String?

    public init() {}

    enum CodingKeys: String, CodingKey { case repo, checkIntervalHours, lastCheckAt, notifiedVersion, skippedVersion }

    /// Tolerante: una clave que falta o tiene otro tipo cae al default; un intervalo negativo es 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = (try? c.decodeIfPresent(String.self, forKey: .repo)) ?? Self.defaultRepo
        checkIntervalHours = max(0, (try? c.decodeIfPresent(Int.self, forKey: .checkIntervalHours)) ?? Self.defaultCheckIntervalHours)
        lastCheckAt = (try? c.decodeIfPresent(Date.self, forKey: .lastCheckAt)) ?? nil
        notifiedVersion = (try? c.decodeIfPresent(String.self, forKey: .notifiedVersion)) ?? nil
        skippedVersion = (try? c.decodeIfPresent(String.self, forKey: .skippedVersion)) ?? nil
    }

    public var checksAutomatically: Bool { checkIntervalHours > 0 }

    /// El switch "Check automatically": apagar es 0; prender vuelve a 24 h si estaba apagado.
    public mutating func setAutomaticChecks(_ on: Bool) {
        if !on {
            checkIntervalHours = 0
        } else if checkIntervalHours <= 0 {
            checkIntervalHours = Self.defaultCheckIntervalHours
        }
    }

    /// `repo` sin espacios alrededor si es un `owner/name` válido; si no, el default.
    public var effectiveRepo: String {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isValidRepo(trimmed) ? trimmed : Self.defaultRepo
    }

    /// Dos partes `[A-Za-z0-9._-]`, ninguna vacía ni empezando con `.` o `-` (va en una URL y en `git clone`).
    public static func isValidRepo(_ repo: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && !part.hasPrefix(".") && !part.hasPrefix("-") && part.allSatisfy { allowed.contains($0) }
        }
    }
}
