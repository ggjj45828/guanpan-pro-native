import Foundation

// MARK: - 数据置信度：出价前的硬门槛

/// 每条具体交易建议都必须能回答：行情多新、样本多长、依据是什么、置信度多少。
/// 置信度不足时**禁止生成伪精确的挂单价格**——宁可说「今天无法给出可靠挂单价」。
struct NextDataConfidence: Equatable {
    enum Level: String, Equatable {
        case high = "高"
        case medium = "中"
        case low = "低"
        case blocked = "不足以出价"
    }
    let level: Level
    let quoteAgeSeconds: Int?
    let quoteSource: String
    let dailyBarCount: Int
    let minuteSampleCount: Int
    let minuteCompletenessPercent: Double
    let missing: [String]
    let summary: String

    /// 做 T 出价门槛：行情 2 分钟内、日 K ≥20 根、分时 ≥30 点。
    var canPriceTPlan: Bool {
        level != .blocked && dailyBarCount >= 20 && minuteSampleCount >= 30 && (quoteAgeSeconds ?? 9_999) <= 120
    }
    /// 网格出价门槛：行情 2 分钟内、日 K ≥60 根（与网格适合度引擎的样本要求一致）。
    var canPriceGridPlan: Bool {
        level != .blocked && dailyBarCount >= 60 && (quoteAgeSeconds ?? 9_999) <= 120
    }

    /// `intradayRequired` 默认 true（做 T 需要分时点估算价位）。
    /// 网格按「日 K ≥60 + 新鲜报价 + NAS 长期区间」出价，本地的当日分时点不是它的硬门槛，
    /// 传 false 时不再因缺分时而判 blocked。
    static func assess(quote: NextQuote?, now: Date, dailyBarCount: Int, minuteSampleCount: Int,
                       intradayRequired: Bool = true) -> NextDataConfidence {
        var missing: [String] = []
        let age: Int?
        let source: String
        if let quote {
            age = max(0, Int(now.timeIntervalSince(quote.time)))
            source = quote.source
            if !quote.hasReliableMarketTime { missing.append("该行情源没有可核验的供应商时间戳，仅记录接收时间；不能据此生成具体挂单价") }
            if quote.time > now.addingTimeInterval(60) { missing.append("行情时间戳超前超过 60 秒，数据时钟异常") }
            if let age, age > 120 { missing.append("行情时间已过 \(age / 60) 分钟，超过 2 分钟新鲜度门槛") }
        } else {
            age = nil
            source = "无行情缓存"
            missing.append("当前没有可用报价")
        }
        if dailyBarCount < 20 { missing.append("日 K 仅 \(dailyBarCount) 根，识别市场状态至少需要 20 根") }
        if intradayRequired && minuteSampleCount < 30 { missing.append("今日分时仅 \(minuteSampleCount) 点，估算做 T 价格至少需要 30 点") }
        let completeness = min(1.0, Double(minuteSampleCount) / 240.0) * 100
        let staleQuote = (age ?? 9_999) > 120
        let futureQuote = quote.map { $0.time > now.addingTimeInterval(60) } ?? false
        let blocked = staleQuote || futureQuote || quote?.hasReliableMarketTime != true || dailyBarCount < 20 || (intradayRequired && minuteSampleCount < 30)
        let level: Level
        if blocked { level = .blocked }
        else if (age ?? 9_999) <= 60 && dailyBarCount >= 60 && minuteSampleCount >= 120 { level = .high }
        else if dailyBarCount >= 40 && minuteSampleCount >= 60 { level = .medium }
        else { level = .low }
        let summary: String
        switch level {
        case .high: summary = "行情 \(age ?? 0) 秒前 · 日 K \(dailyBarCount) 根 · 分时 \(minuteSampleCount) 点（\(Int(completeness.rounded()))%）· \(source)"
        case .medium: summary = "行情 \(age ?? 0) 秒前 · 日 K \(dailyBarCount) 根 · 分时 \(minuteSampleCount) 点 · \(source)"
        case .low: summary = "行情 \(age ?? 0) 秒前 · 样本偏少（日 K \(dailyBarCount) 根 / 分时 \(minuteSampleCount) 点）· \(source)"
        case .blocked: summary = missing.isEmpty ? "数据不足" : "数据不足：\(missing.joined(separator: "；"))"
        }
        return NextDataConfidence(level: level, quoteAgeSeconds: age, quoteSource: source,
                                  dailyBarCount: dailyBarCount, minuteSampleCount: minuteSampleCount,
                                  minuteCompletenessPercent: completeness, missing: missing, summary: summary)
    }

    /// NAS 长期数据过期 / 不够时降一档，并把原因写进摘要。
    /// 绝不因为「看起来还能算」就假装数据是新的。
    func downgraded(_ reason: String) -> NextDataConfidence {
        guard !reason.isEmpty else { return self }
        let newLevel: Level
        switch level {
        case .high: newLevel = .medium
        case .medium: newLevel = .low
        case .low, .blocked: newLevel = level
        }
        return NextDataConfidence(level: newLevel, quoteAgeSeconds: quoteAgeSeconds, quoteSource: quoteSource,
                                  dailyBarCount: dailyBarCount, minuteSampleCount: minuteSampleCount,
                                  minuteCompletenessPercent: minuteCompletenessPercent,
                                  missing: missing, summary: summary + "；" + reason)
    }
}

/// NAS 长期区间：用 20/60 日分时归档算出「历史上真正走过的价格带」。
/// 网格上下界必须落在它里面——超出历史区间的档位没有依据，不挂。
struct NextNasRange: Equatable {
    let low: Decimal
    let high: Decimal
    let days: Int
    let source: String
    var isValid: Bool { low > 0 && high > low }

    init?(stats: NextNASMinuteStats?, prefer: [Int] = [60]) {
        guard let stats, stats.quality.enoughForLongTerm, stats.days >= 60,
              stats.quality.minuteCoverage >= 0.8,
              (stats.quality.volumeCoverage ?? 0) >= 0.8,
              !stats.freshness.stale else { return nil }
        for count in prefer {
            guard let window = stats.window(count) else { continue }
            guard window.daysUsed >= 60, window.dayCoverage >= 0.8,
                  (window.volumeCoverage ?? 0) >= 0.8 else { continue }
            let lowText = window.supportP10 ?? window.support
            let highText = window.resistanceP90 ?? window.resistance
            guard let lowText, let highText,
                  let low = Decimal(string: lowText), let high = Decimal(string: highText),
                  low > 0, high > low else { continue }
            self.low = low
            self.high = high
            self.days = window.daysUsed
            self.source = "NAS \(window.daysUsed) 日分时 p10–p90"
            return
        }
        return nil
    }
}

// MARK: - 计划时钟：候选计划的有效期口径

