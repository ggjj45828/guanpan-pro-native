import Foundation

/// 给 AI 分析准备「补充材料」。
///
/// **为什么单独拆一层**：`AIAnalysisService` 只该关心怎么问模型，不该知道
/// 观盘 Pro 的 store 里有哪些字段；调用方（首页组合分析、个股页、账户画像）
/// 也不该各自拼一遍同样的文本。所以素材装配统一放这里。
///
/// 全部是**本机计算，不发任何请求**。素材不全时如实写「未缓存 / 样本不足」，
/// 绝不插值补数 —— 让 AI 知道它缺什么，比给它一个编出来的数安全得多。
///
/// **整块标 `@MainActor`**：`PortfolioStore` 是主线程隔离的，这里要直接读它的
/// `data` / `dailyBars` / `indexQuotes` / `totalAsset`。不标就会被编译器挡在门外
/// （「main actor-isolated property can not be referenced from a non-isolated context」）。
/// 调用点都在主线程（首页组合分析、个股页），所以加了也不影响什么。
@MainActor
enum AIContextBuilder {

    // MARK: - 组合分析

    /// 组合分析要用的全部补充材料。任何一块拿不到就不放（prompt 里少一段，而不是多一段假话）。
    static func portfolioSections(store: PortfolioStore) -> [String] {
        var sections: [String] = [behaviorSection(store: store)]
        if let market = marketSection(store: store) { sections.append(market) }
        // 市场状态放在最前面：后面所有结论都要在这个背景下读。
        if let regime = regimeSection(store: store) { sections.insert(regime, at: 1) }
        if let risk = portfolioRiskSection(store: store) { sections.append(risk) }
        if let tech = technicalSection(store: store, codes: store.data.holdings.map(\.code)) {
            sections.append(tech)
        }
        if let macd = multiTimeframeMACDSection(store: store) { sections.append(macd) }
        if let episodes = episodeSection(store: store) { sections.append(episodes) }
        if let realized = realizedSection(store: store) { sections.append(realized) }
        if let intraday = intradayTradeSection(store: store) { sections.append(intraday) }
        if let cost = expenseSection(store: store) { sections.append(cost) }
        if let news = newsSection(store: store) { sections.append(news) }
        if let memory = decisionMemorySection(store: store) { sections.append(memory) }
        return sections
    }

    // MARK: - 市场状态

    /// 指数状态 + 风险等级。这一段决定「今天该不该动手」，
    /// 比任何单只标的的信号都靠前。
    static func regimeSection(store: PortfolioStore) -> String? {
        guard let assessment = store.marketRegime() else {
            return """
            【市场状态】
            本机没有足够的上证指数日线（至少需要 60 个交易日），无法判断大盘状态。不要用其它标的的走势代替。
            """
        }
        var lines: [String] = []
        lines.append("状态：\(assessment.regime.title) · \(assessment.riskLevel.title) · 置信度 \(assessment.confidenceLabel)")
        if let date = assessment.dataAsOf {
            lines.append("数据截至：\(MarketCalendar.isoDay(date))")
        }
        if let ret5 = assessment.return5Sessions { lines.append("近 5 日：\(ret5.pct(2))") }
        if let ret20 = assessment.return20Sessions { lines.append("近 20 日：\(ret20.pct(2))") }
        if let drawdown = assessment.drawdown20Sessions {
            lines.append("20 日回撤：\(drawdown.pct(2))")
        }
        if let vol = assessment.realizedVolatility20Sessions {
            lines.append("20 日年化波动率：\(vol.pct(1))")
        }
        if !assessment.reasons.isEmpty {
            lines.append("判据：" + assessment.reasons.prefix(4).joined(separator: "；"))
        }
        // 这一条很重要：状态是观察用的，不是操作指令。
        if assessment.observationOnly {
            lines.append("该状态属于「观察级别」：可以据此调整仓位节奏，但不构成买卖指令。")
        }
        if !assessment.ordinaryTBuyAllowed {
            lines.append("当前状态下不建议按「普通做 T」思路操作。")
        }
        return """
        【市场状态（本机按上证指数日线计算，含两个交易日的防抖）】
        · \(lines.joined(separator: "\n· "))
        """
    }

