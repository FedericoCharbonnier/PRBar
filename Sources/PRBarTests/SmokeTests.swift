import PRBarCore

enum SmokeTests {
    static let cases: [TestCase] = [
        TestCase("smoke: versión del core") {
            try expectEqual(PRBarCore.version, "0.1.0")
        },
    ]
}
