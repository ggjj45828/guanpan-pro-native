import Foundation

// MARK: - K 线形态识别引擎（离线 · 可配置 · 可测试）
//
// 设计原则（与研究约束严格一致）：
//   · 全部为「历史描述 + 形态识别」，不是预测，更不是买卖信号；
//   · 每条规则都是可配置的数学阈值，不依赖 AI 看图；
//   · evidenceLevel 恒为 experimental —— 这是观察材料，不是结论；
//   · 任何形态都不单独翻成「买入」，只作为多信号证据的一层；
//   · 未收盘的最新 K 线只做「雏形」备注，不确认；
//   · 与现有六维评分 / 技术指标评分解耦：本引擎只产出「看见了什么」，
//     由调用方（技术信号入口 / 六维 / AI 顾问）按各自口径引用，绝不直接加分。
//
// 六类形态（对应研究需求）：
//   1. 放量突破震荡区间  2. 突破后回踩确认  3. 恐慌下跌后止跌确认
//   4. 阴线实体逐渐缩小  5. 长下影小实体阴线  6. 放量阴线

/// 形态阈值配置。全部可配，便于回测时整组扫描。
struct CandlePatternConfig {
    // 震荡区间判定
    var consolidationLookback: Int = 20
    var consolidationRangeRatio: Double = 0.08   // (maxHigh-minLow)/avgClose < 此值视为震荡
    var breakoutVolumeMultiple: Double = 1.5      // 突破量 ≥ 20 日均量 × 此值

    // 回踩确认
    var pullbackMaxBars: Int = 5
    var pullbackTolerance: Double = 0.02          // 回踩不破突破位 × 容忍

    // 恐慌止跌
    var panicLookback: Int = 10
    var panicDropRatio: Double = 0.10             // 区间内累计跌幅 ≥ 此值
    var panicMaxUpRatio: Double = 0.04            // 止跌确认单根反弹 ≥ 此值（或缩量小阴）

    // 阴线缩小
    var shrinkBars: Int = 3
    var shrinkMinBodyRatio: Double = 0.004        // 单根实体占收盘比下限

    // 长下影小实体阴线
    var lowerShadowRatio: Double = 0.02
    var smallBodyRatio: Double = 0.015
    var lowerShadowDominance: Double = 1.5         // 下影 ≥ 上影 × 此值

    // 放量阴线
    var heavyVolumeMultiple: Double = 2.0
    var heavyBodyRatio: Double = 0.01

    static let `default` = CandlePatternConfig()
}

enum CandlePatternKind: String, CaseIterable {
    case breakout, pullback, panicStop, shrinkingBearish, longLowerShadow, heavyBearish

    var title: String {
        switch self {
        case .breakout: return "放量突破震荡区间"
        case .pullback: return "突破后回踩确认"
        case .panicStop: return "恐慌下跌后止跌确认"
        case .shrinkingBearish: return "阴线实体逐渐缩小"
        case .longLowerShadow: return "长下影小实体阴线"
        case .heavyBearish: return "放量阴线"
        }
    }
}

/// 单条形态命中结果。strength 是 0…1 的「描述性强度」，绝不作买卖评分。
struct CandlePatternHit {
    let kind: CandlePatternKind
    let detected: Bool
    let strength: Double
    let barIndex: Int?            // 触发 K 线在 source 中的下标
    let notes: [String]
}

/// 一份标的的形态识别报告。
struct CandlePatternReport {
    let code: String
    let date: String
    let hits: [CandlePatternHit]
    let evidenceLevel: String
    let notes: [String]

    var detectedKinds: [CandlePatternKind] { hits.filter { $0.detected }.map { $0.kind } }
}

// 单根 K 线的几何量（基于 DailyBar）。
private struct Candle {
    let bar: DailyBar
    var open: Double { bar.open }
    var close: Double { bar.close }
    var high: Double { bar.high }
    var low: Double { bar.low }
    var volume: Double { bar.volume }

