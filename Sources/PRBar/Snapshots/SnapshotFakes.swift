import Foundation
import PRBarCore

/// Stand-ins for everything `AppModel` talks to, so snapshot mode never runs `gh`, `git` or `claude`, never
/// touches the network, Slack or the Keychain, and never writes outside its own scratch folder.
enum SnapshotFakes {
    static let refused = PRBarError.invalidResponse("Not available in snapshot mode")
}

/// Answers `gh auth status` and `gh auth token` with the sample accounts; refuses anything else.
struct SnapshotProcessRunner: ProcessRunning {
    let accounts: [GHAccount]

    func run(_ executable: String, _ arguments: [String], environment: [String: String]?,
             currentDirectory: URL?, timeout: TimeInterval?) async throws -> ProcessResult {
        if arguments.starts(with: ["auth", "status"]) {
            let lines = accounts.map { account in
                "  ✓ Logged in to github.com account \(account.login) (keyring)\n  - Active account: \(account.isActive)"
            }
            return ProcessResult(status: 0, stdout: "github.com\n" + lines.joined(separator: "\n"), stderr: "")
        }
        if arguments.starts(with: ["auth", "token"]) {
            return ProcessResult(status: 0, stdout: "snapshot-token\n", stderr: "")
        }
        throw SnapshotFakes.refused
    }
}

/// The GitHub lists that Settings shows (repos, branches, people); everything else is refused.
struct SnapshotGitHubAPI: GitHubAPI {
    let repos: [RepoRef]
    let branches: [String: [String]]
    let defaultBranches: [String: String]
    let users: [GitHubUser]

    func viewerRepositories(token: String) async throws -> [RepoRef] { repos }
    func branches(of repo: RepoRef, token: String) async throws -> [String] { branches[repo.fullName] ?? ["main"] }
    func defaultBranch(of repo: RepoRef, token: String) async throws -> String { defaultBranches[repo.fullName] ?? "main" }
    func assignableUsers(of repo: RepoRef, token: String) async throws -> [GitHubUser] { users }
    func user(login: String, token: String) async throws -> GitHubUser? { users.first { $0.login == login } }

    func openPullRequests(in repo: RepoRef, token: String) async throws -> RepoPRs { throw SnapshotFakes.refused }
    func pullRequestFiles(repo: RepoRef, number: Int, token: String) async throws -> [PRFile] { throw SnapshotFakes.refused }
    func pullRequestDetails(repo: RepoRef, number: Int, token: String) async throws -> PRDetails { throw SnapshotFakes.refused }
    func submitReview(repo: RepoRef, number: Int, submission: ReviewSubmission, token: String) async throws -> URL {
        throw SnapshotFakes.refused
    }
    func reviewFeedback(repo: RepoRef, number: Int, token: String) async throws -> PRFeedback { throw SnapshotFakes.refused }
    func replyToReviewComment(repo: RepoRef, number: Int, commentID: Int, body: String, token: String) async throws -> URL {
        throw SnapshotFakes.refused
    }
    func addIssueComment(repo: RepoRef, number: Int, body: String, token: String) async throws -> URL {
        throw SnapshotFakes.refused
    }
}

/// The channel list of the Repos tab; nothing is ever posted.
struct SnapshotSlackAPI: SlackAPI {
    let channels: [SlackChannel]

    func channels(token: String) async throws -> SlackChannelList { SlackChannelList(channels: channels, truncated: false) }

    func postMessage(channel: String, text: String, threadTS: String?, token: String) async throws -> String {
        throw SnapshotFakes.refused
    }
    func threadReplies(channel: String, ts: String, token: String) async throws -> [SlackMessage] { throw SnapshotFakes.refused }
    func authTest(token: String) async throws -> SlackIdentity { throw SnapshotFakes.refused }
    func history(channel: String, oldest: Date, token: String) async throws -> [SlackMessage] { throw SnapshotFakes.refused }
    func addReaction(channel: String, ts: String, name: String, token: String) async throws { throw SnapshotFakes.refused }
}

/// An empty Keychain that never stores anything.
struct SnapshotSecretStore: SecretStore {
    func read(_ key: String) throws -> String? { nil }
    func exists(_ key: String) throws -> Bool { false }
    func write(_ value: String?, for key: String) throws {}
}

/// Reviews: the PRs in `inProgress` stay "Reviewing…" with 3 agents until canceled; the others finish at once
/// with their sample draft.
struct SnapshotReviewPipeline: ReviewPipelineRunning {
    let drafts: [String: ReviewDraft]
    let inProgress: Set<String>

    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        let prID = request.item.id
        await onPhase(.reviewing(agents: 3))
        if inProgress.contains(prID) {
            while true { try await Task.sleep(for: .seconds(3600)) }
        }
        guard let draft = drafts[prID] else { throw SnapshotFakes.refused }
        return draft
    }
}

/// "Respond": the sample analysis, fixes and test run, instantly. Pushing and posting are refused.
struct SnapshotRespondPipeline: RespondPipelineRunning {
    let draft: RespondDraft
    let result: RespondResult
    let tests: TestRun
    let logDirectory: URL

    func analyze(_ request: RespondRequest, draftID: UUID,
                 onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void) async throws -> RespondDraft {
        var draft = self.draft
        draft.id = draftID
        return draft
    }

    func implement(draft: RespondDraft, selections: [String: RespondSelection],
                   onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> RespondResult {
        result
    }

    func runTests(draft: RespondDraft, testCommand: String) async -> TestRun { tests }
    func push(draft: RespondDraft, result: RespondResult) async throws { throw SnapshotFakes.refused }
    func cleanup(draft: RespondDraft) async {}

    func postReplies(draft: RespondDraft, selections: [String: RespondSelection], result: RespondResult?,
                     alreadyPosted: [String: PostedReply],
                     onPosted: @escaping @Sendable (String, PostedReply) async -> Void) async -> (posted: [String: PostedReply], error: Error?) {
        (alreadyPosted, SnapshotFakes.refused)
    }

    func logURL(for id: UUID) -> URL { logDirectory.appendingPathComponent("\(id.uuidString).log") }
}

/// Snapshot mode never runs a chat turn: every call fails and cleanup does nothing (no git, no claude).
struct SnapshotChatBackend: ChatBackend {
    private var unavailable: SnapshotError { SnapshotError(message: "There’s no chat in snapshot mode") }

    func workspace(_ request: ChatWorkspaceRequest) async throws -> ChatWorkspace { throw unavailable }
    func send(_ input: ChatTurnInput, subject: ChatSubject, logURL: URL,
              onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ChatTurnOutput { throw unavailable }
    func sendEditing(_ input: ChatTurnInput, draft: RespondDraft, result: RespondResult, sessionID: UUID, logURL: URL,
                     onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> (ChatTurnOutput, ChatFilesOutcome) {
        throw unavailable
    }
    func undoFiles(draft: RespondDraft, snapshot: ChatFileSnapshot, logURL: URL) async throws -> RespondResult { throw unavailable }
    func filesChangedSince(draft: RespondDraft, snapshot: ChatFileSnapshot) async -> Bool { false }
    func cleanup(session: ChatSession, subject: ChatSubject, localPath: String?) async {}
}

/// Snapshot mode never runs the instructions chat.
struct SnapshotInstructionsChatBackend: InstructionsChatBackend {
    func send(_ input: InstructionsTurnInput,
              onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> InstructionsTurnOutput {
        throw SnapshotError(message: "There’s no chat in snapshot mode")
    }
}
