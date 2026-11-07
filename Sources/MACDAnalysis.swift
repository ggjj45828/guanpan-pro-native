import Foundation

// MARK: - 参数

struct MACDParameters: Equatable {
    let fast: Int
    let slow: Int
    let signal: Int

    init?(fast: Int = 12, slow: Int = 26, signal: Int = 9) {
        guard fast > 0, slow > fast, signal > 0, fast <= 250, slow <= 500, signal <= 100 else { return nil }
        self.fast = fast
        self.slow = slow
        self.signal = signal
    }

    static let standard = MACDParameters() ?? MACDParameters(fast: 12, slow: 26, signal: 9)!

    /// 第一根完整 DIF/DEA 之前需要的 K 线根数。
    var warmupBars: Int { slow + signal - 1 }
}

enum MACDTimeframe: String, CaseIterable {
    case daily, weekly, monthly, minutes120, minutes60, minutes30, minutes15

    var title: String {
        switch self {
        case .daily: return "日线"
        case .weekly: return "周线"
        case .monthly: return "月线"
        case .minutes120: return "120 分钟"
        case .minutes60: return "60 分钟"
        case .minutes30: return "30 分钟"
        case .minutes15: return "15 分钟"
        }
    }

    /// 短周期标识：120/60/30/15 分都算「分钟级」，日/周/月不算。
    var isIntraday: Bool {
        switch self {
        case .minutes120, .minutes60, .minutes30, .minutes15: return true
        default: return false
        }
    }
}

struct MACDBar {
    let timestamp: Date
    let close: Double?
    /// 未走完的那根。可以显示，但不算「信号已确认」。
    let isFinal: Bool

    init(timestamp: Date, close: Double?, isFinal: Bool = true) {
        self.timestamp = timestamp
        self.close = close
        self.isFinal = isFinal
    }
}

struct MACDPoint {
    let inputIndex: Int
    let timestamp: Date
    let close: Double
    let dif: Double
    let dea: Double
    /// 显示惯例：2 × (DIF − DEA)。
    let histogram: Double
}

struct MACDSeries {
    let timeframe: MACDTimeframe
    let points: [MACDPoint]
    let inputCount: Int
    let validInputCount: Int
    let finalized: Bool
    let reasonCodes: [String]

    var completeness: Double {
        inputCount == 0 ? 0 : Double(validInputCount) / Double(inputCount)
    }
    var latest: MACDPoint? { points.last }
}

/// 确定性 MACD。EMA 用前 `period` 个有效收盘价的算术均值做种子；
/// 遇到缺失/非法数据就**中断并重新预热**，不跨空档续算 —— 跨空档算出来的 EMA
/// 是「假装连续」的，图形看着平滑，实际是错的。
enum MACDEngine {
    static func calculate(bars: [MACDBar], timeframe: MACDTimeframe,
                          parameters: MACDParameters = .standard) -> MACDSeries {
        guard bars.allSatisfy({ $0.timestamp.timeIntervalSince1970.isFinite }),
              zip(bars, bars.dropFirst()).allSatisfy({ $0.0.timestamp < $0.1.timestamp }) else {
            return MACDSeries(timeframe: timeframe, points: [], inputCount: bars.count,
                              validInputCount: 0, finalized: false,
                              reasonCodes: ["时间轴不单调或含非法时间戳"])
        }
        var points: [MACDPoint] = []
        var closeRun: [Double] = []
        var difRun: [Double] = []
        var fastEMA: Double?
        var slowEMA: Double?
        var signalEMA: Double?
        var validCount = 0
        var numericalFailure = false
        let fastAlpha = 2.0 / Double(parameters.fast + 1)
        let slowAlpha = 2.0 / Double(parameters.slow + 1)
        let signalAlpha = 2.0 / Double(parameters.signal + 1)

        for (index, bar) in bars.enumerated() {
            guard let close = bar.close, close.isFinite, close > 0 else {
                closeRun.removeAll(keepingCapacity: true)
                difRun.removeAll(keepingCapacity: true)
                fastEMA = nil; slowEMA = nil; signalEMA = nil
                continue
            }
            validCount += 1
            closeRun.append(close)
            if fastEMA == nil {
                if closeRun.count >= parameters.fast {
                    fastEMA = mean(closeRun.suffix(parameters.fast))
                }
            } else if let current = fastEMA {
                fastEMA = fastAlpha * close + (1 - fastAlpha) * current
            }
            if slowEMA == nil {
                if closeRun.count >= parameters.slow {
                    slowEMA = mean(closeRun.suffix(parameters.slow))
                }
            } else if let current = slowEMA {
                slowEMA = slowAlpha * close + (1 - slowAlpha) * current
            }
            guard let fast = fastEMA, let slow = slowEMA else { continue }
            let dif = fast - slow
            guard fast.isFinite, slow.isFinite, dif.isFinite else {
                numericalFailure = true
                closeRun.removeAll(keepingCapacity: true)
                difRun.removeAll(keepingCapacity: true)
                fastEMA = nil; slowEMA = nil; signalEMA = nil
                continue
            }
            difRun.append(dif)
            if signalEMA == nil {
                if difRun.count >= parameters.signal {
                    signalEMA = mean(difRun.suffix(parameters.signal))
                }
            } else if let current = signalEMA {
                signalEMA = signalAlpha * dif + (1 - signalAlpha) * current
            }
            guard let dea = signalEMA, dea.isFinite else { continue }
            let histogram = 2 * (dif - dea)
            guard histogram.isFinite else {
                numericalFailure = true
                continue
            }
            points.append(MACDPoint(inputIndex: index, timestamp: bar.timestamp,
                                    close: close, dif: dif, dea: dea, histogram: histogram))
        }
        return MACDSeries(timeframe: timeframe,
                          points: points,
                          inputCount: bars.count,
                          validInputCount: validCount,
                          finalized: bars.last?.isFinal == true && points.last?.inputIndex == bars.count - 1,
                          reasonCodes: (points.isEmpty ? ["历史长度不足，尚未完成预热"] : [])
                            + (numericalFailure ? ["中间量出现非有限数，已丢弃"] : []))
    }

