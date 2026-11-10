import Foundation

/// 组合估值的严格口径。
///
/// 之前 `totalAsset` 是 `holdings.reduce(marketValue) + cash`：只要有一只持仓的报价
/// 是三天前的缓存，这个总额照样算得出来、照样显示成「总资产」—— 数字看起来是确定的，
/// 实际是拿旧价当现价。AI 分析、仓位百分比、再平衡提醒全都建立在这个数上，
/// 一个陈旧报价会一路污染到建议里。
///
/// 这里的规则：**要么全部可信，要么明确说不可信**，绝不返回部分值。
enum PortfolioValuationFailure: Error, Equatable {
    /// 有持仓但完全拿不到报价。
    case missingQuote([String])
    /// 有报价但不新鲜、或来源不在白名单。
    case staleQuote([String])
    /// 持仓数据本身不合法（份额为负、价格为 0）。
    case invalidPosition([String])

    var codes: [String] {
        switch self {
        case .missingQuote(let codes), .staleQuote(let codes), .invalidPosition(let codes):
            return codes
        }
    }

    var title: String {
        switch self {
        case .missingQuote: return "缺少报价"
        case .staleQuote: return "报价已过期"
        case .invalidPosition: return "持仓数据异常"
        }
    }
}

struct PortfolioValuation {
    let cash: Double
    let holdingsValue: Double
    let total: Double
    /// 用到的所有报价里最早的那个时间。显示「估值截至」时用它，
    /// 不能拿本地当前时间冒充。
    let quotesAsOf: Date?
    /// 非致命降级说明（手动覆盖价等）。有内容时界面要标出来。
    let degradedReasons: [String]
}

enum PortfolioValuationEngine {
    /// 求值。`session` 传当前时段，非交易时段只要求报价落在最近交易日。
    static func evaluate(data: PortfolioData,
                         session: MarketSessionStatus,
                         now: Date = .now) -> Result<PortfolioValuation, PortfolioValuationFailure> {
        guard now.timeIntervalSince1970.isFinite, data.cash.isFinite else {
            return .failure(.invalidPosition([]))
        }
        let quoteMap = Dictionary(data.quotes.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        let custom = data.customMarketHolidays

        var holdingsValue = 0.0
        var missing: [String] = []
        var stale: [String] = []
        var invalid: [String] = []
        var timestamps: [Date] = []
        var degraded: [String] = []
        var manualCount = 0

        for holding in data.holdings {
            guard holding.quantity > 0 else {
                // 份额为 0 的残留行不该拖垮估值，但也不能当成有市值。
                if holding.quantity < 0 { invalid.append(holding.code) }
                continue
            }
            switch holding.kind {
            case .etf:
                let quote = quoteMap[holding.code]
                let price = quote?.price ?? holding.current
                guard price.isFinite, price > 0 else {
                    missing.append(holding.code); continue
                }
                if let quote {
                    let temporal = quote.temporal(in: session)
                    let freshness = temporal.freshness(at: now, custom: custom)
                    if QuoteSourceTrust.isManual(quote.source) {
                        // 手动覆盖价：用户主动选的，允许计入，但必须标出来。
                        manualCount += 1
                    } else {
                        switch freshness {
                        case .fresh:
                            if let timestamp = quote.updatedAt { timestamps.append(timestamp) }
                        case .stale:
                            stale.append(holding.code)
                        case .unverified:
                            // 老备份里的缓存报价没有来源标签 —— 无法验证，按过期处理。
                            stale.append(holding.code)
                        }
                    }
                } else {
                    // 持仓有价、自选里没有这条报价：只能用 holding.current，
                    // 它的时间戳是 `marketUpdatedAt`。
                    guard let updatedAt = holding.marketUpdatedAt else {
                        missing.append(holding.code); continue
                    }
                    let synthetic = QuoteTemporal(quoteTimestamp: updatedAt,
                                                  fetchedAt: updatedAt,
                                                  source: QuoteSourceTrust.tencentDirect,
                                                  session: session)
                    if synthetic.freshness(at: now, custom: custom) == .fresh {
                        timestamps.append(updatedAt)
                    } else {
                        stale.append(holding.code)
                    }
                }
                holdingsValue += holding.quantity * price

            case .fund:
                // 场外基金已下线：遗留数据在加载时就被清掉，这里只是兜底跳过。
                continue
            }
        }

        if !invalid.isEmpty { return .failure(.invalidPosition(invalid.sorted())) }
        if !missing.isEmpty { return .failure(.missingQuote(missing.sorted())) }
        if !stale.isEmpty { return .failure(.staleQuote(stale.sorted())) }

        if manualCount > 0 {
            degraded.append("\(manualCount) 项用了手动覆盖价")
        }

        let total = holdingsValue + data.cash
        guard total.isFinite, holdingsValue.isFinite else {
            return .failure(.invalidPosition([]))
        }
        return .success(PortfolioValuation(cash: data.cash,
                                           holdingsValue: holdingsValue,
                                           total: total,
                                           quotesAsOf: timestamps.min(),
                                           degradedReasons: degraded))
    }
}
