import ArgumentParser
import Darwin
import Foundation
import PRBarCore

public enum PRBarCLIKit {
    public static let commandName = "prbar"
}

/// `prbar`: todo lo que se hace en la app, desde la terminal (spec C). Ver docs/cli.md.
public struct PRBarCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: PRBarCLIKit.commandName,
        abstract: "Control PRBar from the terminal.",
        discussion: "Everything you can do in PRBar’s menu bar and windows. PRs: owner/repo#N, repo#N or the PR’s URL. See docs/cli.md.",
        version: AppConnection.cliVersion,
        subcommands: [
            StatusCommand.self, PRsCommand.self, ResourcesCommand.self, CleanupCommand.self, RefreshCommand.self, OpenCommand.self, HistoryGroup.self, AppGroup.self,
            ReviewGroup.self, RespondGroup.self, MergeCommand.self, ChatCommand.self, UpdateCommand.self,
            ConfigGroup.self, AccountGroup.self, RepoGroup.self, FollowGroup.self, NotifyGroup.self, ClaudeGroup.self, RunnersGroup.self, ToolsGroup.self, RulesGroup.self,
            SlackGroup.self,
            VersionCommand.self, DoctorCommand.self, CompletionCommand.self,
        ]
    )

    public init() {}
}

public enum PRBarCLIMain {
    /// Parsea, corre y sale con los códigos de `CLIExit` (uso inválido = 2, no el 64 de ArgumentParser).
    public static func run() async -> Never {
        signal(SIGPIPE, SIG_IGN)
        do {
            var command = try PRBarCommand.parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            exit(CLIExit.ok)
        } catch {
            if PRBarCommand.exitCode(for: error).rawValue == ExitCode.validationFailure.rawValue {
                FileHandle.standardError.write(Data((PRBarCommand.fullMessage(for: error) + "\n").utf8))
                exit(CLIExit.usage)
            }
            PRBarCommand.exit(withError: error)
        }
    }
}
