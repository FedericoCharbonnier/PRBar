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
    ]
}
