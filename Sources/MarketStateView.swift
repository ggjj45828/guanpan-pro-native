import SwiftUI

/// 市场状态与账户战绩。
///
/// 把「现在大盘什么状态」「我这几轮做得到底怎么样」放在一页：
/// 这两件事必须一起看 —— 熊市里胜率高，和牛市里胜率高，含义完全不同。
struct MarketStateView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    @State private var regime: MarketRegimeAssessment?
    @State private var transitions: [MarketRegimeTransition] = []
    /// 因子表默认展开：这一页进来的目的就是看细节，藏起来要再点一次没有意义。
    @State private var expandedFactors = true
    @State private var expandedFactorKey: String?

    private var palette: DsPalette {
        DsPalette(isLight: AppTheme.palette(for: store.resolvedAppearance).isLight)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: palette.sectionGap) {
                    regimeCard
                    if let regime, !regime.reasons.isEmpty {
                        reasonCard(regime)
                    }
                    transitionCard
                    factorCard
                    realizedCard
                    intradayCard
                    disclaimer
                }
                .padding(.horizontal, palette.pageInset)
                .padding(.vertical, 14)
            }
            .background(palette.canvas.ignoresSafeArea())
            .navigationTitle("市场状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.tint(palette.accent)
                }
            }
            .onAppear {
                // 顺序不能反：marketRegime() 会先写入可能发生的新变更，
                // 之后读才拿得到刚记下的那条。
                regime = store.marketRegime()
                transitions = MarketRegimeStore.loadTransitions()
            }
        }
    }

    // MARK: 状态卡

    private var regimeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("上证指数")
                    .scaledFont(palette.fsLabel, weight: .medium)
                    .foregroundStyle(palette.ink2)
                Spacer(minLength: 4)
                if let regime {
                    Text(regime.riskLevel.title)
                        .scaledFont(9.5, weight: .semibold)
                        .foregroundStyle(riskTint(regime.riskLevel))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background {
                            Capsule().fill(riskTint(regime.riskLevel).opacity(palette.isLight ? 0.12 : 0.20))
                        }
                }
            }

            if let regime {
                Text(regime.regime.title)
                    .scaledFont(palette.fsHero, weight: .bold)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                HStack(spacing: 16) {
                    if let ret5 = regime.return5Sessions {
                        metric("近 5 日", ret5.pct(2), tone: PnLColor.of(ret5))
                    }
                    if let ret20 = regime.return20Sessions {
                        metric("近 20 日", ret20.pct(2), tone: PnLColor.of(ret20))
                    }
                    if let drawdown = regime.drawdown20Sessions {
                        metric("20 日回撤", drawdown.pct(2), tone: PnLColor.of(drawdown))
                    }
                }

                HStack(spacing: 6) {
                    Text("置信度 \(regime.confidenceLabel)")
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink3)
                    if let date = regime.dataAsOf {
                        Text("· 数据截至 \(MarketCalendar.isoDay(date))")
                            .scaledFont(palette.fsMicro)
                            .foregroundStyle(palette.ink3)
                    }
                    Spacer(minLength: 0)
                }

                if regime.observationOnly {
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                            .font(.system(size: 10, weight: .semibold))
                        Text("观察级别：可以据此调整节奏，不构成买卖指令")
                            .scaledFont(palette.fsMicro)
                    }
                    .foregroundStyle(palette.ink2)
                }
            } else {
                Text("日线不足")
                    .scaledFont(palette.fsHero, weight: .bold)
                    .foregroundStyle(palette.ink3)
                Text("至少需要 60 个交易日的上证指数日线。打开一次行情页并下滑刷新，让它把日 K 拉回来。")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.heroRadius, padding: 0)
    }

    private func metric(_ title: String, _ value: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scaledFont(9.5)
                .foregroundStyle(palette.ink3)
            Text(value)
                .scaledFont(palette.fsRow, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(tone)
        }
    }

    private func riskTint(_ level: MarketRiskLevel) -> Color {
        switch level {
        case .r0Normal: return palette.ink2
        case .r1Elevated: return PnLColor.up
        case .r2High, .r3Severe, .r4Extreme: return PnLColor.down
        }
    }

    // MARK: 判据

    private func reasonCard(_ regime: MarketRegimeAssessment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DsSectionHeader(palette: palette, title: "判据")
            VStack(alignment: .leading, spacing: 6) {
                // 不能用 `ForEach(Array(x.enumerated()), id: \.offset)` ——
                // Swift 的 key path 不能指向元组元素，那个写法编译不过。
                ForEach(regime.reasons.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(palette.ink3).frame(width: 3, height: 3).padding(.top, 6)
                        Text(regime.reasons[index])
                            .scaledFont(palette.fsMicro)
                            .foregroundStyle(palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: 状态变更

    /// 只列确认过的变更。pending 不进来 ——
    /// 防抖的整个意义就是不让「一根大阳线」进入结论，留痕也不该破例。
    private var transitionCard: some View {
        let recent = Array(transitions.suffix(8).reversed())
        return VStack(alignment: .leading, spacing: 8) {
            DsSectionHeader(palette: palette, title: "状态变更")
            if recent.isEmpty {
                Text("确认状态还没有变过。这里只在状态跨过防抖阈值时记一条 —— 记的是结论，不是每天的候选值。")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(recent) { item in
                        HStack(spacing: 10) {
                            Text(String(item.sessionKey.suffix(5)))
                                .scaledFont(palette.fsMicro)
                                .monospacedDigit()
                                .foregroundStyle(palette.ink3)
                                .frame(width: 36, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                if item.regimeChanged {
                                    Text("\(item.fromRegime.title) → \(item.toRegime.title)")
                                        .scaledFont(11.5, weight: .medium)
                                        .foregroundStyle(palette.ink)
                                }
                                if item.riskChanged {
                                    Text("R\(item.fromRisk.rawValue) → R\(item.toRisk.rawValue)")
                                        .scaledFont(9.5)
                                        .monospacedDigit()
                                        .foregroundStyle(item.isRiskUp ? PnLColor.up : palette.ink3)
                                }
                            }
                            Spacer(minLength: 4)
                            if item.isRiskUp {
                                Text("风险↑")
                                    .scaledFont(9.5, weight: .semibold)
                                    .foregroundStyle(PnLColor.up)
                            }
                        }
                        .padding(.vertical, 9)
                        if item.id != recent.last?.id {
                            Rectangle().fill(palette.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .dsSurface(palette, radius: 18, padding: 0)
                Text("风险上调要 2 个交易日确认，下调要 3 个 —— 所以它总是慢半拍地降级，这是刻意的不对称。")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 因子

    private var factorCard: some View {
        let factors = regime?.factors ?? []
        return VStack(alignment: .leading, spacing: 8) {
            DsSectionHeader(palette: palette, title: "计算因子",
                            trailing: expandedFactors ? "收起" : "展开",
                            action: { withAnimation(.easeInOut(duration: 0.18)) { expandedFactors.toggle() } })
            if expandedFactors {
                VStack(spacing: 0) {
                    ForEach(factors) { factor in
                        factorRow(factor)
                        if factor.id != factors.last?.id {
                            Rectangle().fill(palette.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .dsSurface(palette, radius: 18, padding: 0)

                Text("点任意一行看它最近 \(MarketRegimeEngine.factorHistoryLength) 个交易日的走势。历史是把每根 K 线当作当天，只用那天之前的数据重算出来的 —— 不是用今天的参数回头修出来的。")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(factors.filter(\.available).count) 项可用 / 共 \(factors.count) 项")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
            }
        }
    }

    @ViewBuilder
    private func factorRow(_ factor: MarketRegimeFactor) -> some View {
        let expanded = expandedFactorKey == factor.id
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard factor.hasHistory else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    expandedFactorKey = expanded ? nil : factor.id
                }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(factor.label)
                                .scaledFont(11.5, weight: .medium)
                                .foregroundStyle(factor.available ? palette.ink : palette.ink3)
                                .lineLimit(1)
                            if factor.hasHistory {
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(palette.ink3)
                            }
                        }
                        Text(factor.reason)
                            .scaledFont(9.5)
                            .foregroundStyle(palette.ink3)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 6)
                    Text(factor.displayValue)
                        .scaledFont(palette.fsLabel, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(factor.available ? factorTint(factor) : palette.ink3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 9)

            if expanded, factor.hasHistory {
                factorHistory(factor)
                    .padding(.bottom, 10)
            }
        }
    }

    private func factorHistory(_ factor: MarketRegimeFactor) -> some View {
        let values = factor.plottedHistory
        let range = factor.historyRange
        return VStack(alignment: .leading, spacing: 6) {
            DsSparkline(values: values, tint: factorTint(factor), lineWidth: 1.4)
                .frame(height: 44)
            HStack(spacing: 12) {
                if let range {
                    Text("区间 \(factor.unit.format(range.min)) ~ \(factor.unit.format(range.max))")
                }
                Text("\(values.count) 个交易日")
                if let percentile = factor.historyPercentile {
                    Text("当前 \(Int((percentile * 100).rounded()))% 分位")
                }
                Spacer(minLength: 0)
            }
            .scaledFont(9.5)
            .foregroundStyle(palette.ink3)
        }
    }

    /// 趋势类按涨跌上色；回撤用亏色；波动与量能超阈值才标红 ——
    /// 剩下的保持中性，不然整张表都是颜色，等于没有颜色。
    private func factorTint(_ factor: MarketRegimeFactor) -> Color {
        guard let value = factor.value, value.isFinite else { return palette.ink3 }
        switch factor.key {
        case "volatility_20":
            return value >= 0.25 ? PnLColor.up : palette.ink2
        case "volume_expansion":
            return value >= 1.8 ? PnLColor.up : palette.ink2
        case "daily_bar_spacing":
            return palette.ink2
        default:
            return PnLColor.of(value)
        }
    }

    // MARK: 已实现

    private var realizedCard: some View {
        let snapshot = store.realizedPerformance
        return VStack(alignment: .leading, spacing: 8) {
            DsSectionHeader(palette: palette, title: "已实现业绩")
            if snapshot.sellFillCount == 0 {
                Text("还没有卖出记录。这一栏只统计已经了结的部分，浮盈不计入。")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已实现净额")
                                .scaledFont(palette.fsMicro)
                                .foregroundStyle(palette.ink3)
                            Text(snapshot.netRealizedProfit.cny())
                                .scaledFont(palette.fsStat, weight: .bold)
                                .monospacedDigit()
                                .foregroundStyle(PnLColor.of(snapshot.netRealizedProfit))
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            if let rate = snapshot.instrumentWinRate {
                                Text("标的胜率 \(rate.pct(0))")
                                    .scaledFont(palette.fsLabel, weight: .semibold)
                                    .foregroundStyle(palette.ink)
                            }
                            if let average = snapshot.averageReturnOnCost {
                                Text("平均收益率 \(average.pct(2))")
                                    .scaledFont(palette.fsMicro)
                                    .foregroundStyle(palette.ink2)
                            }
                        }
                    }
                    .padding(.vertical, 12)

                    if !snapshot.byInstrument.isEmpty {
                        Rectangle().fill(palette.hairline).frame(height: 1)
                        ForEach(snapshot.byInstrument.prefix(8)) { item in
                            HStack(spacing: 8) {
                                Text(item.name)
                                    .scaledFont(palette.fsRow, weight: .medium)
                                    .foregroundStyle(palette.ink)
                                    .lineLimit(1)
                                Text(item.code)
                                    .scaledFont(palette.fsMicro)
                                    .foregroundStyle(palette.ink3)
                                Spacer(minLength: 4)
                                Text(item.returnOnRemovedCost.map { $0.pct(2) } ?? "--")
                                    .scaledFont(palette.fsMicro)
                                    .monospacedDigit()
                                    .foregroundStyle(palette.ink3)
                                Text(item.netRealizedProfit.cny())
                                    .scaledFont(palette.fsLabel, weight: .semibold)
                                    .monospacedDigit()
                                    .foregroundStyle(PnLColor.of(item.netRealizedProfit))
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .dsSurface(palette, radius: 18, padding: 0)
                Text("收益率的分母是这笔卖出移除掉的成本基础，不是卖出金额；按标的算胜率，不是按笔 —— 同一只反复做 T 会把按笔胜率刷得很高。")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 做 T

    private var intradayCard: some View {
        let summaries = store.dailyTradeSummaries(limitDays: 30)
        let trips = summaries.flatMap { $0.roundTrips }
        let total = trips.reduce(0) { $0 + $1.contribution }
        return VStack(alignment: .leading, spacing: 8) {
            DsSectionHeader(palette: palette, title: "日内做 T 贡献")
            if trips.isEmpty {
                Text("近 30 个交易日没有「先卖后回补」的配对。先买后卖属于调仓，不计入做 T。")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("合计贡献")
                                .scaledFont(palette.fsMicro)
                                .foregroundStyle(palette.ink3)
                            Text(total.cny())
                                .scaledFont(palette.fsStat, weight: .bold)
                                .monospacedDigit()
                                .foregroundStyle(PnLColor.of(total))
                        }
                        Spacer(minLength: 8)
                        Text("\(trips.count) 笔配对 · \(trips.filter { $0.contribution > 0.01 }.count) 笔为正")
                            .scaledFont(palette.fsMicro)
                            .foregroundStyle(palette.ink3)
                    }
                    .padding(.vertical, 12)

                    Rectangle().fill(palette.hairline).frame(height: 1)
                    ForEach(trips.prefix(6)) { trip in
                        HStack(spacing: 8) {
                            Text(trip.name)
                                .scaledFont(palette.fsRow, weight: .medium)
                                .foregroundStyle(palette.ink)
                                .lineLimit(1)
                            Text("\(trip.quantity.num(0)) 份")
                                .scaledFont(palette.fsMicro)
                                .foregroundStyle(palette.ink3)
                            Spacer(minLength: 4)
                            Text("\(trip.sellPrice.num(3)) → \(trip.buyBackPrice.num(3))")
                                .scaledFont(palette.fsMicro)
                                .monospacedDigit()
                                .foregroundStyle(palette.ink3)
                            Text(trip.contribution.cny())
                                .scaledFont(palette.fsLabel, weight: .semibold)
                                .monospacedDigit()
                                .foregroundStyle(PnLColor.of(trip.contribution))
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 14)
                .dsSurface(palette, radius: 18, padding: 0)
            }
        }
    }

    private var disclaimer: some View {
        Text("市场状态由本机按上证指数日线计算，含两个交易日的防抖（连续 3 日一致才确认）。它只描述环境，不预测点位。已实现与做 T 数据全部来自本机账本，不含券商实际成交与滑点。")
            .scaledFont(palette.fsMicro)
            .foregroundStyle(palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
