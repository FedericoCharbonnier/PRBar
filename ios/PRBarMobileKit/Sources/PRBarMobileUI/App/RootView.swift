import SwiftUI
import PRBarMobileCore

/// Pairing the first time; afterwards the four tabs with a navigation stack each.
public struct RootView: View {
    @Bindable var app: PhoneApp
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme

    public init(app: PhoneApp) {
        self.app = app
    }

    public var body: some View {
        Group {
            if app.needsPairing {
                PairingFlow(model: app.pairing, revokedFrom: revokedMac)
            } else {
                tabs
            }
        }
        .sheet(isPresented: $app.isPairingSheetPresented, onDismiss: { app.pairing.cancelScanning() }) {
            PairingFlow(model: app.pairing)
                .onChange(of: app.pairing.step) { _, step in
                    if step == .welcome { app.isPairingSheetPresented = false }
                }
        }
        .onOpenURL { url in
            if let link = DeepLink(url) { app.open(link) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await app.connection.enterForeground() }
            case .background: app.connection.enterBackground()
            default: break
            }
        }
    }

    var revokedMac: String? {
        if case .revoked(let mac) = app.connection.state { return mac ?? "your Mac" }
        return nil
    }

    var tabs: some View {
        TabView(selection: $app.tab) {
            Tab("To Review", systemImage: "tray", value: AppTab.toReview) {
                stack(.toReview) { HomeScreen(app: app, tab: .toReview) }
            }
            .badge(app.home.count(.toReview))
            Tab("My PRs", systemImage: "arrow.triangle.pull", value: AppTab.mine) {
                stack(.mine) { HomeScreen(app: app, tab: .mine) }
            }
            Tab("Activity", systemImage: "gauge.with.dots.needle.50percent", value: AppTab.activity) {
                stack(.activity) { ActivityScreen(model: app.activityModel(), home: app.home) }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                stack(.settings) { SettingsScreen(model: app.settingsModel(), app: app) }
            }
        }
        .tint(Tokens.accentfg.color(scheme))
        .modifier(TabBarMinimize())
    }

    func stack<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: Binding(get: { app.path(tab) }, set: { app.paths[tab] = $0 })) {
            content()
                .hidesSystemNavigationBar()
                .navigationDestination(for: Route.self) { route in
                    destination(route).hidesSystemNavigationBar()
                }
        }
    }

    @ViewBuilder func destination(_ route: Route) -> some View {
        switch route {
        case .review(let pr): ReviewScreen(model: app.reviewModel(pr), app: app)
        case .respond(let pr, let mode): RespondScreen(model: app.respondModel(pr, mode), app: app)
        case .merge(let pr): MergeScreen(model: app.mergeModel(pr), app: app)
        case .chat(let pr, let kind): ChatScreen(model: app.chatModel(pr, kind))
        case .pr(let pr): PRSummaryScreen(app: app, pr: pr)
        }
    }
}

struct TabBarMinimize: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.tabBarMinimizeBehavior(.onScrollDown)
        #else
        content
        #endif
    }
}

extension View {
    /// Screens draw their own glass header (design § Navigation).
    func hidesSystemNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}
