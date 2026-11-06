import SwiftUI

/// 市场状态与账户战绩。
///
/// 把「现在大盘什么状态」「我这几轮做得到底怎么样」放在一页：
/// 这两件事必须一起看 —— 熊市里胜率高，和牛市里胜率高，含义完全不同。
struct MarketStateView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    @State private var regime: MarketRegimeAssessment?
    @State private var expandedFactors = false

    private var palette: DsPalette {
        DsPalette(isLight: AppTheme.palette(for: store.resolvedAppearance).isLight)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.sectionGap) {
                    regimeCard
                    if let regime, !regime.reasons.isEmpty {
                        reasonCard(regime)
                    }
                    factorCard
                    realizedCard
                    intradayCard
                    disclaimer
                }
                .padding(.horizontal, DS.pageInset)
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
            .onAppear { regime = store.marketRegime() }
        }
    }

    // MARK: 状态卡

    private var regimeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("上证指数")
                    .scaledFont(DS.fsLabel, weight: .medium)
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
                    .scaledFont(DS.fsHero, weight: .bold)
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
                        .scaledFont(DS.fsMicro)
                        .foregroundStyle(palette.ink3)
                    if let date = regime.dataAsOf {
                        Text("· 数据截至 \(MarketCalendar.isoDay(date))")
                            .scaledFont(DS.fsMicro)
                            .foregroundStyle(palette.ink3)
                    }
                    Spacer(minLength: 0)
                }

                if regime.observationOnly {
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                            .font(.system(size: 10, weight: .semibold))
                        Text("观察级别：可以据此调整节奏，不构成买卖指令")
                            .scaledFont(DS.fsMicro)
                    }
                    .foregroundStyle(palette.ink2)
                }
            } else {
                Text("日线不足")
                    .scaledFont(DS.fsHero, weight: .bold)
                    .foregroundStyle(palette.ink3)
                Text("至少需要 60 个交易日的上证指数日线。打开一次行情页并下滑刷新，让它把日 K 拉回来。")
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: DS.heroRadius, padding: 0)
    }

    private func metric(_ title: String, _ value: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scaledFont(9.5)
                .foregroundStyle(palette.ink3)
            Text(value)
                .scaledFont(DS.fsRow, weight: .semibold)
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
                            .scaledFont(DS.fsMicro)
                            .foregroundStyle(palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: 因子

    private var factorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            DsSectionHeader(palette: palette, title: "计算因子",
                            trailing: expandedFactors ? "收起" : "展开",
                            action: { withAnimation(.easeInOut(duration: 0.18)) { expandedFactors.toggle() } })
            if expandedFactors {
                VStack(spacing: 8) {
                    ForEach(regime?.factors ?? []) { factor in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(factor.key)
                                    .scaledFont(11, weight: .medium)
                                    .foregroundStyle(factor.available ? palette.ink : palette.ink3)
                                    .lineLimit(1)
                                Text(factor.reason)
                                    .scaledFont(9.5)
                                    .foregroundStyle(palette.ink3)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 6)
                            Text(factor.available ? factor.displayValue : "--")
                                .scaledFont(DS.fsLabel, weight: .medium)
                                .monospacedDigit()
                                .foregroundStyle(factor.available ? palette.ink : palette.ink3)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(14)
                .dsSurface(palette, radius: 16, padding: 0)
            } else {
                Text("\(regime?.factors.filter(\.available).count ?? 0) 项可用 / 共 \(regime?.factors.count ?? 0) 项")
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink3)
            }
        }
    }

    // MARK: 已实现

    private var realizedCard: some View {
        let snapshot = store.realizedPerformance
        return VStack(alignment: .leading, spacing: 8) {
            DsSectionHeader(palette: palette, title: "已实现业绩")
            if snapshot.sellFillCount == 0 {
                Text("还没有卖出记录。这一栏只统计已经了结的部分，浮盈不计入。")
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink3)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已实现净额")
                                .scaledFont(DS.fsMicro)
                                .foregroundStyle(palette.ink3)
                            Text(snapshot.netRealizedProfit.cny())
                                .scaledFont(DS.fsStat, weight: .bold)
                                .monospacedDigit()
                                .foregroundStyle(PnLColor.of(snapshot.netRealizedProfit))
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            if let rate = snapshot.instrumentWinRate {
                                Text("标的胜率 \(rate.pct(0))")
                                    .scaledFont(DS.fsLabel, weight: .semibold)
                                    .foregroundStyle(palette.ink)
                            }
                            if let average = snapshot.averageReturnOnCost {
                                Text("平均收益率 \(average.pct(2))")
                                    .scaledFont(DS.fsMicro)
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
                                    .scaledFont(DS.fsRow, weight: .medium)
                                    .foregroundStyle(palette.ink)
                                    .lineLimit(1)
                                Text(item.code)
                                    .scaledFont(DS.fsMicro)
                                    .foregroundStyle(palette.ink3)
                                Spacer(minLength: 4)
                                Text(item.returnOnRemovedCost.map { $0.pct(2) } ?? "--")
                                    .scaledFont(DS.fsMicro)
                                    .monospacedDigit()
                                    .foregroundStyle(palette.ink3)
                                Text(item.netRealizedProfit.cny())
                                    .scaledFont(DS.fsLabel, weight: .semibold)
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
                    .scaledFont(DS.fsMicro)
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
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("合计贡献")
                                .scaledFont(DS.fsMicro)
                                .foregroundStyle(palette.ink3)
                            Text(total.cny())
                                .scaledFont(DS.fsStat, weight: .bold)
                                .monospacedDigit()
                                .foregroundStyle(PnLColor.of(total))
                        }
                        Spacer(minLength: 8)
                        Text("\(trips.count) 笔配对 · \(trips.filter { $0.contribution > 0.01 }.count) 笔为正")
                            .scaledFont(DS.fsMicro)
                            .foregroundStyle(palette.ink3)
                    }
                    .padding(.vertical, 12)

                    Rectangle().fill(palette.hairline).frame(height: 1)
                    ForEach(trips.prefix(6)) { trip in
                        HStack(spacing: 8) {
                            Text(trip.name)
                                .scaledFont(DS.fsRow, weight: .medium)
                                .foregroundStyle(palette.ink)
                                .lineLimit(1)
                            Text("\(trip.quantity.num(0)) 份")
                                .scaledFont(DS.fsMicro)
                                .foregroundStyle(palette.ink3)
                            Spacer(minLength: 4)
                            Text("\(trip.sellPrice.num(3)) → \(trip.buyBackPrice.num(3))")
                                .scaledFont(DS.fsMicro)
                                .monospacedDigit()
                                .foregroundStyle(palette.ink3)
                            Text(trip.contribution.cny())
                                .scaledFont(DS.fsLabel, weight: .semibold)
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
            .scaledFont(DS.fsMicro)
            .foregroundStyle(palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
