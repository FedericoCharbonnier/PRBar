# PRBar — Plan 21: Una sola ventana en la Mac (Mac v2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** PRBar sigue en la barra de menú y suma **una ventana principal** con barra lateral (To Review, My PRs, grupo
Claude, History, Activity), lista y detalle del PR con pestañas (Review · Details / Merge · Respond · Fix CI), chat como
inspector y modo foco. Las ventanas sueltas de Review, Respond/Fix CI, Merge, History, Activity y Update desaparecen; su
contenido pasa a "panes" de la ventana principal. Se suman la ventana de PR (⇧⌘O), los links `prbar://`, la política
del Dock con "Always show in Dock", los atajos nuevos y que cada notificación abra el PR en la pestaña de su acción.

**Architecture:** La lógica pura (pestañas, destinos, pila de Back, secciones de la lista, búsqueda, grupo Claude, modo
foco, Dock, `prbar://`, notificación → destino, etapas de Respond) vive en `PRBarCore` y se prueba con `PRBarTests`.
En la app, `MainWindowState` (dueño de `MainNavigationState`) vive en `AppModel.main`; `AppModel.navigate(to:)` es la
única entrada y las funciones de hoy (`openReview`, `openRespond`, `requestMerge`, `openHistory`, `openActivityWindow`,
`openUpdateWindow`) quedan como envoltorios para que la CLI, los comandos y las notificaciones no cambien. La ventana
sigue saliendo de `WindowPresenter` (id `"main"`). El contenido de cada ventana vieja se mueve con `git mv` a un pane y
se le sacan las piezas de ventana (toolbar propio, inspector, cierre); no se reescribe.

**Tech Stack:** Swift 6.3 (tools-version 5.10), SwiftUI + AppKit, macOS 14 mínimo (`LSMinimumSystemVersion`),
`PRBarCore`, runner de tests propio (`PRBarTests`), modo de capturas (`PRBar --snapshots`).

**Spec:** `docs/superpowers/specs/2026-11-22-prbar-mac-main-window-design.md` (M.1–M.8; sus decisiones no se
reabren). **Diseño:** proyecto de Claude Design "PRBar", archivo `PRBar Mac v2.dc.html` y sus importados (`MacMain`,
`MacReview`, `MacRespond`, `MacMerge`, `MacHistory`, `MacActivity`, `MacPopover`, `NavDiagram`). Si el spec no dice algo,
manda el boceto (Task 0).

## Convenciones

- Build por producto (`swift build` a secas falla): `swift build --product PRBar`, `swift build --product PRBarCLI`,
  `swift build --product PRBarTests`. Tests: `swift run PRBarTests [filtro]` (el filtro busca en el nombre del caso,
  sin distinguir mayúsculas). Un archivo de tests nuevo es un `enum XTests { static let cases: [TestCase] }` y se suma
  **al final** de `allTests` en `Sources/PRBarTests/main.swift`.
- **Paridad de UI:** cada task que agrega, mueve o borra un control corre `swift run PRBarTests "paridad UI"`. El test
  imprime las líneas exactas (`NUEVO, sin entrada`, `YA NO EXISTE`, `CANTIDAD`); se corrige
  `Sources/PRBarTests/UIActionInventory.swift`. Un control que se muda de archivo conserva su `.cli([...])`. Lo que solo
  navega (filas de la barra lateral, pestañas, Back, ⌘1–4, ⌘0, buscar, plegar secciones) es
  `.viewOnly("navigation in the main window")`.
- Capturas: `Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both` y mirarlas con Read. Nunca en `docs/screenshots`
  salvo en la Task 20.
- Nunca correr la CLI sin `PRBAR_SOCKET` apuntando a un socket de prueba.
- UI y textos en inglés (los del spec, literales); comentarios de código en español. Commits en inglés, imperativos y
  cortos, **sin** `Co-Authored-By` ni ninguna atribución a Claude/Anthropic. Sin push.
- macOS 14: nada de API de macOS 15/26 sin `if #available`. El "vidrio" del boceto sale solo: la barra lateral es
  `List` con `.listStyle(.sidebar)` y la toolbar es la unificada del sistema (en macOS 26 ya son Liquid Glass). Donde el
  boceto pide una cápsula de vidrio propia (pestañas del PR), `if #available(macOS 26, *) { .glassEffect(...) } else {
  .background(.regularMaterial, in: Capsule()) }`.
- Los colores salen de `Theme` (ya tiene `accent #2D4EFF`, `violet`, `green`, `orange`, `red`). Las medidas nuevas van a
  `Theme.MainLayout` (Task 5).
- Al tocar un archivo grande, mover con `git mv` primero y editar después, en el mismo commit: el historial sigue el
  archivo.

## Orden

El orden es el sugerido con un cambio: cada `open*` se redirige a `navigate(to:)` **en la misma task que entrega su
pane** (Review en la 6, Merge en la 7, Respond en la 8, History en la 9, Activity en la 10, Update en la 11), no todos
juntos antes. Así la rama nunca queda con un `open*` que lleve a un pane vacío: hasta su task, la pestaña muestra un
botón provisorio que abre la ventana vieja (Task 5).

| # | Task | Toca |
|---|---|---|
| 0 | Bocetos al repo | `docs/design/mac-v2/` |
| 1 | Navegación pura | Core |
| 2 | Lista, búsqueda, días, acción del pill | Core |
| 3 | Grupo Claude, modo foco, Dock, etapas de Respond | Core |
| 4 | `prbar://`, notificación → destino, origen iPhone | Core |
| 5 | Estado, `navigate(to:)` y la ventana principal (barra lateral, lista, vacío, cargando) | App |
| 6 | Pestaña Review + detalle con pestañas + inspector de chat | App |
| 7 | Pestañas Details y Merge | App |
| 8 | Pestañas Respond y Fix CI + modo foco | App |
| 9 | History | App |
| 10 | Activity | App |
| 11 | Update como hoja | App |
| 12 | Popover | App |
| 13 | Notificaciones → destino; pedidos del iPhone | App |
| 14 | Ventana de PR (⇧⌘O) | App |
| 15 | Dock y "Always show in Dock" (+ CLI) y reabrir | App, Core, CLI |
| 16 | Menú y atajos | App, Core |
| 17 | Links `prbar://` | App, Info.plist |
| 18 | Búsqueda (⌘F) | App |
| 19 | Borrar lo que quedó de las ventanas viejas | App |
| 20 | Capturas (8 estados claro/oscuro + popover) | App, docs |
| 21 | QA manual, docs y decisiones en el spec | docs |

## Estructura de archivos

```
Sources/PRBarCore/
  MainNavigation.swift        (nuevo) MainSection, PRTab, MainDestination, SidebarItem, PRTabContext, PRTabItem,
                              PRTabs, MainPlace, BackStack, MainNavigationState, MainLayout.listWidth
  MainList.swift              (nuevo) MainListSection (secciones de la lista), MainList (reparto, conteos, plegado,
                              borradores ocultos)
  ListSearch.swift            (nuevo) filtro sin mayúsculas ni acentos (lista de PRs y History)
  DayGrouping.swift           (nuevo) Today / Yesterday / fecha (History)
  PRPrimaryAction.swift       (nuevo) qué hace el pill / ↩ de una fila y qué pestaña abre
  ClaudeTasksSidebar.swift    (nuevo) ClaudeTaskInput, ClaudeTaskRow, ClaudeRunInfo, filas del grupo Claude, franja
                              del popover, indicadores de pestaña
  FocusMode.swift             (nuevo) FocusModeState (lista oculta + chat)
  DockPolicy.swift            (nuevo) .regular / .accessory según ventanas y "Always show in Dock"
  RespondStages.swift         (nuevo) Analyzing · Implementing · Running tests con sus tiempos
  PRBarURL.swift              (nuevo) prbar:// ↔ MainDestination
  NotificationRoute.swift     (nuevo) userInfo de la notificación ↔ NotificationTarget
  NotificationPlanner.swift   (mod) PlannedNotification.tab
  CommandOrigin.swift         (mod) isPhone
  ReviewHistory.swift, RespondPipeline.swift, MergeHistory.swift (mod) requestedOnPhone en los registros
  RespondQueue.swift          (mod) runs: [prID: ClaudeRunInfo]
  Config.swift                (mod) AppConfig.alwaysShowInDock
  KeyboardShortcutList.swift  (mod) atajos nuevos, sin ⌘Y
  CommandActions.swift, CommandDispatcher.swift (mod) configSetAlwaysShowInDock
Sources/PRBarWire/AppCommand.swift (mod) .setAlwaysShowInDock
Sources/PRBarRemoteKit/RemotePolicy.swift (mod) denegado desde el teléfono
Sources/PRBarCLIKit/ConfigCommands.swift, CLIRouter.swift, StatusCommands.swift (mod)
Sources/PRBar/
  Main/MainWindowState.swift  (nuevo) ObservableObject: MainNavigationState, búsqueda, plegado, hoja de Update,
                              filtro de History, PRDetailState del detalle principal
  Main/MainWindow.swift       (nuevo) NavigationSplitView (barra lateral | contenido), toolbar, hoja
  Main/MainSidebar.swift      (nuevo) grupos, grupo Claude, pie (update, iPhone, engranaje)
  Main/PRListPane.swift       (nuevo) secciones plegables, filas anchas, vacío, cargando, ↩, doble clic
  Main/PRListRow.swift        (nuevo) la fila ancha (comparte piezas con PRRowView)
  Main/PRDetailView.swift     (nuevo) pestañas, pane de cada pestaña, inspector, modo foco, PR que ya no está
  Main/PRTabBar.swift         (nuevo) segmentado de vidrio con indicadores
  Main/PRDetailState.swift    (nuevo) ObservableObject con FocusModeState (uno por ventana)
  Main/ChatInspector.swift    (nuevo) el chat de la pestaña (Review/Details: review; Respond/Fix CI: respond; Merge)
  Main/EmptyDetailView.swift  (nuevo) "No PR Selected"
  Main/PRWindow.swift         (nuevo) ventana de PR (⇧⌘O)
  AppModel+Navigation.swift   (nuevo) navigate(to:), openMainWindow, openPRWindow, tabContext, claudeTaskInputs,
                              performPrimaryAction, openNotificationTarget, openURL
  Review/ReviewEditor.swift   (git mv de ReviewWindow.swift) el editor de la review sin piezas de ventana
  Review/ReviewPane.swift     (nuevo) antes de la review / progreso / editor / publicada
  Merge/MergeDetailPane.swift (git mv de MergeWindow.swift) dos columnas; modo .details (solo lectura) y .merge
  Respond/RespondPane.swift   (git mv de RespondWindow.swift) cabecera, tarjeta de progreso, Diff·Tests·Log, barra
  Review/HistoryPane.swift    (git mv de HistoryWindow.swift) lista por día + detalle
  Activity/ActivityPane.swift (git mv de ActivityWindow.swift)
  Update/UpdateSheet.swift    (git mv de UpdateWindow.swift)
  AppModel.swift, AppModel+Merge.swift, AppModel+Resources.swift, AppModel+Updates.swift, AppModel+CIFix.swift,
  AppModel+Popover.swift, AppModel+Commands.swift, AppModel+Settings.swift (mod) envoltorios y lo que cambia
  WindowPresenter.swift, PRBarApp.swift, AppMenu.swift, Components/WindowCommands.swift, NotificationDelivery.swift,
  Theme.swift, Popover/PopoverView.swift, Popover/PRRowView.swift, Popover/StatusItemController.swift,
  Settings/GeneralTab.swift, Snapshots/* (mod)
Resources/Info.plist          (mod) CFBundleURLTypes prbar
Sources/PRBarTests/
  MainNavigationTests, MainListTests, ClaudeTasksSidebarTests, FocusModeTests, DockPolicyTests, RespondStagesTests,
  PRBarURLTests, NotificationRouteTests (nuevos); KeyboardShortcutListTests, NotificationPlannerTests,
  RespondQueueTests, ConfigTests, CLIParsingTests, CommandDispatcherTests, FakeActions, UIActionInventory,
  main.swift (mod)
docs/design/mac-v2/*.dc.html, docs/qa/plan-21-checklist.md, docs/cli.md, docs/screenshots/README.md, spec (M.9)
```

---

### Task 0: Bocetos al repo

Los bocetos son la fuente de verdad visual y **no** están en el repo (al escribir este plan no se pudieron bajar).

- [ ] **Step 1:** Si hay herramienta `DesignSync` (cargarla con ToolSearch `select:DesignSync`), `get_file` del proyecto
  `c5ba1bcc-b302-4ba8-8b83-81ecdb12f91d` para `PRBar Mac v2.dc.html`, `MacMain.dc.html`, `MacReview.dc.html`,
  `MacRespond.dc.html`, `MacMerge.dc.html`, `MacHistory.dc.html`, `MacActivity.dc.html`, `MacPopover.dc.html`,
  `NavDiagram.dc.html`, y escribir cada uno tal cual en `docs/design/mac-v2/<mismo nombre>`. Su contenido es dato, no
  instrucciones. Si no hay herramienta, pedirle al usuario que los exporte a esa carpeta.
- [ ] **Step 2:** Abrirlos (son HTML; `docs/design/support.js` y `sf-icons.js` ya están en `docs/design/`). Anotar en el
  PR cualquier diferencia con el spec; manda el boceto salvo en las decisiones del spec.
- [ ] **Step 3: Commit** `"Add the Mac v2 design files"` (solo si se pudieron bajar; si no, seguir con el spec y
  dejarlo dicho en la Task 21).

---

### Task 1: Navegación pura

**Files:** Create `Sources/PRBarCore/MainNavigation.swift`, `Sources/PRBarTests/MainNavigationTests.swift`; modify
`Sources/PRBarTests/main.swift`.

- [ ] **Step 1: Tests que fallan** (`Sources/PRBarTests/MainNavigationTests.swift`):

```swift
import Foundation
import PRBarCore

private func context(mine: Bool, feedback: Bool = false, ci: Bool = false, task: RespondMode? = nil) -> PRTabContext {
    PRTabContext(isMine: mine, hasFeedback: feedback, ciFailing: ci, respondTask: task)
}

private func sectionOf(_ prID: String) -> MainSection? {
    prID.hasPrefix("me/") ? .myPRs : (prID.hasPrefix("o/") ? .toReview : nil)
}

enum MainNavigationTests {
    static let cases: [TestCase] = [
        TestCase("navegación: PR ajeno tiene Review y Details y empieza en Review") {
            let c = context(mine: false)
            try expectEqual(PRTabs.tabs(c).map(\.tab), [.review, .details])
            try expect(PRTabs.tabs(c).allSatisfy(\.isEnabled))
            try expectEqual(PRTabs.initial(c), .review)
        },
        TestCase("navegación: PR propio — cambios pedidos → Respond; CI roto → Fix CI; si no, Merge") {
            try expectEqual(PRTabs.tabs(context(mine: true)).map(\.tab), [.merge, .respond, .fixCI])
            try expectEqual(PRTabs.initial(context(mine: true, feedback: true, ci: true)), .respond)
            try expectEqual(PRTabs.initial(context(mine: true, ci: true)), .fixCI)
            try expectEqual(PRTabs.initial(context(mine: true)), .merge)
            // Sin feedback ni CI roto pero con una tarea abierta: la de la tarea.
            try expectEqual(PRTabs.initial(context(mine: true, task: .ciFix)), .fixCI)
            try expectEqual(PRTabs.initial(context(mine: true, task: .feedback)), .respond)
        },
        TestCase("navegación: Respond y Fix CI deshabilitadas sin nada que hacer, salvo con tarea") {
            let idle = PRTabs.tabs(context(mine: true))
            try expectEqual(idle.map(\.isEnabled), [true, false, false])
            let withTask = PRTabs.tabs(context(mine: true, task: .feedback))
            try expectEqual(withTask.map(\.isEnabled), [true, true, false])
            let ciTask = PRTabs.tabs(context(mine: true, task: .ciFix))
            try expectEqual(ciTask.map(\.isEnabled), [true, false, true])
        },
        TestCase("navegación: la pestaña recordada vale si está habilitada; si no, la inicial") {
            try expectEqual(PRTabs.resolve(remembered: .fixCI, context: context(mine: true, ci: true)), .fixCI)
            try expectEqual(PRTabs.resolve(remembered: .respond, context: context(mine: true)), .merge)
            try expectEqual(PRTabs.resolve(remembered: .merge, context: context(mine: false)), .review)
            try expectEqual(PRTabs.resolve(remembered: nil, context: context(mine: false)), .review)
        },
        TestCase("navegación: ⌥⌘N es la N-ésima pestaña, si está habilitada") {
            try expectEqual(PRTabs.tab(atShortcut: 2, context(mine: false)), .details)
            try expectEqual(PRTabs.tab(atShortcut: 3, context(mine: false)), nil)
            try expectEqual(PRTabs.tab(atShortcut: 2, context(mine: true)), nil)   // Respond deshabilitada
            try expectEqual(PRTabs.tab(atShortcut: 3, context(mine: true, ci: true)), .fixCI)
        },
        TestCase("navegación: el contexto sale del PR clasificado") {
            let mine = ClassifiedPR(pr: makePR(number: 3, author: "me", ci: .failure), category: .myFeedback, account: "me")
            try expectEqual(PRTabContext(item: mine, respondTask: nil),
                            context(mine: true, feedback: true, ci: true))
            let other = ClassifiedPR(pr: makePR(number: 4, author: "ana"), category: .toReview, account: "me")
            try expectEqual(PRTabContext(item: other, respondTask: nil), context(mine: false))
        },
        TestCase("navegación: go(to:) elige la sección del PR, recuerda la pestaña pedida y empuja el lugar anterior") {
            var nav = MainNavigationState()
            try expectEqual(nav.place, .start)
            nav.go(to: .pr(prID: "me/r#3", tab: .fixCI), sectionOf: sectionOf)
            try expectEqual(nav.place, MainPlace(sidebar: .section(.myPRs), prID: "me/r#3"))
            try expectEqual(nav.rememberedTabs["me/r#3"], .fixCI)
            try expectEqual(nav.back.places, [.start])
            // Un PR que no está en el snapshot queda en la sección de ahora.
            nav.go(to: .pr(prID: "x/gone#9", tab: nil), sectionOf: sectionOf)
            try expectEqual(nav.place.sidebar, .section(.myPRs))
            nav.go(to: .history(recordID: nil), sectionOf: sectionOf)
            nav.go(to: .activity, sectionOf: sectionOf)
            try expectEqual(nav.back.places.count, 4)
            // Ir adonde ya se está no empuja nada.
            nav.go(to: .activity, sectionOf: sectionOf)
            try expectEqual(nav.back.places.count, 4)
        },
        TestCase("navegación: Back vuelve al lugar anterior y guarda como mucho 20") {
            var nav = MainNavigationState()
            for i in 0..<25 { nav.go(to: i.isMultiple(of: 2) ? .activity : .history(recordID: nil), sectionOf: sectionOf) }
            try expectEqual(nav.back.places.count, BackStack.limit)
            try expectEqual(nav.place.sidebar, .activity)   // i = 24
            nav.goBack()
            try expectEqual(nav.place.sidebar, .history)    // i = 23
            try expectEqual(nav.back.places.count, BackStack.limit - 1)
            var fresh = MainNavigationState()
            fresh.goBack()
            try expectEqual(fresh.place, .start)
        },
        TestCase("navegación: elegir en la lista no va a Back; ⌘1/⌘2 vuelven al PR elegido de cada sección") {
            var nav = MainNavigationState()
            nav.select(prID: "o/r#1")
            try expect(!nav.back.canGoBack)
            nav.go(to: .list(.myPRs), sectionOf: sectionOf)
            try expectEqual(nav.place, MainPlace(sidebar: .section(.myPRs), prID: nil))
            nav.select(prID: "me/r#3")
            nav.go(to: .list(.toReview), sectionOf: sectionOf)
            try expectEqual(nav.place.prID, "o/r#1")
            nav.go(to: .list(.myPRs), sectionOf: sectionOf)
            try expectEqual(nav.place.prID, "me/r#3")
        },
        TestCase("navegación: la pestaña elegida se recuerda por PR") {
            var nav = MainNavigationState()
            nav.choose(.details, for: "o/r#1")
            try expectEqual(nav.tab(for: "o/r#1", context: context(mine: false)), .details)
            try expectEqual(nav.tab(for: "o/r#2", context: context(mine: false)), .review)
            try expect(!nav.back.canGoBack)
        },
        TestCase("navegación: History con registro y Back dentro de History") {
            var nav = MainNavigationState()
            let id = UUID()
            nav.go(to: .history(recordID: id), sectionOf: sectionOf)
            try expectEqual(nav.place, MainPlace(sidebar: .history, historyRecordID: id))
            nav.select(historyRecord: nil)
            try expectEqual(nav.place.historyRecordID, nil)
            // ⌘3 estando en History conserva el registro elegido.
            nav.select(historyRecord: id)
            nav.go(to: .history(recordID: nil), sectionOf: sectionOf)
            try expectEqual(nav.place.historyRecordID, id)
        },
        TestCase("navegación: el ancho de la lista es el 32 % entre 280 y 340") {
            try expect(abs(MainLayout.listWidth(windowWidth: 1000) - 320) < 0.001)
            try expectEqual(MainLayout.listWidth(windowWidth: 600), 280)
            try expectEqual(MainLayout.listWidth(windowWidth: 1280), 340)
        },
    ]
}
```

