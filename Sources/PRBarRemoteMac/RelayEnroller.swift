import Foundation
import PRBarCore
import PRBarRemoteKit

/// `POST https://<host>/v1/accounts` (spec P.3): crea la cuenta de la Mac con el token de inscripción.
public protocol RelayEnrolling: Sendable {
    /// Devuelve el `accountId`. Los errores ya tienen el texto de la UI.
    func enroll(host: String, token: String, macRelayKey: Data) async throws -> String
}

public struct URLSessionRelayEnroller: RelayEnrolling {
    let allowInsecureForTests: Bool

    public init(allowInsecureForTests: Bool = false) {
        self.allowInsecureForTests = allowInsecureForTests
    }

    public func enroll(host: String, token: String, macRelayKey: Data) async throws -> String {
        guard let url = URL(string: "\(allowInsecureForTests ? "http" : "https")://\(host)/v1/accounts") else {
            throw CommandFailure(.invalidUsage, "That isn’t a valid relay host.")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["enrollToken": token, "macRelayKey": Base64URL.encode(macRelayKey)])
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CommandFailure(.failed, "Couldn’t reach \(host).")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200, 201:
            guard let account = try? JSONDecoder().decode([String: String].self, from: data)["accountId"], !account.isEmpty else {
                throw CommandFailure(.failed, "The relay answered something PRBar doesn’t understand.")
            }
            return account
        default:
            throw Self.failure(status: status)
        }
    }

    public static func failure(status: Int) -> CommandFailure {
        switch status {
        case 401, 403: CommandFailure(.unauthorized, "The relay refused the enrollment token.")
        case 429: CommandFailure(.failed, "Too many attempts. Try again in 15 minutes.")
        case 409: CommandFailure(.failed, "The relay has no room for another Mac.")
        default: CommandFailure(.failed, "The relay couldn’t create the account (HTTP \(status)).")
        }
    }
}
