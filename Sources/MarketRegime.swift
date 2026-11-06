import Foundation

// MARK: - 市场状态

enum MarketRegime: String, Codable, CaseIterable {
    case bullTrend, bearTrend, range, highVolatility, riskOff, extremeRisk
    case recovery, transition, uncertain, dataUnreliable

    var title: String {
        switch self {
        case .bullTrend: return "上升趋势"
        case .bearTrend: return "下降趋势"
        case .range: return "震荡"
        case .highVolatility: return "高波动"
        case .riskOff: return "风险升高"
        case .extremeRisk: return "极端风险"
        case .recovery: return "修复阶段"
        case .transition: return "趋势转换"
        case .uncertain: return "证据冲突"
        case .dataUnreliable: return "数据不足"
        }
    }

    var isBullish: Bool { self == .bullTrend }
}

enum MarketRiskLevel: Int, Codable, CaseIterable, Comparable {
    case r0Normal = 0, r1Elevated = 1, r2High = 2, r3Severe = 3, r4Extreme = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .r0Normal: return "R0 正常"
        case .r1Elevated: return "R1 风险升高"
        case .r2High: return "R2 高风险"
        case .r3Severe: return "R3 严重风险"
        case .r4Extreme: return "R4 极端风险"
        }
    }
}

/// 因子的量纲。决定怎么显示 —— 比率必须按百分比读，
/// 全按四位小数显示会让 -0.0721 和 0.55 看起来像同一类东西。
enum MarketRegimeFactorUnit {
    case ratio      // 0.01 表示 1%
    case absolute   // 原值
    case flag       // 0 / 1

    func format(_ value: Double) -> String {
        switch self {
        case .ratio: return value.pct(2)
        case .absolute: return value.num(4)
        case .flag: return value >= 0.5 ? "是" : "否"
        }
    }
}

struct MarketRegimeFactor: Identifiable {
    var id: String { key }
    let key: String
    /// 中文短名。`key` 是给日志和排错看的，不该出现在界面上。
    let label: String
    let value: Double?
    let available: Bool
    let reason: String
    let unit: MarketRegimeFactorUnit
    /// 同一因子在过去若干个交易日上的取值，最右为最新。
    /// 缺值处留 nil 而不是丢掉 —— 丢掉会把时间轴压缩，看起来像「一直有值」。
    let history: [Double?]

    var displayValue: String {
        guard let value, value.isFinite else { return "--" }
        return unit.format(value)
    }

    /// 历史里真正有值的样本数。少于 3 个不画图：两个点只能说明「变了」。
    var plottedHistory: [Double] {
        history.compactMap { $0 }
    }

    var hasHistory: Bool { plottedHistory.count >= 3 }

    var historyRange: (min: Double, max: Double)? {
        let values = plottedHistory
        guard let first = values.first else { return nil }
        let result = values.dropFirst().reduce((first, first)) { partial, value in
            (Swift.min(partial.0, value), Swift.max(partial.1, value))
        }
        return (min: result.0, max: result.1)
    }

    /// 当前值在历史里的分位（0 最低，1 最高）。样本太少返回 nil。
    var historyPercentile: Double? {
        let values = plottedHistory
        guard values.count >= 5, let value else { return nil }
        let below = values.filter { $0 < value }.count
        return Double(below) / Double(values.count)
    }
}

/// 状态记忆。存在的意义是**防抖**：
/// 没有记忆，一根大阳线就能把状态从「下降趋势」翻成「上升趋势」，
/// 第二天再翻回来 —— 那种状态没有任何决策价值。
struct MarketRegimeMemory: Codable, Equatable {
    var confirmedRegime: MarketRegime
    var confirmedRiskLevel: MarketRiskLevel
    var pendingRegime: MarketRegime?
    var pendingRegimeSessions: Int
    var pendingRiskLevel: MarketRiskLevel?
    var pendingRiskSessions: Int
    var lastEvaluationAt: Date
}