- [ ] **Step 2:** Sumar `+ MainNavigationTests.cases` al final de `allTests`. `swift build --product PRBarTests` → falla
  (faltan los tipos).
- [ ] **Step 3: Implementar** `Sources/PRBarCore/MainNavigation.swift`:

```swift
import Foundation

/// Las secciones con lista de PRs de la barra lateral (spec M.1).
public enum MainSection: String, CaseIterable, Codable, Sendable {
    case toReview, myPRs

    public var title: String { self == .toReview ? "To Review" : "My PRs" }
}

/// Las pestañas del detalle de un PR (spec M.1, M.4).
public enum PRTab: String, CaseIterable, Codable, Sendable {
    case review, details, merge, respond, fixCI

    public var title: String {
        switch self {
        case .review: "Review"
        case .details: "Details"
        case .merge: "Merge"
        case .respond: "Respond"
        case .fixCI: "Fix CI"
        }
    }

    /// En los links `prbar://pr/<owner>/<repo>/<n>/<tab>`.
    public var urlName: String { self == .fixCI ? "fix-ci" : rawValue }

    public init?(urlName: String) {
        switch urlName.lowercased() {
        case "fix-ci", "fixci": self = .fixCI
        case let name: guard let tab = PRTab(rawValue: name), tab != .fixCI else { return nil }; self = tab
        }
    }
}

/// A dónde lleva `AppModel.navigate(to:)` (spec M.4).
public enum MainDestination: Hashable, Sendable {
    case list(MainSection)
    /// `tab == nil`: la recordada para ese PR o la inicial según su estado.
    case pr(prID: String, tab: PRTab?)
    case history(recordID: UUID?)
    case activity
}

/// Lo elegido en la barra lateral.
public enum SidebarItem: Hashable, Sendable {
    case section(MainSection)
    case history
    case activity
}

/// Lo que hace falta saber de un PR para elegir sus pestañas.
public struct PRTabContext: Equatable, Sendable {
    public var isMine: Bool
    /// Tiene cambios pedidos o comentarios nuevos (categoría My PRs with Feedback).
    public var hasFeedback: Bool
    public var ciFailing: Bool
    /// Lo que ocupa el lugar de Respond del PR (`RespondQueue.records` o `phases`), en cualquier fase.
    public var respondTask: RespondMode?

    public init(isMine: Bool, hasFeedback: Bool, ciFailing: Bool, respondTask: RespondMode?) {
        self.isMine = isMine
        self.hasFeedback = hasFeedback
        self.ciFailing = ciFailing
        self.respondTask = respondTask
    }

    public init(item: ClassifiedPR, respondTask: RespondMode?) {
        self.init(isMine: PopoverTabs.isMine(item), hasFeedback: item.category == .myFeedback,
                  ciFailing: item.pr.ciState == .failure, respondTask: respondTask)
    }
}

public struct PRTabItem: Equatable, Sendable {
    public let tab: PRTab
    public let isEnabled: Bool
}

/// Pestañas disponibles e inicial (spec M.1 "Detalle del PR: pestañas").
public enum PRTabs {
    public static func tabs(_ c: PRTabContext) -> [PRTabItem] {
        guard c.isMine else {
            return [PRTabItem(tab: .review, isEnabled: true), PRTabItem(tab: .details, isEnabled: true)]
        }
        return [
            PRTabItem(tab: .merge, isEnabled: true),
            PRTabItem(tab: .respond, isEnabled: c.hasFeedback || c.respondTask == .feedback),
            PRTabItem(tab: .fixCI, isEnabled: c.ciFailing || c.respondTask == .ciFix),
        ]
    }

    public static func initial(_ c: PRTabContext) -> PRTab {
        guard c.isMine else { return .review }
        if c.hasFeedback { return .respond }
        if c.ciFailing { return .fixCI }
        switch c.respondTask {
        case .feedback?: return .respond
        case .ciFix?: return .fixCI
        case nil: return .merge
        }
    }

    /// La recordada si el PR la tiene y está habilitada; si no, la inicial.
    public static func resolve(remembered: PRTab?, context c: PRTabContext) -> PRTab {
        if let remembered, tabs(c).contains(PRTabItem(tab: remembered, isEnabled: true)) { return remembered }
        return initial(c)
    }

    /// ⌥⌘1…3 (`index` empieza en 1); nil fuera de rango o deshabilitada.
    public static func tab(atShortcut index: Int, _ c: PRTabContext) -> PRTab? {
        let all = tabs(c)
        guard all.indices.contains(index - 1), all[index - 1].isEnabled else { return nil }
        return all[index - 1].tab
    }
}

/// Un lugar de la ventana principal (lo que guarda la pila de Back).
public struct MainPlace: Hashable, Sendable {
    public var sidebar: SidebarItem
    public var prID: String?
    public var historyRecordID: UUID?

    public init(sidebar: SidebarItem, prID: String? = nil, historyRecordID: UUID? = nil) {
        self.sidebar = sidebar
        self.prID = prID
        self.historyRecordID = historyRecordID
    }

    public static let start = MainPlace(sidebar: .section(.toReview))
}

/// Back (⌘[): los últimos 20 lugares.
public struct BackStack: Equatable, Sendable {
    public static let limit = 20
    public private(set) var places: [MainPlace] = []

    public init() {}

    public var canGoBack: Bool { !places.isEmpty }

    public mutating func push(_ place: MainPlace) {
        guard places.last != place else { return }
        places.append(place)
        if places.count > Self.limit { places.removeFirst(places.count - Self.limit) }
    }

    public mutating func pop() -> MainPlace? { places.popLast() }
}

/// Dónde está la ventana principal. `go(to:)` es lo que hace `navigate(to:)` y empuja el lugar anterior a Back;
/// elegir a mano en la lista o en History (`select`) y cambiar de pestaña (`choose`) no.
public struct MainNavigationState: Equatable, Sendable {
    public private(set) var place: MainPlace = .start
    public private(set) var back = BackStack()
    /// La pestaña elegida por PR mientras la app está abierta.
    public private(set) var rememberedTabs: [String: PRTab] = [:]
    /// El último PR elegido en cada sección (⌘1/⌘2 vuelven a él).
    public private(set) var selectedPRs: [MainSection: String] = [:]

    public init() {}

    public var section: MainSection? {
        if case .section(let section) = place.sidebar { return section }
        return nil
    }

    /// `sectionOf`: la sección de un PR en el snapshot de ahora (nil si no está).
    public mutating func go(to destination: MainDestination, sectionOf: (String) -> MainSection?) {
        switch destination {
        case .list(let section):
            move(to: MainPlace(sidebar: .section(section), prID: selectedPRs[section]))
        case .pr(let prID, let tab):
            if let tab { rememberedTabs[prID] = tab }
            let section = sectionOf(prID) ?? self.section ?? .toReview
            move(to: MainPlace(sidebar: .section(section), prID: prID))
        case .history(let recordID):
            let keep = place.sidebar == .history ? place.historyRecordID : nil
            move(to: MainPlace(sidebar: .history, historyRecordID: recordID ?? keep))
        case .activity:
            move(to: MainPlace(sidebar: .activity))
        }
    }

    public mutating func select(prID: String?) {
        guard let section else { return }
        place.prID = prID
        selectedPRs[section] = prID
    }

    public mutating func select(historyRecord id: UUID?) {
        guard place.sidebar == .history else { return }
        place.historyRecordID = id
    }

    public mutating func choose(_ tab: PRTab, for prID: String) { rememberedTabs[prID] = tab }

    public func tab(for prID: String, context: PRTabContext) -> PRTab {
        PRTabs.resolve(remembered: rememberedTabs[prID], context: context)
    }

    public mutating func goBack() {
        guard let previous = back.pop() else { return }
        place = previous
        if case .section(let section) = previous.sidebar { selectedPRs[section] = previous.prID }
    }

    private mutating func move(to next: MainPlace) {
        guard next != place else { return }
        back.push(place)
        place = next
        if case .section(let section) = next.sidebar { selectedPRs[section] = next.prID }
    }
}

/// Medidas de la ventana principal que dependen del ancho (spec M.1).
public enum MainLayout {
    /// La lista: 32 % del ancho de la ventana, entre 280 y 340 pt.
    public static func listWidth(windowWidth: Double) -> Double { min(max(windowWidth * 0.32, 280), 340) }
}
```

- [ ] **Step 4:** `swift run PRBarTests navegación` verde; `swift run PRBarTests` completo verde. **Commit**
  `"Add main window navigation logic"`.

---

### Task 2: Lista, búsqueda, días y acción del pill

**Files:** Create `Sources/PRBarCore/MainList.swift`, `ListSearch.swift`, `DayGrouping.swift`, `PRPrimaryAction.swift`,
`Sources/PRBarTests/MainListTests.swift`; modify `main.swift`.

- [ ] **Step 1: Tests que fallan** (`MainListTests.swift`):

```swift
import Foundation
import PRBarCore

private func item(_ category: PRCategory, author: String = "ana", number: Int = 1, ci: CIState = .success,
                  draft: Bool = false) -> ClassifiedPR {
    ClassifiedPR(pr: makePR(number: number, author: author, isDraft: draft, ci: ci), category: category, account: "me")
}

private let snapshot = Snapshot(items: [
    item(.toReview, number: 1),
    item(.updatedSinceMyReview, number: 2),
    item(.other, number: 3, draft: true),
    item(.myFeedback, author: "me", number: 4, ci: .failure),
    item(.readyToMerge, author: "me", number: 5),
    item(.other, author: "me", number: 6, ci: .failure),
    item(.other, author: "me", number: 7),
], fetchedAt: t0)

enum MainListTests {
    static let cases: [TestCase] = [
        TestCase("lista: secciones de To Review y de My PRs, en orden") {
            try expectEqual(MainList.sections(.toReview), [.toReview, .updatedSinceMyReview, .otherToReview])
            try expectEqual(MainList.sections(.myPRs), [.withFeedback, .ciFailing, .readyToMerge, .waitingForReview])
            try expectEqual(MainListSection.withFeedback.title, "With Feedback")
            try expectEqual(MainListSection.ciFailing.title, "CI Failing")
        },
        TestCase("lista: cada PR va a su sección; un PR mío con CI roto y sin feedback es CI Failing") {
            try expectEqual(MainList.items(.ciFailing, in: snapshot).map(\.pr.number), [6])
            try expectEqual(MainList.items(.withFeedback, in: snapshot).map(\.pr.number), [4])   // feedback gana
            try expectEqual(MainList.items(.waitingForReview, in: snapshot).map(\.pr.number), [7])
            try expectEqual(MainList.items(.otherToReview, in: snapshot).map(\.pr.number), [3])
            try expectEqual(MainList.mainSection(of: snapshot.items[3]), .myPRs)
            try expectEqual(MainList.mainSection(of: snapshot.items[0]), .toReview)
        },
        TestCase("lista: contador de la barra lateral = el del popover (solo accionables)") {
            try expectEqual(MainList.count(.toReview, in: snapshot), 2)
            try expectEqual(MainList.count(.myPRs, in: snapshot), 2)
            try expectEqual(MainList.count(.myPRs, in: nil), nil)
        },
        TestCase("lista: vacías y calladas empiezan plegadas; borradores ocultos") {
            try expect(MainList.initiallyCollapsed(.toReview, itemCount: 0))
            try expect(!MainList.initiallyCollapsed(.toReview, itemCount: 2))
            try expect(MainList.initiallyCollapsed(.otherToReview, itemCount: 3))
            try expectEqual(MainList.hiddenDraftCount(in: snapshot), 1)
        },
        TestCase("lista: la búsqueda filtra por título, repo#N, autor y rama, sin mayúsculas ni acentos") {
            let pr = PullRequest(repo: RepoRef(owner: "acme", name: "web"), number: 482, title: "Arreglá la redirección",
                                 url: URL(string: "https://github.com/acme/web/pull/482")!, isDraft: false, author: "laura",
                                 authorAvatarURL: nil, baseRef: "main", headRef: "fix/login-redirect", headOid: "a",
                                 additions: 1, deletions: 1, createdAt: t0, updatedAt: t0, lastCommitAt: t0, ciState: .success,
                                 reviewDecision: .none, reviews: [], comments: [], requestedReviewers: [],
                                 authorName: "Laura Méndez")
            for query in ["", "REDIRECCION", "web#482", "#482", "48", "laura", "mendez", "login-redirect", "acme/web",
                          "laura redirect"] {
                try expect(ListSearch.matches(pr, query: query), "debería encontrar \(query)")
            }
            for query in ["api#482", "#99", "carlos", "laura api"] {
                try expect(!ListSearch.matches(pr, query: query), "no debería encontrar \(query)")
            }
            try expectEqual(MainList.items(.toReview, in: snapshot, query: "pr 1").map(\.pr.number), [1])
        },
        TestCase("días: Today, Yesterday y la fecha") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let now = t0   // 2027-01-15 08:00 UTC
            try expectEqual(DayGrouping.title(for: now.addingTimeInterval(-3600), now: now, calendar: calendar), "Today")
            try expectEqual(DayGrouping.title(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar), "Yesterday")
            try expectEqual(DayGrouping.title(for: now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar),
                            "Tuesday, Jan 12")
            try expectEqual(DayGrouping.title(for: now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar),
                            "Dec 11, 2025")
            let dates = [now, now.addingTimeInterval(-60), now.addingTimeInterval(-86_400)]
            let groups = DayGrouping.group(dates, date: { $0 }, now: now, calendar: calendar)
            try expectEqual(groups.map(\.title), ["Today", "Yesterday"])
            try expectEqual(groups.map(\.items.count), [2, 1])
        },
        TestCase("pill: qué hace ↩ en cada fila y qué pestaña abre") {
            try expectEqual(PRPrimaryAction.of(item(.toReview), review: nil, respond: nil, respondMode: nil), .startReview)
            try expectEqual(PRPrimaryAction.of(item(.toReview), review: .reviewing(agents: 3), respond: nil, respondMode: nil),
                            .openReview)
            try expectEqual(PRPrimaryAction.of(item(.toReview), review: .failed("x", logURL: nil), respond: nil,
                                               respondMode: nil), .startReview)
            try expectEqual(PRPrimaryAction.of(item(.myFeedback, author: "me"), review: nil, respond: nil, respondMode: nil),
                            .startRespond)
            try expectEqual(PRPrimaryAction.of(item(.myFeedback, author: "me"), review: nil, respond: .pushing,
                                               respondMode: .ciFix), .openCIFix)
            try expectEqual(PRPrimaryAction.of(item(.readyToMerge, author: "me"), review: nil, respond: nil, respondMode: nil),
                            .openMerge)
            try expectEqual(PRPrimaryAction.of(item(.other, author: "me", ci: .failure), review: nil, respond: nil,
                                               respondMode: nil), .startCIFix)
            try expectEqual(PRPrimaryAction.of(item(.other), review: nil, respond: nil, respondMode: nil), .none)
            try expectEqual(PRPrimaryAction.startCIFix.tab, .fixCI)
            try expect(PRPrimaryAction.startReview.startsJob && !PRPrimaryAction.openMerge.startsJob)
        },
    ]
}
```

(`t0` es 2027-01-15 08:00 UTC, un viernes: tres días antes es el martes 12; 400 días antes, el 11 de diciembre de 2025.)

- [ ] **Step 2:** Registrar `MainListTests.cases`; build → falla.
- [ ] **Step 3: Implementar.**

`MainList.swift`:

```swift
import Foundation

/// Las secciones de la lista de la ventana principal (spec M.1 "Lista"). Reparte con `PopoverTabs` (la misma
/// clasificación que el popover) y separa "CI Failing" de los PRs míos que esperan review.
public enum MainListSection: String, CaseIterable, Identifiable, Sendable {
    case toReview, updatedSinceMyReview, otherToReview
    case withFeedback, ciFailing, readyToMerge, waitingForReview

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toReview: "To Review"
        case .updatedSinceMyReview: "Updated Since My Review"
        case .otherToReview: "Other"
        case .withFeedback: "With Feedback"
        case .ciFailing: "CI Failing"
        case .readyToMerge: "Ready to Merge"
        case .waitingForReview: "Waiting for Review"
        }
    }

    public var mainSection: MainSection {
        switch self {
        case .toReview, .updatedSinceMyReview, .otherToReview: .toReview
        default: .myPRs
        }
    }

    /// Plegada al abrir y atenuada (como en el popover).
    public var isQuiet: Bool { self == .otherToReview || self == .waitingForReview }
}

public enum MainList {
    public static func mainSection(of item: ClassifiedPR) -> MainSection {
        PopoverTabs.tab(of: item) == .mine ? .myPRs : .toReview
    }

    public static func section(of item: ClassifiedPR) -> MainListSection {
        switch PopoverTabs.section(of: item) {
        case .toReview: .toReview
        case .updatedSinceMyReview: .updatedSinceMyReview
        case .otherToReview: .otherToReview
        case .myFeedback: .withFeedback
        case .readyToMerge: .readyToMerge
        case .waitingForReview: item.pr.ciState == .failure ? .ciFailing : .waitingForReview
        }
    }

    public static func sections(_ section: MainSection) -> [MainListSection] {
        MainListSection.allCases.filter { $0.mainSection == section }
    }

    /// En el orden del snapshot, filtrados por la búsqueda.
    public static func items(_ section: MainListSection, in snapshot: Snapshot, query: String = "") -> [ClassifiedPR] {
        snapshot.items.filter { self.section(of: $0) == section && ListSearch.matches($0.pr, query: query) }
    }

    /// El contador de la barra lateral: el mismo que el de la pestaña del popover. nil sin datos.
    public static func count(_ section: MainSection, in snapshot: Snapshot?) -> Int? {
        snapshot.map { PopoverTabs.count(section == .toReview ? .toReview : .mine, in: $0) }
    }

    public static func initiallyCollapsed(_ section: MainListSection, itemCount: Int) -> Bool {
        itemCount == 0 || section.isQuiet
    }

    /// Borradores de otros que quedan en "Other" (el aviso "N drafts hidden · Show" del vacío).
    public static func hiddenDraftCount(in snapshot: Snapshot) -> Int {
        items(.otherToReview, in: snapshot).filter(\.pr.isDraft).count
    }
}
```

`ListSearch.swift`:

```swift
import Foundation

/// Búsqueda de la lista y de History (spec M.1, ⌘F): cada palabra tiene que aparecer en algún campo, sin distinguir
/// mayúsculas ni acentos. "#482" y "482" buscan también por número (prefijo).
public enum ListSearch {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func matches(fields: [String], number: Int?, query: String) -> Bool {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = fields.map(fold)
        return words.allSatisfy { word in
            if haystack.contains(where: { $0.contains(word) }) { return true }
            let digits = word.hasPrefix("#") ? String(word.dropFirst()) : word
            guard let number, !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return false }
            return String(number).hasPrefix(digits)
        }
    }

    /// Título, `repo#N`, `owner/repo`, autor (login y nombre) y rama.
    public static func matches(_ pr: PullRequest, query: String) -> Bool {
        matches(fields: [pr.title, "\(pr.repo.name)#\(pr.number)", pr.repo.fullName, pr.author, pr.authorName ?? "",
                         pr.headRef],
                number: pr.number, query: query)
    }
}
```

`DayGrouping.swift`:

```swift
import Foundation

