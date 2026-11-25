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
                .respondStart, .respondSelect, .respondReset, .respondImplement,
                .respondCancel, .respondDismiss, .mergeDismiss, .chatSend, .chatUndo, .chatStop, .notifySet,
                .notifySetEnabled, .ciFix]
            let gated: Set<AppCommand.Name> = [.merge, .respondPush, .respondPushAnyway, .respondTest, .reviewPublish,
                                                .respondReplyOnly]
            for name in AppCommand.Name.allCases {
                let expected: RemotePolicy.Class = allowed.contains(name) ? .allowed : gated.contains(name) ? .gated
                    : name == .remoteSetPresenceRequirement ? .dependsOnArguments : .denied
                try expect(RemotePolicy.classify(name) == expected, "\(name)")
            }
        },
        TestCase("remote policy: lo que ejecuta código del repo en la Mac (tests, push) siempre es gated (H1)") {
            try expectEqual(RemotePolicy.runsRepoCode, [.respondTest, .respondPush, .respondPushAnyway])
            for name in RemotePolicy.runsRepoCode {
                try expect(RemotePolicy.classify(name) == .gated, "\(name)")
                try expect(RemotePolicy.gatedNames.contains(name), "\(name)")
            }
            try expectEqual(RemotePolicy.decide(.respondTest(pr: "a/b#1", wait: true)), .gated)
        },
        TestCase("remote policy: todo lo que publica en GitHub como el usuario pide Face ID") {
            for event in [ReviewEvent.approve, .comment, .requestChanges] {
                let publish = AppCommand.reviewPublish(pr: "a/b#1", event: event, only: nil, withComments: true,
                                                       allInBody: false, confirmed: true)
                try expectEqual(RemotePolicy.decide(publish), .gated)
            }
            try expectEqual(RemotePolicy.decide(.respondReplyOnly(pr: "a/b#1", confirmed: true, wait: false)), .gated)
            // Editar el texto de una respuesta no publica: lo publica el push o reply-only (gated).
            try expectEqual(RemotePolicy.decide(.respondSelect(pr: "a/b#1", items: ["1"],
                                                               change: RespondSelectionChange(replyText: "x"))), .allowed)
            try expectEqual(RemotePolicy.decide(.status), .allowed)
            try expectEqual(RemotePolicy.decide(.quit), .denied)
            try expectEqual(RemotePolicy.decide(.setAlwaysShowInDock(enabled: true)), .denied)
            try expectEqual(RemotePolicy.decide(.slackTokenSet(token: "placeholder")), .denied)
            try expectEqual(RemotePolicy.decide(.respondPush(pr: "a/b#1", confirmed: true, wait: false)), .gated)
            try expectEqual(RemotePolicy.decide(.respondPushAnyway(pr: "a/b#1", confirmed: true, wait: false)), .gated)
            try expectEqual(RemotePolicy.decide(.ciFix(pr: "a/b#1", wait: false)), .allowed)
            try expectEqual(RemotePolicy.decide(.ciList), .allowed)
            // Resolve Conflicts (decisión C.9.9): solo desde la Mac.
            try expectEqual(RemotePolicy.classify(.conflictsList), .denied)
            try expectEqual(RemotePolicy.classify(.conflictsResolve), .denied)
            try expectEqual(RemotePolicy.decide(.conflictsResolve(pr: "a/b#1", wait: false)), .denied)
            try expectEqual(RemotePolicy.decide(.usage(month: nil)), .allowed)
            try expect(RemotePolicy.gatedNames.contains(.merge) && RemotePolicy.gatedNames.contains(.reviewPublish))
        },
        TestCase("remote policy: los remote* se deniegan; apagar Face ID desde el teléfono pide Face ID (L5)") {
            let remote: [AppCommand] = [.remoteStatus, .remoteEnable(relay: "r.example.com", enrollToken: "t"),
                                        .remoteDisable, .remotePairStart, .remotePairWait(pairing: "p"),
                                        .remotePairConfirm(pairing: "p", confirmed: true), .remoteDevices,
                                        .remoteRevoke(device: "d", confirmed: true), .remoteSetKeepAwake(enabled: true),
                                        .remoteReset(confirmed: true), .remoteSetMailbox(enabled: false)]
            for command in remote { try expectEqual(RemotePolicy.decide(command), .denied) }
            try expectEqual(RemotePolicy.decide(.remoteSetPresenceRequirement(device: "d", enabled: true)), .allowed)
            try expectEqual(RemotePolicy.decide(.remoteSetPresenceRequirement(device: "d", enabled: false)), .gated)
            try expect(RemotePolicy.gatedNames.contains(.remoteSetPresenceRequirement))
        },
        TestCase("remote policy: las sesiones en una terminal y la elección de terminal no se ofrecen en el iPhone (spec T.4)") {
            for name in [AppCommand.Name.sessionList, .sessionOpen, .setTerminal, .setTerminalCommand, .setKeepSessionFolders] {
                try expect(RemotePolicy.classify(name) == .denied, "\(name)")
                try expect(!RemotePolicy.gatedNames.contains(name), "\(name)")
            }
            try expectEqual(RemotePolicy.decide(.sessionOpen(pr: "a/b#1", job: nil, run: nil)), .denied)
            try expectEqual(RemotePolicy.decide(.sessionList(pr: "a/b#1")), .denied)
            try expectEqual(RemotePolicy.decide(.setTerminal(terminal: .iterm)), .denied)
        },
    ]
}
