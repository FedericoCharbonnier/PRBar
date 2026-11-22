import Foundation
import PRBarCore

private let settings = NotificationSettings()
private let repo = RepoRef(owner: "acme", name: "web")

enum NotificationRouteTests {
    static let cases: [TestCase] = [
        TestCase("notificación → destino: review listo, respond, fix CI, merge") {
            let review = try expectSome(NotificationPlanner.reviewFinished(prID: "acme/web#1", repo: repo, number: 1,
                                                                            keptCount: 3, settings: settings))
            try expectEqual(NotificationRoute.target(userInfo: NotificationRoute.userInfo(review)),
                            .destination(.pr(prID: "acme/web#1", tab: .review)))
            let respond = try expectSome(NotificationPlanner.respondFinished(prID: "acme/web#2", repo: repo, number: 2,
                                                                              event: .fixesReady(commits: 1), settings: settings))
            try expectEqual(NotificationRoute.target(userInfo: NotificationRoute.userInfo(respond)),
                            .destination(.pr(prID: "acme/web#2", tab: .respond)))
            let ci = try expectSome(NotificationPlanner.respondFinished(prID: "acme/web#3", repo: repo, number: 3,
                                                                         event: .ciFixReady(commits: 1), settings: settings))
            try expectEqual(ci.tab, .fixCI)
        },
        TestCase("notificación → destino: review fallido va a History; update a la hoja; disco a Activity") {
            let id = UUID()
            let failed = try expectSome(NotificationPlanner.reviewFinished(prID: "acme/web#1", repo: repo, number: 1,
                                                                            keptCount: nil, recordID: id, settings: settings))
            try expectEqual(NotificationRoute.target(userInfo: NotificationRoute.userInfo(failed)),
                            .destination(.history(recordID: id)))
            try expectEqual(NotificationRoute.target(userInfo: ["updateVersion": "1.4.0"]), .updateSheet)
            try expectEqual(NotificationRoute.target(userInfo: ["activity": "1"]), .destination(.activity))
            try expectEqual(NotificationRoute.target(userInfo: ["url": "https://github.com/acme/web/pull/1"]),
                            .url(URL(string: "https://github.com/acme/web/pull/1")!))
            try expectEqual(NotificationRoute.target(userInfo: [:]), nil)
        },
    ]
}
