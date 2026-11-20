import PRBarCore

/// The size the searchable pickers open at (`PickerListSizing`).
enum PickerListSizingTests {
    static let cases: [TestCase] = [
        TestCase("pickers: la lista mide sus filas (subtítulos y encabezados incluidos)") {
            try expectEqual(PickerListSizing.contentHeight(subtitled: [false, false, true], sections: 0), 28 + 28 + 44 + 8)
            try expectEqual(PickerListSizing.contentHeight(subtitled: [false, false], sections: 2), 28 * 2 + 26 * 2 + 8)
            try expectEqual(PickerListSizing.contentHeight(subtitled: [], sections: 0), 8)
        },
        TestCase("pickers: con muchas filas se ven unas 14 y el resto con scroll; nunca más alta que la pantalla") {
            let many = PickerListSizing.contentHeight(subtitled: Array(repeating: false, count: 200), sections: 3)
            try expectEqual(PickerListSizing.listHeight(contentHeight: many, screenHeight: 900), 14 * 28 + 8)
            try expectEqual(PickerListSizing.listHeight(contentHeight: many, maxHeight: 480, screenHeight: 900), 480)
            // Small screen.
            try expectEqual(PickerListSizing.listHeight(contentHeight: many, maxHeight: 480, screenHeight: 500), 500 - 140)
            // Few rows: as tall as they are; none: room for a message.
            try expectEqual(PickerListSizing.listHeight(contentHeight: 3 * 28 + 8, screenHeight: 900), 92)
            try expectEqual(PickerListSizing.listHeight(contentHeight: 8, screenHeight: 900), 60)
            try expectEqual(PickerListSizing.listHeight(contentHeight: many, screenHeight: nil), 14 * 28 + 8)
        },
        TestCase("pickers: al menos 360 de ancho") {
            try expectEqual(PickerListSizing.width(requested: 280), 360)
            try expectEqual(PickerListSizing.width(requested: 440), 440)
        },
    ]
}