    // MARK: - 多周期 MACD

    /// 日线 + 周线 + 60 分。缺哪个周期就说哪个不可用，不拿别的周期代填。
    static func multiTimeframeMACDSection(store: PortfolioStore) -> String? {
        var lines: [String] = []
        for holding in store.data.holdings.prefix(8) {
            guard let result = store.multiTimeframeMACD(code: holding.code) else { continue }
            var parts: [String] = ["日线 \(result.daily.trend.title)"]
            if let weekly = result.weekly { parts.append("周线 \(weekly.trend.title)") }
            else { parts.append("周线不可用") }
            if let intraday = result.intraday { parts.append("60 分 \(intraday.trend.title)") }
            else { parts.append("60 分不可用") }
            var line = "\(holding.name)（\(holding.code)）：\(parts.joined(separator: " · "))"
            let crosses = [result.daily.cross, result.weekly?.cross, result.intraday?.cross]
                .compactMap { $0 }
                .filter { $0 != .none }
            if !crosses.isEmpty {
                line += "；交叉：\(crosses.map(\.title).joined(separator: "、"))"
            }
            line += "；\(result.resonance)"
            if !result.daily.signalConfirmed { line += "（最新一根未走完）" }
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }
        return """
        【多周期 MACD（日线由本机日 K 计算，周线按自然周聚合，60 分由分钟快照分桶）】
        · \(lines.joined(separator: "\n· "))
        说明：60 分线用的是分钟快照的收盘价（不是真 OHLC），方向可参考，幅度不可精读。未走完的那根不算确认信号。
        """
    }

    /// 单只标的的多周期摘要，给个股分析用。
    static func multiTimeframeMACDLine(store: PortfolioStore, code: String, name: String) -> String? {
        guard let result = store.multiTimeframeMACD(code: code) else { return nil }
        func describe(_ assessment: MACDTimeframeAssessment?) -> String {
            guard let assessment else { return "不可用" }
            var text = assessment.trend.title
            if assessment.cross != .none { text += " · \(assessment.cross.title)" }
            if !assessment.signalConfirmed { text += "（未走完，未确认）" }
            if assessment.dataQuality < 0.98 { text += "（数据\(assessment.qualityLabel)）" }
            return text
        }
        var lines: [String] = []
        lines.append("\(name)（\(code)）")
        lines.append("日线：\(describe(result.daily))")
        lines.append("周线：\(describe(result.weekly))")
        lines.append("60 分：\(describe(result.intraday))")
        lines.append("关系：\(result.relationship)；\(result.resonance)")
        return """
        【多周期 MACD（本机计算，不是外部信号服务）】
        \(lines.joined(separator: "\n"))
        说明：60 分线由分钟快照分桶得到，只用收盘价，不是真 OHLC；未走完的 K 线不算确认信号。
        """
    }

    // MARK: - 已实现业绩

    static func realizedSection(store: PortfolioStore) -> String? {
        let snapshot = store.realizedPerformance
        guard snapshot.sellFillCount > 0 else { return nil }
        var lines: [String] = []
        lines.append("累计卖出 \(snapshot.sellFillCount) 笔，已实现净额 \(snapshot.netRealizedProfit.cny())")
        if let rate = snapshot.instrumentWinRate {
            lines.append("按标的算的卖出胜率 \(rate.pct(0))（赚的标的数 / 有卖出的标的数，不是按笔）")
        }
        if let average = snapshot.averageReturnOnCost {
            lines.append("平均已实现收益率 \(average.pct(2))（分母是卖出的成本基础，不是卖出金额）")
        }
        let top = snapshot.byInstrument.prefix(3)
        if !top.isEmpty {
            lines.append("贡献最大：" + top.map { "\($0.name) \($0.netRealizedProfit.cny())" }.joined(separator: "、"))
        }
        let worst = snapshot.byInstrument.last
        if let worst, worst.netRealizedProfit < 0 {
            lines.append("亏损最大：\(worst.name) \(worst.netRealizedProfit.cny())")
        }
        return """
        【已实现业绩（本机账本按起点 + 逐笔重放，只统计已经卖出的部分）】
        · \(lines.joined(separator: "\n· "))
        """
    }

