import Foundation

// MARK: - 历史验证（样本内 / 样本外）
//
// 分级：计算定义 + 证据（evidenceLevel = experimental · 样本外对照）。
// 它回答的唯一问题：**既有技术规则在历史上出现后，后续收益与「随便哪天」相比如何**，
// 以及样本内（前 70% 时间）与样本外（后 30% 时间）是否一致。
//
// 诚实边界（写死，防止以后被「顺手美化」）：
// - 按**时间顺序**切分样本内 / 样本外，绝不用随机切分（随机切分 = 未来信息泄漏）。
// - 命中 = 信号日收盘 → N 日后收盘的收益 > 0；恰好 0 算未命中。
// - 信号日必须有完整的 N 日前向窗口；窗口不够的信号**剔除**，不计为未命中（也不计为命中）。
// - 每段都给出**无条件基准**（该段任意一天持有 N 日的命中率 / 平均收益）：
//   规则跑不赢「随便哪天」就没有超额，牛市里人人都能「命中」，这不是规则的功劳。
// - 任一段样本数 < 8 → 标「样本不足」，不给命中率、不下结论。
// - 样本外命中率比样本内低 20 个百分点以上 → 明确警告过拟合；样本外超额 ≤ 0 → 明确说无效。
// - 前向窗口可以跨过切分点（信号在样本内、N 日后落到样本外是正常的），
//   但**信号本身**只按其日期归属段落，绝不两边重复计数。
// - 口径简化：按信号日收盘价成交。真实成交应是次日价格，实盘会更差，不拿这里的数字当承诺。
// - 不是买卖信号，不进任何评分，不自动执行。
struct HistoricalSegmentStats {
    /// 该段内有完整前向窗口的信号数。
    let sampleCount: Int
    /// 因前向窗口不足被剔除的信号数（不计入 sampleCount）。
    let droppedIncomplete: Int
    /// 命中率（0…1）；样本不足时为 nil。
    let hitRate: Double?
    /// 平均前向收益（百分数单位）；样本不足时为 nil。
    let avgReturnPercent: Double?
    /// 该段无条件基准命中率（任意一天持有 N 日）。
    let baselineHitRate: Double?
    /// 该段无条件基准平均收益（百分数单位）。
    let baselineAvgReturnPercent: Double?
    /// 样本不足，不可下结论。
    let insufficient: Bool
}

struct HistoricalHorizonReport {
    let horizonDays: Int
    let inSample: HistoricalSegmentStats
    let outOfSample: HistoricalSegmentStats
}

struct HistoricalRuleReport {
    let ruleID: String
    let ruleName: String
    /// 规则定义的诚实描述（数学口径，不含任何预测措辞）。
    let definition: String
    let evidenceLevel: String
    /// 各前向窗口（5 / 10 / 20 交易日）。
    let horizons: [HistoricalHorizonReport]
    let notes: [String]
}

struct HistoricalValidationReport {
    let totalBars: Int
    let splitIndex: Int
    let inSampleRange: String
    let outOfSampleRange: String
    let rules: [HistoricalRuleReport]
    let notes: [String]
}

enum HistoricalValidationEngine {
    static let horizons = [5, 10, 20]
    /// 时间顺序前 70% 为样本内，后 30% 为样本外。
    static let inSampleRatio = 0.7
    /// 任一段样本数低于此值不下结论。
    static let minSamples = 8
    /// 整体可用的最少日线数（MACD 预热 + MA60 + 有意义的前后段）。
    static let minBars = 80

