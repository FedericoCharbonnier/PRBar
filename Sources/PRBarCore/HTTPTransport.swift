import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Like `send`, but a redirect comes back as is (3xx with `Location`) instead of being followed: the log of a CI job
    /// redirects to a signed URL that must never get the token (spec K.4).
    func sendWithoutRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension HTTPTransport {
    public func sendWithoutRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }
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
}

/// Refuses every redirect: the 3xx comes back to the caller.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
