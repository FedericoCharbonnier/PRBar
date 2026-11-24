import AppKit
import Foundation
import PRBarCore

/// Claude's sessions in a terminal (spec T): the kept folders, what "Terminal" offers and opening it.
extension AppModel {
    // MARK: Settings (spec T.6)

    func configSetTerminal(_ terminal: TerminalChoice) throws {
        try applyConfig { $0.setTerminal(terminal) }
    }

    /// The same check `TerminalOpener` runs before launching: not empty, has `{command}`, no quoted placeholders.
    func configSetTerminalCommand(_ command: String) throws {
        do {
            try TerminalLauncher.validateCustomCommand(command)
        } catch {
            throw CommandFailure(.invalidUsage, "\(error.localizedDescription) {dir} is the PR’s folder, {command} runs Claude.")
        }
        try applyConfig { $0.setTerminalCommand(command) }
    }
}
