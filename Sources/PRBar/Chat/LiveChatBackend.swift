import Foundation
import PRBarCore

/// The app's chat backend. Like `LiveReviewPipeline`, the paths of git, gh and claude and the Claude settings are
/// read from `AppModel` in the main actor on every call, and a `ChatService` is built with them.
struct LiveChatBackend: ChatBackend {
    let runner: SystemProcessRunner
    let tokens: TokenProviding
    let api: GitHubAPI
    let context: @MainActor @Sendable () -> ReviewContext
    /// 5 s between SIGTERM and SIGKILL to Claude's process group, as in reviews.
    let claudeRunner = SystemProcessRunner(killGracePeriod: 5)

    private func service(needsClaude: Bool = true) async throws -> ChatService {
        let context = await context()
        // The startup orphan cleanup must not delete this chat's worktree.
        await context.orphanCleanup?.value
        guard let git = context.tools.git else { throw PRBarError.toolNotFound("git") }
        if needsClaude && context.tools.claude == nil { throw PRBarError.toolNotFound("claude") }
        return ChatService(processRunner: runner, streamingRunner: claudeRunner, tokens: tokens, api: api, gitPath: git,
                           ghPath: context.tools.gh, claudePath: context.tools.claude ?? "claude", settings: context.claude)
    }

    func workspace(_ request: ChatWorkspaceRequest) async throws -> ChatWorkspace {
        try await service().workspace(request)
    }

    func send(_ input: ChatTurnInput, subject: ChatSubject, logURL: URL,
              onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ChatTurnOutput {
        try await service().send(input, subject: subject, logURL: logURL, onEvent: onEvent)
    }

    func sendEditing(_ input: ChatTurnInput, draft: RespondDraft, result: RespondResult, sessionID: UUID, logURL: URL,
                     onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> (ChatTurnOutput, ChatFilesOutcome) {
        try await service().sendEditing(input, draft: draft, result: result, sessionID: sessionID, logURL: logURL, onEvent: onEvent)
    }

    func undoFiles(draft: RespondDraft, snapshot: ChatFileSnapshot, logURL: URL) async throws -> RespondResult {
        try await service(needsClaude: false).undoFiles(draft: draft, snapshot: snapshot, logURL: logURL)
    }

    func filesChangedSince(draft: RespondDraft, snapshot: ChatFileSnapshot) async -> Bool {
        guard let service = try? await service(needsClaude: false) else { return true }
        return await service.filesChangedSince(draft: draft, snapshot: snapshot)
    }

    func cleanup(session: ChatSession, subject: ChatSubject, localPath: String?) async {
        guard let service = try? await service(needsClaude: false) else { return }
        await service.cleanup(session: session, subject: subject, localPath: localPath)
    }
}
