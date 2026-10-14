import SwiftUI
import Foundation

// MARK: - 账户智能画像（对齐网页版「私人顾问 · 画像」）
//
// 网页版会「看你的行为，不用你说」：从交易流水里推断交易风格、风险偏好、纪律性。
// 这里做同一件事，但把「谁下结论」分得很清楚：
//   1. 本机规则引擎先行 —— 不配 Key 也能看到一份可解释、可审计的画像（零成本）；
//   2. 配了 Key 时，**大模型拿原始材料自己生成画像与建议** —— 发给它的是持仓、
//      交易流水、行情变化这些事实，不是本机算好的结论。给它本机结论再让它「验证
//      或反驳」，等于把本机规则当标准答案，模型只会顺着复述；所以本机推断出的
//      风格 / 风险偏好一律不进 prompt。
// 所有材料只来自本机账本（ledger / fundTransactions / 快照 / 持仓），不上传任何数据。

// MARK: 画像数据模型

struct PortraitMetric: Identifiable {
    let title: String
    let value: String
    /// nil = 中性；true = 偏积极；false = 偏风险
    let tone: Bool?
    var id: String { title }
}

struct PortraitTag: Identifiable {
    let text: String
    /// 积极 / 中性 / 风险 三种配色
    let tone: Int // 1 积极, 0 中性, -1 风险
    var id: String { text }
}

struct AccountPortrait {
    var tags: [PortraitTag] = []
    var metrics: [PortraitMetric] = []
    var conclusions: [String] = []
    /// 推断出的投资偏好建议（可一键写入 investmentProfile）
    var suggestedStyle: String = "swing"   // day / swing / mid / long
    var suggestedRisk: String = "bal"      // con / bal / agg
    var suggestedMaxPosition: Double = 35
    var suggestedHorizon: String = "1-3个月"
    var inferredMethod: String = ""
    var sampleSize: Int = 0
    var hasAccountData = false
    var hasData: Bool { sampleSize > 0 || hasAccountData }
}

// MARK: 规则推断引擎