enum NextPlanClock {
    /// 当日收盘（东八区 15:05）。已过收盘则顺延到下一个自然日 15:05——
    /// 计划永远有一个「今天内有效」的边界，不会无限期挂旧价格。
    static func sessionEnd(after now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 15; components.minute = 5; components.second = 0
        let today = calendar.date(from: components) ?? now.addingTimeInterval(3_600)
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }
}

// MARK: - 市场状态识别（做 T / 网格的前置判断）

enum NextMarketState: String, Equatable {
    case trendingUp = "趋势上涨"
    case trendingDown = "趋势下跌"
    case narrowRange = "窄幅震荡"
    case wideRange = "宽幅震荡"
    case anomalous = "异常波动"
    case insufficient = "数据不足"

    var isTrend: Bool { self == .trendingUp || self == .trendingDown }
    var isRange: Bool { self == .narrowRange || self == .wideRange }
}

struct NextMarketStateReading: Equatable {
    let state: NextMarketState
    let reasons: [String]
    let warnings: [String]
    let dailyBarCount: Int
    let minuteSampleCount: Int
    let signal: NextTechnicalSignal?
    let gridMetrics: NextGridCheckEngine.Metrics
    let dailyReturn20: Double?
    let priceVsMA20: Double?
    let todayChangePercent: Double?
}

/// 状态识别只做「分类 + 给依据」，不预测涨跌。
/// 复用 NextSignalEngine（均线/RSI/MACD）与 NextGridCheckEngine.metrics（波动/振幅/震荡性），不重算。
enum NextMarketStateEngine {
    static func classify(daily: [NextChartSample], intraday: [NextChartSample], quote: NextQuote?, now: Date) -> NextMarketStateReading {
        let bars = daily.filter { $0.close > 0 }.sorted { $0.timestamp < $1.timestamp }
        let signal = NextSignalEngine.evaluate(bars)
        let metrics = NextGridCheckEngine.metrics(of: bars)
        let minuteCount = intraday.filter { $0.close > 0 }.count
        let todayChange: Double? = quote.map { NextNum.double(($0.price / $0.previousClose - 1) * 100) }

        var return20: Double?
        var priceVsMA20: Double?
        if bars.count >= 21, let last = bars.last?.close, last > 0 {
            let past = bars[bars.count - 21].close
            if past > 0 { return20 = NextNum.double((last / past - 1) * 100) }
            let ma20 = bars.suffix(20).reduce(Decimal.zero) { $0 + $1.close } / Decimal(20)
            if ma20 > 0 { priceVsMA20 = NextNum.double((last / ma20 - 1) * 100) }
        }

        // 门槛：日 K 不足 20 根或信号引擎拒判，一律「数据不足」，不用短样本冒充结论。
        guard bars.count >= 20, let signal else {
            var reasons = ["日 K 仅 \(bars.count) 根，识别市场状态至少需要 20 根"]
            if minuteCount < 30 { reasons.append("今日分时仅 \(minuteCount) 点") }
            return NextMarketStateReading(state: .insufficient, reasons: reasons, warnings: ["数据补齐前不出任何带价建议"],
                                          dailyBarCount: bars.count, minuteSampleCount: minuteCount, signal: nil,
                                          gridMetrics: metrics, dailyReturn20: nil, priceVsMA20: nil, todayChangePercent: todayChange)
        }

        var reasons: [String] = []
        var warnings: [String] = []

        // 1) 异常波动优先：当日涨跌 ≥4%，或 60 日极值 + 明显放量。
        if let change = todayChange, abs(change) >= 4 {
            reasons.append("当日涨跌 \(NextNum.signed(change))%，超出正常日内范围，历史规律可能失效")
            return NextMarketStateReading(state: .anomalous, reasons: reasons, warnings: ["异常波动期间暂停原交易计划"],
                                          dailyBarCount: bars.count, minuteSampleCount: minuteCount, signal: signal,
                                          gridMetrics: metrics, dailyReturn20: return20, priceVsMA20: priceVsMA20, todayChangePercent: todayChange)
        }
        if metrics.atExtreme, let ratio = signal.volumeRatio, ratio >= 1.8 {
            reasons.append("最新价处于近 60 日最高/最低附近，且放量 \(String(format: "%.2f", ratio)) 倍")
            return NextMarketStateReading(state: .anomalous, reasons: reasons, warnings: ["单边极端放量，暂不生成网格/做T计划"],
                                          dailyBarCount: bars.count, minuteSampleCount: minuteCount, signal: signal,
                                          gridMetrics: metrics, dailyReturn20: return20, priceVsMA20: priceVsMA20, todayChangePercent: todayChange)
        }

        // 2) 趋势：20 日涨跌幅 ≥8% 且现价偏离 MA20 ≥3%。
        if let r20 = return20, let vs = priceVsMA20 {
            if r20 >= 8, vs >= 3 {
                reasons.append("20 日上涨 \(String(format: "%.1f", r20))%，现价高于 MA20 \(String(format: "%.1f", vs))%")
                reasons.append("均线结构：\(signal.trend)")
                return reading(.trendingUp, reasons: reasons, warnings: warnings, bars: bars.count, minute: minuteCount, signal: signal, metrics: metrics, r20: return20, vs: priceVsMA20, change: todayChange)
            }
            if r20 <= -8, vs <= -3 {
                reasons.append("20 日下跌 \(String(format: "%.1f", abs(r20)))%，现价低于 MA20 \(String(format: "%.1f", abs(vs)))%")
                reasons.append("均线结构：\(signal.trend)")
                return reading(.trendingDown, reasons: reasons, warnings: ["下跌趋势中暂停新增网格买档，不急于补仓摊薄"], bars: bars.count, minute: minuteCount, signal: signal, metrics: metrics, r20: return20, vs: priceVsMA20, change: todayChange)
            }
        }

        // 3) 震荡：近 60 日收盘贴 MA20 天数占比 ≥55% 判震荡；按日均振幅分窄幅/宽幅。
        if let ratio = metrics.rangeBoundRatio, ratio >= 0.55 {
            let amplitude = metrics.avgAmplitudePercent ?? 0
            reasons.append("近 60 日有 \(Int((ratio * 100).rounded()))% 的交易日收盘贴近 MA20，走势偏震荡")
            if let amplitudeValue = metrics.avgAmplitudePercent {
                reasons.append("日均振幅 \(String(format: "%.3f", amplitudeValue))%")
            }
            if amplitude < 0.8 {
                warnings.append("日均振幅不足 0.8%，扣除手续费后可操作空间有限")
                return reading(.narrowRange, reasons: reasons, warnings: warnings, bars: bars.count, minute: minuteCount, signal: signal, metrics: metrics, r20: return20, vs: priceVsMA20, change: todayChange)
            }
            return reading(.wideRange, reasons: reasons, warnings: warnings, bars: bars.count, minute: minuteCount, signal: signal, metrics: metrics, r20: return20, vs: priceVsMA20, change: todayChange)
        }

        // 4) 结构不典型：用均线结构兜底，标注为保守震荡判断。
        if signal.trend == "多头排列", (return20 ?? 0) > 0 {
            reasons.append("均线多头排列但 20 日涨幅不足 8%，按「温和偏强」保守处理")
            return reading(.wideRange, reasons: reasons, warnings: ["结构不典型，网格/做T计划按震荡口径保守评估"], bars: bars.count, minute: minuteCount, signal: signal, metrics: metrics, r20: return20, vs: priceVsMA20, change: todayChange)
        }
        if signal.trend == "空头排列", (return20 ?? 0) < 0 {
            reasons.append("均线空头排列但 20 日跌幅不足 8%，按「温和偏弱」保守处理")
            return reading(.trendingDown, reasons: reasons, warnings: ["偏弱但未构成显著下跌趋势，仅暂停新增买档"], bars: bars.count, minute: minuteCount, signal: signal, metrics: metrics, r20: return20, vs: priceVsMA20, change: todayChange)
        }
        reasons.append("均线交织、无明显趋势，按震荡处理")
        return reading(.narrowRange, reasons: reasons, warnings: warnings, bars: bars.count, minute: minuteCount, signal: signal, metrics: metrics, r20: return20, vs: priceVsMA20, change: todayChange)
    }

