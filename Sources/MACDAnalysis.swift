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
    case daily, weekly, minutes60

    var title: String {
        switch self {
        case .daily: return "日线"
        case .weekly: return "周线"
        case .minutes60: return "60 分钟"
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

struct MACDTimeframeAssessment {
    let timeframe: MACDTimeframe
    let trend: MACDTrend
    let difAboveZero: Bool?
    let deaAboveZero: Bool?
    let histogramIncreasing: Bool?
    let cross: MACDCross
    let signalConfirmed: Bool
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
                                           signalConfirmed: false, dataQuality: series.completeness,
                                           reasonCodes: ["历史长度不足，尚未完成预热"])
        }
        let previous = points[points.count - 2]
        guard last.inputIndex == previous.inputIndex + 1 else {
            // 最后两点之间有空档（中间那根数据缺失）。此时「金叉」可能是假的。
            return MACDTimeframeAssessment(timeframe: series.timeframe, trend: .dataInsufficient,
                                           difAboveZero: last.dif > 0, deaAboveZero: last.dea > 0,
                                           histogramIncreasing: nil, cross: .none,
                                           signalConfirmed: false, dataQuality: series.completeness,
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
        return MACDTimeframeAssessment(timeframe: series.timeframe, trend: trend,
                                       difAboveZero: last.dif > 0, deaAboveZero: last.dea > 0,
                                       histogramIncreasing: increasing, cross: cross,
                                       signalConfirmed: series.finalized,
                                       dataQuality: series.completeness, reasonCodes: reasons)
    }

    /// 日线 + 周线 + 60 分。缺哪个就说哪个不可用，不拿别的周期代填。
    static func combine(daily: MACDSeries, weekly: MACDSeries?, intraday: MACDSeries?) -> MultiTimeframeMACDAssessment {
        let dailyResult = assess(daily)
        let weeklyResult = weekly.map { assess($0) }
        let intradayResult = intraday.map { assess($0) }

        var relationship: String
        if let intradayResult {
            if dailyResult.trend == intradayResult.trend {
                relationship = "日线与 60 分信号一致（\(dailyResult.trend.title)）"
            } else if intradayResult.trend == .bullishImproving || intradayResult.trend == .shortTermRebound {
                relationship = "短周期动能改善，日线尚未确认"
            } else if intradayResult.trend == .weakening || intradayResult.trend == .bearish {
                relationship = "短周期转弱，注意日线是否跟随"
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

    func multiTimeframeMACD(code: String) -> MultiTimeframeMACDAssessment? {
        guard let daily = macdDailySeries(code: code) else { return nil }
        return MultiTimeframeMACDAnalyzer.combine(daily: daily,
                                                 weekly: macdWeeklySeries(code: code),
                                                 intraday: macdHourlySeries(code: code))
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
