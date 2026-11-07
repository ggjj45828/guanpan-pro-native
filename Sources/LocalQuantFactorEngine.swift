import Foundation

// MARK: - 八类本地量化因子（技术证据层）
//
// 口径来源：观盘 Web F 版 `FLocalQuantEngine`（FCore/LocalQuantEngine.swift），
// 与 Web 版逐函数对齐（趋势结构 / 均线结构 / VWAP 偏离 / 短动量 / 均值回归 /
// 日内波动 / 量能异动 / IOPV 折溢价八类）。补齐 Pro 侧此前没有的因子明细口径。
//
// 治理约束（只做证据，不做信号）：
//   · 因子值只是描述性测量；directionalScore 是波动率标准化后的方向刻度，
//     不是概率、不是预期收益、不是买卖信号、不进任何评分/排名/评级体系。
//   · 样本不足、时间戳不连续、量能缺失 → 一律给 unavailableReason，绝不补 0 假装可用。
//   · VWAP 需 ≥20 个分钟样本且 ≥90% 有成交量；短线因子要求 20 个样本两两间隔 ≤90 秒
//     （分钟档案的断档不能当成相邻分钟）。
//   · 趋势结构至少要两条独立均线（如 MA20/60）才能出数，单条均线不描述趋势结构。
//   · 日内因子（VWAP/短动量/均值回归/日内波动/量能异动）只用当日已收盘前的分钟样本，
//     实时报价过期或不在连续交易时段 → 不可用。

/// 八类因子的枚举，case 与 Web 版 `FLocalQuantFactorKind` 一一对应。
enum LocalQuantFactorKind: String, CaseIterable, Equatable, Sendable {
    case trendStructure
    case movingAverageStructure
    case vwapDeviation
    case shortMomentum
    case meanReversion
    case intradayVolatility
    case volumeAnomaly
    case iopvPremium

    /// 中文展示名。
    var title: String {
        switch self {
        case .trendStructure: return "趋势结构"
        case .movingAverageStructure: return "均线结构"
        case .vwapDeviation: return "VWAP 偏离"
        case .shortMomentum: return "短动量"
        case .meanReversion: return "均值回归"
        case .intradayVolatility: return "日内波动"
        case .volumeAnomaly: return "量能异动"
        case .iopvPremium: return "IOPV 折溢价"
        }
    }

    /// 一句话口径说明（研究页展示用）。
    var definition: String {
        switch self {
        case .trendStructure: return "现价相对 MA20/60/250 的偏离均值（至少两条均线才出数）"
        case .movingAverageStructure: return "MA5/20、MA20/60、MA60/250 三组长短均线乖离的均值"
        case .vwapDeviation: return "现价相对当日分钟 VWAP 的偏离（量不足不出数）"
        case .shortMomentum: return "最近 5 个连续分钟样本的收益"
        case .meanReversion: return "20 个分钟样本均值相对现价的回归空间"
        case .intradayVolatility: return "分钟收益的波动率（描述波动本身，不判方向）"
        case .volumeAnomaly: return "近 5 分钟均量 / 前 15 分钟均量 − 1"
        case .iopvPremium: return "现价相对 ETF 单位净值(IOPV)的折溢价"
        }
    }

    /// 是否带方向刻度（需要波动率作标准化尺度；波动/量能/折溢价本身不判方向）。
    var hasDirectionalScore: Bool {
        switch self {
        case .trendStructure, .movingAverageStructure, .vwapDeviation,
             .shortMomentum, .meanReversion:
            return true
        case .intradayVolatility, .volumeAnomaly, .iopvPremium:
            return false
        }
    }
}

