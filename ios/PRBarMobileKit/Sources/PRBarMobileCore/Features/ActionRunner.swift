import Foundation
import PRBarRemoteKit
import PRBarWire

/// How a screen's action ended, in the terms the screens show.
public enum ActionError: Error, Equatable, Sendable {
    /// Face ID was cancelled: nothing was sent; the screen stays where it was.
    case presenceCancelled
    /// The Face ID key is no longer valid: the re-pair screen.
    case presenceKeyInvalid
    /// The Mac (or the link) said no: the message is shown as is.
    case failed(String)
    /// The Mac wants a confirmation first (`confirmationRequired`): the message is the question's text.
    case needsConfirmation(String)

    public var message: String? {
        switch self {
        case .presenceCancelled: nil
        case .presenceKeyInvalid: PresenceFailure.keyInvalidMessage
        case .failed(let text), .needsConfirmation(let text): text
        }
    }
}

/// Sends commands for the view models: asks for Face ID when the command is gated and the Mac requires it for this
/// device, turns failures into `ActionError`, and delivers command events in order on the main actor.
@MainActor
public struct ActionRunner {
    public let connection: RemoteConnection
    public let authorizer: any PresenceAuthorizer

    public init(connection: RemoteConnection, authorizer: any PresenceAuthorizer) {
        self.connection = connection
        self.authorizer = authorizer
    }

    public var isOnline: Bool { connection.state == .online }

    /// `reason` is the Face ID prompt ("Approve acme/api#317"); it is only used for gated commands.
    @discardableResult
    public func run(_ command: AppCommand, reason: String? = nil,
                    onEvent: ((CommandEvent) -> Void)? = nil) async throws(ActionError) -> JSONValue {
        let signer: (any PresenceSigner)? = command.needsPresence && connection.requirePresence
            ? authorizer.signer(reason: reason ?? command.name.rawValue) : nil
        let (stream, continuation) = AsyncStream.makeStream(of: CommandEvent.self)
        let pump = Task { @MainActor in
            for await event in stream { onEvent?(event) }
        }
        defer { continuation.finish() }
        do {
            let result = try await connection.transport.send(command, presence: signer) { continuation.yield($0) }
            continuation.finish()
            await pump.value
            return result
        } catch let failure as PresenceFailure {
            switch failure {
            case .cancelled: throw .presenceCancelled
            case .keyInvalid: throw .presenceKeyInvalid
            case .unavailable(let message): throw .failed(message)
            }
        } catch let failure as CommandFailure {
            continuation.finish()
            await pump.value
            if failure.code == .confirmationRequired { throw .needsConfirmation(failure.message) }
            throw .failed(failure.message)
        } catch {
            throw .failed(error.localizedDescription)
        }
    }
}

extension JSONValue {
    func decoded<T: Decodable>(_ type: T.Type) throws(ActionError) -> T {
        do { return try decode(T.self) } catch { throw .failed("PRBar on your Mac sent something this iPhone can’t read.") }
    }
}