enum PortraitEngine {
    static func compute(data: PortfolioData, totalAsset: Double) -> AccountPortrait {
        var out = AccountPortrait()
        out.hasAccountData = !data.holdings.isEmpty || data.cash > 0 || !data.snapshots.isEmpty
            || !data.ledger.isEmpty || !data.fundTransactions.isEmpty || !data.fundDCAPlans.isEmpty

        // ---- 交易样本：ETF 台账 + 基金流水（分红不算交易；自动定投单独标记）----
        let etfBuys = data.ledger.filter { $0.side == .buy }
        let etfSells = data.ledger.filter { $0.side == .sell }
        let fundBuys = data.fundTransactions.filter { $0.side == .buy }
        let fundSells = data.fundTransactions.filter { $0.side == .sell }
        // 已执行定投流水属于交易样本；启用中的计划只是计划，不能当作已发生交易。
        let executedDcaCount = data.fundTransactions.filter { $0.isAutomaticDCA == true && $0.side != .dividend }.count
        let activeDcaPlanCount = data.fundDCAPlans.filter { $0.enabled }.count
        let manualTrades = etfBuys.count + etfSells.count
            + fundBuies(fundBuys) + fundSells.count
        out.sampleSize = manualTrades + executedDcaCount

        // ---- 交易跨度（月）----
        var dates: [Date] = data.ledger.map(\.date)
        let iso = FormatCache.shanghai("yyyy-MM-dd")
        for t in data.fundTransactions where t.side != .dividend {
            if let d = iso.date(from: String(t.effectiveDate.prefix(10))) { dates.append(d) }
        }
        let spanMonths: Double
        if let first = dates.min(), let last = dates.max(), last > first {
            spanMonths = max(1, Double(Calendar.current.dateComponents([.day], from: first, to: last).day ?? 30) / 30.0)
        } else { spanMonths = 1 }
        let perMonth = Double(manualTrades) / spanMonths

        // ---- 胜负与费用 ----
        let realized = data.ledger.map(\.realizedPnL)
            + data.fundTransactions.filter { $0.side == .sell }.map(\.realizedPnL)
        let wins = realized.filter { $0 > 0.005 }.count
        let losses = realized.filter { $0 < -0.005 }.count
        let winRate: Double? = (wins + losses) > 0 ? Double(wins) / Double(wins + losses) * 100 : nil
        let turnover = data.ledger.map(\.gross).reduce(0, +)
            + data.fundTransactions.filter { $0.side != .dividend }.map(\.amount).reduce(0, +)
        let fees = data.ledger.map(\.fee).reduce(0, +)
            + data.fundTransactions.map(\.fee).reduce(0, +)
        let feeRate: Double? = turnover > 0 ? fees / turnover * 100 : nil

        // ---- 集中度与现金 ----
        let marketValue = data.holdings.reduce(0) { $0 + $1.marketValue }
        let maxWeight: Double = totalAsset > 0
            ? (data.holdings.map { $0.marketValue / totalAsset }.max() ?? 0) * 100 : 0
        let cashRatio: Double = totalAsset > 0 ? data.cash / totalAsset * 100 : 0

        // ---- 画像标签 ----
        if perMonth >= 8 {
            out.tags.append(PortraitTag(text: "高频交易", tone: -1))
        } else if perMonth >= 3 {
            out.tags.append(PortraitTag(text: "波段选手", tone: 0))
        } else if perMonth >= 1 {
            out.tags.append(PortraitTag(text: "中低频", tone: 0))
        } else if out.sampleSize > 0 {
            out.tags.append(PortraitTag(text: "低频长线", tone: 1))
        }
        if executedDcaCount > 0 { out.tags.append(PortraitTag(text: "已执行定投 \(executedDcaCount) 笔", tone: 1)) }
        if activeDcaPlanCount > 0 { out.tags.append(PortraitTag(text: "定投计划 \(activeDcaPlanCount) 个", tone: 0)) }
        if maxWeight >= 45 {
            out.tags.append(PortraitTag(text: "单仓 \(Int(maxWeight))% · 集中", tone: -1))
        } else if maxWeight > 0 && maxWeight < 20 {
            out.tags.append(PortraitTag(text: "持仓分散", tone: 1))
        }
        if let wr = winRate {
            if wr >= 60 { out.tags.append(PortraitTag(text: "胜率 \(Int(wr))% · 不错", tone: 1)) }
            else if wr < 40 { out.tags.append(PortraitTag(text: "胜率 \(Int(wr))% · 偏低", tone: -1)) }
            else { out.tags.append(PortraitTag(text: "胜率 \(Int(wr))%", tone: 0)) }
        }
        if cashRatio <= 3 && totalAsset > 0 { out.tags.append(PortraitTag(text: "几乎满仓", tone: -1)) }
        else if cashRatio >= 40 && totalAsset > 0 { out.tags.append(PortraitTag(text: "现金充裕", tone: 0)) }
        if let fr = feeRate, fr >= 0.5 { out.tags.append(PortraitTag(text: "费用拖累 \(fr.num(2))%", tone: -1)) }

        // ---- 指标行 ----
        out.metrics.append(PortraitMetric(title: "手动交易笔数", value: manualTrades == 0 && out.hasAccountData ? "暂无流水" : "\(manualTrades) 笔", tone: nil))
        out.metrics.append(PortraitMetric(title: "交易频率", value: manualTrades == 0 && out.hasAccountData ? "样本不足" : "\(perMonth.num(1)) 笔/月", tone: manualTrades == 0 ? nil : perMonth >= 8 ? false : nil))
        out.metrics.append(PortraitMetric(title: "卖出胜负", value: wins + losses == 0 ? "暂无卖出" : "\(wins) 胜 \(losses) 负", tone: nil))
        if let wr = winRate {
            out.metrics.append(PortraitMetric(title: "卖出胜率", value: wr.pct(1), tone: wr >= 50 ? true : false))
        }
        if let fr = feeRate {
            out.metrics.append(PortraitMetric(title: "费用占换手", value: fr.pct(2), tone: fr >= 0.5 ? false : true))
        }
        out.metrics.append(PortraitMetric(title: "最大单仓", value: maxWeight.pct(1), tone: maxWeight >= 45 ? false : nil))
        out.metrics.append(PortraitMetric(title: "现金占比", value: cashRatio.pct(1), tone: nil))
        out.metrics.append(PortraitMetric(title: "累计费用", value: fees.cny(), tone: nil))

        // ---- 推断结论 ----
        var lines: [String] = []
        if perMonth >= 8 {
            lines.append("你最近平均每月手动交易 \(perMonth.num(1)) 笔，属于高频节奏。账面费用已累计 \(fees.cny())，换手越频繁，费用对收益的侵蚀越明显——先核对一下这些交易有多少是计划内、多少是临时起意。")
        } else if perMonth >= 1 {
            lines.append("平均每月 \(perMonth.num(1)) 笔手动交易，节奏适中。保持「计划先行」的习惯比增加次数更有价值。")
        } else if out.sampleSize > 0 {
            lines.append("手动交易很少（\(manualTrades) 笔），更接近低频 / 定投风格。账户波动主要来自持仓本身而非操作。")
        } else if out.hasAccountData {
            lines.append("目前缺少买卖流水，无法判断交易频率或胜率；以下只按当前持仓集中度和现金比例分析账户结构。补录流水后再生成行为结论。")
        } else {
            lines.append("账本里还没有持仓、现金或交易记录，暂时无法形成画像。")
        }
        if maxWeight >= 45 {
            let top = data.holdings.max { $0.marketValue < $1.marketValue }
            lines.append("最大单仓占总资产 \(maxWeight.num(1))%\(top.map { "（\($0.name)）" } ?? "")，单一标的的波动会主导整个账户。网页版的再平衡建议会按同样的口径提醒你。")
        }
        if let wr = winRate, wr < 40, wins + losses >= 5 {
            lines.append("已实现的卖出里只有 \(Int(wr))% 是盈利的（\(wins) 胜 \(losses) 负）。样本不算大，但值得回看亏损卖出的共同点：是止损太早、追高被套，还是标的本身选错。")
        }
        if executedDcaCount > 0 {
            lines.append("账本里有 \(executedDcaCount) 笔已执行定投。定投最大的价值是「纪律」；可以按原计划持续执行，并定期核对计划是否仍符合你的资金安排。")
        }
        if activeDcaPlanCount > 0 {
            lines.append("目前有 \(activeDcaPlanCount) 个启用中的定投计划；这是计划状态，不代表已经扣款。")
        }
        if cashRatio <= 3 && totalAsset > 0 {
            lines.append("现金只剩 \(cashRatio.pct(1))，几乎满仓。留 5–10% 现金不是为了收益，是为了在下跌时有子弹、在急涨时不被迫卖。")
        }
        if manualTrades == 0 && out.hasAccountData && maxWeight >= 30 {
            let top = data.holdings.max { $0.marketValue < $1.marketValue }
            lines.append("当前最大单仓占总资产 \(maxWeight.num(1))%\(top.map { "（\($0.name)）" } ?? "")。新买入前先检查它是否已接近你设定的单标的上限，避免仓位继续集中。")
        }
        if manualTrades == 0 && out.hasAccountData && totalAsset > 0 && cashRatio < 5 {
            lines.append("参考现金占比只有 \(cashRatio.num(1))%，可用缓冲较少。若计划加仓，先核对现金安排和仓位上限，避免为了补仓被迫卖出其他资产。")
        }
        if manualTrades == 0 && out.hasAccountData && totalAsset > 0 && cashRatio >= 40 {
            lines.append("参考现金占比为 \(cashRatio.num(1))%，现金缓冲较充足；可以先按目标仓位分批计划，不必因短期波动一次性投入。")
        }
        out.conclusions = lines

        // ---- 偏好建议（写入 InvestmentProfile 用）----
        out.suggestedStyle = perMonth >= 8 ? "day" : perMonth >= 3 ? "swing" : perMonth >= 1 ? "mid" : "long"
        out.suggestedRisk = (maxWeight >= 40 || cashRatio <= 5) ? "agg" : (maxWeight <= 20 && (executedDcaCount > 0 || activeDcaPlanCount > 0)) ? "con" : "bal"
        out.suggestedMaxPosition = min(80, max(10, (maxWeight / 10).rounded(.up) * 10 + 10))
        out.suggestedHorizon = perMonth >= 8 ? "数天" : perMonth >= 3 ? "1-3个月" : perMonth >= 1 ? "3-6个月" : "1年以上"
        out.inferredMethod = perMonth >= 8
            ? "系统观察：高频手动交易，注意费用与情绪化下单。"
            : (executedDcaCount > 0 || activeDcaPlanCount > 0) && perMonth < 1
            ? "系统观察：低频 + 定投为主，很少手动操作。"
            : "系统观察：节奏适中，波段与中线之间。"
        return out
    }

