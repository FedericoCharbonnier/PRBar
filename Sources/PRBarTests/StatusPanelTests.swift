import CoreGraphics
import PRBarCore

/// The menu bar panel: where it goes (`StatusPanelLayout`) and its keyboard (`PopoverKey`, `PopoverRowNavigation`).
enum StatusPanelTests {
    /// A 1512×982 display with a notch (37 pt menu bar) and the Dock at the bottom (70 pt).
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let visible = CGRect(x: 0, y: 70, width: 1512, height: 982 - 70 - 37)
    static let button = CGRect(x: 1200, y: 982 - 37, width: 40, height: 37)

    static let cases: [TestCase] = [
        TestCase("status panel: el borde de arriba va debajo del ícono, con la barra visible") {
            try expectEqual(StatusPanelLayout.top(buttonFrame: button, screenFrame: screen, menuBarHeight: 37),
                            982 - 37 - StatusPanelLayout.gap)
        },
        TestCase("status panel: con la barra escondida (o saliendo) el borde queda donde descansa la barra") {
            // The icon's window slid above the top of the screen.
            let hidden = button.offsetBy(dx: 0, dy: 40)
            try expectEqual(StatusPanelLayout.top(buttonFrame: hidden, screenFrame: screen, menuBarHeight: 37),
                            982 - 37 - StatusPanelLayout.gap)
            // Half way.
            let sliding = button.offsetBy(dx: 0, dy: 10)
            try expectEqual(StatusPanelLayout.top(buttonFrame: sliding, screenFrame: screen, menuBarHeight: 37),
                            982 - 37 - StatusPanelLayout.gap)
        },
        TestCase("status panel: la altura de la barra es la mayor entre grosor, notch y franja sobre el área visible") {
            try expectEqual(StatusPanelLayout.menuBarHeight(statusBarThickness: 24, safeAreaTop: 37, screenFrame: screen,
                                                            visibleFrame: visible), 37)
            // Hidden menu bar, no notch: the visible area reaches the top.
            let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            try expectEqual(StatusPanelLayout.menuBarHeight(statusBarThickness: 24, safeAreaTop: 0, screenFrame: full,
                                                            visibleFrame: full), 24)
            try expectEqual(StatusPanelLayout.menuBarHeight(statusBarThickness: 22, safeAreaTop: 0, screenFrame: full,
                                                            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)), 25)
        },
        TestCase("status panel: el alto máximo sigue a la pantalla (Dock incluido) y tiene un mínimo") {
            let top: CGFloat = 982 - 37 - 4
            try expectEqual(StatusPanelLayout.maxHeight(top: top, visibleFrame: visible), top - 70 - StatusPanelLayout.margin)
            let tiny = CGRect(x: 0, y: 900, width: 800, height: 40)
            try expectEqual(StatusPanelLayout.maxHeight(top: 940, visibleFrame: tiny), StatusPanelLayout.minimumHeight)
        },
        TestCase("status panel: el frame fija el borde de arriba, recorta la altura y centra bajo el ícono") {
            let top: CGFloat = 941
            let frame = StatusPanelLayout.frame(contentSize: CGSize(width: 380, height: 500), top: top, anchorX: 1220,
                                                visibleFrame: visible)
            try expectEqual(frame, CGRect(x: 1030, y: 441, width: 380, height: 500))
            // Taller than the screen allows: the top stays, the bottom stops above the Dock.
            let tall = StatusPanelLayout.frame(contentSize: CGSize(width: 380, height: 2000), top: top, anchorX: 1220,
                                               visibleFrame: visible)
            try expectEqual(tall.maxY, top)
            try expectEqual(tall.minY, 70 + StatusPanelLayout.margin)
            // A resize keeps the same top edge.
            let shorter = StatusPanelLayout.frame(contentSize: CGSize(width: 380, height: 220), top: top, anchorX: 1220,
                                                  visibleFrame: visible)
            try expectEqual(shorter.maxY, top)
        },
        TestCase("status panel: cerca del borde derecho o izquierdo queda adentro de la pantalla") {
            let right = StatusPanelLayout.frame(contentSize: CGSize(width: 380, height: 300), top: 941, anchorX: 1500,
                                                visibleFrame: visible)
            try expectEqual(right.maxX, 1512 - StatusPanelLayout.margin)
            let left = StatusPanelLayout.frame(contentSize: CGSize(width: 380, height: 300), top: 941, anchorX: 10,
                                               visibleFrame: visible)
            try expectEqual(left.minX, StatusPanelLayout.margin)
            // Second display to the left of the main one (negative x).
            let other = CGRect(x: -1440, y: 0, width: 1440, height: 875)
            let onOther = StatusPanelLayout.frame(contentSize: CGSize(width: 380, height: 300), top: 850, anchorX: -20,
                                                  visibleFrame: other)
            try expectEqual(onOther.maxX, -StatusPanelLayout.margin)
        },
        TestCase("status panel: si el ícono se mueve, solo vertical se queda, de costado lo sigue, de pantalla cierra") {
            let screens = [screen, CGRect(x: 1512, y: 0, width: 1920, height: 1080)]
            try expectEqual(StatusPanelLayout.buttonMove(from: button, to: button.offsetBy(dx: 0, dy: 40), screenFrames: screens), .keep)
            try expectEqual(StatusPanelLayout.buttonMove(from: button, to: button.offsetBy(dx: -12, dy: 0), screenFrames: screens), .follow)
            try expectEqual(StatusPanelLayout.buttonMove(from: button, to: button.offsetBy(dx: 900, dy: 98), screenFrames: screens), .close)
        },
        TestCase("popover keys: flechas, Return y Esc sin modificadores; el resto no") {
            try expectEqual(PopoverKey(keyCode: 126, hasModifiers: false), .up)
            try expectEqual(PopoverKey(keyCode: 125, hasModifiers: false), .down)
            try expectEqual(PopoverKey(keyCode: 36, hasModifiers: false), .open)
            try expectEqual(PopoverKey(keyCode: 76, hasModifiers: false), .open)
            try expectEqual(PopoverKey(keyCode: 53, hasModifiers: false), .close)
            try expectEqual(PopoverKey(keyCode: 125, hasModifiers: true), nil)
            try expectEqual(PopoverKey(keyCode: 36, hasModifiers: true), nil)
            try expectEqual(PopoverKey(keyCode: 0, hasModifiers: false), nil)
        },
        TestCase("popover keys: ↑/↓ recorren las filas y se detienen en los extremos") {
            let ids = ["a", "b", "c"]
            try expectEqual(PopoverRowNavigation.move(from: nil, in: ids, key: .down), "a")
            try expectEqual(PopoverRowNavigation.move(from: nil, in: ids, key: .up), "c")
            try expectEqual(PopoverRowNavigation.move(from: "a", in: ids, key: .down), "b")
            try expectEqual(PopoverRowNavigation.move(from: "c", in: ids, key: .down), "c")
            try expectEqual(PopoverRowNavigation.move(from: "a", in: ids, key: .up), "a")
            try expectEqual(PopoverRowNavigation.move(from: "gone", in: ids, key: .down), "a")
            try expectEqual(PopoverRowNavigation.move(from: "b", in: ids, key: .open), "b")
            try expectEqual(PopoverRowNavigation.move(from: "a", in: [], key: .down), nil)
        },
        TestCase("popover keys: la selección sobrevive a un refresco solo si su fila sigue") {
            try expectEqual(PopoverRowNavigation.keep("b", in: ["a", "b"]), "b")
            try expectEqual(PopoverRowNavigation.keep("b", in: ["a"]), nil)
            try expectEqual(PopoverRowNavigation.keep(nil, in: ["a"]), nil)
        },
        TestCase("quit: pregunta solo con trabajos corriendo y si lo pidió el usuario") {
            try expect(QuitConfirmation.shouldAsk(activeJobs: 2, programmatic: false))
            try expect(!QuitConfirmation.shouldAsk(activeJobs: 0, programmatic: false))
            try expect(!QuitConfirmation.shouldAsk(activeJobs: 3, programmatic: true))
            try expectEqual(QuitConfirmation.title(activeJobs: 1), "Quit PRBar while a job is running?")
            try expectEqual(QuitConfirmation.title(activeJobs: 3), "Quit PRBar while 3 jobs are running?")
        },
    ]
}
