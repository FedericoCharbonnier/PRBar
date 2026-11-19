import Foundation
import NaturalLanguage

/// The language a PR is written in, detected from its description (spec §16). Everything PRBar publishes on
/// GitHub for that PR (review comments, replies and PRBar's own fixed phrases) goes out in this language; what
/// is shown only to the user inside the app stays in English.
///
/// Encoded as its BCP-47 code (`"es"`), so it fits in old history files as a plain string.
public struct PRLanguage: Codable, Hashable, Sendable {
    /// BCP-47 code, as `NLLanguage` reports it ("es", "pt", "zh-Hans"…).
    public let code: String

    public init(code: String) {
        self.code = code
    }

    public static let english = PRLanguage(code: "en")

    /// Letters the stripped description needs to be used on its own; with fewer, the title is added.
    public static let minimumDescriptionLetters = 40
    /// Below this many letters (description + title) nothing is reliable: English.
    public static let minimumLetters = 12
    /// Below this confidence of the dominant language: English.
    public static let minimumConfidence = 0.5

    /// The English name of the language ("Spanish"), or the code if the system doesn't know it.
    public var displayName: String {
        let english = Locale(identifier: "en_US")
        if let name = english.localizedString(forIdentifier: code), name != code { return name }
        if let name = english.localizedString(forLanguageCode: code), name != code { return name }
        return code
    }

    /// The base language without region or script ("pt-BR" → "pt").
    public var baseCode: String {
        String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }

    /// Detects the language of a PR. The description is stripped first (see `strip`); if it has at least
    /// `minimumDescriptionLetters` letters it is used on its own, otherwise the title is added. Too little text
    /// or a dominant language below `minimumConfidence` → English.
    public static func detect(description: String?, title: String) -> PRLanguage {
        let body = strip(description ?? "")
        let text = letterCount(body) >= minimumDescriptionLetters ? body : body + "\n" + strip(title)
        guard letterCount(text) >= minimumLetters else { return .english }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              best.value >= minimumConfidence, best.key != .undetermined else { return .english }
        return PRLanguage(code: best.key.rawValue)
    }

    /// Removes what says nothing about the author's language: HTML comments (PR templates), fenced and inline
    /// code, HTML tags, images, URLs, checklist items, headings, tables' pipes, @mentions, #refs and Markdown
    /// punctuation. Link texts are kept.
    public static func strip(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let rules: [(pattern: String, replacement: String)] = [
            (#"<!--[\s\S]*?(-->|$)"#, " "),                       // HTML comments (also an unclosed one)
            (#"(?m)^[ \t]*(```|~~~)[^\n]*\n[\s\S]*?(^[ \t]*\1[^\n]*$|\z)"#, " "), // fenced code blocks
            (#"`[^`\n]*`"#, " "),                                 // inline code
            (#"!\[[^\]]*\]\([^)]*\)"#, " "),                      // images
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),                    // links → their text
            (#"<[^>\n]+>"#, " "),                                 // HTML tags
            (#"(?i)\b(https?://|www\.)\S+"#, " "),                // URLs
            (#"(?m)^[ \t]*([-*+]|\d+\.)[ \t]+\[[ xX]\].*$"#, " "), // checklist items
            (#"(?m)^[ \t]*#{1,6}[ \t].*$"#, " "),                 // headings (usually template structure)
            (#"(?m)^[ \t]{4,}\S.*$"#, " "),                       // indented code
            (#"(^|\s)[@#][\w./-]+"#, " "),                        // @mentions and #123 refs
            (#"[*_~>|#=\[\]()-]+"#, " "),                         // Markdown punctuation
        ]
        for rule in rules {
            text = text.replacingOccurrences(of: rule.pattern, with: rule.replacement, options: .regularExpression)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func letterCount(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
    }

    public init(from decoder: Decoder) throws {
        let code = try decoder.singleValueContainer().decode(String.self)
        self.init(code: code.isEmpty ? PRLanguage.english.code : code)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

/// PRBar's own fixed phrases inside text it publishes on GitHub. Only "Fixed in …" depends on the PR's
/// language; the other formats are language-neutral Markdown.
public enum PublishedPhrases {
    /// "Fixed in <link>." in the PR's language, by base code. Unknown languages get English.
    static let fixedInFormats: [String: String] = [
        "en": "Fixed in %@.",
        "es": "Arreglado en %@.",
        "pt": "Corrigido em %@.",
        "fr": "Corrigé dans %@.",
        "de": "Behoben in %@.",
        "it": "Corretto in %@.",
    ]

    public static func fixedIn(_ link: String, language: PRLanguage) -> String {
        let format = fixedInFormats[language.baseCode] ?? fixedInFormats["en"]!
        return format.replacingOccurrences(of: "%@", with: link)
    }

    /// A finding whose line isn't in the diff, moved into the review body.
    public static func unanchoredFinding(location: String, text: String) -> String {
        "**\(location)** — \(text)"
    }

    /// A reply to a review body, posted as a PR comment: the mention, the quoted first line (if any) and the text.
    public static func reviewBodyReply(reviewer: String, quote: String, text: String) -> String {
        let mention = "@\(reviewer)"
        return quote.isEmpty ? "\(mention)\n\n\(text)" : "\(mention)\n\n> \(quote)\n\n\(text)"
    }
}
