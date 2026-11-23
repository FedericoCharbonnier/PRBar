import AppKit
import PRBarCore
import SwiftUI

/// La pestaña Review de un PR ajeno (spec M.1 "Review"): antes de la review, el estado del PR y Start Review; mientras
/// corre, el progreso; lista, el editor; publicada, la review publicada.
struct ReviewPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var reviews: ReviewQueue
    let prID: String
    /// El modo de capturas abre los descartados y un hallazgo desplegado; la app, nunca.
    @Environment(\.reviewEditorInitialState) private var initialState

    init(model: AppModel, prID: String) {
        self.model = model
        reviews = model.reviews
        self.prID = prID
    }

    var body: some View {
        switch reviews.phases[prID] {
        case .ready(let draft)?:
            ReviewEditor(model: model, draft: draft, chat: model.reviewChat(for: draft), published: nil, close: nil,
                         initialState: initialState)
                .id(draft.id)
        case .published?:
            if let record = model.publishedReviewRecord(prID: prID) {
                ReviewEditor(model: model, draft: record.draft, chat: model.reviewChat(for: record.draft),
                             published: PublishedReview(record: record), close: nil)
                    .id(record.id)
            } else {
                ReviewStartView(model: model, prID: prID)
            }
        case let phase? where phase.isActive:
            ReviewProgressView(model: model, prID: prID, phase: phase)
        default:
            ReviewStartView(model: model, prID: prID)
        }
    }
}

/// El encabezado de la pestaña para un PR de la lista (sin draft todavía).
@MainActor
private func reviewHeader(_ item: ClassifiedPR, model: AppModel) -> some View {
    let pr = item.pr
    let draft = ReviewDraft(prID: item.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url, author: pr.author,
                            headOid: pr.headOid, account: item.account, summary: "", items: [])
    return ReviewHeader(draft: draft, pr: pr, placement: model.placements.label(prID: item.id))
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
}

/// Antes de la review: el estado del PR, el error si la anterior falló y Start Review.
private struct ReviewStartView: View {
    @ObservedObject var model: AppModel
    let prID: String

    var body: some View {
        if let item = model.currentItem(prID) {
            VStack(alignment: .leading, spacing: 0) {
                reviewHeader(item, model: model)
                Divider()
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(Theme.violet)
                        .accessibilityHidden(true)
                    Text(status(item)).font(.title3.weight(.semibold))
                    // The review posted before the PR's latest commits (the Review tab shows Start Review again).
                    if let previous = model.publishedReviewRecord(prID: prID)?.reviewURL {
                        ExternalLink("Your previous review", destination: previous)
                            .font(.callout)
                    }
                    HStack(spacing: 6) {
                        CIIcon(state: item.pr.ciState)
                        Text(CIIcon.label(for: item.pr.ciState) ?? "No CI")
                        if item.pr.isDraft {
                            Text("·").foregroundStyle(.tertiary)
                            Text("Draft")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    if case .failed(let message, let logURL)? = model.reviews.phases[prID] {
                        VStack(spacing: 6) {
                            ErrorBanner(messages: [message])
                            if let logURL {
                                Button("Show Log") { NSWorkspace.shared.open(logURL) }
                                    .controlSize(.small)
                            }
                        }
                        .frame(maxWidth: 520)
                    }
                    Button("Start Review") { model.startReview(item) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.jobsBlockedReason != nil)
                        .help(model.jobsBlockedReason ?? "Review this PR with Claude")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            }
        } else {
            MessageView(icon: "questionmark.folder", title: "This PR is no longer in your list",
                        text: "There’s no review of it to show.")
                .frame(maxHeight: .infinity)
        }
    }

    private func status(_ item: ClassifiedPR) -> String {
        switch item.category {
        case .updatedSinceMyReview: "Updated since your review"
        case .toReview: "Waiting for your review"
        default: "Not reviewed with Claude yet"
        }
    }
}

/// Mientras corre: "Queued…" o "Reviewing with N agents · 1:12", y Cancel.
private struct ReviewProgressView: View {
    @ObservedObject var model: AppModel
    let prID: String
    let phase: ReviewPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = model.currentItem(prID) {
                reviewHeader(item, model: model)
                Divider()
            }
            VStack(spacing: 14) {
                Spacer()
                ProgressView().controlSize(.large).tint(Theme.violet)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(text(now: context.date))
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
                Button("Cancel") { model.cancelReview(prID: prID) }
                    .help("Stop the review (what Claude did so far is lost)")
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    private func text(now: Date) -> String {
        let clock = model.reviewRuns[prID].map { " · " + ClaudeTasksSidebar.clock(now.timeIntervalSince($0.startedAt)) } ?? ""
        switch phase {
        case .queued: return "Queued…"
        case .preparing: return "Preparing the review…" + clock
        case .reviewing(let agents): return "Reviewing with \(agents) agent\(agents == 1 ? "" : "s")" + clock
        case .filtering: return "Filtering the findings…" + clock
        default: return "Reviewing…"
        }
    }
}

private struct ReviewEditorInitialStateKey: EnvironmentKey {
    static let defaultValue = ReviewEditor.InitialState()
}

extension EnvironmentValues {
    var reviewEditorInitialState: ReviewEditor.InitialState {
        get { self[ReviewEditorInitialStateKey.self] }
        set { self[ReviewEditorInitialStateKey.self] = newValue }
    }
}
