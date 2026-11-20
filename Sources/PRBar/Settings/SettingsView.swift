import AppKit
import PRBarCore
import SwiftUI

/// Ventana de Configuración con pestañas en la barra de herramientas (estilo Ajustes de macOS): el título de la
/// ventana es el de la pestaña elegida.
///
/// Se arma con `NSTabViewController(.toolbar)` en vez de la escena `Settings` de SwiftUI: en una app
/// LSUIElement que cambia de política de activación, `Settings` no avisa cuándo se cierra su ventana (para volver
/// a `.accessory`), no se trae al frente sola y en macOS 14 solo se abre desde `SettingsLink`/`openSettings`
/// dentro de vistas SwiftUI. Así la ventana pasa por `WindowPresenter` como las demás.
enum SettingsWindow {
    private static let selectedTabKey = "SettingsSelectedTabID"

    /// Pestañas en orden, con el tamaño de contenido de cada una: al cambiar de pestaña la ventana se anima a ese
    /// tamaño (el comportamiento estándar de `NSTabViewController` con estilo `.toolbar`).
    enum Tab: String, CaseIterable {
        case general, claude, instructions, accounts, repos, slack

        var title: String {
            switch self {
            case .general: "General"
            case .claude: "Claude"
            case .instructions: "Instructions"
            case .accounts: "Accounts"
            case .repos: "Repos"
            case .slack: "Slack"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .claude: "sparkles"
            case .instructions: "text.book.closed"
            case .accounts: "person.crop.circle"
            case .repos: "books.vertical"
            case .slack: "number"
            }
        }

        var contentSize: NSSize {
            switch self {
            case .general: NSSize(width: 700, height: 500)
            case .claude: NSSize(width: 700, height: 500)
            case .instructions: NSSize(width: 700, height: 640)
            case .accounts: NSSize(width: 700, height: 300)
            case .repos: NSSize(width: 700, height: 580)
            case .slack: NSSize(width: 700, height: 620)
            }
        }
    }

    /// The window grows only in height (the panes are laid out for 700 pt); each tab opens at its `contentSize`, and
    /// can be made taller for long pages like Claude, or shorter down to the smallest tab (Accounts).
    static let minContentSize = NSSize(width: 700, height: 300)
    static let maxContentSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)

    /// La pestaña que se eligió la última vez (General si no hay ninguna guardada).
    /// La ventana de Settings abierta (para cambiar de pestaña desde la CLI).
    @MainActor private static weak var current: NSTabViewController?

    /// Elige `tab`: la recuerda para la próxima vez y, si la ventana está abierta, cambia a esa pestaña.
    @MainActor
    static func select(_ tab: Tab) {
        UserDefaults.standard.set(tab.rawValue, forKey: selectedTabKey)
        current?.selectedTabViewItemIndex = Tab.allCases.firstIndex(of: tab) ?? 0
    }

    static var savedTab: Tab {
        UserDefaults.standard.string(forKey: selectedTabKey).flatMap(Tab.init(rawValue:)) ?? .general
    }

    /// `tab`: opens on that tab and doesn't remember the selection, and the controls draw as in the key window
    /// even though the window never becomes key (snapshot mode). `nil` opens the saved tab.
    @MainActor
    static func makeController(model: AppModel, tab initialTab: Tab? = nil) -> NSViewController {
        let tabs = SettingsTabViewController()
        tabs.drawsAsKey = initialTab != nil
        tabs.tabStyle = .toolbar
        let store = model.configStore
        for tab in Tab.allCases {
            switch tab {
            case .general:
                tabs.addTab(tab, model: model) { GeneralTab(model: model, configStore: store) }
            case .claude:
                tabs.addTab(tab, model: model) { ClaudeTab(model: model, configStore: store, skills: model.claudeSkills) }
            case .instructions:
                tabs.addTab(tab, model: model) {
                    InstructionsTab(model: model, store: model.instructions, chat: model.instructionsChat, configStore: store)
                }
            case .accounts:
                tabs.addTab(tab, model: model) { AccountsTab(model: model, configStore: store) }
            case .repos:
                tabs.addTab(tab, model: model) {
                    ReposTab(model: model, configStore: store, slack: model.slack, catalog: model.catalog)
                }
            case .slack:
                tabs.addTab(tab, model: model) { SlackTab(model: model, configStore: store, slack: model.slack) }
            }
        }
        tabs.selectedTabViewItemIndex = Tab.allCases.firstIndex(of: initialTab ?? savedTab) ?? 0
        guard initialTab == nil else { return tabs }
        current = tabs
        tabs.onSelect = { index in
            guard Tab.allCases.indices.contains(index) else { return }
            UserDefaults.standard.set(Tab.allCases[index].rawValue, forKey: selectedTabKey)
        }
        return tabs
    }
}

private final class SettingsTabViewController: NSTabViewController {
    var onSelect: ((Int) -> Void)?
    var drawsAsKey = false

    func addTab<Content: View>(_ tab: SettingsWindow.Tab, model: AppModel, @ViewBuilder content: () -> Content) {
        let pane = SettingsPane(model: model, configStore: model.configStore, content: content())
        let hosting = NSHostingController(rootView: pane.modifier(DrawsAsKey(enabled: drawsAsKey)))
        // Each tab has its own size; choosing it animates the window to that size (the user can then make it taller).
        hosting.sizingOptions = []
        hosting.preferredContentSize = tab.contentSize
        hosting.title = tab.title
        let item = NSTabViewItem(viewController: hosting)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?(selectedTabViewItemIndex)
    }
}

/// Snapshot mode: the controls draw as in the key window (the offscreen window never becomes key).
private struct DrawsAsKey: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.environment(\.controlActiveState, .key)
        } else {
            content
        }
    }
}

/// Contenido de una pestaña con el error de configuración (si hay) arriba.
private struct SettingsPane<Content: View>: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore
    let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if let error = configStore.loadError ?? model.settingsError {
                // Alineado con las secciones de los `Form` agrupados (20 pt de margen).
                ErrorBanner(messages: [error], horizontalInset: 20)
                    .padding(.top, 12)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Selector de cuenta de la pestaña Repos.
struct AccountPicker: View {
    let logins: [String]
    @Binding var selection: String

    var body: some View {
        if logins.count > 1 {
            Picker("Account", selection: $selection) {
                ForEach(logins, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

extension ConfigStore {
    var enabledLogins: [String] { config.accounts.filter(\.enabled).map(\.login) }

    func account(_ login: String) -> AccountConfig? {
        config.accounts.first { $0.login == login && $0.enabled }
    }
}
