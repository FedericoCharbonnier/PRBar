import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Like `send`, but a redirect comes back as is (3xx with `Location`) instead of being followed: the log of a CI job
    /// redirects to a signed URL that must never get the token (spec K.4).
    func sendWithoutRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Like `sendWithoutRedirects`, but streams the body and keeps only its last `keepingLast` bytes; past `maxBytes`
    /// read it gives up (`PRBarError.invalidResponse`). Nothing is cached or stored (no cookies, no URL cache): it reads
    /// CI job logs, which may hold sensitive output (spec K.4, K.6.4).
    func downloadTail(_ request: URLRequest, keepingLast: Int, maxBytes: Int) async throws -> (Data, HTTPURLResponse)
}

/// Not following redirects and capping a download can't be done on top of `send` (it follows the 302, carrying the
/// headers along). A transport that doesn't implement them fails instead of silently leaking the token (spec K.4).
extension HTTPTransport {
    public func sendWithoutRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw PRBarError.invalidResponse("this connection can’t make requests without following redirects")
    }

    public func downloadTail(_ request: URLRequest, keepingLast: Int, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        throw PRBarError.invalidResponse("this connection can’t make capped downloads")
    }
}

/// The last `keep` bytes of a stream, giving up once more than `limit` bytes went through.
public struct TailBuffer: Sendable {
    public let keep: Int
    public let limit: Int
    public private(set) var totalBytes = 0
    private var buffer = Data()

    public init(keep: Int, limit: Int) {
        self.keep = max(keep, 0)
        self.limit = limit
    }

    public mutating func append(_ chunk: Data) throws {
        totalBytes += chunk.count
        guard totalBytes <= limit else { throw Self.tooLarge(limit) }
        buffer.append(chunk)
        // Trimmed now and then (not on every chunk): memory stays under about twice `keep`.
        if buffer.count > keep * 2 { buffer = Data(buffer.suffix(keep)) }
    }

    public static func tooLarge(_ limit: Int) -> PRBarError {
        .invalidResponse("the download is larger than \(ByteSize.file(Int64(limit)))")
    }

    /// The last `keep` bytes so far.
    public var tail: Data { Data(buffer.suffix(keep)) }
    /// More than `keep` bytes went through.
    public var truncated: Bool { totalBytes > keep }
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PRBarError.invalidResponse("the response isn't HTTP")
        }
        return (data, http)
    }

    public func sendWithoutRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else {
            throw PRBarError.invalidResponse("the response isn't HTTP")
        }
        return (data, http)
    }

    public func downloadTail(_ request: URLRequest, keepingLast keep: Int, maxBytes limit: Int) async throws -> (Data, HTTPURLResponse) {
        // Its own ephemeral session: no URL cache on disk, no shared cookies or credentials.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else {
            throw PRBarError.invalidResponse("the response isn't HTTP")
        }
        // Announced as too large: not worth reading.
        if http.expectedContentLength > Int64(limit) { throw TailBuffer.tooLarge(limit) }
        var buffer = TailBuffer(keep: keep, limit: limit)
        var chunk = Data()
        chunk.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 64 * 1024 {
                try buffer.append(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try buffer.append(chunk)
        return (buffer.tail, http)
    }
}

/// Refuses every redirect: the 3xx comes back to the caller.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
