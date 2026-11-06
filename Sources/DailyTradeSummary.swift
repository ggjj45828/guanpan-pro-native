import Foundation

/// 一笔「先卖后回补」的配对。
///
/// 这是判断「做 T 到底赚没赚」的唯一可靠口径：只有同一天、同一标的、
/// **先卖出、再用更低（或更高）的价格买回来**的那部分，才叫日内回转贡献。
/// 「先买后卖」不算 —— 那是加仓后减仓，属于调仓，把它算成做 T 会虚增成绩。
struct TradeRoundTrip: Identifiable {
    let id: UUID
    let code: String
    let name: String
    let kind: Holding.Kind
    let at: Date
    let quantity: Double
    let sellPrice: Double
    let buyBackPrice: Double
    /// 配对部分分摊到的费用。
    let feeShare: Double

    var contribution: Double { (sellPrice - buyBackPrice) * quantity - feeShare }
    var perShare: Double { sellPrice - buyBackPrice }
}

struct TradeDaySummary: Identifiable {
    var id: String { day }
    let day: String
    let date: Date
    let fills: [LedgerEntry]
    let buyAmount: Double
    let sellAmount: Double
    let fees: Double
    /// 当日成交里记录的已实现盈亏（含全部卖出）。
    let realized: Double
    let roundTrips: [TradeRoundTrip]

    /// 只算「先卖后回补」那部分。
    var intradayContribution: Double { roundTrips.reduce(0) { $0 + $1.contribution } }
    /// 当日总费用（成交手续费 + 配对已含的费用不重复加）。
    var turnover: Double { buyAmount + sellAmount }
}

enum DailyTradeSummaryBuilder {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// 按交易日汇总。最近的在前面，默认最多 60 天。
    static func build(data: PortfolioData, limitDays: Int = 60) -> [TradeDaySummary] {
        // 导入的历史流水只留档、不动余额，也不该参与「今天做 T 了没」的统计。
        let usable = data.ledger.filter { $0.affectsHoldings != false }
        var buckets: [String: [LedgerEntry]] = [:]
        for fill in usable {
            buckets[dayKey(fill.date), default: []].append(fill)
        }
        let summaries = buckets.keys.sorted(by: >).compactMap { day -> TradeDaySummary? in
            guard let fills = buckets[day], let first = fills.first else { return nil }
            let ordered = fills.sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.date < rhs.date
            }
            let buyAmount = ordered.filter { $0.side == .buy }.reduce(0) { $0 + $1.gross }
            let sellAmount = ordered.filter { $0.side == .sell }.reduce(0) { $0 + $1.gross }
            let fees = ordered.reduce(0) { $0 + max(0, $1.fee) }
            let realized = ordered.reduce(0) { $0 + $1.realizedPnL }
            return TradeDaySummary(day: day,
                                   date: first.date,
                                   fills: ordered,
                                   buyAmount: buyAmount,
                                   sellAmount: sellAmount,
                                   fees: fees,
                                   realized: realized,
                                   roundTrips: roundTrips(in: ordered))
        }
        return Array(summaries.prefix(max(0, limitDays)))
    }

    /// 同日同标的的「先卖后回补」配对。
    static func roundTrips(in orderedFills: [LedgerEntry]) -> [TradeRoundTrip] {
        var trips: [TradeRoundTrip] = []
        // 按标的分开走各自的「未回补卖出」队列。
        var pendingSells: [String: [(qty: Double, price: Double, feePerUnit: Double, id: UUID, at: Date)]] = [:]

        // 先扫一遍收集买入批次，才能让「卖出在前、买入在后」正确配对：
        // 真正的规则是「卖出之后又有买入」，所以下面按时间顺序走，
        // 卖出压栈，遇到买入才消费。
        for fill in orderedFills {
            let key = "\(fill.code)|\((fill.kind ?? .etf).rawValue)"
            let feePerUnit = fill.quantity > 0 ? max(0, fill.fee) / fill.quantity : 0
            switch fill.side {
            case .sell:
                pendingSells[key, default: []].append((fill.quantity, fill.price, feePerUnit, fill.id, fill.date))
            case .buy:
                var remaining = fill.quantity
                while remaining > 1e-9, var queue = pendingSells[key], !queue.isEmpty {
                    var sell = queue[0]
                    let matched = min(remaining, sell.qty)
                    if matched > 1e-9 {
                        trips.append(TradeRoundTrip(id: sell.id,
                                                    code: fill.code,
                                                    name: fill.name,
                                                    kind: fill.kind ?? .etf,
                                                    at: sell.at,
                                                    quantity: matched,
                                                    sellPrice: sell.price,
                                                    buyBackPrice: fill.price,
                                                    feeShare: matched * (sell.feePerUnit + feePerUnit)))
                    }
                    sell.qty -= matched
                    remaining -= matched
                    if sell.qty <= 1e-9 { queue.removeFirst() } else { queue[0] = sell }
                    pendingSells[key] = queue
                }
                // 没被卖出覆盖的那部分买入就是普通加仓，不计入做 T。
            }
        }
        // 排序：贡献绝对值大的在前，方便一眼看到最赚/最亏的那几笔。
        return trips.sorted { abs($0.contribution) > abs($1.contribution) }
    }
}

extension PortfolioStore {
    func dailyTradeSummaries(limitDays: Int = 60) -> [TradeDaySummary] {
        DailyTradeSummaryBuilder.build(data: data, limitDays: limitDays)
    }

    /// 最近 N 天的做 T 汇总。只统计有配对回转的交易日。
    func intradayContributionSummary(days: Int = 30) -> (days: Int, trips: Int, total: Double) {
        let summaries = dailyTradeSummaries(limitDays: days)
        let trips = summaries.flatMap { $0.roundTrips }
        return (summaries.filter { !$0.roundTrips.isEmpty }.count,
                trips.count,
                trips.reduce(0) { $0 + $1.contribution })
    }
}
