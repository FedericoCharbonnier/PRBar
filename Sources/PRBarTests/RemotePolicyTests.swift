import Foundation
import PRBarCore
import PRBarRemoteKit

enum RemotePolicyTests {
    static let cases: [TestCase] = [
        TestCase("remote policy: la tabla del spec P.7") {
            // Sin `feat/ci-cost` en esta rama: `usage`, `ciList` (lectura) y `ciFix` (acción) se agregan como allowed
            // cuando se mergee (el switch exhaustivo de RemotePolicy no compila hasta entonces).
            let allowed: Set<AppCommand.Name> = [.status, .listPRs, .resolvePR, .history, .historyShow, .reviewShow,
                .respondShow, .respondDiff, .mergePreview, .chatShow, .resources, .notifyList, .refresh,
                .reviewStart, .reviewEdit, .reviewSetIncluded, .reviewSetComment, .reviewCancel, .reviewDismiss,
                .respondStart, .respondSelect, .respondReset, .respondImplement, .respondTest, .respondReplyOnly,
                .respondCancel, .respondDismiss, .mergeDismiss, .chatSend, .chatUndo, .chatStop, .notifySet,
                .notifySetEnabled]
            let gated: Set<AppCommand.Name> = [.merge, .respondPush, .respondPushAnyway]
            for name in AppCommand.Name.allCases {
                let expected: RemotePolicy.Class = allowed.contains(name) ? .allowed : gated.contains(name) ? .gated
                    : name == .reviewPublish ? .dependsOnArguments : .denied
                try expect(RemotePolicy.classify(name) == expected, "\(name)")
            }
        },
        TestCase("remote policy: approve pide Face ID; comment y request changes no") {
            let approve = AppCommand.reviewPublish(pr: "a/b#1", event: .approve, only: nil, withComments: true,
                                                   allInBody: false, confirmed: true)
            try expectEqual(RemotePolicy.decide(approve), .gated)
            for event in [ReviewEvent.comment, .requestChanges] {
                let other = AppCommand.reviewPublish(pr: "a/b#1", event: event, only: nil, withComments: true,
                                                     allInBody: false, confirmed: true)
                try expectEqual(RemotePolicy.decide(other), .allowed)
            }
            try expectEqual(RemotePolicy.decide(.status), .allowed)
            try expectEqual(RemotePolicy.decide(.quit), .denied)
            try expectEqual(RemotePolicy.decide(.slackTokenSet(token: "placeholder")), .denied)
            try expectEqual(RemotePolicy.decide(.respondPush(pr: "a/b#1", confirmed: true, wait: false)), .gated)
            try expect(RemotePolicy.gatedNames.contains(.merge) && RemotePolicy.gatedNames.contains(.reviewPublish))
        },
    ]
}
