import ArgumentParser
import Foundation
import PRBarCore

struct StatusCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "What PRBar shows in the menu bar.")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .status }

    func render(_ result: JSONValue, _ output: Output) throws {
        let status: StatusInfo = try result.decode()
        var header = "PRBar \(status.appVersion)"
        if status.refreshing {
            header += " · updating…"
        } else if status.offline {
            header += " · offline"
        } else if let fetchedAt = status.fetchedAt {
            header += " · updated \(Render.age(fetchedAt))"
        }
        if let until = status.rateLimitedUntil, until > Date() { header += " · GitHub rate limit until \(ClockTime.hhmm(until))" }
        output.line(output.paint(header, .bold))
        output.table(["Section", "PRs"], PRCategory.allCases.map { [$0.title, String(status.counts[$0.rawValue] ?? 0)] })
        if !status.jobs.isEmpty {
            output.line()
            output.table(["Running", "Kind", "Phase"], status.jobs.map { [$0.pr, $0.kind, $0.phase] })
        }
        for issue in status.issues + status.slackIssues { output.line(output.paint("! " + issue, .red)) }
        let missing = status.tools.filter { $0.path == nil }.map(\.name)
        if !missing.isEmpty {
            output.line(output.paint("Missing tools: \(missing.joined(separator: ", ")). Run `prbar doctor`.", .yellow))
        }
    }
}