struct MarketRegimeAssessment {
    let market: String
    let regime: MarketRegime
    let riskLevel: MarketRiskLevel
    let confidence: Double
    let factors: [MarketRegimeFactor]
    let reasons: [String]
    let dataAsOf: Date?
    let movingAverages: [Int: Double]
    let return5Sessions: Double?
    let return20Sessions: Double?
    let drawdown20Sessions: Double?
    let realizedVolatility20Sessions: Double?
    let volumeExpansion: Double?
    /// 只是观察，不构成操作建议。
    let observationOnly: Bool
    /// 是否允许「普通做 T」—— 只有在状态可信、风险不高于 R1、且处于上升或震荡时才为真。
    let ordinaryTBuyAllowed: Bool
    let memory: MarketRegimeMemory

    var confidenceLabel: String { "\(Int(confidence.rounded()))%" }
}

// MARK: - 引擎

enum MarketRegimeEngine {
    /// 数据最大年龄：5 个自然日（覆盖周末与一天假期）。
    static let maximumDataAge: TimeInterval = 5 * 86_400

    static func evaluate(bars: [DailyBar],
                         market: String = "CN",
                         previous: MarketRegimeMemory? = nil,
                         now: Date = .now) -> MarketRegimeAssessment {
        // 1) 清洗：时间戳合法、价格合法、按时间排序、同日冲突去重。
        var parsed: [(date: Date, bar: DailyBar)] = []
        for bar in bars {
            guard let date = date(from: bar.date) else { continue }
            guard date <= now else { continue }
            guard bar.close.isFinite, bar.close > 0 else { continue }
            guard bar.volume.isFinite, bar.volume >= 0 else { continue }
            parsed.append((date, bar))
        }
        parsed.sort { $0.date < $1.date }
        var grouped: [Date: [DailyBar]] = [:]
        for item in parsed { grouped[item.date, default: []].append(item.bar) }
        // 同一天两条数据且内容不同 —— 说明上游给了矛盾数据，宁可整体判不可信。
        let hasConflictingDuplicates = grouped.values.contains { group in
            guard let first = group.first else { return false }
            return group.contains { $0.close != first.close }
        }
        let unique = grouped.keys.sorted().compactMap { key -> (date: Date, close: Double, volume: Double)? in
            guard let group = grouped[key], group.allSatisfy({ $0.close == group[0].close }) else { return nil }
            return (key, group[0].close, group[0].volume)
        }
        let closes = unique.map(\.close)

        // 2) 间距：必须真是日线。混进分钟线的样本会让所有均值失去意义。
        let hasIntradaySpacing = zip(unique, unique.dropFirst()).contains {
            $1.date.timeIntervalSince($0.date) < 12 * 3600
        }
        let dailySpacingReliable = unique.count >= 2 && !hasIntradaySpacing
        let latestTimestamp = unique.last?.date
        let latestIsFresh = latestTimestamp.map { now.timeIntervalSince($0) <= maximumDataAge } ?? false

        // 3) 记忆过期就丢掉，别让几个月前的状态继续锚定今天的判断。
        var memory = previous
        if let memoryValue = memory, let latestTimestamp {
            let gap = latestTimestamp.timeIntervalSince(memoryValue.lastEvaluationAt)
            if gap < 0 || gap > maximumDataAge { memory = nil }
        }

        // 4) 因子
        let ma20 = averageTail(closes, count: 20)
        let ma60 = averageTail(closes, count: 60)
        let ma120 = closes.count >= 120 ? averageTail(closes, count: 120) : nil
        let ma250 = closes.count >= 250 ? averageTail(closes, count: 250) : nil
        let ret5 = periodReturn(closes, sessions: 5)
        let ret20 = periodReturn(closes, sessions: 20)
        let drawdown20 = drawdown(closes, lookback: 20)
        let vol20 = realizedVolatility(closes, count: 20)
        let slope = movingAverageSlope(closes, period: 20, lag: 5)
        let volumeExpansion = volumeRatio(unique.map { (close: $0.close, volume: $0.volume) })

        let coreReliable = ma20 != nil && ma60 != nil && ret5 != nil && ret20 != nil
            && drawdown20 != nil && vol20 != nil && slope != nil && dailySpacingReliable
        let dataReliable = !market.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && latestIsFresh && !hasConflictingDuplicates && closes.count >= 60
            && coreReliable && (memory?.lastEvaluationAt ?? .distantPast) <= (latestTimestamp ?? now)

        let volumes = unique.map(\.volume)

        let factors: [MarketRegimeFactor] = [
            factor("trend_MA20_60", label: "MA20 / MA60", unit: .ratio,
                   value: ma20.flatMap { a in ma60.map { a / $0 - 1 } },
                   reason: "MA20/MA60 排列；至少需要 60 个收盘样本",
                   history: historySeries(closes: closes, volumes: volumes) { c, _ in
                       averageTail(c, count: 20).flatMap { a in averageTail(c, count: 60).map { a / $0 - 1 } }
                   }),
            factor("trend_MA60_250", label: "MA60 / MA250", unit: .ratio,
                   value: ma60.flatMap { a in ma250.map { a / $0 - 1 } },
                   reason: "MA60/MA250 长期结构；至少需要 250 个收盘样本",
                   history: historySeries(closes: closes, volumes: volumes) { c, _ in
                       averageTail(c, count: 60).flatMap { a in averageTail(c, count: 250).map { a / $0 - 1 } }
                   }),
            factor("trend_slope", label: "MA20 斜率", unit: .ratio,
                   value: slope,
                   reason: "MA20 五个交易日斜率",
                   history: historySeries(closes: closes, volumes: volumes) { c, _ in
                       movingAverageSlope(c, period: 20, lag: 5)
                   }),
            factor("daily_bar_spacing", label: "日线间隔", unit: .flag,
                   value: dailySpacingReliable ? 1 : nil,
                   reason: hasIntradaySpacing ? "存在间隔小于 12 小时的相邻 K 线，不是日线" : "相邻样本符合日线间隔",
                   history: []),
            factor("drawdown_20", label: "20 日回撤", unit: .ratio,
                   value: drawdown20,
                   reason: "近 20 个交易日相对高点回撤",
                   history: historySeries(closes: closes, volumes: volumes) { c, _ in
                       drawdown(c, lookback: 20)
                   }),
            factor("return_5", label: "5 日涨跌", unit: .ratio,
                   value: ret5,
                   reason: "近 5 个交易日跌速",
                   history: historySeries(closes: closes, volumes: volumes) { c, _ in
                       periodReturn(c, sessions: 5)
                   }),
            factor("volatility_20", label: "20 日波动率", unit: .ratio,
                   value: vol20,
                   reason: "近 20 个交易日实现波动率（年化）",
                   history: historySeries(closes: closes, volumes: volumes) { c, _ in
                       realizedVolatility(c, count: 20)
                   }),
            factor("volume_expansion", label: "量能放大", unit: .absolute,
                   value: volumeExpansion,
                   reason: "近 5 日与此前 15 日平均成交量比",
                   history: historySeries(closes: closes, volumes: volumes) { c, v in
                       guard c.count == v.count else { return nil }
                       return volumeRatio(zip(c, v).map { (close: $0.0, volume: $0.1) })
                   })
        ]

        // 5) 崩盘信号
        let crashSignals = [
            ret5.map { $0 <= -0.07 } ?? false,
            drawdown20.map { $0 <= -0.14 } ?? false,
            vol20.map { $0 >= 0.35 } ?? false,
            volumeExpansion.map { $0 >= 1.8 } ?? false
        ]
        let crashCount = crashSignals.filter { $0 }.count
        let candidateRisk: MarketRiskLevel
        if crashCount >= 3 {
            candidateRisk = .r4Extreme
        } else if crashCount >= 2 {
            candidateRisk = .r3Severe
        } else if crashCount == 1 {
            candidateRisk = .r2High
        } else if (ret5.map { $0 <= -0.035 } ?? false) || (vol20.map { $0 >= 0.25 } ?? false) {
            candidateRisk = .r1Elevated
        } else {
            candidateRisk = .r0Normal
        }

        // 6) 候选状态
        var timeframeConflict = false
        let candidateRegime: MarketRegime
        if !dataReliable {
            candidateRegime = .dataUnreliable
        } else if candidateRisk == .r4Extreme {
            candidateRegime = .extremeRisk
        } else if let ret5Value = ret5, let ret20Value = ret20, let ma20Value = ma20,
                  let ma60Value = ma60, let last = closes.last {
            let bullish = last > ma20Value && ma20Value > ma60Value
                && (slope ?? 0) > 0 && ret20Value > 0.02
            let bearish = last < ma20Value && ma20Value < ma60Value && ret20Value < -0.02
            let longTermBull = ma250.map { ma60Value > $0 } ?? true
            let longTermBear = ma250.map { ma60Value < $0 } ?? true
            let wasRisky = memory.map { [.bearTrend, .riskOff, .extremeRisk].contains($0.confirmedRegime) } ?? false
            if wasRisky && ret5Value > 0.025 && !bullish {
                candidateRegime = .recovery
            } else if vol20.map({ $0 >= 0.35 }) == true {
                candidateRegime = .highVolatility
            } else if candidateRisk >= .r2High {
                candidateRegime = .riskOff
            } else if bullish && !longTermBull {
                timeframeConflict = true
                candidateRegime = .transition
            } else if bearish && !longTermBear {
                timeframeConflict = true
                candidateRegime = .transition
            } else if bullish {
                candidateRegime = memory?.confirmedRegime == .bearTrend ? .transition : .bullTrend
            } else if bearish {
                candidateRegime = memory?.confirmedRegime == .bullTrend ? .transition : .bearTrend
            } else if abs(ret20Value) < 0.04 && abs(last / ma20Value - 1) < 0.04 {
                candidateRegime = .range
            } else if abs(ret5Value) > 0.04 || abs(ret20Value) > 0.08 {
                candidateRegime = .transition
            } else {
                candidateRegime = .uncertain
            }
        } else {
            candidateRegime = .uncertain
        }

        // 7) 防抖：状态要连续 3 个交易日一致才确认；风险上调只需 2 日，下调需 3 日。
        let latestSession = latestTimestamp ?? now
        let isNewSession = memory.map { latestSession > $0.lastEvaluationAt } ?? true
        let confirmedRegime: MarketRegime
        var pendingRegime: MarketRegime?
        var pendingRegimeSessions = 0
        if memory == nil || candidateRegime == .dataUnreliable || candidateRegime == .extremeRisk
            || timeframeConflict || candidateRegime == memory?.confirmedRegime {
            confirmedRegime = candidateRegime
        } else if let prior = memory {
            let count = candidateRegime == prior.pendingRegime
                ? prior.pendingRegimeSessions + (isNewSession ? 1 : 0) : 1
            if count >= 3 {
                confirmedRegime = candidateRegime
            } else {
                confirmedRegime = prior.confirmedRegime
                pendingRegime = candidateRegime
                pendingRegimeSessions = count
            }
        } else {
            confirmedRegime = candidateRegime
        }

        let confirmedRisk: MarketRiskLevel
        var pendingRisk: MarketRiskLevel?
        var pendingRiskSessions = 0
        if memory == nil || candidateRisk == .r4Extreme || candidateRisk == memory?.confirmedRiskLevel {
            confirmedRisk = candidateRisk
        } else if let prior = memory {
            let count = candidateRisk == prior.pendingRiskLevel
                ? prior.pendingRiskSessions + (isNewSession ? 1 : 0) : 1
            if candidateRisk > prior.confirmedRiskLevel && count >= 2 {
                confirmedRisk = candidateRisk
            } else if candidateRisk < prior.confirmedRiskLevel && count >= 3 {
                confirmedRisk = MarketRiskLevel(rawValue: prior.confirmedRiskLevel.rawValue - 1) ?? candidateRisk
                pendingRisk = confirmedRisk == candidateRisk ? nil : candidateRisk
            } else {
                confirmedRisk = prior.confirmedRiskLevel
                pendingRisk = candidateRisk
                pendingRiskSessions = count
            }
        } else {
            confirmedRisk = candidateRisk
        }

        let regime: MarketRegime = !dataReliable ? .dataUnreliable
            : (confirmedRisk == .r4Extreme ? .extremeRisk : confirmedRegime)

        var reasons: [String] = []
        if !dataReliable {
            if !latestIsFresh { reasons.append("日线数据已超过 5 天未更新") }
            if closes.count < 60 { reasons.append("有效收盘样本只有 \(closes.count) 个，不足 60") }
            if hasIntradaySpacing { reasons.append("样本间隔小于 12 小时，不是日线") }
            if hasConflictingDuplicates { reasons.append("同一天存在矛盾的收盘价") }
        } else {
            if let drawdown20, drawdown20 <= -0.10 { reasons.append("近 20 日回撤 \(drawdown20.pct(1))") }
            if let vol20, vol20 >= 0.25 { reasons.append("20 日波动率 \(vol20.pct(1))，处于高位") }
            if crashCount > 0 { reasons.append("触发 \(crashCount) 项风险信号") }
            if timeframeConflict { reasons.append("中期结构与长期均线方向冲突") }
            if let pendingRegime {
                reasons.append("状态可能转向「\(pendingRegime.title)」，已连续 \(pendingRegimeSessions) 个交易日")
            }
        }
        let usableFactors = factors.filter { $0.available && $0.key != "daily_bar_spacing" }.count
        let confidence = dataReliable ? min(100, 35 + Double(usableFactors) * 8) : 0

        let memoryNext = MarketRegimeMemory(confirmedRegime: regime,
                                            confirmedRiskLevel: confirmedRisk,
                                            pendingRegime: pendingRegime,
                                            pendingRegimeSessions: pendingRegimeSessions,
                                            pendingRiskLevel: pendingRisk,
                                            pendingRiskSessions: pendingRiskSessions,
                                            lastEvaluationAt: latestSession)

        let observationOnly = [.recovery, .transition, .uncertain, .highVolatility,
                               .riskOff, .extremeRisk, .dataUnreliable].contains(regime)
        return MarketRegimeAssessment(market: market,
                                      regime: regime,
                                      riskLevel: confirmedRisk,
                                      confidence: confidence,
                                      factors: factors,
                                      reasons: reasons,
                                      dataAsOf: latestTimestamp,
                                      movingAverages: [20: ma20, 60: ma60, 120: ma120, 250: ma250]
                                        .compactMapValues { $0 },
                                      return5Sessions: ret5,
                                      return20Sessions: ret20,
                                      drawdown20Sessions: drawdown20,
                                      realizedVolatility20Sessions: vol20,
                                      volumeExpansion: volumeExpansion,
                                      observationOnly: observationOnly,
                                      ordinaryTBuyAllowed: dataReliable && confirmedRisk < .r2High
                                        && [.bullTrend, .range].contains(regime),
                                      memory: memoryNext)
    }

