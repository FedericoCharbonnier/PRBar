import SwiftUI
import PRBarMobileUI

@main
struct PRBarMobileApp: App {
    @State private var app = AppBootstrap.make()

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
        }
    }
}
