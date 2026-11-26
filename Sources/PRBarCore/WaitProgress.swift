import Foundation

/// The progress lines of `--wait` (spec LP.5, decision 23): the phase and, while there is one, the step
/// ("Reviewing… · Reading src/a.swift"). A new line when either changes; the same step started again (another
/// `startedAt`) is a new line too: the CLI drops identical lines in a row when its output isn't a terminal.
public struct WaitProgress: Sendable {
    private var lastPhase: String?
    private var lastActivity: JobActivity?
    private var started = false

    public init() {}

    /// The line to send now, or nil if nothing changed since the last one.
    public mutating func next(phase: String, activity: JobActivity?) -> String? {
        if started, phase == lastPhase, activity == lastActivity { return nil }
        started = true
        lastPhase = phase
        lastActivity = activity
        return activity.map { "\(phase) · \($0.text)" } ?? phase
    }
}
