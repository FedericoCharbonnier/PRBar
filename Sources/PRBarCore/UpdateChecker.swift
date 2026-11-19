import Foundation

/// Un release publicado de PRBar (spec D.2).
public struct ReleaseInfo: Codable, Equatable, Sendable {
    public var version: SemanticVersion
    /// El tag tal cual está en GitHub (`v1.3.0`): es lo que se descarga y compila.
    public var tag: String
    public var title: String
    /// Notas del release (Markdown).
    public var notes: String
    public var url: URL
    public var publishedAt: Date?

    public init(version: SemanticVersion, tag: String, title: String, notes: String, url: URL, publishedAt: Date?) {
        self.version = version
        self.tag = tag
        self.title = title
        self.notes = notes
        self.url = url
        self.publishedAt = publishedAt
    }

    /// La primera línea con texto de las notas que no es un título, sin la viñeta (`-`, `*`, `+`), de hasta 120
    /// caracteres. Es el cuerpo de la notificación.
    public var summary: String? {
        for raw in notes.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            guard !line.isEmpty else { continue }
            return line.count > 120 ? String(line.prefix(119)) + "…" : line
        }
        return nil
    }
}

/// Pregunta a GitHub cuál es el último release de PRBar: `GET /repos/{repo}/releases/latest`, sin token (el repo es
/// público). Ignora drafts, prereleases y tags que no son exactamente `vX.Y.Z` (`SemanticVersion(releaseTag:)`).
public struct UpdateChecker: Sendable {
    public static let timeout: TimeInterval = 15

    private let transport: HTTPTransport
    private let repo: String

    /// `repo`: `owner/name` ya validado (`UpdateSettings.effectiveRepo`).
    public init(transport: HTTPTransport, repo: String) {
        self.transport = transport
        self.repo = repo
    }

    public static func latestURL(repo: String) -> URL {
        URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    /// `nil` si el repo no tiene releases (404) o si el último no se puede instalar (draft, prerelease, tag raro).
    public func latestRelease() async throws -> ReleaseInfo? {
        var request = URLRequest(url: Self.latestURL(repo: repo), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PRBar/\(AppVersion.current())", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as PRBarError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PRBarError.network(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            break
        case 404:
            return nil
        case 403, 429:
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
               let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) {
                throw PRBarError.rateLimited(resetAt: Date(timeIntervalSince1970: reset))
            }
            throw PRBarError.http(status: response.statusCode, message: Self.message(from: data))
        default:
            throw PRBarError.http(status: response.statusCode, message: Self.message(from: data))
        }

        let release: GitHubRelease
        do {
            release = try JSONCoding.decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw PRBarError.invalidResponse("latest release: \(error.localizedDescription)")
        }
        guard !release.draft, !release.prerelease, let version = SemanticVersion(releaseTag: release.tagName) else { return nil }
        let name = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ReleaseInfo(
            version: version, tag: release.tagName, title: name.isEmpty ? "PRBar \(version)" : name,
            notes: release.body ?? "", url: release.htmlURL, publishedAt: release.publishedAt
        )
    }

    private static func message(from data: Data) -> String {
        struct Body: Decodable { let message: String? }
        return (try? JSONDecoder().decode(Body.self, from: data))?.message ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", name, body, htmlURL = "html_url", draft, prerelease, publishedAt = "published_at"
        }
    }
}
