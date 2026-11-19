import Foundation
import PRBarCLIKit

enum CLISmokeTests {
    static let cases: [TestCase] = [
        TestCase("cli: el kit compila y se llama prbar") {
            try expectEqual(PRBarCLIKit.commandName, "prbar")
        },
    ]
}