    static func validate(bars: [DailyBar]) -> HistoricalValidationReport {
        let rows = bars.sorted { $0.date < $1.date }
        let n = rows.count
        guard n >= minBars else {
            return HistoricalValidationReport(
                totalBars: n, splitIndex: 0, inSampleRange: "—", outOfSampleRange: "—",
                rules: [],
                notes: ["日线只有 \(n) 根（不足 \(minBars) 根）：不做历史验证，不拿小样本编结论。"])
        }

        let splitIndex = Int(Double(n) * inSampleRatio)
        let inRange = "\(rows[0].date) ~ \(rows[splitIndex - 1].date)"
        let outRange = "\(rows[splitIndex].date) ~ \(rows[n - 1].date)"

        let closes = rows.map(\.close)
        let signals: [(String, String, String, [Int])] = [
            ("macd_golden", "MACD 金叉（日线 12/26/9）",
             "DIF 上穿 DEA（前一根 DIF≤DEA 且当根 DIF>DEA，且两根之间无缺口）",
             macdGoldenCrossIndices(closes: closes)),
            ("breakout", "放量突破震荡区间",
             "近 20 根窄幅震荡后放量收于区间上沿之上（复用 K 线六形态口径）",
             breakoutIndices(bars: rows)),
            ("ma60_reclaim", "收盘上穿 MA60",
             "前一日收盘 ≤ MA60 且当日收盘 > MA60",
             maCrossIndices(closes: closes, period: 60)),
        ]

        var ruleReports: [HistoricalRuleReport] = []
        for (id, name, definition, indices) in signals {
            let horReports = horizons.map { h in
                HistoricalHorizonReport(
                    horizonDays: h,
                    inSample: segmentStats(closes: closes, signalIndices: indices,
                                           horizon: h, range: 0..<splitIndex),
                    outOfSample: segmentStats(closes: closes, signalIndices: indices,
                                              horizon: h, range: splitIndex..<n))
            }
            ruleReports.append(HistoricalRuleReport(
                ruleID: id, ruleName: name, definition: definition,
                evidenceLevel: "experimental · 样本外对照",
                horizons: horReports,
                notes: ruleNotes(horizons: horReports)))
        }

        let notes = [
            "按时间顺序切分：样本内 \(inRange)（前 70%），样本外 \(outRange)（后 30%）。不用随机切分，杜绝未来信息泄漏。",
            "命中 = 信号日收盘到 N 交易日后收盘的收益 > 0；恰好 0 算未命中。窗口不足的信号剔除，不计成败。",
            "每段都给出无条件基准（该段任意一天持有 N 日）：跑不赢基准就没有超额，牛市的高命中率不是规则的功劳。",
            "口径简化：按信号日收盘价成交，真实成交应按次日价格，实盘结果会更差，此处数字不是收益承诺。",
            "本结果是历史统计观察材料（experimental），不是买卖信号，不进评分，不自动执行。",
        ]

        return HistoricalValidationReport(
            totalBars: n, splitIndex: splitIndex,
            inSampleRange: inRange, outOfSampleRange: outRange,
            rules: ruleReports, notes: notes)
    }

    // MARK: - 分段统计

    private static func segmentStats(closes: [Double], signalIndices: [Int],
                                     horizon: Int, range: Range<Int>) -> HistoricalSegmentStats {
        let n = closes.count
        var sample = 0, dropped = 0, hits = 0
        var sum = 0.0
        for i in signalIndices {
            guard range.contains(i) else { continue }
            guard i + horizon < n, closes[i] > 0 else {
                dropped += 1
                continue
            }
            let ret = (closes[i + horizon] / closes[i] - 1) * 100
            guard ret.isFinite else { dropped += 1; continue }
            sample += 1
            if ret > 0 { hits += 1 }
            sum += ret
        }

        // 无条件基准：该段内所有具备完整窗口的交易日。
        var baseSample = 0, baseHits = 0
        var baseSum = 0.0
        for i in range {
            guard i + horizon < n, closes[i] > 0 else { continue }
            let ret = (closes[i + horizon] / closes[i] - 1) * 100
            guard ret.isFinite else { continue }
            baseSample += 1
            if ret > 0 { baseHits += 1 }
            baseSum += ret
        }

        let insufficient = sample < minSamples
        return HistoricalSegmentStats(
            sampleCount: sample,
            droppedIncomplete: dropped,
            hitRate: insufficient ? nil : Double(hits) / Double(sample),
            avgReturnPercent: insufficient ? nil : sum / Double(sample),
            baselineHitRate: baseSample > 0 ? Double(baseHits) / Double(baseSample) : nil,
            baselineAvgReturnPercent: baseSample > 0 ? baseSum / Double(baseSample) : nil,
            insufficient: insufficient)
    }

