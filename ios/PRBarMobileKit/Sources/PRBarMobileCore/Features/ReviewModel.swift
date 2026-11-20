import Foundation
import Observation
import PRBarWire

/// `review`, `review:menu`, `review:faceid`, `edit`, `review:posted` (design §review, §edit).
@MainActor @Observable
public final class ReviewModel {
    public enum Decision: String, CaseIterable, Sendable, Identifiable {
        case comment, requestChanges, approve

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .comment: "Comment"
            case .requestChanges: "Request Changes"
            case .approve: "Approve"
            }
        }
        public var symbol: String {
            switch self {
            case .comment: "text.bubble"
            case .requestChanges: "exclamationmark.triangle"
            case .approve: "checkmark.circle"
            }
        }
        public var event: ReviewEvent {
            switch self {
            case .comment: .comment
            case .requestChanges: .requestChanges
            case .approve: .approve
            }
        }
        /// Spec V.1: only Approve asks for Face ID.
        public var needsFaceID: Bool { self == .approve }
    }

    /// What `review:posted` shows.
    public struct Posted: Equatable, Sendable {
        public var decision: Decision
        public var comments: Int
        public var url: URL
        public var macName: String

        public var headline: String { "Review posted" }
        public func message(prRef: String) -> String {
            let verb = switch decision {
            case .approve: "Approved"
            case .requestChanges: "Requested changes on"
            case .comment: "Commented on"
            }
            return "\(verb) \(prRef) with \(Format.count(comments, "comment"))."
        }
    }

    public let pr: String
    public var decision: Decision = .comment
    public private(set) var posted: Posted?
    public private(set) var isPosting = false
    public var alert: String?
    /// "Face ID changed": the re-pair screen.
    public private(set) var needsRepair = false
    /// Local values while the Mac's `pr:` state catches up (toggles feel instant).
    @ObservationIgnored private var includedOverrides: [String: Bool] = [:]
    private var overridesVersion = 0

    public let connection: RemoteConnection
    @ObservationIgnored private let runner: ActionRunner

    public init(pr: String, connection: RemoteConnection, runner: ActionRunner) {
        self.pr = pr
        self.connection = connection
        self.runner = runner
    }

    public var topic: String { Topic.pr(pr) }
    public func appear() async { await connection.retain(topic) }
    public func disappear() async { await connection.release(topic) }

    public var detail: RemotePRDetail? { connection.store.detail(for: pr) }
    public var info: PRInfo? { detail?.pr ?? connection.store.home?.prs.first { $0.id == pr } }
    public var review: ReviewInfo? { detail?.review }
    public var isOffline: Bool { connection.store.isStale }

    public var authorName: String {
        guard let author = info?.author else { return "" }
        return connection.store.home?.displayName(author) ?? author
    }

    public var isRunning: Bool {
        guard let phase = review?.phase else { return false }
        return ["queued", "preparing", "reviewing", "filtering"].contains(phase)
    }

    public var canPost: Bool { review?.phase == "ready" && !isPosting && !isOffline }

    /// The findings as the Mac numbers them, with local toggles applied.
    public var findings: [FindingInfo] {
        _ = overridesVersion
        return (review?.findings ?? []).filter { $0.hiddenBy == nil }.map { finding in
            var copy = finding
            if let included = includedOverrides[finding.id] { copy.included = included }
            return copy
        }
    }

    public var includedSummary: String {
        let all = findings
        return "\(all.filter(\.included).count) of \(all.count) included"
    }

    public var includedCount: Int { findings.filter(\.included).count }

    // MARK: Actions

    public func startReview() async {
        await perform(.reviewStart(pr: pr, wait: false))
    }

    public func cancelReview() async {
        await perform(.reviewCancel(pr: pr))
    }

    public func dismissReview() async {
        await perform(.reviewDismiss(pr: pr))
    }

    public func setIncluded(_ finding: FindingInfo, _ included: Bool) async {
        includedOverrides[finding.id] = included
        overridesVersion += 1
        await perform(.reviewSetIncluded(pr: pr, findings: [finding.id], all: false, included: included))
    }

    /// The `edit` sheet's Save.
    public func saveEdit(_ finding: FindingInfo, body: String) async -> Bool {
        await perform(.reviewEdit(pr: pr, finding: finding.id, title: nil, body: body))
    }

    public func setGeneralComment(_ text: String) async {
        await perform(.reviewSetComment(pr: pr, text: text))
    }

    /// The bottom bar's Post: Face ID first for Approve (`review:faceid`), then `reviewPublish` with `confirmed`.
    public func post() async {
        guard !isPosting else { return }
        isPosting = true
        defer { isPosting = false }
        let chosen = decision
        do {
            let result = try await runner.run(
                .reviewPublish(pr: pr, event: chosen.event, only: nil, withComments: true, allInBody: false,
                               confirmed: true),
                reason: "Approve \(pr)")
            let published = try result.decoded(PublishedReviewInfo.self)
            posted = Posted(decision: chosen, comments: published.comments, url: published.url,
                            macName: connection.macName ?? "your Mac")
        } catch {
            handle(error)
        }
    }

    public func finishPosted() {
        posted = nil
    }

    @discardableResult
    private func perform(_ command: AppCommand) async -> Bool {
        do {
            try await runner.run(command)
            return true
        } catch {
            handle(error)
            return false
        }
    }

    private func handle(_ error: ActionError) {
        switch error {
        case .presenceCancelled: break
        case .presenceKeyInvalid: needsRepair = true
        default: alert = error.message
        }
    }
}
