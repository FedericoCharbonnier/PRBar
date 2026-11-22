import PRBarCore

enum DiffFilesTests {
    private static let stat = """
     package.json              |  1 +
     src/reports/export.ts     | 41 +++++++++++------
     docs/old.md => docs/new.md |  0
     3 files changed, 42 insertions(+), 15 deletions(-)
    """

    private static let diff = """
    diff --git a/package.json b/package.json
    --- a/package.json
    +++ b/package.json
    @@ -1 +1,2 @@
    +  "x": 1,
    diff --git a/src/reports/export.ts b/src/reports/export.ts
    --- a/src/reports/export.ts
    +++ b/src/reports/export.ts
    @@ -3 +3 @@
    -old
    +new
    """

    static let cases: [TestCase] = [
        TestCase("diff: los archivos del diffstat, sin la línea de resumen") {
            try expectEqual(DiffFiles.files(stat: stat), ["package.json", "src/reports/export.ts", "docs/new.md"])
            try expectEqual(DiffFiles.files(stat: ""), [])
        },
        TestCase("diff: el fragmento de un archivo; vacío si no está") {
            let only = DiffFiles.section(of: diff, file: "src/reports/export.ts")
            try expect(only.hasPrefix("diff --git a/src/reports/export.ts"))
            try expect(only.contains("+new"))
            try expect(!only.contains("package.json"))
            try expectEqual(DiffFiles.section(of: diff, file: "package.json").split(separator: "\n").count, 5)
            try expectEqual(DiffFiles.section(of: diff, file: "nope.txt"), "")
        },
        TestCase("diff: las últimas N líneas de un log") {
            try expectEqual(DiffFiles.tail("a\nb\nc\nd", lines: 2), "c\nd")
            try expectEqual(DiffFiles.tail("a\nb\n", lines: 5), "a\nb")
        },
    ]
}