    // MARK: - 做 T 贡献

    /// 只认「先卖后回补」的配对。先买后卖属于调仓，不算日内回转。
    static func intradayTradeSection(store: PortfolioStore) -> String? {
        let summaries = store.dailyTradeSummaries(limitDays: 30)
        let trips = summaries.flatMap { $0.roundTrips }
        guard !trips.isEmpty else { return nil }
        let total = trips.reduce(0) { $0 + $1.contribution }
        let wins = trips.filter { $0.contribution > 0.01 }.count
        let days = Set(summaries.filter { !$0.roundTrips.isEmpty }.map(\.day)).count
        var lines: [String] = []
        lines.append("近 30 个交易日里，\(days) 天有先卖后回补，共 \(trips.count) 笔配对")
        lines.append("这些配对合计贡献 \(total.cny())，其中 \(wins) 笔为正")
        if let best = trips.first {
            lines.append("最大单笔：\(best.name) \(best.quantity.num(0)) 份，卖 \(best.sellPrice.num(3)) 买回 \(best.buyBackPrice.num(3))，贡献 \(best.contribution.cny())")
        }
        return """
        【日内做 T 贡献（本机账本，只算同日同标的「先卖后回补」）】
        · \(lines.joined(separator: "\n· "))
        说明：先买后卖属于调仓，没有计入；配对部分按比例分摊了两边手续费。
        """
    }

    // MARK: - 决策记忆

    static func decisionMemorySection(store: PortfolioStore) -> String? {
        let entries = DecisionMemoryProjection.build(store.decisionVerdicts())
        return DecisionMemoryProjection.promptText(entries)
    }

    // MARK: - 持仓周期

    /// 按「轮」统计的真实战绩：已了结几轮、赢几轮、平均拿多久。
    /// 与「交易行为画像」不同 —— 那个看的是下单习惯，这里看的是**每一轮拿完的结果**。
    static func episodeSection(store: PortfolioStore) -> String? {
        let instruments = EpisodeProjection.build(from: store.data).instruments
        guard !instruments.isEmpty else { return nil }
        let closed = instruments.flatMap { $0.closedEpisodes }
        guard !closed.isEmpty else {
            return """
            【持仓周期（本机按账本起点 + 逐笔成交还原）】
            目前没有已了结的持仓周期（还没出现「买到清零」的完整回合），不能计算轮次胜率。
            """
        }
        let wins = closed.filter { $0.realized > 0.01 }.count
        let losses = closed.filter { $0.realized < -0.01 }.count
        let days = closed.compactMap { $0.days() }
        let averageDays = days.isEmpty ? 0 : Double(days.reduce(0, +)) / Double(days.count)
        let realized = closed.reduce(0) { $0 + $1.realized }
        let best = closed.max { $0.realized < $1.realized }
        let worst = closed.min { $0.realized < $1.realized }
        let resolved = wins + losses
        let rate = resolved > 0 ? Double(wins) / Double(resolved) * 100 : 0

        var lines: [String] = []
        lines.append("已了结 \(closed.count) 轮：\(wins) 胜 \(losses) 负，胜率 \(rate.num(0))%（只统计有盈亏的回合）")
        lines.append("这些回合合计已实现 \(realized.cny())，平均持有 \(Int(averageDays.rounded())) 天")
        if let best { lines.append("最好的一轮：\(best.name) 第 \(best.number) 轮 \(best.realized.cny())") }
        if let worst { lines.append("最差的一轮：\(worst.name) 第 \(worst.number) 轮 \(worst.realized.cny())") }
        let active = instruments.filter { $0.activeEpisode != nil }
        if !active.isEmpty {
            let parts = active.prefix(6).map { item -> String in
                let days = item.activeEpisode?.days().map { "\($0)" } ?? "未知"
                let cost = item.activeEpisode?.averageCost ?? 0
                return "\(item.name)（\(item.code)）本轮已持有 \(days) 天，成本 \(cost.num(3))"
            }
            lines.append("进行中：" + parts.joined(separator: "；"))
        }
        return """
        【持仓周期（本机按账本起点 + 逐笔成交还原，一轮 = 从建仓到份额清零）】
        · \(lines.joined(separator: "\n· "))
        说明：账本起点之前的历史买入无法还原，第一轮的天数从起点快照时刻起算，可能偏短。
        """
    }

