import SwiftUI
import Foundation

// MARK: - 技术研究页（K 线六形态 + 多周期 MACD + 量价）
//
// 设计对齐：repo/layout-mockups（M1~M5）+ repo/chart-mockups（V3 深色专业 / V5 高密度多指标）
//   · 双主题：科技黑绿（近黑底、卡片浮层、强调柠檬绿 #C8F751）
//             / 蓝海浅色（浅灰底、白卡、蓝紫强调）。全部走 ThemeSemantics 契约，不硬编码色。
//   · 卡片：大圆角、无色阶分层（tech）/ 淡影（ocean），与模拟图一致，不堆孤立白卡。
//   · 所有技术信号标记为「实验级 · 观察证据」：本机规则计算，不联网、不预测、不是买卖建议。
//   · 与六维评分 / 技术指标评分解耦：本页只呈现「看见了什么」，不新增任何买卖评分。

struct TechnicalResearchView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject private var store: PortfolioStore

    let code: String
    let name: String

    private var bars: [DailyBar] { store.dailyBars[code] ?? [] }
    private var macd: MultiTimeframeMACDAssessment? { store.multiTimeframeMACD120(code: code) }
    private var patterns: CandlePatternReport? { store.candlePatterns(code: code) }
    private var volume: VolumeAnalysisResult? {
        guard !bars.isEmpty else { return nil }
        return VolumeAnalysisEngine.daily(bars)
    }

    /// 市场环境（指数）：复用本机 MarketRegime 引擎，与全 App 一致（含防抖记忆）。
    @State private var regime: MarketRegimeAssessment? = nil

    /// 历史验证（样本内 / 样本外）：时间顺序 70/30 切分，只陈述统计事实。
    @State private var historyReport: HistoricalValidationReport? = nil

    // MARK: - 策略仲裁输入（全部来自既有引擎，不新增数据源）

    private var quote: Quote? {
        store.data.quotes.first { $0.code == code }
    }

    private var session: MarketSessionStatus {
        TradingSession.status(at: Date(), custom: store.data.customMarketHolidays)
    }

    /// 第 1 关：真实数据有效性。净值来自新浪/腾讯净值接口，拿不到就如实标「缺 IOPV」。
    private var priceQuality: ETFPriceQuality {
        let nav = store.etfIOPV[code]
        let input = ETFPriceInput(code: code,
                                  price: quote?.price,
                                  quoteAt: quote?.updatedAt,
                                  fetchedAt: quote?.fetchedAt,
                                  source: quote?.source,
                                  iopv: nav?.nav,
                                  iopvAt: nav?.navAt,
                                  isCrossBorder: RiskBudgetEngine.theme(for: code) == "跨境",
                                  session: session,
                                  customHolidays: store.data.customMarketHolidays)
        return ETFPriceQualityEngine.evaluate(input)
    }

    /// 第 2 关：组合级风险预算（与单笔 RiskGuard 分工不同）。
    private var riskBudget: RiskBudgetAssessment {
        let positions = store.data.holdings.map {
            RiskBudgetPosition(code: $0.code, name: $0.name, value: $0.marketValue)
        }
        return RiskBudgetEngine.evaluate(positions: positions, cash: store.data.cash)
    }

    /// 第 3~6 关：数据 > 组合风险 > 市场状态 > 技术证据 > AI > 候选。
    private var decision: ArbitrationDecision {
        StrategyArbitration.decide(ArbitrationInput(code: code,
                                                    priceQuality: priceQuality,
                                                    riskBudget: riskBudget,
                                                    regime: regime,
                                                    dailyTrend: macd?.daily.trend,
                                                    divergence: macd?.daily.divergence,
                                                    patternHitCount: patterns?.detectedKinds.count ?? 0))
    }

    var body: some View {
        let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
        ScrollView {
            VStack(alignment: .leading, spacing: layout.gap * 1.4) {
                header
                decisionCard
                pricingCard
                patientLimitCard
                macdCard
                patternCard
                volumeCard
                marketRegimeCard
                historyValidationCard
                LocalQuantFactorCardView(code: code)
                disclaimerCard
            }
            .padding(layout.pageInset)
        }
        .task {
            regime = store.marketRegime()
            await store.refreshETFIOPV(codes: [code])
            if historyReport == nil {
                historyReport = HistoricalValidationEngine.validate(bars: bars)
            }
        }
        .themedFormBackground(ThemeSemantics.of(appearance))
        .navigationTitle("技术研究")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 头部

    private var header: some View {
        let sem = ThemeSemantics.of(appearance)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.title2.bold()).foregroundStyle(sem.ink)
                Text(code).font(.subheadline).foregroundStyle(sem.ink3)
                Spacer(minLength: 0)
            }
            if let latest = bars.last {
                Text("最新收盘 \(latest.close.num(3)) · \(latest.date)")
                    .font(.caption).foregroundStyle(sem.ink3)
            } else {
                Text("暂无日线数据").font(.caption).foregroundStyle(sem.ink3)
            }
        }
    }

    // MARK: - 策略仲裁（数据 > 组合风险 > 市场状态 > 技术证据 > AI > 候选）

    private var decisionCard: some View {
        let sem = ThemeSemantics.of(appearance)
        let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
        let d = decision
        let tint = verdictTint(d.verdict, sem)

        var techText = macd?.daily.trend.title ?? "无 MACD 数据"
        if let div = macd?.daily.divergence, div != .none {
            techText += " · \(div.title)"
        }
        if let count = patterns?.detectedKinds.count, count > 0 {
            techText += " · 形态 \(count) 项"
        }

        return ResearchCard(title: "决策闸门",
                            subtitle: "真实数据 > 组合风险 > 市场状态 > 技术证据 > AI > 候选",
                            badge: d.title) {
            VStack(alignment: .leading, spacing: layout.gap) {
                Text(d.headline)
                    .font(.subheadline.bold())
                    .foregroundStyle(sem.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(d.action)
                    .font(.caption)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(sem.hairline)

                row(label: "数据有效性") {
                    Text(priceQuality.verdict.title)
                        .font(.caption.bold())
                        .foregroundStyle(verdictTint(priceQuality.verdict, sem))
                }
                row(label: "组合风险") {
                    Text(riskBudget.hasVeto ? "否决" : (riskBudget.worstSeverity?.title ?? "正常"))
                        .font(.caption.bold())
                        .foregroundStyle(riskBudget.hasVeto ? sem.danger : sem.ink2)
                }
                row(label: "市场状态") {
                    Text(regime.map { "\($0.regime.title) · \($0.riskLevel.title)" } ?? "不可用")
                        .font(.caption)
                        .foregroundStyle(sem.ink2)
                }
                row(label: "技术证据") {
                    Text(techText).font(.caption).foregroundStyle(sem.ink2)
                }

                if !d.reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(d.reasons.prefix(5).indices, id: \.self) { index in
                            Text("· \(d.reasons[index])")
                                .font(.caption2)
                                .foregroundStyle(sem.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("本次由「\(d.decidedBy.title)」这一关定案。\(d.allowsExactLimitPrice ? "允许给精确限价。" : "只能给区间，不给精确价。")系统不自动下单，Candidate 一律需人工确认。")
                    .font(.caption2)
                    .foregroundStyle(sem.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func verdictTint(_ v: ArbitrationVerdict, _ sem: ThemeSemantics) -> Color {
        switch v {
        case .blockedByData, .blockedByRisk: return sem.danger
        case .waitForMarket, .observeOnly: return sem.warn
        case .candidateEligible, .candidateActive: return sem.ok
        }
    }

    private func verdictTint(_ v: PriceDataVerdict, _ sem: ThemeSemantics) -> Color {
        switch v {
        case .usable: return sem.ok
        case .degraded: return sem.warn
        case .blocked: return sem.danger
        }
    }

    // MARK: - 净值 / IOPV / 折溢价 / 股息率

    private var holding: Holding? {
        store.data.holdings.first { $0.code == code }
    }

    /// 股息率：手填年分红优先；没填才用账本里过去 12 个月实际派发（不足一年不外推）。
    private var dividendYield: DividendYieldCalculator.Result? {
        if let manual = DividendYieldCalculator.yield(annualDividendPerShare: holding?.annualDividendPerShare,
                                                     price: quote?.price) {
            return manual
        }
        return DividendYieldCalculator.trailingYield(events: store.data.etfDividendEvents,
                                                     code: code,
                                                     price: quote?.price)
    }

    private var pricingCard: some View {
        let sem = ThemeSemantics.of(appearance)
        let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
        let nav = store.etfIOPV[code]
        let premium = nav?.premiumPercent(price: quote?.price)
        let dy = dividendYield

        return ResearchCard(title: "净值 · 折溢价 · 股息率",
                            subtitle: nav?.source ?? "尚未取得净值",
                            badge: nav == nil ? "无 IOPV" : nil) {
            VStack(alignment: .leading, spacing: layout.gap) {
                row(label: "单位净值（IOPV 口径）") {
                    Text(nav.map { $0.nav.num(4) } ?? "—")
                        .font(.subheadline.bold()).monospacedDigit()
                        .foregroundStyle(nav == nil ? sem.ink3 : sem.ink)
                }
                row(label: "净值日期") {
                    Text(nav?.rawDateText ?? "—").font(.caption).foregroundStyle(sem.ink3)
                }
                row(label: "成交价") {
                    Text(quote.map { $0.price.num(3) } ?? "—")
                        .font(.subheadline.bold()).monospacedDigit()
                        .foregroundStyle(quote == nil ? sem.ink3 : sem.ink)
                }
                row(label: "折溢价") {
                    if let premium {
                        Text(premium.pct(2))
                            .font(.subheadline.bold()).monospacedDigit()
                            .foregroundStyle(premiumTint(premium, sem))
                    } else {
                        Text("—（无净值不猜）").font(.caption).foregroundStyle(sem.ink3)
                    }
                }
                row(label: "股息率") {
                    if let dy {
                        Text(dy.yieldPercent.pct(2))
                            .font(.subheadline.bold()).monospacedDigit()
                            .foregroundStyle(sem.ink)
                    } else {
                        Text("未填年分红").font(.caption).foregroundStyle(sem.ink3)
                    }
                }

                if let dy {
                    Text("股息率口径：\(dy.source)，每份年分红 \(dy.annualDividendPerShare.num(4)) 元。分红是已公告/已派发口径，不是收益承诺。")
                        .font(.caption2).foregroundStyle(sem.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("股息率缺口：既没填「每份年分红」，账本里的分红记录也不满 12 个月。补齐任一项才给数——不按行业均值瞎估，也不把半年派发乘 2 当年化。")
                        .font(.caption2).foregroundStyle(sem.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("折溢价 =（成交价 − 单位净值）÷ 单位净值。盘中单位净值即 IOPV 口径，收盘后为当日净值。折溢价只说明贵或便宜，不是买卖信号。")
                    .font(.caption2).foregroundStyle(sem.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func premiumTint(_ premium: Double, _ sem: ThemeSemantics) -> Color {
        let magnitude = abs(premium)
        if magnitude >= 3 { return sem.danger }
        if magnitude >= 1 { return sem.warn }
        return sem.ink2
    }

    // MARK: - 耐心限价（ATR 退让 + 组合风险额度）

    /// 退让幅度由 ATR 决定，数量由组合风险预算决定；数据被阻断时不给任何精确价。
    private var patientLimit: PatientLimitPlan {
        PatientLimitEngine.plan(PatientLimitInput(code: code,
                                                  price: quote?.price,
                                                  bars: bars,
                                                  priceQuality: priceQuality,
                                                  deployableAmount: RiskBudgetEngine.maxDeployable(code: code, assessment: riskBudget),
                                                  ownedShares: holding?.quantity ?? 0,
                                                  lotSize: 100,
                                                  style: .balanced,
                                                  validityDays: 5,
                                                  lastBarForming: session.isLivePricing))
    }

    private var patientLimitCard: some View {
        let sem = ThemeSemantics.of(appearance)
        let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
        let plan = patientLimit

        let subtitle: String
        if let atr = plan.atr {
            subtitle = "ATR\(atr.period) \(atr.value.num(3)) · \(atr.percent.num(2))% · \(atr.method.title)"
        } else {
            subtitle = "无实测 ATR（日线不足），按缺省波动估算"
        }

        return ResearchCard(title: "耐心限价",
                            subtitle: subtitle,
                            badge: plan.blocked ? "暂不给价" : (plan.allowsExactPrice ? "可执行价" : "仅区间")) {
            VStack(alignment: .leading, spacing: layout.gap) {
                row(label: "参考价") {
                    HStack(spacing: 6) {
                        Text(plan.referencePrice.map { $0.num(3) } ?? "—")
                            .font(.subheadline.bold()).monospacedDigit()
                            .foregroundStyle(plan.referencePrice == nil ? sem.ink3 : sem.ink)
                        Text(plan.referenceSource).font(.caption2).foregroundStyle(sem.ink3)
                    }
                }
                row(label: "可加仓额度（组合风险）") {
                    Text(plan.deployableAmount > 0 ? plan.deployableAmount.cny(0) : "无额度")
                        .font(.subheadline.bold()).monospacedDigit()
                        .foregroundStyle(plan.deployableAmount > 0 ? sem.ink : sem.warn)
                }

                if plan.blocked {
                    ForEach(plan.blockedReasons, id: \.self) { reason in
                        Text("· \(reason)")
                            .font(.caption).foregroundStyle(sem.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !plan.bands.isEmpty {
                    Divider().overlay(sem.hairline)
                    ForEach(plan.bands) { band in
                        bandRow(band, plan: plan, sem: sem)
                    }
                    Divider().overlay(sem.hairline)
                    row(label: "合计") {
                        Text("\(plan.totalShares) 份 · \(plan.totalAmount.cny(0))")
                            .font(.subheadline.bold()).monospacedDigit().foregroundStyle(sem.ink)
                    }
                    row(label: "有效期") {
                        Text("\(plan.validityDays) 个交易日").font(.caption).foregroundStyle(sem.ink2)
                    }
                    if let invalidation = plan.invalidationPrice {
                        row(label: "失效价（跌破撤单）") {
                            Text(invalidation.num(3)).font(.subheadline.bold())
                                .monospacedDigit().foregroundStyle(sem.danger)
                        }
                    }
                }

                ForEach(plan.notes, id: \.self) { note in
                    Text("· \(note)")
                        .font(.caption2).foregroundStyle(sem.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("限价只是「愿意在这个价买」，不保证成交；挂单期间基本面或数据失效要主动撤单。退让幅度按 ATR 算，不是目标价倒推，也不预测涨跌。数量受组合风险预算约束，整手向下取整，余额留现金。")
                    .font(.caption2).foregroundStyle(sem.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bandRow(_ band: PatientLimitBand, plan: PatientLimitPlan, sem: ThemeSemantics) -> some View {
        let isRecommended = plan.recommendedBandID == band.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(band.title).font(.subheadline).foregroundStyle(sem.ink)
                if isRecommended {
                    Text("推荐")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(sem.accent.opacity(0.18)))
                        .foregroundStyle(sem.accent)
                }
                Spacer(minLength: 0)
                Text(band.price.num(3))
                    .font(.subheadline.bold()).monospacedDigit()
                    .foregroundStyle(sem.ink)
            }
            HStack(spacing: 8) {
                Text("低于参考 \(band.discountPercent.num(2))% · 退让 \(band.atrMultiple.num(1))×ATR")
                Spacer(minLength: 0)
                Text(band.isAffordable ? "\(band.shares) 份 · \(band.amount.cny(0))" : "不足一手")
                    .foregroundStyle(band.isAffordable ? sem.ink2 : sem.warn)
            }
            .font(.caption2)
            .foregroundStyle(sem.ink3)
            Text("近 \(band.lookback) 个交易日中，有 \(band.touchCount) 天盘中触及该价")
                .font(.caption2).foregroundStyle(sem.ink3)
            if let note = band.note {
                Text(note).font(.caption2).foregroundStyle(sem.ink3)
            }
        }
    }

    // MARK: - 多周期 MACD

    private var macdCard: some View {
        ResearchCard(title: "多周期 MACD",
                     subtitle: "日线 12,26,9 · 120分 6,13,5 · 周线 12,26,9",
                     badge: "实验级 · 观察证据") {
            let sem = ThemeSemantics.of(appearance)
            let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
            VStack(alignment: .leading, spacing: layout.gap) {
                if let macd {
                    let items = [macd.daily] + [macd.weekly, macd.intraday].compactMap { $0 }
                    ForEach(Array(items.enumerated()), id: \.element.timeframe) { idx, a in
                        macdRow(a)
                        if idx < items.count - 1 { Divider().background(sem.hairline) }
                    }
                    Divider().background(sem.hairline)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "link").font(.caption2).foregroundStyle(sem.ink3)
                        Text(macd.relationship).font(.caption).foregroundStyle(sem.ink2)
                    }
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "waveform").font(.caption2).foregroundStyle(sem.ink3)
                        Text(macd.resonance).font(.caption).foregroundStyle(sem.ink2)
                    }
                } else {
                    Text("日线数据不足，暂无法计算 MACD。").font(.footnote).foregroundStyle(sem.ink3)
                }
                Divider().background(sem.hairline)
                longTermTrendRows(sem: sem)
            }
        }
    }

    // MARK: - 长期趋势（日线 MA250）

    private var longTermTrend: LongTermTrend {
        LongTermTrendEngine.evaluate(dailyBars: bars, price: quote?.price)
    }

    @ViewBuilder
    private func longTermTrendRows(sem: ThemeSemantics) -> some View {
        let trend = longTermTrend
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("长期趋势（日线 MA250）").font(.caption.bold()).foregroundStyle(sem.ink2)
                Spacer(minLength: 0)
                Text(trend.position.title)
                    .font(.caption.bold())
                    .foregroundStyle(longTermTint(trend.position, sem))
            }
            row(label: "MA250") {
                Text(trend.ma250.map { $0.num(3) } ?? "数据不足")
                    .font(.subheadline.bold()).monospacedDigit()
                    .foregroundStyle(trend.ma250 == nil ? sem.ink3 : sem.ink)
            }
            row(label: "距 MA250") {
                Text(trend.distancePercent.map { $0.pct(2) } ?? "—")
                    .font(.subheadline.bold()).monospacedDigit()
                    .foregroundStyle(trend.distancePercent == nil ? sem.ink3 : sem.ink)
            }
            row(label: "MA250 近 20 日") {
                if let slope = trend.ma250SlopePercent, let rising = trend.isRising {
                    Text("\(rising ? "上行" : "下行") \(slope.pct(2))")
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(rising ? sem.ok : sem.warn)
                } else {
                    Text("样本不足").font(.caption).foregroundStyle(sem.ink3)
                }
            }
            ForEach(trend.notes, id: \.self) { note in
                Text("· \(note)")
                    .font(.caption2).foregroundStyle(sem.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func longTermTint(_ position: LongTermTrend.Position, _ sem: ThemeSemantics) -> Color {
        switch position {
        case .above: return sem.ok
        case .below: return sem.warn
        case .near: return sem.ink2
        case .unavailable: return sem.ink3
        }
    }

    private func macdRow(_ a: MACDTimeframeAssessment) -> some View {
        let sem = ThemeSemantics.of(appearance)
        let params: String = {
            switch a.timeframe {
            case .minutes120: return "6,13,5"
            default: return "12,26,9"
            }
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(a.timeframe.title).font(.subheadline.bold()).foregroundStyle(sem.ink)
                Text(params).font(.caption2).foregroundStyle(sem.ink3)
                Spacer(minLength: 0)
                Text(a.trend.title)
                    .font(.caption.bold())
                    .foregroundStyle(trendColor(a.trend, sem: sem))
            }
            HStack(spacing: 12) {
                crossBadge(a.cross, sem: sem)
                if let above = a.difAboveZero {
                    Text(above ? "DIF 在零轴上" : "DIF 在零轴下")
                        .font(.caption2).foregroundStyle(sem.ink3)
                }
                if let inc = a.histogramIncreasing {
                    Text(inc ? "红柱扩大" : "绿柱缩短（非买点）")
                        .font(.caption2)
                        .foregroundStyle(inc ? sem.ok : sem.ink3)
                }
                Spacer(minLength: 0)
            }
            if a.divergence == .bullish || a.divergence == .bearish {
                HStack(spacing: 6) {
                    Image(systemName: a.divergence == .bullish ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2)
                    Text(a.divergence.title)
                        .font(.caption2.bold())
                }
                .foregroundStyle(a.divergence == .bullish ? sem.ok : sem.danger)
            }
            HStack(spacing: 8) {
                if !a.signalConfirmed {
                    Text("最新一根未走完 · 信号未收盘确认")
                        .font(.caption2).foregroundStyle(sem.warn)
                }
                Text("数据\(a.qualityLabel)")
                    .font(.caption2).foregroundStyle(sem.ink3)
            }
        }
    }

    private func trendColor(_ t: MACDTrend, sem: ThemeSemantics) -> Color {
        switch t {
        case .bullishImproving, .shortTermRebound: return sem.ok
        case .weakening, .bearish: return sem.danger
        case .neutral: return sem.ink3
        case .dataInsufficient: return sem.warn
        }
    }

    private func crossBadge(_ cross: MACDCross, sem: ThemeSemantics) -> some View {
        let spec: (String, Color, Color) = {
            switch cross {
            case .golden: return ("金叉", sem.accent, sem.accent.opacity(0.16))
            case .death: return ("死叉", sem.danger, sem.danger.opacity(0.16))
            case .none: return ("无交叉", sem.ink3, Color.clear)
            }
        }()
        return Text(spec.0).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(spec.2))
            .foregroundStyle(spec.1)
    }

    // MARK: - K 线六形态

    private var patternCard: some View {
        ResearchCard(title: "K 线六形态识别",
                     subtitle: "放量突破 / 回踩确认 / 止跌 / 阴线缩小 / 长下影 / 放量阴",
                     badge: "实验级 · 观察证据") {
            let sem = ThemeSemantics.of(appearance)
            let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
            VStack(alignment: .leading, spacing: layout.gap) {
                if let report = patterns {
                    if report.hits.isEmpty {
                        Text("历史长度不足，无法识别 K 线形态。").font(.footnote).foregroundStyle(sem.ink3)
                    } else {
                        ForEach(Array(report.hits.enumerated()), id: \.element.kind) { idx, hit in
                            patternRow(hit)
                            if idx < report.hits.count - 1 { Divider().background(sem.hairline) }
                        }
                    }
                } else {
                    Text("日线数据不足，暂无法识别。").font(.footnote).foregroundStyle(sem.ink3)
                }
            }
        }
    }

    private func patternRow(_ hit: CandlePatternHit) -> some View {
        let sem = ThemeSemantics.of(appearance)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.kind.title).font(.subheadline).foregroundStyle(sem.ink)
                Spacer(minLength: 0)
                if hit.detected {
                    Text("已识别").font(.caption2.bold()).foregroundStyle(sem.ok)
                } else {
                    Text("未识别").font(.caption2).foregroundStyle(sem.ink3)
                }
            }
            if let note = hit.notes.first {
                Text(note).font(.caption2)
                    .foregroundStyle(hit.detected ? sem.ink2 : sem.ink3)
            }
            if hit.detected {
                HStack(spacing: 6) {
                    Capsule().fill(sem.ink3.opacity(0.3))
                        .frame(maxWidth: .infinity, minHeight: 4, maxHeight: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(sem.accent)
                                .frame(width: max(8, CGFloat(hit.strength) * 140), height: 4)
                        }
                    Text(String(format: "强度 %.0f%%", hit.strength * 100))
                        .font(.caption2).foregroundStyle(sem.ink3)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: - 量价分析

    private var volumeCard: some View {
        ResearchCard(title: "量价分析",
                     subtitle: "量能 vs 20日均量 · 价量关系",
                     badge: "实验级 · 观察证据") {
            let sem = ThemeSemantics.of(appearance)
            let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
            VStack(alignment: .leading, spacing: layout.gap) {
                if let vol = volume, let latest = vol.latest {
                    row(label: "最新量 / 20日均量") {
                        if let r = latest.volumeToMA20 {
                            Text(String(format: "%.2f×", r))
                                .font(.subheadline.bold())
                                .foregroundStyle(r >= 1.5 ? sem.warn : (r >= 1.0 ? sem.accent : sem.ink2))
                        } else { Text("—").foregroundStyle(sem.ink3) }
                    }
                    row(label: "量能状态") {
                        Text(volumeStateTitle(latest.state)).font(.subheadline).foregroundStyle(sem.ink2)
                    }
                    row(label: "价量关系") {
                        Text(priceVolumeTitle(latest.priceVolumeRelation)).font(.caption).foregroundStyle(sem.ink2)
                    }
                    row(label: "连续放量 / 缩量") {
                        Text("\(latest.consecutiveExpansionCount) 天放量 / \(latest.consecutiveContractionCount) 天缩量")
                            .font(.caption).foregroundStyle(sem.ink3)
                    }
                    if !latest.isFinal {
                        Text("当前 K 线尚未收盘，量能为形成中估算。").font(.caption2).foregroundStyle(sem.warn)
                    }
                } else {
                    Text("成交量数据不足，暂无法分析。").font(.footnote).foregroundStyle(sem.ink3)
                }
            }
        }
    }

    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        let sem = ThemeSemantics.of(appearance)
        return HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(sem.ink)
            Spacer(minLength: 0)
            content()
        }
    }

    private func volumeStateTitle(_ s: VolumeState) -> String {
        switch s {
        case .unavailable: return "不可用"
        case .formingProvisional: return "形成中（估算）"
        case .aboveSameTimeBaseline: return "高于同进度基线"
        case .belowSameTimeBaseline: return "低于同进度基线"
        case .atSameTimeBaseline: return "持平同进度基线"
        }
    }

    private func priceVolumeTitle(_ p: PriceVolumeRelation) -> String {
        switch p {
        case .unavailable: return "不可用"
        case .provisional: return "形成中"
        case .priceUpVolumeAboveBaseline: return "价涨量增"
        case .priceUpVolumeAtOrBelowBaseline: return "价涨量平/缩"
        case .priceDownVolumeAboveBaseline: return "价跌量增（派发？）"
        case .priceDownVolumeAtOrBelowBaseline: return "价跌量缩（惜售？）"
        case .unchangedPriceVolumeAboveBaseline: return "价平量增"
        case .unchangedPriceVolumeAtOrBelowBaseline: return "价平量缩"
        }
    }

    // MARK: - 诚实声明

    private var disclaimerCard: some View {
        let sem = ThemeSemantics.of(appearance)
        return VStack(alignment: .leading, spacing: 4) {
            Text("诚实声明").font(.caption.bold()).foregroundStyle(sem.ink2)
            Text("本页全部为「本机规则计算的观察材料」，evidenceLevel = experimental：只描述历史与当下形态，不预测、不构成买卖建议，也不对收益负责。绿柱缩短、金叉、形态识别均属实验级证据，禁止单独翻成买入。信号与六维评分、技术指标评分、AI 顾问相互独立；最新 K 线未收盘时一律标记「未确认」。NAS 不可用不影响本页（本地离线计算）。")
                .font(.caption2).foregroundStyle(sem.ink3)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 市场环境（复用本机 MarketRegime 引擎）

    private var marketRegimeCard: some View {
        ResearchCard(title: "市场环境（上证指数）",
                     subtitle: "指数环境 · 多周期均线结构",
                     badge: "观察级别") {
            let sem = ThemeSemantics.of(appearance)
            let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
            VStack(alignment: .leading, spacing: layout.gap) {
                if let r = regime {
                    HStack {
                        Text(r.regime.title)
                            .font(.headline.bold())
                            .foregroundStyle(sem.ink)
                        Spacer(minLength: 0)
                        Text(r.riskLevel.title)
                            .font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(riskTint(r.riskLevel, sem: sem).opacity(0.16)))
                            .foregroundStyle(riskTint(r.riskLevel, sem: sem))
                    }
                    HStack(spacing: 16) {
                        if let v = r.return5Sessions { metric("近 5 日", v, sem: sem) }
                        if let v = r.return20Sessions { metric("近 20 日", v, sem: sem) }
                        if let v = r.drawdown20Sessions { metric("20 日回撤", v, sem: sem) }
                    }
                    HStack(spacing: 6) {
                        Text("置信度 \(r.confidenceLabel)")
                            .font(.caption2).foregroundStyle(sem.ink3)
                        if let d = r.dataAsOf {
                            Text("· 截至 \(MarketCalendar.isoDay(d))")
                                .font(.caption2).foregroundStyle(sem.ink3)
                        }
                        Spacer(minLength: 0)
                    }
                    if r.observationOnly {
                        HStack(spacing: 6) {
                            Image(systemName: "eye").font(.caption2)
                            Text("观察级别：可据此调整节奏，不构成买卖指令")
                                .font(.caption2).fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(sem.ink2)
                    }
                    if !r.reasons.isEmpty {
                        ForEach(Array(r.reasons.prefix(3).enumerated()), id: \.offset) { _, reason in
                            Text("· " + reason).font(.caption2).foregroundStyle(sem.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text("上证指数日线不足 60 个交易日，暂无法判定市场环境（去行情页刷新一次即可）。")
                        .font(.footnote).foregroundStyle(sem.ink3)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: Double, sem: ThemeSemantics) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(sem.ink3)
            Text(value.pct(2)).font(.subheadline.bold()).monospacedDigit()
                .foregroundStyle(PnLColor.of(value))
        }
    }

    private func riskTint(_ level: MarketRiskLevel, sem: ThemeSemantics) -> Color {
        switch level {
        case .r0Normal: return sem.ink2
        case .r1Elevated: return sem.warn
        case .r2High, .r3Severe, .r4Extreme: return sem.danger
        }
    }

    // MARK: - 历史验证（样本内 / 样本外）

    private var historyValidationCard: some View {
        ResearchCard(title: "历史验证（样本内 / 样本外）",
                     subtitle: "时间顺序 70/30 · 与无条件基准对照",
                     badge: "统计观察") {
            let sem = ThemeSemantics.of(appearance)
            let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
            VStack(alignment: .leading, spacing: layout.gap) {
                if let r = historyReport {
                    HStack(spacing: 6) {
                        Text("样本内 \(r.inSampleRange)").font(.caption2).foregroundStyle(sem.ink3)
                        Spacer(minLength: 0)
                        Text("样本外 \(r.outOfSampleRange)").font(.caption2).foregroundStyle(sem.ink3)
                    }
                    ForEach(Array(r.rules.enumerated()), id: \.offset) { _, rule in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.ruleName).font(.caption.bold()).foregroundStyle(sem.ink)
                            Text(rule.definition).font(.caption2).foregroundStyle(sem.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(rule.horizons.enumerated()), id: \.offset) { _, h in
                                historyHorizonRow(h, sem: sem)
                            }
                            ForEach(Array(rule.notes.enumerated()), id: \.offset) { _, note in
                                Text("· " + note).font(.caption2).foregroundStyle(sem.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    ForEach(Array(r.notes.prefix(3).enumerated()), id: \.offset) { _, note in
                        Text("· " + note).font(.caption2).foregroundStyle(sem.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("日线数据不足 \(HistoricalValidationEngine.minBars) 根，暂不做历史验证（不拿小样本编结论）。")
                        .font(.footnote).foregroundStyle(sem.ink3)
                }
            }
        }
    }

    private func historyHorizonRow(_ h: HistoricalHorizonReport, sem: ThemeSemantics) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(h.horizonDays) 日窗口").font(.caption2.bold()).foregroundStyle(sem.ink2)
            HStack(spacing: 10) {
                historySegmentCell("样本内", h.inSample, sem: sem)
                historySegmentCell("样本外", h.outOfSample, sem: sem)
            }
        }
    }

    private func historySegmentCell(_ title: String, _ s: HistoricalSegmentStats,
                                    sem: ThemeSemantics) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(sem.ink3)
            if s.insufficient {
                Text("样本 \(s.sampleCount) 次 · 不下结论")
                    .font(.caption2).foregroundStyle(sem.ink3).monospacedDigit()
            } else if let hit = s.hitRate, let base = s.baselineHitRate {
                Text("命中 \((hit * 100).num(0))% vs 基准 \((base * 100).num(0))%")
                    .font(.caption2).foregroundStyle(sem.ink).monospacedDigit()
                if let avg = s.avgReturnPercent {
                    Text("均收益 \(avg.pct(2))")
                        .font(.caption2).foregroundStyle(PnLColor.of(avg)).monospacedDigit()
                }
                Text("样本 \(s.sampleCount) 次")
                    .font(.caption2).foregroundStyle(sem.ink3).monospacedDigit()
            } else {
                Text("样本 \(s.sampleCount) 次 · 数据缺失")
                    .font(.caption2).foregroundStyle(sem.ink3).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 八类因子证据卡（独立私有视图，不与页面 computed var 混排）
//
// 只呈现 LocalQuantFactorEngine 的测量结果：因子值、方向刻度、样本与来源。
// 不加分、不排名、不给买卖建议；不可用的因子如实写原因，不补 0。

private struct LocalQuantFactorCardView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject private var store: PortfolioStore

    let code: String

    private var bars: [DailyBar] { store.dailyBars[code] ?? [] }
    private var quote: Quote? { store.data.quotes.first { $0.code == code } }

    /// 已收盘日线：与 F 版同口径——当日那根 bar 也先剔除，
    /// 墙钟时间不能证明提供方已定稿当日日线（保守做法，宁缺毋滥）。
    private var completedBars: [DailyBar] {
        let today = Self.shanghaiDay(Date())
        return bars.filter { $0.date < today }
    }

    /// 当日分钟样本（归档分时按天取最新一天）。
    private var todaySamples: [IntradayBar] {
        let mine = store.intradayBars.filter { $0.code == code }
        guard let latestDay = mine.map(\.day).max() else { return [] }
        return mine.filter { $0.day == latestDay }.sorted { $0.timestamp < $1.timestamp }
    }

    /// 实时报价是否可用：连续交易时段 + 报价在 90 秒内。
    private var quoteFresh: Bool {
        guard TradingSession.status(at: Date(), custom: store.data.customMarketHolidays) == .continuous,
              let updatedAt = quote?.updatedAt else { return false }
        return Date().timeIntervalSince(updatedAt) <= 90
    }

    private var report: LocalQuantFactorReport {
        LocalQuantFactorEngine.evaluate(
            code: code,
            bars: completedBars,
            samples: todaySamples,
            price: quote?.price,
            iopv: store.etfIOPV[code],
            quoteFresh: quoteFresh)
    }

    var body: some View {
        ResearchCard(title: "八类因子证据",
                     subtitle: "本机 Quant · 与 Web 版口径逐项对齐",
                     badge: "观察证据 · 非买卖信号") {
            let sem = ThemeSemantics.of(appearance)
            let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
            let report = self.report
            VStack(alignment: .leading, spacing: layout.gap) {
                HStack(alignment: .firstTextBaseline) {
                    Text("综合方向刻度").font(.caption).foregroundStyle(sem.ink3)
                    Spacer()
                    if let score = report.directionalScore {
                        Text("\(score)")
                            .font(.title3.bold()).monospacedDigit()
                            .foregroundStyle(score > 0 ? PnLColor.up : (score < 0 ? PnLColor.down : sem.ink2))
                        Text("(\(report.scoredFactorCount) 项)")
                            .font(.caption2).foregroundStyle(sem.ink3)
                    } else {
                        Text("有效刻度 < 3，不出综合值").font(.caption).foregroundStyle(sem.ink3)
                    }
                }

                Divider().opacity(0.4)

                ForEach(report.factors) { factor in
                    factorRow(factor, sem: sem)
                }

                Text("方向刻度 = 因子值 ÷ 波动率 → z/(1+|z|)×100，只描述相对方向，不是概率、不是预期收益。日线类用已收盘 K 线；日内类用当日分钟样本（断档样本不出数）。任何单项都不构成买卖信号、不进评分。")
                    .font(.caption2).foregroundStyle(sem.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func factorRow(_ factor: LocalQuantFactorObservation,
                                        sem: ThemeSemantics) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(factor.kind.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(sem.ink)
                Spacer()
                if factor.isAvailable, let value = factor.value {
                    Text((value * 100).pct(2))
                        .font(.subheadline.bold()).monospacedDigit()
                        .foregroundStyle(sem.ink2)
                    if let score = factor.directionalScore {
                        Text("→ \(score)")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(score > 0 ? PnLColor.up : (score < 0 ? PnLColor.down : sem.ink3))
                    }
                } else {
                    Text("不可用")
                        .font(.caption)
                        .foregroundStyle(sem.ink3)
                }
            }
            if !factor.isAvailable {
                Text(factor.unavailableReason ?? "数据不足")
                    .font(.caption2).foregroundStyle(sem.ink3)
            } else {
                Text(factor.kind.definition)
                    .font(.caption2).foregroundStyle(sem.ink3)
                if let note = factor.qualityNote {
                    Text(note).font(.caption2).foregroundStyle(sem.warn)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static func shanghaiDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return formatter.string(from: date)
    }
}

// MARK: - 双主题卡片容器

private struct ResearchCard<Content: View>: View {
    @Environment(\.appAppearance) private var appearance
    let title: String
    var subtitle: String? = nil
    var badge: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let sem = ThemeSemantics.of(appearance)
        let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
        VStack(alignment: .leading, spacing: layout.gap) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(sem.ink)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(sem.ink3)
                    }
                }
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(sem.warn.opacity(0.16)))
                        .foregroundStyle(sem.warn)
                }
            }
            content()
        }
        .padding(layout.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: layout.radius, style: .continuous)
                .fill(sem.card)
                .shadow(color: Color.black.opacity(layout.shadowOpacity), radius: layout.shadowRadius, y: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: layout.radius, style: .continuous)
                        .strokeBorder(sem.hairline, lineWidth: 1)
                )
        )
    }
}