    private static func reading(_ state: NextMarketState, reasons: [String], warnings: [String], bars: Int, minute: Int,
                                signal: NextTechnicalSignal, metrics: NextGridCheckEngine.Metrics,
                                r20: Double?, vs: Double?, change: Double?) -> NextMarketStateReading {
        NextMarketStateReading(state: state, reasons: reasons, warnings: warnings, dailyBarCount: bars, minuteSampleCount: minute,
                               signal: signal, gridMetrics: metrics, dailyReturn20: r20, priceVsMA20: vs, todayChangePercent: change)
    }
}

// MARK: - 日内分时统计（做 T 的价格根基）

struct NextIntradayStats: Equatable {
    let sampleCount: Int
    let vwap: Decimal?
    let vwapIsWeighted: Bool
    let dayHigh: Decimal?
    let dayLow: Decimal?
    let amplitudePercent: Double?
    let vwapCrossings: Int
    let volumeLots: Decimal?
    let firstPrice: Decimal?
    let lastPrice: Decimal?
}

enum NextIntradayStatsEngine {
    static func compute(samples: [NextChartSample], previousClose: Decimal?) -> NextIntradayStats {
        let priced = samples.filter { $0.close > 0 }.sorted { $0.timestamp < $1.timestamp }
        guard !priced.isEmpty else {
            return NextIntradayStats(sampleCount: 0, vwap: nil, vwapIsWeighted: false, dayHigh: nil, dayLow: nil,
                                     amplitudePercent: nil, vwapCrossings: 0, volumeLots: nil, firstPrice: nil, lastPrice: nil)
        }
        var weighted = Decimal.zero
        var volumeSum = Decimal.zero
        var volumeLots = Decimal.zero
        var hasVolume = false
        for sample in priced {
            if let volume = sample.volume, volume > 0 {
                weighted += sample.close * volume
                volumeSum += volume
                volumeLots += volume
                hasVolume = true
            }
        }
        let vwap: Decimal?
        let weightedFlag: Bool
        if hasVolume, volumeSum > 0 {
            vwap = weighted / volumeSum
            weightedFlag = true
        } else {
            let sum = priced.reduce(Decimal.zero) { $0 + $1.close }
            vwap = sum / Decimal(priced.count)
            weightedFlag = false
        }
        let high = priced.map(\.close).max()
        let low = priced.map(\.close).min()
        var amplitude: Double?
        if let high, let low, let previousClose, previousClose > 0, high > low {
            amplitude = NextNum.double((high - low) / previousClose * 100)
        }
        // VWAP 穿越次数：价格在 VWAP 上下往返的次数（>0 即日内反复，是做 T 的土壤）。
        var crossings = 0
        if let vwap {
            var previousSide: Int?
            for sample in priced {
                let side: Int = sample.close > vwap ? 1 : (sample.close < vwap ? -1 : 0)
                if side != 0 {
                    if let previousSide, previousSide != 0, side != previousSide { crossings += 1 }
                    previousSide = side
                }
            }
        }
        return NextIntradayStats(sampleCount: priced.count, vwap: vwap, vwapIsWeighted: weightedFlag,
                                 dayHigh: high, dayLow: low, amplitudePercent: amplitude, vwapCrossings: crossings,
                                 volumeLots: hasVolume ? volumeLots : nil,
                                 firstPrice: priced.first?.close, lastPrice: priced.last?.close)
    }
}

// MARK: - 策略自动选择（不让用户先选策略）

enum NextStrategyKind: String, Equatable {
    case hold = "长期持有"
    case tTrade = "做T"
    case grid = "网格"
    case waitBuy = "等待买入"
    case pauseAdd = "暂停加仓"
    case reduce = "减仓"
    case noTrade = "不交易"
}

struct NextStrategyReading: Equatable {
    let kind: NextStrategyKind
    let reasons: [String]
    let warnings: [String]
    let referencePrice: Decimal?
}

enum NextStrategySelector {
    /// 规则版、可解释：状态 → 策略。「不交易」是正常且重要的结论。
    static func select(state reading: NextMarketStateReading, grid: NextGridCheck?, hasPosition: Bool,
                       oscillating: Bool, now: Date) -> NextStrategyReading {
        switch reading.state {
        case .insufficient:
            return NextStrategyReading(kind: .noTrade, reasons: reading.reasons,
                                       warnings: ["数据补齐前不出任何带价建议"], referencePrice: nil)
        case .anomalous:
            return NextStrategyReading(kind: .noTrade, reasons: reading.reasons,
                                       warnings: ["异常波动期间暂停原交易计划，等波动回归常态再评估"], referencePrice: nil)
        case .trendingUp:
            if hasPosition {
                return NextStrategyReading(kind: .hold, reasons: reading.reasons + ["单边上涨中频繁做T容易踏空，优先拿住仓位"],
                                           warnings: ["如已接近你的目标仓位，不追加"], referencePrice: nil)
            }
            let reference = reading.signal?.ma[20].map { Decimal($0) }
            return NextStrategyReading(kind: .waitBuy, reasons: reading.reasons + ["上涨趋势中不追高，等回调再评估"],
                                       warnings: ["等待买入只是观察价，不是挂单建议"], referencePrice: reference)
        case .trendingDown:
            if hasPosition {
                return NextStrategyReading(kind: .pauseAdd, reasons: reading.reasons + ["下跌中暂停新增网格买档，不用补仓摊薄成本"],
                                           warnings: ["先确认这仍是你会长期持有的品种；减仓需要你自己在组合层面确认"], referencePrice: nil)
            }
            return NextStrategyReading(kind: .noTrade, reasons: reading.reasons + ["下跌趋势中不接飞刀，等待趋势企稳信号"],
                                       warnings: [], referencePrice: nil)
        case .narrowRange:
            let amplitude = reading.gridMetrics.avgAmplitudePercent ?? 0
            return NextStrategyReading(kind: .noTrade, reasons: reading.reasons + ["日均振幅仅 \(String(format: "%.3f", amplitude))%，扣除手续费后做T和网格都没有足够空间"],
                                       warnings: [], referencePrice: nil)
        case .wideRange:
            // 日内反复震荡（价格多次穿越 VWAP）优先做T；多日区间稳定则网格。
            if oscillating, hasPosition {
                return NextStrategyReading(kind: .tTrade, reasons: reading.reasons + ["日内价格多次穿越 VWAP，具备做T空间"],
                                           warnings: [], referencePrice: nil)
            }
            if let grid {
                switch grid.grade {
                case .suitable:
                    return NextStrategyReading(kind: .grid, reasons: reading.reasons + grid.reasons,
                                               warnings: grid.warnings, referencePrice: nil)
                case .consider:
                    return NextStrategyReading(kind: .grid, reasons: reading.reasons + ["网格适合度评级「可考虑」，按保守档数生成"],
                                               warnings: grid.warnings + ["评级未到「适合」，档数与资金都取保守值"], referencePrice: nil)
                case .avoid:
                    return NextStrategyReading(kind: .noTrade, reasons: reading.reasons + ["网格适合度评级「不适合」"],
                                               warnings: grid.warnings, referencePrice: nil)
                }
            }
            return NextStrategyReading(kind: .noTrade, reasons: reading.reasons + ["缺日 K 无法评估网格适合度"],
                                       warnings: [], referencePrice: nil)
        }
    }
}

