import Foundation

/// 本机统计的「交易行为画像」。
///
/// **存在的理由**：喂给 AI 的原始材料只有「最近 30 笔流水」，AI 得自己数；
/// 而真正定义一个人的东西 —— 胜率、一笔拿多久、是越跌越买还是追涨、
/// 卖完之后是不是又涨上去了 —— 都藏在那几十行流水里，AI 靠肉眼数不出来，
/// 数出来也容易错。这里把它们算成一段人话，让 AI 看的是
/// 「你怎么做决策」，而不只是「你现在持有什么」。
///
/// 全部在本机算，**不产生任何网络请求**，也不改变任何账本数据。
/// 样本不够时对应的字段留 nil，界面和 prompt 都写「样本不足」而不是硬给一个数。
struct BehaviorProfile {
    // 已实现交易
    var closedCount = 0
    var etfClosedCount = 0
    var fundClosedCount = 0
    var winCount = 0
    var lossCount = 0
    var totalProfit = 0.0
    var totalLoss = 0.0

    // 持有周期（FIFO 匹配买卖批次算出来的自然日）
    var overallHoldingDays: Double?
    var etfHoldingDays: Double?
    var fundHoldingDays: Double?

    // 加仓节奏：买入时标的近 20 个交易日是涨还是跌
    var buyOnDipRatio: Double?
    var dipSampleCount = 0

    // 卖出后回看：卖出后 10 个交易日内是否创出更高价
    var sellTooEarlyRatio: Double?
    var averageMissedGain: Double?
    var sellSampleCount = 0

    // 仓位纪律
    var maxPositionUsed: Double?
    var positionCap: Double?

    // 交易频率
    var tradesPerMonth: Double?

    var winRate: Double? {
        let decided = winCount + lossCount
        guard decided >= 5 else { return nil }
        return Double(winCount) / Double(decided) * 100
    }

    var profitFactor: Double? {
        guard totalLoss > 0.01, winCount + lossCount >= 5 else { return nil }
        return totalProfit / totalLoss
    }

    /// 样本是否足够支撑结论。不足时 prompt 里会明确写出来，
    /// 免得 AI 拿 3 笔交易总结出一套「你的交易风格」。
    var hasEnoughSamples: Bool { closedCount >= 8 }

    // MARK: - 计算

    /// 事件（买入/卖出）的统一形态，ETF 流水与基金申赎都归一到这里。
    private struct Event {
        let date: Date
        let code: String
        let isBuy: Bool
        let quantity: Double
        let price: Double
    }

