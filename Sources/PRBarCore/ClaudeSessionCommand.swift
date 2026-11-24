import Foundation

/// The shell command that resumes a Claude session where it ran (spec T.5). Every value goes in single quotes
/// (`ShellQuote`) and the id must be a UUID: nothing from a record is interpolated as shell.
public enum ClaudeSessionCommand {
    public enum Failure: Error, Equatable, LocalizedError {
        case invalidSessionID(String)

        public var errorDescription: String? {
            switch self {
            case .invalidSessionID: "This Claude session can’t be resumed: its id isn’t valid."
            }
        }
    }

    /// `cd '<folder>' && '<claude>' --resume <uuid>` (`claudePath`: Settings › Tools).
    public static func local(session: ClaudeSessionRef, claudePath: String) throws -> String {
        try resume(session: session, claudePath: claudePath)
    }

    /// `ssh … -t -- <host> "cd '<folder>' && '<claude>' --resume <uuid>"`, quoted as one line for a shell
    /// (`claudePath`: the runner's claude, from its check).
    public static func remote(session: ClaudeSessionRef, destination: RunnerDestination, claudePath: String,
                              sshPath: String = OpenSSHVersion.systemPath) throws -> String {
        let inner = try resume(session: session, claudePath: claudePath)
        return try ShellQuote.command([sshPath] + SSHCommandBuilder.interactiveArguments(destination, remoteCommand: inner))
    }

    private static func resume(session: ClaudeSessionRef, claudePath: String) throws -> String {
        let id = try validID(session)
        return "cd \(try ShellQuote.posix(session.directory)) && \(try ShellQuote.posix(claudePath)) --resume \(id)"
    }

    /// The id, lowercased, if it is a UUID.
    static func validID(_ session: ClaudeSessionRef) throws -> String {
        guard ClaudeSessionRef.isValidID(session.id), let uuid = UUID(uuidString: session.id) else {
            throw Failure.invalidSessionID(session.id)
        }
        return uuid.uuidString.lowercased()
    }
}
