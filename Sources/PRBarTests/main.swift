import Foundation
import PRBarCore

/// Los tests nunca escriben en ~/Library/Logs/PRBar/prbar.log.
enum TestEnvironment {
    static let logFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("prbar-tests-\(UUID().uuidString).log")
}
AppLog.setDestination(TestEnvironment.logFile)

let allTests: [TestCase] = []
    + SmokeTests.cases
    + ModelsTests.cases
    + ClassifierTests.cases
    + FormattingTests.cases
    + ConfigTests.cases
    + ProcessTests.cases
    + GitHubClientTests.cases
    + SnapshotTests.cases
    + NotificationPlannerTests.cases
    + AppLogTests.cases
    + SlackConfigTests.cases
    + SlackTemplatePreviewTests.cases
    + SlackPlannerTests.cases
    + SlackReviewReactionsTests.cases
    + SlackClientTests.cases
    + SlackAnnouncerTests.cases
    + SlackAntiDuplicateTests.cases
    + SlackSelfTestTests.cases
    + ReviewModelsTests.cases
    + ClaudeStreamTests.cases
    + WorktreeTests.cases
    + ClaudeRunnerTests.cases
    + ClaudeConnectorTests.cases
    + SlackConnectorParsingTests.cases
    + ClaudeReviewerTests.cases
    + ReviewContextTests.cases
    + ClaudeSkillsTests.cases
    + JobSchedulerTests.cases
    + ReviewQueueTests.cases
    + ReviewPublisherTests.cases
    + ReviewHistoryTests.cases
    + RespondModelsTests.cases
    + RespondConfirmationTests.cases
    + FeedbackAPITests.cases
    + WorktreeResolverTests.cases
    + RespondAnalyzerTests.cases
    + FixImplementerTests.cases
    + RespondPublisherTests.cases
    + RespondQueueTests.cases
    + PRLanguageTests.cases
    + ReviewSummaryTextTests.cases
    + SnapshotOptionsTests.cases
    + AppVersionTests.cases
    + SemanticVersionTests.cases
    + UpdateConfigTests.cases
    + ScriptTests.cases
    + UpdateCheckerTests.cases
    + UpdatePolicyTests.cases
    + UpdateSourceTests.cases
    + UpdateInstallTests.cases
    + UpdateSessionTests.cases
    + InFlightCounterTests.cases
    + ReleaseScriptTests.cases
    + ChatModelsTests.cases
    + ChatActionsTests.cases
    + ChatPromptsTests.cases
    + ChatEngineTests.cases
    + ChatServiceTests.cases
    + ChatCoordinatorTests.cases
    + PlaceholderTemplateTests.cases
    + FindingCategoryTests.cases
    + ClaudeOptionsTests.cases
    + RulesTests.cases
    + InstructionsStoreTests.cases
    + StagePromptsTests.cases
    + ReviewOptionsFilterTests.cases
    + FixTemplatesTests.cases
    + DependencyManifestsTests.cases
    + RespondPushGateTests.cases
    + InstructionsChatTests.cases
    + InstructionsChatCoordinatorTests.cases
    + DiscardStatsTests.cases
    + PromptFenceTests.cases
    + MergeModelsTests.cases
    + MergeConfigTests.cases
    + MergeDataTests.cases
    + ReadyToMergeTests.cases
    + ReadyToMergeNotificationTests.cases
    + MergePolicyTests.cases
    + MergeMutationTests.cases
    + MergeQueueTests.cases
    + MergeFlowTests.cases
    + SlackMergedTemplateTests.cases
    + SlackMergedReplyTests.cases
    + CLISmokeTests.cases
    + CLISupportTests.cases
    + CLIParsingTests.cases
    + CLIParityTests.cases
    + UIParityTests.cases
    + CLIIntegrationTests.cases
    + PRReferenceTests.cases
    + CommandProtocolTests.cases
    + AppCommandTests.cases
    + ReviewEditsCLITests.cases
    + CommandResultsTests.cases
    + CommandDispatcherTests.cases
    + CommandServerTests.cases
    + MergeDetailTests.cases
    + MergeWindowTests.cases
    + MergeHistoryTests.cases
    + MergeChatTests.cases
    + PopoverTabsTests.cases
    + ProcessActivityTests.cases
    + ProcessSamplingTests.cases
    + DiskUsageTests.cases
    + DiskCleanupTests.cases

let filter = CommandLine.arguments.dropFirst().first
let selected = allTests.filter { test in
    guard let filter else { return true }
    return test.name.localizedCaseInsensitiveContains(filter)
}

var failures = 0
for test in selected {
    do {
        try await test.body()
        print("✓ \(test.name)")
    } catch {
        failures += 1
        print("✗ \(test.name)\n    \(error)")
    }
}
print("\n\(selected.count - failures)/\(selected.count) passed")
exit(failures == 0 ? 0 : 1)
