import Foundation
import PRBarCore

enum SemanticVersionTests {
    static let cases: [TestCase] = [
        TestCase("semver: releaseTag acepta solo vX.Y.Z exacto") {
            try expectEqual(SemanticVersion(releaseTag: "v1.2.3"), SemanticVersion(1, 2, 3))
            try expectEqual(SemanticVersion(releaseTag: "v0.10.0"), SemanticVersion(0, 10, 0))
            for tag in ["1.2.3", "V1.2.3", "v01.2.3", "v1.02.3", "v1.2.03", "v1.2.3+b", "v1.2.3-beta.1", " v1.2.3",
                        "v1.2.3 ", "v1.2.3\n", "v1.2", "v1.2.3.4", "v-1.2.3", "v1.2.3a", "v１.2.3", ""] {
                try expectEqual(SemanticVersion(releaseTag: tag), nil)
            }
        },
        TestCase("semver: parsea X.Y.Z con y sin v, con espacios y metadata de build") {
            try expectEqual(SemanticVersion("1.2.3"), SemanticVersion(1, 2, 3))
            try expectEqual(SemanticVersion("v1.2.3"), SemanticVersion(1, 2, 3))
            try expectEqual(SemanticVersion(" v10.0.12 \n"), SemanticVersion(10, 0, 12))
            try expectEqual(SemanticVersion("1.2.3+build.5"), SemanticVersion(1, 2, 3))
            try expectEqual(SemanticVersion(1, 2, 3).description, "1.2.3")
        },
        TestCase("semver: prerelease") {
            let beta = SemanticVersion("v2.0.0-beta.1")
            try expectEqual(beta?.prerelease, "beta.1")
            try expect(beta?.isPrerelease == true)
            try expectEqual(beta?.description, "2.0.0-beta.1")
            try expect(SemanticVersion("2.0.0")?.isPrerelease == false)
        },
        TestCase("semver: rechaza lo que no es X.Y.Z") {
            let invalid = ["", "v", "1", "1.2", "1.2.3.4", "1..3", "a.b.c", "1.2.x", "-1.2.3", "1.2.3-", "1.2.3-bé",
                           "nightly", "--upload-pack=x", "1.2.3456789012"]
            for text in invalid {
                try expect(SemanticVersion(text) == nil, "\"\(text)\" should be rejected")
            }
        },
        TestCase("semver: orden (números, prerelease antes que la final, prerelease numérico)") {
            let texts = ["0.1.0", "0.9.9", "1.0.0-alpha", "1.0.0-beta.2", "1.0.0-beta.10", "1.0.0", "1.0.1", "1.2.0",
                         "1.10.0", "2.0.0"]
            let ordered = texts.compactMap { SemanticVersion($0) }
            try expectEqual(ordered.count, texts.count)
            try expectEqual(ordered.shuffled().sorted(), ordered)
            try expect(SemanticVersion(1, 3, 0) > SemanticVersion(1, 2, 9))
            try expect(!(SemanticVersion(1, 3, 0) < SemanticVersion(1, 3, 0)))
        },
        TestCase("semver: JSON como string") {
            let data = try JSONCoding.encoder.encode([SemanticVersion(1, 3, 0)])
            try expectEqual(String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }, #"["1.3.0"]"#)
            let decoded = try JSONCoding.decoder.decode([SemanticVersion].self, from: Data(#"["v2.0.1"]"#.utf8))
            try expectEqual(decoded, [SemanticVersion(2, 0, 1)])
            let bad = try? JSONCoding.decoder.decode([SemanticVersion].self, from: Data(#"["latest"]"#.utf8))
            try expect(bad == nil)
        },
    ]
}
