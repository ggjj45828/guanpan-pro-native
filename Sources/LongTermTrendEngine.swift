import Foundation

// MARK: - 长期趋势（日线 MA250）
//
// 分级：计算定义 + 证据。它只回答两个事实问题：
// 「现价相对 250 日均线在什么位置」「250 日均线本身是上行还是下行」。
// **不是**买卖信号：站上 MA250 也可能继续跌，跌破也可能反弹。
//
// 诚实边界（写死在这里，避免以后被「顺手补一个」破坏）：
// - 日线不足 250 根 → 不给 MA250。**不拿 MA120 冒充「长期」**。
// - 120 分周期要 250 根 ≈ 125 个交易日，本机日内快照远达不到 → 明确标注不可算，
//   绝不用「120 分 MA60」这种 7 个交易日的东西冒充长期趋势。
// - 斜率需要 270 根（250 + 20 根回看），不够就返回 nil，不外推。
struct LongTermTrend: Equatable, Sendable {
    enum Position: String, Equatable, Sendable {
        /// 现价在 MA250 上方。
        case above
        /// 现价在 MA250 下方。
        case below
        /// 距 MA250 在 ±2% 内。
        case near
        /// 数据不足，无法判断。
        case unavailable

        var title: String {
            switch self {
            case .above: return "线上"
            case .below: return "线下"
            case .near: return "贴合均线"
            case .unavailable: return "不可判断"
            }
        }
    }

    let price: Double?
    let ma250: Double?
    let ma60: Double?
    let position: Position
    /// 现价距 MA250 的百分比（正=在上方）。
    let distancePercent: Double?
    /// MA250 近 20 根的变化百分比。
    let ma250SlopePercent: Double?
    let isRising: Bool?
    let dailyBarsUsed: Int
    let notes: [String]
}

enum LongTermTrendEngine {
    static let longPeriod = 250
    static let midPeriod = 60
    static let slopeLookback = 20
    /// 距 MA250 在 ±2% 内算「贴合」。
    static let nearBandPercent = 2.0

    static func evaluate(dailyBars: [DailyBar], price: Double?) -> LongTermTrend {
        let closes = dailyBars.map(\.close).filter { $0.isFinite && $0 > 0 }
        var notes: [String] = []

        var reference: Double?
        if let price, price.isFinite, price > 0 {
            reference = price
        } else if let last = closes.last {
            reference = last
            notes.append("没有有效现价，用最近收盘代替")
        }

        let ma250 = average(closes, longPeriod)
        let ma60 = average(closes, midPeriod)

        if ma250 == nil {
            notes.append("日线只有 \(closes.count) 根，不足 \(longPeriod) 根：不给 MA250，也不拿 MA120 冒充长期")
        }

        var slope: Double?
        var rising: Bool?
        if closes.count >= longPeriod + slopeLookback, let ma250 {
            let earlierCloses = Array(closes.dropLast(slopeLookback))
            if let earlier = average(earlierCloses, longPeriod), earlier > 0 {
                let change = (ma250 - earlier) / earlier * 100
                if change.isFinite {
                    slope = change
                    rising = change > 0
                }
            }
        } else if ma250 != nil {
            notes.append("日线不足 \(longPeriod + slopeLookback) 根，算不出 MA250 斜率")
        }

        var position: LongTermTrend.Position = .unavailable
        var distance: Double?
        if let ma250, ma250 > 0, let reference {
            let gap = (reference - ma250) / ma250 * 100
            if gap.isFinite {
                distance = gap
                if abs(gap) <= nearBandPercent {
                    position = .near
                } else if gap > 0 {
                    position = .above
                } else {
                    position = .below
                }
            }
        }

        notes.append("长期趋势只用日线判断；120 分要 250 根≈125 个交易日才够，本机日内快照达不到，因此不提供 120 分长期均线")

        return LongTermTrend(price: reference,
                             ma250: ma250,
                             ma60: ma60,
                             position: position,
                             distancePercent: distance,
                             ma250SlopePercent: slope,
                             isRising: rising,
                             dailyBarsUsed: dailyBars.count,
                             notes: notes)
    }

    /// 最近 period 根的算术平均；不足 period 或结果非正返回 nil。
    private static func average(_ values: [Double], _ period: Int) -> Double? {
        guard period > 0, values.count >= period else { return nil }
        let window = values.suffix(period)
        let sum = window.reduce(0, +)
        guard sum.isFinite, sum > 0 else { return nil }
        return sum / Double(period)
    }
}
