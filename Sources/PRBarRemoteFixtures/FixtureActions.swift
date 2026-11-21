import Foundation
import PRBarCore
import PRBarRemoteMac

/// An `AppModel` stand-in with fixture PRs, for driving `RemoteAccessService` without GitHub or Claude: the iPhone's
/// end-to-end test (ios/PRBarMobileKit) pairs with it through the real relay. It keeps a little state (which findings
/// are included, what was approved and merged, the chat), records every call, and tells the service when something
/// changed (`onChange`) or when a chat streams text (`onChatText`, the Mac's `chatDelta`). Fictional data only.
@MainActor
public final class FixtureActions: PRBarActions {
    public private(set) var calls: [String] = []
    public var onChange: (() -> Void)?
    public var onChatText: ((_ pr: String, _ text: String) -> Void)?
    /// Pieces of Claude's answer to `chatSend`, streamed as `text` events (and as `chatDelta`, like the app).
    public var chatReply = ["Looking ", "at the ", "diff… ", "It only touches the session refresh path."]
    /// How long `chatSend` waits after streaming before it answers (lets a test look at the chat mid-run).
    public var chatHold: Duration = .zero

    public static let t0 = Date(timeIntervalSince1970: 1_795_178_280)
    public static let reviewPR = "acme/api#317"
    public static let mergePR = "acme/api#322"
    public static let ciPR = "acme/web-app#488"

    public private(set) var included: [String: Bool] = ["f1": true, "f2": true, "f3": false]
    public private(set) var approved: [String] = []
    public private(set) var merged: [String] = []
    public private(set) var chat: [ChatMessageInfo] = []

    public init() {}

    private func record(_ call: String) { calls.append(call) }
    private func changed() { onChange?() }
    private static func url(_ id: String) -> URL {
        let parts = id.split(separator: "#")
        return URL(string: "https://github.com/\(parts[0])/pull/\(parts[1])")!
    }
    private func missing(_ what: String) -> CommandFailure { CommandFailure(.invalidState, "Not in the fixture: \(what).") }

    // MARK: Fixture PRs

    public var prs: [PRInfo] {
        func pr(_ id: String, _ title: String, author: String, name: String?, section: PopoverSection, review: String? = nil,
                approvals: Int? = nil, files: Int, ci: String = "success") -> PRInfo {
            let parts = id.split(separator: "#")
            return PRInfo(id: id, repo: String(parts[0]), number: Int(parts[1])!, title: title, url: Self.url(id),
                          author: author, account: "diego", category: section.category.rawValue, baseRef: "main",
                          headRef: "feature/\(parts[1])", isDraft: false, ci: ci, additions: 46, deletions: 12,
                          updatedAt: Self.t0, review: review, merge: merged.contains(id) ? "merged" : nil,
                          tab: section.tab, section: section, authorName: name, approvals: approvals, changedFiles: files)
        }
        return [
            pr(Self.reviewPR, "Refresh expired sessions without logging users out", author: "truiz", name: "Tomás Ruiz",
               section: .toReview, review: approved.contains(Self.reviewPR) ? "published" : "ready", files: 5),
            pr(Self.mergePR, "Make payment retries idempotent", author: "diego", name: "Diego", section: .readyToMerge,
               approvals: 2, files: 4),
            pr(Self.ciPR, "Move report jobs to the new queue", author: "diego", name: "Diego", section: .waitingForReview,
               files: 3, ci: "failure"),
        ].filter { !merged.contains($0.id) }
    }

    private var findings: [FindingInfo] {
        [("f1", Severity.high, "Expired refresh tokens are retried forever"),
         ("f2", .medium, "Race between two refreshes"),
         ("f3", .low, "Cookie max-age is hard-coded")].enumerated().map { index, item in
            FindingInfo(number: index + 1, id: item.0, severity: item.1, location: "src/auth/session.ts:\(80 + index)",
                        title: item.2, body: "Body of \(item.2).", keptByFilter: true, filterReason: nil,
                        included: included[item.0] ?? false, edited: false)
        }
    }