/// 一条因子观测。与 Web 版 `FLocalQuantFactorObservation` 对齐。
struct LocalQuantFactorObservation: Equatable, Identifiable, Sendable {
    var id: LocalQuantFactorKind { kind }
    let kind: LocalQuantFactorKind
    /// 因子原值（偏离/收益/比率，未标准化）。不可用时 nil。
    let value: Double?
    /// 方向刻度：value/波动率 → z/(1+|z|)*100 截断到 [-100,100]。
    /// 只是相对方向描述，不是概率、不是收益预期。无尺度或尺度为 0 时 nil。
    let directionalScore: Int?
    /// 观测时间。
    let observedAt: Date?
    /// 支撑该观测的最新已收盘日线日期（日线类因子用，yyyy-MM-dd 文本）。
    let supportingDataAsOf: String?
    /// 数据来源标签。
    let source: String?
    /// 质量备注（如 VWAP 量能覆盖率）。
    let qualityNote: String?
    /// 不可用原因；非 nil 时 value/score 一定为 nil。
    let unavailableReason: String?

    var isAvailable: Bool { value?.isFinite == true && unavailableReason == nil }
}

/// 一次完整的八类因子评估结果。
struct LocalQuantFactorReport: Equatable, Sendable {
    let code: String
    let evaluatedAt: Date
    let factors: [LocalQuantFactorObservation]
    /// 可用且带方向刻度的因子数（<3 不给综合方向刻度，防稀疏数据误导）。
    let scoredFactorCount: Int
    /// 可用方向刻度的算术平均（至少 3 个才有值）。依旧只是描述性方向刻度。
    let directionalScore: Int?

    /// 可用因子数（含无刻度的波动/量能/折溢价）。
    var availableCount: Int { factors.filter(\.isAvailable).count }
}

/// 八类因子计算引擎：纯函数、离线可测、只做证据。
///
/// 数据口径：
///   · `bars` 传入**不含当日未收盘 bar** 的日线（调用方负责剔除当日形成中的行，
///     与 F 版 `completedBars` 同义——墙钟时间不能证明提供方已定稿当日日线）。
///   · `samples` 是该标的当日分钟样本（按时间升序，`IntradayBar`）。
///   · `price` 是可用的实时价；`iopv` 是 ETF 净值快照（可用时）。
///   · `quoteFresh` 表示实时报价新鲜且处于连续交易时段——日内因子的总闸门。
enum LocalQuantFactorEngine {

    /// 分钟样本允许的最大间隔（秒）：超过就不视为相邻分钟。
    static let maximumIntradaySampleGap: TimeInterval = 90
    /// 短线因子需要的连续分钟样本数。
    static let consecutiveSampleCount = 20

    // MARK: - 入口

