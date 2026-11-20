import SwiftUI
import PRBarMobileCore

/// `home` / `home:mine` / `home:offline`.
public struct HomeScreen: View {
    let app: PhoneApp
    let tab: HomeModel.Tab

    public init(app: PhoneApp, tab: HomeModel.Tab) {
        self.app = app
        self.tab = tab
    }

    public var body: some View {
        ScrollView {
            HomeContent(model: app.home, tab: tab, open: open, act: act)
                .padding(.bottom, 100)
        }
        .background(Tokens.bg)
        .refreshable { await app.home.refresh() }
    }

    func open(_ row: HomeModel.Row) {
        app.push(app.defaultRoute(for: row.pr.id))
    }

    func act(_ row: HomeModel.Row, _ action: HomeModel.Action) {
        switch action {
        case .review:
            Task { await app.home.startReview(row.pr) }
            app.push(.review(row.pr.id))
        case .fixCI:
            Task { await app.home.fixCI(row.pr) }
            app.push(.respond(row.pr.id, .ciFix))
        default:
            app.push(app.defaultRoute(for: row.pr.id))
        }
    }
}

/// The scrollable content (also what the snapshot tool renders).
public struct HomeContent: View {
    let model: HomeModel
    let tab: HomeModel.Tab
    var open: (HomeModel.Row) -> Void = { _ in }
    var act: (HomeModel.Row, HomeModel.Action) -> Void = { _, _ in }

    public init(model: HomeModel, tab: HomeModel.Tab, open: @escaping (HomeModel.Row) -> Void = { _ in },
                act: @escaping (HomeModel.Row, HomeModel.Action) -> Void = { _, _ in }) {
        self.model = model
        self.tab = tab
        self.open = open
        self.act = act
    }

    public var body: some View {
        let sections = model.sections(tab)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                MacPill(name: model.macName, status: model.pillStatus, online: !model.isOffline,
                        accessibility: model.pillAccessibilityLabel)
                Spacer()
                GlassCircleButton("line.3.horizontal.decrease", label: "Filter") {}
            }
            Text(tab == .toReview ? "To Review" : "My PRs")
                .font(Typo.largeTitle)
                .foregroundStyle(Tokens.fg)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 4)
            if model.isOffline {
                OfflineCard(title: model.offlineTitle, message: model.offlineMessage) {
                    Task { await model.tryAgain() }
                }
            }
            if let error = model.lastError {
                NoticeBanner(error)
            }
            if sections.isEmpty {
                EmptyState(tab: tab)
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: section.title, count: section.rows.count, expanded: !model.isCollapsed(section),
                                  dimmed: model.isOffline || section.isQuiet) {
                        withAnimation(.snappy) { model.toggle(section) }
                    }
                    if !model.isCollapsed(section) {
                        VStack(spacing: 0) {
                            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Hairline(inset: Metrics.separatorInset) }
                                PRRowView(row: row, disabled: model.isOffline) { action in act(row, action) }
                                    .onTapGesture { open(row) }
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                        .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous))
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
    }
}

/// Same copy as the Mac popover's empty tabs (`PopoverTabs.emptyState`).
struct EmptyState: View {
    let tab: HomeModel.Tab

    var copy: (String, String) {
        switch tab {
        case .toReview: ("Nothing to review 🎉", "No PRs are waiting for your review.")
        case .mine: ("No PRs of yours need anything", "No new feedback and nothing ready to merge.")
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal").font(.system(size: 34)).foregroundStyle(Tokens.green)
            Text(copy.0).font(Typo.headline).foregroundStyle(Tokens.fg)
            Text(copy.1).font(Typo.body).foregroundStyle(Tokens.fg2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
