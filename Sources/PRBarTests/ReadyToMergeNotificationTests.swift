import Foundation
import PRBarCore

private func snap(_ items: ClassifiedPR...) -> Snapshot {
    Snapshot(items: items, fetchedAt: t0, fetchedScopes: ["me|o/r"])
}

private func mine(_ category: PRCategory, decision: ReviewDecision, ci: CIState = .success) -> ClassifiedPR {
    ClassifiedPR(pr: makePR(number: 7, author: "me", ci: ci, decision: decision), category: category, account: "me")
}

enum ReadyToMergeNotificationTests {
    static let cases: [TestCase] = [
        TestCase("ready notif: aprobado y listo en el mismo refresco → solo readyToMerge") {
            let planned = NotificationPlanner.plan(
                previous: snap(mine(.other, decision: .reviewRequired)), current: snap(mine(.readyToMerge, decision: .approved)),
                settings: NotificationSettings())
            try expectEqual(planned.map(\.kind), [.readyToMerge])
            try expectEqual(planned[0].title, "o/r#7 is ready to merge")
            try expectEqual(planned[0].body, "PR 7")
            try expectEqual(planned[0].url?.absoluteString, "https://github.com/o/r/pull/7")
            try expectEqual(planned[0].identifier, "readyToMerge:o/r#7")
        },
        TestCase("ready notif: ya aprobado que pasa de feedback a listo → readyToMerge") {
            let planned = NotificationPlanner.plan(
                previous: snap(mine(.myFeedback, decision: .approved)), current: snap(mine(.readyToMerge, decision: .approved)),
                settings: NotificationSettings())
            try expectEqual(planned.map(\.kind), [.readyToMerge])
        },
        TestCase("ready notif: con readyToMerge apagado sale el aviso de aprobado") {
            var settings = NotificationSettings()
            settings.readyToMerge = false
            let planned = NotificationPlanner.plan(
                previous: snap(mine(.other, decision: .reviewRequired)), current: snap(mine(.readyToMerge, decision: .approved)),
                settings: settings)
            try expectEqual(planned.map(\.kind), [.myPRApprovedOrCIFailed])
            try expectEqual(planned[0].title, "Your PR Was Approved")
        },
        TestCase("ready notif: si sigue listo no repite; un CI que falla igual avisa") {
            let ready = snap(mine(.readyToMerge, decision: .approved))
            try expectEqual(NotificationPlanner.plan(previous: ready, current: ready, settings: NotificationSettings()), [])
            let failing = snap(mine(.readyToMerge, decision: .approved, ci: .failure))
            let planned = NotificationPlanner.plan(previous: ready, current: failing, settings: NotificationSettings())
            try expectEqual(planned.map(\.title), ["CI Failed on Your PR"])
        },
        TestCase("ready notif: config vieja sin la clave → encendida; respeta el interruptor general") {
            let old = try JSONCoding.decoder.decode(NotificationSettings.self, from: Data(#"{"enabled":true}"#.utf8))
            try expect(old.readyToMerge)
            try expect(old.isOn(.readyToMerge))
            var off = NotificationSettings()
            off.enabled = false
            try expect(!off.isOn(.readyToMerge))
        },
    ]
}