    // MARK: 工具

    private static func factor(_ key: String, label: String, unit: MarketRegimeFactorUnit,
                               value: Double?, reason: String,
                               history: [Double?]) -> MarketRegimeFactor {
        MarketRegimeFactor(key: key, label: label, value: value,
                           available: value?.isFinite == true, reason: reason,
                           unit: unit, history: history)
    }

    /// 因子历史最多回溯多少个交易日。
    static let factorHistoryLength = 60

    /// 滚动重算同一个因子，回答「这个数最近一直在什么位置」。
    ///
    /// 做法是每取一个端点就砍掉尾部 k 根 K 线重算一遍 —— 得到的是当时真能算出来的值，
    /// 不用今天的参数回头修历史。某个端点上样本不够就留 nil，不拿前值填。
    private static func historySeries(closes: [Double],
                                      volumes: [Double],
                                      length: Int = MarketRegimeEngine.factorHistoryLength,
                                      compute: ([Double], [Double]) -> Double?) -> [Double?] {
        guard closes.count > 1, closes.count == volumes.count else { return [] }
        let span = min(length, closes.count - 1)
        guard span > 0 else { return [] }
        var result: [Double?] = []
        result.reserveCapacity(span)
        for drop in stride(from: span - 1, through: 0, by: -1) {
            let windowCloses = drop == 0 ? closes : Array(closes.dropLast(drop))
            let windowVolumes = drop == 0 ? volumes : Array(volumes.dropLast(drop))
            guard let value = compute(windowCloses, windowVolumes), value.isFinite else {
                result.append(nil)
                continue
            }
            result.append(value)
        }
        return result
    }

