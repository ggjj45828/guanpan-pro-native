import Foundation

// MARK: - 量能结构分析（移植自观盘max FCore/VolumeAnalysis.swift）
//
// 口径与观盘max 保持一致，不自行发明阈值：
//   · 成交量均线窗口 5 / 10 / 20 / 60，必须窗口满且每根都有有效量；
//   · 已收盘 K 线的均线含当根，形成中 K 线只用历史（不把未完成量算进基准）；
//   · 已收盘 K 线用「前 20 根均量」做对比基准，形成中 K 线用「同进度历史均量」；
//   · 连续放量/缩量只在相邻两根都收盘、且前一根有量时计数；
//   · 价量关系只在收盘 K 线上判定；
//   · evidenceLevel 恒为 experimental —— 这是观察材料，不是买卖结论。
//
// 与 Pro 数据的适配：
//   · `DailyBar` 带成交量（qfq 前复权只改价格，成交量不受复权影响，可直接用）；
//   · `IntradayBar` 是本机分时快照而非归档 K 线，因此一律按「形成中、无同进度基线」
//     处理，绝不把快照量伪装成已收盘分钟 K 线。
//   · 时间帧沿用 Pro 的 `MACDTimeframe`（daily / weekly / minutes60 三档）。

enum VolumeEvidenceLevel: String, CaseIterable, Equatable, Sendable {
    case experimental, observational, validated, degraded, retired
}

struct VolumeInputBar {
    let timeframe: MACDTimeframe
    let timestamp: Date
    let close: Double?
    let volume: Double?
    var isFinal: Bool = true
    /// 形成中 K 线的完成度 0...1，用于匹配同进度历史基线。
    var completionFraction: Double? = nil
}

enum VolumeState: String, Equatable, Sendable {
    case unavailable
    case formingProvisional
    case aboveSameTimeBaseline
    case belowSameTimeBaseline
    case atSameTimeBaseline
}

enum PriceVolumeRelation: String, Equatable, Sendable {
    case unavailable
    case provisional
    case priceUpVolumeAboveBaseline
    case priceUpVolumeAtOrBelowBaseline
    case priceDownVolumeAboveBaseline
    case priceDownVolumeAtOrBelowBaseline
    case unchangedPriceVolumeAboveBaseline
    case unchangedPriceVolumeAtOrBelowBaseline
}

struct SameProgressVolumeBaseline {
    let timeframe: MACDTimeframe
    let completionFraction: Double
    let volumes: [Double]
}

struct VolumeAnalysisPoint {
    let timeframe: MACDTimeframe
    let timestamp: Date
    let isFinal: Bool
    let completionFraction: Double?
    let volume: Double?
    let volumeMA5: Double?
    let volumeMA10: Double?
    let volumeMA20: Double?
    let volumeMA60: Double?
    let volumeToMA5: Double?
    let volumeToMA20: Double?
    let volumeToComparisonBaseline: Double?
    let volumeChangeRate: Double?
    let consecutiveExpansionCount: Int
    let consecutiveContractionCount: Int
    let state: VolumeState
    let priceVolumeRelation: PriceVolumeRelation
    let reasonCodes: [String]
}

struct VolumeAnalysisResult {
    let timeframe: MACDTimeframe
    let points: [VolumeAnalysisPoint]
    let evidenceLevel: VolumeEvidenceLevel
    let reasonCodes: [String]

    var latest: VolumeAnalysisPoint? { points.last }
    var validBarCount: Int { points.filter { $0.volume != nil }.count }
}

enum VolumeAnalysisEngine {

