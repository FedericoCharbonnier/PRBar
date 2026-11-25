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
    ]
}
