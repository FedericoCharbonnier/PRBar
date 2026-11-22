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
