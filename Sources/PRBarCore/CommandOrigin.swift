import Foundation

/// Who asked for what the app is doing now (spec P.7, decision H1 of the iPhone review): this Mac (the UI or `prbar`)
/// or a paired iPhone through the relay. The remote bridge sets it around the command it dispatches; the places that
/// run code from the repository (the test command, a push that runs the user's git hooks) check it, so a phone
/// request without a fresh Face ID proof can never reach them, whatever path it takes.
public enum CommandOrigin: Equatable, Sendable {
    case mac
    /// `mayRunRepoCode`: the request carried a verified presence proof (Face ID), or that iPhone doesn't require one
    /// (the user turned "Require Face ID" off for it on the Mac).
    case phone(device: String, mayRunRepoCode: Bool)

    @TaskLocal public static var current: CommandOrigin = .mac

    /// Whether what runs now may execute code from the repository (tests, push hooks).
    public static var mayRunRepoCode: Bool {
        switch current {
        case .mac: true
        case .phone(_, let allowed): allowed
        }
    }

    public static let presenceRequiredMessage = "Face ID is required for this on iPhone."
}