    private static func mean<S: Sequence>(_ values: S) -> Double? where S.Element == Double {
        var total = 0.0
        var count = 0
        for value in values {
            count += 1
            total += (value - total) / Double(count)
            guard total.isFinite else { return nil }
        }
        return count > 0 ? total : nil
    }
}

// MARK: - 判读

enum MACDTrend: String {
    case bullishImproving, shortTermRebound, neutral, weakening, bearish
    case dataInsufficient

    var title: String {
        switch self {
        case .bullishImproving: return "多头动能增强"
        case .shortTermRebound: return "零轴下反弹"
        case .neutral: return "动能中性"
        case .weakening: return "动能转弱"
        case .bearish: return "空头延续"
        case .dataInsufficient: return "数据不足"
        }
    }
}

enum MACDCross: String {
    case none, golden, death

    var title: String {
        switch self {
        case .none: return "无交叉"
        case .golden: return "金叉"
        case .death: return "死叉"
        }
    }
}

/// MACD 背离：仅在已收盘（信号确认）后判定，属观察证据，不得单独翻成买卖。
enum MACDDivergence: String, Equatable, Sendable {
    case none, bullish, bearish, undetermined

    var title: String {
        switch self {
        case .none: return "无背离"
        case .bullish: return "底背离（观察）"
        case .bearish: return "顶背离（观察）"
        case .undetermined: return "背离待确认"
        }
    }
}

struct MACDTimeframeAssessment {
    let timeframe: MACDTimeframe
    let trend: MACDTrend
    let difAboveZero: Bool?
    let deaAboveZero: Bool?
    let histogramIncreasing: Bool?
    let cross: MACDCross
    let signalConfirmed: Bool
    let divergence: MACDDivergence
    let dataQuality: Double
    let reasonCodes: [String]

    var qualityLabel: String {
        if dataQuality >= 0.98 { return "完整" }
        if dataQuality >= 0.8 { return "可用（有缺口）" }
        return "不足"
    }
}

struct MultiTimeframeMACDAssessment {
    let daily: MACDTimeframeAssessment
    let intraday: MACDTimeframeAssessment?
    let weekly: MACDTimeframeAssessment?
    /// 多周期关系的一句话结论。
    let relationship: String
    /// 共振方向：三周期同向才算强共振。
    let resonance: String
}

enum MultiTimeframeMACDAnalyzer {