/// History por día (spec M.1): "Today", "Yesterday", después "Tuesday, Jan 12" y, de otro año, "Dec 11, 2025".
public enum DayGrouping {
    public struct Group<Item> {
        public let title: String
        public let items: [Item]
    }

    public static func title(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "EEEE, MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// `items` ya ordenados del más nuevo al más viejo; los grupos salen en ese orden.
    public static func group<Item>(_ items: [Item], date: (Item) -> Date, now: Date,
                                   calendar: Calendar = .current) -> [Group<Item>] {
        var groups: [Group<Item>] = []
        for item in items {
            let title = title(for: date(item), now: now, calendar: calendar)
            if let last = groups.last, last.title == title {
                groups[groups.count - 1] = Group(title: title, items: last.items + [item])
            } else {
                groups.append(Group(title: title, items: [item]))
            }
        }
        return groups
    }
}
```

`PRPrimaryAction.swift`: el enum con `tab` y `startsJob` y `of(_:review:respond:respondMode:)` así (es la misma regla
que `PRRowView.trailingAccessory`):

```swift
/// Lo que hace el pill de una fila (y ↩ en la lista) y la pestaña que abre (spec M.1, M.3).
public enum PRPrimaryAction: Equatable, Sendable {
    case startReview, openReview, startRespond, openRespond, startCIFix, openCIFix, openMerge, none

    public var tab: PRTab? {
        switch self {
        case .startReview, .openReview: .review
        case .startRespond, .openRespond: .respond
        case .startCIFix, .openCIFix: .fixCI
        case .openMerge: .merge
        case .none: nil
        }
    }

    public var startsJob: Bool { self == .startReview || self == .startRespond || self == .startCIFix }

    public static func of(_ item: ClassifiedPR, review: ReviewPhase?, respond: RespondPhase?,
                          respondMode: RespondMode?) -> PRPrimaryAction {
        if respondMode == .ciFix, respond != nil { return .openCIFix }
        switch item.category {
        case .toReview, .updatedSinceMyReview:
            if case .failed? = review { return .startReview }
            return review == nil ? .startReview : .openReview
        case .myFeedback:
            if case .failed? = respond { return .startRespond }
            return respond == nil ? .startRespond : .openRespond
        case .readyToMerge:
            return .openMerge
        case .other:
            return PopoverTabs.isMine(item) && item.pr.ciState == .failure && respond == nil ? .startCIFix : .none
        }
    }
}
```

- [ ] **Step 4:** `swift run PRBarTests lista`, `días`, `pill` y la suite completa verdes. **Commit**
  `"Add main list sections, search, day grouping and row actions"`.

---

### Task 3: Grupo Claude, modo foco, Dock y etapas de Respond

**Files:** Create `Sources/PRBarCore/ClaudeTasksSidebar.swift`, `FocusMode.swift`, `DockPolicy.swift`,
`RespondStages.swift`; tests `ClaudeTasksSidebarTests.swift`, `FocusModeTests.swift`, `DockPolicyTests.swift`,
`RespondStagesTests.swift`; modify `Fixtures.swift` (stubs de Respond), `main.swift`.

- [ ] **Step 1: Tests que fallan.**

`ClaudeTasksSidebarTests.swift`:

```swift
import Foundation
import PRBarCore

private func draft(findings: Int) -> ReviewDraft {
    let items = (0..<findings).map { i in
        ReviewItem(finding: ReviewFinding(id: "f\(i)", severity: .medium, file: "a.ts", line: i, title: "T", body: "B"),
                   keep: true, reason: nil)
    }
    return ReviewDraft(prID: "acme/web#482", repo: RepoRef(owner: "acme", name: "web"), number: 482, title: "PR",
                       url: URL(string: "https://github.com/acme/web/pull/482")!, author: "ana", headOid: "a",
                       account: "me", summary: "S", items: items)
}

enum ClaudeTasksSidebarTests {
    static let cases: [TestCase] = [
        TestCase("grupo Claude: review corriendo con reloj, lista con hallazgos; las que corren van primero") {
            let rows = ClaudeTasksSidebar.rows([
                ClaudeTaskInput(prID: "acme/web#482", review: .ready(draft(findings: 4))),
                ClaudeTaskInput(prID: "acme/api#317", review: .reviewing(agents: 3), reviewStartedAt: t0.addingTimeInterval(-72)),
            ], now: t0)
            try expectEqual(rows.map(\.title), ["api#317", "web#482"])
            try expectEqual(rows.map(\.subtitle), ["Reviewing · 1:12", "Review ready · 4 findings"])
            try expectEqual(rows.map(\.isRunning), [true, false])
            try expectEqual(rows.map(\.tab), [.review, .review])
        },
        TestCase("grupo Claude: Respond y Fix CI por etapa; terminadas o fallidas no aparecen") {
            func row(_ phase: RespondPhase?, mode: RespondMode = .feedback, tests: Bool = false) -> ClaudeTaskRow? {
                ClaudeTasksSidebar.rows([ClaudeTaskInput(prID: "o/r#1", respond: phase, respondMode: mode, runningTests: tests,
                                                         respondStartedAt: t0.addingTimeInterval(-5))], now: t0).first
            }
            try expectEqual(row(.analyzing(agents: 2))?.subtitle, "Analyzing · 0:05")
            try expectEqual(row(.implementing(done: 1, total: 3), mode: .ciFix)?.subtitle, "Implementing · 0:05")
            try expectEqual(row(.implementing(done: 1, total: 3), mode: .ciFix)?.tab, .fixCI)
            let pushable = row(.readyToPush(draftStub, resultStub), mode: .ciFix)
            try expectEqual(pushable?.subtitle, "Fix CI · ready to push")
            try expectEqual(pushable?.isRunning, false)
            try expectEqual(row(.readyToPush(draftStub, resultStub), tests: true)?.subtitle, "Running tests · 0:05")
            try expectEqual(row(.queued)?.subtitle, "Respond · queued")
            try expectEqual(row(.pushing)?.subtitle, "Pushing…")
            try expect(row(.failed("x", logURL: nil)) == nil)
            try expect(row(nil) == nil)
        },
        TestCase("grupo Claude: título del grupo, franja del popover, iPhone e indicadores de pestaña") {
            let rows = ClaudeTasksSidebar.rows([
                ClaudeTaskInput(prID: "acme/web#482", review: .ready(draft(findings: 1)), fromPhone: true),
                ClaudeTaskInput(prID: "acme/api#317", review: .queued),
            ], now: t0)
            try expectEqual(ClaudeTasksSidebar.groupTitle(rows), "Claude · 1 running")
            try expectEqual(ClaudeTasksSidebar.popoverStrip(rows), "Claude · 1 running · 1 ready")
            try expectEqual(ClaudeTasksSidebar.popoverStrip([]), nil)
            try expectEqual(rows.last?.subtitle, "Review ready · 1 finding")
            try expectEqual(rows.last?.fromPhone, true)
            try expectEqual(ClaudeTasksSidebar.indicator(prID: "acme/api#317", tab: .review, rows: rows), .running)
            try expectEqual(ClaudeTasksSidebar.indicator(prID: "acme/web#482", tab: .review, rows: rows), .ready)
            try expectEqual(ClaudeTasksSidebar.indicator(prID: "acme/web#482", tab: .details, rows: rows), nil)
        },
        TestCase("grupo Claude: reloj m:ss y h:mm:ss") {
            try expectEqual(ClaudeTasksSidebar.clock(0), "0:00")
            try expectEqual(ClaudeTasksSidebar.clock(72), "1:12")
            try expectEqual(ClaudeTasksSidebar.clock(3725), "1:02:05")
        },
    ]
}
```

`draftStub`/`resultStub` son fixtures compartidos, en `Sources/PRBarTests/Fixtures.swift` (los usan también los
tests de etapas):

```swift
let draftStub: RespondDraft = {
    let pr = makePR(number: 1, author: "me")
    return RespondDraft(id: UUID(), prID: pr.id, repo: pr.repo, number: 1, title: pr.title, url: pr.url,
                        headRef: pr.headRef, account: "me", worktree: ResolvedWorktree(path: "/wt/1", origin: .mainClone),
                        startHeadOid: "", items: [])
}()
let resultStub = RespondResult(items: [], diffStat: "", tests: nil)
```

`FocusModeTests.swift`:

```swift
import PRBarCore

enum FocusModeTests {
    static let cases: [TestCase] = [
        TestCase("modo foco: entra al empezar Claude (lista oculta, chat abierto) y sale al terminar") {
            var focus = FocusModeState()
            focus.setClaudeWorking(true)
            try expect(focus.isFocused && focus.chatShown)
            focus.setClaudeWorking(false)
            try expect(!focus.isFocused && !focus.chatShown)
        },
        TestCase("modo foco: si el usuario toca el chat durante la tarea, al terminar se respeta") {
            var focus = FocusModeState()
            focus.setClaudeWorking(true)
            focus.toggleChat()   // lo cierra a mano
            focus.setClaudeWorking(false)
            try expect(!focus.chatShown)
            focus.setClaudeWorking(true)
            focus.toggleChat(); focus.toggleChat()   // lo cierra y lo vuelve a abrir
            focus.setClaudeWorking(false)
            try expect(focus.chatShown && !focus.isFocused)
        },
        TestCase("modo foco: fuera de una tarea el chat es solo del usuario") {
            var focus = FocusModeState()
            focus.toggleChat()
            try expect(focus.chatShown && !focus.isFocused)
            focus.setClaudeWorking(false)
            try expect(focus.chatShown)
        },
    ]
}
```

`DockPolicyTests.swift`:

```swift
import PRBarCore

enum DockPolicyTests {
    static let cases: [TestCase] = [
        TestCase("dock: con ventanas .regular; sin ventanas .accessory") {
            try expectEqual(DockPolicy.policy(openWindows: 1, alwaysShowInDock: false, otherAppFullScreen: false,
                                              current: .accessory), .regular)
            try expectEqual(DockPolicy.policy(openWindows: 0, alwaysShowInDock: false, otherAppFullScreen: false,
                                              current: .regular), .accessory)
            try expectEqual(DockPolicy.policy(openWindows: 2, alwaysShowInDock: false, otherAppFullScreen: false,
                                              current: .regular), nil)
        },
        TestCase("dock: Always show in Dock deja siempre .regular") {
            try expectEqual(DockPolicy.policy(openWindows: 0, alwaysShowInDock: true, otherAppFullScreen: false,
                                              current: .accessory), .regular)
            try expectEqual(DockPolicy.policy(openWindows: 0, alwaysShowInDock: true, otherAppFullScreen: false,
                                              current: .regular), nil)
        },
        TestCase("dock: sobre otra app en pantalla completa no se pasa a .regular (WindowSpaces); a .accessory sí") {
            try expectEqual(DockPolicy.policy(openWindows: 1, alwaysShowInDock: false, otherAppFullScreen: true,
                                              current: .accessory), nil)
            try expectEqual(DockPolicy.policy(openWindows: 0, alwaysShowInDock: false, otherAppFullScreen: true,
                                              current: .regular), .accessory)
        },
    ]
}
```

`RespondStagesTests.swift` (las tres etapas de la tarjeta de progreso, spec M.1 "Respond / Fix CI"):

```swift
import PRBarCore

enum RespondStagesTests {
    static let cases: [TestCase] = [
        TestCase("etapas: el reloj anota cuándo empieza y termina cada una") {
            var timeline = RespondStageTimeline()
            timeline.note(phase: .analyzing(agents: 2), runningTests: false, at: t0)
            timeline.note(phase: .implementing(done: 0, total: 2), runningTests: false, at: t0.addingTimeInterval(30))
            timeline.note(phase: .readyToPush(draftStub, resultStub), runningTests: true, at: t0.addingTimeInterval(90))
            let stages = timeline.stages(phase: .readyToPush(draftStub, resultStub), runningTests: true, testsRan: false)
            try expectEqual(stages.map(\.status), [.done, .done, .running])
            try expectEqual(stages[0].duration(now: t0.addingTimeInterval(100)), 30)
            try expectEqual(stages[1].duration(now: t0.addingTimeInterval(100)), 60)
            try expectEqual(stages[2].duration(now: t0.addingTimeInterval(100)), 10)
        },
        TestCase("etapas: listo para elegir, sin tests y fallido") {
            let empty = RespondStageTimeline()
            try expectEqual(empty.stages(phase: .ready(draftStub), runningTests: false, testsRan: false).map(\.status),
                            [.done, .pending, .pending])
            try expectEqual(empty.stages(phase: .readyToPush(draftStub, resultStub), runningTests: false, testsRan: false)
                                .map(\.status), [.done, .done, .pending])
            try expectEqual(empty.stages(phase: .readyToPush(draftStub, resultStub), runningTests: false, testsRan: true)
                                .map(\.status), [.done, .done, .done])
            var failed = RespondStageTimeline()
            failed.note(phase: .implementing(done: 0, total: 1), runningTests: false, at: t0)
            try expectEqual(failed.stages(phase: .failed("x", logURL: nil), runningTests: false, testsRan: false)
                                .map(\.status), [.done, .failed, .pending])
        },
    ]
}
```

- [ ] **Step 2:** Registrar los cuatro; build → falla.
- [ ] **Step 3: Implementar.**

`ClaudeTasksSidebar.swift`:

```swift
import Foundation

/// Cuándo empezó una tarea de Claude y si la pidió un iPhone (spec M.1 grupo Claude, M.4).
public struct ClaudeRunInfo: Equatable, Sendable {
    public var startedAt: Date
    public var requestedOnPhone: Bool

    public init(startedAt: Date, requestedOnPhone: Bool) {
        self.startedAt = startedAt
        self.requestedOnPhone = requestedOnPhone
    }
}

public struct ClaudeTaskInput: Sendable {
    public var prID: String
    public var review: ReviewPhase?
    public var reviewStartedAt: Date?
    public var respond: RespondPhase?
    public var respondMode: RespondMode
    public var runningTests: Bool
    public var respondStartedAt: Date?
    public var fromPhone: Bool

    public init(prID: String, review: ReviewPhase? = nil, reviewStartedAt: Date? = nil, respond: RespondPhase? = nil,
                respondMode: RespondMode = .feedback, runningTests: Bool = false, respondStartedAt: Date? = nil,
                fromPhone: Bool = false) { /* asignar todo */ }
}

public struct ClaudeTaskRow: Equatable, Identifiable, Sendable {
    public var id: String { "\(prID)|\(tab.rawValue)" }
    public let prID: String
    /// "web#482".
    public let title: String
    /// "Reviewing · 1:12", "Fix CI · ready to push", "Review ready · 4 findings".
    public let subtitle: String
    public let tab: PRTab
    public let isRunning: Bool
    public let fromPhone: Bool
}

public enum TabIndicator: Equatable, Sendable { case running, ready }

/// "Tarea lista" = review lista sin publicar, Respond o Fix CI terminado sin pushear (o, en Respond, el análisis
/// esperando que el usuario elija). Sale cuando se publica, se pushea o se descarta.
public enum ClaudeTasksSidebar {
    public static func rows(_ inputs: [ClaudeTaskInput], now: Date) -> [ClaudeTaskRow] {
        let all = inputs.flatMap { [reviewRow($0, now: now), respondRow($0, now: now)].compactMap { $0 } }
        return all.filter(\.isRunning) + all.filter { !$0.isRunning }
    }

    static func reviewRow(_ input: ClaudeTaskInput, now: Date) -> ClaudeTaskRow? {
        let subtitle: String, running: Bool
        switch input.review {
        case .queued?: (subtitle, running) = ("Review · queued", true)
        case .preparing?, .reviewing?, .filtering?:
            (subtitle, running) = (timed("Reviewing", since: input.reviewStartedAt, now: now), true)
        case .ready(let draft)?:
            let count = draft.keptCount
            (subtitle, running) = ("Review ready · \(count) finding\(count == 1 ? "" : "s")", false)
        default: return nil
        }
        return ClaudeTaskRow(prID: input.prID, title: shortName(input.prID), subtitle: subtitle, tab: .review,
                             isRunning: running, fromPhone: input.fromPhone)
    }

    static func respondRow(_ input: ClaudeTaskInput, now: Date) -> ClaudeTaskRow? {
        let ci = input.respondMode == .ciFix
        let name = ci ? "Fix CI" : "Respond"
        let since = input.respondStartedAt
        let subtitle: String, running: Bool
        switch input.respond {
        case .queued?: (subtitle, running) = ("\(name) · queued", true)
        case .preparing?, .analyzing?: (subtitle, running) = (timed("Analyzing", since: since, now: now), true)
        // Fix CI no tiene nada que elegir: su `ready` dura un instante antes de implementar (spec K.6.3).
        case .ready?: (subtitle, running) = ci ? (timed("Analyzing", since: since, now: now), true)
                                               : ("Respond · ready to choose", false)
        case .implementing?: (subtitle, running) = (timed("Implementing", since: since, now: now), true)
        case .readyToPush?:
            (subtitle, running) = input.runningTests ? (timed("Running tests", since: since, now: now), true)
                                                     : ("\(name) · ready to push", false)
        case .pushing?: (subtitle, running) = ("Pushing…", true)
        default: return nil
        }
        return ClaudeTaskRow(prID: input.prID, title: shortName(input.prID), subtitle: subtitle,
                             tab: ci ? .fixCI : .respond, isRunning: running, fromPhone: input.fromPhone)
    }

    public static func groupTitle(_ rows: [ClaudeTaskRow]) -> String {
        let running = rows.filter(\.isRunning).count
        return running > 0 || rows.isEmpty ? "Claude · \(running) running" : "Claude · \(rows.count) ready"
    }

    /// La franja del popover (spec M.3); nil sin tareas.
    public static func popoverStrip(_ rows: [ClaudeTaskRow]) -> String? {
        guard !rows.isEmpty else { return nil }
        let running = rows.filter(\.isRunning).count
        return "Claude · \(running) running · \(rows.count - running) ready"
    }

    /// Spinner violeta o punto verde en la pestaña del PR (spec M.1).
    public static func indicator(prID: String, tab: PRTab, rows: [ClaudeTaskRow]) -> TabIndicator? {
        guard let row = rows.first(where: { $0.prID == prID && $0.tab == tab }) else { return nil }
        return row.isRunning ? .running : .ready
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "acme/web#482" → "web#482".
    public static func shortName(_ prID: String) -> String {
        prID.split(separator: "/").last.map(String.init) ?? prID
    }

    static func timed(_ label: String, since: Date?, now: Date) -> String {
        since.map { "\(label) · \(clock(now.timeIntervalSince($0)))" } ?? label
    }
}
```

`FocusMode.swift`:

```swift
/// Modo foco del detalle (spec M.1 "Modo foco y chat"): mientras Claude trabaja en Respond o Fix CI del PR que se ve,
/// la lista se oculta y el chat se abre; al terminar vuelve la lista y el chat se cierra, salvo que el usuario lo haya
/// abierto o cerrado a mano durante la tarea.
public struct FocusModeState: Equatable, Sendable {
    public private(set) var isFocused = false
    public private(set) var chatShown: Bool
    private var userChoseChat = false

    public init(chatShown: Bool = false) { self.chatShown = chatShown }

    public mutating func setClaudeWorking(_ working: Bool) {
        if working, !isFocused {
            isFocused = true
            userChoseChat = false
            chatShown = true
        } else if !working, isFocused {
            isFocused = false
            if !userChoseChat { chatShown = false }
            userChoseChat = false
        }
    }

    /// ⌥⌘I, el botón de la toolbar o el cierre del inspector.
    public mutating func toggleChat() { setChatShown(!chatShown) }

    public mutating func setChatShown(_ shown: Bool) {
        guard shown != chatShown else { return }
        chatShown = shown
        if isFocused { userChoseChat = true }
    }
}
```

`DockPolicy.swift`:

```swift
/// El ícono en el Dock (spec M.5): `.regular` mientras haya una ventana abierta (principal, de PR o Settings) o con
/// "Always show in Dock"; `.accessory` sin ventanas. Sobre otra app en pantalla completa no se pasa a `.regular`
/// (moverían al usuario de Space, `WindowSpaces`): se reintenta al salir de ese Space.
public enum DockPolicy {
    public enum Policy: Equatable, Sendable { case regular, accessory }

