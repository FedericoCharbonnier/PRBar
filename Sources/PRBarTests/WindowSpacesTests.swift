import CoreGraphics
import PRBarCore

/// PRBar's windows and Spaces (`WindowSpaces`) and growing a window for its chat (`InspectorSizing`).
enum WindowSpacesTests {
    static let cases: [TestCase] = [
        TestCase("windows: Settings/Activity/Update vienen al Space actual y se muestran sobre una app en pantalla completa") {
            try expectEqual(WindowSpaces.behavior(kind: .utility, overFullScreenApp: false),
                            .init(moveToActiveSpace: true, fullScreenAuxiliary: true, promotesToRegular: true))
            try expectEqual(WindowSpaces.behavior(kind: .utility, overFullScreenApp: true),
                            .init(moveToActiveSpace: true, fullScreenAuxiliary: true, promotesToRegular: false))
        },
        TestCase("windows: Review y compañía son normales (pantalla completa, pestañas) salvo sobre una app en pantalla completa") {
            try expectEqual(WindowSpaces.behavior(kind: .document, overFullScreenApp: false),
                            .init(moveToActiveSpace: false, fullScreenAuxiliary: false, promotesToRegular: true))
            try expectEqual(WindowSpaces.behavior(kind: .document, overFullScreenApp: true),
                            .init(moveToActiveSpace: true, fullScreenAuxiliary: true, promotesToRegular: false))
            // Already a tab or in full screen: left as it is.
            try expectEqual(WindowSpaces.behavior(kind: .document, overFullScreenApp: true, inTabsOrFullScreen: true),
                            .init(moveToActiveSpace: false, fullScreenAuxiliary: false, promotesToRegular: false))
        },
        TestCase("windows: una ventana que cubre una pantalla entera es pantalla completa; una maximizada no") {
            let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
            let side = WindowSpaces.cgFrame(CGRect(x: 1512, y: -98, width: 1920, height: 1080), mainScreenHeight: 982)
            try expectEqual(side, CGRect(x: 1512, y: 0, width: 1920, height: 1080))
            try expect(WindowSpaces.isFullScreen(windowBounds: [CGRect(x: 0, y: 0, width: 1512, height: 982)],
                                                 screenFrames: [main, side]))
            try expect(WindowSpaces.isFullScreen(windowBounds: [CGRect(x: 100, y: 100, width: 300, height: 200), side],
                                                 screenFrames: [main, side]))
            // Zoomed under the menu bar.
            try expect(!WindowSpaces.isFullScreen(windowBounds: [CGRect(x: 0, y: 37, width: 1512, height: 945)],
                                                  screenFrames: [main, side]))
            try expect(!WindowSpaces.isFullScreen(windowBounds: [], screenFrames: [main]))
        },
        TestCase("inspector: la ventana crece lo que falta y no se sale del área visible") {
            let visible = CGRect(x: 0, y: 70, width: 1512, height: 875)
            // 720 wide, editor needs 600 + chat 360.
            let grown = InspectorSizing.frame(window: CGRect(x: 100, y: 200, width: 720, height: 640), contentWidth: 720,
                                              requiredContentWidth: 960, visibleFrame: visible)
            try expectEqual(grown, CGRect(x: 100, y: 200, width: 960, height: 640))
            // Near the right edge: it grows to the left.
            let right = InspectorSizing.frame(window: CGRect(x: 700, y: 200, width: 720, height: 640), contentWidth: 720,
                                              requiredContentWidth: 960, visibleFrame: visible)
            try expectEqual(right, CGRect(x: 552, y: 200, width: 960, height: 640))
            // Small screen: as wide as the visible area.
            let small = InspectorSizing.frame(window: CGRect(x: 0, y: 0, width: 720, height: 600), contentWidth: 720,
                                              requiredContentWidth: 960, visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 700))
            try expectEqual(small, CGRect(x: 0, y: 0, width: 900, height: 600))
            // Already wide enough.
            try expectEqual(InspectorSizing.frame(window: CGRect(x: 0, y: 0, width: 1180, height: 600), contentWidth: 1180,
                                                  requiredContentWidth: 960, visibleFrame: visible), nil)
            // SwiftUI already widened it past the right edge: it's brought back.
            let off = InspectorSizing.frame(window: CGRect(x: 1000, y: 200, width: 960, height: 640), contentWidth: 960,
                                            requiredContentWidth: 960, visibleFrame: visible)
            try expectEqual(off, CGRect(x: 552, y: 200, width: 960, height: 640))
        },
    ]
}
