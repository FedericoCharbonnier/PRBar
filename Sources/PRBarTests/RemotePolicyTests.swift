import Foundation
import PRBarCore
import PRBarRemoteKit

enum RemotePolicyTests {
    static let cases: [TestCase] = [
        TestCase("remote policy: la tabla del spec P.7") {
            // `usage` y `ciList` (lectura) y `ciFix` (acción) llegaron con el merge de `feat/ci-cost`; `ci show/diff/push`
            // son los comandos de Respond (`ci push` = `respondPush`, gated).
            let allowed: Set<AppCommand.Name> = [.status, .listPRs, .resolvePR, .history, .historyShow, .reviewShow,
                .respondShow, .respondDiff, .mergePreview, .chatShow, .resources, .usage, .ciList, .notifyList, .refresh,
                .reviewStart, .reviewEdit, .reviewSetIncluded, .reviewSetComment, .reviewCancel, .reviewDismiss,
                .respondStart, .respondSelect, .respondReset, .respondImplement, .respondTest, .respondReplyOnly,
                .respondCancel, .respondDismiss, .mergeDismiss, .chatSend, .chatUndo, .chatStop, .notifySet,
                .notifySetEnabled, .ciFix]
            let gated: Set<AppCommand.Name> = [.merge, .respondPush, .respondPushAnyway]
            for name in AppCommand.Name.allCases {
                let expected: RemotePolicy.Class = allowed.contains(name) ? .allowed : gated.contains(name) ? .gated
                    : [.reviewPublish, .remoteSetPresenceRequirement].contains(name) ? .dependsOnArguments : .denied
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
            try expectEqual(RemotePolicy.decide(.respondPushAnyway(pr: "a/b#1", confirmed: true, wait: false)), .gated)
            try expectEqual(RemotePolicy.decide(.ciFix(pr: "a/b#1", wait: false)), .allowed)
            try expectEqual(RemotePolicy.decide(.ciList), .allowed)
            try expectEqual(RemotePolicy.decide(.usage(month: nil)), .allowed)
            try expect(RemotePolicy.gatedNames.contains(.merge) && RemotePolicy.gatedNames.contains(.reviewPublish))
        },
        TestCase("remote policy: los remote* se deniegan; apagar Face ID desde el teléfono pide Face ID (L5)") {
            let remote: [AppCommand] = [.remoteStatus, .remoteEnable(relay: "r.example.com", enrollToken: "t"),
                                        .remoteDisable, .remotePairStart, .remotePairWait(pairing: "p"),
                                        .remotePairConfirm(pairing: "p", confirmed: true), .remoteDevices,
                                        .remoteRevoke(device: "d", confirmed: true), .remoteSetKeepAwake(enabled: true),
                                        .remoteReset(confirmed: true), .remoteSetMailbox(enabled: false),
                                        .remoteSetAppLink(url: nil)]
            for command in remote { try expectEqual(RemotePolicy.decide(command), .denied) }
            try expectEqual(RemotePolicy.decide(.remoteSetPresenceRequirement(device: "d", enabled: true)), .allowed)
            try expectEqual(RemotePolicy.decide(.remoteSetPresenceRequirement(device: "d", enabled: false)), .gated)
            try expect(RemotePolicy.gatedNames.contains(.remoteSetPresenceRequirement))
        },
    ]
}