    static func build(data: PortfolioData, dailyBars: [String: [DailyBar]]) -> BehaviorProfile {
        var profile = BehaviorProfile()

        let etfEvents = data.ledger.map {
            Event(date: $0.date, code: $0.code, isBuy: $0.side == .buy,
                  quantity: $0.quantity, price: $0.price)
        }
        let fundEvents = data.fundTransactions.compactMap { trade -> Event? in
            guard trade.side != .dividend, let date = parseDay(trade.effectiveDate) else { return nil }
            return Event(date: date, code: trade.code, isBuy: trade.side == .buy,
                         quantity: trade.quantity, price: trade.nav)
        }

        // ---- 已实现盈亏 ----
        var sellPnLs: [Double] = []
        for entry in data.ledger where entry.side == .sell {
            guard entry.realizedPnL.isFinite else { continue }
            sellPnLs.append(entry.realizedPnL)
            profile.etfClosedCount += 1
        }
        for trade in data.fundTransactions where trade.side == .sell {
            guard trade.realizedPnL.isFinite else { continue }
            sellPnLs.append(trade.realizedPnL)
            profile.fundClosedCount += 1
        }
        profile.closedCount = sellPnLs.count
        profile.winCount = sellPnLs.filter { $0 > 0.005 }.count
        profile.lossCount = sellPnLs.filter { $0 < -0.005 }.count
        profile.totalProfit = sellPnLs.filter { $0 > 0 }.reduce(0, +)
        profile.totalLoss = abs(sellPnLs.filter { $0 < 0 }.reduce(0, +))

        // ---- 持有周期 ----
        let etfDurations = fifoHoldingDays(etfEvents)
        let fundDurations = fifoHoldingDays(fundEvents)
        profile.etfHoldingDays = mean(etfDurations)
        profile.fundHoldingDays = mean(fundDurations)
        profile.overallHoldingDays = mean(etfDurations + fundDurations)

        // ---- 加仓节奏：买入时标的近 20 个交易日是涨还是跌 ----
        let buys = (etfEvents + fundEvents).filter { $0.isBuy }
        var dipBuys = 0
        var dipSamples = 0
        for buy in buys {
            guard let bars = dailyBars[buy.code], bars.count > 21 else { continue }
            guard let trend = priorTrend(bars: bars, on: buy.date, lookback: 20) else { continue }
            dipSamples += 1
            if trend < 0 { dipBuys += 1 }
        }
        profile.dipSampleCount = dipSamples
        if dipSamples >= 5 {
            profile.buyOnDipRatio = Double(dipBuys) / Double(dipSamples) * 100
        }

        // ---- 卖出后回看 ----
        let sells = (etfEvents + fundEvents).filter { !$0.isBuy }
        var missed: [Double] = []
        for sell in sells {
            guard let bars = dailyBars[sell.code], sell.price > 0 else { continue }
            guard let gain = missedGain(bars: bars, on: sell.date, sellPrice: sell.price, window: 10) else { continue }
            missed.append(gain)
        }
        profile.sellSampleCount = missed.count
        if missed.count >= 5 {
            let tooEarly = missed.filter { $0 > 1.5 }.count
            profile.sellTooEarlyRatio = Double(tooEarly) / Double(missed.count) * 100
            profile.averageMissedGain = missed.reduce(0, +) / Double(missed.count)
        }

        // ---- 仓位纪律 ----
        let totalAsset = data.holdings.reduce(0) { $0 + $1.marketValue } + data.cash
        if totalAsset > 1 {
            profile.maxPositionUsed = data.holdings.map { $0.marketValue / totalAsset * 100 }.max()
        }
        profile.positionCap = data.investmentProfile.maxPositionPercent

        // ---- 交易频率 ----
        let allDates = etfEvents.map(\.date) + fundEvents.map(\.date)
        if let first = allDates.min(), let last = allDates.max(), allDates.count >= 3 {
            let months = max(1.0, last.timeIntervalSince(first) / (86_400 * 30.4))
            profile.tradesPerMonth = Double(allDates.count) / months
        }

        return profile
    }

    // MARK: - 注入 prompt 的文本

