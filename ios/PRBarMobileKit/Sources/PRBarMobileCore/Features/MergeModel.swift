import Foundation
import Observation
import PRBarWire

/// `merge`, `merge:faceid`, `merge:merged` (design §merge).
@MainActor @Observable
public final class MergeModel {
    public struct ReviewerRow: Identifiable, Equatable, Sendable {
        public var id: String { login }
        public var login: String
        public var name: String
        public var state: String
        public var approved: Bool
    }

    public let pr: String
    public let connection: RemoteConnection
    public private(set) var preview: MergePreviewInfo?
    public var method: MergeMethod = .squash
    public private(set) var merged: MergeInfo?
    public private(set) var isMerging = false
    public private(set) var isLoading = false
    public var alert: String?
    public private(set) var needsRepair = false
    @ObservationIgnored private let runner: ActionRunner

    public init(pr: String, connection: RemoteConnection, runner: ActionRunner) {
        self.pr = pr
        self.connection = connection
        self.runner = runner
    }

    public var isOffline: Bool { connection.store.isStale }
    public var detail: MergeDetail? { preview?.detail }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let info = try await runner.run(.mergePreview(pr: pr, method: nil)).decoded(MergePreviewInfo.self)
            preview = info
            method = info.method
        } catch {
            alert = error.message
        }
    }

    // MARK: Summary rows

    public func displayName(_ login: String) -> String { connection.store.home?.people?[login] ?? login }

    public var reviewers: [ReviewerRow] {
        (detail?.reviews ?? []).map {
            ReviewerRow(login: $0.author, name: displayName($0.author), state: $0.state.title,
                        approved: $0.state == .approved)
        }
    }

    public var checksText: String {
        guard let detail else { return "—" }
        let failed = detail.checks.filter { $0.state == .failed }.count
        let running = detail.checks.filter { $0.state == .running }.count
        if failed > 0 { return "\(failed) failing" }
        if running > 0 { return "\(running) running" }
        return "✓ \(detail.checks.filter { $0.state == .passed }.count) passing"
    }

    public var checksPassing: Bool {
        guard let detail else { return false }
        return !detail.checks.contains { $0.state == .failed || $0.state == .running }
    }

    public var conversationsText: String {
        guard let unresolved = detail?.unresolvedThreads, unresolved > 0 else { return "None" }
        return "\(unresolved) unresolved"
    }

    public var filesText: String { "\(detail?.changedFiles ?? 0) changed" }

    public func methodNote(_ method: MergeMethod) -> String {
        let base = preview?.baseRef ?? "main"
        let count = preview?.commitCount ?? detail?.commitCount ?? 0
        switch method {
        case .squash:
            return "\(Format.count(count, "commit")) become\(count == 1 ? "s" : "") one commit on \(base)."
        case .merge:
            return "Adds a merge commit and keeps all \(Format.count(count, "commit"))."
        case .rebase:
            return "Replays the \(Format.count(count, "commit")) on top of \(base)."
        }
    }

    // MARK: Merge

    public var canMerge: Bool { preview != nil && preview?.problem == nil && !isMerging && !isOffline }

    /// Face ID, then `merge` with the head the preview showed: if the PR moved, the Mac refuses.
    public func merge() async {
        guard let preview, !isMerging else { return }
        isMerging = true
        defer { isMerging = false }
        do {
            let result = try await runner.run(
                .merge(pr: pr, method: method, confirmed: true, expectedHeadOid: preview.headOid),
                reason: "Merge \(pr)")
            merged = try result.decoded(MergeInfo.self)
        } catch .presenceCancelled {
            return
        } catch .presenceKeyInvalid {
            needsRepair = true
        } catch {
            alert = error.message
            // The head changed (or something else moved): show what is there now.
            await load()
        }
    }

    public func dismissError() async {
        do { try await runner.run(.mergeDismiss(pr: pr)) } catch { alert = error.message }
    }

    public var mergedMessage: String {
        let ref = Format.shortRef(pr)
        let base = preview?.baseRef ?? "main"
        switch merged?.method ?? method {
        case .squash: return "\(ref) was squashed into \(base)."
        case .merge: return "\(ref) was merged into \(base)."
        case .rebase: return "\(ref) was rebased onto \(base)."
        }
    }
}