    private static func date(from dayKey: String) -> Date? { formatter.date(from: dayKey) }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func averageTail(_ values: [Double], count: Int) -> Double? {
        guard values.count >= count, count > 0 else { return nil }
        let slice = values.suffix(count)
        let mean = slice.reduce(0, +) / Double(count)
        return mean.isFinite ? mean : nil
    }

    private static func periodReturn(_ values: [Double], sessions: Int) -> Double? {
        guard let last = values.last, values.count > sessions else { return nil }
        let base = values[values.count - 1 - sessions]
        guard base > 0 else { return nil }
        let value = last / base - 1
        return value.isFinite ? value : nil
    }

    private static func drawdown(_ values: [Double], lookback: Int) -> Double? {
        guard let last = values.last, values.count >= lookback, lookback > 0 else { return nil }
        let window = values.suffix(lookback)
        guard let peak = window.max(), peak > 0 else { return nil }
        let value = last / peak - 1
        return value.isFinite ? value : nil
    }

    private static func realizedVolatility(_ values: [Double], count: Int) -> Double? {
        guard values.count > count, count >= 2 else { return nil }
        let window = Array(values.suffix(count + 1))
        var returns: [Double] = []
        for index in 1..<window.count {
            let previous = window[index - 1]
            guard previous > 0 else { return nil }
            returns.append(window[index] / previous - 1)
        }
        guard returns.count >= 2 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(returns.count - 1)
        let annualized = (variance.squareRoot()) * (250.0).squareRoot()
        return annualized.isFinite ? annualized : nil
    }

