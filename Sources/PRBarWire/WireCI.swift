import Foundation

// Las hojas de Fix CI (spec K) que viajan en `RespondInfo`; el resto de los checks queda en Core.

/// Qué hace una corrida de "Responder" (spec K.6.1): responder el feedback de un review o arreglar el CI.
public enum RespondMode: String, Codable, CaseIterable, Sendable {
    case feedback
    case ciFix
    /// Resolve Conflicts (spec C): mergea la base y Claude resuelve los conflictos.
    case conflicts
}

/// Un check que falló, como lo guarda el Fix CI (spec K.6.2). El log ya saneado va en el ítem, no acá.
public struct CICheckFailure: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var conclusion: String
    public var appName: String?
    public var detailsURL: URL?
    /// Se le pasó a Claude el log del job (Actions); si no, solo el resumen del check.
    public var hasLog: Bool
    /// Cuánto tardó el check (de `started_at` a `completed_at`), si GitHub lo dijo.
    public var durationSeconds: Double?
    /// Las últimas líneas del log ya saneado (como mucho `logExcerptLines`), para mostrar dónde falló.
    public var logExcerpt: [String]?

    public static let logExcerptLines = 8

    public init(id: String, name: String, conclusion: String, appName: String?, detailsURL: URL?, hasLog: Bool,
                durationSeconds: Double? = nil, logExcerpt: [String]? = nil) {
        self.id = id
        self.name = name
        self.conclusion = conclusion
        self.appName = appName
        self.detailsURL = detailsURL
        self.hasLog = hasLog
        self.durationSeconds = durationSeconds
        self.logExcerpt = logExcerpt
    }
}
