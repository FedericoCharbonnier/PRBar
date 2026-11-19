import Foundation
import PRBarCore

private func pr(status: MergeStateStatus = .clean, mergeable: MergeableState = .mergeable, nodeID: String? = "PR_1",
                base: String = "main") -> PullRequest {
    makePR(author: "me", base: base, decision: .approved, merge: PRMergeState(nodeID: nodeID, mergeable: mergeable, status: status))
}

private func availability(_ pr: PullRequest, _ settings: RepoMergeSettings? = nil) -> MergeAvailability {
    MergePolicy.availability(pr, settings: settings)
}

enum MergePolicyTests {
    static let cases: [TestCase] = [
        TestCase("merge policy: CLEAN y HAS_HOOKS → habilitado sin nota") {
            try expectEqual(availability(pr(status: .clean)), .enabled(note: nil))
            try expectEqual(availability(pr(status: .hasHooks)), .enabled(note: nil))
        },
        TestCase("merge policy: UNSTABLE → habilitado con nota") {
            let result = availability(pr(status: .unstable))
            try expectEqual(result, .enabled(note: "Some checks that aren’t required are failing"))
            try expect(result.isEnabled)
            try expectEqual(result.note, "Some checks that aren’t required are failing")
        },
        TestCase("merge policy: BLOCKED, BEHIND, UNKNOWN y DRAFT → deshabilitado con el motivo") {
            try expectEqual(availability(pr(status: .blocked)), .disabled(reason: "Blocked by branch protection or required checks"))
            try expectEqual(availability(pr(status: .behind, base: "develop")), .disabled(reason: "Branch is behind develop"))
            try expectEqual(availability(pr(status: .unknown)), .disabled(reason: "Checking…"))
            try expectEqual(availability(pr(status: .draft)), .disabled(reason: "Checking…"))
            try expectEqual(availability(pr(nodeID: nil)), .disabled(reason: "Checking…"))
            try expectEqual(availability(pr(status: .blocked)).reason, "Blocked by branch protection or required checks")
        },
        TestCase("merge policy: conflictos → deshabilitado") {
            try expectEqual(availability(pr(status: .dirty)), .disabled(reason: "This branch has conflicts"))
            try expectEqual(availability(pr(status: .unknown, mergeable: .conflicting)), .disabled(reason: "This branch has conflicts"))
        },
        TestCase("merge policy: sin permiso de escritura o sin métodos permitidos → deshabilitado") {
            try expectEqual(availability(pr(), RepoMergeSettings(viewerPermission: "READ")),
                            .disabled(reason: "You don’t have permission to merge in o/r"))
            let none = RepoMergeSettings(squashAllowed: false, mergeCommitAllowed: false, rebaseAllowed: false)
            try expectEqual(availability(pr(), none), .disabled(reason: "This repo doesn’t allow any merge method"))
            try expectEqual(availability(pr(), RepoMergeSettings(viewerPermission: "WRITE")), .enabled(note: nil))
        },
        TestCase("merge policy: métodos permitidos; sin datos del repo, los tres") {
            try expectEqual(MergePolicy.allowedMethods(nil), [.squash, .merge, .rebase])
            try expectEqual(MergePolicy.allowedMethods(RepoMergeSettings(squashAllowed: false)), [.merge, .rebase])
        },
        TestCase("merge policy: método por defecto (config del repo, default de GitHub, primero permitido)") {
            let settings = RepoMergeSettings(squashAllowed: true, mergeCommitAllowed: false, rebaseAllowed: true, viewerDefault: .rebase)
            try expectEqual(MergePolicy.defaultMethod(configured: .squash, settings: settings), .squash)
            try expectEqual(MergePolicy.defaultMethod(configured: .merge, settings: settings), .rebase)
            try expectEqual(MergePolicy.defaultMethod(configured: nil, settings: settings), .rebase)
            let mergeDefault = RepoMergeSettings(squashAllowed: false, mergeCommitAllowed: false, rebaseAllowed: true, viewerDefault: .merge)
            try expectEqual(MergePolicy.defaultMethod(configured: nil, settings: mergeDefault), .rebase)
            try expectEqual(MergePolicy.defaultMethod(configured: nil, settings: nil), .squash)
            try expectEqual(MergePolicy.defaultMethod(configured: .rebase, settings: nil), .rebase)
            let none = RepoMergeSettings(squashAllowed: false, mergeCommitAllowed: false, rebaseAllowed: false)
            try expectEqual(MergePolicy.defaultMethod(configured: .squash, settings: none), nil)
        },
        TestCase("merge policy: options junta la config del repo, el snapshot de la cuenta y el PR") {
            var config = AppConfig()
            config.accounts = [AccountConfig(login: "me", repos: [RepoConfig(owner: "o", name: "r", mergeMethod: .merge)])]
            let item = ClassifiedPR(pr: pr(status: .unstable), category: .readyToMerge, account: "me")
            let snapshot = Snapshot(items: [item], fetchedAt: t0, repoMergeSettings: [
                "me|o/r": RepoMergeSettings(viewerDefault: .squash),
                "otra|o/r": RepoMergeSettings(squashAllowed: false, mergeCommitAllowed: false, rebaseAllowed: false),
            ])
            let options = MergePolicy.options(for: item, snapshot: snapshot, config: config)
            try expectEqual(options, MergeOptions(
                availability: .enabled(note: "Some checks that aren’t required are failing"),
                methods: [.squash, .merge, .rebase], defaultMethod: .merge))
            let noSnapshot = MergePolicy.options(for: item, snapshot: nil, config: AppConfig())
            try expectEqual(noSnapshot.defaultMethod, .squash)
        },
    ]
}
