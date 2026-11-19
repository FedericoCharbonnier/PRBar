import Foundation
import os

public struct GHAccount: Hashable, Sendable {
    public let login: String
    public var isActive: Bool

    public init(login: String, isActive: Bool) {
        self.login = login
        self.isActive = isActive
    }
}

public protocol TokenProviding: Sendable {
    func token(for login: String) async throws -> String
}

/// Lee cuentas y tokens de `gh`. Nunca guarda tokens (spec §3).
/// `ghPath` se escribe desde el main actor (al resolver herramientas) y se lee desde tareas en segundo plano
/// (`SnapshotBuilder` → `token(for:)`), así que se protege con un lock.
public final class AccountProvider: TokenProviding, @unchecked Sendable {
    private let runner: ProcessRunning
    private let ghPathLock: OSAllocatedUnfairLock<String?>

    public var ghPath: String? {
        get { ghPathLock.withLock { $0 } }
        set { ghPathLock.withLock { $0 = newValue } }
    }

    public init(runner: ProcessRunning, ghPath: String?) {
        self.runner = runner
        self.ghPathLock = OSAllocatedUnfairLock(initialState: ghPath)
    }

    public func listAccounts() async throws -> [GHAccount] {
        guard let ghPath else { throw PRBarError.toolNotFound("gh") }
        let result = try await runner.run(ghPath, ["auth", "status", "--hostname", "github.com"], timeout: ProcessTimeouts.standard)
        return Self.parseStatus(result.stdout + "\n" + result.stderr)
    }

    public func token(for login: String) async throws -> String {
        guard let ghPath else { throw PRBarError.toolNotFound("gh") }
        let result = try await runner.run(ghPath, ["auth", "token", "--hostname", "github.com", "--user", login], timeout: ProcessTimeouts.standard)
        guard result.status == 0 else {
            throw PRBarError.commandFailed(
                command: "gh auth token --user \(login)",
                status: result.status,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw PRBarError.unauthorized }
        return token
    }

    public static func parseStatus(_ text: String) -> [GHAccount] {
        var accounts: [GHAccount] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: "Logged in to github.com account ") {
                let login = line[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                if !login.isEmpty { accounts.append(GHAccount(login: login, isActive: false)) }
            } else if line.hasPrefix("- Active account: true"), !accounts.isEmpty {
                accounts[accounts.count - 1].isActive = true
            }
        }
        return accounts
    }
}