    static func assess(_ series: MACDSeries) -> MACDTimeframeAssessment {
        let points = series.points
        guard let last = points.last, points.count >= 2 else {
            return MACDTimeframeAssessment(timeframe: series.timeframe, trend: .dataInsufficient,
                                           difAboveZero: nil, deaAboveZero: nil,
                                           histogramIncreasing: nil, cross: .none,
                                           signalConfirmed: false, divergence: .undetermined, dataQuality: series.completeness,
                                           reasonCodes: ["历史长度不足，尚未完成预热"])
        }
        let previous = points[points.count - 2]
        guard last.inputIndex == previous.inputIndex + 1 else {
            // 最后两点之间有空档（中间那根数据缺失）。此时「金叉」可能是假的。
            return MACDTimeframeAssessment(timeframe: series.timeframe, trend: .dataInsufficient,
                                           difAboveZero: last.dif > 0, deaAboveZero: last.dea > 0,
                                           histogramIncreasing: nil, cross: .none,
                                           signalConfirmed: false, divergence: .undetermined, dataQuality: series.completeness,
                                           reasonCodes: ["最新两点之间存在缺口，交叉不可确认"])
        }
        let increasing = last.histogram > previous.histogram
        let cross: MACDCross
        if previous.dif <= previous.dea && last.dif > last.dea {
            cross = .golden
        } else if previous.dif >= previous.dea && last.dif < last.dea {
            cross = .death
        } else {
            cross = .none
        }
        let trend: MACDTrend
        if increasing && last.dif > last.dea {
            trend = last.dif < 0 ? .shortTermRebound : .bullishImproving
        } else if !increasing && last.dif > last.dea {
            trend = .weakening
        } else if last.dif < 0 && last.dea < 0 && !increasing {
            trend = .bearish
        } else {
            trend = .neutral
        }
        var reasons = series.reasonCodes
        if cross == .golden { reasons.append("DIF 上穿 DEA") }
        if cross == .death { reasons.append("DIF 下穿 DEA") }
        if !series.finalized { reasons.append("最新一根未走完，信号未确认") }
        let div = Self.detectDivergence(series)
        return MACDTimeframeAssessment(timeframe: series.timeframe, trend: trend,
                                       difAboveZero: last.dif > 0, deaAboveZero: last.dea > 0,
                                       histogramIncreasing: increasing, cross: cross,
                                       signalConfirmed: series.finalized, divergence: div,
                                       dataQuality: series.completeness, reasonCodes: reasons)
    }

    // MARK: - 背离检测（仅观察，不得单独翻成买卖）

    /// 在最近窗口内找局部拐点（枢轴）。`lows=true` 找局部低点，`false` 找局部高点。
    private static func pivotPoints(_ points: [MACDPoint], window: Int, lows: Bool) -> [MACDPoint] {
        guard points.count > window * 2 else { return [] }
        var result: [MACDPoint] = []
        for i in window..<(points.count - window) {
            let center = points[i]
            let neighbors = points[(i - window)...(i + window)].filter { $0.inputIndex != center.inputIndex }
            if lows {
                if neighbors.allSatisfy({ $0.close > center.close }) { result.append(center) }
            } else {
                if neighbors.allSatisfy({ $0.close < center.close }) { result.append(center) }
            }
        }
        return result
    }

    /// 常规背离：价格创新低/高，但 MACD 柱（动能）未同步创新低/高。
    /// 仅在已收盘（`series.finalized`）后判定，未收盘一律 `undetermined`。
    private static func detectDivergence(_ series: MACDSeries) -> MACDDivergence {
        guard series.finalized, series.points.count >= 40 else { return .undetermined }
        let points = series.points
        let lows = pivotPoints(points, window: 3, lows: true)
        let highs = pivotPoints(points, window: 3, lows: false)
        if lows.count >= 2 {
            let earlier = lows[lows.count - 2]
            let later = lows[lows.count - 1]
            // 底背离：价格更低，但 MACD 柱更高 —— 下跌动能减弱。
            if later.close < earlier.close, later.histogram > earlier.histogram {
                return .bullish
            }
        }
        if highs.count >= 2 {
            let earlier = highs[highs.count - 2]
            let later = highs[highs.count - 1]
            // 顶背离：价格更高，但 MACD 柱更低 —— 上涨动能减弱。
            if later.close > earlier.close, later.histogram < earlier.histogram {
                return .bearish
            }
        }
        return .none
    }