    /// 唯一入口。任何输入不合格都返回空的 experimental 结果 + 原因码，绝不猜值。
    static func calculate(bars: [VolumeInputBar],
                          timeframe: MACDTimeframe,
                          sameProgressBaseline: SameProgressVolumeBaseline? = nil) -> VolumeAnalysisResult {
        func reject(_ code: String) -> VolumeAnalysisResult {
            VolumeAnalysisResult(timeframe: timeframe, points: [],
                                 evidenceLevel: .experimental, reasonCodes: [code])
        }
        guard !bars.isEmpty else { return reject("volume_history_unavailable") }
        guard bars.allSatisfy({ $0.timeframe == timeframe }) else {
            return reject("volume_timeframe_mismatch")
        }
        var previous: Date?
        for bar in bars {
            guard bar.timestamp.timeIntervalSince1970.isFinite else {
                return reject("volume_bar_timeline_invalid")
            }
            if let previous, bar.timestamp <= previous {
                return reject("volume_bar_timeline_invalid")
            }
            previous = bar.timestamp
        }

        let allVolumes: [Double?] = bars.map { validVolume($0.volume) }
        let baselineMean = sameProgressMean(bars: bars,
                                           timeframe: timeframe,
                                           baseline: sameProgressBaseline)
        var points: [VolumeAnalysisPoint] = []

        for (index, bar) in bars.enumerated() {
            let volume = allVolumes[index]
            // 已收盘含当根；形成中只用历史。
            let source: [Double?] = bar.isFinal
                ? Array(allVolumes[...index])
                : Array(allVolumes[..<index])
            let ma5 = movingAverage(source, 5)
            let ma10 = movingAverage(source, 10)
            let ma20 = movingAverage(source, 20)
            let ma60 = movingAverage(source, 60)
            let prior: [Double?] = Array(allVolumes[..<index])
            let priorMA20 = movingAverage(prior, 20)

            let comparisonBaseline: Double? = bar.isFinal ? priorMA20 : baselineMean
            let toBaseline = safeRatio(volume, comparisonBaseline)
            let toMA5 = bar.isFinal ? safeRatio(volume, ma5) : nil
            let toMA20 = bar.isFinal ? safeRatio(volume, ma20) : nil
            let changeRate: Double? = {
                guard bar.isFinal, let volume, let previous = prior.last, let prev = previous, prev > 0 else { return nil }
                return volume / prev - 1
            }()

            let state: VolumeState
            if volume == nil {
                state = .unavailable
            } else if !bar.isFinal && comparisonBaseline == nil {
                state = .formingProvisional
            } else if let toBaseline {
                state = toBaseline > 1 ? .aboveSameTimeBaseline
                    : toBaseline < 1 ? .belowSameTimeBaseline : .atSameTimeBaseline
            } else {
                state = .unavailable
            }

            let relation = priceVolumeRelation(bars: bars, index: index, state: state)
            let (expansion, contraction) = consecutiveCounts(allVolumes: allVolumes,
                                                              bars: bars, index: index)
            var codes: [String] = []
            if volume == nil { codes.append("volume_bar_missing") }
            if !bar.isFinal { codes.append("volume_bar_forming") }
            if !bar.isFinal && comparisonBaseline == nil { codes.append("same_progress_baseline_unavailable") }
            if state == .unavailable && volume != nil { codes.append("comparison_baseline_unavailable") }

            points.append(VolumeAnalysisPoint(
                timeframe: timeframe,
                timestamp: bar.timestamp,
                isFinal: bar.isFinal,
                completionFraction: bar.completionFraction,
                volume: volume,
                volumeMA5: ma5,
                volumeMA10: ma10,
                volumeMA20: ma20,
                volumeMA60: ma60,
                volumeToMA5: toMA5,
                volumeToMA20: toMA20,
                volumeToComparisonBaseline: toBaseline,
                volumeChangeRate: changeRate,
                consecutiveExpansionCount: expansion,
                consecutiveContractionCount: contraction,
                state: state,
                priceVolumeRelation: relation,
                reasonCodes: codes))
        }

        return VolumeAnalysisResult(timeframe: timeframe, points: points,
                                    evidenceLevel: .experimental,
                                    reasonCodes: ["volume_evidence_experimental"])
    }

    // MARK: - Pro 数据适配

    /// 日线：成交量直接用（qfq 复权不改变成交量）。日期必须全部能解析，
    /// 否则返回 experimental 拒绝结果，不静默丢弃任何一根。
    static func daily(_ bars: [DailyBar]) -> VolumeAnalysisResult {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        var input: [VolumeInputBar] = []
        input.reserveCapacity(bars.count)
        for bar in bars {
            guard let date = formatter.date(from: bar.date) else {
                return VolumeAnalysisResult(timeframe: .daily, points: [],
                                            evidenceLevel: .experimental,
                                            reasonCodes: ["volume_bar_timeline_invalid"])
            }
            input.append(VolumeInputBar(timeframe: .daily, timestamp: date,
                                        close: bar.close, volume: bar.volume, isFinal: true))
        }
        return calculate(bars: input, timeframe: .daily)
    }