    // MARK: - 账户级成本

    /// 平台费、融资利息、托管费、数据费 —— 不在任何成交流水里，很容易被忽略。
    static func expenseSection(store: PortfolioStore) -> String? {
        let summary = store.expenseSummaryLastYear()
        guard summary.count > 0 else {
            return """
            【账户级成本】
            本机没有记录平台费、融资利息、托管费或数据费。这可能代表真的没有，也可能代表没记 —— 如果是后者，账户真实收益会比这里算出来的低。
            """
        }
        var lines: [String] = []
        lines.append("最近一年记录 \(summary.count) 笔，合计 \(summary.total.cny())")
        if let rate = summary.annualizedRate {
            let basis = summary.usedCurrentAssetFallback ? "（快照不足，分母用的是当前总资产）" : ""
            lines.append("折算年化约占平均总资产的 \(rate.pct(2))\(basis)")
        }
        let top = summary.byCategory.prefix(3).map { "\($0.category.title) \($0.amount.cny())" }
        if !top.isEmpty { lines.append("主要构成：" + top.joined(separator: "、")) }
        return """
        【账户级成本（本机手工记录，不含交易手续费）】
        · \(lines.joined(separator: "\n· "))
        这些是已经花出去的钱，讨论收益时应当扣掉；它们没有计进任何持仓成本。
        """
    }

    // MARK: - 新闻

    /// 市场快讯。只有点名了持仓代码的条目才会被带进来，且明确标注「标题、未核实正文」。
    static func newsSection(store: PortfolioStore) -> String? {
        NewsCenter.shared.evidenceText(forCodes: store.data.holdings.map(\.code))
    }

    // MARK: - 交易行为画像

    static func behaviorSection(store: PortfolioStore) -> String {
        let profile = BehaviorProfile.build(data: store.data, dailyBars: store.dailyBars)
        return """
        【交易行为画像（本机按历史流水统计，不是用户自述；用于判断他的实际习惯与自述是否一致）】
        \(profile.promptText)
        """
    }

    // MARK: - 大盘环境

    /// 首页那一排指数。休市时它们会停在上一交易日，所以每条都带日期。
    static func marketSection(store: PortfolioStore) -> String? {
        let quotes = store.indexQuotes
        guard !quotes.isEmpty else { return nil }
        let lines = quotes.prefix(8).map { quote -> String in
            let percent = (quote.changePct * 100).num(2)
            let when = quote.updatedAt.map { shortDay($0) } ?? "时间未知"
            return "\(quote.name) \(quote.price.num(2)) \(quote.changePct.directionMark())\(percent)%（\(when)）"
        }
        return """
        【大盘与外部环境（本机行情，可能非实时；休市时会停在上一交易日）】
        \(lines.joined(separator: "；"))
        """
    }

    // MARK: - 组合结构与风险