    var isBullish: Bool { close >= open }
    var isBearish: Bool { close < open }
    var body: Double { abs(close - open) }
    var bodyRatio: Double { close != 0 ? body / abs(close) : 0 }
    var upperShadow: Double { high - max(open, close) }
    var lowerShadow: Double { min(open, close) - low }
    var range: Double { high - low }
    var upperShadowRatio: Double { close != 0 ? upperShadow / abs(close) : 0 }
    var lowerShadowRatio: Double { close != 0 ? lowerShadow / abs(close) : 0 }
}

enum CandlePatternEngine {

    /// 唯一入口。数据不足返回 experimental 空报告，绝不猜值。
    static func analyze(bars: [DailyBar], config: CandlePatternConfig = .default) -> CandlePatternReport {
        let source = Array(bars.suffix(120))
        let code = source.first?.code ?? ""
        let date = source.last?.date ?? ""
        let minBars = max(config.consolidationLookback, config.panicLookback) + 1
        guard source.count >= minBars, let _ = source.last else {
            return CandlePatternReport(code: code, date: date, hits: [],
                                       evidenceLevel: "experimental",
                                       notes: ["历史长度不足，无法识别 K 线形态"])
        }
        let volumeMA20 = movingAverageVolume(source.map(\.volume), 20)

        var hits: [CandlePatternHit] = []
        hits.append(breakout(source, config, volumeMA20))
        hits.append(pullback(source, config))
        hits.append(panicStop(source, config))
        hits.append(shrinkingBearish(source, config))
        hits.append(longLowerShadow(source, config))
        hits.append(heavyBearish(source, config, volumeMA20))

        let titles = hits.filter { $0.detected }.map { $0.kind.title }
        let notes = titles.isEmpty
            ? ["未识别到显著 K 线形态（仅作观察）"]
            : ["识别到形态：\(titles.joined(separator: "、"))"]
        return CandlePatternReport(code: code, date: date, hits: hits,
                                  evidenceLevel: "experimental", notes: notes)
    }

    // MARK: - 1. 放量突破震荡区间

    private static func breakout(_ source: [DailyBar],
                                 _ config: CandlePatternConfig,
                                 _ volMA20: Double?) -> CandlePatternHit {
        let candles = source.map(Candle.init)
        let n = config.consolidationLookback
        guard candles.count > n else { return miss(.breakout) }
        let window = Array(candles.suffix(n + 1))
        let candidate = window.last!
        let base = Array(window.dropLast())
        let maxHigh = base.map { $0.high }.max() ?? 0
        let minLow = base.map { $0.low }.min() ?? 0
        let avgClose = base.map { $0.close }.reduce(0, +) / Double(base.count)
        let consolidationRatio = avgClose != 0 ? (maxHigh - minLow) / abs(avgClose) : 1
        var notes: [String] = []
        guard consolidationRatio < config.consolidationRangeRatio else {
            return CandlePatternHit(kind: .breakout, detected: false, strength: 0, barIndex: nil,
                                    notes: ["近 \(n) 日振幅 \(String(format: "%.1f", consolidationRatio * 100))% 未形成明显震荡区间"])
        }
        let breakoutLevel = maxHigh
        let broke = candidate.close > breakoutLevel
        let volOK = volMA20.map { candidate.volume >= $0 * config.breakoutVolumeMultiple } ?? false
        let bullish = candidate.isBullish
        if broke, volOK, bullish {
            let raw = (candidate.close - breakoutLevel) / abs(breakoutLevel) / 0.03
            let strength = max(0.3, min(1.0, raw))
            let volText = volMA20 != nil ? String(format: "%.1f", candidate.volume / volMA20!) : "—"
            notes.append("收盘 \(String(format: "%.2f", candidate.close)) 突破区间上沿 \(String(format: "%.2f", breakoutLevel))，量比 \(volText)×")
            return CandlePatternHit(kind: .breakout, detected: true, strength: strength,
                                   barIndex: source.count - 1, notes: notes)
        }
        if !broke { notes.append("未突破区间上沿 \(String(format: "%.2f", breakoutLevel))") }
        if !volOK { notes.append("量能未达突破阈值 \(config.breakoutVolumeMultiple)×") }
        if !bullish { notes.append("当根非阳线") }
        return CandlePatternHit(kind: .breakout, detected: false, strength: 0, barIndex: nil, notes: notes)
    }

    // MARK: - 2. 突破后回踩确认

