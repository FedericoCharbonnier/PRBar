import Foundation

/// Un QR en la terminal con medios bloques: cada carácter son dos módulos (arriba y abajo), con zona silenciosa.
/// Se dibujan los módulos **claros** (`█`, `▀`, `▄`) y los oscuros quedan como el fondo: con colores, `prbar` fuerza
/// texto blanco sobre fondo negro (`colored`), así sale bien en cualquier tema; sin colores, sale bien en una terminal
/// oscura (lo común). `inverted` dibuja los oscuros (para una terminal clara sin colores).
public enum QRRender {
    public static func halfBlocks(matrix: [[Bool]], quietZone: Int = 2, inverted: Bool = false) -> [String] {
        let size = matrix.count
        let width = size + quietZone * 2
        func module(_ y: Int, _ x: Int) -> Bool {
            let row = y - quietZone, column = x - quietZone
            guard row >= 0, row < size, column >= 0, column < size else { return false }
            return matrix[row][column]
        }
        func ink(_ y: Int, _ x: Int) -> Bool { inverted ? module(y, x) : !module(y, x) }
        var lines: [String] = []
        var y = 0
        while y < size + quietZone * 2 {
            var line = ""
            for x in 0..<width {
                let top = ink(y, x)
                let bottom = y + 1 < size + quietZone * 2 ? ink(y + 1, x) : false
                let block: String = switch (top, bottom) {
                case (true, true): "█"
                case (true, false): "▀"
                case (false, true): "▄"
                case (false, false): " "
                }
                line += block
            }
            lines.append(line)
            y += 2
        }
        return lines
    }

    /// Blanco sobre negro, para que el QR se lea igual con un tema claro.
    public static func colored(_ line: String) -> String { "\u{1B}[97;40m\(line)\u{1B}[0m" }
}