    /// 日线 + 周线 + 60 分。缺哪个就说哪个不可用，不拿别的周期代填。
    static func combine(daily: MACDSeries, weekly: MACDSeries?, intraday: MACDSeries?) -> MultiTimeframeMACDAssessment {
        let dailyResult = assess(daily)
        let weeklyResult = weekly.map { assess($0) }
        let intradayResult = intraday.map { assess($0) }

        var relationship: String
        if let intradayResult {
            let t = intradayResult.timeframe.title
            if dailyResult.trend == intradayResult.trend {
                relationship = "日线与 \(t) 信号一致（\(dailyResult.trend.title)）"
            } else if intradayResult.trend == .bullishImproving || intradayResult.trend == .shortTermRebound {
                relationship = "\(t)动能改善，日线尚未确认"
            } else if intradayResult.trend == .weakening || intradayResult.trend == .bearish {
                relationship = "\(t)转弱，注意日线是否跟随"
            } else {
                relationship = "多周期信号冲突，等待更多证据"
            }
        } else {
            relationship = "仅有日线数据，短周期不可用"
        }

        // 共振：三个周期都在「多头增强/零轴下反弹」记为一致向上；都在「转弱/空头」记为一致向下。
        let trends = [dailyResult.trend, weeklyResult?.trend, intradayResult?.trend].compactMap { $0 }
        let upSet: Set<MACDTrend> = [.bullishImproving, .shortTermRebound]
        let downSet: Set<MACDTrend> = [.weakening, .bearish]
        let resonance: String
        if trends.count >= 2, trends.allSatisfy({ upSet.contains($0) }) {
            resonance = "\(trends.count) 个周期同向向上"
        } else if trends.count >= 2, trends.allSatisfy({ downSet.contains($0) }) {
            resonance = "\(trends.count) 个周期同向向下"
        } else if trends.contains(.dataInsufficient) {
            resonance = "有周期数据不足，无法判断共振"
        } else {
            resonance = "周期之间不一致"
        }

        return MultiTimeframeMACDAssessment(daily: dailyResult, intraday: intradayResult,
                                            weekly: weeklyResult, relationship: relationship,
                                            resonance: resonance)
    }
}

// MARK: - 从本机 K 线构造

extension PortfolioStore {

    /// 日线序列（按日期升序）。
    func macdDailySeries(code: String, parameters: MACDParameters = .standard) -> MACDSeries? {
        guard let bars = dailyBars[code], !bars.isEmpty else { return nil }
        let ordered = bars.sorted { $0.date < $1.date }
        let inputs = ordered.enumerated().map { index, bar -> MACDBar in
            let isFinal = index < ordered.count - 1 || !isToday(bar.date)
            return MACDBar(timestamp: Self.macdDate(bar.date) ?? Date(timeIntervalSince1970: Double(index)),
                           close: bar.close, isFinal: isFinal)
        }
        return MACDEngine.calculate(bars: inputs, timeframe: .daily, parameters: parameters)
    }

    /// 周线：按自然周（ISO 周）聚合，取每周最后一个收盘价。
    ///
    /// 不能简单「每 5 根取一根」—— 遇到节假日就不是 5 根，且周与周的分界会漂。
    func macdWeeklySeries(code: String, parameters: MACDParameters = .standard) -> MACDSeries? {
        guard let bars = dailyBars[code], bars.count >= 40 else { return nil }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var buckets: [String: (date: Date, close: Double)] = [:]
        for bar in bars {
            guard let date = Self.macdDate(bar.date), bar.close > 0 else { continue }
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            let key = "\(components.yearForWeekOfYear ?? 0)-\(components.weekOfYear ?? 0)"
            if let existing = buckets[key], existing.date >= date { continue }
            buckets[key] = (date, bar.close)
        }
        let ordered = buckets.values.sorted { $0.date < $1.date }
        guard ordered.count >= 30 else { return nil }
        let inputs = ordered.map { MACDBar(timestamp: $0.date, close: $0.close) }
        return MACDEngine.calculate(bars: inputs, timeframe: .weekly, parameters: parameters)
    }

