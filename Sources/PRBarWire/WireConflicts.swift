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
    /// Decisión C.9.16: lo que dejó el merge automático (antes de Claude) en cada ruta que no es un archivo de
    /// contenido en conflicto y que difiere del head del PR (el resto quedó como en el head). Contra esto se buscan
    /// los cambios fuera de los conflictos. Nil en drafts anteriores (no se puede verificar).
    public var automaticMerge: [AutoMergeEntry]?

    public init(baseRef: String, baseOid: String, mergeBase: String, files: [ConflictFile], incomingCommits: Int,
                automaticMerge: [AutoMergeEntry]? = nil) {
        self.baseRef = baseRef
        self.baseOid = baseOid
        self.mergeBase = mergeBase
        self.files = files
        self.incomingCommits = incomingCommits
        self.automaticMerge = automaticMerge
    }

    public var contentFiles: [String] { files.filter { $0.kind == .content }.map(\.path) }
    public var byHandFiles: [ConflictFile] { files.filter { $0.kind == .byHand } }

    /// El mensaje del commit de merge (decisión C.9.12): fijo, nunca de Claude.
    public func commitMessage(headRef: String) -> String { "Merge \(baseRef) into \(headRef)" }
}

/// Una entrada del índice (etapa 0) que dejó el merge automático: modo y blob; `nil` los dos = la ruta no está
/// (el merge la borró).
public struct AutoMergeEntry: Codable, Equatable, Sendable {
    public var path: String
    public var mode: String?
    public var oid: String?

    public init(path: String, mode: String?, oid: String?) {
        self.path = path
        self.mode = mode
        self.oid = oid
    }

    public var exists: Bool { mode != nil && oid != nil }
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

/// Decisión C.9.18: un archivo de contenido en conflicto que quedó igual a uno de los lados (Claude o el chat se
/// quedaron con esa versión entera). El combined diff no lo muestra: PRBar lo avisa y muestra un diff contra el lado
/// que se descartó.
public struct OneSidedResolution: Codable, Equatable, Sendable {
    public enum Side: String, Codable, Sendable {
        /// Quedó la versión del PR: se descartaron los cambios de la base.
        case pr
        /// Quedó la versión de la base: se descartaron los cambios del PR.
        case base
    }

    public var path: String
    public var kept: Side

    public init(path: String, kept: Side) {
        self.path = path
        self.kept = kept
    }

    /// "README.md (kept the PR’s version, dropped main’s changes)".
    public func description(baseRef: String) -> String {
        switch kept {
        case .pr: "\(path) (kept the PR’s version, dropped \(baseRef)’s changes)"
        case .base: "\(path) (kept \(baseRef)’s version, dropped the PR’s changes)"
        }
    }
}