    private static func pullback(_ source: [DailyBar], _ config: CandlePatternConfig) -> CandlePatternHit {
        let candles = source.map(Candle.init)
        guard candles.count > config.consolidationLookback + config.pullbackMaxBars else { return miss(.pullback) }
        // 在 [consolidationLookback, count-1) 之间找最近一次「收盘价创前 N 日新高」作为突破点。
        var breakoutIndex: Int?
        let start = config.consolidationLookback
        for i in start..<(candles.count - 1) {
            let prior = candles[max(0, i - config.consolidationLookback)..<i].map { $0.high }
            let priorMax = prior.max() ?? 0
            if candles[i].close > priorMax * 1.001 {
                breakoutIndex = i
            }
        }
        guard let bi = breakoutIndex else { return miss(.pullback, "近段未见明显突破") }
        let breakoutLevel = candles[bi].close
        var held = true
        var pulledBack = false
        for j in (bi + 1)..<(candles.count - 1) {
            let c = candles[j]
            if c.close < breakoutLevel * (1 - config.pullbackTolerance) { held = false }
            if c.close <= breakoutLevel * 1.005 && c.close >= breakoutLevel * 0.95 { pulledBack = true }
        }
        let last = candles.last!
        let reassert = last.close > breakoutLevel && last.isBullish
        if held, pulledBack, reassert {
            return CandlePatternHit(kind: .pullback, detected: true, strength: 0.7,
                                   barIndex: candles.count - 1,
                                   notes: ["突破位 \(String(format: "%.2f", breakoutLevel)) 回踩未破，最新阳线重新站上，确认概率较高（观察）"])
        }
        var notes = ["突破位 \(String(format: "%.2f", breakoutLevel))"]
        if !held { notes.append("回踩曾跌破突破位") }
        if !pulledBack { notes.append("未见明显回踩") }
        if !reassert { notes.append("最新未重新站上突破位") }
        return CandlePatternHit(kind: .pullback, detected: false, strength: 0, barIndex: nil, notes: notes)
    }

    // MARK: - 3. 恐慌下跌后止跌确认

    private static func panicStop(_ source: [DailyBar], _ config: CandlePatternConfig) -> CandlePatternHit {
        let candles = source.map(Candle.init)
        let p = config.panicLookback
        guard candles.count >= p + 1 else { return miss(.panicStop) }
        let window = Array(candles.suffix(p + 1))
        let recent = Array(window.dropLast())
        let first = recent.first!.close
        let lastOfRecent = recent.last!.close
        let drop = first != 0 ? (first - lastOfRecent) / abs(first) : 0
        let last = candles.last!
        guard drop >= config.panicDropRatio else {
            return CandlePatternHit(kind: .panicStop, detected: false, strength: 0, barIndex: nil,
                                    notes: ["近 \(p) 日累计跌幅 \(String(format: "%.1f", drop * 100))% 未达恐慌阈值 \(Int(config.panicDropRatio * 100))%"])
        }
        let rebound = lastOfRecent != 0 ? (last.close - lastOfRecent) / abs(lastOfRecent) : 0
        let stabilizing = rebound >= config.panicMaxUpRatio
            || (last.isBearish && last.bodyRatio < config.smallBodyRatio)
            || (!last.isBearish)
        if stabilizing {
            let how = last.isBearish ? "缩量小阴/十字" : "阳线反弹 \(String(format: "%.1f", rebound * 100))%"
            return CandlePatternHit(kind: .panicStop, detected: true, strength: 0.6,
                                   barIndex: candles.count - 1,
                                   notes: ["近 \(p) 日累跌 \(String(format: "%.1f", drop * 100))%，最新出现止跌迹象（\(how)），仅作观察"])
        }
        return CandlePatternHit(kind: .panicStop, detected: false, strength: 0, barIndex: nil,
                                notes: ["累跌 \(String(format: "%.1f", drop * 100))% 但最新仍无明确止跌"])
    }

    // MARK: - 4. 阴线实体逐渐缩小

