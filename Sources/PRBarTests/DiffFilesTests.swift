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
        TestCase("diff memo: same diff and file reuse the section; a new file or diff recomputes it") {
            let memo = DiffSectionMemo()
            let first = memo.section(of: diff, file: "package.json")
            try expectEqual(first, DiffFiles.section(of: diff, file: "package.json"))
            _ = memo.section(of: diff, file: "package.json")
            try expectEqual(memo.computations, 1)
            try expectEqual(memo.section(of: diff, file: "src/reports/export.ts"),
                            DiffFiles.section(of: diff, file: "src/reports/export.ts"))
            try expectEqual(memo.computations, 2)
            _ = memo.section(of: diff + "\n+more", file: "src/reports/export.ts")
            try expectEqual(memo.computations, 3)
        },
        TestCase("diff: el fragmento de un archivo; vacío si no está") {
            let only = DiffFiles.section(of: diff, file: "src/reports/export.ts")
            try expect(only.hasPrefix("diff --git a/src/reports/export.ts"))
            try expect(only.contains("+new"))
            try expect(!only.contains("package.json"))
            try expectEqual(DiffFiles.section(of: diff, file: "package.json").split(separator: "\n").count, 5)
            try expectEqual(DiffFiles.section(of: diff, file: "nope.txt"), "")
        },
        TestCase("diff: CRLF (un solo Character para Swift) no junta las líneas: fragmentos, líneas comentables, archivos y colas") {
            let crlf = diff.replacingOccurrences(of: "\n", with: "\r\n")
            let only = DiffFiles.section(of: crlf, file: "src/reports/export.ts")
            try expect(only.hasPrefix("diff --git a/src/reports/export.ts"), only)
            try expect(only.contains("+new") && !only.contains("package.json"), only)
            try expect(DiffFiles.section(of: crlf, file: "package.json").contains("\"x\": 1"))
            try expectEqual(ChatActions.files(inDiff: crlf), ["package.json", "src/reports/export.ts"])
            // Contexto, una línea vacía de contexto (" ") y agregadas, con CRLF.
            let patch = "@@ -1,2 +1,4 @@\r\n a\r\n \r\n+b\r\n-c\r\n+d\r\n"
            try expectEqual(DiffLineMap.commentableLines(in: patch), [1, 2, 3, 4])
            try expectEqual(DiffFiles.tail("a\r\nb\r\nc\r\n", lines: 2), "b\nc")
            try expectEqual(FixImplementer.tail("a\r\nb\r\nc\r\n", lines: 2), "b\nc")
            try expectEqual(CILogs.tail("a\r\nb\r\nc\r\n", lines: 2).text, "b\nc")
            // El tope de líneas del diff guardado cuenta las CRLF (y no les saca el \r).
            let long = Array(repeating: "+x\r", count: FixImplementer.maxDiffLines + 1).joined(separator: "\n")
            let (capped, truncated) = FixImplementer.capDiff(long)
            try expect(truncated)
            try expectEqual(capped, Array(repeating: "+x\r", count: FixImplementer.maxDiffLines).joined(separator: "\n"))
        },
        TestCase("diff: las últimas N líneas de un log") {
            try expectEqual(DiffFiles.tail("a\nb\nc\nd", lines: 2), "c\nd")
            try expectEqual(DiffFiles.tail("a\nb\n", lines: 5), "a\nb")
        },
    ]
}