    /// 60 分钟线：把分钟样本按 60 分钟分桶，取每桶最后一个价。
    ///
    /// `IntradayBar` 是快照而不是 OHLC，所以只能用收盘价 —— 这点要诚实，
    /// 出来的 MACD 与真实 60 分 K 会有细微差别，但方向判断可用。
    func macdHourlySeries(code: String, parameters: MACDParameters = .standard) -> MACDSeries? {
        let samples = intradayBars.filter { $0.code == code }
        guard samples.count >= 80 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var buckets: [String: (date: Date, close: Double)] = [:]
        for bar in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: bar.timestamp)
            // 把小时归到偶数档：9、10 → 9:30–11:30 的两根；13、14 → 下午两根。
            let hour = components.hour ?? 0
            let slot = hour / 2 * 2
            let key = String(format: "%04d%02d%02d-%02d", components.year ?? 0, components.month ?? 0,
                             components.day ?? 0, slot)
            buckets[key] = (bar.timestamp, bar.price)
        }
        let ordered = buckets.values.sorted { $0.date < $1.date }
        guard ordered.count >= 40 else { return nil }
        let inputs = ordered.map { MACDBar(timestamp: $0.date, close: $0.close) }
        return MACDEngine.calculate(bars: inputs, timeframe: .minutes60, parameters: parameters)
    }

    /// 按任意分钟窗口把分钟快照分桶取收盘价，构造 MACD 输入。
    ///
    /// `IntradayBar` 是快照不是 OHLC，所以只用收盘价 —— 这点对所有分钟级周期都如实标注，
    /// 出来的 MACD 幅度不可精读，但方向可用。120 分是短周期默认，60/30/15 作为补充。
    private func macdIntradayBucketedSeries(code: String, bucketMinutes: Int,
                                           parameters: MACDParameters = .standard) -> MACDSeries? {
        let samples = intradayBars.filter { $0.code == code }
        guard samples.count >= max(120, bucketMinutes) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var buckets: [String: (date: Date, close: Double)] = [:]
        for bar in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: bar.timestamp)
            let minutesOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            let slot = minutesOfDay / bucketMinutes
            let key = String(format: "%04d%02d%02d-%03d", components.year ?? 0, components.month ?? 0,
                             components.day ?? 0, slot)
            buckets[key] = (bar.timestamp, bar.price)
        }
        let ordered = buckets.values.sorted { $0.date < $1.date }
        guard ordered.count >= 40 else { return nil }
        let timeframe: MACDTimeframe = bucketMinutes == 120 ? .minutes120
            : bucketMinutes == 60 ? .minutes60
            : bucketMinutes == 30 ? .minutes30 : .minutes15
        let inputs = ordered.map { MACDBar(timestamp: $0.date, close: $0.close) }
        return MACDEngine.calculate(bars: inputs, timeframe: timeframe, parameters: parameters)
    }

    func macdMinutes120Series(code: String, parameters: MACDParameters = .standard) -> MACDSeries? {
        macdIntradayBucketedSeries(code: code, bucketMinutes: 120, parameters: parameters)
    }

    func macdMinutes30Series(code: String, parameters: MACDParameters = .standard) -> MACDSeries? {
        macdIntradayBucketedSeries(code: code, bucketMinutes: 30, parameters: parameters)
    }

    func macdMinutes15Series(code: String, parameters: MACDParameters = .standard) -> MACDSeries? {
        macdIntradayBucketedSeries(code: code, bucketMinutes: 15, parameters: parameters)
    }

    /// 既有组合：日线 + 周线 + 60 分。保留给原有的 AI 顾问段落，不改动其口径。
    func multiTimeframeMACD(code: String) -> MultiTimeframeMACDAssessment? {
        guard let daily = macdDailySeries(code: code) else { return nil }
        return MultiTimeframeMACDAnalyzer.combine(daily: daily,
                                                 weekly: macdWeeklySeries(code: code),
                                                 intraday: macdHourlySeries(code: code))
    }

    /// 升级组合：日线 + 周线 + 120 分。120 分作为短周期默认（6/13/5），
    /// 供「技术信号」入口、六维评分与买入机会研究使用。
    func multiTimeframeMACD120(code: String) -> MultiTimeframeMACDAssessment? {
        guard let daily = macdDailySeries(code: code) else { return nil }
        return MultiTimeframeMACDAnalyzer.combine(daily: daily,
                                                 weekly: macdWeeklySeries(code: code),
                                                 intraday: macdMinutes120Series(code: code))
    }

    private func isToday(_ dayKey: String) -> Bool {
        dayKey == MarketCalendar.isoDay(.now)
    }

    static func macdDate(_ dayKey: String) -> Date? {
        macdDayFormatter.date(from: dayKey)
    }

    private static let macdDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
