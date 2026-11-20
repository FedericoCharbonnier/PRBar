import SwiftUI
import PRBarMobileCore

// Xcode previews of every screen in light and dark, on the demo graph (design's sample data).

#Preview("App · light") { RootView(app: .demo()) }
#Preview("App · dark") { RootView(app: .demo()).preferredColorScheme(.dark) }
#Preview("home:offline") { RootView(app: .demo(online: false)) }
#Preview("pair:welcome · light") { PairWelcome(message: nil) {} }
#Preview("pair:welcome · dark") { PairWelcome(message: nil) {}.preferredColorScheme(.dark) }
#Preview("pair:scan") { PairScan(error: nil, joiningMac: nil, cancel: {}, scanned: { _ in }) }
#Preview("pair:paired · light") {
    PairPaired(macName: Sample.macName, code: "482 913", waiting: false, match: {}, dontMatch: {})
}
#Preview("pair:paired · dark") {
    PairPaired(macName: Sample.macName, code: "482 913", waiting: false, match: {}, dontMatch: {})
        .preferredColorScheme(.dark)
}
#Preview("review · light") { NavigationStack { ReviewScreen(model: PhoneApp.demo().reviewModel("acme/api#317"), app: nil) } }
#Preview("review · dark") {
    NavigationStack { ReviewScreen(model: PhoneApp.demo().reviewModel("acme/api#317"), app: nil) }.preferredColorScheme(.dark)
}
#Preview("respond") {
    NavigationStack { RespondScreen(model: PhoneApp.demo().respondModel("acme/web-app#475", .feedback), app: nil) }
}
#Preview("respond:fixci · dark") {
    NavigationStack { RespondScreen(model: PhoneApp.demo().respondModel("acme/web-app#488", .ciFix), app: nil) }
        .preferredColorScheme(.dark)
}
#Preview("merge · light") { NavigationStack { MergeScreen(model: PhoneApp.demo().mergeModel("acme/api#322"), app: nil) } }
#Preview("merge · dark") {
    NavigationStack { MergeScreen(model: PhoneApp.demo().mergeModel("acme/api#322"), app: nil) }.preferredColorScheme(.dark)
}
#Preview("chat:review") { ChatScreen(model: PhoneApp.demo().chatModel("acme/api#317", .review)) }
#Preview("chat:merge · dark") {
    ChatScreen(model: PhoneApp.demo().chatModel("acme/api#322", .merge)).preferredColorScheme(.dark)
}
#Preview("activity") { ActivityScreen(model: PhoneApp.demo().activityModel(), home: PhoneApp.demo().home) }
#Preview("settings · dark") { SettingsScreen(model: PhoneApp.demo().settingsModel()).preferredColorScheme(.dark) }