    /// 拼成一段给 AI 的补充材料。没有的项直接不写 —— 空白比「样本不足」的占位更省 token，
    /// 但**整体样本不足时必须显式说出来**，否则 AI 会拿几笔交易硬总结风格。
    var promptText: String {
        guard closedCount > 0 || dipSampleCount > 0 || sellSampleCount > 0 else {
            return "（暂无可统计的交易流水，行为画像为空。不要凭空推断交易风格。）"
        }
        var lines: [String] = []

        if closedCount > 0 {
            var line = "已实现卖出 \(closedCount) 笔（ETF/证券 \(etfClosedCount) 笔、场外基金 \(fundClosedCount) 笔）"
            if let winRate = winRate {
                line += "：胜率 \(winRate.num(0))%（\(winCount) 胜 / \(lossCount) 负）"
                if let pf = profitFactor {
                    line += "，盈亏比 \(pf.num(2))（总盈利 ÷ 总亏损）"
                }
            } else {
                let needed = max(0, 5 - (winCount + lossCount))
                line += "：还需 \(needed) 笔才能给出胜率"
            }
            lines.append("· " + line)
        }

        if let days = overallHoldingDays {
            var line = "平均持有 \(days.num(0)) 天"
            var parts: [String] = []
            if let etf = etfHoldingDays { parts.append("ETF \(etf.num(0)) 天") }
            if let fund = fundHoldingDays { parts.append("场外基金 \(fund.num(0)) 天") }
            if !parts.isEmpty { line += "（\(parts.joined(separator: "、"))）" }
            lines.append("· " + line)
        }

        if let dip = buyOnDipRatio {
            let style = dip >= 65 ? "偏左侧，越跌越买" : (dip <= 35 ? "偏右侧，追强势买入" : "涨跌都买，没有明显的择时偏好")
            lines.append("· 加仓时点：\(dip.num(0))% 的买入发生在标的近 20 个交易日下跌之后（\(style)）")
        }

        if let early = sellTooEarlyRatio, let missedGain = averageMissedGain {
            let style = early >= 55 ? "卖得偏早" : (early <= 30 ? "卖出时点拿得比较稳" : "卖出时点不算激进也不算保守")
            lines.append("· 卖出后回看：\(early.num(0))% 的卖出在 10 个交易日内被更高价超过，平均少赚 \(missedGain.num(2))%（\(style)）")
        }

        if let used = maxPositionUsed, let cap = positionCap, cap > 0 {
            let note = used > cap ? "⚠️ 已经超过自设上限" : "在自设上限之内"
            lines.append("· 单标的仓位：当前最大一只占总资产 \(used.num(1))%，自设上限 \(cap.num(1))%（\(note)）")
        }

        if let rate = tradesPerMonth {
            lines.append("· 交易频率：平均每月 \(rate.num(1)) 笔")
        }

        if !hasEnoughSamples {
            lines.append("· ⚠️ 卖出样本仅 \(closedCount) 笔，下面的胜率/盈亏比只能当倾向参考，不足以支撑「你的交易风格是……」这类结论。")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 辅助

    private static func parseDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func mean(_ values: [Double]) -> Double? {
        let clean = values.filter { $0.isFinite && $0 >= 0 }
        guard !clean.isEmpty else { return nil }
        return clean.reduce(0, +) / Double(clean.count)
    }

    /// FIFO 匹配买卖批次，得到每笔卖出实际对应的持有天数。
    ///
    /// 不用「当前持仓的成本」反推：那是加权平均，看不出「拿了多久才卖」这件事。
    private static func fifoHoldingDays(_ events: [Event]) -> [Double] {
        var lots: [String: [(date: Date, remaining: Double)]] = [:]
        var durations: [Double] = []
        for event in events.sorted(by: { $0.date < $1.date }) {
            if event.isBuy {
                lots[event.code, default: []].append((event.date, event.quantity))
                continue
            }
            var need = event.quantity
            var cursor = 0
            while need > 0.000001, var queue = lots[event.code], cursor < queue.count {
                let take = min(need, queue[cursor].remaining)
                if take > 0.000001 {
                    durations.append(event.date.timeIntervalSince(queue[cursor].date) / 86_400)
                }
                queue[cursor].remaining -= take
                need -= take
                cursor += 1
                lots[event.code] = queue
            }
        }
        return durations
    }

    /// 买入日之前，标的近 `lookback` 个交易日的涨跌幅（%）。正数=买在上涨之后。
    private static func priorTrend(bars: [DailyBar], on date: Date, lookback: Int) -> Double? {
        let day = MarketCalendar.isoDay(date)
        let series = bars.filter { $0.date <= day }
        guard series.count > lookback else { return nil }
        let latest = series[series.count - 1].close
        let past = series[series.count - 1 - lookback].close
        guard past > 0, latest > 0 else { return nil }
        return (latest - past) / past * 100
    }

    /// 卖出日之后 `window` 个交易日内，最高价比卖出价高多少（%）。
    private static func missedGain(bars: [DailyBar], on date: Date, sellPrice: Double, window: Int) -> Double? {
        let day = MarketCalendar.isoDay(date)
        let after = bars.filter { $0.date > day }.prefix(window)
        guard !after.isEmpty, sellPrice > 0 else { return nil }
        let high = after.map(\.high).max() ?? 0
        guard high > 0 else { return nil }
        return (high - sellPrice) / sellPrice * 100
    }
}
