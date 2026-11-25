import Foundation

// Las hojas de Resolve Conflicts (spec C) que viajan en `RespondInfo`.

/// Un archivo en conflicto después de `merge --no-commit` (spec C.3.2, decisión C.9.3).
public struct ConflictFile: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Los dos lados cambiaron el texto: lo resuelve Claude.
        case content
        /// Borrado/modificado, renombre, binario, symlink, submódulo o un archivo de git: PRBar deja la versión del PR
        /// y el usuario lo resuelve a mano.
        case byHand
    }

    public var path: String
    public var kind: Kind
    /// Por qué es `byHand` ("deleted in the base", "binary"…); nil para `content`.
    public var reason: String?

    public var id: String { path }

    public init(path: String, kind: Kind, reason: String? = nil) {
        self.path = path
        self.kind = kind
        self.reason = reason
    }
}

/// Lo que guarda el draft de un Resolve Conflicts.
public struct ConflictsContext: Codable, Equatable, Sendable {
    /// La rama base del PR que se mergeó.
    public var baseRef: String
    /// El commit de la base que se mergeó: el segundo padre del commit de merge.
    public var baseOid: String
    /// `merge-base` del head del PR y `baseOid`.
    public var mergeBase: String
    public var files: [ConflictFile]
    /// Cuántos commits de la base entran (`mergeBase..baseOid`).
    public var incomingCommits: Int

    public init(baseRef: String, baseOid: String, mergeBase: String, files: [ConflictFile], incomingCommits: Int) {
        self.baseRef = baseRef
        self.baseOid = baseOid
        self.mergeBase = mergeBase
        self.files = files
        self.incomingCommits = incomingCommits
    }

    public var contentFiles: [String] { files.filter { $0.kind == .content }.map(\.path) }
    public var byHandFiles: [ConflictFile] { files.filter { $0.kind == .byHand } }

    /// El mensaje del commit de merge (decisión C.9.12): fijo, nunca de Claude.
    public func commitMessage(headRef: String) -> String { "Merge \(baseRef) into \(headRef)" }
}

/// Cómo resolvió Claude un archivo (spec C.3.3), ya saneado.
public struct ConflictFileSummary: Codable, Equatable, Sendable {
    public var path: String
    public var summary: String

    public init(path: String, summary: String) {
        self.path = path
        self.summary = summary
    }
}
