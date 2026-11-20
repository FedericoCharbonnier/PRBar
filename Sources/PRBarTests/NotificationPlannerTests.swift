import Foundation
import PRBarCore

private func snap(_ items: ClassifiedPR..., scopes: Set<String> = ["me|o/r"], failed: Bool = false) -> Snapshot {
    Snapshot(items: items, fetchedAt: t0, failedCompletely: failed, fetchedScopes: scopes)
}

private func item(_ pr: PullRequest, _ category: PRCategory, account: String = "me") -> ClassifiedPR {
    ClassifiedPR(pr: pr, category: category, account: account)
}

enum NotificationPlannerTests {
    static let cases: [TestCase] = [
        TestCase("notif: primera ejecución no notifica") {
            try expectEqual(NotificationPlanner.plan(previous: nil, current: snap(item(makePR(), .toReview)), settings: NotificationSettings()), [])
        },
        TestCase("notif: PR que entra a Para revisar notifica") {
            let planned = NotificationPlanner.plan(previous: snap(), current: snap(item(makePR(number: 7), .toReview)), settings: NotificationSettings())
            try expectEqual(planned.map(\.kind), [.newToReview])
            try expectEqual(planned[0].title, "New PR to Review")
            try expectEqual(planned[0].body, "r#7 · juan: PR 7")
            try expectEqual(planned[0].url?.absoluteString, "https://github.com/o/r/pull/7")
        },
        TestCase("notif: identificador estable e hilo por PR") {
            let previous = snap(item(makePR(number: 7, author: "me", decision: .reviewRequired), .other))
            let current = snap(item(makePR(number: 7, author: "me", decision: .approved), .other))
            let planned = NotificationPlanner.plan(previous: previous, current: current, settings: NotificationSettings())
            try expectEqual(planned.count, 1)
            let prID = current.items[0].id
            try expectEqual(planned[0].identifier, "myPRApprovedOrCIFailed:approved:\(prID)")
            try expectEqual(planned[0].threadIdentifier, prID)
            let review = NotificationPlanner.reviewFinished(
                prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, keptCount: 3, settings: NotificationSettings())
            try expectEqual(review?.identifier, "reviewFinished:o/r#7")
            try expectEqual(review?.threadIdentifier, "o/r#7")
        },
        TestCase("notif: si el refresco anterior falló por completo no notifica") {
            let planned = NotificationPlanner.plan(previous: snap(scopes: [], failed: true), current: snap(item(makePR(number: 7), .toReview)), settings: NotificationSettings())
            try expectEqual(planned, [])
        },
        TestCase("notif: repo recién agregado no notifica") {
            let newRepo = RepoRef(owner: "o", name: "nuevo")
            let current = snap(item(makePR(repo: newRepo, number: 7), .toReview), scopes: ["me|o/r", "me|o/nuevo"])
            try expectEqual(NotificationPlanner.plan(previous: snap(), current: current, settings: NotificationSettings()), [])
        },
        TestCase("notif: repo que se recupera de un error no notifica") {
            let previous = snap(scopes: [])
            let current = snap(item(makePR(number: 7), .toReview), item(makePR(number: 8, author: "me", decision: .approved), .other))
            let before = snap(item(makePR(number: 8, author: "me", decision: .reviewRequired), .other), scopes: [])
            try expectEqual(NotificationPlanner.plan(previous: previous, current: current, settings: NotificationSettings()), [])
            try expectEqual(NotificationPlanner.plan(previous: before, current: current, settings: NotificationSettings()), [])
        },
        TestCase("notif: cuenta nueva sobre un repo ya consultado no notifica") {
            let current = snap(item(makePR(number: 7), .toReview, account: "otra"), scopes: ["me|o/r", "otra|o/r"])
            try expectEqual(NotificationPlanner.plan(previous: snap(), current: current, settings: NotificationSettings()), [])
        },
        TestCase("notif: sin cambio de categoría no repite") {
            let s = snap(item(makePR(), .toReview))
            try expectEqual(NotificationPlanner.plan(previous: s, current: s, settings: NotificationSettings()), [])
        },
        TestCase("notif: cambio a actualizado y a feedback") {
            let previous = snap(item(makePR(number: 1), .other), item(makePR(number: 2, author: "me"), .other))
            let current = snap(item(makePR(number: 1), .updatedSinceMyReview), item(makePR(number: 2, author: "me"), .myFeedback))
            try expectEqual(NotificationPlanner.plan(previous: previous, current: current, settings: NotificationSettings()).map(\.kind), [.reviewedPRUpdated, .myPRFeedback])
        },
        TestCase("notif: respeta el toggle por tipo y el general") {
            var settings = NotificationSettings()
            settings.newToReview = false
            try expectEqual(NotificationPlanner.plan(previous: snap(), current: snap(item(makePR(), .toReview)), settings: settings), [])
            settings = NotificationSettings()
            settings.enabled = false
            try expectEqual(NotificationPlanner.plan(previous: snap(), current: snap(item(makePR(), .toReview)), settings: settings), [])
        },
        TestCase("notif: mi PR aprobado o con CI fallando") {
            let previous = snap(item(makePR(number: 1, author: "me", ci: .pending, decision: .reviewRequired), .other))
            let current = snap(item(makePR(number: 1, author: "me", ci: .failure, decision: .approved), .other))
            let planned = NotificationPlanner.plan(previous: previous, current: current, settings: NotificationSettings())
            try expectEqual(planned.map(\.title), ["Your PR Was Approved", "CI Failed on Your PR"])
        },
        TestCase("notif: CI de PRs ajenos no notifica") {
            let previous = snap(item(makePR(ci: .pending), .other))
            let current = snap(item(makePR(ci: .failure), .other))
            try expectEqual(NotificationPlanner.plan(previous: previous, current: current, settings: NotificationSettings()), [])
        },
        TestCase("notif: más de 5 eventos se agrupan por tipo") {
            let current = Snapshot(items: (1...7).map { item(makePR(number: $0), .toReview) }, fetchedAt: t0)
            let planned = NotificationPlanner.plan(previous: snap(), current: current, settings: NotificationSettings())
            try expectEqual(planned.count, 1)
            try expectEqual(planned[0].title, "7 new PRs to review")
            try expectEqual(planned[0].url, nil)
        },
        TestCase("notif: review listo con éxito") {
            let planned = NotificationPlanner.reviewFinished(
                prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, keptCount: 3, settings: NotificationSettings())
            try expectEqual(planned?.kind, .reviewFinished)
            try expectEqual(planned?.title, "Review Ready")
            try expectEqual(planned?.body, "r#7: 3 comments to choose from")
            try expectEqual(planned?.reviewPRID, "o/r#7")
            try expectEqual(planned?.url, nil)
        },
        TestCase("notif: review listo con un solo comentario va en singular") {
            let planned = NotificationPlanner.reviewFinished(
                prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, keptCount: 1, settings: NotificationSettings())
            try expectEqual(planned?.body, "r#7: 1 comment to choose from")
        },
        TestCase("notif: review que falló") {
            let planned = NotificationPlanner.reviewFinished(
                prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, keptCount: nil, settings: NotificationSettings())
            try expectEqual(planned?.title, "Review Failed")
            try expectEqual(planned?.body, "r#7: the review failed. Open PRBar to see the log.")
            try expectEqual(planned?.reviewPRID, "o/r#7")
        },
        TestCase("notif: review que falló lleva el id de su registro; uno listo no") {
            let id = UUID()
            let failed = NotificationPlanner.reviewFinished(
                prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, keptCount: nil, recordID: id, settings: NotificationSettings())
            try expectEqual(failed?.reviewRecordID, id)
            let ready = NotificationPlanner.reviewFinished(
                prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, keptCount: 2, recordID: id, settings: NotificationSettings())
            try expectEqual(ready?.reviewRecordID, nil)
        },
        TestCase("notif: review listo con el toggle apagado no notifica") {
            var settings = NotificationSettings()
            settings.reviewFinished = false
            try expectEqual(NotificationPlanner.reviewFinished(
                prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, keptCount: 3, settings: settings), nil)
            settings = NotificationSettings()
            settings.enabled = false
            try expectEqual(NotificationPlanner.reviewFinished(
                prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, keptCount: nil, settings: settings), nil)
        },
            TestCase("notif: hitos de Responder con su texto, id estable y respondPRID") {
            let repo = RepoRef(owner: "o", name: "r")
            let settings = NotificationSettings()
            let analysis = NotificationPlanner.respondFinished(prID: "o/r#7", repo: repo, number: 7, event: .analysisReady(count: 3), settings: settings)
            try expectEqual(analysis?.title, "Analysis Ready")
            try expectEqual(analysis?.body, "r#7: 3 comments")
            try expectEqual(analysis?.respondPRID, "o/r#7")
            try expectEqual(analysis?.reviewPRID, nil)
            try expectEqual(analysis?.identifier, "reviewFinished:respond-analysis:o/r#7")
            try expectEqual(analysis?.threadIdentifier, "o/r#7")
            let one = NotificationPlanner.respondFinished(prID: "o/r#7", repo: repo, number: 7, event: .analysisReady(count: 1), settings: settings)
            try expectEqual(one?.body, "r#7: 1 comment")
            let fixes = NotificationPlanner.respondFinished(prID: "o/r#7", repo: repo, number: 7, event: .fixesReady(commits: 2), settings: settings)
            try expectEqual(fixes?.body, "r#7: 2 unpushed commits")
            let published = NotificationPlanner.respondFinished(
                prID: "o/r#7", repo: repo, number: 7, event: .published(replies: 1, pushed: true), settings: settings)
            try expectEqual(published?.title, "Replies Posted")
            try expectEqual(published?.body, "r#7: fixes pushed and 1 reply posted")
            let replies = NotificationPlanner.respondFinished(
                prID: "o/r#7", repo: repo, number: 7, event: .published(replies: 3, pushed: false), settings: settings)
            try expectEqual(replies?.body, "r#7: 3 replies posted")
            let failed = NotificationPlanner.respondFinished(prID: "o/r#7", repo: repo, number: 7, event: .failed, settings: settings)
            try expectEqual(failed?.title, "Couldn't Respond")
        },
        TestCase("notif: Responder usa el interruptor de reviews terminadas") {
            var settings = NotificationSettings()
            settings.reviewFinished = false
            try expectEqual(NotificationPlanner.respondFinished(
                prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, event: .analysisReady(count: 2), settings: settings), nil)
        },
        TestCase("notificaciones: aviso de disco con el total y el umbral") {
            let planned = NotificationPlanner.diskWarning(totalBytes: 6_400_000_000, limitGB: 5, settings: NotificationSettings())
            try expectEqual(planned?.kind, .diskUsage)
            try expectEqual(planned?.title, "PRBar Is Using a Lot of Disk")
            try expectEqual(planned?.body, "PRBar is using 6.4 GB (your limit is 5 GB). Open PRBar Activity to clean up.")
            var off = NotificationSettings()
            off.enabled = false
            try expectEqual(NotificationPlanner.diskWarning(totalBytes: 6_400_000_000, limitGB: 5, settings: off), nil)
        },
]
}