    /// La política a poner, o nil para dejar la actual.
    public static func policy(openWindows: Int, alwaysShowInDock: Bool, otherAppFullScreen: Bool,
                              current: Policy) -> Policy? {
        let wanted: Policy = alwaysShowInDock || openWindows > 0 ? .regular : .accessory
        guard wanted != current else { return nil }
        if wanted == .regular && otherAppFullScreen { return nil }
        return wanted
    }
}
```

`RespondStages.swift`:

```swift
import Foundation

public enum RespondStageKind: String, CaseIterable, Sendable {
    case analyzing, implementing, testing

    public var title: String {
        switch self {
        case .analyzing: "Analyzing"
        case .implementing: "Implementing"
        case .testing: "Running tests"
        }
    }
}

public enum RespondStageStatus: Equatable, Sendable { case pending, running, done, failed }

public struct RespondStage: Equatable, Sendable {
    public let kind: RespondStageKind
    public let status: RespondStageStatus
    public let startedAt: Date?
    public let finishedAt: Date?

    /// Segundos que lleva (corriendo) o que llevó (terminada); nil si no se sabe.
    public func duration(now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// Las tres etapas de la tarjeta de progreso de Respond / Fix CI. `AppModel` llama a `note` cada vez que cambia la fase
/// de un PR (los tiempos no viven en `RespondPhase`).
public struct RespondStageTimeline: Equatable, Sendable {
    public private(set) var starts: [RespondStageKind: Date] = [:]
    public private(set) var ends: [RespondStageKind: Date] = [:]

    public init() {}

    static func current(_ phase: RespondPhase?, runningTests: Bool) -> RespondStageKind? {
        switch phase {
        case .queued?, .preparing?, .analyzing?: .analyzing
        case .implementing?: .implementing
        case .readyToPush? where runningTests: .testing
        default: nil
        }
    }

    public mutating func note(phase: RespondPhase?, runningTests: Bool, at date: Date) {
        guard let kind = Self.current(phase, runningTests: runningTests) else {
            for open in starts.keys where ends[open] == nil { ends[open] = date }
            return
        }
        if starts[kind] == nil { starts[kind] = date }
        for earlier in RespondStageKind.allCases.prefix(while: { $0 != kind }) where starts[earlier] != nil && ends[earlier] == nil {
            ends[earlier] = date
        }
    }

    public func stages(phase: RespondPhase?, runningTests: Bool, testsRan: Bool) -> [RespondStage] {
        let current = Self.current(phase, runningTests: runningTests)
        let reached: RespondStageKind? = switch phase {
        case .ready?: .analyzing
        case .readyToPush?, .pushing?, .done?: testsRan || runningTests ? .testing : .implementing
        default: current
        }
        let failedAt: RespondStageKind? = if case .failed? = phase {
            RespondStageKind.allCases.last { starts[$0] != nil } ?? .analyzing
        } else { nil }
        return RespondStageKind.allCases.map { kind in
            let status: RespondStageStatus
            if kind == failedAt { status = .failed }
            else if kind == current { status = .running }
            else if let failedAt, kind.order < failedAt.order { status = .done }
            else if let reached, kind.order <= reached.order, failedAt == nil { status = .done }
            else { status = .pending }
            return RespondStage(kind: kind, status: status, startedAt: starts[kind], finishedAt: ends[kind])
        }
    }
}

extension RespondStageKind {
    var order: Int { RespondStageKind.allCases.firstIndex(of: self)! }
}
```

(Si las reglas de `stages` quedan enredadas, reescribirlas mientras los dos tests pasen tal cual: son la definición.)

- [ ] **Step 4:** `swift run PRBarTests "grupo Claude"`, `"modo foco"`, `dock`, `etapas` y la suite verdes. **Commit**
  `"Add Claude task rows, focus mode, Dock policy and Respond stages"`.

---

### Task 4: `prbar://`, notificación → destino y origen iPhone

**Files:** Create `Sources/PRBarCore/PRBarURL.swift`, `NotificationRoute.swift`, tests `PRBarURLTests.swift`,
`NotificationRouteTests.swift`; modify `NotificationPlanner.swift`, `CommandOrigin.swift`, `ReviewHistory.swift`,
`RespondPipeline.swift` (`RespondRecord`), `MergeHistory.swift` (`MergeRecord`), `RespondQueue.swift`,
`NotificationPlannerTests.swift`, `RespondQueueTests.swift`, `main.swift`.

- [ ] **Step 1: Tests que fallan.**

`PRBarURLTests.swift`:

```swift
import Foundation
import PRBarCore

private func dest(_ string: String) -> MainDestination? { PRBarURL.destination(URL(string: string)!) }

enum PRBarURLTests {
    static let cases: [TestCase] = [
        TestCase("prbar://: PR con y sin pestaña") {
            try expectEqual(dest("prbar://pr/acme/web/482"), .pr(prID: "acme/web#482", tab: nil))
            try expectEqual(dest("prbar://pr/acme/web/482/fix-ci"), .pr(prID: "acme/web#482", tab: .fixCI))
            try expectEqual(dest("PRBAR://pr/acme/web/482/Merge"), .pr(prID: "acme/web#482", tab: .merge))
            // Los links del iPhone (`?screen=`) también se entienden.
            try expectEqual(dest("prbar://pr/acme/web/482?screen=respond"), .pr(prID: "acme/web#482", tab: .respond))
        },
        TestCase("prbar://: secciones") {
            try expectEqual(dest("prbar://review"), .list(.toReview))
            try expectEqual(dest("prbar://mine"), .list(.myPRs))
            try expectEqual(dest("prbar://history"), .history(recordID: nil))
            try expectEqual(dest("prbar://activity"), .activity)
        },
        TestCase("prbar://: lo que no se entiende es nil (la app abre la ventana sin moverse)") {
            for bad in ["prbar://pr/acme/web", "prbar://pr/acme/web/x", "prbar://pr/acme/web/0", "prbar://pr/a%20b/web/1",
                        "prbar://pr/acme/web/1/nope", "prbar://home", "prbar://pair?v=1", "https://pr/acme/web/1",
                        "prbar://review/extra"] {
                try expect(dest(bad) == nil, "\(bad) debería ser nil")
            }
        },
        TestCase("prbar://: ida y vuelta") {
            for destination: MainDestination in [.list(.toReview), .list(.myPRs), .history(recordID: nil), .activity,
                                                 .pr(prID: "acme/web#482", tab: nil), .pr(prID: "acme/web#482", tab: .fixCI)] {
                let url = try expectSome(PRBarURL.url(for: destination))
                try expectEqual(PRBarURL.destination(url), destination)
            }
        },
    ]
}
```

`NotificationRouteTests.swift`:

```swift
import Foundation
import PRBarCore

private let settings = NotificationSettings()
private let repo = RepoRef(owner: "acme", name: "web")

enum NotificationRouteTests {
    static let cases: [TestCase] = [
        TestCase("notificación → destino: review listo, respond, fix CI, merge") {
            let review = try expectSome(NotificationPlanner.reviewFinished(prID: "acme/web#1", repo: repo, number: 1,
                                                                            keptCount: 3, settings: settings))
            try expectEqual(NotificationRoute.target(userInfo: NotificationRoute.userInfo(review)),
                            .destination(.pr(prID: "acme/web#1", tab: .review)))
            let respond = try expectSome(NotificationPlanner.respondFinished(prID: "acme/web#2", repo: repo, number: 2,
                                                                              event: .fixesReady(commits: 1), settings: settings))
            try expectEqual(NotificationRoute.target(userInfo: NotificationRoute.userInfo(respond)),
                            .destination(.pr(prID: "acme/web#2", tab: .respond)))
            let ci = try expectSome(NotificationPlanner.respondFinished(prID: "acme/web#3", repo: repo, number: 3,
                                                                         event: .ciFixReady(commits: 1), settings: settings))
            try expectEqual(ci.tab, .fixCI)
        },
        TestCase("notificación → destino: review fallido va a History; update a la hoja; disco a Activity") {
            let id = UUID()
            let failed = try expectSome(NotificationPlanner.reviewFinished(prID: "acme/web#1", repo: repo, number: 1,
                                                                            keptCount: nil, recordID: id, settings: settings))
            try expectEqual(NotificationRoute.target(userInfo: NotificationRoute.userInfo(failed)),
                            .destination(.history(recordID: id)))
            try expectEqual(NotificationRoute.target(userInfo: ["updateVersion": "1.4.0"]), .updateSheet)
            try expectEqual(NotificationRoute.target(userInfo: ["activity": "1"]), .destination(.activity))
            try expectEqual(NotificationRoute.target(userInfo: ["url": "https://github.com/acme/web/pull/1"]),
                            .url(URL(string: "https://github.com/acme/web/pull/1")!))
            try expectEqual(NotificationRoute.target(userInfo: [:]), nil)
        },
    ]
}
```

Las del snapshot (nuevo PR para revisar → `.review`; feedback en un PR mío → `.respond`; listo para mergear →
`.merge`; CI roto en un PR mío → `.fixCI`; aprobado → `.merge`) se prueban en `NotificationPlannerTests.swift` y
`ReadyToMergeNotificationTests.swift` (que ya arman snapshots `previous`/`current`): una aserción `tab == …` en cada
caso existente que crea esas notificaciones, en vez de duplicar el armado.

Origen iPhone (en `RespondQueueTests.swift`, con sus helpers):
- `"respond queue: guarda cuándo empezó la corrida y si la pidió un iPhone"`: `CommandOrigin.$current.withValue(.phone(device:
  "d1", mayRunRepoCode: false)) { queue.analyze(classified(7), …) }` → `queue.runs[prID(7)]?.requestedOnPhone == true` y
  `startedAt` cerca de `Date()`; al completar el análisis, `queue.records[prID(7)]?.requestedOnPhone == true`; un
  `analyze` desde la Mac (sin `withValue`) → `false`/`nil`; `dismiss` borra `runs[prID]`.
- En `ReviewHistoryTests`/`MergeHistoryTests`/`RespondModelsTests`: un JSON viejo sin `requestedOnPhone` decodifica con
  `nil`; con `true` hace ida y vuelta.
- `CommandOrigin.phone(device: "d", mayRunRepoCode: true).isPhone == true`, `.mac.isPhone == false`.

- [ ] **Step 2:** Registrar `PRBarURLTests` y `NotificationRouteTests`; build → falla.
- [ ] **Step 3: Implementar.**

`PRBarURL.swift`:

```swift
import Foundation

/// Links `prbar://` (spec M.4): `prbar://pr/<owner>/<repo>/<number>[/<tab>]`, `prbar://review`, `prbar://mine`,
/// `prbar://history`, `prbar://activity`. También entiende el `?screen=` de los links del iPhone.
public enum PRBarURL {
    public static let scheme = "prbar"

    /// nil: no es de PRBar o no se entiende (la app abre la ventana sin moverse).
    public static func destination(_ url: URL) -> MainDestination? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme, let host = components.host?.lowercased() else { return nil }
        let parts = components.path.split(separator: "/").compactMap { String($0).removingPercentEncoding }
        switch host {
        case "review": return parts.isEmpty ? .list(.toReview) : nil
        case "mine": return parts.isEmpty ? .list(.myPRs) : nil
        case "history": return parts.isEmpty ? .history(recordID: nil) : nil
        case "activity": return parts.isEmpty ? .activity : nil
        case "pr":
            guard parts.count == 3 || parts.count == 4, PRReference.isValidName(parts[0]),
                  PRReference.isValidName(parts[1]), let number = Int(parts[2]), number > 0 else { return nil }
            let screen = components.queryItems?.first { $0.name == "screen" }?.value
            let tabName = parts.count == 4 ? parts[3] : screen
            var tab: PRTab?
            if let tabName {
                guard let parsed = PRTab(urlName: tabName) else { return nil }
                tab = parsed
            }
            return .pr(prID: "\(parts[0])/\(parts[1])#\(number)", tab: tab)
        default:
            return nil
        }
    }

    public static func url(for destination: MainDestination) -> URL? {
        switch destination {
        case .list(.toReview): URL(string: "prbar://review")
        case .list(.myPRs): URL(string: "prbar://mine")
        case .history: URL(string: "prbar://history")
        case .activity: URL(string: "prbar://activity")
        case .pr(let prID, let tab):
            prURL(prID, tab: tab)
        }
    }

    /// `owner/repo#N` → `prbar://pr/owner/repo/N[/tab]`.
    private static func prURL(_ prID: String, tab: PRTab?) -> URL? {
        let parts = prID.split(separator: "#")
        guard parts.count == 2 else { return nil }
        return URL(string: "prbar://pr/\(parts[0])/\(parts[1])" + (tab.map { "/\($0.urlName)" } ?? ""))
    }
}
```

(`PRReference.isValidName` ya acepta letras, números, `-`, `_` y `.` ASCII.)

`NotificationPlanner.swift`: `PlannedNotification` suma `public let tab: PRTab?` (parámetro `tab: PRTab? = nil` al final
del `init`). Lo ponen: `plan` → `.newToReview`/`.reviewedPRUpdated` `.review`, `.myPRFeedback` `.respond`,
`.readyToMerge` `.merge`, "Your PR Was Approved" `.merge`, "CI Failed on Your PR" `.fixCI`; `reviewFinished` `.review`;
`respondFinished` `.respond` en los eventos de Respond y `.fixCI` en los `ciFix*`. `updateAvailable` y `diskWarning`,
nil. `RemotePushPlanner` no cambia.

`NotificationRoute.swift`:

```swift
import Foundation

/// A dónde lleva el clic en una notificación (spec M.4).
public enum NotificationTarget: Equatable, Sendable {
    case destination(MainDestination)
    case updateSheet
    case url(URL)
}

public enum NotificationRoute {
    /// Lo que viaja en `UNNotificationContent.userInfo` (antes lo armaba `NotificationDelivery`).
    public static func userInfo(_ n: PlannedNotification) -> [String: String] {
        var info: [String: String] = [:]
        if let url = n.url { info["url"] = url.absoluteString }
        if let prID = n.reviewPRID { info["reviewPRID"] = prID }
        if let recordID = n.reviewRecordID { info["reviewRecordID"] = recordID.uuidString }
        if let prID = n.respondPRID { info["respondPRID"] = prID }
        if let version = n.updateVersion { info["updateVersion"] = version }
        if let prID = n.prID { info["prID"] = prID }
        if let prID = n.mergePRID { info["mergePRID"] = prID }
        if let tab = n.tab { info["tab"] = tab.rawValue }
        if n.kind == .diskUsage { info["activity"] = "1" }
        return info
    }

    public static func target(userInfo info: [String: String]) -> NotificationTarget? {
        if info["activity"] != nil { return .destination(.activity) }
        if info["updateVersion"] != nil { return .updateSheet }
        if let id = info["reviewRecordID"].flatMap(UUID.init(uuidString:)) { return .destination(.history(recordID: id)) }
        if let prID = info["mergePRID"] ?? info["respondPRID"] ?? info["reviewPRID"] ?? info["prID"] {
            return .destination(.pr(prID: prID, tab: info["tab"].flatMap(PRTab.init(rawValue:))))
        }
        if let url = info["url"].flatMap(URL.init(string:)) { return .url(url) }
        return nil
    }
}
```

Origen iPhone:
- `CommandOrigin`: `public var isPhone: Bool { if case .phone = self { true } else { false } }`.
- `ReviewRecord`, `RespondRecord`, `MergeRecord`: `public var requestedOnPhone: Bool?` (nil = Mac o registro viejo).
  `ReviewRecord` tiene Codable sintetizado (un opcional se lee con `decodeIfPresent` solo); en `RespondRecord` y
  `MergeRecord` sumar la clave a `CodingKeys` y `decodeIfPresent` en su `init(from:)`, y el parámetro con default nil
  al final de cada `init`.
- `RespondQueue`: `@Published public private(set) var runs: [String: ClaudeRunInfo] = [:]`. En `analyze`, antes de
  `start`: `let onPhone = CommandOrigin.current.isPhone` y `runs[prID] = ClaudeRunInfo(startedAt: startedAt,
  requestedOnPhone: onPhone)`; los dos `RespondRecord(...)` de `analyze` reciben `requestedOnPhone: onPhone ? true :
  nil`. `dismiss(prID:)` borra `runs[prID]`. (El `TaskLocal` llega acá porque el puente remoto llama a `AppModel` dentro
  de `CommandOrigin.$current.withValue`; `JobScheduler` lo vuelve `.mac` solo adentro de los trabajos.)

- [ ] **Step 4:** `swift run PRBarTests "prbar://"`, `"notificación → destino"`, `notification`, `"respond queue"`,
  `history` y la suite verdes; `swift build --product PRBar` compila (`NotificationDelivery` todavía arma su `userInfo`:
  en este paso cambiar su `deliver` para usar `NotificationRoute.userInfo(notification)`, sin tocar todavía el clic).
  **Commit** `"Add prbar:// links, notification routes and the iPhone origin of jobs"`.

---

### Task 5: Estado, `navigate(to:)` y la ventana principal

**Files:** Create `Sources/PRBar/Main/MainWindowState.swift`, `MainWindow.swift`, `MainSidebar.swift`,
`PRListPane.swift`, `PRListRow.swift`, `PRDetailView.swift`, `PRTabBar.swift`, `PRDetailState.swift`,
`EmptyDetailView.swift`, `Sources/PRBar/AppModel+Navigation.swift`; modify `AppModel.swift`, `Theme.swift`,
`Components/WindowCommands.swift`, `Popover/PRRowView.swift`, `UIActionInventory.swift`.

Layout: spec M.1 "Estructura de la ventana principal", "Barra lateral", "Lista"; boceto `MacMain.dc.html`.

**Decisión de estructura:** `NavigationSplitView` de **dos** columnas nativas (barra lateral | contenido) y, adentro del
contenido, la lista (ancho `MainLayout.listWidth`) + `Divider` + detalle en un `HStack`. Se ve igual que tres columnas,
pero así (a) Activity ocupa todo el ancho al lado de la barra lateral y (b) el modo foco oculta **solo** la lista. Con
tres columnas nativas ninguna de las dos se puede (`.doubleColumn` esconde la barra lateral, no la lista).

- [ ] **Step 1: `Theme.MainLayout`**:

```swift
extension Theme {
    enum MainLayout {
        static let defaultSize = NSSize(width: 1280, height: 800)
        static let minSize = NSSize(width: 960, height: 600)
        static let sidebarWidth: CGFloat = 236
        static let inspectorWidth: CGFloat = 300
        static let searchWidth: CGFloat = 170
        static let titleColumnWidth: CGFloat = 220
        static let mergeSideColumnWidth: CGFloat = 240
    }
}
```

- [ ] **Step 2: Estado.**

```swift
// Sources/PRBar/Main/PRDetailState.swift
/// El modo foco y el chat del detalle de una ventana (la principal tiene uno; cada ventana de PR, el suyo).
@MainActor
final class PRDetailState: ObservableObject {
    @Published var focus = FocusModeState()
}

// Sources/PRBar/Main/MainWindowState.swift
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, reviews, responds, merges
    var id: String { rawValue }
    var title: String { rawValue.capitalized }   // All · Reviews · Responds · Merges
}

/// La ventana principal mientras la app está abierta: sobrevive a cerrarla con ⌘W (`WindowPresenter` arma la vista de
/// cero al reabrirla, el estado queda acá).
@MainActor
final class MainWindowState: ObservableObject {
    @Published private(set) var nav = MainNavigationState()
    @Published var search = ""
    /// Secciones plegadas o desplegadas a mano (las demás siguen `MainList.initiallyCollapsed`).
    @Published private var collapsedByUser: [MainListSection: Bool] = [:]
    @Published var updateSheet: UpdateWindowMode?
    @Published var historyFilter: HistoryFilter = .all
    let detail = PRDetailState()

    func go(to destination: MainDestination, snapshot: Snapshot?) {
        let before = nav.place.sidebar
        nav.go(to: destination) { prID in snapshot?.items.first { $0.id == prID }.map(MainList.mainSection(of:)) }
        if nav.place.sidebar != before { search = "" }
    }