    /// 评估八类因子。任何输入缺失只影响对应因子，不整批失败。
    /// - Parameters:
    ///   - bars: 已收盘日线（升序，不含当日未收盘 bar）。
    ///   - samples: 当日分钟样本（升序，含价与量）。
    ///   - price: 实时价（quoteFresh 为 true 时才被日内因子使用）。
    ///   - iopv: ETF 净值快照（仅 iopvPremium 使用；须调用方确认未过期）。
    ///   - quoteFresh: 报价新鲜且在连续交易时段。
    ///   - now: 评估时刻（测试注入用）。
    static func evaluate(code: String,
                         bars: [DailyBar],
                         samples: [IntradayBar],
                         price: Double?,
                         iopv: ETFIOPVSnapshot?,
                         quoteFresh: Bool,
                         now: Date = Date()) -> LocalQuantFactorReport {
        let closes = bars.map(\.close).filter { $0.isFinite && $0 > 0 }
        let dailyVolatility = returnVolatility(Array(closes.suffix(21)))

        let sortedSamples = samples.sorted { $0.timestamp < $1.timestamp }
        let minutePrices = sortedSamples.compactMap { bar -> Double? in
            bar.price.isFinite && bar.price > 0 ? bar.price : nil
        }
        let minuteVolatility = returnVolatility(Array(minutePrices.suffix(21)))
        let vwap = volumeWeightedAverage(sortedSamples)
        let vwapNote = volumeCoverageNote(sortedSamples)
        let recent = recentConsecutiveSamples(sortedSamples)
        let recentPrices = recent.compactMap { bar -> Double? in
            bar.price.isFinite && bar.price > 0 ? bar.price : nil
        }

        // 日内因子的公共拒绝原因
        let intradayUnavailable = quoteFresh
            ? "分钟样本不足或时间间隔过大"
            : "实时行情过期或不在连续交易时段"

        var factors: [LocalQuantFactorObservation] = []

        // 1. 趋势结构：现价相对 MA20/60/250 的偏离均值，至少两条均线。
        factors.append(factor(
            .trendStructure,
            value: trendValue(current: price, bars: bars, periods: [20, 60, 250]),
            scale: dailyVolatility,
            at: now,
            supportingDataAsOf: bars.last?.date,
            source: "日线",
            unavailable: bars.isEmpty ? "新鲜证券日K不可用" : "趋势均线或波动尺度不足"))

        // 2. 均线结构：三组长短均线乖离均值。
        factors.append(factor(
            .movingAverageStructure,
            value: movingAverageStructure(bars: bars),
            scale: dailyVolatility,
            at: bars.isEmpty ? nil : now,
            supportingDataAsOf: bars.last?.date,
            source: "日线",
            unavailable: bars.isEmpty ? "新鲜证券日K不可用" : "均线结构或波动尺度不足"))

        // 3. VWAP 偏离
        factors.append(factor(
            .vwapDeviation,
            value: {
                guard let price, let vwap, vwap > 0 else { return nil }
                return price / vwap - 1
            }(),
            scale: minuteVolatility,
            at: now,
            source: "分钟样本",
            qualityNote: vwapNote,
            unavailable: !quoteFresh ? intradayUnavailable : "分钟成交量不足，无法计算VWAP"))

        // 4. 短动量：最近 5 个连续分钟收益
        factors.append(factor(
            .shortMomentum,
            value: returnOverLastSamples(recentPrices, count: 5),
            scale: minuteVolatility,
            at: now,
            source: "分钟样本",
            unavailable: !quoteFresh ? intradayUnavailable : "短周期分钟样本不足或时间间隔过大"))

        // 5. 均值回归：20 样本均值/现价 − 1
        factors.append(factor(
            .meanReversion,
            value: meanReversionValue(recentPrices),
            scale: minuteVolatility,
            at: now,
            source: "分钟样本",
            unavailable: !quoteFresh ? intradayUnavailable : "分钟价格样本不足或时间间隔过大"))

        // 6. 日内波动：分钟收益波动率（无方向刻度）
        factors.append(factor(
            .intradayVolatility,
            value: quoteFresh ? minuteVolatility : nil,
            scale: nil,
            at: now,
            source: "分钟样本",
            unavailable: !quoteFresh ? intradayUnavailable : "分钟收益样本不足或时间间隔过大"))

        // 7. 量能异动：近 5 / 前 15 均量比 − 1（无方向刻度）
        factors.append(factor(
            .volumeAnomaly,
            value: quoteFresh ? volumeAnomaly(recent) : nil,
            scale: nil,
            at: now,
            source: "分钟样本",
            unavailable: !quoteFresh ? intradayUnavailable : "20个连续有效分钟成交量不足"))

        // 8. IOPV 折溢价：现价/净值 − 1（无方向刻度）
        factors.append(factor(
            .iopvPremium,
            value: {
                guard let price, let nav = iopv?.nav, nav > 0 else { return nil }
                return price / nav - 1
            }(),
            scale: nil,
            at: iopv?.navAt,
            source: iopv?.source,
            unavailable: iopv == nil ? "IOPV缺失、过期或质量未通过" : "ETF价格不可用"))

        let scored = factors.filter { $0.isAvailable && $0.directionalScore != nil }
        let average: Int? = scored.count >= 3
            ? Int((Double(scored.compactMap(\.directionalScore).reduce(0, +)) / Double(scored.count)).rounded())
            : nil

        return LocalQuantFactorReport(
            code: code,
            evaluatedAt: now,
            factors: factors,
            scoredFactorCount: scored.count,
            directionalScore: average)
    }

    // MARK: - 因子包装（与 F 版 factor() 同口径）

