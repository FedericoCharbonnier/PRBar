import Foundation
import PRBarCore

enum MergeModelsTests {
    static let cases: [TestCase] = [
        TestCase("merge models: método en minúsculas en config y en mayúsculas en GraphQL") {
            try expectEqual(MergeMethod.allCases.map(\.rawValue), ["squash", "merge", "rebase"])
            try expectEqual(MergeMethod.squash.graphQLValue, "SQUASH")
            try expectEqual(MergeMethod(graphQL: "REBASE"), .rebase)
            try expectEqual(MergeMethod(graphQL: "FAST_FORWARD"), nil)
            try expectEqual(MergeMethod(graphQL: nil), nil)
            try expectEqual(MergeMethod.allCases.map(\.actionTitle), ["Squash and Merge", "Merge", "Rebase and Merge"])
            try expectEqual(MergeMethod.allCases.map(\.title), ["Squash", "Merge", "Rebase"])
        },
        TestCase("merge models: estados de GitHub; los desconocidos → unknown") {
            try expectEqual(MergeableState(graphQL: "CONFLICTING"), .conflicting)
            try expectEqual(MergeableState(graphQL: "MERGEABLE"), .mergeable)
            try expectEqual(MergeableState(graphQL: nil), .unknown)
            try expectEqual(MergeStateStatus(graphQL: "CLEAN"), .clean)
            try expectEqual(MergeStateStatus(graphQL: "HAS_HOOKS"), .hasHooks)
            try expectEqual(MergeStateStatus(graphQL: "UNSTABLE"), .unstable)
            try expectEqual(MergeStateStatus(graphQL: "BLOCKED"), .blocked)
            try expectEqual(MergeStateStatus(graphQL: "BEHIND"), .behind)
            try expectEqual(MergeStateStatus(graphQL: "DIRTY"), .dirty)
            try expectEqual(MergeStateStatus(graphQL: "DRAFT"), .draft)
            try expectEqual(MergeStateStatus(graphQL: "SOMETHING_NEW"), .unknown)
        },
        TestCase("merge models: un PR de un state.json viejo (sin merge) se lee con .unknown") {
            let pr = makePR()
            var object = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(pr)) as? [String: Any] ?? [:]
            try expect(object["merge"] != nil)
            object["merge"] = nil
            let decoded = try JSONCoding.decoder.decode(PullRequest.self, from: JSONSerialization.data(withJSONObject: object))
            try expectEqual(decoded.merge, .unknown)
            try expectEqual(decoded, pr)
        },
        TestCase("merge models: PR con datos de merge sobrevive un round-trip; valores raros no rompen") {
            let pr = makePR(merge: PRMergeState(nodeID: "PR_1", mergeable: .mergeable, status: .clean, viewerCanUpdate: true, commitCount: 3))
            let data = try JSONCoding.encoder.encode(pr)
            try expectEqual(try JSONCoding.decoder.decode(PullRequest.self, from: data), pr)
            let odd = try JSONCoding.decoder.decode(PRMergeState.self, from: Data(#"{"nodeID":"PR_1","mergeable":"maybe","status":42}"#.utf8))
            try expectEqual(odd, PRMergeState(nodeID: "PR_1"))
        },
        TestCase("merge models: métodos permitidos y permiso del repo") {
            let settings = RepoMergeSettings(
                squashAllowed: true, mergeCommitAllowed: false, rebaseAllowed: true, viewerDefault: .rebase,
                deleteBranchOnMerge: true, viewerPermission: "WRITE")
            try expectEqual(settings.allowedMethods, [.squash, .rebase])
            try expectEqual(settings.viewerCanMerge, true)
            try expectEqual(RepoMergeSettings(viewerPermission: "MAINTAIN").viewerCanMerge, true)
            try expectEqual(RepoMergeSettings(viewerPermission: "TRIAGE").viewerCanMerge, false)
            try expectEqual(RepoMergeSettings(viewerPermission: "READ").viewerCanMerge, false)
            try expectEqual(RepoMergeSettings().viewerCanMerge, nil)
            let partial = try JSONCoding.decoder.decode(
                RepoMergeSettings.self, from: Data(#"{"rebaseAllowed":false,"viewerDefault":"octopus"}"#.utf8))
            try expectEqual(partial.allowedMethods, [.squash, .merge])
            try expectEqual(partial.viewerDefault, nil)
            try expectEqual(partial.deleteBranchOnMerge, false)
        },
        TestCase("merge models: Snapshot viejo sin repoMergeSettings; uno nuevo sobrevive un round-trip") {
            let old = try JSONCoding.decoder.decode(Snapshot.self, from: Data(#"{"items":[],"fetchedAt":"2027-01-15T08:00:00Z"}"#.utf8))
            try expectEqual(old.repoMergeSettings, [:])
            let snapshot = Snapshot(items: [], fetchedAt: t0, repoMergeSettings: ["me|o/r": RepoMergeSettings(viewerDefault: .squash)])
            try expectEqual(try JSONCoding.decoder.decode(Snapshot.self, from: JSONCoding.encoder.encode(snapshot)), snapshot)
        },
    ]
}
