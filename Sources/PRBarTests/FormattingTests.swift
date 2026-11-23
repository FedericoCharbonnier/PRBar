import Foundation
import PRBarCore

enum FormattingTests {
    static let cases: [TestCase] = [
        TestCase("formatting: short relative age") {
            try expectEqual(RelativeAge.short(from: t0.addingTimeInterval(-30), now: t0), "now")
            try expectEqual(RelativeAge.short(from: at(-40), now: t0), "40 min")
            try expectEqual(RelativeAge.short(from: at(-180), now: t0), "3h")
            try expectEqual(RelativeAge.short(from: at(-60 * 50), now: t0), "2d")
        },
        TestCase("formatting: byte sizes always use English separators") {
            try expectEqual(ByteSize.file(2_300_000_000), "2.3 GB")
            try expectEqual(ByteSize.file(512_000_000), "512 MB")
            try expectEqual(ByteSize.file(1_234_567_890_123), "1.23 TB")
            try expectEqual(ByteSize.memory(3 * 1_073_741_824 / 2), "1.5 GB")
        },
        TestCase("formatting: hora HH:mm") {
            var components = DateComponents()
            components.year = 2026; components.month = 11; components.day = 18; components.hour = 9; components.minute = 5
            let date = Calendar.current.date(from: components)!
            try expectEqual(ClockTime.hhmm(date), "09:05")
        },
        TestCase("formatting: iniciales") {
            try expectEqual(Initials.of("juanperez"), "JU")
            try expectEqual(Initials.of("sofia-r"), "SR")
            try expectEqual(Initials.of("nico_g"), "NG")
            try expectEqual(Initials.of("x"), "X")
            try expectEqual(Initials.of(""), "?")
        },
        TestCase("formatting: color de avatar estable y en rango") {
            let a = AvatarColor.index(for: "juanperez", paletteCount: 7)
            try expectEqual(AvatarColor.index(for: "juanperez", paletteCount: 7), a)
            try expect((0..<7).contains(a))
        },
    ]
}
