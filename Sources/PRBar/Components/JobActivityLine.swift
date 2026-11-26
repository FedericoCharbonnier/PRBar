import PRBarCore
import SwiftUI

/// The step a running job is on (spec LP.5), under a PR's row: "Analyzing · Reading src/shop/tax.py", small and gray,
/// truncated in the middle. It observes only the feed: two changes a second don't redraw the rest of the row.
struct JobActivityLine: View {
    @ObservedObject var feed: JobActivityFeed
    let prID: String
    /// "Analyzing" (`ReviewPhase.stepTitle`, `RespondPhase.stepTitle`).
    let phase: String

    var body: some View {
        if let activity = feed.current[prID] {
            Text("\(phase) · \(activity.text)")
                .font(.caption)
                // A plain color, like `PlacementLabel`: `.secondary` drew black under a toolbar in Dark Mode.
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(activity.text)
                .accessibilityLabel("Now: \(activity.text)")
        }
    }
}

/// The step line of a row: its review's (PRs to review) or its Respond slot's (my PRs: Respond, Fix CI, Resolve
/// Conflicts). Nothing while nothing runs.
struct JobActivityRowLine: View {
    let item: ClassifiedPR
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue

    var body: some View {
        if let title = reviews.phases[item.id]?.stepTitle {
            JobActivityLine(feed: reviews.activityFeed, prID: item.id, phase: title)
        } else if let title = respond.phases[item.id]?.stepTitle(mode: respond.mode(of: item.id),
                                                                runningTests: respond.runningTests.contains(item.id)) {
            JobActivityLine(feed: respond.activityFeed, prID: item.id, phase: title)
        }
    }
}

/// Under the progress indicator of the PR window's tabs (spec LP.5): "Reading src/shop/tax.py · 12 s", every second.
struct JobActivityDetail: View {
    @ObservedObject var feed: JobActivityFeed
    let prID: String

    var body: some View {
        if let activity = feed.current[prID] {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(activity.text) · \(activity.elapsedText(now: context.date))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(activity.text)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