// MARK: - 三分钱定价

/// ETF 最小变动价位 0.001 元：所有生成价都按此取整，避免出现交易所不接受的价位。
enum NextPriceRounding {
    static func tick(_ value: Decimal) -> Decimal {
        let handler = NSDecimalNumberHandler(roundingMode: .plain, scale: 3, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false)
        return NSDecimalNumber(decimal: value).rounding(accordingToBehavior: handler).decimalValue
    }
}

// MARK: - 计划硬约束（画像上限 + NAS 长期统计）
//
// 画像是「你的习惯」，必须能真正压住份额与档数，否则等于没接入。
// NAS 长期统计只提供「历史上这种波动有多常见」，不提供方向。

struct NextPlanCaps: Equatable {
    /// 单次做 T 份额上限（已按可用份额比例换算成整手）
    var maxTUnits: Int? = nil
    var tUnitsNote: String? = nil
    /// 网格档数上限 / 最大资金占用上限
    var maxGridTiers: Int? = nil
    var maxGridCash: Decimal? = nil
    var gridNotes: [String] = []
    /// NAS 长期分时（60 日窗口）——只用于说明历史常见程度
    var nasAmplitude60: Double? = nil
    var nasRoundTrips60: Double? = nil
    var nasDays: Int? = nil
    var nasVolumeCoverage60: Double? = nil
    var nasVwapHighDeviation60: Double? = nil
    var nasVwapLowDeviation60: Double? = nil

    static let none = NextPlanCaps()

    static func make(profile: NextInvestorProfile?, nasStats: NextNASMinuteStats?,
                     book: NextBook, code: String, lotSize: Int, now: Date) -> NextPlanCaps {
        var caps = NextPlanCaps()
        if let profile {
            if profile.trait(.tAppetite)?.value != "none" || profile.trait(.tAppetite)?.isKnown != true {
                let available = book.availableUnits(for: code, at: now)
                if available > 0 {
                    let ratio = max(0.1, min(1.0, profile.thresholds.maxTUnitsRatio))
                    let capUnits = max(lotSize, (Int(Double(available) * ratio) / lotSize) * lotSize)
                    caps.maxTUnits = capUnits
                    caps.tUnitsNote = "单次做T份额按你的画像上限压到 \(capUnits) 份（不超过可用 \(available) 份的 \(Int((ratio * 100).rounded()))%）"
                }
            }
            caps.maxGridTiers = max(2, profile.thresholds.gridMaxTiers)
            let ratio = max(0.05, min(1.0, profile.thresholds.gridMaxCashRatio))
            caps.maxGridCash = book.cash * Decimal(string: "\(ratio)")!
            if ratio < 1 {
                caps.gridNotes.append("网格资金占用按你的画像上限封顶在可用现金的 \(Int((ratio * 100).rounded()))%（¥\(NextMoney.text(caps.maxGridCash ?? 0))）")
            }
        }
        if let stats = nasStats {
            caps.nasDays = stats.days
            if let w60 = stats.window(60) {
                caps.nasAmplitude60 = w60.amplitudeMedianPercent
                caps.nasRoundTrips60 = w60.roundTripsMedian
                caps.nasVolumeCoverage60 = w60.volumeCoverage ?? stats.quality.volumeCoverage
                caps.nasVwapHighDeviation60 = w60.vwapHighDeviationMedian
                caps.nasVwapLowDeviation60 = w60.vwapLowDeviationMedian
            }
        }
        return caps
    }
}

// MARK: - 做 T 计算器（候选限价计划，不是订单）

enum NextTKind: String, Equatable {
    case reverse = "反T · 先卖后买"
    case forward = "正T · 先买后卖"
}

struct NextTPlan: Equatable {
    let kind: NextTKind
    let code: String
    let name: String
    let sellPrice: Decimal
    let buyPrice: Decimal
    let units: Int
    let grossSpread: Decimal
    let feeTotal: Decimal
    let netGain: Decimal
    let costReductionPerUnit: Decimal
    let trampleRisk: String
    let volumeSupport: String
    let validUntil: Date
    let cancelConditions: [String]
    let evidence: [String]
    let confidence: NextDataConfidence
    let historyMissRate: Double?
}

enum NextTPlannerResult: Equatable {
    case ready(NextTPlan)
    case notWorthwhile([String])
    case insufficientData(NextDataConfidence, [String])
}

struct NextOrderBookLiquidity: Equatable {
    let spreadPercent: Double
    let bidDepthLots: Double
    let askDepthLots: Double
}

enum NextOrderBookEvidence {
    static func assess(_ snapshot: NextOrderBookSnapshot, lotSize: Int, now: Date) -> NextOrderBookLiquidity? {
        guard lotSize > 0, (try? snapshot.validate()) != nil,
              now.timeIntervalSince(snapshot.observedAt) >= 0,
              now.timeIntervalSince(snapshot.observedAt) <= 30,
              snapshot.bids.count == 5, snapshot.asks.count == 5,
              let bid = snapshot.bids.first?.price, let ask = snapshot.asks.first?.price,
              bid > 0, ask >= bid else { return nil }
        let mid = (bid + ask) / 2
        guard mid > 0 else { return nil }
        let spread = NextNum.double((ask - bid) / mid * 100)
        let bidLots = NextNum.double(snapshot.bids.reduce(Decimal.zero) { $0 + Decimal($1.units) } / Decimal(lotSize))
        let askLots = NextNum.double(snapshot.asks.reduce(Decimal.zero) { $0 + Decimal($1.units) } / Decimal(lotSize))
        return NextOrderBookLiquidity(spreadPercent: spread, bidDepthLots: bidLots, askDepthLots: askLots)
    }
}