    private static func factor(_ kind: LocalQuantFactorKind, value: Double?, scale: Double?,
                               at timestamp: Date?, supportingDataAsOf: String? = nil,
                               source: String?, qualityNote: String? = nil, unavailable: String)
        -> LocalQuantFactorObservation {
        guard let value, value.isFinite else {
            return LocalQuantFactorObservation(
                kind: kind, value: nil, directionalScore: nil, observedAt: nil,
                supportingDataAsOf: nil, source: nil, qualityNote: qualityNote,
                unavailableReason: unavailable)
        }
        var score: Int? = nil
        if let scale, scale.isFinite, scale > 0 {
            let z = value / scale
            guard z.isFinite else {
                return LocalQuantFactorObservation(
                    kind: kind, value: nil, directionalScore: nil, observedAt: nil,
                    supportingDataAsOf: nil, source: nil, qualityNote: qualityNote,
                    unavailableReason: "标准化因子超出可表示范围")
            }
            let bounded = z / (1 + abs(z))
            score = Int((bounded * 100).rounded())
        }
        return LocalQuantFactorObservation(
            kind: kind, value: value, directionalScore: score, observedAt: timestamp,
            supportingDataAsOf: supportingDataAsOf, source: source,
            qualityNote: qualityNote, unavailableReason: nil)
    }

    // MARK: - 各因子计算（与 F 版逐函数对齐）

    /// 现价相对各周期均线的偏离均值；至少两条均线才有值。
    static func trendValue(current: Double?, bars: [DailyBar], periods: [Int]) -> Double? {
        guard let current, current.isFinite, current > 0, !bars.isEmpty else { return nil }
        let averages = periods.compactMap { period -> Double? in
            guard let ma = movingAverage(bars, period: period), ma > 0 else { return nil }
            return current / ma - 1
        }
        // 单条均线不描述趋势结构，至少两条独立周期。
        guard averages.count >= 2 else { return nil }
        let result = averages.reduce(0, +) / Double(averages.count)
        return result.isFinite ? result : nil
    }

    /// 三组长短均线乖离的均值：MA5/20、MA20/60、MA60/250。
    static func movingAverageStructure(bars: [DailyBar]) -> Double? {
        guard !bars.isEmpty else { return nil }
        func latest(_ period: Int) -> Double? { movingAverage(bars, period: period) }
        let pairs = [(latest(5), latest(20)), (latest(20), latest(60)), (latest(60), latest(250))]
        let deviations = pairs.compactMap { short, long -> Double? in
            guard let short, let long, long > 0 else { return nil }
            let value = short / long - 1
            return value.isFinite ? value : nil
        }
        guard !deviations.isEmpty else { return nil }
        let result = deviations.reduce(0, +) / Double(deviations.count)
        return result.isFinite ? result : nil
    }

    /// 简单均线最后一个值；样本不足（< period）返回 nil。
    static func movingAverage(_ bars: [DailyBar], period: Int) -> Double? {
        guard period > 0, bars.count >= period else { return nil }
        let window = bars.suffix(period).map(\.close)
        guard window.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let sum = window.reduce(0, +)
        let result = sum / Double(period)
        return result.isFinite && result > 0 ? result : nil
    }

    /// 当日分钟 VWAP。需 ≥20 个样本，且已知量样本 ≥90%；量总量 >0。
    static func volumeWeightedAverage(_ samples: [IntradayBar]) -> Double? {
        guard samples.count >= consecutiveSampleCount else { return nil }
        let weightedSamples = samples.compactMap { bar -> (price: Double, volume: Double)? in
            guard let volume = bar.volume, volume.isFinite, volume >= 0,
                  bar.price.isFinite, bar.price > 0 else { return nil }
            return (bar.price, volume)
        }
        // 首个腾讯观测没有安全的量增量，偶发计数器归零也会缺量：剔除这些点，
        // 但缺失超过 10% 时直接失败（fail closed）。
        let minimumKnown = Int(ceil(Double(samples.count) * 0.9))
        guard weightedSamples.count >= minimumKnown else { return nil }
        var weighted = 0.0
        var volumeTotal = 0.0
        for sample in weightedSamples {
            let product = sample.price * sample.volume
            guard product.isFinite else { return nil }
            weighted += product
            volumeTotal += sample.volume
            guard weighted.isFinite, volumeTotal.isFinite else { return nil }
        }
        guard volumeTotal > 0 else { return nil }
        let result = weighted / volumeTotal
        return result.isFinite && result > 0 ? result : nil
    }