    private func reviewInfo(_ pr: String) throws -> ReviewInfo {
        guard pr == Self.reviewPR, !approved.contains(pr) else { throw CommandFailure(.notFound, "No review of \(pr).") }
        return ReviewInfo(pr: pr, phase: "ready", detail: "2 agents", title: prs.first?.title,
                          summary: "Sessions refresh in the background.", outdated: false, findings: findings)
    }

    private func chatInfo(_ pr: String) -> ChatInfo {
        ChatInfo(pr: pr, kind: pr == Self.mergePR ? "merge" : "review", readOnly: pr == Self.mergePR, running: false,
                 lockReason: nil, messages: pr == Self.reviewPR ? chat : [])
    }

    // MARK: StatusActions
    public func status() async throws -> StatusInfo {
        record("status")
        return StatusInfo(appVersion: "1.9.0", fetchedAt: Self.t0, badgeCount: prs.count,
                          jobs: [JobInfo(pr: Self.ciPR, kind: "respond", phase: "implementing")])
    }
    public func listPRs(list: PRListFilter?, account: String?, tab: PopoverTab?) throws -> [PRInfo] { prs }
    public func resolvePR(_ pr: String) throws -> PRLink { PRLink(pr: pr, url: Self.url(pr)) }
    public func historyList(repo: String?, kind: HistoryKind?, limit: Int?, search: String?) -> [HistoryEntryInfo] { [] }
    public func historyShow(id: String) throws -> HistoryDetail { throw missing("history") }
    public func historyReopen(id: String) throws { throw missing("history") }
    public func refresh() async { record("refresh") }
    public func open(pr: String, target: OpenTarget) throws -> PRLink { PRLink(pr: pr, url: Self.url(pr)) }
    public func openSettings(tab: SettingsTabName?) {}
    public func openHistory(id: String?) throws {}
    public func quit() {}
    public func openPopover(tab: PopoverTab?) async -> PopoverInfo { PopoverInfo(tab: tab ?? .toReview, shown: true) }

    // MARK: ReviewActions
    public func reviewStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> ReviewInfo {
        record("reviewStart \(pr)"); return try reviewInfo(pr)
    }
    public func reviewShow(pr: String) throws -> ReviewInfo { try reviewInfo(pr) }
    public func reviewEdit(pr: String, finding: String, title: String?, body: String?) throws -> ReviewInfo { try reviewInfo(pr) }
    public func reviewSetIncluded(pr: String, findings: [String], all: Bool, included: Bool) throws -> ReviewInfo {
        record("reviewSetIncluded \(pr) \(findings.joined(separator: ",")) \(included)")
        for id in all ? Array(self.included.keys) : findings { self.included[id] = included }
        changed()
        return try reviewInfo(pr)
    }
    public func reviewSetComment(pr: String, text: String) throws -> ReviewInfo { try reviewInfo(pr) }
    public func reviewPublish(pr: String, event: ReviewEvent, only: [String]?, withComments: Bool,
                              allInBody: Bool) async throws -> PublishedReviewInfo {
        let comments = findings.filter(\.included).count
        record("reviewPublish \(pr) \(event.rawValue)")
        approved.append(pr)
        changed()
        return PublishedReviewInfo(pr: pr, url: Self.url(pr), action: event.rawValue, comments: comments, publishedAt: Self.t0)
    }
    public func reviewCancel(pr: String) throws { record("reviewCancel \(pr)") }
    public func reviewDismiss(pr: String) throws { record("reviewDismiss \(pr)") }

