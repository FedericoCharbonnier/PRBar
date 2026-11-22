import Foundation
import PRBarCore

private func dest(_ string: String) -> MainDestination? { PRBarURL.destination(URL(string: string)!) }

enum PRBarURLTests {
    static let cases: [TestCase] = [
        TestCase("prbar://: PR con y sin pestaña") {
            try expectEqual(dest("prbar://pr/acme/web/482"), .pr(prID: "acme/web#482", tab: nil))
            try expectEqual(dest("prbar://pr/acme/web/482/fix-ci"), .pr(prID: "acme/web#482", tab: .fixCI))
            try expectEqual(dest("PRBAR://pr/acme/web/482/Merge"), .pr(prID: "acme/web#482", tab: .merge))
            // Los links del iPhone (`?screen=`) también se entienden.
            try expectEqual(dest("prbar://pr/acme/web/482?screen=respond"), .pr(prID: "acme/web#482", tab: .respond))
        },
        TestCase("prbar://: secciones") {
            try expectEqual(dest("prbar://review"), .list(.toReview))
            try expectEqual(dest("prbar://mine"), .list(.myPRs))
            try expectEqual(dest("prbar://history"), .history(recordID: nil))
            try expectEqual(dest("prbar://activity"), .activity)
        },
        TestCase("prbar://: lo que no se entiende es nil (la app abre la ventana sin moverse)") {
            for bad in ["prbar://pr/acme/web", "prbar://pr/acme/web/x", "prbar://pr/acme/web/0", "prbar://pr/a%20b/web/1",
                        "prbar://pr/acme/web/1/nope", "prbar://home", "prbar://pair?v=1", "https://pr/acme/web/1",
                        "prbar://review/extra"] {
                try expect(dest(bad) == nil, "\(bad) debería ser nil")
            }
        },
        TestCase("prbar://: ida y vuelta") {
            for destination: MainDestination in [.list(.toReview), .list(.myPRs), .history(recordID: nil), .activity,
                                                 .pr(prID: "acme/web#482", tab: nil), .pr(prID: "acme/web#482", tab: .fixCI)] {
                let url = try expectSome(PRBarURL.url(for: destination))
                try expectEqual(PRBarURL.destination(url), destination)
            }
        },
        TestCase("prbar://: Info.plist registra el esquema") {
            let plist = try InfoPlist.read()
            let types = try expectSome(plist["CFBundleURLTypes"] as? [[String: Any]])
            try expect(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(PRBarURL.scheme) == true })
        },
    ]
}