    /// VWAP 量能覆盖率备注（有点缺量时提示）。
    static func volumeCoverageNote(_ samples: [IntradayBar]) -> String? {
        guard !samples.isEmpty else { return nil }
        let known = samples.filter { bar in
            guard let volume = bar.volume else { return false }
            return volume.isFinite && volume >= 0
        }.count
        guard known < samples.count else { return nil }
        let percent = known * 100 / samples.count
        return "VWAP仅使用已知成交量点：\(known)/\(samples.count)（\(percent)%）；未知量点已忽略"
    }

    /// 最近 20 个「两两间隔 ≤90 秒」的连续分钟样本；断档就返回空（不把断档当相邻）。
    static func recentConsecutiveSamples(_ samples: [IntradayBar]) -> [IntradayBar] {
        let window = Array(samples.suffix(consecutiveSampleCount))
        guard window.count == consecutiveSampleCount,
              zip(window, window.dropFirst()).allSatisfy({
                  let gap = $1.timestamp.timeIntervalSince($0.timestamp)
                  return gap.isFinite && gap > 0 && gap <= maximumIntradaySampleGap
              }) else { return [] }
        return window
    }

    /// 最近 count 个样本的收益：last/first − 1。
    static func returnOverLastSamples(_ prices: [Double], count: Int) -> Double? {
        guard prices.count >= count, let first = prices.suffix(count).first,
              let last = prices.last, first > 0 else { return nil }
        let result = last / first - 1
        return result.isFinite ? result : nil
    }

    /// 均值回归：20 样本均值 / 现价 − 1（现价=样本末值）。
    static func meanReversionValue(_ prices: [Double]) -> Double? {
        let window = Array(prices.suffix(consecutiveSampleCount))
        guard window.count >= 5, let current = window.last, current > 0 else { return nil }
        guard let mean = safeAverage(window), mean > 0 else { return nil }
        let result = mean / current - 1
        return result.isFinite ? result : nil
    }

    /// 量能异动：近 5 均量 / 前 15 均量 − 1（需 20 个已知量样本）。
    static func volumeAnomaly(_ samples: [IntradayBar]) -> Double? {
        guard samples.count >= consecutiveSampleCount else { return nil }
        let window = Array(samples.suffix(consecutiveSampleCount))
        let volumes = window.compactMap { bar -> Double? in
            guard let volume = bar.volume, volume.isFinite, volume >= 0 else { return nil }
            return volume
        }
        guard volumes.count == consecutiveSampleCount else { return nil }
        guard let baseline = safeAverage(Array(volumes.prefix(15))),
              let recent = safeAverage(Array(volumes.suffix(5))),
              baseline > 0 else { return nil }
        let ratio = recent / baseline
        guard ratio.isFinite, ratio > 0 else { return nil }
        let result = ratio - 1
        return result.isFinite ? result : nil
    }

    /// 收益率波动（总体标准差，与 F 版同口径）。≥3 个价才有值；零波动序列返回 0（合法观测）。
    static func returnVolatility(_ prices: [Double]) -> Double? {
        guard prices.count >= 3 else { return nil }
        var returns: [Double] = []
        for (previous, current) in zip(prices, prices.dropFirst()) {
            guard previous > 0 else { return nil }
            let value = current / previous - 1
            guard value.isFinite else { return nil }
            returns.append(value)
        }
        let mean = returns.reduce(0, +) / Double(returns.count)
        guard mean.isFinite else { return nil }
        let squared = returns.map { ($0 - mean) * ($0 - mean) }
        guard squared.allSatisfy(\.isFinite) else { return nil }
        let variance = squared.reduce(0, +) / Double(squared.count)
        guard variance.isFinite, variance >= 0 else { return nil }
        let result = variance.squareRoot()
        return result.isFinite && result >= 0 ? result : nil
    }

    /// 数值稳定的均值（逐项累加 /n，防大数求和溢出语义漂移）。
    static func safeAverage(_ values: [Double]) -> Double? {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        let divisor = Double(values.count)
        var average = 0.0
        for value in values {
            average += value / divisor
            guard average.isFinite else { return nil }
        }
        return average
    }
}