    // MARK: - 结论备注（只陈述统计事实）

    private static func ruleNotes(horizons: [HistoricalHorizonReport]) -> [String] {
        var notes: [String] = []
        for h in horizons {
            let tag = "\(h.horizonDays) 日"
            let a = h.inSample, b = h.outOfSample
            if a.insufficient && b.insufficient {
                notes.append("\(tag)：两段样本均不足 \(minSamples) 次，不下结论")
                continue
            }
            if a.insufficient || b.insufficient {
                notes.append("\(tag)：一段样本不足 \(minSamples) 次，无法对比样本内外")
                continue
            }
            guard let aHit = a.hitRate, let bHit = b.hitRate,
                  let aBase = a.baselineHitRate, let bBase = b.baselineHitRate else { continue }
            let aExcess = (aHit - aBase) * 100
            let bExcess = (bHit - bBase) * 100
            if (aHit - bHit) * 100 > 20 {
                notes.append("\(tag)：样本外命中率较样本内低 \(((aHit - bHit) * 100).num(0)) 个百分点以上 —— 警惕过拟合")
            }
            if bExcess <= 0 {
                notes.append("\(tag)：样本外未跑赢无条件基准（超额 \(bExcess.num(1)) 个百分点），规则在此段无优势")
            } else if aExcess > 0 && bExcess > 0 {
                notes.append("\(tag)：样本内外均跑赢基准（超额 \(aExcess.num(1)) / \(bExcess.num(1)) 个百分点）")
            }
        }
        return notes
    }

    // MARK: - 规则信号日提取（全部只用 ≤ 当日的数据）

    /// MACD 金叉：DIF 上穿 DEA，且两根之间无缺口（与 MarketSignals 的 cross 口径一致）。
    static func macdGoldenCrossIndices(closes: [Double]) -> [Int] {
        let inputs = closes.enumerated().map { index, close in
            MACDBar(timestamp: Date(timeIntervalSince1970: Double(index)), close: close)
        }
        let series = MACDEngine.calculate(bars: inputs, timeframe: .daily)
        let points = series.points
        guard points.count >= 2 else { return [] }
        var out: [Int] = []
        for k in 1..<points.count {
            let prev = points[k - 1], cur = points[k]
            guard cur.inputIndex == prev.inputIndex + 1 else { continue }
            if prev.dif <= prev.dea && cur.dif > cur.dea {
                out.append(cur.inputIndex)
            }
        }
        return out
    }

    /// 放量突破：复用 CandlePatternEngine，对每个前缀序列判定「最后一根是否命中」。
    static func breakoutIndices(bars: [DailyBar]) -> [Int] {
        var out: [Int] = []
        guard bars.count > 20 else { return out }
        for i in 20..<bars.count {
            let report = CandlePatternEngine.analyze(bars: Array(bars[0...i]))
            if report.hits.contains(where: { $0.kind == .breakout && $0.detected }) {
                out.append(i)
            }
        }
        return out
    }

    /// 收盘上穿 MA60：前一日 ≤ MA60 且当日 > MA60。
    static func maCrossIndices(closes: [Double], period: Int) -> [Int] {
        var out: [Int] = []
        guard closes.count > period else { return out }
        func ma(_ end: Int) -> Double? {
            guard end + 1 >= period else { return nil }
            let window = closes[(end + 1 - period)...end]
            return window.reduce(0, +) / Double(period)
        }
        for i in period..<closes.count {
            guard let now = ma(i), let prev = ma(i - 1) else { continue }
            if closes[i - 1] <= prev && closes[i] > now {
                out.append(i)
            }
        }
        return out
    }
}