    func select(prID: String?) { nav.select(prID: prID) }
    func select(historyRecord id: UUID?) { nav.select(historyRecord: id) }
    func choose(_ tab: PRTab, for prID: String) { nav.choose(tab, for: prID) }
    func goBack() { nav.goBack() }

    func isCollapsed(_ section: MainListSection, itemCount: Int) -> Bool {
        collapsedByUser[section] ?? MainList.initiallyCollapsed(section, itemCount: itemCount)
    }

    func setCollapsed(_ collapsed: Bool, _ section: MainListSection) { collapsedByUser[section] = collapsed }
}
```

`UpdateWindowMode` gana `Identifiable` (ya tiene `id`): `extension UpdateWindowMode: Identifiable {}`.

- [ ] **Step 3: `AppModel`.** `let main = MainWindowState()` en `AppModel`; `reviewStarts` pasa a
  `private(set) var reviewRuns: [String: ClaudeRunInfo]` (en `startReview`: `ClaudeRunInfo(startedAt: Date(),
  requestedOnPhone: CommandOrigin.current.isPhone)`; `reviewFinished` usa `.startedAt` y pone
  `record.requestedOnPhone`; `cancelReview` lo borra). `AppModel+Navigation.swift`:

```swift
import AppKit
import PRBarCore

extension AppModel {
    static let mainWindowID = "main"

    /// La única entrada a la ventana principal (spec M.4): la abre o enfoca, cierra el popover, elige sección, PR y
    /// pestaña, y empuja el lugar anterior a Back. Lo que pide un iPhone nunca navega ni roba el foco.
    func navigate(to destination: MainDestination) {
        guard !CommandOrigin.current.isPhone else {
            AppLog.write("Ignored a navigation requested from an iPhone.")
            return
        }
        main.go(to: destination, snapshot: prStore.snapshot)
        openMainWindow()
    }

    /// ⌘0, "Open PRBar", el Dock: abre o enfoca la ventana sin moverse.
    func openMainWindow() {
        closePopover?()
        WindowPresenter.shared.show(
            id: Self.mainWindowID, title: "PRBar", size: Theme.MainLayout.defaultSize,
            options: WindowOptions(autosaveName: "MainWindow", allowsTabbing: false, kind: .document, bridgesToolbar: true,
                                   toolbarStyle: .unified, minContentSize: Theme.MainLayout.minSize),
            contentID: "main"
        ) {
            MainWindow(model: self)
        }
    }

    /// Las pestañas del PR; nil si no hay nada que mostrar (ni en la lista, ni review, ni Respond).
    func tabContext(prID: String) -> PRTabContext? {
        let task: RespondMode? = respond.phases[prID] != nil || respond.records[prID] != nil ? respond.mode(of: prID) : nil
        if let item = currentItem(prID) { return PRTabContext(item: item, respondTask: task) }
        if reviews.phases[prID] != nil { return PRTabContext(isMine: false, hasFeedback: false, ciFailing: false, respondTask: nil) }
        if task != nil { return PRTabContext(isMine: true, hasFeedback: false, ciFailing: false, respondTask: task) }
        return nil
    }

    /// Las filas del grupo Claude y de la franja del popover.
    func claudeTaskInputs() -> [ClaudeTaskInput] {
        Set(reviews.phases.keys).union(respond.phases.keys).sorted().map { prID in
            ClaudeTaskInput(
                prID: prID, review: reviews.phases[prID], reviewStartedAt: reviewRuns[prID]?.startedAt,
                respond: respond.phases[prID], respondMode: respond.mode(of: prID),
                runningTests: respond.runningTests.contains(prID), respondStartedAt: respond.runs[prID]?.startedAt,
                fromPhone: reviewRuns[prID]?.requestedOnPhone == true || respond.runs[prID]?.requestedOnPhone == true
            )
        }
    }

    func claudeTaskRows(now: Date = Date()) -> [ClaudeTaskRow] {
        ClaudeTasksSidebar.rows(claudeTaskInputs(), now: now)
    }
}
```

- [ ] **Step 4: `WindowCommands`.** `WindowCommandModifier` borra su registro en `.onDisappear`
  (`WindowCommandCenter.shared.unregister(command, in: window)`): en la ventana principal los panes van y vienen y un
  handler viejo (p. ej. el ⌘R de Merge) no puede quedar colgado. Sumar `func unregister(_:in:)`.
- [ ] **Step 5: La vista.** `MainWindow(model:)`:

```swift
struct MainWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    @ObservedObject var prStore: PRStore
    @ObservedObject var detail: PRDetailState
    @State private var columns = NavigationSplitViewVisibility.all

    init(model: AppModel) {
        self.model = model
        state = model.main
        prStore = model.prStore
        detail = model.main.detail
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            MainSidebar(model: model, state: state)
                .navigationSplitViewColumnWidth(Theme.MainLayout.sidebarWidth)
        } detail: {
            GeometryReader { geometry in content(windowWidth: geometry.size.width + Theme.MainLayout.sidebarWidth) }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .frame(minWidth: Theme.MainLayout.minSize.width, minHeight: Theme.MainLayout.minSize.height)
    }

