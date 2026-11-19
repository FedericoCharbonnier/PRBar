import Foundation

/// Versión semántica `X.Y.Z` con `-prerelease` opcional, como la de `CFBundleShortVersionString` y la de los tags
/// `vX.Y.Z` de los releases (spec D.1). Se guarda en JSON como string.
public struct SemanticVersion: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Lo que va después del `-` (`beta.1`); `nil` en una versión final.
    public let prerelease: String?

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Acepta `1.2.3`, `v1.2.3` y `1.2.3-beta.1`; ignora la metadata de build (`+…`). `nil` si no son exactamente tres
    /// números (de hasta 9 dígitos) o si el prerelease tiene algo fuera de `[A-Za-z0-9.-]`.
    public init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        if let plus = text.firstIndex(of: "+") { text = text[..<plus] }
        var prerelease: String?
        if let dash = text.firstIndex(of: "-") {
            let suffix = text[text.index(after: dash)...]
            guard !suffix.isEmpty,
                  suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
            prerelease = String(suffix)
            text = text[..<dash]
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...9).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        self.init(numbers[0], numbers[1], numbers[2], prerelease: prerelease)
    }

    public var isPrerelease: Bool { prerelease != nil }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (left?, right?): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = SemanticVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a version: \(text)"))
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
