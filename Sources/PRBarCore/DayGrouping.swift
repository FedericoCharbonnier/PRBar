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
