import Foundation
import Testing
import PRBarMobileCore

@Suite struct SmokeTests {
    @Test func deepLinksParse() {
        #expect(DeepLink(URL(string: "prbar://pr/acme/api/317")!) == .pr(id: "acme/api#317", screen: nil))
    }
}
