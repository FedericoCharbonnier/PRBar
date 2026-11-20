import ArgumentParser
import Foundation
import PRBarCore

struct UpdateCommand: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "update", abstract: "Update PRBar (and prbar) from the repo’s releases.",
        discussion: "--check exits with 0 if up to date and 10 if there’s a new version. Updating builds the new version (1–2 minutes) and restarts PRBar; without a terminal it needs --yes.")
    @Flag(help: "Only check.") var check = false
    @Flag(help: "Skip the version offered now (Skip This Version).") var skip = false
    @Option(name: .customLong("skip-version"), help: "With --skip: the version to skip (it must be the one offered).") var version: String?
    @Flag(help: "Cancel the update being installed.") var cancel = false
    @Flag(help: "Cancel running reviews and responses instead of waiting for them.") var cancelJobs = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard [check, skip, cancel].filter({ $0 }).count <= 1 else {
            throw ValidationError("Use only one of --check, --skip and --cancel.")
        }
        if version != nil && !skip { throw ValidationError("--skip-version goes with --skip.") }
    }

    private var installs: Bool { !check && !skip && !cancel }

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        guard installs else { return nil }
        let info: UpdateInfo = try connection.run(.updateCheck).decode()
        guard let latest = info.latest else { throw CommandFailure(.invalidState, "PRBar is up to date (\(info.installed)).") }
        if output.terminal.isInteractive && !output.json, let notes = info.notes, !notes.isEmpty {
            output.line(output.paint(info.title ?? "PRBar \(latest)", .bold))
            output.line(notes)
        }
        return "Update PRBar from \(info.installed) to \(latest)? It restarts PRBar."
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        if check { return .updateCheck }
        if cancel { return .updateCancel }
        if skip { return .updateSkip(version: version) }
        return .updateInstall(confirmed: confirmed, cancelJobs: cancelJobs)
    }

    var cancelCommand: AppCommand? { installs ? .updateCancel : nil }

    func render(_ result: JSONValue, _ output: Output) throws {
        if cancel { return output.line("Canceled the update.") }
        let info: UpdateInfo = try result.decode()
        if check {
            if let latest = info.latest {
                output.line("PRBar \(latest) is available (installed: \(info.installed))\(info.skipped ? " — skipped" : "").")
                if let notes = info.notes, !notes.isEmpty { output.line(notes) }
                return
            }
            return output.line("PRBar is up to date (\(info.installed)).")
        }
        if skip { return output.line("Skipped \(info.latest ?? "it"). PRBar will offer the next one.") }
        output.line("Installed \(info.latest ?? "the update"). PRBar is restarting…")
    }

    func exitCode(for result: JSONValue) throws -> Int32 {
        guard check else { return CLIExit.ok }
        let info: UpdateInfo = try result.decode()
        return info.isAvailable ? CLIExit.updateAvailable : CLIExit.ok
    }

    mutating func run() throws {
        guard installs else { return try CLIRunner.run(self) }
        try UpdateInstallRunner.run(self, environment: .live)
    }
}

/// `prbar update` (instalar): al final la app se reinicia y corta la conexión. Solo si antes avisó que se reiniciaba
/// ("Restarting PRBar") espera a que vuelva, y confirma que volvió con otra versión. Cualquier otro corte es un error
/// (exit 3) como en los demás comandos.
public enum UpdateInstallRunner {
    public static func run<C: RemoteCommand>(_ command: C, environment: CLIEnvironment, timeout: TimeInterval = 60,
                                             poll: TimeInterval = 1) throws {
        let output = Output(terminal: environment.terminal, json: command.global.json, out: environment.out,
                            err: environment.err)
        let before = try? environment.reconnect()
        let previous = before?.appVersion
        before?.close()
        var relaunching = false
        do {
            try CLIRunner.run(command, environment: environment) { event in
                if case .progress(let message) = event, message == UpdatePhase.relaunching.title { relaunching = true }
            }
        } catch let exit as ExitCode where exit.rawValue == CLIExit.appUnavailable && relaunching {
            let deadline = Date().addingTimeInterval(timeout)
            var current: String?
            while Date() < deadline {
                Thread.sleep(forTimeInterval: poll)
                guard let connection = try? environment.reconnect() else { continue }
                current = connection.appVersion
                connection.close()
                if current != previous {
                    let message = "PRBar \(current ?? "") is running."
                    return output.json ? output.note(message) : output.line(message)
                }
            }
            if let current {
                output.error("PRBar restarted but it’s still \(current): the update wasn’t installed. See the update log (`prbar doctor`).")
                throw ExitCode(CLIExit.generalError)
            }
            output.error("PRBar didn’t come back within \(Int(timeout)) seconds. Open it from ~/Applications or run `prbar doctor`.")
            throw ExitCode(CLIExit.appUnavailable)
        }
    }
}
