import CoreImage
import Foundation

/// Un código QR como matriz de módulos (`true` = oscuro), con CoreImage (`CIQRCodeGenerator`, corrección M). Lo usan
/// la hoja "Pair iPhone…" de la app y `prbar remote pair` (medios bloques en la terminal). Sin zona silenciosa: quien
/// dibuja la agrega.
public enum QRCodeMatrix {
    public static func make(_ text: String, correction: String = "M") -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue(correction, forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, width < 1000, height < 1000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: extent, format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        var rows: [[Bool]] = (0..<height).map { y in (0..<width).map { x in pixels[(y * width + x) * 4] < 128 } }
        // Sin el margen claro que agrega CoreImage.
        while let first = rows.first, !first.contains(true) { rows.removeFirst() }
        while let last = rows.last, !last.contains(true) { rows.removeLast() }
        guard !rows.isEmpty else { return nil }
        while rows.allSatisfy({ $0.first == false }) { rows = rows.map { Array($0.dropFirst()) } }
        while rows.allSatisfy({ $0.last == false }) { rows = rows.map { Array($0.dropLast()) } }
        // La fila 0 tiene que ser la de arriba: los patrones de posición van arriba a la izquierda, arriba a la derecha
        // y abajo a la izquierda (nunca abajo a la derecha).
        if hasFinder(rows, top: rows.count - 7, left: rows.count - 7), !hasFinder(rows, top: 0, left: rows.count - 7) {
            rows.reverse()
        }
        guard rows.count == rows.first?.count, hasFinder(rows, top: 0, left: 0) else { return nil }
        return rows
    }

    /// Un patrón de posición (7×7: borde oscuro, anillo claro, centro 3×3 oscuro) en esa esquina.
    static func hasFinder(_ rows: [[Bool]], top: Int, left: Int) -> Bool {
        guard top >= 0, left >= 0, top + 7 <= rows.count, left + 7 <= (rows.first?.count ?? 0) else { return false }
        for y in 0..<7 {
            for x in 0..<7 {
                let ring = max(abs(y - 3), abs(x - 3))
                let dark = ring == 3 || ring <= 1
                if rows[top + y][left + x] != dark { return false }
            }
        }
        return true
    }
}