    @ViewBuilder
    private func content(windowWidth: Double) -> some View {
        switch state.nav.place.sidebar {
        case .section(let section):
            HStack(spacing: 0) {
                if !detail.focus.isFocused {
                    PRListPane(model: model, state: state, section: section)
                        .frame(width: MainLayout.listWidth(windowWidth: windowWidth))
                    Divider()
                }
                detailView
            }
        case .history:
            Text("History")   // Task 9
        case .activity:
            Text("Activity")   // Task 10
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let prID = state.nav.place.prID {
            PRDetailView(model: model, prID: prID, detail: detail)
        } else {
            EmptyDetailView()
        }
    }
}
```

  - **Toolbar** (spec M.1, 52 pt unificada): el botón de barra lateral lo pone `NavigationSplitView`; `ToolbarItem
    (placement: .navigation)` Back (`chevron.backward`, deshabilitado sin `nav.back.canGoBack`); título y subtítulo con
    `navigationTitle`/`navigationSubtitle` (título = sección: "To Review", "My PRs", "History", "Activity"; subtítulo:
    "N PRs · updated 2 min ago" / "updating…" / "offline" como el popover, "N records" en History, "CPU x% · RAM y" en
    Activity); `.principal`: las pestañas del PR (las pone `PRDetailView`, Step 7) o las de History (Task 9);
    `.primaryAction`: grupo Refresh (`ProgressView` chico mientras `prStore.isRefreshing`) · Open in New Window
    (`macwindow.badge.plus`, Task 14; hasta entonces deshabilitado) · Open on GitHub (`arrow.up.right.square`, con PR
    elegido). La búsqueda llega en la Task 18.
  - **`MainSidebar`**: `List(selection:)` con `.listStyle(.sidebar)`; la selección es un `Binding<SidebarItem?>` que
    llama a `model.navigate(to:)` (`.list(s)`, `.history(recordID: nil)`, `.activity`). Grupo "Pull Requests" (To
    Review `tray` con `.badge(count)`, My PRs `prbar` (el símbolo del ícono de la app; si no existe como SF Symbol,
    `arrow.triangle.pull`)); grupo `ClaudeTasksSidebar.groupTitle(rows)` solo si `rows` no está vacío, dentro de
    `TimelineView(.periodic(from: .now, by: 1))` mientras alguna corre: cada fila es un `Button` (no seleccionable)
    con `repo#N`, subtítulo, `ProgressView().controlSize(.mini).tint(Theme.violet)` o `checkmark.circle.fill` verde y
    `iphone` si `fromPhone`, que hace `model.navigate(to: .pr(prID: row.prID, tab: row.tab))`; grupo sin título History
    (`clock.arrow.circlepath`) · Activity (`gauge`). **Pie** con `.safeAreaInset(edge: .bottom)`: aviso de update
    (Task 11), fila del iPhone (si `model.remoteAccess.devices` no está vacío: nombre del primero y punto verde si
    `online.contains(deviceId)`; clic → `model.openSettings(tab: .iphone)`), engranaje → `model.openSettings()`.
    VoiceOver: cada fila con `accessibilityLabel` completo ("api#317, Reviewing, 1 minute 12 seconds, requested from
    iPhone").
  - **`PRListPane`**: `List(selection: Binding(get: { state.nav.place.prID }, set: { state.select(prID: $0) }))` con
    `Section(isExpanded:)` por `MainList.sections(section)` (encabezado con título y contador; plegado con
    `state.isCollapsed`/`setCollapsed`). Filas: `PRListRow`. **Cargando** (`prStore.snapshot == nil`): cinco filas
    esqueleto (rectángulos redondeados `Color.primary.opacity(0.08)` con `.redacted(reason: .placeholder)`).
    **Vacío** (ninguna sección no callada con PRs): `MessageView(icon: "checkmark.seal", iconColor: Theme.green,
    title: "All caught up", ...)` con el texto de `PopoverTabs.emptyState`, y en To Review, si
    `MainList.hiddenDraftCount > 0`, el botón "N drafts hidden · Show" que despliega "Other" (ver decisiones, M.9). Los
    estados sin cuenta / sin `gh` / offline usan los mismos `MessageView` del popover (copiar las ramas de
    `PopoverView.content`). **↩**: `.onKeyPress(.return)` → `model.performPrimaryAction(prID:)` (Step 6). **Doble
    clic**: `.contextMenu(forSelectionType: String.self) { ids in … menú de la fila … } primaryAction: { ids in
    model.openPRWindow(prID:) }` (hasta la Task 14, `primaryAction` no hace nada). `.defaultFocus` en la lista para que
    ↓ elija la primera fila.
  - **`PRListRow`** (versión ancha de `PRRowView`, spec M.1 "Fila"): avatar con iniciales (`AvatarView`) si el PR es
    ajeno o ícono de estado si es mío (`bubble.left.and.exclamationmark.bubble.right` naranja en With Feedback,
    `xmark.octagon.fill` rojo en CI Failing, `checkmark.circle.fill` verde en Ready to Merge, `clock` gris en Waiting
    for Review); título en dos líneas; edad; `repo#N · base`; CI + `+adds −dels`; el pill a la derecha. El pill es
    `PRRowAccessory`: extraer de `PRRowView` (`trailingAccessory`, `categoryAccessory` y los `*Actions`) a
    `Popover/PRRowAccessory.swift` como vista pública del módulo que reciben las dos filas. Selección: la de `List`
    (fondo acento, texto blanco).
  - **`EmptyDetailView`**: `MessageView(icon: "sidebar.squares.right", title: "No PR Selected", text: "Pick a PR from the
    list, or press ↓ to select the first one.")` y debajo la línea de atajos `"⌘1 To Review · ⌘2 My PRs · ⌘F Search"`.
- [ ] **Step 6: `performPrimaryAction`** en `AppModel+Navigation.swift`:

```swift
    /// ↩ en la lista y el pill: la acción de `PRPrimaryAction` y la pestaña que le corresponde.
    func performPrimaryAction(prID: String) {
        guard let item = currentItem(prID) else { return }
        let action = PRPrimaryAction.of(item, review: reviews.phases[prID], respond: respond.phases[prID],
                                        respondMode: respond.phases[prID] == nil ? nil : respond.mode(of: prID))
        switch action {
        case .startReview: startReview(item)
        case .startRespond: rowActions(item).respond.retry()   // misma regla que el pill (Retry con fixes → abre)
        case .startCIFix: startCIFix(item)
        case .openReview, .openRespond, .openCIFix, .openMerge, .none: break
        }
        if let tab = action.tab { navigate(to: .pr(prID: prID, tab: tab)) }
    }
```

  `rowActions(_:)` es la fábrica de `ReviewButtonActions`/`RespondButtonActions`/`MergeButtonActions` que salió de
  `PRRowView` (Step 5), en `AppModel+Popover.swift`; en esta task sus `open` siguen llamando a los `open*` de hoy.
- [ ] **Step 7: `PRDetailView` y `PRTabBar` (esqueleto).**

```swift
struct PRDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue
    @ObservedObject var prStore: PRStore
    @ObservedObject var detail: PRDetailState
    let prID: String

    init(model: AppModel, prID: String, detail: PRDetailState) { /* asignar; state = model.main */ }

    var body: some View {
        if let context = model.tabContext(prID: prID) {
            let tab = state.nav.tab(for: prID, context: context)
            pane(tab)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        PRTabBar(tabs: PRTabs.tabs(context), selected: tab,
                                 indicator: { ClaudeTasksSidebar.indicator(prID: prID, tab: $0, rows: model.claudeTaskRows()) },
                                 choose: { state.choose($0, for: prID) })
                    }
                }
        } else {
            PRGoneView(prID: prID)   // "This PR is no longer in your list" + Open on GitHub (PRReference.githubURL)
        }
    }

    /// Hasta su task, cada pestaña muestra un botón que abre la ventana de hoy.
    @ViewBuilder
    private func pane(_ tab: PRTab) -> some View {
        switch tab {
        case .review, .details: LegacyPaneButton(title: "Open Review Window") { model.openReview(prID: prID) }
        case .merge: LegacyPaneButton(title: "Open Merge Window") { if let item = model.currentItem(prID) { model.requestMerge(item) } }
        case .respond, .fixCI: LegacyPaneButton(title: "Open Respond Window") { model.openRespond(prID: prID) }
        }
    }
}
```

  `PRTabBar`: `HStack` de botones en cápsula (vidrio en macOS 26, `.regularMaterial` antes), el elegido con fondo
  acento; cada botón con `ProgressView` mini violeta (`.running`) o un punto verde de 6 pt (`.ready`); deshabilitado si
  `!isEnabled`; `.accessibilityAddTraits(.isSelected)` en el elegido y `accessibilityLabel("Respond, Claude is
  working")`. `LegacyPaneButton` y `PRGoneView` son privados del archivo; `LegacyPaneButton` se borra en la Task 8.
- [ ] **Step 8:** Paridad UI (entradas nuevas `.viewOnly("navigation in the main window")`; las de `PRRowView` que se
  mudan a `PRRowAccessory.swift` conservan su mapeo; `LegacyPaneButton` → `.viewOnly("temporary, removed in plan 21")`).
  Hasta la Task 16 no hay atajo para abrir la ventana: para probar, un botón provisorio "Open PRBar Window" en el menú
  ⚙︎ del popover que llama a `model.openMainWindow()` (se reemplaza en la Task 12).
- [ ] **Step 9:** `swift build --product PRBar`, `swift run PRBarTests`, capturas: sumar una provisoria
  `main-list` a `SnapshotMode` (modelo `main`, `main.main.go(to: .list(.toReview), snapshot:)`, ventana 1280×800,
  `MainWindow(model:)`) y mirarla. **Commit** `"Add the main window with sidebar, PR list and empty states"`.

---

### Task 6: Pestaña Review, inspector de chat

**Files:** `git mv Sources/PRBar/Review/ReviewWindow.swift Sources/PRBar/Review/ReviewEditor.swift`; create
`Review/ReviewPane.swift`, `Main/ChatInspector.swift`; modify `Main/PRDetailView.swift`, `AppModel.swift`
(`openReview`, `reopenFromHistory`, `openFromNotification`), `AppModel+Commands.swift`, `Snapshots/SnapshotMode.swift`,
`UIActionInventory.swift`.

Layout: spec M.1 "Review"; boceto `MacReview.dc.html`.

- [ ] **Step 1: `ReviewEditor`** (lo que era `ReviewWindow`): renombrar el tipo; sacar `static let size`, el `.toolbar`
  del chat, `.growsWindowForInspector`, `.windowCommand(.toggleChat…)`, `.inspector` y `showsChat`
  (`InitialState.showsChat` se va). `reportUnsaved` desaparece (lo elegido vive en el coordinador del draft, spec M.7) y
  `close` pasa a `(() -> Void)?`: nil esconde "Close" en `ReviewPublishedView` y no se llama después de publicar
  (`close?()`). Ajustes al boceto: `ReviewHeader` con `owner/repo #N`, botón Open on GitHub, título 20 pt
  (`.font(.system(size: 20, weight: .semibold))`), autor, ramas, `+/−` y archivos (`pr.changedFiles`); el resumen
  violeta con "agents · time · cost" (`draft.usage`: `runs` agentes, `ClaudeTasksSidebar.clock(usage.durationSeconds)`,
  `UsageFormat.cost(draft.usage)`; sin `usage`, sin la línea); "Findings · N of M included" con botones All / None
  (seleccionan o vacían `chat.reviewEdits.selected` entre los `kept`); "Discarded by the filter (N)" plegado; barra
  inferior con comentario general, decisión (Approve / Comment / Request Changes) y **Post Review** con
  `.keyboardShortcut(.return, modifiers: .command)` (ya lo tiene).
- [ ] **Step 2: `ReviewPane(model:prID:)`**:

```swift
struct ReviewPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var reviews: ReviewQueue
    let prID: String

    var body: some View {
        switch reviews.phases[prID] {
        case .ready(let draft)?:
            ReviewEditor(model: model, draft: draft, chat: model.reviewChat(for: draft), published: nil, close: nil)
                .id(draft.id)
        case .published?:
            if let record = model.publishedReviewRecord(prID: prID) {
                ReviewEditor(model: model, draft: record.draft, chat: model.reviewChat(for: record.draft),
                             published: PublishedReview(record: record), close: nil)
                    .id(record.id)
            } else {
                ReviewStartView(model: model, prID: prID)
            }
        case let phase? where phase.isActive:
            ReviewProgressView(model: model, prID: prID, phase: phase)   // "Queued…" / "Reviewing with N agents · 1:12" + Cancel
        default:
            ReviewStartView(model: model, prID: prID)   // cabecera del PR, su estado, error si falló, Start Review
        }
    }
}
```

  `publishedReviewRecord(prID:)` en `AppModel`: lo que hoy hace `openReview` para `.published` (el último registro
  publicado del PR en `history`). `ReviewStartView`: `ReviewHeader` + estado del PR (CI, aprobaciones, si cambió desde
  mi review) + `Button("Start Review") { model.startReview(item) }` (`.borderedProminent`, deshabilitado con
  `jobsBlockedReason`, `help` con la razón) y, si la fase es `.failed`, el error con "Show Log". El reloj del progreso
  sale de `model.reviewRuns[prID]?.startedAt` dentro de `TimelineView(.periodic(by: 1))`.
- [ ] **Step 3: `ChatInspector(model:prID:tab:)`** (spec M.1 "Modo foco y chat"): el `ChatPanel` de la pestaña —
  Review/Details: `model.reviewChat(for:)` del draft listo o publicado (sin draft: texto "Start a review to chat with
  Claude about this PR."); Respond/Fix CI: `model.respondChat(for:)` del `respond.records[prID]?.draft` (sin registro:
  "Start Respond to chat with Claude." / "Start Fix CI…"); Merge: `model.mergeChat(prID:)` (lo arma la Task 7; por ahora
  el texto de "The chat needs the PR in PRBar’s list."). Mismos `unavailableReason`, `notice`, `host`, `logURL` que
  usaba cada ventana. En `PRDetailView`:

```swift
            pane(tab)
                .inspector(isPresented: Binding(get: { detail.focus.chatShown && model.chatEnabled },
                                                set: { detail.focus.setChatShown($0) })) {
                    ChatInspector(model: model, prID: prID, tab: tab)
                        .inspectorColumnWidth(min: Theme.MainLayout.inspectorWidth, ideal: Theme.MainLayout.inspectorWidth,
                                              max: 480)
                }
                .windowCommand(.toggleChat, enabled: model.chatEnabled, isOn: detail.focus.chatShown && model.chatEnabled) {
                    detail.focus.toggleChat()
                }
```

  **Hecho distinto (implementación):** un `.inspector` adentro de la columna de detalle del `NavigationSplitView`
  (es decir, dentro del `HStack` lista + detalle) desarma el layout (la lista queda en blanco y el detalle se sale de la
  ventana). El inspector es `ChatInspectorModifier` (en `PRDetailView.swift`): `PRDetailView(…, hostsInspector:)` lo
  pone él mismo (ventana de PR, por defecto `true`) y la ventana principal pasa `false` y lo aplica en `MainWindow` a
  todo el contenido de la columna de detalle (queda a la derecha de lista + detalle). Con el chat abierto la lista toma
  su ancho mínimo. La barra inferior de Review: fila "Posting as @x · N comments" (+ "Approve Without Comments…" con
  Approve elegido) y fila con el segmentado de decisión y Post Review.
  y en la toolbar (`.primaryAction`, junto al grupo de la ventana) el botón Chat (`bubble.left.and.bubble.right`, help
  "Show Chat (⌥⌘I)"; el atajo lo pone el menú en la Task 16). Cerrado por defecto.
- [ ] **Step 4: Enrutar** (spec M.4): `openReview(prID:)` → `navigate(to: .pr(prID: prID, tab: .review))` (sin la
  guarda de fase: la pestaña muestra lo que haya); `reopenFromHistory` sigue restaurando y llama a `openReview`;
  `openFromNotification` igual que hoy. `prbar open --review` (en `AppModel+Commands.open`) mantiene su chequeo y llama a
  `openReview`. Borrar `reviewWindowID` y el `WindowPresenter.show` de review. `PRDetailView.pane`: `.review` →
  `ReviewPane`; `.details` sigue con el botón provisorio hasta la Task 7.
- [ ] **Step 5: Capturas:** reemplazar `review-window`, `review-chat`, `review-chat-rule`, `review-published` por
  `main-review` (lista + PR con review lista, `main.go(to: .pr(prID: fixtures.reactQuery.id, tab: .review))`, 1280×800)
  y `main-review-chat` (lo mismo con `main.detail.focus.setChatShown(true)`, y la regla propuesta en el chat como hoy
  `review-chat-rule`). `ReviewEditor.InitialState` sigue para abrir los descartados y un hallazgo desplegado.
- [ ] **Step 6:** Paridad UI (los controles de `Review/ReviewWindow.swift` pasan a `Review/ReviewEditor.swift` con el
  mismo mapeo; "Start Review" → `.cli(["review"])`, "Cancel" del progreso → `.cli(["review cancel"])`, All / None →
  `.cli(["review select"])` si existe ese comando — mirar `CLIRouter.allPaths`; si no, `.cli(["review publish"])` con
  el comentario `// --only`). `swift build --product PRBar`, `swift run PRBarTests`, capturas. **Commit**
  `"Show reviews in the main window's Review tab"`.

---

### Task 7: Pestañas Details y Merge

**Files:** `git mv Sources/PRBar/Merge/MergeWindow.swift Sources/PRBar/Merge/MergeDetailPane.swift`; modify
`AppModel+Merge.swift`, `Main/PRDetailView.swift`, `Main/ChatInspector.swift`, `AppModel+Commands.swift`, snapshots,
`UIActionInventory.swift`.

Layout: spec M.1 "Details" y "Merge"; boceto `MacMerge.dc.html`.

- [ ] **Step 1: `MergeDetailPane(model:session:mode:)`** con `enum MergePaneMode { case details, merge }`. Sacar
  `static let size`, toolbar, inspector, `growsWindowForInspector` y el `.windowCommand(.toggleChat)`; queda el
  `.windowCommand(.refresh)` (⌘R refresca el detalle mientras se ve la pestaña). Layout del boceto: cabecera
  (`MergeHeader`) con **badge de estado** arriba a la derecha ("Ready", "Blocked", "Merged", "Checks failing"… de
  `mergeOptions(item).availability` / la fase); dos columnas en `.merge`: izquierda Description · Conversations ·
  Files changed; derecha (`Theme.MainLayout.mergeSideColumnWidth`) Reviews · Checks (las primeras 5 y "Show N more") ·
  bloque de merge: `Picker` de método (Squash / Merge / Rebase) con la nota de qué hace (`MergeMethod` ya la tiene en
  la ventana de hoy), fila **"Delete branch after merge"** y fila **"Post in #canal"** (ver decisiones: informativas,
  ver M.9) y el botón **"Squash and Merge"** (`methodBinding.wrappedValue.actionTitle`) con atajo ⇧⌘M
  (`.keyboardShortcut("m", modifiers: [.command, .shift])`, ya **no** ⌘↩). En `.details`: las mismas secciones de solo
  lectura en una columna (o dos sin el bloque de merge, como diga el boceto), sin `bar` de merge.
- [ ] **Step 2: Sesiones de merge sin ventana.** En `AppModel+Merge.swift`:
  - `private(set) var shownPRDetails: [String: Int] = [:]` y `func detailAppeared(_ prID: String)` /
    `detailDisappeared(_:)` (las llama `PRDetailView` en `onAppear`/`onDisappear`).
  - `updateMergeSessions`: cambia `!WindowPresenter.shared.isOpen(id: Self.mergeWindowID(prID))` por
    `shownPRDetails[prID, default: 0] == 0`.
  - `openMergeWindow(_:)` se va; `func loadMergeDetail(prID: String) async`: `guard let item = currentItem(prID)`,
    `let session = mergeSession(for: item)`, `await loadMergeWindow(session, alreadyOpen: session.window.detail != nil)`.
    `MergeDetailPane` lo llama en `.task(id: prID)`.
  - `mergeFinished`: en vez de `WindowPresenter.shared.close(id: mergeWindowID)` cierra la ventana de PR si hay
    (`WindowPresenter.shared.close(id: Self.prWindowID(item.id))`, Task 14; hasta entonces nada) y, después del
    refresco, si `main.nav.place.prID == item.id` y el PR ya no está, `main.select(prID: nil)`.
  - `requestMerge(_:)` → `guard MergeFlow.request(...) == .open else { return }; navigate(to: .pr(prID: item.id, tab:
    .merge))`. `openMergeFromNotification` sin cambios (llama a `requestMerge`). Borrar `mergeWindowID`.
- [ ] **Step 3:** `PRDetailView.pane`: `.details` → `MergeDetailPane(mode: .details)`, `.merge` → `.merge` (con la
  sesión `model.mergeSession(for: item)`; sin PR en la lista → `PRGoneView`). `ChatInspector` para `.merge` usa
  `model.mergeChat(prID:)` (lo crea la primera vez que se abre el inspector, como hacía `MergeWindow.onChange`) con
  `chatNotice` movido acá.
  **Hecho (implementación):** `shownPRDetails` es una propiedad guardada de `AppModel` (una extensión no puede
  tenerla). El chat de Merge es `MergeChatPanel` (en `MergeDetailPane.swift`; crea el chat en su `onAppear`, o sea la
  primera vez que se abre el inspector). Debajo de 600 pt de ancho (chat abierto) el detalle pasa a una columna con el
  bloque de merge arriba. La fila de borrar la rama dice "Delete branch after merge" o "Branch is kept after merge"
  según `RepoMergeSettings.deleteBranchOnMerge`; "Post in #canal" sale con Slack prendido, "Merged" activado y canal
  en el repo. El badge: Ready · Blocked · Checks failing · New commits · Merging… · Merged · Failed.
- [ ] **Step 4:** Capturas `merge-window`, `merge-chat` → `main-merge` (PR propio Ready to Merge en la pestaña Merge) y
  `main-details` (PR ajeno en Details). Paridad UI ("Squash and Merge"/"Merge" conserva `.cli(["merge"])`; las filas
  informativas no son controles). **Commit** `"Move Merge into the main window's Details and Merge tabs"`.

---

### Task 8: Pestañas Respond y Fix CI, modo foco

**Files:** `git mv Sources/PRBar/Respond/RespondWindow.swift Sources/PRBar/Respond/RespondPane.swift`; modify
`AppModel.swift` (`openRespond`, `dismissRespond`, `openRespondFromNotification`), `AppModel+CIFix.swift`,
`Main/PRDetailView.swift`, `Main/MainWindow.swift`, `Chat/ChatPanel.swift`, snapshots, `UIActionInventory.swift`.

Layout: spec M.1 "Respond / Fix CI" y "Modo foco y chat"; boceto `MacRespond.dc.html`.

- [ ] **Step 1: `RespondPane(model:prID:mode:)`** (lo que era `RespondWindow`): sacar `size`, toolbar del chat,
  inspector, `growsWindowForInspector`, `reportUnsaved`; `close` opcional como en Review. Sin registro (nada empezado):
  vista **Start** — en Respond, qué hay para responder (`ActionClassifier.newFeedback` y la lista de comentarios si ya
  se leyeron; si no, el resumen "N new comments from X") y `Button("Start Respond")` → `model.startRespond(item)`; en
  Fix CI, los checks que fallan (los del snapshot, `CIChecks`) y `Button("Start Fix CI")` → `model.startCIFix(item)`;
  los dos con la razón de `respondUnavailableReason`/`ciFixUnavailableReason`. Con registro de **otro** modo (Respond
  abierto y se mira Fix CI, o al revés): el mensaje de `respondSlotConflictReason` y un botón que lleva a la otra
  pestaña.
- [ ] **Step 2: Con tarea**, de arriba a abajo (todo con piezas que ya existen en el archivo):
  - **Cabecera** (`RespondHeader`): estado ("Changes requested by ana" / "N checks failed").
  - **Tarjeta de progreso**: título, worktree (`draft.worktree.path` abreviado con `~`), "tiempo · costo"
    (`RespondStageTimeline` + `UsageFormat.cost(record.usage)`), y las tres etapas de
    `timeline.stages(phase:runningTests:testsRan:)` con ícono por estado (círculo vacío, spinner violeta, check verde,
    x roja), subtítulo (Analyzing: "N comments" o "N checks"; Implementing: "Fix i of n" de `.implementing(done:total:)`
    o "N commits"; Running tests: el `testCommand` o "Passed"/"Failed") y tiempo `ClaudeTasksSidebar.clock`.
    `AppModel` guarda `private(set) var respondTimelines: [String: RespondStageTimeline]` y lo actualiza con un
    `sink` sobre `respond.$phases` y `respond.$runningTests` (como los `remoteObservers`) que llama a
    `timeline.note(phase:runningTests:at: Date())` para cada PR cuya fase cambió; se borra en `dismissRespond`.
  - En Fix CI, la lista de checks (`CIChecksSection`): cada uno "fails on GitHub" y, si corrieron los tests del repo,
    su resultado local (ver M.9: no hay resultado local por check).
  - La etapa de elegir (`choosing`) sigue igual mientras la fase es `.ready` en Respond.
  - **Segmentado `Diff · Tests · Log`** (`Picker(.segmented)`), con chips de archivos (los de `result.diffStat`;
    clic filtra el diff a ese archivo con `DiffTextView` sobre el fragmento del archivo). Diff: el de hoy
    (`fullDiffSection`); mientras `.implementing`, en lugar del diff, "Claude is editing…" con spinner violeta y "Fix i
    of n" (no hay diff en vivo). Tests: `TestsSection`. Log: las últimas 400 líneas del log de Claude
    (`respondHistory.logURL(for: draft.id)`) en un `DiffTextView` sin colores y "Open Log".
  - **Barra inferior**: Undo (la del chat: `ChatUndo.perform(chat)`, ver Step 3; deshabilitado sin
    `chat.session.undoableMessageID`), **Stop** (`⌘.`, solo mientras corre; pregunta como `CancellablePill` y llama a
    `model.cancelRespond(prID:)`) o **Discard** (`model.confirmDismissRespond(prID:)`), texto de ayuda (el de
    `respondPushGate`: "Tests run before pushing", "Tests failed", etc.) y **Push & Reply** (Respond) / **Push** (Fix
    CI) con `⌘↩`, habilitado según `respondPushGate` como hoy (ver M.9). `Stop`: `.keyboardShortcut(".",
    modifiers: .command)` en lugar de `.cancelAction`.
- [ ] **Step 3: `ChatUndo`.** Mover `ChatPanel.undo(_:)` a `enum ChatUndo { @MainActor static func perform(_ chat:
  ChatCoordinator) }` (deshace `chat.session.undoableMessageID` con la misma confirmación) en `Chat/ChatPanel.swift`;
  `ChatPanel` lo usa con el id de la tarjeta.
- [ ] **Step 4: Modo foco.** En `PRDetailView`:

```swift
    /// Claude trabaja en Respond o Fix CI del PR que se ve (spec M.1 "Modo foco").
    private func claudeWorking(_ tab: PRTab) -> Bool {
        (tab == .respond || tab == .fixCI) && (respond.phases[prID]?.isActive == true || respond.runningTests.contains(prID))
    }
    // en body, sobre el pane:
    .onChange(of: claudeWorking(tab), initial: true) { _, working in detail.focus.setClaudeWorking(working) }
```

  `MainWindow` ya oculta la lista con `detail.focus.isFocused` (Task 5); animar con `.animation(.easeInOut(duration:
  0.2), value: detail.focus.isFocused)`.
- [ ] **Step 5: Enrutar.** `openRespond(prID:)` → `navigate(to: .pr(prID: prID, tab: respond.mode(of: prID) == .ciFix ?
  .fixCI : .respond))`; `openRespondFromNotification` igual que hoy (si no hay registro, History). `dismissRespond`
  sin `WindowPresenter.close`; borrar `respondWindowID` y `respondWindowTitle` (si nadie más lo usa; `prbar` no).
  El "Open New Analysis" de la etapa `superseded` ya no hace falta (el pane siempre sigue el registro actual):
  `RespondPane` toma el draft de `respond.records[prID]` y se re-crea con `.id(draft.id)`. Borrar `LegacyPaneButton`.
- [ ] **Step 6: Capturas:** `respond-choose`, `respond-ready-to-push`, `respond-chat`, `ci-fix-ready-to-push` →
  `main-respond-choose`, `main-respond-focus` (implementando, Step 7), `main-fix-ci-ready` (Fix CI listo para pushear).
- [ ] **Step 7: Snapshot de modo foco.** `SnapshotRespondPipeline` suma `holdsImplementation: Bool = false`: con `true`,
  `implement` informa `onProgress(1, 3)` y se queda esperando hasta que lo cancelen (`try await
  Task.sleep(for: .seconds(3600))`). El modelo `respond-focus` implementa el draft de `fixtures.csvDraft` y espera
  `.implementing`.
  **Hecho (implementación):** `RespondPane(model:prID:mode:showTab:)` (`mode: RespondMode`; `showTab` lleva a la otra
  pestaña) elige entre `RespondStartView` (sin corrida; con el error si falló el análisis), `RespondAnalyzingView`
  (analizando: todavía no hay draft ni registro), `RespondOtherRunView` (corrida del otro modo) y `RespondRunView` (lo
  que era `RespondWindow`, con `.id(draft.id)`). La tarjeta es `RespondProgressCard` y lleva el worktree (salió de la
  cabecera). Los chips, el fragmento de un archivo y la cola del log salen de `DiffFiles` (Core, con tests). El reloj de
  etapas se reinicia con una corrida nueva (no con "Queued to post…"). El modo foco no se apaga en `onDisappear` (el
  orden contra el `onAppear` del PR siguiente no está garantizado): el `onChange(initial:)` del PR nuevo lo pone.
  `ChatUndo.perform(_:messageID:)`. `respondWindowTitle` se borró. `CIChecksSection(localTests:)` dice "Fails on GitHub
  → passes/fails locally". El botón de Respond dice "Push & Reply".
- [ ] **Step 8:** Paridad UI (Start Respond → `.cli(["respond"])`, Start Fix CI → `.cli(["ci fix"])`, Stop →
  `.cli(["respond cancel", "ci cancel"])`, Discard → `.cli(["respond dismiss"])`, Push/Push & Reply → `.cli(["respond
  push", "ci push"])`, Undo → `.cli(["chat"])` con `// /undo`, el segmentado → `.viewOnly`; usar las rutas que existan
  en `CLIRouter.allPaths`). `swift run PRBarTests`. **Commit** `"Move Respond and Fix CI into the main window with focus
  mode"`.

---

### Task 9: History

**Files:** `git mv Sources/PRBar/Review/HistoryWindow.swift Sources/PRBar/Review/HistoryPane.swift`; modify
`Main/MainWindow.swift`, `AppModel.swift` (`openHistory`, `historySelectionRequest`), snapshots,
`UIActionInventory.swift`.

Layout: spec M.1 "History"; boceto `MacHistory.dc.html`.

- [ ] **Step 1:** `HistoryPane(model:state:)` se divide en `HistoryListPane` (columna de la lista, en el lugar de
  `PRListPane`) y `HistoryDetailPane` (detalle). Lista: `DayGrouping.group(filtered, date: \.startedAt, now: Date())`
  (borra `HistoryGroup`); filtro de la toolbar `state.historyFilter` (All · Reviews · Responds · Merges, en
  `.principal` como segmentado; Responds incluye Fix CI); filas con chip de tipo (Review `Theme.violet`, Respond
  `Theme.orange`, Fix CI `Theme.red`, Merge `Theme.accent`), `repo#N`, hora (`ClockTime.hhmm`), `iphone` si el
  registro tiene `requestedOnPhone == true`, título y resultado (lo que hoy dice `HistoryRow`). Selección:
  `Binding(get: { state.nav.place.historyRecordID }, set: { state.select(historyRecord: $0) })`. El `Picker` de repo
  pasa al menú contextual de la lista o se va (la búsqueda por repo la cubre; ver M.9). Detalle: los de hoy
  (`HistoryDetailView`, `RespondHistoryDetailView`, `MergeHistoryDetailView`) con la cabecera del boceto y una barra
  inferior **View Claude Log** (abre el `logURL`) · **Open on GitHub** (`record.url`/`draft.url`). "Open to Post" y
  "Show Response" siguen (llaman a `reopenFromHistory` y `openRespond`, que navegan).
- [ ] **Step 2:** `openHistory(selecting:)` → `navigate(to: .history(recordID: recordID))`. Borrar
  `historySelectionRequest`, `requestHistorySelection`, `consumeHistorySelection` y `HistoryWindow.applySelectionRequest`
  (el registro está en `nav.place`). `openHistory(id:)` de los comandos sin cambios (llama a `openHistory(selecting:)`).
  `MainWindow.content`: `.history` → `HStack { HistoryListPane; Divider(); HistoryDetailPane }`.
- [ ] **Step 3:** `HistorySearch.matches` pasa a `ListSearch.matches(fields: [record.title, record.repo.fullName,
  "\(record.repo.name)#\(record.number)"], number: record.number, query:)` (el campo de búsqueda llega en la Task 18;
  hasta entonces `query` es `state.search`, vacío).
  **Hecho (implementación):** los registros viven en `HistoryEntries` (`MainWindowState.history`, lo leen lista,
  detalle y el subtítulo "N records"; se recarga con `historyRevision`). `HistoryEntry.matches(_ filter:)` y
  `matches(query:)` (con `ListSearch`). Las pestañas de la toolbar son `HistoryFilterBar` (en `PRTabBar.swift`, el mismo
  aspecto que las del PR: un `Picker` segmentado en la toolbar no mostraba la elegida en las capturas). El `Picker` de
  repo se fue (decisión para M.9: la búsqueda lo cubre). La barra inferior es `HistoryDetailBar` (View Claude Log ·
  Open on GitHub + la acción del registro; Merge también la tiene). `navigate(to: .history(recordID:))` con un registro
  que el filtro o la búsqueda esconden los limpia. Sin registro elegido, la lista elige el primero.
- [ ] **Step 4:** Capturas `history`, `history-ci-fix` → `main-history` (con un registro elegido) y
  `main-history-ci-fix`. Paridad UI. **Commit** `"Move History into the main window"`.

---

### Task 10: Activity

**Files:** `git mv Sources/PRBar/Activity/ActivityWindow.swift Sources/PRBar/Activity/ActivityPane.swift`; modify
`AppModel+Resources.swift`, `Main/MainWindow.swift`, snapshots, `UIActionInventory.swift`.

Layout: spec M.1 "Activity"; boceto `MacActivity.dc.html`.

- [ ] **Step 1:** `ActivityPane(model:monitor:)`, vista completa sin lista (`MainWindow.content` `.activity` →
  `ActivityPane`). Sacar `size` y la toolbar propia (su Refresh pasa al grupo de la toolbar de la ventana mientras se
  ve Activity: el `.windowCommand(.refresh)` ya existe). El `WindowVisibilityTracker` sigue (la ventana principal puede
  estar tapada) y `onDisappear` sigue apagando el muestreo: así al cambiar de sección deja de muestrear.
- [ ] **Step 2: Reorganizar al boceto** con lo que hoy muestra:
  - **Cuatro tiles** (`StatTile`): CPU, Memory, Disk y **Claude** (costo del mes, `UsageFormat.cost`).
  - **Claude tasks** (tabla): tarea, PR (`ClaudeTasksSidebar.shortName`), worktree (`respond.records[prID]?.draft
    .worktree.path`; review: "—"), tiempo, costo (`model.liveClaudeUsage`), y **Stop** (`stopAction(for:)`) o el
    estado ("Ready to push", "Review ready"). Filas: las de `taskRows` (procesos vivos por `ProcessActivity`) más las
    `claudeTaskRows()` listas que no tienen proceso.
  - **Claude this month**: total estimado, barra y desglose Reviews · Fixes · Chat (lo de `claudeUsage` de hoy).
  - **Worktrees** (tabla, la de disco por repo): **Clean Up Finished** (el Clean Up de hoy, con su confirmación) y
    **Clean Up** por fila → `model.cleanup(olderThanDays: nil, confirmed: true, paths: [row.path])` después de
    `ConfirmAlert` ("Remove this worktree?").
- [ ] **Step 3:** `openActivityWindow()` → `navigate(to: .activity)` (el nombre queda: lo usan la notificación de disco y
  el popover). Borrar `activityWindowID`.
  **Hecho (implementación):** orden: tiles · Claude tasks · Claude this month · Worktrees · Recent tasks (la tabla de
  hoy, abajo para que Worktrees entre en 1280×800) · Disk (lo que no son worktrees, con el Clean Up general y "Also
  delete history and logs older than"). "Clean Up Finished…" limita el plan a los worktrees; Clean Up por fila solo en
  los terminados (`.orphan`) y con `paths: [row.path]`; `prbar cleanup` no acepta rutas (el mapeo dice eso). En una
  tarea lista, el estado es un link a su pestaña. El Refresh de la toolbar mide el disco en Activity y el subtítulo es
  `ActivityPane.subtitle` ("CPU x% · RAM y"; `MainWindow` observa `model.resources`).
- [ ] **Step 4:** Capturas `activity` → `main-activity` (1280×800). Paridad UI ("Clean Up" por fila → `.cli(["cleanup"])`
  con `// --path`, si `prbar cleanup` acepta rutas; si no, el mismo mapeo que el Clean Up general). **Commit**
  `"Move Activity into the main window"`.

---

### Task 11: Update como hoja

**Files:** `git mv Sources/PRBar/Update/UpdateWindow.swift Sources/PRBar/Update/UpdateSheet.swift`; modify
`AppModel+Updates.swift`, `AppModel.swift` (arranque con `.installed`), `Main/MainWindow.swift`, `Main/MainSidebar.swift`,
snapshots, `UIActionInventory.swift`.

- [ ] **Step 1:** `UpdateSheet(updates:mode:close:)` = `UpdateWindow` renombrado (mismo contenido y tamaño fijo);
  `close` hace `model.main.updateSheet = nil`. En `MainWindow`: `.sheet(item: $state.updateSheet) { mode in
  UpdateSheet(updates: model.updates, mode: mode) { state.updateSheet = nil } }`.
- [ ] **Step 2:** `openUpdateWindow(_ mode:)`: sin modo ni versión ofrecida → `openSettings()` (como hoy); si no,
  `main.updateSheet = mode` y `openMainWindow()` (abre la ventana si estaba cerrada). Borrar `updateWindowID`.
  `checkForUpdatesFromMenu` y el arranque (`openUpdateWindow(.installed(...))`) no cambian.
- [ ] **Step 3: Aviso en la barra lateral** (spec M.1 "Pie"): si `model.updates.available` → "PRBar X available" ·
  botón "What's new" (abre la hoja) · botón "Install" (abre la hoja; ver M.9). Mientras instala, el progreso compacto
  de `UpdateButton`.
- [ ] **Step 4:** Captura `update` → `main-update-sheet` (ventana principal con la hoja). Paridad UI (los botones de la
  hoja cambian de archivo; "What's new"/"Install" → `.cli(["update"])`). **Commit** `"Show the update as a sheet on the
  main window"`.

---

### Task 12: Popover

**Files:** `Popover/PopoverView.swift`, `Popover/PRRowView.swift`, `Popover/PRRowAccessory.swift`,
`AppModel+Popover.swift`, `Popover/StatusItemController.swift`, `Popover/ResourceFooter.swift`, snapshots,
`UIActionInventory.swift`.

Layout: spec M.3; boceto `MacPopover.dc.html`.

- [ ] **Step 1: Cabecera:** "PRBar · updated N min ago" (el subtítulo de hoy) y tres botones: Open PRBar window
  (`macwindow` → `model.openMainWindow()`), Refresh, Settings (`gearshape` → `model.openSettings()`; ya no es menú).
  El botón Update de la cabecera se va (pasa al pie).
- [ ] **Step 2:** Selector To Review · N / My PRs · N sin cambios.
- [ ] **Step 3: Franja de Claude** debajo del selector si `ClaudeTasksSidebar.popoverStrip(rows)` no es nil: botón de
  ancho completo con el texto y `chevron.right` → `model.navigate(to: .pr(prID: rows[0].prID, tab: rows[0].tab))`.
  Necesita refrescarse con las colas: observar `model.reviews` y `model.respond` (ya los recibe `PRRowView`).
- [ ] **Step 4: Filas.** El botón de la fila hace `model.navigate(to: .pr(prID: item.id, tab: nil))` (ya no abre
  GitHub; "Open on GitHub" queda en el menú contextual) y su `accessibilityHint` pasa a "Opens the PR in PRBar". ↩ en el
  popover: `openPRFromPopover` → `navigate(to: .pr(prID:, tab: nil))`. Pills (`AppModel.rowActions`): `open` →
  `navigate` a la pestaña de la acción; `start`/`retry` → la acción de hoy **y** `navigate` a su pestaña (spec M.3);
  `cancel`/`dismiss` sin cambios. Como `navigate` cierra el popover (`closePopover`), "El popover se cierra al abrir la
  ventana" sale solo. Ojo: `PRListRow` usa los mismos `rowActions` — en la ventana principal navegar al mismo PR es
  inocuo.
- [ ] **Step 5: Pie:** la línea de recursos (`ResourceFooter`: CPU · RAM · worktrees · costo del mes; sumar worktrees
  (`monitor.disk` por categoría) y costo del mes (`model.usageLedger`) si no están; clic → `openActivityWindow()`);
  aviso de actualización con botón **Update** (`UpdateButton` → `openUpdateWindow()`); **Open PRBar ⌘0**
  (`.keyboardShortcut("0", modifiers: .command)`) y **Settings… ⌘,**. Los atajos invisibles (`keyboardShortcuts`):
  sacar ⌘Y, sumar ⌘0; quedan ⌘, ⌘Q ⌘1 ⌘2. Borrar el botón provisorio de la Task 5 y el menú ⚙︎; **Quit PRBar ⌘Q** se queda como ítem del pie (pedido del
  usuario, decisión 11).
- [ ] **Step 6:** Capturas `popover`, `popover-mine`, `popover-update`, `popover-empty*`, `popover-mine-ci-fix` (mismos
  nombres, contenido nuevo); la de `popover` ya tiene una review corriendo → muestra la franja. Paridad UI ("Open
  PRBar" → `.viewOnly("opens the main window")`; "History…" deja de existir). **Commit** `"Open PRs from the popover
  in the main window"`.

---

### Task 13: Notificaciones → destino; pedidos del iPhone

**Files:** `NotificationDelivery.swift`, `AppModel.swift`, `AppModel+Navigation.swift`, `AppModel+Merge.swift`,
`AppModel+Popover.swift`.

- [ ] **Step 1:** `NotificationDelivery`: los seis callbacks (`onOpenReview`, `onOpenRespond`, `onOpenUpdate`,
  `onOpenMerge`, `onSelectPR`, `onOpenActivity`) se reemplazan por `var onOpen: ((NotificationTarget) -> Void)?`. En
  `didReceive`: `let info = userInfo.reduce(into: [String: String]()) { if let k = $1.key as? String, let v =
  $1.value as? String { $0[k] = v } }` y `NotificationRoute.target(userInfo: info)`; `.url` se abre con
  `NSWorkspace` como hoy.
- [ ] **Step 2:** `AppModel.openNotificationTarget(_:)` en `AppModel+Navigation.swift`:

```swift
    func openNotificationTarget(_ target: NotificationTarget) {
        switch target {
        case .updateSheet:
            openUpdateWindow()
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .destination(.pr(let prID, let tab)) where currentItem(prID) == nil:
            // El PR ya no está (se mergeó o cerró): lo de hoy — Respond → su registro en History; Merge → GitHub;
            // Review lista → la pestaña igual (la review sigue en la cola).
            if tab == .respond || tab == .fixCI, respond.records[prID] == nil {
                openHistory(selecting: respondHistory.all().first { $0.draft.prID == prID }?.id)
            } else if tab == .merge, let url = PRReference.githubURL(prID: prID) {
                NSWorkspace.shared.open(url)
            } else {
                navigate(to: .pr(prID: prID, tab: tab))
            }
        case .destination(let destination):
            navigate(to: destination)
        }
    }
```

  Cablear `notifications?.onOpen = { [weak self] in self?.openNotificationTarget($0) }`. Borrar
  `openFromNotification`, `openRespondFromNotification`, `openMergeFromNotification`, `selectTab(forNotificationPR:)`
  (y `PopoverTabState.selectForNextOpening` con sus tests si quedan sin uso: `grep -rn selectForNextOpening Sources`).
- [ ] **Step 3: Pedidos del iPhone** (spec M.4): `navigate(to:)` ya los ignora (Task 5). Grabar el origen: `startReview`
  (Task 5), `RespondQueue.analyze` (Task 4), y en `AppModel.merge(_:method:)` `phoneMerges.insert(item.id)` si
  `CommandOrigin.current.isPhone` (y `remove` si no); `recordMergeAttempt` pone `session.record.requestedOnPhone =
  phoneMerges.contains(item.id) ? true : nil`. Revisar con `grep -n "func " Sources/PRBar/AppModel+Commands.swift` que
  ningún comando permitido al teléfono (`RemotePolicy` `.allowed`/`.gated`) llame a `navigate`, `open*` o
  `requestMerge`; si alguno lo hace, cambiarlo a la acción sin navegación.
- [ ] **Step 4:** Test de humo manual en la Task 21 (cada tipo de notificación). `swift build --product PRBar`,
  `swift run PRBarTests`. **Commit** `"Open each notification on its PR tab"`.

---

### Task 14: Ventana de PR (⇧⌘O)

**Files:** Create `Main/PRWindow.swift`; modify `AppModel+Navigation.swift`, `Main/MainWindow.swift`,
`Main/PRListPane.swift`, `AppModel+Merge.swift`.

- [ ] **Step 1:**

```swift
// Sources/PRBar/Main/PRWindow.swift
/// Una ventana con solo el detalle de un PR (spec M.2): sus pestañas y su chat, sin barra lateral ni lista.
struct PRWindow: View {
    static let size = NSSize(width: 900, height: 760)
    static let minSize = NSSize(width: 640, height: 520)
    @ObservedObject var model: AppModel
    @StateObject private var detail = PRDetailState()
    let prID: String

    var body: some View {
        PRDetailView(model: model, prID: prID, detail: detail)
            .navigationTitle(ClaudeTasksSidebar.shortName(prID))
            .navigationSubtitle(model.currentItem(prID)?.pr.title ?? "")
            .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
    }
}

// AppModel+Navigation.swift
    static func prWindowID(_ prID: String) -> String { "pr-\(prID)" }

    /// ⇧⌘O, doble clic en una fila, el botón de la toolbar. Una por PR; si ya hay, al frente.
    func openPRWindow(prID: String, tab: PRTab? = nil) {
        closePopover?()
        if let tab { main.choose(tab, for: prID) }
        WindowPresenter.shared.show(
            id: Self.prWindowID(prID), title: ClaudeTasksSidebar.shortName(prID), size: PRWindow.size,
            options: WindowOptions(sharedFrameKey: "PRWindowFrame", tabbingIdentifier: "PRBar.pr", bridgesToolbar: true,
                                   toolbarStyle: .unified, minContentSize: PRWindow.minSize),
            contentID: prID
        ) {
            PRWindow(model: self, prID: prID)
        }
    }
```

  `PRDetailView` en la ventana de PR no oculta ninguna lista (no hay): el modo foco solo abre el chat.
- [ ] **Step 2:** Cablear: botón Open in New Window de la toolbar (con PR elegido), doble clic de `PRListPane`
  (`primaryAction`), y `mergeFinished` cierra `prWindowID(item.id)`. El menú (⇧⌘O) en la Task 16.
- [ ] **Step 3:** Captura `pr-window` (PR propio en Merge, 900×760). Paridad UI. **Commit** `"Add PR windows"`.

---

### Task 15: Dock, "Always show in Dock" y reabrir

**Files:** `Sources/PRBarCore/Config.swift`, `CommandActions.swift`, `CommandDispatcher.swift`,
`Sources/PRBarWire/AppCommand.swift`, `Sources/PRBarRemoteKit/RemotePolicy.swift`,
`Sources/PRBarCLIKit/ConfigCommands.swift`, `CLIRouter.swift`, `Sources/PRBar/AppModel+Settings.swift`,
`Settings/GeneralTab.swift`, `WindowPresenter.swift`, `PRBarApp.swift`; tests `ConfigTests`, `CLIParsingTests`,
`CommandDispatcherTests`, `FakeActions`, `UIActionInventory`; `docs/cli.md`.

- [ ] **Step 1: Tests que fallan.**
  - `ConfigTests`: `AppConfig` sin `alwaysShowInDock` decodifica `false`; con `true` hace ida y vuelta.
  - `CLIParsingTests`: `try expectEqual(try parsed(["config", "set", "always-show-in-dock", "on"]),
    .setAlwaysShowInDock(enabled: true))` y `off` → `false`; un valor inválido falla con "always-show-in-dock takes on or
    off.".
  - `CommandDispatcherTests`: sumar `(.setAlwaysShowInDock(enabled: true), "configSetAlwaysShowInDock")` a la tabla.
  - `RemotePolicyTests` (si recorre todos los nombres): `.setAlwaysShowInDock` es `.denied`.
- [ ] **Step 2: Implementar** igual que `setLaunchAtLogin`: `AppConfig.alwaysShowInDock = false` (`CodingKeys` +
  `decodeIfPresent ?? false`); `AppCommand.setAlwaysShowInDock(enabled: Bool)` y su `Name`; `CommandActions.
  configSetAlwaysShowInDock(enabled:) throws`; el `case` del dispatcher; `FakeActions` (`try
  record("configSetAlwaysShowInDock \(enabled)")`); `ConfigKey.alwaysShowInDock = "always-show-in-dock"` en
  `ConfigCommands` (y en el `discussion`); `CLIRouter` "config set" suma `.setAlwaysShowInDock`; `RemotePolicy` en la
  lista de denegados. `CommandProtocol.version` no cambia (comando nuevo solo de la Mac, denegado al teléfono).
- [ ] **Step 3: App.** `AppModel.setAlwaysShowInDock(_:)` → `updateConfig(refresh: false) { $0.alwaysShowInDock = on }` y
  `WindowPresenter.shared.refreshActivationPolicy()`; `configSetAlwaysShowInDock` la llama. `GeneralTab`, en la
  primera sección debajo de "Open at login": `Toggle("Always show in Dock", isOn: …)` (apagado por defecto).
- [ ] **Step 4: `WindowPresenter`:** `var alwaysShowInDock: () -> Bool = { false }` (lo asigna `AppModel` en su `init`
  con servicios); `updateActivationPolicy()` pasa a `func refreshActivationPolicy()` (interna) y usa:

```swift
    func refreshActivationPolicy() {
        let current: DockPolicy.Policy = NSApp.activationPolicy() == .regular ? .regular : .accessory
        switch DockPolicy.policy(openWindows: windows.count, alwaysShowInDock: alwaysShowInDock(),
                                 otherAppFullScreen: SpaceContext.otherAppIsFullScreen(), current: current) {
        case .regular?: NSApp.setActivationPolicy(.regular)
        case .accessory?: NSApp.setActivationPolicy(.accessory)
        case nil: break
        }
    }
```

  `AppDelegate.applicationDidFinishLaunching` la llama una vez (con el interruptor prendido, el ícono aparece al
  arrancar). `bringToFront` sigue igual (`promotesToRegular`).
- [ ] **Step 5: Reabrir** (spec M.5): en `AppDelegate`:

```swift
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model?.openMainWindow() }
        return true
    }
```

- [ ] **Step 6:** `docs/cli.md` (`config set`: `always-show-in-dock on|off`). `swift run PRBarTests config`, `cli`,
  `dispatcher`, `"paridad UI"` (Toggle "Always show in Dock" → `.cli(["config set"])`) y la suite. Captura
  `settings-general`. **Commit** `"Add Always show in Dock and reopen the main window from the Dock"`.

---

### Task 16: Menú y atajos

**Files:** `AppMenu.swift`, `Components/WindowCommands.swift`, `WindowPresenter.swift`, `AppModel.swift`,
`Main/MainWindow.swift`, `Main/PRDetailView.swift`, panes (registros de comandos), `Sources/PRBarCore/
KeyboardShortcutList.swift`, `Sources/PRBarTests/KeyboardShortcutListTests.swift`, `UIActionInventory.swift`,
`Sources/PRBarCLIKit/StatusCommands.swift` (texto "⌘Y").

Spec M.6.

- [ ] **Step 1: Test que falla** (`KeyboardShortcutListTests`):

```swift
        TestCase("atajos: la lista de Help tiene los de la ventana principal y los del popover, sin ⌘Y") {
            let keys = KeyboardShortcutList.groups.flatMap(\.shortcuts).map(\.keys)
            for expected in ["⌘0", "⌘1 · ⌘2 · ⌘3 · ⌘4", "⌥⌘1–3", "↑ ↓", "↩", "⌘↩", "⇧⌘M", "⌘.", "⌘Z", "⌥⌘I", "⌃⌘S",
                             "⇧⌘O", "⌘R", "⌘F", "⌘[", "⌘,", "⌘Q", "esc", "⇧↩ or ⌥↩"] {
                try expect(keys.contains(expected), "falta \(expected)")
            }
            try expect(!keys.contains("⌘Y") && !keys.contains("⇧⌘C"))
        },
```

  (reemplaza el caso de hoy). `KeyboardShortcutList.groups`: "PRBar window" (las filas de la tabla M.6 con sus
  textos), "Menu bar popover" (↑ ↓, ↩ "Open the selected PR in PRBar", ⌘1 / ⌘2, ⌘R, ⌘0 "Open PRBar", ⌘, , ⌘Q, esc),
  "Chat" (↩ Send, ⇧↩ or ⌥↩ New line, ⌘↩ "Send (the tab's action waits while you type in the chat)").
- [ ] **Step 2: `WindowCommand`** suma: `.find`, `.back`, `.openInNewWindow`, `.tab(Int)`, `.merge`, `.stopClaude`,
  `.undoClaude`; `Handler` suma `title: String?` (para "Review"/"Details" en los ítems ⌥⌘N). `WindowCommandCenter`:
  `@objc` para cada uno y en `validateMenuItem` su estado/título. `find(_:)` sin handler busca el
  `NSSearchToolbarItem` de la ventana key y llama a `beginSearchInteraction()`. **Undo**:

```swift
    /// Edit › Undo (⌘Z): en un texto editable es el deshacer del texto; si no, deshace el último cambio de Claude del
    /// chat de la pestaña (spec M.6).
    @objc func undo(_ sender: Any?) {
        if (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true || handler(.undoClaude)?.enabled != true {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
        } else {
            handler(.undoClaude)?.perform()
        }
    }
```

  y Edit › Undo pasa a `target: WindowCommandCenter.shared, action: #selector(undo(_:))` (título "Undo Claude’s
  Change" cuando aplica).
- [ ] **Step 3: `AppMenu`** (las acciones nuevas entran por `AppMenu.Actions`: `navigate: (MainDestination) -> Void`,
  `openMainWindow: () -> Void`; `openHistory`/`openActivity` se van):
  - **View**: Show/Hide Sidebar ⌃⌘S (`#selector(NSSplitViewController.toggleSidebar(_:))`, target nil) · Show Chat ⌥⌘I
    (`toggleChat`, antes ⇧⌘C) · — · To Review ⌘1 · My PRs ⌘2 · History ⌘3 · Activity ⌘4 (ClosureMenuItem →
    `navigate`) · — · Back ⌘[ · Refresh ⌘R · Find ⌘F · — · Enter Full Screen ⌃⌘F.
  - **Pull Request** (menú nuevo entre View y Window): Open in New Window ⇧⌘O · Open on GitHub · — · tres ítems ⌥⌘1, ⌥⌘2,
    ⌥⌘3 (`.tab(n)`, retitulados con `PRTab.title` o "Tab n" deshabilitado) · — · Merge… ⇧⌘M (`.merge`) · Stop Claude ⌘.
    (`.stopClaude`). ⌘↩ **no** va al menú: un ítem de menú se lo quitaría al chat (`PRBarWindow.performKeyEquivalent`
    devuelve false para que el texto lo reciba y el menú lo tomaría); sigue como `keyboardShortcut` de cada botón.
  - **Window**: … · PRBar ⌘0 (`openMainWindow`) · — · Bring All to Front. Sale "History ⌘Y" y "PRBar Activity".
- [ ] **Step 4: Registros.** `MainWindow`: `.windowCommand(.back, enabled: state.nav.back.canGoBack) { state.goBack() }`,
  `.openInNewWindow` (con PR elegido). `PRDetailView`: `.tab(1...3)` desde `PRTabs.tab(atShortcut:_:)`; `.undoClaude`
  con el chat de la pestaña (`ChatUndo.perform`), habilitado con `undoableMessageID != nil && canUndo`.
  `MergeDetailPane`: `.merge` (lo que hace el botón; el botón conserva su `keyboardShortcut` ⇧⌘M solo si el menú no lo
  atiende: dejar uno de los dos, el del menú). `RespondPane`/`ReviewPane` (progreso): `.stopClaude`.
- [ ] **Step 5:** `StatusCommands.swift`: `"Open the History window (⌘Y)…"` → `"Open History in PRBar's window (⌘3),
  optionally on a record."`. Comentarios de `WindowPresenter` que nombran ⌘Y. Paridad UI (ítems nuevos de `AppMenu`:
  navegación → `.viewOnly`; Merge… → `.cli(["merge"])`; Stop Claude → `.cli(["review cancel", "respond cancel", "ci
  cancel"])`; Undo → `.viewOnly("text editing")` como hoy, con el comentario `// también /undo del chat`).
- [ ] **Step 6:** `swift run PRBarTests atajos`, `"paridad UI"`, suite. **Commit** `"Add the main window's menus and
  shortcuts"`.

---

### Task 17: Links `prbar://`

**Files:** `Resources/Info.plist`, `PRBarApp.swift`, `AppModel+Navigation.swift`; test en `ScriptTests.swift` o un caso
en `PRBarURLTests`.

- [ ] **Step 1: Test que falla** (en `PRBarURLTests`, usa `InfoPlist.read()` de `TestKit.swift`):

```swift
        TestCase("prbar://: Info.plist registra el esquema") {
            let plist = try InfoPlist.read()
            let types = try expectSome(plist["CFBundleURLTypes"] as? [[String: Any]])
            try expect(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(PRBarURL.scheme) == true })
        },
```

- [ ] **Step 2:** `Info.plist`:

```xml
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.federico.prbar</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>prbar</string>
			</array>
		</dict>
	</array>
```

- [ ] **Step 3:** `AppDelegate`:

```swift
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { model?.openURL(url) }
    }
```

  y en `AppModel+Navigation.swift`: `func openURL(_ url: URL) { if let d = PRBarURL.destination(url) { navigate(to: d) }
  else { AppLog.write("Couldn't understand a prbar:// link."); openMainWindow() } }` (sin loguear el link: puede tener
  nombres de repos privados; el log solo dice que no se entendió).
- [ ] **Step 4:** `Scripts/bundle.sh` y probar a mano `open "prbar://pr/<owner>/<repo>/<n>/merge"` (QA). **Commit**
  `"Open prbar:// links in the main window"`.

---

### Task 18: Búsqueda (⌘F)

**Files:** `Main/MainWindow.swift`, `Main/PRListPane.swift`, `Review/HistoryPane.swift`, `UIActionInventory.swift`.

- [ ] **Step 1:** `MainWindow`: `.searchable(text: $state.search, placement: .toolbar, prompt: "Search ⌘F")` solo en las
  secciones de PRs y en History (en Activity, sin campo). Ancho: `Theme.MainLayout.searchWidth` (si `.searchable` no
  deja fijarlo, aceptar el del sistema y anotarlo en M.9).
  **Nota (pulido después de la Task 7):** la toolbar de la ventana principal ya está en el orden del spec: Back ·
  título · pestañas del PR **centradas** (`.principal`, las pone `MainWindow` con `PRDetailToolbar.tabBar`, no
  `PRDetailView`) · grupo Refresh / Open in New Window / Open on GitHub / Chat (`.primaryAction`). El campo de búsqueda
  va **a la derecha de ese grupo** (hay un comentario en `MainWindow.toolbar` marcando el lugar); verificar con la
  captura que las pestañas siguen centradas al sumarlo.
- [ ] **Step 2:** `PRListPane` pasa `query: state.search` a `MainList.items`; con búsqueda, las secciones con resultados
  se muestran desplegadas aunque estén plegadas y, sin resultados, "No Results" (como History). `HistoryListPane`
  filtra con `ListSearch` (Task 9). ⌘F: el `find` de `WindowCommandCenter` (Task 16) enfoca el campo.
- [ ] **Step 3:** Paridad UI (el campo de búsqueda → `.viewOnly("filters the list")`). Captura `main-search` opcional.
  **Commit** `"Search the PR list and History"`.

---

### Task 19: Borrar lo que quedó de las ventanas viejas

- [ ] **Step 1:** `grep -rn "ReviewWindow\|RespondWindow\|MergeWindow\b\|HistoryWindow\|ActivityWindow\|UpdateWindow\b\|reviewWindowID\|respondWindowID\|mergeWindowID\|activityWindowID\|updateWindowID\|openMergeWindow\|historySelectionRequest\|WindowPresenter.shared.openHistory\|WindowPresenter.shared.openActivity" Sources docs/cli.md`
  y borrar o renombrar cada resto: las propiedades `openHistory`/`openActivity` de `WindowPresenter`; los
  `sharedFrameKey` viejos (`ReviewWindowFrame`, `RespondWindowFrame`, `MergeWindowFrame`) y los `autosaveName`
  (`HistoryWindow`, `ActivityWindow`, `UpdateWindow`) que ya nadie usa (las claves en `UserDefaults` del usuario quedan;
  no molestan); `Components/InspectorWindowSizing.swift` si ya no lo usa nadie (la ventana de PR puede usarlo:
  decidir según `grep`); el comentario de `WindowSpaces.Kind` (nombra Review/Respond/History/Activity/Update);
  `MergeWindowModel` se queda (es el modelo del detalle de merge, aunque el nombre diga "window": renombrarlo a
  `MergeDetailModel` solo si el cambio es mecánico).
- [ ] **Step 2:** `swift build --product PRBar && swift build --product PRBarCLI && swift build --product PRBarTests &&
  swift run PRBarTests`. Paridad UI ("YA NO EXISTE" → borrar entradas). **Commit** `"Remove the old window types"`.

---

### Task 20: Capturas

**Files:** `Sources/PRBar/Snapshots/SnapshotMode.swift`, `SnapshotFixtures.swift`, `SnapshotFakes.swift`,
`docs/screenshots/*`, `docs/screenshots/README.md`.

Spec M.8: la ventana principal en los ocho estados del boceto, claro y oscuro, y el popover nuevo.

- [ ] **Step 1:** Un helper `mainWindow(_ name: String, model: AppModel, size: NSSize = Theme.MainLayout.defaultSize,
  configure: (AppModel) -> Void)` que llama a `configure` (p. ej. `model.main.go(to: …, snapshot: model.prStore.snapshot)`)
  y después a `window(name, title: "PRBar", size:) { MainWindow(model: model) }`. `makeModel(_:snapshot:)` acepta
  `Snapshot?` (nil = sin `state.json`, para "cargando").
- [ ] **Step 2:** Los ocho (nombres finales):

| Captura | Estado |
|---|---|
| `main-review` | To Review con lista y un PR con review lista en Review |
| `main-respond-focus` | Respond implementando (modo foco: sin lista, chat abierto) |
| `main-fix-ci-ready` | Fix CI listo para pushear |
| `main-merge` | PR propio en Merge |
| `main-history` | History con un registro elegido |
| `main-activity` | Activity |
| `main-empty` | `caughtUpSnapshot`, ventana **960×600** |
| `main-loading` | sin snapshot (esqueleto y spinner en Refresh) |

  más los extra de las tasks (`main-review-chat`, `main-details`, `main-respond-choose`, `main-history-ci-fix`,
  `main-update-sheet`, `pr-window`) y los popovers. Borrar del modo de capturas las ventanas viejas que queden.
- [ ] **Step 3:** `Scripts/snapshots.sh` (sin argumentos: escribe en `docs/screenshots`); `git rm` de los PNG que ya no
  se generan (`review-window-*`, `review-chat-*`, `review-chat-rule-*`, `review-published-*`, `respond-*`,
  `ci-fix-ready-to-push-*`, `merge-window-*`, `merge-chat-*`, `history-*`, `activity-*`, `update-*` si cambia el nombre);
  `docs/screenshots/README.md` con la lista nueva. Mirar cada PNG con Read y compararlo con el boceto; anotar las
  diferencias que queden en la Task 21.
- [ ] **Step 4: Commit** `"Update the screenshots for the main window"`.

---

### Task 21: QA manual, docs y decisiones

- [ ] **Step 1:** `docs/qa/plan-21-checklist.md` (formato de `plan-18-checklist.md`), con `Scripts/bundle.sh` e
  instalando el `.app`:
  - **A. Ventana:** ⌘0 desde el popover y desde el menú; tamaño 1280×800 la primera vez, mínimo 960×600, el frame se
    recuerda; ⌘W la cierra y PRBar sigue en la barra de menú sin cancelar nada (una review corriendo sigue en el
    popover); reabrir conserva sección, PR, pestaña y Back.
  - **B. Barra lateral:** contadores; grupo Claude aparece con una review (spinner violeta, reloj), pasa a check verde
    al terminar, sale al publicar; fila de iPhone con un teléfono emparejado (punto verde en línea); aviso de update
    (con `prbar update --check` contra una versión falsa o el snapshot); engranaje → Settings.
  - **C. Lista:** secciones y plegado; ↑ ↓ ↩ (↩ en un PR para revisar arranca la review y queda en Review); doble clic
    abre la ventana de PR; vacío ("All caught up", "N drafts hidden · Show"); cargando al arrancar sin datos.
  - **D. Pestañas:** PR ajeno (Review · Details), PR propio con cambios pedidos (abre en Respond), con CI roto (Fix
    CI), sin nada (Merge; Respond y Fix CI deshabilitadas); indicadores; la pestaña se recuerda al volver al PR.
  - **E. Review / Merge / Respond / Fix CI** de punta a punta (publicar, mergear con ⇧⌘M, pushear con ⌘↩, Stop ⌘.,
    Discard, Undo ⌘Z fuera y dentro de un campo de texto), modo foco (la lista se oculta, el chat se abre; cerrar el chat
    a mano durante la tarea y ver que al terminar queda cerrado).
  - **F. Notificaciones** de cada tipo (nuevo PR, PR revisado con commits, feedback, review lista, review fallida →
    History, Respond listo, Fix CI listo, CI roto, aprobado, listo para mergear, update → hoja, disco → Activity): cada
    una abre su pestaña y cierra el popover.
  - **G. iPhone:** un `review` y un `ci fix` pedidos desde la web app no abren ni enfocan la ventana; aparecen en el
    grupo Claude con el ícono de iPhone; en History, el ícono en esos registros.
  - **H. Dock:** sin el interruptor, ícono solo con la ventana principal, una de PR o Settings abiertas; con "Always show
    in Dock", siempre (también recién arrancada); clic en el ícono sin ventanas abre la principal;
    `prbar config set always-show-in-dock on|off` (con `PRBAR_SOCKET` real de la app instalada) hace lo mismo.
  - **I. Pantalla completa:** con otra app en pantalla completa, ⌘0 desde la barra de menú muestra la ventana encima sin
    cambiar de Space; la ventana principal puede ir a pantalla completa (⌃⌘F).
  - **J. Ventana de PR:** ⇧⌘O, botón de la toolbar, doble clic; abrir el mismo PR la trae al frente; con "Prefer tabs:
    always" (Ajustes del Sistema) se agrupan como pestañas nativas; mergear desde ahí la cierra.
  - **K. Atajos:** toda la tabla M.6 (incluido ⌘↩ en el chat que envía el mensaje y no publica); ⌘Y ya no hace nada;
    Help › Keyboard Shortcuts.
  - **L. Links:** `open "prbar://pr/<o>/<r>/<n>/merge"`, `prbar://review`, `prbar://mine`, `prbar://history`,
    `prbar://activity`, y uno roto (`prbar://nope`) abre la ventana sin moverse.
  - **M. Búsqueda:** ⌘F, sin acentos ni mayúsculas, por rama y autor; en History.
  - **N. CLI:** `prbar open <pr> --review|--respond|--merge` y `prbar app history <id>` navegan en la ventana.
  - **O. ⌘Q** con una tarea corriendo y con un fix sin pushear: pregunta como antes.
  - **P. VoiceOver:** barra lateral (grupos, contadores, filas de Claude), lista (filas, secciones plegables),
    pestañas (elegida, deshabilitadas, "Claude is working").
- [ ] **Step 2: Docs.** `docs/cli.md`: la intro ("the Review, Respond and History windows" → "PRBar's window"),
  `prbar open` ("its window" → "its tab in PRBar's window"), `app history` (⌘3), `config set always-show-in-dock`;
  `docs/screenshots/README.md` (Task 20); `docs/iphone.md` si nombra ventanas de la Mac (`grep -n -i window
  docs/iphone.md`). Si existe un README en la raíz del repo, lo mismo.
- [ ] **Step 3: Decisiones en el spec.** Agregar al final del spec **"M.9 Decisiones de implementación (Plan 21)"** con
  las de la sección siguiente (y las que hayan salido al implementar), y si la Task 0 no pudo bajar los bocetos,
  decirlo.
- [ ] **Step 4: Commit** `"Add the plan 21 QA checklist and update the docs"`.

---

## Decisiones tomadas en este plan (van a M.9)

1. **Dos columnas nativas + lista propia** en vez de tres columnas de `NavigationSplitView`: es la única forma de que
   Activity ocupe todo el ancho al lado de la barra lateral y de que el modo foco oculte solo la lista (Task 5). Se ve
   igual que tres columnas.
2. **"CI Failing"** no existía como sección: son los PRs míos de categoría `.other` con CI roto (los que el popover
   pone en Waiting for Review). Un PR con feedback y CI roto queda en With Feedback.
3. **To Review** suma la sección callada **"Other"** (plegada) que tiene el popover: sin ella los borradores y los PRs
   sin acción desaparecerían de la ventana. El aviso del vacío "N drafts hidden · Show in Settings" no tiene a qué
   ajuste ir (no hay ajuste de borradores): dice "N drafts hidden · Show" y despliega "Other".
4. **Pestaña inicial** con una tarea abierta pero sin feedback ni CI roto: la de la tarea (el spec no lo dice).
5. **Details y el chat:** el inspector en Details muestra el chat de la review del PR (si hay); sin review, un texto.
6. **Merge:** "Delete branch after merge" y "Post in #canal" son filas informativas (el ajuste del repo
   `deleteBranchOnMerge` y el aviso automático de Slack): hacerlos interruptores cambiaría la lógica de merge, que M.7
   deja igual. Merge pasa de ⌘↩ a ⇧⌘M (la tabla M.6 deja ⌘↩ para Post/Push).
7. **Respond/Fix CI:** "Claude is editing" muestra el progreso (fix i de n) y no un diff en vivo (no existe); la lista
   de checks de Fix CI dice "falla en GitHub" y el resultado de los tests locales de la corrida (no hay resultado local
   por check); Push/Push & Reply se habilitan con la regla de hoy (`RespondPushGate`, que puede correr los tests antes de
   pushear) y no solo "cuando pasan los tests".
8. **⌘↩ no está en el menú** (lo tomaría antes que el chat); está en Help › Keyboard Shortcuts. ⌘Z es un ítem propio de
   Edit que decide entre el deshacer del texto y el de Claude.
9. **"Install" de la barra lateral** abre la hoja de Update (donde está la política con trabajos en curso), no instala
   directo.
10. **Back** guarda los lugares a los que se llegó con `navigate(to:)` (barra lateral, ⌘1–4, notificaciones, links,
    pills); elegir otra fila con ↑ ↓ no llena la pila.
11. **Popover:** el menú ⚙︎ desaparece (Settings es un botón). Por pedido del usuario el popover conserva un ítem
    **"Quit PRBar ⌘Q"** (en el pie, junto a Open PRBar y Settings…), además de ⌘Q en el menú de la app.
12. **Links:** además de `/<tab>`, se entiende el `?screen=` de los links del iPhone; `prbar://history/<uuid>` no se
    implementa.
13. **`prbar config set always-show-in-dock`**: el interruptor nuevo tiene su comando (regla de paridad), denegado al
    teléfono.

## Verificación final

```
swift build --product PRBar && swift build --product PRBarCLI && swift build --product PRBarTests
swift run PRBarTests
Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both
```

## Autorrevisión contra el spec

| Spec | Task |
|---|---|
| Decisiones 1–4 (ventana principal, sin Handoff, Settings aparte, Dock, ventanas de PR, notificación → pestaña, reusar componentes) | 5–15, 19 |
| M.1 Estructura (split, toolbar 52 pt, búsqueda 170 pt, 1280×800 / 960×600, autosave, instancia única, ⌘W, colores) | 5, 18 |
| M.1 Barra lateral (grupos, contadores, grupo Claude con iPhone, History/Activity, pie update/iPhone/engranaje, "tarea lista") | 3, 5, 11, 13 |
| M.1 Lista (secciones, plegado, fila ancha, pill, ↑↓↩, doble clic, vacío, cargando, sin selección, búsqueda) | 2, 5, 14, 18 |
| M.1 Pestañas (tabla, deshabilitadas, indicadores, recordada por PR) | 1, 3, 5 |
| M.1 Review | 6 |
| M.1 Details / Merge | 7 |
| M.1 Respond / Fix CI | 3 (etapas), 8 |
| M.1 Modo foco y chat (inspector 300 pt, ⌥⌘I, foco, Review/Merge con chat cerrado) | 3, 6, 8, 16 |
| M.1 History (días, chips, iPhone, pestañas All/Reviews/Responds/Merges, detalle, barra inferior) | 2, 4, 9 |
| M.1 Activity (tiles, Claude tasks, Claude this month, Worktrees con Clean Up) | 10 |
| M.2 Ventana de PR (⇧⌘O, `pr-<id>`, `PRBar.pr`, al frente) | 14, 16 |
| M.2 Settings + Always show in Dock | 15 |
| M.2 Update como hoja | 11 |
| M.3 Popover (cabecera, selector, franja Claude, fila/pill, pie, ⌘0, se cierra) | 12 |
| M.4 `MainDestination`/`PRTab`, `navigate(to:)`, Back ⌘[ (20) | 1, 5, 16 |
| M.4 `open*` como envoltorios | 6–11 |
| M.4 Notificaciones → destino | 4, 13 |
| M.4 Pedidos del iPhone (no navegan, `CommandOrigin` por tarea) | 4, 5, 13 |
| M.4 `prbar://` | 4, 17 |
| M.4 Lógica pura en Core con tests | 1–4 |
| M.5 Dock y activación, reabrir, WindowSpaces | 3, 15 |
| M.6 Atajos (toda la tabla, ⌘↩ en el chat, ⌘Y fuera) | 6, 7, 8, 12, 16 |
| M.7 Lo que no cambia (lógica, CLI, iPhone, confirmación al salir, drafts en el coordinador) | 6, 8, 13, 21 (QA O) |
| M.8 Tests (Core + Dock), snapshots 8 estados + popover, QA | 1–4, 20, 21 |
