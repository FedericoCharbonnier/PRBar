import Foundation

public enum RelativeAge {
    /// "ahora", "40 min", "3h", "2d".
    public static func short(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60) min"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

public enum ClockTime {
    /// "09:05", en la zona horaria local.
    public static func hhmm(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

public enum Initials {
    public static func of(_ login: String) -> String {
        let parts = login.split(whereSeparator: { "-_.".contains($0) })
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        let letters = login.prefix(2).uppercased()
        return letters.isEmpty ? "?" : letters
    }
}

public enum AvatarColor {
    public static func index(for login: String, paletteCount: Int) -> Int {
        guard paletteCount > 0 else { return 0 }
        let sum = login.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return sum % paletteCount
    }
}

/// Byte counts in the UI's English format ("2.3 GB", "512 MB"), whatever the system locale: the rest of the UI
/// ("$2.60", "682.6k") already uses "." as the decimal separator, and `ByteCountFormatter` would say "2,3 GB" in a
/// Spanish or German locale.
public enum ByteSize {
    private static let locale = Locale(identifier: "en_US")

    /// Disk and downloads: decimal units, like Finder.
    public static func file(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    /// RAM: binary units, like Activity Monitor.
    public static func memory(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .memory).locale(locale))
    }
}
