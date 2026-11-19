import Foundation
import PRBarCore

enum PRReferenceTests {
    static let cases: [TestCase] = [
        TestCase("pr ref: owner/repo#N, repo#N y URL") {
            try expectEqual(PRReference.parse("acme/api#12"), .full(owner: "acme", repo: "api", number: 12))
            try expectEqual(PRReference.parse("api#12"), .short(repo: "api", number: 12))
            try expectEqual(PRReference.parse("https://github.com/acme/api/pull/12"), .full(owner: "acme", repo: "api", number: 12))
            try expectEqual(PRReference.parse("https://github.com/acme/api/pull/12/files#diff-1"),
                            .full(owner: "acme", repo: "api", number: 12))
            try expectEqual(PRReference.parse(" acme/my.repo_2#3 "), .full(owner: "acme", repo: "my.repo_2", number: 3))
        },
        TestCase("pr ref: rechaza lo que no es un PR") {
            let invalid = ["", "acme/api", "api#", "api#0", "api#-1", "a/b/c#1", "#4", "ac me/api#1",
                           "https://github.com/acme/api/issues/3", "https://example.com/acme/api/pull/3"]
            for text in invalid {
                try expect(PRReference.parse(text) == nil, text)
            }
        },
        TestCase("pr ref: resolve sin distinguir mayúsculas y con repo corto único") {
            let ids = ["acme/api#12", "acme/web#12", "other/api#3"]
            try expectEqual(PRReference.full(owner: "ACME", repo: "Api", number: 12).resolve(among: ids), .success("acme/api#12"))
            try expectEqual(PRReference.short(repo: "web", number: 12).resolve(among: ids), .success("acme/web#12"))
            try expectEqual(PRReference.short(repo: "api", number: 9).resolve(among: ids), .failure(.notFound))
            try expectEqual(PRReference.full(owner: "acme", repo: "api", number: 3).resolve(among: ids), .failure(.notFound))
        },
        TestCase("pr ref: repo corto ambiguo") {
            let ids = ["other/api#3", "acme/api#3"]
            try expectEqual(PRReference.short(repo: "api", number: 3).resolve(among: ids),
                            .failure(.ambiguous(["acme/api#3", "other/api#3"])))
        },
        TestCase("pr ref: URL de GitHub a partir del id") {
            try expectEqual(PRReference.githubURL(prID: "acme/api#12")?.absoluteString, "https://github.com/acme/api/pull/12")
            try expectEqual(PRReference.githubURL(prID: "nope"), nil)
        },
    ]
}
