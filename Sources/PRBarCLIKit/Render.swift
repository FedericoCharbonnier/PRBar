import Foundation
import PRBarCore

/// Ayudas de texto de los comandos.
enum Render {
    static func age(_ date: Date) -> String {
        let short = RelativeAge.short(from: date)
        return short == "now" ? "just now" : "\(short) ago"
    }

    /// Una línea, cortada con "…".
    static func truncate(_ text: String, _ limit: Int) -> String {
        let single = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return single.count <= limit ? single : String(single.prefix(max(limit - 1, 0))) + "…"
    }

    /// Spec LP.5: "Now: <step> (<time>)" while the job runs.
    static func now(_ activity: JobActivity?, _ output: Output, at date: Date = Date()) {
        guard let activity else { return }
        output.line("Now: \(activity.text) (\(activity.elapsedText(now: date)))")
    }

    static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// `clave: valor` con las claves alineadas.
    static func pairs(_ pairs: [(String, String)], _ output: Output) {
        let width = pairs.map(\.0.count).max() ?? 0
        for (key, value) in pairs {
            output.line(output.paint(key + ":", .dim) + String(repeating: " ", count: width - key.count + 1) + value)
        }
    }

    static func indent(_ text: String, _ prefix: String = "    ") -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }
}
