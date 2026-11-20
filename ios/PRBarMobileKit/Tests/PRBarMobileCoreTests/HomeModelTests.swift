import Foundation
import Testing
import PRBarRemoteKit
import PRBarWire
@testable import PRBarMobileCore

@MainActor @Suite struct HomeModelTests {
    func model(_ env: TestEnv) -> HomeModel {
        HomeModel(connection: env.connection, runner: env.runner, now: { Sample.now },
                  locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/Montevideo")!)
    }

    @Test func toReviewSectionsFollowThePopoverOrder() async {
        let env = await TestEnv()
        let sections = model(env).sections(.toReview)
        #expect(sections.map(\.title) == ["To Review", "Updated Since My Review"])
        #expect(sections[0].rows.map(\.pr.id) == ["acme/web-app#491", "acme/api#317"])
        let first = sections[0].rows[0]
        #expect(first.meta == "web-app#491 · develop")
        #expect(first.age == "8 min")
        #expect(first.leading == .avatar(initials: "LM", colorIndex: Format.avatarIndex("lmendez", count: 8)))
        #expect(first.action == .review)
        let reviewing = sections[0].rows[1]
        #expect(reviewing.action == .reviewing)
        #expect(reviewing.status == .working("2 agents · on devbox"))
        #expect(sections[1].rows[0].action == .comments(4))
    }

    @Test func myPRsHaveFeedbackReadyCIFailingAndWaiting() async {
        let env = await TestEnv()
        let sections = model(env).sections(.mine)
        #expect(sections.map(\.title) == ["My PRs with Feedback", "Ready to Merge", "CI Failing", "Waiting for Review"])
        #expect(sections[0].rows[0].status == .changesRequested("Changes requested · 2 comments"))
        #expect(sections[0].rows[0].action == .respond)
        #expect(sections[1].rows[0].status == .approved("Approved by 2 · checks passing"))
        #expect(sections[1].rows[0].action == .merge)
        #expect(sections[2].rows.map(\.pr.id) == ["acme/web-app#488"])
        #expect(sections[2].rows[0].status == .checksFailed("2 checks failed"))
        #expect(sections[2].rows[0].action == .fixCI)
        #expect(sections[2].rows[0].leading == .state(.ciFailing))
        // The failing PR left Waiting for Review; the quiet section starts collapsed.
        #expect(sections[3].rows.count == 2)
        #expect(sections[3].isQuiet)
        #expect(model(env).isCollapsed(sections[3]))
    }

    @Test func tabCountsComeFromTheMac() async {
        let env = await TestEnv()
        #expect(model(env).count(.toReview) == 3)
        #expect(model(env).count(.mine) == 3)
    }

    @Test func togglingASectionCollapsesIt() async {
        let env = await TestEnv()
        let home = model(env)
        let section = home.sections(.toReview)[0]
        home.toggle(section)
        #expect(home.isCollapsed(section))
        home.toggle(section)
        #expect(!home.isCollapsed(section))
    }

    @Test func pullToRefreshSendsRefresh() async {
        let env = await TestEnv()
        await model(env).refresh()
        #expect(env.transport.sentCommands == [.refresh])
    }

    @Test func rowActionsSendTheirCommands() async {
        let env = await TestEnv()
        let home = model(env)
        await home.startReview(Sample.webApp491)
        await home.fixCI(Sample.webApp488)
        #expect(env.transport.sentCommands == [.reviewStart(pr: "acme/web-app#491", wait: false),
                                                .ciFix(pr: "acme/web-app#488", wait: false)])
    }

    @Test func offlineShowsTheBannerAndSendsNothing() async {
        let env = await TestEnv()
        await env.connection.handle(.link(.macOffline(since: nil)))
        let home = model(env)
        #expect(home.isOffline)
        await home.refresh()
        #expect(env.transport.sentCommands.isEmpty)
        #expect(home.offlineTitle == "Diego's MacBook Pro is offline or asleep")
        let message = home.offlineMessage.replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(message.hasSuffix("You're seeing cached data, and actions are off until your Mac is back."))
        #expect(message.hasPrefix("Last connected today at 9:38 AM."))
        #expect(home.pillStatus.replacingOccurrences(of: "\u{202F}", with: " ") == "Offline · last seen 9:38 AM")
    }

    @Test func onlinePillSaysUpdatedJustNow() async {
        let env = await TestEnv()
        #expect(model(env).pillStatus == "Connected · updated just now")
        #expect(model(env).pillAccessibilityLabel == "Diego's MacBook Pro, connected, updated just now")
    }

    @Test func failuresAreShown() async {
        let env = await TestEnv()
        env.transport.fail("refresh", CommandFailure(.failed, "GitHub is unreachable."))
        let home = model(env)
        await home.refresh()
        #expect(home.lastError == "GitHub is unreachable.")
    }
}