    /// 本机分时快照：不是归档分钟 K 线，一律按形成中处理且不带同进度基线。
    /// 这样输出只会是 formingProvisional，不会伪装出「放量/缩量」结论。
    static func snapshot(_ bars: [IntradayBar]) -> VolumeAnalysisResult {
        let sorted = bars.sorted { $0.timestamp < $1.timestamp }
        let input = sorted.map {
            VolumeInputBar(timeframe: .minutes60, timestamp: $0.timestamp,
                           close: $0.price, volume: $0.volume, isFinal: false)
        }
        return calculate(bars: input, timeframe: .minutes60)
    }

    // MARK: - 内部计算

    private static func validVolume(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// 增量稳定均值：窗口必须满且每根都有量，否则 nil。
    private static func movingAverage(_ values: [Double?], _ period: Int) -> Double? {
        guard values.count >= period else { return nil }
        let window = values.suffix(period)
        var sum = 0.0
        for value in window {
            guard let value else { return nil }
            sum += value
        }
        return sum / Double(period)
    }

    private static func safeRatio(_ value: Double?, _ baseline: Double?) -> Double? {
        guard let value, let baseline, baseline > 0, value.isFinite else { return nil }
        return value / baseline
    }

    /// 同进度基线只在：形成中 K 线、时间帧一致、完成度差 ≤ 1e-6、
    /// 样本全部有效且 ≥ 5 根时才成立。
    private static func sameProgressMean(bars: [VolumeInputBar],
                                         timeframe: MACDTimeframe,
                                         baseline: SameProgressVolumeBaseline?) -> Double? {
        guard let baseline, baseline.timeframe == timeframe else { return nil }
        guard let forming = bars.first(where: { !$0.isFinal }),
              let fraction = forming.completionFraction,
              abs(fraction - baseline.completionFraction) <= 1e-6 else { return nil }
        let volumes = baseline.volumes.filter { $0.isFinite && $0 >= 0 }
        guard volumes.count >= 5, volumes.count == baseline.volumes.count else { return nil }
        return volumes.reduce(0, +) / Double(volumes.count)
    }

    private static func consecutiveCounts(allVolumes: [Double?],
                                          bars: [VolumeInputBar],
                                          index: Int) -> (Int, Int) {
        guard index > 0 else { return (0, 0) }
        var expansion = 0
        var contraction = 0
        var cursor = index
        while cursor > 0 {
            let current = bars[cursor]
            let previous = bars[cursor - 1]
            guard current.isFinal, previous.isFinal,
                  let now = allVolumes[cursor], let before = allVolumes[cursor - 1],
                  before > 0 else { break }
            if now > before { expansion += 1; contraction = 0 }
            else if now < before { contraction += 1; expansion = 0 }
            else { break }
            cursor -= 1
        }
        return (expansion, contraction)
    }

    private static func priceVolumeRelation(bars: [VolumeInputBar],
                                            index: Int,
                                            state: VolumeState) -> PriceVolumeRelation {
        guard index > 0, bars[index].isFinal else {
            return bars[index].isFinal ? .unavailable : .provisional
        }
        guard let now = bars[index].close, let before = bars[index - 1].close,
              now.isFinite, before.isFinite, now > 0, before > 0 else { return .unavailable }
        let above = state == .aboveSameTimeBaseline
        let atOrBelow = state == .belowSameTimeBaseline || state == .atSameTimeBaseline
        guard above || atOrBelow else { return .unavailable }
        if now > before {
            return above ? .priceUpVolumeAboveBaseline : .priceUpVolumeAtOrBelowBaseline
        } else if now < before {
            return above ? .priceDownVolumeAboveBaseline : .priceDownVolumeAtOrBelowBaseline
        }
        return above ? .unchangedPriceVolumeAboveBaseline : .unchangedPriceVolumeAtOrBelowBaseline
    }
}