    private static func fundBuies(_ buys: [FundTransaction]) -> Int {
        buys.filter { $0.isAutomaticDCA != true }.count
    }

    /// 把**原始材料**发给大模型，让它**自己**生成画像与建议（配了 Key 时才发送）。
    ///
    /// 为什么不再发本机结论：先给「你是波段选手 / 风险激进」再让模型「验证或反驳」，
    /// 等于把本机规则设成了标准答案 —— 模型只会顺着复述，画像是被算出来的，不是被看出来的。
    /// 现在只发事实：持仓明细、交易流水明细、行情与结构变化，再加一份标注为「素材」的统计。
    /// 判断留给模型，并强制它逐条引用证据、证据不足时写「样本不足」。
    ///
    /// **标 `@MainActor`**：这里要读 `store.data` / `store.indexQuotes` / `store.totalAsset`，
    /// 而 `PortfolioStore` 是主线程隔离的。调用点 `runAI` 本来就在主线程。
    @MainActor
    static func portraitPrompt(_ p: AccountPortrait, store: PortfolioStore) -> String {
        let data = store.data
        let totalAsset = store.totalAsset

        // ---- 账户总览 ----
        let cashRatio = totalAsset > 0 ? data.cash / totalAsset * 100 : 0
        let overview = "总资产 \(totalAsset.num(2)) 元；持仓 \(data.holdings.count) 只；现金 \(data.cash.num(2)) 元（占总资产 \(cashRatio.num(1))%）。"

        // ---- 持仓明细（带当日涨跌；行情没缓存就如实写「未缓存」，不补数）----
        let holdingLines = data.holdings.map { h -> String in
            let weight = totalAsset > 0 ? h.marketValue / totalAsset * 100 : 0
            let costPct = h.cost > 0 ? (h.current - h.cost) / h.cost * 100 : 0
            let quote = data.quotes.first { $0.code == h.code }
            let today = quote.map { "，当日 \($0.changePct >= 0 ? "+" : "")\(($0.changePct * 100).num(2))%" } ?? "，当日行情未缓存"
            return "- \(h.name)（\(h.code)）\(h.kind == .etf ? "ETF" : "场外基金")：\(h.quantity.compactNum(4)) 份，成本 \(h.cost.num(4))，现价 \(h.current.num(4))\(today)，市值 \(h.marketValue.num(2))，浮盈亏 \(h.pnl.num(2))（\(costPct.num(2))%），占总资产 \(weight.num(1))%"
        }
        let holdingsBlock = holdingLines.isEmpty ? "（暂无持仓）" : holdingLines.joined(separator: "\n")

        // ---- 交易流水明细（两类各取近 20 笔，按时间倒序）----
        let ledgerSorted = data.ledger.sorted { $0.date > $1.date }
        let ledgerLines = ledgerSorted.prefix(20).map { e -> String in
            "- \(shortDay(e.date)) \(e.side == .buy ? "买入" : "卖出") \(e.name)（\(e.code)）\(e.quantity.compactNum(4)) 份 @ \(e.price.num(4))，金额 \(e.gross.num(2))，费 \(e.fee.num(2))，已实现盈亏 \(e.realizedPnL.num(2))"
        }
        let fundTrades = data.fundTransactions.filter { $0.side != .dividend }
        let fundSorted = fundTrades.sorted { $0.effectiveDate > $1.effectiveDate }
        let fundLines = fundSorted.prefix(20).map { t -> String in
            let dcaTag = t.isAutomaticDCA == true ? "（定投）" : ""
            return "- \(String(t.effectiveDate.prefix(10))) \(t.side == .buy ? "买入" : "卖出")\(dcaTag) \(t.name)（\(t.code)）\(t.amount.num(2)) 元 @ 净值 \(t.nav.num(4))，费 \(t.fee.num(2))，已实现盈亏 \(t.realizedPnL.num(2))"
        }
        var tradeParts: [String] = []
        if !ledgerLines.isEmpty {
            tradeParts.append("证券 / ETF 台账（近 \(ledgerLines.count) 笔）：\n\(ledgerLines.joined(separator: "\n"))")
        }
        if !fundLines.isEmpty {
            tradeParts.append("场外基金流水（近 \(fundLines.count) 笔，不含分红）：\n\(fundLines.joined(separator: "\n"))")
        }
        let tradesBlock = tradeParts.isEmpty ? "（账本里还没有买卖流水）" : tradeParts.joined(separator: "\n")

        // ---- 行情与结构变化：复用首页组合分析那一套素材，口径一致 ----
        var marketParts: [String] = []
        if let market = AIContextBuilder.marketSection(store: store) { marketParts.append(market) }
        if let risk = AIContextBuilder.portfolioRiskSection(store: store) { marketParts.append(risk) }
        if let tech = AIContextBuilder.technicalSection(store: store, codes: data.holdings.map(\.code)) {
            marketParts.append(tech)
        }
        let marketBlock = marketParts.isEmpty ? "（暂无行情 / 技术面缓存）" : marketParts.joined(separator: "\n")

        // ---- 本机统计：只是素材，明确写清「不是结论」----
        let metricsBlock = p.metrics.map { "- \($0.title)：\($0.value)" }.joined(separator: "\n")
        let sampleNote = p.sampleSize > 0
            ? "以上统计来自本机 \(p.sampleSize) 条交易样本。"
            : "账本里没有可用的买卖流水 —— 不要推断交易风格、胜率或操作习惯，只分析当前持仓结构。"

        return """
        你是投资行为分析师。下面是某个个人账户的**原始材料**：持仓、交易流水、行情变化，以及一份由本机规则算出的统计。请你**自己**从中生成这个账户主人的画像和后续建议 —— 画像的结论必须由你得出，不要把下面的统计当成既定结论来复述，也不要只做点评。先区分「流水能证明的事实」与「你的推断」，再下判断。

        【账户总览】
        \(overview)

        【持仓明细】
        \(holdingsBlock)

        【交易流水明细】
        \(tradesBlock)

        【行情与结构变化】
        \(marketBlock)

        【本机统计（由上面的流水算出，仅供参考的素材，不是结论）】
        \(metricsBlock)
        （\(sampleNote)）

        请按下面四段输出，用词直接、不嘲讽、不承诺收益、不编造数据：
        1. 画像：从交易风格、风险偏好、纪律性、偏好标的（能力圈）、典型行为特征五个方面给判断。每一方面都要引用上面具体的持仓或流水作为证据（写成「因为…所以判断…」）；证据不足的方面明确写「样本不足，无法判断」，不要用含糊措辞带过。
        2. 关键问题：挑出最值得处理的 1-2 个，说明它们为什么比其他问题优先，以及各自对应上面哪条证据。
        3. 建议：每条写清「触发条件 / 动作 / 边界」，并说明它针对第 2 段里的哪个问题。
        4. 复核信号：出现什么情况（数值、行为或市场条件）应该停下来重新评估这份画像。
        """
    }
}

