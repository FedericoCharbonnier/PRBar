import Foundation
import PRBarCore

private let head = String(repeating: "a", count: 40)
private let baseOid = String(repeating: "b", count: 40)
private let mergeBase = String(repeating: "c", count: 40)

func conflictsContext(files: [ConflictFile] = [ConflictFile(path: "README.md", kind: .content)]) -> ConflictsContext {
    ConflictsContext(baseRef: "main", baseOid: baseOid, mergeBase: mergeBase, files: files, incomingCommits: 2)
}

func conflictsDraft(context: ConflictsContext = conflictsContext(), items: [RespondItem] = []) -> RespondDraft {
    RespondDraft(prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "T",
                 url: URL(string: "https://github.com/o/r/pull/7")!, headRef: "feature", account: "me",
                 worktree: ResolvedWorktree(path: "/tmp/wt", origin: .dedicated, localPath: "/tmp/r", ref: "refs/prbar/respond-7-0a0b0c0d"),
                 startHeadOid: head, items: items, mode: .conflicts, conflicts: context)
}

enum ConflictsTests {
    static let cases: [TestCase] = [
        TestCase("conflicts: el draft guarda modo y contexto; uno viejo sin ellos se lee como feedback") {
            let draft = conflictsDraft()
            let data = try JSONEncoder().encode(draft)
            let decoded = try JSONDecoder().decode(RespondDraft.self, from: data)
            try expectEqual(decoded.mode, .conflicts)
            try expectEqual(decoded.conflicts, conflictsContext())
            try expect(decoded.isConflicts && decoded.implementsAlone && !decoded.isCIFix)
            // Un contexto roto no pierde el draft.
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            object["conflicts"] = ["baseRef": 3]
            object["mode"] = "algo-nuevo"
            let broken = try JSONDecoder().decode(RespondDraft.self, from: JSONSerialization.data(withJSONObject: object))
            try expectEqual(broken.mode, .feedback)
            try expectEqual(broken.conflicts, nil)
        },
        TestCase("conflicts: contexto (archivos de contenido y a mano, mensaje del commit)") {
            let context = conflictsContext(files: [ConflictFile(path: "a.swift", kind: .content),
                                                   ConflictFile(path: "logo.png", kind: .byHand, reason: "binary")])
            try expectEqual(context.contentFiles, ["a.swift"])
            try expectEqual(context.byHandFiles.map(\.path), ["logo.png"])
            try expectEqual(context.commitMessage(headRef: "feature"), "Merge main into feature")
        },
        TestCase("conflicts: el ítem se implementa y nunca se responde; ItemResult guarda los resúmenes por archivo") {
            let feedback = FeedbackItem(id: "conflicts:\(head)", kind: .mergeConflicts, path: nil, line: nil, isOutdated: false, comments: [])
            let item = RespondItem(feedback: feedback, assessment: "", action: .fix, fixPlan: "", reply: "")
            let selection = RespondSelection.defaults(for: item)
            try expect(selection.implement && !selection.reply)
            let result = ItemResult(id: item.id, status: .committed, commit: head, summary: "ok",
                                    conflictFiles: [ConflictFileSummary(path: "README.md", summary: "Both.")])
            let decoded = try JSONDecoder().decode(ItemResult.self, from: JSONEncoder().encode(result))
            try expectEqual(decoded.conflictFiles, [ConflictFileSummary(path: "README.md", summary: "Both.")])
        },
        TestCase("conflicts: etapa, actividad, historial y sesiones tienen su nombre") {
            try expectEqual(PromptStage.conflicts.title, "Conflicts")
            try expectEqual(PromptStage.conflicts.cliName, "conflicts")
            try expectEqual(PromptStage.conflicts.ruleStage, .respond)
            try expectEqual(PromptStage.conflicts.variables.map(\.name), ["pr", "repo", "title", "base", "files", "rules"])
            try expectEqual(PromptStage.conflicts.requiredVariables, [])
            try expectEqual(ProcessActivity.conflicts("o/r#7").title, "Resolve Conflicts r#7")
            try expectEqual(HistoryKind(rawValue: "conflicts"), .conflicts)
            try expectEqual(SessionJob(rawValue: "conflicts"), .conflicts)
            try expectEqual(ClaudeUsageStage.name(fromLogHeader: "=== conflicts ==="), "conflicts")
        },
        TestCase("conflict classifier: ls-files -u; contenido, borrados, binarios, symlinks, submódulos y archivos de git") {
            func entry(_ mode: String, _ stage: Int, _ path: String) -> String { "\(mode) \(String(repeating: "\(stage)", count: 40)) \(stage)\t\(path)" }
            let output = [
                entry("100644", 1, "a.swift"), entry("100644", 2, "a.swift"), entry("100644", 3, "a.swift"),
                entry("100644", 1, "gone.txt"), entry("100644", 2, "gone.txt"),               // borrado en la base
                entry("100644", 1, "mine.txt"), entry("100644", 3, "mine.txt"),               // borrado en el PR
                entry("100644", 2, "both.txt"), entry("100644", 3, "both.txt"),               // agregado en los dos
                entry("100644", 1, "logo.png"), entry("100644", 2, "logo.png"), entry("100644", 3, "logo.png"),
                entry("120000", 1, "link"), entry("120000", 2, "link"), entry("120000", 3, "link"),
                entry("160000", 1, "vendor/lib"), entry("160000", 2, "vendor/lib"), entry("160000", 3, "vendor/lib"),
                entry("100644", 1, "sub/.gitattributes"), entry("100644", 2, "sub/.gitattributes"), entry("100644", 3, "sub/.gitattributes"),
                entry("100644", 1, "dir with space/ñ.txt"), entry("100644", 2, "dir with space/ñ.txt"), entry("100644", 3, "dir with space/ñ.txt"),
            ].joined(separator: "\0") + "\0"
            let entries = ConflictClassifier.entries(fromLsFilesUZ: output)
            try expectEqual(entries.count, 24)
            try expectEqual(ConflictClassifier.contentCandidates(entries).map(\.path),
                            ["a.swift", "both.txt", "dir with space/ñ.txt", "logo.png", "sub/.gitattributes"])
            let files = ConflictClassifier.classify(entries, binary: ["logo.png"])
            try expectEqual(files, [
                ConflictFile(path: "a.swift", kind: .content),
                ConflictFile(path: "both.txt", kind: .content),
                ConflictFile(path: "dir with space/ñ.txt", kind: .content),
                ConflictFile(path: "gone.txt", kind: .byHand, reason: "deleted in the base"),
                ConflictFile(path: "link", kind: .byHand, reason: "symlink"),
                ConflictFile(path: "logo.png", kind: .byHand, reason: "binary"),
                ConflictFile(path: "mine.txt", kind: .byHand, reason: "deleted in the PR"),
                ConflictFile(path: "sub/.gitattributes", kind: .byHand, reason: "git settings file"),
                ConflictFile(path: "vendor/lib", kind: .byHand, reason: "submodule"),
            ])
            try expect(ConflictClassifier.isBinaryNumstat("-\t-\tx => y\n"))
            try expect(!ConflictClassifier.isBinaryNumstat("1\t2\tx => y\n"))
        },
        TestCase("conflict markers: git grep -c --null por archivo; tope = max(head, base, head+base−mergeBase)") {
            try expectEqual(ConflictMarkers.counts(fromGrep: "README.md\u{0}3\nsrc/a b.swift\u{0}1\n", revision: nil),
                            ["README.md": 3, "src/a b.swift": 1])
            let rev = String(repeating: "a", count: 40)
            try expectEqual(ConflictMarkers.counts(fromGrep: "\(rev):docs/x.md\u{0}1\n", revision: rev), ["docs/x.md": 1])
            try expectEqual(ConflictMarkers.counts(fromGrep: "", revision: nil), [:])
            // Un título subrayado con ======= en el head y en la base: no es un marcador que dejó Claude.
            try expectEqual(ConflictMarkers.leftover(after: ["docs/x.md": 1, "README.md": 3],
                                                     head: ["docs/x.md": 1], base: ["docs/x.md": 1], mergeBase: ["docs/x.md": 1]),
                            ["README.md"])
            // Cada lado agregó un título: 2 es lo esperable (1 + 1 − 0).
            try expectEqual(ConflictMarkers.leftover(after: ["x.md": 2], head: ["x.md": 1], base: ["x.md": 1], mergeBase: [:]), [])
            try expectEqual(ConflictMarkers.leftover(after: ["x.md": 3], head: ["x.md": 1], base: ["x.md": 1], mergeBase: [:]), ["x.md"])
            // Los patrones van a git grep -E, cada uno con -e.
            try expectEqual(ConflictMarkers.grepArguments.prefix(5), ["grep", "-I", "-c", "--null", "-E"])
            try expect(ConflictMarkers.grepArguments.contains("^=======[[:space:]]*$"))
        },
        TestCase("conflict index: lo que Claude cambió en el índice; symlinks/gitlinks nuevos y archivos a mano tocados") {
            let blob = String(repeating: "1", count: 40), other = String(repeating: "2", count: 40)
            let before = ["100644 \(blob) 0\tsame.txt", "100644 \(blob) 1\tREADME.md", "100644 \(blob) 2\tREADME.md",
                          "100644 \(blob) 3\tREADME.md", "100644 \(blob) 0\tkept.txt"].joined(separator: "\0") + "\0"
            let after = ["100644 \(blob) 0\tsame.txt", "100644 \(other) 0\tREADME.md", "100644 \(other) 0\tkept.txt",
                         "120000 \(other) 0\tnew-link", "160000 \(other) 0\tnew-sub"].joined(separator: "\0") + "\0"
            let changed = ConflictIndex.changed(before: before, after: after)
            try expectEqual(changed.map(\.path), ["README.md", "kept.txt", "new-link", "new-sub"])
            try expectEqual(ConflictIndex.special(changed), ["new-link", "new-sub"])
            try expectEqual(ConflictIndex.touched(["kept.txt", "other.txt"], before: before, after: after), ["kept.txt"])
            try expectEqual(ConflictIndex.unmerged(after), [])
            try expectEqual(ConflictIndex.unmerged(before), ["README.md"])
        },
    ]
}