    private static func shrinkingBearish(_ source: [DailyBar], _ config: CandlePatternConfig) -> CandlePatternHit {
        let candles = source.map(Candle.init)
        let k = config.shrinkBars
        guard candles.count >= k else { return miss(.shrinkingBearish) }
        let lastK = Array(candles.suffix(k))
        guard lastK.allSatisfy({ $0.isBearish && $0.bodyRatio >= config.shrinkMinBodyRatio }) else {
            return CandlePatternHit(kind: .shrinkingBearish, detected: false, strength: 0, barIndex: nil,
                                    notes: ["最近 \(k) 根不均为有效阴线"])
        }
        let bodies = lastK.map { $0.bodyRatio }
        let allShrink = zip(bodies, bodies.dropFirst()).allSatisfy { $0 > $1 }
        if allShrink {
            let seq = bodies.map { String(format: "%.2f%%", $0 * 100) }.joined(separator: "→")
            return CandlePatternHit(kind: .shrinkingBearish, detected: true, strength: 0.6,
                                   barIndex: candles.count - 1,
                                   notes: ["连续 \(k) 根阴线且实体逐步缩小（\(seq)），抛压减弱（观察）"])
        }
        return CandlePatternHit(kind: .shrinkingBearish, detected: false, strength: 0, barIndex: nil,
                                notes: ["最近阴线实体未呈递减"])
    }

    // MARK: - 5. 长下影小实体阴线

    private static func longLowerShadow(_ source: [DailyBar], _ config: CandlePatternConfig) -> CandlePatternHit {
        let candles = source.map(Candle.init)
        guard let last = candles.last else { return miss(.longLowerShadow) }
        let smallBody = last.bodyRatio < config.smallBodyRatio
        let longLower = last.lowerShadowRatio >= config.lowerShadowRatio
        let lowerDominant = last.lowerShadow >= last.upperShadow * config.lowerShadowDominance
        if last.isBearish, smallBody, longLower, lowerDominant {
            return CandlePatternHit(kind: .longLowerShadow, detected: true, strength: 0.55,
                                   barIndex: candles.count - 1,
                                   notes: ["长下影小实体阴线，下影/收盘 \(String(format: "%.1f", last.lowerShadowRatio * 100))%，下方有承接（观察）"])
        }
        return CandlePatternHit(kind: .longLowerShadow, detected: false, strength: 0, barIndex: nil,
                                notes: ["未出现长下影小实体阴线"])
    }

    // MARK: - 6. 放量阴线

    private static func heavyBearish(_ source: [DailyBar],
                                    _ config: CandlePatternConfig,
                                    _ volMA20: Double?) -> CandlePatternHit {
        let candles = source.map(Candle.init)
        guard let last = candles.last, let v = volMA20 else { return miss(.heavyBearish) }
        let heavy = last.volume >= v * config.heavyVolumeMultiple
        let bear = last.isBearish
        let meaningful = last.bodyRatio >= config.heavyBodyRatio
        if heavy, bear, meaningful {
            return CandlePatternHit(kind: .heavyBearish, detected: true, strength: 0.5,
                                   barIndex: candles.count - 1,
                                   notes: ["放量阴线，量比 \(String(format: "%.1f", last.volume / v))×，警惕派发/恐慌（观察，非买入）"])
        }
        return CandlePatternHit(kind: .heavyBearish, detected: false, strength: 0, barIndex: nil,
                                notes: ["未出现放量阴线"])
    }

    // MARK: - 内部工具

    private static func miss(_ kind: CandlePatternKind, _ note: String = "未识别") -> CandlePatternHit {
        CandlePatternHit(kind: kind, detected: false, strength: 0, barIndex: nil, notes: [note])
    }

    private static func movingAverageVolume(_ vols: [Double], _ period: Int) -> Double? {
        guard vols.count >= period else { return nil }
        let window = vols.suffix(period)
        guard window.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return window.reduce(0, +) / Double(period)
    }
}

// MARK: - PortfolioStore 接入（与 MACD 同位置）

extension PortfolioStore {
    /// K 线六形态识别（离线、可配置）。缺数据返回 nil，不静默编造。
    func candlePatterns(code: String, config: CandlePatternConfig = .default) -> CandlePatternReport? {
        guard let bars = dailyBars[code], bars.count >= 30 else { return nil }
        return CandlePatternEngine.analyze(bars: bars, config: config)
    }
}
