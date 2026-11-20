import Foundation
import PRBarCLIKit

enum UIParityTests {
    static let cases: [TestCase] = [
        TestCase("paridad UI: cada control de la app tiene su comando (o una razón)") {
            let scanned = try UIActionScanner.scan()
            try expect(!scanned.isEmpty, "el escáner no encontró nada en \(UIActionScanner.appSources.path)")
            var expected: [UIActionScanner.Key: UIAction] = [:]
            for entry in UIActionInventory.entries {
                try expect(expected[entry.key] == nil, "entrada repetida: \(entry.key)")
                expected[entry.key] = entry
            }
            var problems: [String] = []
            for (key, count) in scanned.sorted(by: { $0.key < $1.key }) {
                guard let entry = expected[key] else {
                    problems.append("NUEVO, sin entrada:  .init(\"\(key.file)\", \"\(key.kind)\", \"\(key.label)\", \(count), .cli([\"…\"])),")
                    continue
                }
                if entry.count != count { problems.append("CANTIDAD: \(key) tiene \(count), el inventario dice \(entry.count)") }
            }
            for key in expected.keys.sorted() where scanned[key] == nil {
                problems.append("YA NO EXISTE: \(key) (borrar la entrada)")
            }
            for entry in UIActionInventory.entries {
                if case .cli(let paths) = entry.mapping {
                    for path in paths where !CLIRouter.allPaths.contains(path) {
                        problems.append("COMANDO INEXISTENTE: \(entry.key) → `\(path)`")
                    }
                }
            }
            try expect(problems.isEmpty, "\n" + problems.joined(separator: "\n"))
        },
    ]
}