    private static func movingAverageSlope(_ values: [Double], period: Int, lag: Int) -> Double? {
        guard values.count >= period + lag else { return nil }
        let current = averageTail(values, count: period)
        let previous = averageTail(Array(values.dropLast(lag)), count: period)
        guard let current, let previous, previous > 0 else { return nil }
        let value = current / previous - 1
        return value.isFinite ? value : nil
    }

    private static func volumeRatio(_ bars: [(close: Double, volume: Double)]) -> Double? {
        let volumes = bars.map(\.volume).filter { $0 > 0 }
        guard volumes.count >= 20 else { return nil }
        let recent = volumes.suffix(5).reduce(0, +) / 5
        let baselineSlice = volumes.dropLast(5).suffix(15)
        guard baselineSlice.count >= 10 else { return nil }
        let baseline = baselineSlice.reduce(0, +) / Double(baselineSlice.count)
        guard baseline > 0 else { return nil }
        let value = recent / baseline
        return value.isFinite ? value : nil
    }
}

// MARK: - 记忆存取

/// 一次**已确认**的状态变更。
///
/// 只记确认值，不记 pending —— 防抖存在的意义就是让「一根大阳线」不进入结论，
/// 如果 pending 也留痕，记录里全是噪音，等于把防抖又抵消掉。
struct MarketRegimeTransition: Codable, Identifiable, Equatable {
    let sessionKey: String
    let at: Date
    let fromRegime: MarketRegime
    let fromRisk: MarketRiskLevel
    let toRegime: MarketRegime
    let toRisk: MarketRiskLevel