    static func portfolioRiskSection(store: PortfolioStore) -> String? {
        let holdings = store.data.holdings.filter { $0.marketValue > 0 }
        let total = store.totalAsset
        guard total > 0, !holdings.isEmpty else { return nil }

        var lines: [String] = []
        let weights = holdings.map { $0.marketValue / total * 100 }.sorted(by: >)
        if let top = weights.first {
            lines.append("最大单一持仓占总资产 \(top.num(1))%")
        }
        // HHI 用「占比平方和 ÷ 10000」：1 = 全压一只，越小越分散。
        let hhi = weights.reduce(0) { $0 + $1 * $1 } / 10_000
        lines.append("持仓集中度 HHI \(hhi.num(3))（1 = 全部压一只）")
        lines.append("现金占总资产 \((store.data.cash / total * 100).num(1))%")

        // 快照口径的回撤与波动。快照不是每日都有，所以必须写明口径，
        // 否则 AI 会把这个数当成「日频最大回撤」。
        let totals = store.data.snapshots.sorted { $0.date < $1.date }.map(\.total)
        if totals.count >= 5 {
            var peak = totals[0]
            var maxDrawdown = 0.0
            for value in totals {
                peak = max(peak, value)
                if peak > 0 { maxDrawdown = max(maxDrawdown, (peak - value) / peak * 100) }
            }
            lines.append("快照口径最大回撤 \(maxDrawdown.num(2))%（共 \(totals.count) 条快照，非日频）")

            let returns = zip(totals, totals.dropFirst()).compactMap { previous, current -> Double? in
                previous > 0 ? (current - previous) / previous * 100 : nil
            }
            if returns.count >= 5 {
                let mean = returns.reduce(0, +) / Double(returns.count)
                let variance = returns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(returns.count)
                lines.append("快照间波动率（标准差）\(variance.squareRoot().num(2))%")
            }
        }

        return """
        【组合结构与风险（本机计算）】
        · \(lines.joined(separator: "\n· "))
        """
    }

    // MARK: - 技术面

    /// 按**已缓存的**日 K 算均线与区间。没缓存过的标的直接跳过 ——
    /// 与其在分析时临时发一串请求让按钮转半天，不如少给一段。
    static func technicalSection(store: PortfolioStore, codes: [String]) -> String? {
        var lines: [String] = []
        // 最多只放 8 只：再多会把 prompt 撑长，而技术面本来就只是补充材料。
        let targets = Array(codes.prefix(8))
        for code in targets {
            guard let bars = store.dailyBars[code], bars.count >= 20 else { continue }
            let closes = bars.map(\.close)
            guard let last = closes.last, last > 0 else { continue }
            var parts: [String] = []
            for period in [5, 20, 60, 250] {
                guard let ma = movingAverage(closes, period: period), ma > 0 else { continue }
                let distance = (last - ma) / ma * 100
                parts.append("MA\(period) \(ma.num(2))（现价在其\(distance >= 0 ? "上" : "下")方 \(abs(distance).num(1))%）")
            }
            let window = Array(bars.suffix(60))
            let high = window.map(\.high).max() ?? last
            let low = window.map(\.low).min() ?? last
            let name = store.data.holdings.first { $0.code == code }?.name
                ?? store.data.quotes.first { $0.code == code }?.name ?? code
            lines.append("\(name)（\(code)）：\(parts.isEmpty ? "均线样本不足" : parts.joined(separator: "、"))；近 60 日区间 \(low.num(2))–\(high.num(2))，最新一根 \(bars.last?.date ?? "--")")
        }
        guard !lines.isEmpty else { return nil }
        return """
        【技术面（本机按已缓存的日 K 计算，未缓存的标的不在此列）】
        · \(lines.joined(separator: "\n· "))
        """
    }

    // MARK: - 辅助

    private static func movingAverage(_ values: [Double], period: Int) -> Double? {
        guard period > 0, values.count >= period else { return nil }
        let slice = values.suffix(period)
        let sum = slice.reduce(0, +)
        guard sum.isFinite, sum > 0 else { return nil }
        return sum / Double(period)
    }
}