/// 做 T 计划生成器。**只根据真实持仓与行情计算可手工挂出的价格和份额**；
/// 未成交前不改变持仓、现金，不产生任何收益。价格全部来自当日分时统计
///（VWAP、日内高低、振幅）与日 K 结构，禁止由大模型直接生成。
enum NextTradeTPlanner {
    static func plan(kind: NextTKind, book: NextBook, quote: NextQuote?, daily: [NextChartSample], intraday: [NextChartSample],
                     rules: NextInstrumentRules?, orderBook: NextOrderBookSnapshot? = nil, caps: NextPlanCaps? = nil,
                     now: Date, historyMissRate: Double? = nil) -> NextTPlannerResult {
        let bars = daily.filter { $0.close > 0 }
        let confidence = NextDataConfidence.assess(quote: quote, now: now, dailyBarCount: bars.count, minuteSampleCount: intraday.filter { $0.close > 0 }.count)
        guard confidence.canPriceTPlan, let quote else {
            return .insufficientData(confidence, confidence.missing.isEmpty ? ["当前无法评估做T机会"] : confidence.missing)
        }
        // 交易规则必须已核实：场内 ETF、100 份一手、每笔 ¥0.10。规则不确定就拒绝出价。
        guard let rules, rules.isVerified, rules.assetClass == .etf, rules.settlement != .unknown,
              let lotSize = rules.lotSize, lotSize > 0,
              let feePerTrade = rules.feePerTrade, feePerTrade >= 0 else {
            return .insufficientData(confidence, ["该证券的交易规则未核实（份额单位/手续费），为避免错误委托拒绝生成价格"])
        }
        guard let caps, (caps.nasDays ?? 0) >= 60,
              (caps.nasVolumeCoverage60 ?? 0) >= 0.8,
              let historicalHighDeviation = caps.nasVwapHighDeviation60, historicalHighDeviation > 0,
              let historicalLowDeviation = caps.nasVwapLowDeviation60, historicalLowDeviation < 0,
              let roundTrips = caps.nasRoundTrips60, roundTrips >= 1 else {
            return .insufficientData(confidence, ["NAS 60 日成交量覆盖、VWAP 偏离或往返统计不完整；不给具体做T价格"])
        }
        guard let orderBook, orderBook.code == quote.code,
              let liquidity = NextOrderBookEvidence.assess(orderBook, lotSize: lotSize, now: now),
              liquidity.spreadPercent <= 0.3, liquidity.bidDepthLots >= 10, liquidity.askDepthLots >= 10 else {
            return .insufficientData(confidence, ["缺少 30 秒内有效五档盘口、价差或深度不足；不给具体做T挂单价"])
        }
        let stats = NextIntradayStatsEngine.compute(samples: intraday, previousClose: quote.previousClose)
        guard let vwap = stats.vwap, let dayHigh = stats.dayHigh, let dayLow = stats.dayLow,
              let amplitude = stats.amplitudePercent, stats.sampleCount >= 30,
              stats.vwapIsWeighted, stats.volumeLots != nil else {
            return .insufficientData(confidence, ["今日分时不足、缺少成交量或无法计算成交量加权 VWAP；拒绝用简单均价代替"])
        }
        guard let position = book.positions.first(where: { $0.code == quote.code }), position.units > 0 else {
            return .insufficientData(confidence, ["没有该证券的真实持仓，做T只对已持有份额适用"])
        }

        // 份额：反T 受 T+1 与可卖数量约束；正T 受现金与组合仓位约束。
        var units: Int
        switch kind {
        case .reverse:
            let available = book.availableUnits(for: quote.code, at: now)
            let lots = available / lotSize
            guard lots >= 1 else {
                return .insufficientData(confidence, ["可卖份额不足一手：持有 \(position.units) 份，今日买入锁定 \(book.lockedUnits(for: quote.code, at: now)) 份，可卖 \(available) 份"])
            }
            units = lots * lotSize
        case .forward:
            let affordable = Int(NextNum.double((book.cash - feePerTrade) / (quote.price * Decimal(lotSize))))
            let cashLots = max(0, affordable)
            guard cashLots >= 1 else {
                return .insufficientData(confidence, ["可用现金 ¥\(NextMoney.text(book.cash)) 不足一手（约 ¥\(NextMoney.text(quote.price * Decimal(lotSize)))）"])
            }
            units = cashLots * lotSize
        }
        // 画像上限：这是硬约束，不是提示。低于一手时不压缩（否则等于禁止交易，应走「不做」结论）。
        var capNotes: [String] = []
        if let cap = caps?.maxTUnits, cap >= lotSize, units > cap {
            let capped = (cap / lotSize) * lotSize
            if capped >= lotSize {
                capNotes.append("份额从 \(units) 份压到 \(capped) 份：" + (caps?.tUnitsNote ?? "按你的画像上限"))
                units = capped
            }
        }

        // 目标价：以 VWAP 为锚，偏离幅度取「0.5×今日已实现振幅」与 0.4% 的较大值。
        // 目标偏离同时受 60 日 VWAP 偏离中位数与今日实际振幅约束，
        // 避免单凭一个最低 0.4% 固定阈值生成看起来精确的挂单价。
        let todayHalfRange = amplitude / 100 / 2
        let upDeviation = min(historicalHighDeviation, todayHalfRange)
        let downDeviation = min(abs(historicalLowDeviation), todayHalfRange)
        guard upDeviation > 0, downDeviation > 0 else {
            return .insufficientData(confidence, ["今日振幅没有覆盖 NAS 长期 VWAP 偏离，无法形成有历史依据的双边价格"])
        }
        let sellPrice: Decimal
        let buyPrice: Decimal
        switch kind {
        case .reverse:
            let ceiling = vwap * Decimal(string: "\(1 + upDeviation)")!
            let anchored = min(dayHigh, ceiling)
            // 现价已达偏离上限时按现价挂，否则挂锚定价与日内高点的较低者。
            sellPrice = quote.price >= ceiling ? quote.price : NextPriceRounding.tick(anchored)
            buyPrice = NextPriceRounding.tick(max(dayLow, vwap * Decimal(string: "\(1 - downDeviation)")!))
        case .forward:
            let floorPrice = vwap * Decimal(string: "\(1 - downDeviation)")!
            let anchored = max(dayLow, floorPrice)
            buyPrice = quote.price <= floorPrice ? quote.price : NextPriceRounding.tick(anchored)
            sellPrice = NextPriceRounding.tick(min(dayHigh, vwap * Decimal(string: "\(1 + upDeviation)")!))
        }
        guard buyPrice < sellPrice else {
            return .notWorthwhile(["当前 VWAP 偏离与日内高低点算不出正价差：卖出 ¥\(NextMoney.text(sellPrice, digits: 3)) / 买回 ¥\(NextMoney.text(buyPrice, digits: 3))，今天不做这笔 T"])
        }
        let grossSpread = sellPrice - buyPrice
        let feeTotal = feePerTrade * 2
        let netGain = grossSpread * Decimal(units) - feeTotal
        guard netGain > 0 else {
            return .notWorthwhile(["毛价差 ¥\(NextMoney.text(grossSpread, digits: 3)) × \(units) 份 = ¥\(NextMoney.text(grossSpread * Decimal(units)))，扣除两笔手续费 ¥\(NextMoney.text(feeTotal)) 后净收益不为正，今天不做这笔 T"])
        }
        let costReduction = netGain / Decimal(position.units)

        // 踏空风险：以 1× 今日振幅的继续上涨为参考，量化「卖飞」的代价。
        let referenceRise = sellPrice * Decimal(string: "\(amplitude / 100)")!
        let missCost = (sellPrice + referenceRise - buyPrice) * Decimal(units) - feeTotal
        var trample = "若卖出后价格继续上涨超过 \(String(format: "%.2f", amplitude))%（约 ¥\(NextMoney.text(sellPrice + referenceRise, digits: 3))）且当日不回落至买回价，本次做T踏空，约少赚 ¥\(NextMoney.text(max(0, missCost)))"
        if let historyMissRate {
            trample += "；长期分时统计中卖出后未回落比例约 \(Int((historyMissRate * 100).rounded()))%"
        } else if let medianAmplitude = caps?.nasAmplitude60 {
            // 用 NAS 60 日振幅中位数与本次所需价差做比值：只是「历史上这种波动够不够」，
            // 不是预测，也不能反过来证明今天一定会回落。
            let needed = NextNum.double(grossSpread / buyPrice * 100)
            let reach = needed > 0 ? min(1.0, medianAmplitude / needed) : 0
            let trips = caps?.nasRoundTrips60
            trample += "；NAS 60 日日内振幅中位数 \(String(format: "%.2f", medianAmplitude))%，本次所需价差 \(String(format: "%.2f", needed))%，历史覆盖度约 \(Int((reach * 100).rounded()))%"
            if let trips { trample += "（同期日均往返 \(String(format: "%.1f", trips)) 次）" }
        } else {
            trample += "；长期分时统计未接入，暂不给历史未回落比例"
        }

        // 成交量支持：本计划份额占当日成交量的比例。
        var volumeSupport = "当日无成交量统计，无法评估冲击成本"
        if let volumeLots = stats.volumeLots, volumeLots > 0 {
            let requiredLots = Decimal(units) / Decimal(lotSize)
            let share = NextNum.double(requiredLots / volumeLots * 100)
            volumeSupport = share <= 20
                ? "当日成交 \(NextMoney.text(volumeLots, digits: 0)) 手，本计划 \(Int(NextNum.double(requiredLots))) 手，占 \(String(format: "%.1f", share))%，冲击成本可控"
                : "当日成交 \(NextMoney.text(volumeLots, digits: 0)) 手，本计划 \(Int(NextNum.double(requiredLots))) 手，占 \(String(format: "%.1f", share))%，建议拆小或减少份额"
        }

        var evidence: [String] = []
        evidence.append("VWAP ¥\(NextMoney.text(vwap, digits: 3))（今日 \(stats.sampleCount) 点\(stats.vwapIsWeighted ? "，成交量加权" : "，简单均值——缺成交量数据")）")
        evidence.append("今日高低 ¥\(NextMoney.text(dayLow, digits: 3))–¥\(NextMoney.text(dayHigh, digits: 3))，振幅 \(String(format: "%.2f", amplitude))%")
        evidence.append("价格穿越 VWAP \(stats.vwapCrossings) 次（日内往返，做T空间来源）")
        evidence.append("NAS 60 日成交量覆盖 \(Int(((caps?.nasVolumeCoverage60 ?? 0) * 100).rounded()))%；VWAP 上/下偏离中位数 \(String(format: "%.2f", historicalHighDeviation * 100))% / \(String(format: "%.2f", historicalLowDeviation * 100))%")
        evidence.append("实时盘口价差 \(String(format: "%.3f", liquidity.spreadPercent))%；五档深度买 \(String(format: "%.0f", liquidity.bidDepthLots)) 手 / 卖 \(String(format: "%.0f", liquidity.askDepthLots)) 手（\(orderBook.source)）")
        if let rsi = NextSignalEngine.evaluate(bars)?.rsi {
            evidence.append("RSI14 \(String(format: "%.1f", rsi))")
        }
        evidence.append("现价 ¥\(NextMoney.text(quote.price, digits: 3))（\(quote.source)，\(confidence.quoteAgeSeconds ?? 0) 秒前）")
        evidence.append(contentsOf: capNotes)
        if let medianAmplitude = caps?.nasAmplitude60, let days = caps?.nasDays {
            evidence.append("NAS \(days) 天分时：60 日振幅中位数 \(String(format: "%.2f", medianAmplitude))%，日均往返 \(String(format: "%.1f", caps?.nasRoundTrips60 ?? 0)) 次")
        }

        let plan = NextTPlan(kind: kind, code: quote.code, name: quote.name, sellPrice: sellPrice, buyPrice: buyPrice,
                             units: units, grossSpread: grossSpread, feeTotal: feeTotal, netGain: netGain,
                             costReductionPerUnit: costReduction, trampleRisk: trample, volumeSupport: volumeSupport,
                             validUntil: NextPlanClock.sessionEnd(after: now),
                             cancelConditions: [
                                "现价偏离 VWAP 超过 1.5× 今日振幅（做T前提消失）",
                                "当日涨跌超过 ±4%（异常波动，历史规律可能失效）",
                                "行情超过 2 分钟未更新（计划自动作废）",
                                "价格突破近 60 日高低区间（按趋势策略重新评估）"
                             ],
                             evidence: evidence, confidence: confidence, historyMissRate: historyMissRate)
        return .ready(plan)
    }

}

