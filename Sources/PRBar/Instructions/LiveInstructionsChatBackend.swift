import Foundation
import PRBarCore

/// The app's instructions chat backend: reads claude's path and the chat's model in the main actor on every turn
/// (they can change in Settings), like `LiveChatBackend`.
struct LiveInstructionsChatBackend: InstructionsChatBackend {
    let context: @MainActor @Sendable () -> (claudePath: String?, model: ClaudeModel?)
    /// 5 s between SIGTERM and SIGKILL, as in reviews.
    let runner = SystemProcessRunner(killGracePeriod: 5)

    func send(_ input: InstructionsTurnInput,
              onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> InstructionsTurnOutput {
        let (claudePath, model) = await context()
        guard let claudePath else { throw PRBarError.toolNotFound("claude") }
        return try await InstructionsChatService(streamingRunner: runner, claudePath: claudePath, model: model)
            .send(input, onEvent: onEvent)
    }
}
