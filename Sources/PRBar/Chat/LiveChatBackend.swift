import Foundation
import PRBarCore

/// The app's chat backend. Like `LiveReviewPipeline`, the paths of git, gh and claude and the Claude settings are
/// read from `AppModel` in the main actor on every call, and a `ChatService` is built with them, on this Mac or on a
/// host (spec J): a Respond chat runs where its analysis ran (`draft.runner`); a Review/Merge chat where its worktree
/// is (`ChatSession.runner`), or, before it has one, where the repo says (falling back only if the host is down).
struct LiveChatBackend: ChatBackend {
    let runner: SystemProcessRunner
    let tokens: TokenProviding
    let api: GitHubAPI
    /// The context for the chat's account and repo.
    let context: @MainActor @Sendable (_ account: String, _ repo: RepoRef) -> ReviewContext
    /// 5 s between SIGTERM and SIGKILL to Claude's process group, as in reviews.
    let claudeRunner = SystemProcessRunner(killGracePeriod: 5)

    private func service(_ context: ReviewContext, needsClaude: Bool, placement: RemotePlacement? = nil) throws -> ChatService {
        guard let git = context.tools.git else { throw PRBarError.toolNotFound("git") }
        if placement == nil && needsClaude && context.tools.claude == nil { throw PRBarError.toolNotFound("claude") }
        return ChatService(processRunner: runner, streamingRunner: claudeRunner, tokens: tokens, api: api, gitPath: git,
                           ghPath: placement == nil ? context.tools.gh : nil,
                           claudePath: placement?.claudePath ?? context.tools.claude ?? "claude", settings: context.claude,
                           placement: placement)
    }

    /// `body` with the `ChatService` of where the chat runs. No fallback after a preparation failure (J.7.10).
    private func run<T: Sendable>(_ subject: ChatSubject, _ target: RunnerDispatch.ChatTarget, needsClaude: Bool = true,
                                  _ body: @escaping @Sendable (ChatService) async throws -> T) async throws -> T {
        let context = await context(subject.account, subject.repo)
        // The startup orphan cleanup must not delete this chat's worktree.
        await context.orphanCleanup?.value
        let prID = subject.prID
        let local: @Sendable () async throws -> T = { try await body(try service(context, needsClaude: needsClaude)) }
        let remote: @Sendable (RemotePlacement) async throws -> T = { try await body(try service(context, needsClaude: false, placement: $0)) }
        let onPlacement: @Sendable (JobPlacement) async -> Void = { await context.onPlacement(prID, $0) }
        switch target {
        case .pinned(let name):
            return try await RunnerDispatch.pinned(runner: name, settings: context.runnerSettings, coordinator: context.coordinator,
                                                   onPlacement: onPlacement, local: local, remote: remote)
        case .repoDestination:
            // Without claude (or git) on this Mac a host that's down shows its own error, not "claude not found" (J.7.24).
            return try await RunnerDispatch.run(destination: context.runner, coordinator: context.coordinator, fallbackOnPreparation: false,
                                                canRunLocally: context.tools.git != nil && (!needsClaude || context.tools.claude != nil),
                                                onPlacement: onPlacement, local: local, remote: remote)
        }
    }

    func workspace(_ request: ChatWorkspaceRequest) async throws -> ChatWorkspace {
        try await run(request.subject, RunnerDispatch.chatTarget(subject: request.subject, session: request.session)) {
            try await $0.workspace(request)
        }
    }

    func send(_ input: ChatTurnInput, subject: ChatSubject, logURL: URL,
              onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ChatTurnOutput {
        // Where `workspace` prepared it (Respond: the analysis' host).
        let target: RunnerDispatch.ChatTarget = if case .respond(let draft) = subject { .pinned(draft.runner) } else { .pinned(input.runner) }
        return try await run(subject, target) { try await $0.send(input, subject: subject, logURL: logURL, onEvent: onEvent) }
    }

    func sendEditing(_ input: ChatTurnInput, draft: RespondDraft, result: RespondResult, sessionID: UUID, logURL: URL,
                     onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> (ChatTurnOutput, ChatFilesOutcome) {
        let output = try await run(.respond(draft), .pinned(draft.runner)) {
            Pair(try await $0.sendEditing(input, draft: draft, result: result, sessionID: sessionID, logURL: logURL, onEvent: onEvent))
        }
        return output.value
    }

    func undoFiles(draft: RespondDraft, snapshot: ChatFileSnapshot, logURL: URL) async throws -> RespondResult {
        try await run(.respond(draft), .pinned(draft.runner), needsClaude: false) {
            try await $0.undoFiles(draft: draft, snapshot: snapshot, logURL: logURL)
        }
    }

    func filesChangedSince(draft: RespondDraft, snapshot: ChatFileSnapshot) async -> Bool {
        (try? await run(.respond(draft), .pinned(draft.runner), needsClaude: false) {
            await $0.filesChangedSince(draft: draft, snapshot: snapshot)
        }) ?? true
    }

    func cleanup(session: ChatSession, subject: ChatSubject, localPath: String?) async {
        let target = RunnerDispatch.chatTarget(subject: subject, session: session)
        // A Review/Merge chat without a worktree has nothing to clean up (and no reason to reach a host).
        guard target != .repoDestination else { return }
        do {
            try await run(subject, target, needsClaude: false) { await $0.cleanup(session: session, subject: subject, localPath: localPath) }
        } catch {
            AppLog.write("Chat: couldn’t clean up \(session.worktreePath ?? "the chat’s files"): \(error.localizedDescription)")
        }
    }
}

/// A tuple isn't `Sendable`-checked as a generic result: this carries `sendEditing`'s pair.
private struct Pair<A: Sendable, B: Sendable>: Sendable {
    let value: (A, B)
    init(_ value: (A, B)) { self.value = value }
}