// MARK: - 智能网格生成器（不固定档数）

struct NextGridTier: Equatable {
    let side: String
    let price: Decimal
    let units: Int
    let cashRequired: Decimal
}

struct NextGridPlan: Equatable {
    let code: String
    let name: String
    let upper: Decimal
    let lower: Decimal
    let tiers: [NextGridTier]
    let maxCashUsage: Decimal
    let remainingUnitsAfterAllSells: Int
    let spacingPercent: Double
    let validUntil: Date
    let pauseConditions: [String]
    let reasons: [String]
    let warnings: [String]
    let confidence: NextDataConfidence
}

enum NextGridPlannerResult: Equatable {
    case ready(NextGridPlan)
    case notRecommended([String])
    case insufficientData(NextDataConfidence, [String])
}

/// 档数、间距、每档份额全部由波动率、历史区间、资金、持仓与手续费推导；
/// 不适合就明说「不建议网格」，不强行生成买档。
enum NextGridPlanner {
    static func plan(book: NextBook, quote: NextQuote?, daily: [NextChartSample], gridCheck: NextGridCheck?,
                     rules: NextInstrumentRules?, nasRange: NextNasRange? = nil,
                     orderBook: NextOrderBookSnapshot? = nil,
                     caps: NextPlanCaps? = nil, now: Date) -> NextGridPlannerResult {
        let bars = daily.filter { $0.close > 0 }.sorted { $0.timestamp < $1.timestamp }
        // 网格不依赖当日分时点：按「日 K ≥60 + 行情 2 分钟内」评估（见 canPriceGridPlan）。
        // 之前这里把 minuteSampleCount 硬编码成 0，导致 assess 因缺分时而判 blocked，
        // 网格永远出不了 ready 计划——这是生产 bug，不是测试问题。
        let confidence = NextDataConfidence.assess(quote: quote, now: now, dailyBarCount: bars.count,
                                                   minuteSampleCount: 0, intradayRequired: false)
        guard let gridCheck else {
            return .insufficientData(confidence, ["还没有网格适合度评估（需要先读取日 K）"])
        }
        if gridCheck.grade == .avoid {
            return .notRecommended(gridCheck.warnings + gridCheck.reasons.filter { $0.contains("不适合") || $0.contains("至少需要") })
        }
        guard confidence.canPriceGridPlan, let quote else {
            return .insufficientData(confidence, confidence.missing)
        }
        guard let rules, rules.isVerified, rules.assetClass == .etf, rules.settlement != .unknown,
              let lotSize = rules.lotSize, lotSize > 0,
              let feePerTrade = rules.feePerTrade else {
            return .insufficientData(confidence, ["该证券的交易规则未核实（份额单位/手续费），拒绝生成网格档位"])
        }
        guard let orderBook, orderBook.code == quote.code,
              let liquidity = NextOrderBookEvidence.assess(orderBook, lotSize: lotSize, now: now),
              liquidity.spreadPercent <= 0.3, liquidity.bidDepthLots >= 10, liquidity.askDepthLots >= 10 else {
            return .insufficientData(confidence, ["缺少 30 秒内有效五档盘口、价差或深度不足；不生成具体网格档位"])
        }
        guard bars.count >= 60 else {
            return .insufficientData(confidence, ["日 K 仅 \(bars.count) 根，网格至少需要 60 根"])
        }
        // 区间：近 60 日高低点；再用 NAS 长期分位收敛（超出历史价格带的档位没有依据）。
        let recent = bars.suffix(60)
        guard let rawUpper = recent.map { $0.high ?? $0.close }.max(),
              let rawLower = recent.map { $0.low ?? $0.close }.min(),
              rawUpper > rawLower, let current = bars.last?.close, current > 0 else {
            return .insufficientData(confidence, ["近 60 日高低点无法计算"])
        }
        var upper = rawUpper
        var lower = rawLower
        var boundNotes: [String] = []
        guard let nasRange, nasRange.isValid else {
            return .insufficientData(confidence, ["缺少新鲜且完整的 NAS 60 日分时区间；不以本机日K替代长期网格证据"])
        }
        let clampedHigh = min(upper, nasRange.high)
        let clampedLow = max(lower, nasRange.low)
        guard clampedHigh > clampedLow else {
            return .notRecommended(["NAS 长期价格带与本机近 60 日区间没有有效重叠，暂停网格并重新检查行情口径"])
        }
        if clampedHigh != upper || clampedLow != lower {
            boundNotes.append("区间按 NAS 长期价格带收敛为 ¥\(NextMoney.text(clampedLow, digits: 3))–¥\(NextMoney.text(clampedHigh, digits: 3))（\(nasRange.source)，\(nasRange.days) 天）")
        }
        upper = clampedHigh
        lower = clampedLow
        let amplitude = gridCheck.avgAmplitudePercent ?? 1.0
        // 间距：不低于 0.4%，取「半倍日均振幅」；保证每档往返扣费后仍为正。
        let spacingPercent = max(0.4, amplitude / 2)
        let rangePercent = NextNum.double((upper - lower) / lower * 100)
        var tierCount = Int(max(2, min(6, (rangePercent / spacingPercent).rounded())))
        var capNotes: [String] = []
        // 画像档数上限是硬约束：档数越多，单档越薄、手续费占比越高。
        if let maxTiers = caps?.maxGridTiers, tierCount > maxTiers {
            capNotes.append("档数从 \(tierCount) 档压到 \(maxTiers) 档：按你的画像最多 \(maxTiers) 档")
            tierCount = max(2, maxTiers)
        }
        // 档数再受资金约束：每一买档至少一手。资金上限优先用画像封顶后的可部署现金。
        let deployableCash = min(book.cash, caps?.maxGridCash ?? book.cash)
        if deployableCash < book.cash { capNotes.append(contentsOf: caps?.gridNotes ?? []) }
        let cashPerTier = deployableCash / Decimal(tierCount)
        let affordableLots = Int(NextNum.double(cashPerTier / (current * Decimal(lotSize))))
        if affordableLots < 1 {
            return .insufficientData(confidence, ["可部署现金 ¥\(NextMoney.text(deployableCash)) 不足以支撑 \(tierCount) 档各一手的买入档"])
        }
        tierCount = max(2, min(tierCount, affordableLots + 1))

        var tiers: [NextGridTier] = []
        var sellUnitsPerTier = 0
        if let position = book.positions.first(where: { $0.code == quote.code }), position.units > 0 {
            let available = book.availableUnits(for: quote.code, at: now)
            let sellTierCount = max(1, tierCount / 2)
            sellUnitsPerTier = (available / sellTierCount / lotSize) * lotSize
        }
        let buyTiers = max(1, tierCount / 2)
        let buyUnitsPerTier = max(lotSize, (affordableLots / buyTiers) * lotSize)

        // 买入档：现价下方，间距按波动率递增。
        for index in 1...buyTiers {
            let offset = spacingPercent / 100 * Double(index)
            let candidate = current * Decimal(string: "\(1 - offset)")!
            if candidate >= lower, buyUnitsPerTier >= lotSize {
                let price = NextPriceRounding.tick(candidate)
                tiers.append(NextGridTier(side: "buy", price: price, units: buyUnitsPerTier,
                                          cashRequired: price * Decimal(buyUnitsPerTier) + feePerTrade))
            }
        }
        // 卖出档：现价上方，只在有可卖份额（T+1 后可用）时生成。
        if sellUnitsPerTier >= lotSize {
            for index in 1...max(1, tierCount / 2) {
                let offset = spacingPercent / 100 * Double(index)
                let candidate = current * Decimal(string: "\(1 + offset)")!
                if candidate <= upper {
                    let price = NextPriceRounding.tick(candidate)
                    tiers.append(NextGridTier(side: "sell", price: price, units: sellUnitsPerTier, cashRequired: 0))
                }
            }
        }
        guard tiers.contains(where: { $0.side == "buy" }) else {
            return .insufficientData(confidence, ["按当前区间与资金算不出有效买入档，暂不生成网格"])
        }
        let maxCashUsage = tiers.filter { $0.side == "buy" }.reduce(Decimal.zero) { $0 + $1.cashRequired }
        let sellUnits = tiers.filter { $0.side == "sell" }.reduce(0) { $0 + $1.units }
        let positionUnits = book.positions.first(where: { $0.code == quote.code })?.units ?? 0
        let remaining = max(0, positionUnits - sellUnits)

        let plan = NextGridPlan(code: quote.code, name: quote.name, upper: NextPriceRounding.tick(upper), lower: NextPriceRounding.tick(lower), tiers: tiers,
                                maxCashUsage: maxCashUsage, remainingUnitsAfterAllSells: remaining, spacingPercent: spacingPercent,
                                validUntil: NextPlanClock.sessionEnd(after: now),
                                pauseConditions: [
                                    "价格突破近 60 日区间（¥\(NextMoney.text(NextPriceRounding.tick(lower), digits: 3))–¥\(NextMoney.text(NextPriceRounding.tick(upper), digits: 3))）上下沿 1%，暂停并按趋势策略重新评估",
                                    "单日涨跌超过 ±4%（异常波动）",
                                    "行情超过 2 分钟未更新",
                                    "日均成交额跌到 0.3 亿以下（流动性不足）"
                                ],
                                reasons: gridCheck.reasons + boundNotes + capNotes,
                                warnings: gridCheck.warnings, confidence: confidence)
        return .ready(plan)
    }
}