// MARK: - 画像视图

struct AccountPortraitView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var portrait: AccountPortrait?
    @State private var aiResult = ""
    @State private var aiBusy = false
    @State private var message = ""
    @State private var savedMessage = ""

    private var keySaved: Bool { AIAnalysisService.hasSavedAPIKey }
    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    var body: some View {
        NavigationStack {
            Form {
                if let p = portrait, p.hasData {
                    portraitHeader(p)
                    tagsSection(p)
                    metricsSection(p)
                    conclusionsSection(p)
                    if p.sampleSize > 0 { suggestionSection(p) }
                    aiSection(p)
                } else {
                    Section {
                        ContentUnavailableView("暂无画像", systemImage: "person.crop.circle.badge.questionmark",
                            description: Text("先记录持仓、现金或交易流水，画像会自动生成。"))
                    }
                    .plainCard(isLight: isLight)
                }
                if !message.isEmpty { Section { Text(message).foregroundStyle(.secondary) }.plainCard(isLight: isLight) }
                Section {
                    Text("画像只描述你已经发生的行为，不预测市场，也不构成投资建议。所有计算在本机完成；只有你主动点「让大模型生成我的画像」时，上面那些持仓、流水与行情材料才会发送到你配置的接口。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
            }
            .navigationTitle("账户画像")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .appListLayout()
            .background(.clear)
            .themedSheetBackground()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear {
                recompute()
                if aiResult.isEmpty, let saved = store.data.savedPortraitAIAnalysis {
                    aiResult = saved.text
                }
            }
        }
    }

    private func recompute() {
        portrait = PortraitEngine.compute(data: store.data, totalAsset: store.totalAsset)
    }

    private func portraitHeader(_ p: AccountPortrait) -> some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(store.effectiveAccentColor)
                    .frame(width: 48, height: 48)
                    .background(store.effectiveAccentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: AppLayout.cardRadius, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("你的账户画像").font(.headline)
                    Text(p.sampleSize > 0 ? "依据 \(p.sampleSize) 条交易与定投样本" : "当前按持仓和现金结构生成")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
        .toneCard(store.effectiveAccentColor, isLight: isLight)
    }

    private func tagsSection(_ p: AccountPortrait) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("画像标签", systemImage: "tag").font(.headline)
                FlowTags(tags: p.tags)
            }
        }
        .plainCard(isLight: isLight)
    }

    private func metricsSection(_ p: AccountPortrait) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                Label("行为指标", systemImage: "chart.bar.xaxis").font(.headline).padding(.bottom, 8)
                ForEach(Array(p.metrics.enumerated()), id: \.offset) { index, m in
                    if index > 0 { Divider() }
                    HStack {
                        Text(m.title).foregroundStyle(.secondary)
                        Spacer()
                        Text(m.value).monospacedDigit()
                            .foregroundStyle(m.tone == true ? PnLColor.up : m.tone == false ? PnLColor.down : Color.primary)
                    }
                    .font(.subheadline).padding(.vertical, 8)
                }
            }
        }
        .plainCard(isLight: isLight)
    }

    private func conclusionsSection(_ p: AccountPortrait) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("系统观察", systemImage: "eye").font(.headline)
                ForEach(Array(p.conclusions.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)").font(.caption.bold()).foregroundStyle(store.effectiveAccentColor)
                            .frame(width: 22, height: 22)
                            .background(store.effectiveAccentColor.opacity(0.13), in: Circle())
                        Text(line).font(.subheadline)
                    }
                }
            }
        }
        .toneCard(store.effectiveAccentColor, isLight: isLight)
    }

    private func suggestionSection(_ p: AccountPortrait) -> some View {
        Section {
            Label("本机推断的偏好（可一键写入）", systemImage: "slider.horizontal.3").font(.headline)
            LabeledContent("交易风格", value: styleName(p.suggestedStyle))
            LabeledContent("风险偏好", value: riskName(p.suggestedRisk))
            LabeledContent("单标的仓位上限", value: "\(Int(p.suggestedMaxPosition))%")
            LabeledContent("典型持有周期", value: p.suggestedHorizon)
            if !p.inferredMethod.isEmpty { Text(p.inferredMethod).font(.footnote).foregroundStyle(.secondary) }
            Button("把推断写入我的投资偏好") {
                var profile = store.data.investmentProfile
                profile.style = p.suggestedStyle
                profile.risk = p.suggestedRisk
                profile.maxPositionPercent = p.suggestedMaxPosition
                profile.horizon = p.suggestedHorizon
                if profile.method.isEmpty { profile.method = p.inferredMethod }
                store.data.investmentProfile = profile
                store.save(label: "写入智能画像推断的偏好")
                Haptics.success()
                savedMessage = "已写入。AI 账户分析会按这份偏好发送请求，你随时可以在那里改回来。"
            }
            if !savedMessage.isEmpty { Text(savedMessage).font(.footnote).foregroundStyle(.secondary) }
        }
        .plainCard(isLight: isLight)
    }

    @ViewBuilder private func aiSection(_ p: AccountPortrait) -> some View {
        Section {
            Label("AI 生成画像与建议（可选）", systemImage: "sparkles").font(.headline)
            Text("把持仓、交易流水和行情变化交给大模型，由它自己推断你是什么类型的投资者、存在什么问题、接下来怎么做。上面「系统观察」是本机规则算的，这里是大模型独立生成的，两者不一致时以证据更具体的一方为准。")
                .font(.footnote).foregroundStyle(.secondary)
            if keySaved {
                Button {
                    Task { await runAI(p) }
                } label: {
                    HStack {
                        if aiBusy { ProgressView().padding(.trailing, 4) }
                        Text(aiBusy ? "正在生成…" : "让大模型生成我的画像")
                    }
                }.disabled(aiBusy)
            } else {
                Text("还没有配置 API 密钥。到「更多 → AI 账户分析」里填好接口与密钥后，这里就能让大模型基于同样的原始数据自己生成画像与建议。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !aiResult.isEmpty {
                if let saved = store.data.savedPortraitAIAnalysis {
                    Label("上次成功分析：\(saved.updatedAt.formatted(date: .abbreviated, time: .shortened))",
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                AIFormattedResultView(text: aiResult, accent: store.effectiveAccentColor)
            }
            if !aiResult.isEmpty {
                Text("模型输出可能有误。画像描述的是历史行为，不代表未来收益。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .toneCard(store.effectiveAccentColor, isLight: isLight)
    }

    @MainActor private func runAI(_ p: AccountPortrait) async {
        aiBusy = true; message = ""
        defer { aiBusy = false }
        do {
            let result = try await AIAnalysisService.chat(
                config: store.data.aiAnalysisConfig,
                prompt: PortraitEngine.portraitPrompt(p, store: store))
            aiResult = result
            store.data.savedPortraitAIAnalysis = SavedAIAnalysis(text: result)
            store.saveAIAnalysisCache()
        } catch {
            message = "分析失败：\(error.localizedDescription)\(aiResult.isEmpty ? "" : "；已保留上次成功结果。")"
        }
    }

    private func styleName(_ raw: String) -> String {
        ["day": "超短线", "swing": "波段", "mid": "中线", "long": "长线定投"][raw] ?? raw
    }
    private func riskName(_ raw: String) -> String {
        ["con": "保守", "bal": "平衡", "agg": "激进"][raw] ?? raw
    }
}

/// 简单的流式标签排布（iOS 16 无 Layout 协议可用的兜底：按宽度手动换行）
private struct FlowTags: View {
    let tags: [PortraitTag]
    var body: some View {
        // 画像标签通常 2-5 个，两列网格足够；不做通用流式布局，避免引 Layout 协议的兼容负担
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
            ForEach(tags) { tag in
                Text(tag.text)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(tagColor(tag.tone).opacity(0.14)))
                    .foregroundStyle(tagColor(tag.tone))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func tagColor(_ tone: Int) -> Color {
        tone > 0 ? PnLColor.up : tone < 0 ? PnLColor.down : Color.secondary
    }
}