    // MARK: RespondActions
    private func respond(_ pr: String) throws -> RespondInfo { throw CommandFailure(.notFound, "No Respond for \(pr).") }
    public func respondStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo { try respond(pr) }
    public func respondShow(pr: String) throws -> RespondInfo { try respond(pr) }
    public func respondSelect(pr: String, items: [String], change: RespondSelectionChange) throws -> RespondInfo { try respond(pr) }
    public func respondReset(pr: String) throws -> RespondInfo { try respond(pr) }
    public func respondImplement(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo { try respond(pr) }
    public func respondTest(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo { try respond(pr) }
    public func respondDiff(pr: String) throws -> RespondDiff { throw missing("diff") }
    public func respondPush(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo { try respond(pr) }
    public func respondPushAnyway(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo { try respond(pr) }
    public func respondReplyOnly(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo { try respond(pr) }
    public func respondCancel(pr: String) throws { record("respondCancel \(pr)") }
    public func respondDismiss(pr: String) throws {}

    // MARK: MergeActions
    public static let mergeHead = "9f3c2a1"
    public func merge(pr: String, method: MergeMethod?, expectedHeadOid: String) async throws -> MergeInfo {
        guard pr == Self.mergePR, expectedHeadOid == Self.mergeHead else {
            throw CommandFailure(.invalidState, "The PR changed since you looked at it.")
        }
        record("merge \(pr) \(method?.rawValue ?? "default")")
        merged.append(pr)
        changed()
        return MergeInfo(pr: pr, method: method ?? .squash, mergedAt: Self.t0, url: Self.url(pr))
    }
    public func mergePreview(pr: String, method: MergeMethod?) async throws -> MergePreviewInfo {
        guard pr == Self.mergePR else { throw CommandFailure(.invalidState, "\(pr) isn’t ready to merge.") }
        return MergePreviewInfo(pr: pr, title: "Make payment retries idempotent", url: Self.url(pr), baseRef: "main",
                                headRef: "feature/322", headOid: Self.mergeHead, commitCount: 3, method: method ?? .squash,
                                deletesBranch: true)
    }
    public func mergeDismiss(pr: String) throws {}

    // MARK: ConfigActions
    public func configShow() -> AppConfig { AppConfig() }
    public func configSetRefreshInterval(minutes: Int) throws {}
    public func configSetLaunchAtLogin(enabled: Bool) throws {}
    public func accountList() -> [AccountInfo] { [] }
    public func accountSetEnabled(login: String, enabled: Bool) throws {}
    public func accountReload() async throws -> [AccountInfo] { [] }
    public func repoList(account: String?) throws -> [RepoInfo] {
        [RepoInfo(id: "acme/api", account: "diego", baseBranches: [], watchedUsers: [], slackChannel: "api-reviews",
                  ignorePaths: [])]
    }
    public func repoAvailable(account: String?, reload: Bool) async throws -> [String] { [] }
    public func repoAdd(repo: String, account: String?) async throws -> RepoInfo { throw missing("repos") }
    public func repoRemove(repo: String, account: String?) throws {}
    public func repoSet(repo: String, account: String?, changes: RepoChanges) async throws -> RepoInfo { throw missing("repos") }
    public func repoBranches(repo: String, account: String?, reload: Bool) async throws -> BranchesInfo { throw missing("repos") }
    public func followList(repo: String?, account: String?) throws -> [FollowInfo] { [] }
    public func followAdd(repo: String, users: [String], account: String?) async throws -> FollowInfo { throw missing("follow") }
    public func followRemove(repo: String, users: [String], account: String?) throws -> FollowInfo { throw missing("follow") }
    public func followSuggestions(repo: String, account: String?) async throws -> [UserSuggestionInfo] { [] }
    public func notifyList() async -> NotificationsInfo { NotificationsInfo(settings: NotificationSettings(), deniedInMacOS: false) }
    public func notifySet(kind: NotificationSettingName, enabled: Bool) throws { record("notifySet \(kind.rawValue) \(enabled)") }
    public func notifySetEnabled(enabled: Bool) throws {}
    public func claudeShow() -> ClaudeSettings { ClaudeSettings() }
    public func claudeSet(changes: ClaudeChanges) throws -> ClaudeSettings { ClaudeSettings() }
    public func claudeReset() throws -> ClaudeSettings { ClaudeSettings() }
    public func claudeSkillList() async -> [SkillInfo] { [] }
    public func toolsList() -> [ToolInfo] { [] }
    public func toolsSet(tool: ToolName, path: String?) async throws -> [ToolInfo] { record("toolsSet"); return [] }

    // MARK: SlackActions
    public func slackShow() -> SlackInfo {
        SlackInfo(enabled: true, provider: .userToken, connected: true, hasToken: true, needsUserToken: false,
                  toggles: [SlackToggleName.merged.rawValue: true], emojis: [:], searchDays: 7, issues: [])
    }
    public func slackSetEnabled(enabled: Bool) throws {}
    public func slackSetProvider(provider: SlackProvider) throws {}
    public func slackTokenSet(token: String) async throws -> SlackCheckInfo { throw missing("Slack") }
    public func slackTokenClear() throws {}
    public func slackSetToggle(toggle: SlackToggleName, enabled: Bool) throws {}
    public func slackSetEmoji(kind: SlackEmojiKind, name: String) throws {}
    public func slackSetSearchDays(days: Int) throws {}
    public func slackTemplateList() -> [TemplateInfo] { [] }
    public func slackTemplateSet(template: SlackTemplateName, text: String) throws {}
    public func slackTemplateReset(template: SlackTemplateName) throws {}
    public func slackCheck() async throws -> SlackCheckInfo { throw missing("Slack") }
    public func slackSelfTest() async throws -> [SelfTestStepInfo] { [] }
    public func slackChannels(reload: Bool) async throws -> [ChannelInfo] { [] }

    // MARK: ChatCommandActions
    public func chatSend(pr: String, message: String, events: CommandEventSink) async throws -> ChatInfo {
        record("chatSend \(pr) \(message)")
        chat.append(ChatMessageInfo(id: UUID(), role: "user", text: message, createdAt: Self.t0, changes: nil, undone: false,
                                    notes: [], undoable: false))
        for piece in chatReply {
            events(.text(delta: piece))
            // The app also streams every chat's text to whoever watches `pr:<id>` (spec Q.4).
            onChatText?(pr, piece)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: chatHold)
        chat.append(ChatMessageInfo(id: UUID(), role: "assistant", text: chatReply.joined(), createdAt: Self.t0,
                                    changes: nil, undone: false, notes: [], undoable: false))
        changed()
        return chatInfo(pr)
    }
    public func chatShow(pr: String) throws -> ChatInfo { chatInfo(pr) }
    public func chatUndo(pr: String, confirmed: Bool) async throws -> ChatInfo { chatInfo(pr) }
    public func chatStop(pr: String) throws -> ChatInfo { chatInfo(pr) }

    // MARK: UpdateCommandActions
    public func updateCheck() async throws -> UpdateInfo { UpdateInfo(installed: "1.9.0") }
    public func updateInstall(cancelJobs: Bool, events: @escaping CommandEventSink) async throws -> UpdateInfo { throw missing("updates") }
    public func updateCancel() throws {}
    public func updateSkip(version: String?) async throws -> UpdateInfo { UpdateInfo(installed: "1.9.0") }
    public func configSetUpdateInterval(hours: Int) throws {}

    // MARK: InstructionCommandActions
    public func rulesList(repo: String?) throws -> [RuleInfo] { [] }
    public func rulesAdd(text: String, scope: RuleScope, appliesTo: [RuleStage]) throws -> RuleInfo { throw missing("rules") }
    public func rulesEdit(id: String, text: String?, scope: RuleScope?, appliesTo: [RuleStage]?) throws -> RuleInfo { throw missing("rules") }
    public func rulesRemove(id: String) throws {}
    public func rulesSetEnabled(id: String, enabled: Bool) throws {}
    public func rulesChatSend(message: String, events: CommandEventSink) async throws -> ChatInfo { throw missing("rules") }
    public func rulesChatShow() -> ChatInfo { chatInfo("") }
    public func rulesChatUndo(confirmed: Bool) async throws -> ChatInfo { chatInfo("") }
    public func rulesChatStop() throws -> ChatInfo { chatInfo("") }
    public func rulesSuggestions() -> [RuleSuggestionInfo] { [] }
    public func rulesSuggestionAct(id: String, action: SuggestionAction, text: String?) throws -> [RuleInfo] { [] }
    public func chatProposal(pr: String, number: Int, save: Bool, text: String?, scope: RuleScope?,
                             appliesTo: [RuleStage]?) throws -> ChatInfo { chatInfo(pr) }
    public func claudeReviewSet(changes: ReviewOptionChanges) throws -> ClaudeSettings { ClaudeSettings() }
    public func claudeRespondSet(changes: RespondOptionChanges) throws -> ClaudeSettings { ClaudeSettings() }
    public func claudeStageSet(stage: PromptStage, change: StageChange) throws -> ClaudeSettings { ClaudeSettings() }
    public func claudePromptShow(stage: PromptStage) -> PromptInfo {
        PromptInfo(stage: stage, text: "", isDefault: true, requiredVariables: [])
    }
    public func claudePromptSet(stage: PromptStage, text: String) throws -> PromptInfo { throw missing("prompts") }
    public func claudePromptReset(stage: PromptStage) throws -> PromptInfo { throw missing("prompts") }

    // MARK: ResourceActions
    public func resources() async -> ResourcesInfo {
        ResourcesInfo(usage: ResourceUsage(cpuPercent: 12, memoryBytes: 300_000_000, processes: [], sampledAt: Self.t0),
                      disk: DiskUsage(items: [], scannedAt: Self.t0))
    }
    public func cleanupPreview(olderThanDays: Int?) async -> CleanupPlan { CleanupPlan(candidates: []) }
    public func cleanup(olderThanDays: Int?, confirmed: Bool, paths: [String]?) async throws -> CleanupResult { CleanupResult() }
    public func configSetDiskWarning(gigabytes: Int?) throws {}

    // MARK: RunnerActions
    public func runnersList() async -> [RunnerInfo] { [] }
    public func runnerAdd(host: String, name: String?, dir: String?, fallback: Bool) async throws -> RunnerInfo { throw missing("runners") }
    public func runnerSet(name: String, dir: String?, fallback: Bool?) async throws -> RunnerInfo { throw missing("runners") }
    public func runnerRemove(name: String) async throws {}
    public func runnerTest(name: String) async throws -> RunnerInfo { throw missing("runners") }
    public func runnerDefault(target: String) throws {}

    // MARK: CIFixUsageActions
    public func ciList() throws -> [CIListEntry] {
        [CIListEntry(pr: Self.ciPR, title: "Move report jobs to the new queue", url: Self.url(Self.ciPR), account: "diego",
                     phase: nil, respondInProgress: false, unavailableReason: nil, failedChecks: 2)]
    }
    public func ciFix(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo { try respond(pr) }
    public func usage(month: String?) throws -> UsageInfo {
        let review = ClaudeUsage(runs: 3, costUSD: 1.20)
        return UsageInfo(month: UsageMonth(month: "2026-11", usage: review, byKind: ["review": review]), tasks: [])
    }

    // MARK: RemoteActions (the phone never reaches these: RemotePolicy denies them)
    public func remoteStatus() -> RemoteStatusInfo {
        RemoteStatusInfo(enabled: true, relayHost: nil, state: "connected", devices: 0, devicesOnline: 0, keepAwake: false,
                         keepingAwake: false, mailbox: true, accountPrefix: nil)
    }
    public func remoteEnable(relay: String, enrollToken: String) async throws -> RemoteStatusInfo { throw missing("remote") }
    public func remoteDisable() async throws -> RemoteStatusInfo { throw missing("remote") }
    public func remotePairStart() async throws -> RemotePairingInfo { throw missing("remote") }
    public func remotePairWait(pairing: String, events: CommandEventSink) async throws -> RemotePairingInfo { throw missing("remote") }
    public func remotePairConfirm(pairing: String, accepted: Bool) async throws -> RemotePairResult { throw missing("remote") }
    public func remoteDevices() -> [RemoteDeviceInfo] { [] }
    public func remoteRevoke(device: String) async throws -> RemoteDeviceInfo { throw missing("remote") }
    public func remoteSetKeepAwake(enabled: Bool) throws -> RemoteStatusInfo { throw missing("remote") }
    public func remoteReset() async throws -> RemoteStatusInfo { throw missing("remote") }
    public func remoteSetPresenceRequirement(device: String, enabled: Bool) async throws -> RemoteDeviceInfo {
        record("remoteSetPresenceRequirement \(enabled)"); throw missing("remote")
    }
    public func remoteSetMailbox(enabled: Bool) async throws -> RemoteStatusInfo { throw missing("remote") }
}

/// `AppConfig.remote` in memory.
@MainActor
public final class MemoryRemoteSettingsStore: RemoteSettingsStore {
    public private(set) var remoteSettings = RemoteSettings()
    public init() {}
    public func updateRemoteSettings(_ mutate: (inout RemoteSettings) -> Void) throws { mutate(&remoteSettings) }
}
