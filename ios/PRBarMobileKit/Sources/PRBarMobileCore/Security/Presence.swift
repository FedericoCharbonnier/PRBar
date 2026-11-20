import CryptoKit
import Foundation
import LocalAuthentication
import PRBarRemoteKit

/// Why a Face ID signature did not happen (spec P.8).
public enum PresenceFailure: Error, Equatable, Sendable {
    /// The user cancelled the prompt: nothing is sent, the screen goes back to where it was.
    case cancelled
    /// Face ID can't be used right now (locked out, not set up): its message is shown.
    case unavailable(String)
    /// The enrolled faces changed (the key is bound to `.biometryCurrentSet`) or the key is gone: pair again.
    case keyInvalid

    public static let keyInvalidMessage = "Face ID changed. Pair this iPhone again from your Mac."

    /// The `LAError` code of a failed evaluation.
    public static func from(laErrorCode code: Int, message: String) -> PresenceFailure {
        switch LAError.Code(rawValue: code) {
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            .cancelled
        case .biometryNotAvailable, .biometryLockout, .biometryNotEnrolled, .passcodeNotSet:
            .unavailable(message)
        default:
            .unavailable(message)
        }
    }
}

/// Hands out a signer for one gated action. The reason is what the Face ID prompt says ("Approve acme/api#12").
public protocol PresenceAuthorizer: Sendable {
    func signer(reason: String) -> any PresenceSigner
}

/// The Face ID key (spec P.8): a P-256 key in the Secure Enclave that does not sign without a current biometric
/// authentication. Face ID is evaluated first (so a cancel is a clean `LAError`), then the key is restored with that
/// authenticated context: if it still can't sign, the enrolled faces changed and the key is invalid.
public struct SecureEnclavePresence: PresenceSigner {
    public let keyData: Data
    public let reason: String

    public init(keyData: Data, reason: String) {
        self.keyData = keyData
        self.reason = reason
    }

    /// A new key: `[.privateKeyUsage, .biometryCurrentSet]`, this device only, no passcode fallback.
    public static func createKey() throws -> Data {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return try SecureEnclave.P256.Signing.PrivateKey(accessControl: access).dataRepresentation
    }

    public static func publicKey(of keyData: Data) throws -> Data {
        try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData).publicKey.x963Representation
    }

    public func sign(_ message: Data) async throws -> Data {
        let context = LAContext()
        context.localizedReason = reason
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError {
            throw PresenceFailure.from(laErrorCode: error.errorCode, message: error.localizedDescription)
        }
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData,
                                                                authenticationContext: context)
            return try key.signature(for: message).derRepresentation
        } catch {
            throw PresenceFailure.keyInvalid
        }
    }
}

public struct SecureEnclaveAuthorizer: PresenceAuthorizer {
    public let keyData: Data

    public init(keyData: Data) {
        self.keyData = keyData
    }

    public func signer(reason: String) -> any PresenceSigner {
        SecureEnclavePresence(keyData: keyData, reason: reason)
    }
}

/// A software P-256 (tests, previews and DEBUG simulator builds only: the simulator has no Secure Enclave). It can be
/// told to fail like Face ID would, and it records the reasons it was asked for.
public final class SoftwarePresenceAuthorizer: PresenceAuthorizer, @unchecked Sendable {
    public let key: P256.Signing.PrivateKey
    private let lock = NSLock()
    private var _reasons: [String] = []
    private var failure: PresenceFailure?

    public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey(), failing failure: PresenceFailure? = nil) {
        self.key = key
        self.failure = failure
    }

    public var publicKey: Data { key.publicKey.x963Representation }
    public var reasons: [String] { lock.withLock { _reasons } }

    public func setFailure(_ failure: PresenceFailure?) {
        lock.withLock { self.failure = failure }
    }

    public func signer(reason: String) -> any PresenceSigner {
        Signer(owner: self, reason: reason)
    }

    fileprivate func sign(_ message: Data, reason: String) throws -> Data {
        let failure = lock.withLock { () -> PresenceFailure? in
            _reasons.append(reason)
            return self.failure
        }
        if let failure { throw failure }
        return try key.signature(for: message).derRepresentation
    }

    private struct Signer: PresenceSigner {
        let owner: SoftwarePresenceAuthorizer
        let reason: String
        func sign(_ message: Data) async throws -> Data { try owner.sign(message, reason: reason) }
    }
}
