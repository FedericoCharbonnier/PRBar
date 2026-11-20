import SwiftUI
import PRBarMobileCore

/// `activity`.
public struct ActivityScreen: View {
    let model: ActivityModel
    var home: HomeModel?

    public init(model: ActivityModel, home: HomeModel? = nil) {
        self.model = model
        self.home = home
    }

    public var body: some View {
        ScrollView {
            ActivityContent(model: model, home: home).padding(.bottom, 100)
        }
        .background(Tokens.bg)
        .task { await model.appear() }
        .onDisappear { Task { await model.disappear() } }
        .alert(model.alert ?? "", isPresented: .constant(model.alert != nil)) {
            Button("OK", role: .cancel) { model.alert = nil }
        }
    }
}

struct ActivityContent: View {
    let model: ActivityModel
    var home: HomeModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let home {
                HStack {
                    MacPill(name: home.macName, status: home.pillStatus, online: !home.isOffline,
                            accessibility: home.pillAccessibilityLabel)
                    Spacer()
                }
            }
            Text("Activity").font(Typo.largeTitle).foregroundStyle(Tokens.fg).accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                ForEach(model.tiles) { tile in StatTile(tile: tile) }
            }
            if !model.running.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Running").font(Typo.headline).foregroundStyle(Tokens.fg)
                    Text("\(model.running.count)").font(.system(size: 15)).foregroundStyle(Tokens.fg2)
                }
                .padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(Array(model.running.enumerated()), id: \.element.id) { index, task in
                        if index > 0 { Hairline(inset: 62) }
                        HStack(spacing: 12) {
                            Circle().fill(Tokens.violetbg).frame(width: 34, height: 34).overlay { Spinner(size: 16) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: task.title).font(Typo.bodyBold).foregroundStyle(Tokens.fg)
                                Text(verbatim: task.subtitle).font(Typo.footnote.monospacedDigit()).foregroundStyle(Tokens.fg2)
                            }
                            Spacer()
                            SymbolCapsule("Stop", symbol: "stop.fill", foreground: Tokens.red, background: Tokens.redbg,
                                          height: 32) { Task { await model.stop(task) } }
                                .disabled(model.isOffline)
                        }
                        .padding(Metrics.rowPadding)
                    }
                }
                .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous))
            }
            if let total = model.monthTotal {
                Text("Claude this month").font(Typo.headline).foregroundStyle(Tokens.fg).padding(.top, 6)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(total).font(Typo.largeTitle).foregroundStyle(Tokens.fg)
                        Text(model.monthCaption).font(Typo.footnote).foregroundStyle(Tokens.fg2)
                    }
                    StackedBar(rows: model.costRows)
                    VStack(spacing: 0) {
                        ForEach(Array(model.costRows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Hairline() }
                            HStack(spacing: 10) {
                                Circle().fill(color(row.tone)).frame(width: 9, height: 9)
                                Text(row.title).font(Typo.body).foregroundStyle(Tokens.fg)
                                Text(verbatim: row.count).font(Typo.body).foregroundStyle(Tokens.fg2)
                                Spacer()
                                Text(verbatim: row.cost).font(Typo.bodyBold.monospacedDigit()).foregroundStyle(Tokens.fg)
                            }
                            .frame(minHeight: 40)
                        }
                    }
                }
                .card()
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
    }

    func color(_ tone: ActivityModel.CostRow.Tone) -> Token {
        switch tone {
        case .violet: Tokens.violet
        case .accent: Tokens.accentfg
        case .tertiary: Tokens.fg3
        }
    }
}

struct StackedBar: View {
    let rows: [ActivityModel.CostRow]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(rows) { row in
                    Rectangle().fill(color(row.tone)).frame(width: max(2, geo.size.width * row.fraction - 2))
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    func color(_ tone: ActivityModel.CostRow.Tone) -> Token {
        switch tone {
        case .violet: Tokens.violet
        case .accent: Tokens.accentfg
        case .tertiary: Tokens.fg3
        }
    }
}

struct StatTile: View {
    let tile: ActivityModel.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tile.title, systemImage: tile.symbol).font(Typo.footnoteBold).foregroundStyle(Tokens.fg2)
                .labelStyle(TightLabel())
            Text(verbatim: tile.value).font(Typo.headline).foregroundStyle(Tokens.fg).lineLimit(1).minimumScaleFactor(0.7)
            Text(verbatim: tile.caption ?? " ").font(Typo.caption).foregroundStyle(Tokens.fg2).lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tokens.fill)
                    Capsule().fill(color).frame(width: geo.size.width * tile.fraction)
                }
            }
            .frame(height: 5)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    var color: Token {
        switch tile.tone {
        case .green: Tokens.green
        case .orange: Tokens.orange
        case .accent: Tokens.accentfg
        }
    }
}
