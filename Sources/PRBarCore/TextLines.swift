import Foundation

/// Partir texto en líneas por cada `\n` (U+000A). `split(separator: "\n")` sobre `Character`s no sirve con CRLF: para
/// Swift `"\r\n"` es un solo `Character`, distinto de `"\n"`, así que esas líneas nunca se parten.
public enum TextLines {
    /// Las líneas de `text`, partidas en cada `\n` (también el de un `\r\n`), con las vacías (como `split(...,
    /// omittingEmptySubsequences: false)`). Con `strippingCarriageReturns`, sin el `\r` del final de cada una.
    public static func split(_ text: some StringProtocol, strippingCarriageReturns: Bool) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { scalars in
            var line = String.UnicodeScalarView(scalars)
            if strippingCarriageReturns, line.last == "\r" { line.removeLast() }
            return String(line)
        }
    }
}
