import Foundation

/// Text formatting shared by the screens. Locale and time zone are parameters so tests are deterministic.
public enum Format {
    /// `acme/web-app` → `web-app`.
    public static func repoName(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    /// `acme/web-app#491` → `web-app#491`.
    public static func shortRef(_ prID: String) -> String {
        guard let hash = prID.lastIndex(of: "#") else { return prID }
        return repoName(String(prID[..<hash])) + prID[hash...]
    }

    /// `acme/api#317` → `acme/api #317` (the detail screens' header).
    public static func headerRef(_ prID: String) -> String {
        prID.replacingOccurrences(of: "#", with: " #")
    }

    /// Row age: "now", "12 min", "2h", "3d", "5w".
    public static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60)) min"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (7 * 86_400)))w"
        }
    }

    /// Notification-style age: "now", "4m ago", "2h ago".
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }

    /// "8:12 AM".
    public static func time(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "today at 8:12 AM" / "yesterday at 8:12 AM" / "Nov 18 at 8:12 AM".
    public static func dayAndTime(_ date: Date, now: Date, locale: Locale = .current,
                                  timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = time(date, locale: locale, timeZone: timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(clock)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(clock)"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return "\(formatter.string(from: date)) at \(clock)"
    }

    /// "4:12" (minutes:seconds, or h:mm:ss past an hour).
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3_600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "3m 40s", "45s", "1h 5m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3_600)h \(total / 60 % 60)m"
    }

    /// "$48.20".
    public static func money(_ value: Double) -> String {
        String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// "11.2 GB", "212 GB", "640 MB" (decimal units, like Finder).
    public static func bytes(_ value: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1_000, unit < units.count - 1 {
            amount /= 1_000
            unit += 1
        }
        if unit == 0 { return "\(value) bytes" }
        let text = amount < 100 && amount.rounded() != amount
            ? String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), amount)
            : String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), amount)
        return "\(text) \(units[unit])"
    }

    /// "Laura Méndez" → "LM"; "lmendez" → "LM"; "ana-pereira" → "AP".
    public static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
        if words.count >= 2 {
            return (words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    /// A stable index (FNV-1a) for a person's avatar color: same login, same color, on every launch.
    public static func avatarIndex(_ login: String, count: Int) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in login.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(max(count, 1)))
    }

    /// "1 comment" / "4 comments".
    public static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
    }

    /// The line of a `file:line` location, if any (`src/a.ts:88` → 88).
    public static func line(of location: String) -> Int? {
        location.split(separator: ":").last.flatMap { Int($0) }
    }
}