    var id: String { "\(sessionKey)-\(toRegime.rawValue)-\(toRisk.rawValue)" }

    var regimeChanged: Bool { toRegime != fromRegime }
    var riskChanged: Bool { toRisk != fromRisk }
    var isRiskUp: Bool { toRisk > fromRisk }

    /// 一句话读法。风险方向和状态方向可能相反（状态转好但风险升级），
    /// 所以两件事分开写，不合并成「变好 / 变差」。
    var summary: String {
        var parts: [String] = []
        if regimeChanged { parts.append("\(fromRegime.title) → \(toRegime.title)") }
        if riskChanged { parts.append("\(fromRisk.title) → \(toRisk.title)") }
        return parts.joined(separator: " · ")
    }
}

/// 状态记忆存 UserDefaults：它不该进账本备份。
///
/// 理由：这是「市场判断的防抖缓存」，不是账本事实。跟着备份在设备之间搬运，
/// 会让新设备继承一个旧设备上的待确认状态。
enum MarketRegimeStore {
    private static let key = "guanpan.pro.market.regime.memory"
    private static let transitionKey = "guanpan.pro.market.regime.transitions"
    /// 上限 60 条：按一周一次变更算够一年，再多也没人看。
    private static let transitionLimit = 60

    static func load(market: String = "CN") -> MarketRegimeMemory? {
        guard let data = UserDefaults.standard.data(forKey: "\(key).\(market)") else { return nil }
        return try? JSONDecoder().decode(MarketRegimeMemory.self, from: data)
    }

