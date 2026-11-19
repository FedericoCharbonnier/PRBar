import Foundation
import PRBarCore

private func item(_ id: String, _ severity: Severity, file: String = "src/a.ts", category: FindingCategory = .bug,
                  keep: Bool = true) -> ReviewItem {
    ReviewItem(finding: ReviewFinding(id: id, severity: severity, file: file, line: 1, title: id, body: "B", category: category),
               keep: keep, reason: keep ? nil : "dup")
}

enum ReviewOptionsFilterTests {
    static let cases: [TestCase] = [
        TestCase("review options filter: con los ajustes por defecto no oculta nada") {
            let items = [item("f1", .low), item("f2", .high, category: .style)]
            try expectEqual(ReviewOptionsFilter.apply(items, options: ReviewOptions()), items)
        },
        TestCase("review options filter: rutas, categorías y severidad, en ese orden") {
            var options = ReviewOptions()
            options.ignorePaths = ["generated/**"]
            options.setCategory(.style, enabled: false)
            options.minSeverity = .medium
            let result = ReviewOptionsFilter.apply(
                [item("f1", .high, file: "generated/api.ts"), item("f2", .high, file: "src/x.lock"), item("f3", .high, category: .style),
                 item("f4", .low), item("f5", .medium)],
                options: options, repoIgnorePaths: ["*.lock"])
            try expectEqual(result.map(\.hiddenBy), ["Ignored path (generated/**)", "Ignored path (*.lock)",
                                                    "Category off: style", "Below the minimum severity (medium)", nil])
        },
        TestCase("review options filter: el máximo deja los más severos entre los visibles que mantuvo el filtro") {
            var options = ReviewOptions()
            options.maxFindings = 2
            let result = ReviewOptionsFilter.apply(
                [item("f1", .low), item("f2", .high), item("f3", .high, keep: false), item("f4", .medium), item("f5", .high)],
                options: options)
            try expectEqual(result.filter { !$0.isHidden && $0.keep }.map(\.id), ["f2", "f5"])
            try expectEqual(result[0].hiddenBy, "Over your limit of 2 findings")
            try expectEqual(result[3].hiddenBy, "Over your limit of 2 findings")
            try expectEqual(result[2].hiddenBy, nil)
            options.maxFindings = 0
            try expectEqual(ReviewOptionsFilter.apply([item("f1", .low)], options: options)[0].hiddenBy, nil)
        },
        TestCase("path glob: sin barra compara el nombre; con barra, la ruta; '/' final y '/' inicial") {
            try expect(PathGlob.matches("*.lock", path: "a/b/yarn.lock"))
            try expect(!PathGlob.matches("*.lock", path: "a/lock/b.ts"))
            try expect(PathGlob.matches("generated/**", path: "generated/a/b.ts"))
            try expect(!PathGlob.matches("generated/**", path: "src/generated.ts"))
            try expect(PathGlob.matches("dist/", path: "dist/app.js"))
            try expect(PathGlob.matches("/docs/*", path: "docs/a.md"))
            try expect(!PathGlob.matches("  ", path: "a.ts"))
        },
    ]
}
