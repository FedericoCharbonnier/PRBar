import SwiftUI
import PRBarMobileCore
import PRBarWire
import PRBarRemoteKit

/// The screens the snapshot tool renders (`swift run PRBarMobileSnapshots`), by design screen id, with the design's
/// sample data. Scroll views and system menus don't draw into an image, so this composes each screen's content and
/// bottom bar directly in a 393 × 852 frame.
@MainActor
public enum Snapshots {
    static let phone: CGFloat = 852

    public static func all() async -> [(String, AnyView, CGFloat?)] {
        let app = PhoneApp.demo(now: { Sample.now })
        let offline = PhoneApp.demo(online: false, now: { Sample.now })
        await Task.yield()
        var shots: [(String, AnyView, CGFloat?)] = [("styleguide", AnyView(StyleGuideView()), nil)]

        func add<V: View>(_ id: String, _ view: V, height: CGFloat? = phone) {
            shots.append((id.replacingOccurrences(of: ":", with: "_"), AnyView(view), height))
        }

        /// Content cut to the phone's height with the bottom bar pinned over it.
        func screen<C: View, B: View>(_ content: C, _ bar: B) -> some View {
            ZStack(alignment: .bottom) {
                content.frame(height: phone, alignment: .top).clipped()
                bar
            }
            .frame(height: phone)
        }

        // Pairing
        add("pair:welcome", PairWelcome(message: nil) {})
        add("pair:scan", PairScan(error: nil, joiningMac: nil, cancel: {}, scanned: { _ in }))
        add("pair:confirm", PairConfirm(macName: Sample.macName, relayHost: "relay.example.com",
                                        replacing: "Studio Mac", pair: {}, cancel: {}))
        add("pair:paired", PairPaired(macName: Sample.macName, code: "482 913", waiting: false, match: {}, dontMatch: {}))

        // Home
        add("home", HomeContent(model: app.home, tab: .toReview))
        let mine = app.home
        mine.collapsed = [PopoverSection.waitingForReview.rawValue]
        add("home:mine", HomeContent(model: mine, tab: .mine))
        add("home:offline", HomeContent(model: offline.home, tab: .toReview))

        // Review
        let review = app.reviewModel("acme/api#317")
        review.decision = .approve
        add("review", screen(ReviewContent(model: review), ReviewBottomBar(model: review)))
        add("review-full", ReviewContent(model: review), height: nil)
        add("edit", EditCommentContent(finding: Sample.findings[0], position: 1, total: 4,
                                       text: .constant(Sample.findings[0].body), discard: {}, save: {}).background(Tokens.sheet))
        let posting = app.reviewModel("acme/api#317")
        posting.decision = .approve
        await posting.post()
        if let posted = posting.posted {
            add("review:posted", ReviewPostedView(posted: posted, prRef: "api#317") {})
        }

        // Respond and Fix CI
        let respond = app.respondModel("acme/web-app#475", .feedback)
        add("respond", screen(RespondContent(model: respond), RespondBottomBar(model: respond)))
        let fixci = app.respondModel("acme/web-app#488", .ciFix)
        add("respond:fixci", screen(RespondContent(model: fixci), RespondBottomBar(model: fixci)))
        let doneApp = PhoneApp.demo()
        doneApp.connection.store.apply(RemoteStateUpdate(topic: Topic.pr("acme/web-app#475"), rev: 99,
                                                         data: (try? JSONValue(encoding: Sample.detail475(phase: "readyToPush"))) ?? .null))
        let diff = doneApp.respondModel("acme/web-app#475", .feedback)
        await diff.loadDiff()
        add("respond:diff", screen(RespondDiffContent(model: diff), RespondBottomBar(model: diff)))
        add("respond-done", screen(RespondContent(model: diff), RespondBottomBar(model: diff)))

        // Merge
        let merge = app.mergeModel("acme/api#322")
        await merge.load()
        add("merge", MergeContent(model: merge).frame(maxHeight: .infinity, alignment: .top))
        let merged = app.mergeModel("acme/api#322")
        await merged.load()
        await merged.merge()
        add("merge:merged", MergedView(model: merged, close: {}, chat: {}))

        // Chat
        for (id, pr, kind) in [("chat:review", "acme/api#317", ChatModel.Kind.review),
                               ("chat:respond", "acme/web-app#475", .respond), ("chat:merge", "acme/api#322", .merge)] {
            let chat = app.chatModel(pr, kind)
            add(id, VStack(spacing: 0) {
                ChatHeader(model: chat)
                ChatMessages(model: chat)
                Spacer()
                ChatInput(model: chat)
            }.background(Tokens.bg2))
        }

        // Activity and Settings
        add("activity", ActivityContent(model: app.activityModel(), home: app.home).frame(maxHeight: .infinity, alignment: .top))
        let settings = app.settingsModel()
        await settings.load()
        add("settings", SettingsContent(model: settings).frame(maxHeight: .infinity, alignment: .top))
        return shots
    }
}
