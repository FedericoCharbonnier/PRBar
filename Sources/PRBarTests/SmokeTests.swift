import PRBarCore

enum SmokeTests {
    static let cases: [TestCase] = [
        TestCase("smoke: la versión del core coincide con Info.plist") {
            // `Scripts/release.sh` cambia las dos a la vez; si alguien toca una sola, esto falla.
            let plist = try InfoPlist.read()
            try expectEqual(plist["CFBundleShortVersionString"] as? String, PRBarCore.version)
            let build = plist["CFBundleVersion"] as? String ?? ""
            try expect(!build.isEmpty && build.allSatisfy { $0.isASCII && $0.isNumber }, "CFBundleVersion: \(build)")
        },
    ]
}
