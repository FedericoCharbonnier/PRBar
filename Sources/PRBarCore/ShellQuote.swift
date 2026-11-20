import Foundation

/// Comillas POSIX estrictas para todo lo que PRBar manda a un host por ssh (spec J.3/J.5). Nunca se interpola texto
/// en un comando: cada argumento va entre comillas simples, y una comilla simple adentro se escribe `'\''`. Dentro de
/// comillas simples POSIX nada es especial (`$`, `` ` ``, `\`, `!`, `*`, saltos de línea), así que el texto llega
/// tal cual. El único byte imposible es NUL (no puede ir en un argumento de `exec`): se rechaza.
public enum ShellQuote {
    public enum Failure: Error, Equatable, LocalizedError {
        case nulByte
        case invalidEnvironmentName(String)
        case invalidExecutable(String)

        public var errorDescription: String? {
            switch self {
            case .nulByte: "Internal error: a remote argument contained a NUL byte."
            case .invalidEnvironmentName(let name): "Internal error: invalid environment variable name \(name.debugDescription)."
            case .invalidExecutable(let path): "Internal error: invalid remote program \(path.debugDescription)."
            }
        }
    }

    public static func posix(_ value: String) throws -> String {
        guard !value.utf8.contains(0) else { throw Failure.nulByte }
        // Escalar por escalar, nunca por `Character`: `'` seguido de una marca combinante (U+0301, U+200D, …) es un
        // solo grafema para `String` y `replacingOccurrences` no lo ve, pero su primer byte cierra la comilla.
        var quoted = String.UnicodeScalarView()
        quoted.append("'")
        for scalar in value.unicodeScalars {
            if scalar == "'" { quoted.append(contentsOf: #"'\''"#.unicodeScalars) } else { quoted.append(scalar) }
        }
        quoted.append("'")
        return String(quoted)
    }

    public static func command(_ argv: [String]) throws -> String {
        try argv.map(posix).joined(separator: " ")
    }

    /// `[A-Za-z_][A-Za-z0-9_]*`.
    public static func isEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII,
              first == "_" || CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0)) }
    }
}
