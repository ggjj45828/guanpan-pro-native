import SwiftUI

/// 持仓周期：这只标的我一共拿了几轮，每轮赚了多少、拿了几天。
///
/// 存在的理由：卖出之后原页面只剩一个「已实现盈亏」数字，看不出它是几轮累积的。
/// 一轮 = 从起点（或第一次买入）到份额清零；清零后再买就是新的一轮。
struct EpisodeView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    @State private var expanded: Set<String> = []
    @State private var showClosedOnly = false

    private var palette: DsPalette { DsPalette.of(store.resolvedAppearance) }

    private var projection: EpisodeProjection.Result {
        EpisodeProjection.build(from: store.data)
    }

    private var instruments: [InstrumentEpisodes] {
        let all = projection.instruments
        guard showClosedOnly else { return all }
        return all.filter { !$0.closedEpisodes.isEmpty }
    }

    private var totalEpisodes: Int { projection.instruments.reduce(0) { $0 + $1.episodes.count } }
    private var activeEpisodes: Int { projection.instruments.reduce(0) { $0 + ($1.activeEpisode == nil ? 0 : 1) } }
    private var closedEpisodes: Int { projection.instruments.reduce(0) { $0 + $1.closedEpisodes.count } }
    private var lifetimeRealized: Double { projection.instruments.reduce(0) { $0 + $1.lifetimeRealized } }
    private var lifetimeFees: Double { projection.instruments.reduce(0) { $0 + $1.lifetimeFees } }

    private var closedDays: [Int] {
        projection.instruments.flatMap { $0.closedEpisodes }.compactMap { $0.days() }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    heroCard
                    if instruments.isEmpty {
                        emptyCard
                    } else {
                        filterBar
                        ForEach(instruments) { instrument in
                            instrumentCard(instrument)
                        }
                    }
                    if !projection.warnings.isEmpty {
                        warningCard
                    }
                    disclaimerCard
                }
                .padding(.horizontal, DS.pageInset)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(palette.canvas.ignoresSafeArea())
            .navigationTitle("持仓周期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .themedSheetBackground()
    }

    // MARK: 总览

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("累计已实现")
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
            Text(lifetimeRealized.cny())
                .scaledFont(DS.fsHero, weight: .bold, design: .rounded)
                .monospacedDigit()
                .foregroundStyle(lifetimeRealized >= 0 ? PnLColor.up : PnLColor.down)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 16) {
                stat("周期", "\(totalEpisodes)")
                stat("进行中", "\(activeEpisodes)")
                stat("已了结", "\(closedEpisodes)")
                stat("费用", lifetimeFees.cny())
            }

            if !closedDays.isEmpty {
                let average = Double(closedDays.reduce(0, +)) / Double(closedDays.count)
                Text("已了结周期的平均持有时间 \(Int(average.rounded())) 天 · 最长 \(closedDays.max() ?? 0) 天 · 最短 \(closedDays.min() ?? 0) 天")
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: DS.heroRadius, padding: 18, glow: palette.accent)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).scaledFont(9.5).foregroundStyle(palette.ink3)
            Text(value)
                .scaledFont(DS.fsRow, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(palette.ink)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            chip("全部", on: !showClosedOnly) { showClosedOnly = false }
            chip("只看有已了结的", on: showClosedOnly) { showClosedOnly = true }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .scaledFont(DS.fsLabel, weight: .medium)
                .foregroundStyle(on ? palette.ink : palette.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background { Capsule().fill(on ? palette.cardSoft : Color.clear) }
                .overlay { Capsule().strokeBorder(palette.hairline, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    // MARK: 单只标的

    private func instrumentCard(_ instrument: InstrumentEpisodes) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(instrument.name)
                    .scaledFont(DS.fsTitle, weight: .semibold)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(instrument.code)
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink3)
                Text(instrument.kind == .fund ? "场外" : "场内")
                    .scaledFont(9.5, weight: .semibold)
                    .foregroundStyle(palette.ink2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background { Capsule().fill(palette.cardSoft) }
                Spacer(minLength: 4)
                Text("\(instrument.episodes.count) 轮")
                    .scaledFont(DS.fsMicro, weight: .medium)
                    .foregroundStyle(palette.ink3)
            }

            HStack(spacing: 16) {
                stat("累计已实现", instrument.lifetimeRealized.cny())
                if let active = instrument.activeEpisode {
                    stat("本轮成本", active.averageCost.num(3))
                    if let unrealized = active.unrealized(currentPrice: instrument.currentPrice) {
                        stat("本轮浮动", unrealized.cny())
                    }
                }
                Spacer(minLength: 0)
            }

            if let rate = instrument.winRate {
                Text("已了结 \(instrument.wins) 胜 \(instrument.losses) 负 · 胜率 \(Int((rate * 100).rounded()))% · 平均持有 \(Int((instrument.averageClosedDays ?? 0).rounded())) 天")
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 周期列表：最近的在上面。
            VStack(spacing: 8) {
                ForEach(instrument.episodes.reversed()) { episode in
                    episodeRow(episode, price: instrument.currentPrice)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: DS.radius, padding: DS.pad)
    }

    private func episodeRow(_ episode: PositionEpisode, price: Double) -> some View {
        let isExpanded = expanded.contains(episode.id)
        let tone: Color = episode.realized > 0.01 ? PnLColor.up
            : (episode.realized < -0.01 ? PnLColor.down : palette.ink2)
        let unrealized = episode.unrealized(currentPrice: price)
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                Haptics.tap()
                if isExpanded { expanded.remove(episode.id) } else { expanded.insert(episode.id) }
            } label: {
                HStack(spacing: 8) {
                    Text("第 \(episode.number) 轮")
                        .scaledFont(DS.fsLabel, weight: .semibold)
                        .foregroundStyle(palette.ink)
                    Text(episode.isActive ? "进行中" : "已了结")
                        .scaledFont(9.5, weight: .semibold)
                        .foregroundStyle(episode.isActive ? palette.accent : palette.ink2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background { Capsule().fill(episode.isActive ? palette.accentDim : palette.cardSoft) }
                    Spacer(minLength: 4)
                    Text(episode.realized.cny())
                        .scaledFont(DS.fsLabel, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(tone)
                    if unrealized != nil {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(palette.ink3)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(palette.ink3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                Text(periodText(episode))
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink2)
                if let days = episode.days() {
                    Text("\(days) 天")
                        .scaledFont(DS.fsMicro)
                        .foregroundStyle(palette.ink3)
                }
                if !episode.historyComplete {
                    Text("买入记录不完整")
                        .scaledFont(9.5)
                        .foregroundStyle(CardTone.warn)
                }
                Spacer(minLength: 0)
            }

            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(episode.trades) { trade in
                        tradeRow(trade)
                    }
                    if let unrealized {
                        HStack(spacing: 6) {
                            Text("本轮浮动")
                                .scaledFont(DS.fsMicro)
                                .foregroundStyle(palette.ink3)
                            Spacer(minLength: 0)
                            Text(unrealized.cny())
                                .scaledFont(DS.fsMicro, weight: .semibold)
                                .monospacedDigit()
                                .foregroundStyle(unrealized >= 0 ? PnLColor.up : PnLColor.down)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("累计投入 \(episode.invested.cny()) · 费用 \(episode.fees.cny())")
                            .scaledFont(9.5)
                            .foregroundStyle(palette.ink3)
                        Spacer(minLength: 0)
                        if let rate = episode.returnRate(currentPrice: price) {
                            Text(rate.pct(2))
                                .scaledFont(9.5, weight: .semibold)
                                .monospacedDigit()
                                .foregroundStyle(PnLColor.of(rate))
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.cardSoft)
        }
    }

    private func tradeRow(_ trade: EpisodeTrade) -> some View {
        HStack(spacing: 6) {
            Text(trade.side == .buy ? (trade.isReinvest ? "红利再投" : "买入") : "卖出")
                .scaledFont(9.5, weight: .bold)
                .foregroundStyle(trade.side == .buy ? PnLColor.up : PnLColor.down)
            Text(Self.dayText(trade.date))
                .scaledFont(9.5)
                .monospacedDigit()
                .foregroundStyle(palette.ink3)
            Text("\(trade.quantity.num(2)) 份 @ \(trade.price.num(3))")
                .scaledFont(9.5)
                .monospacedDigit()
                .foregroundStyle(palette.ink2)
            Spacer(minLength: 0)
            if trade.side == .sell {
                Text(trade.realized.cny())
                    .scaledFont(9.5, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(trade.realized >= 0 ? PnLColor.up : PnLColor.down)
            } else {
                Text(trade.gross.cny())
                    .scaledFont(9.5)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink3)
            }
        }
    }

    private func periodText(_ episode: PositionEpisode) -> String {
        let start = episode.openedAt.map { Self.dayText($0) } ?? "建仓时间未知"
        guard let closedAt = episode.closedAt else { return "\(start) 至今" }
        return "\(start) → \(Self.dayText(closedAt))"
    }

    // MARK: 空态 / 提示

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有可以还原的持仓周期")
                .scaledFont(DS.fsRow, weight: .semibold)
                .foregroundStyle(palette.ink)
            Text("周期由「账本起点 + 逐笔成交」推算。先录入持仓或补一笔成交，这里才有东西可拆。")
                .scaledFont(DS.fsLabel)
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: DS.radius, padding: DS.pad)
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("数据提示")
                .scaledFont(DS.fsMicro, weight: .semibold)
                .foregroundStyle(CardTone.warn)
            ForEach(projection.warnings, id: \.self) { warning in
                Text("· \(warning)")
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: DS.radius, padding: 14)
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("口径")
                .scaledFont(DS.fsMicro, weight: .semibold)
                .foregroundStyle(palette.ink3)
            Text("一轮 = 从起点快照（或第一次买入）到份额清零；清零后再买重新计一轮。成本按加权平均逐笔递推，与「记一笔交易」的算法完全一致。账本起点之前的历史买入无法还原，所以第一轮会标成「买入记录不完整」，天数从起点快照那一刻开始算，不假装知道真实建仓日。")
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yy-MM-dd"
        return formatter.string(from: date)
    }
}