// MARK: - 回本路径分析（目标不是不惜代价回本）

struct NextRecoveryAddOption: Equatable {
    let units: Int
    let cashRequired: Decimal
    let newAverageCost: Decimal
    let allowed: Bool
    let note: String
}

struct NextRecoveryReduceOption: Equatable {
    let units: Int
    let freedCash: Decimal
    let note: String
}

struct NextRecoveryReading: Equatable {
    let code: String
    let lossPercent: Double
    let breakEvenRisePercent: Double
    let tSessionsToHalve: Int?
    let perSessionTGain: Decimal?
    let addOption: NextRecoveryAddOption?
    let reduceOption: NextRecoveryReduceOption?
    let verdict: String
    let warnings: [String]
}

enum NextRecoveryAnalyzer {
    static func analyze(book: NextBook, quote: NextQuote?, rules: NextInstrumentRules?, goal: NextGoal, tNetGain: Decimal?, now: Date) -> NextRecoveryReading? {
        guard let quote, let position = book.positions.first(where: { $0.code == quote.code }), position.units > 0 else { return nil }
        let cost = position.costPerUnit
        guard cost > 0, quote.price > 0 else { return nil }
        let lossPercent = NextNum.double((quote.price / cost - 1) * 100)
        let breakEven = NextNum.double((cost / quote.price - 1) * 100)
        var warnings: [String] = ["补仓会放大单一标的风险；目标是提高整体投资结果，不是机械追求成本价"]
        var tSessions: Int?
        if let tNetGain, tNetGain > 0 {
            let lossAmount = (cost - quote.price) * Decimal(position.units)
            if lossAmount > 0 {
                let sessions = NextNum.double(lossAmount / Decimal(2) / tNetGain).rounded(.up)
                tSessions = Int(sessions)
            }
        }
        // 等量补仓选项：份额翻倍，成本取均值；受组合仓位上限约束。
        var addOption: NextRecoveryAddOption?
        let lotSize = rules?.lotSize ?? 100
        let fee = rules?.feePerTrade ?? NextTradeFees.etfPerTrade
        let doubleUnits = (position.units / lotSize) * lotSize
        if doubleUnits >= lotSize {
            let cashRequired = quote.price * Decimal(doubleUnits) + fee
            let newCost = (cost + quote.price) / 2
            let total = book.total(using: [quote.code: quote]) ?? Decimal.zero
            let weightAfter = total > 0 ? NextNum.double((quote.price * Decimal(position.units + doubleUnits)) / total * 100) : 0
            let allowed = weightAfter <= NextNum.double(goal.concentrationLimit)
            var note = "再买入 \(doubleUnits) 份，平均成本从 ¥\(NextMoney.text(cost, digits: 3)) 降到约 ¥\(NextMoney.text(newCost, digits: 3))"
            note += allowed ? "；补仓后占比 \(String(format: "%.1f", weightAfter))%，未超你设置的 \(NextNum.text(NextNum.double(goal.concentrationLimit)))% 上限" : "；但补仓后占比将达 \(String(format: "%.1f", weightAfter))%，超过你设置的 \(NextNum.text(NextNum.double(goal.concentrationLimit)))% 上限，组合层面不建议"
            if !allowed { warnings.append("组合仓位已到上限：价格再有吸引力也不继续增加这一只") }
            addOption = NextRecoveryAddOption(units: doubleUnits, cashRequired: cashRequired, newAverageCost: newCost, allowed: allowed, note: note)
        }
        // 减仓选项：卖出一半（向下取整到整手），说明风险变化。
        var reduceOption: NextRecoveryReduceOption?
        let available = book.availableUnits(for: quote.code, at: now)
        let halfUnits = (available / 2 / lotSize) * lotSize
        if halfUnits >= lotSize {
            let freed = quote.price * Decimal(halfUnits) - fee
            reduceOption = NextRecoveryReduceOption(units: halfUnits, freedCash: freed,
                note: "卖出 \(halfUnits) 份回收约 ¥\(NextMoney.text(freed))；剩余仓位继续下跌的损失减半，上涨也少赚一半")
        }
        let verdict: String
        if abs(lossPercent) < 2 {
            verdict = "现价贴近成本（\(NextNum.signed(lossPercent))%），无需特别操作"
        } else if lossPercent < 0 {
            verdict = "浮亏 \(String(format: "%.1f", abs(lossPercent)))%：不操作需上涨 \(String(format: "%.1f", breakEven))% 回本" + (tSessions.map { "；按当前做T理论净收益，约 \($0) 次可扳回一半亏损（理论值，未成交前只是计划）" } ?? "；暂无可用的做T净收益估计")
        } else {
            verdict = "浮盈 \(String(format: "%.1f", lossPercent))%，回本不是当前问题；按策略评估止盈/持有"
        }
        return NextRecoveryReading(code: quote.code, lossPercent: lossPercent, breakEvenRisePercent: breakEven,
                                   tSessionsToHalve: tSessions, perSessionTGain: tNetGain, addOption: addOption,
                                   reduceOption: reduceOption, verdict: verdict, warnings: warnings)
    }
}
