import Foundation

/// El acceso desde el iPhone (spec Q): `AppConfig.remote`. Las claves de la Mac viven en el llavero y los teléfonos en
/// `remote/devices.json`; acá solo lo que no es secreto.
public struct RemoteSettings: Codable, Hashable, Sendable {
    /// El relay del usuario (spec P.10). Configurable: `prbar remote enable --relay H` o la hoja de Settings.
    public static let defaultRelayHost = "prbar.fcharbonnier.duckdns.org"
    public static let defaultRelayURL = "https://\(defaultRelayHost)"
    /// Los únicos hosts aceptados para el link de instalación de la app del iPhone.
    public static let installHosts: Set<String> = ["testflight.apple.com", "apps.apple.com"]

    public var enabled: Bool
    /// `host` o `host:puerto`, sin esquema (spec P.14).
    public var relayHost: String?
    /// La cuenta que la Mac creó en el relay al habilitar (spec P.3).
    public var accountId: String?
    public var keepAwakeWhileCharging: Bool
    /// Dejar el último `home` cifrado en el buzón del relay (7 días, spec V.3). Encendido por defecto.
    public var mailboxEnabled: Bool
    /// TestFlight público o App Store ("Get PRBar for iPhone"); nil = todavía no hay.
    public var appInstallURL: URL?

    public init(enabled: Bool = false, relayHost: String? = nil, accountId: String? = nil,
                keepAwakeWhileCharging: Bool = false, mailboxEnabled: Bool = true, appInstallURL: URL? = nil) {
        self.enabled = enabled
        self.relayHost = relayHost
        self.accountId = accountId
        self.keepAwakeWhileCharging = keepAwakeWhileCharging
        self.mailboxEnabled = mailboxEnabled
        self.appInstallURL = appInstallURL
    }

    public static let `default` = RemoteSettings()

    enum CodingKeys: String, CodingKey {
        case enabled, relayHost, accountId, keepAwakeWhileCharging, mailboxEnabled, appInstallURL
    }

    /// Tolerante como el resto de la config: un valor roto o editado a mano vale lo de por defecto.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        relayHost = ((try? c.decodeIfPresent(String.self, forKey: .relayHost)) ?? nil).flatMap { Self.normalizedRelayHost($0) }
        accountId = ((try? c.decodeIfPresent(String.self, forKey: .accountId)) ?? nil).flatMap { Self.isValidAccountId($0) ? $0 : nil }
        keepAwakeWhileCharging = (try? c.decodeIfPresent(Bool.self, forKey: .keepAwakeWhileCharging)) ?? false
        mailboxEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .mailboxEnabled)) ?? true
        appInstallURL = ((try? c.decodeIfPresent(String.self, forKey: .appInstallURL)) ?? nil).flatMap { try? Self.installURL($0) }
        if relayHost == nil || accountId == nil { enabled = false }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(relayHost, forKey: .relayHost)
        try c.encodeIfPresent(accountId, forKey: .accountId)
        try c.encode(keepAwakeWhileCharging, forKey: .keepAwakeWhileCharging)
        try c.encode(mailboxEnabled, forKey: .mailboxEnabled)
        try c.encodeIfPresent(appInstallURL?.absoluteString, forKey: .appInstallURL)
    }

    /// Base32 minúscula (spec P.2), con margen.
    static func isValidAccountId(_ text: String) -> Bool {
        (1...64).contains(text.count) && text.allSatisfy { ("a"..."z").contains($0) || ("2"..."7").contains($0) }
    }

    /// `host`, `host:puerto`, `https://host[:puerto][/]` o `wss://…` → `host[:puerto]` en minúsculas; nil si no es un
    /// nombre de host válido. Nunca `http://` ni rutas, usuarios o consultas. Una IP literal solo en tests.
    public static func normalizedRelayHost(_ input: String, allowIPForTests: Bool = false) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "wss://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty, !text.contains("://"), !text.contains(where: { "/?#@ \\".contains($0) }) else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let host = String(parts[0])
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65_535).contains(port), String(port) == parts[1] else { return nil }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIP = labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
        if isIP { return allowIPForTests ? text : nil }
        guard host.count <= 253, labels.count >= 2, labels.allSatisfy({ label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-"
                && label.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }) else { return nil }
        return text
    }

    /// El link de instalación de la app del iPhone: `https`, sin usuario ni puerto, en `installHosts`.
    public static func installURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), installHosts.contains(host),
              components.user == nil, components.password == nil, components.port == nil,
              let url = components.url, trimmed.count <= 512 else {
            throw CommandFailure(.invalidUsage,
                                 "Use an https link to testflight.apple.com or apps.apple.com.")
        }
        return url
    }
}
