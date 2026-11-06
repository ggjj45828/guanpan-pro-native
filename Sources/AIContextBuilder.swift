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
        if let risk = portfolioRiskSection(store: store) { sections.append(risk) }
        if let tech = technicalSection(store: store, codes: store.data.holdings.map(\.code)) {
            sections.append(tech)
        }
        if let episodes = episodeSection(store: store) { sections.append(episodes) }
        if let cost = expenseSection(store: store) { sections.append(cost) }
        if let news = newsSection(store: store) { sections.append(news) }
        return sections
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