    static func save(_ memory: MarketRegimeMemory, market: String = "CN") {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        UserDefaults.standard.set(data, forKey: "\(key).\(market)")
    }

    // MARK: 变更留痕

    static func loadTransitions(market: String = "CN") -> [MarketRegimeTransition] {
        guard let data = UserDefaults.standard.data(forKey: "\(transitionKey).\(market)"),
              let list = try? JSONDecoder().decode([MarketRegimeTransition].self, from: data) else { return [] }
        return list
    }

    static func clearTransitions(market: String = "CN") {
        UserDefaults.standard.removeObject(forKey: "\(transitionKey).\(market)")
    }

    /// 比较前后两次确认值，变了才写。同一天重复评估不会重复记。
    static func recordChange(from previous: MarketRegimeMemory,
                            to next: MarketRegimeMemory,
                            market: String = "CN") {
        guard previous.confirmedRegime != next.confirmedRegime
                || previous.confirmedRiskLevel != next.confirmedRiskLevel else { return }
        let transition = MarketRegimeTransition(sessionKey: MarketCalendar.isoDay(next.lastEvaluationAt),
                                                at: next.lastEvaluationAt,
                                                fromRegime: previous.confirmedRegime,
                                                fromRisk: previous.confirmedRiskLevel,
                                                toRegime: next.confirmedRegime,
                                                toRisk: next.confirmedRiskLevel)
        var list = loadTransitions(market: market)
        guard list.last?.sessionKey != transition.sessionKey else { return }
        list.append(transition)
        if list.count > transitionLimit { list.removeFirst(list.count - transitionLimit) }
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: "\(transitionKey).\(market)")
    }
}

extension PortfolioStore {
    /// 用上证指数日 K 评估市场状态。
    ///
    /// 用指数而不是持仓个股：个股状态是「这只票怎么样」，
    /// 市场状态要回答的是「现在整个环境适不适合做」。
    func marketRegime(benchmarkCode: String = "sh000001") -> MarketRegimeAssessment? {
        guard let bars = dailyBars[benchmarkCode], bars.count >= 60 else { return nil }
        let previous = MarketRegimeStore.load()
        let result = MarketRegimeEngine.evaluate(bars: bars, previous: previous)
        // 同一根 K 线重复评估不该把 pending 计数推上去，所以只在会话推进时写回。
        if let previous {
            if result.memory.lastEvaluationAt > previous.lastEvaluationAt {
                MarketRegimeStore.recordChange(from: previous, to: result.memory)
                MarketRegimeStore.save(result.memory)
            }
        } else {
            // 第一次评估没有「之前」，不记变更 —— 那是初始化，不是转变。
            MarketRegimeStore.save(result.memory)
        }
        return result
    }
}
