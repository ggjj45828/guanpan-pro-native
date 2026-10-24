import Foundation

/// 本机规则引擎公共数值工具。
///
/// 这一整个文件都**不联网、不调用大模型**，输入是本机账本与已归档的日 K，
/// 输出是可复算、可解释的分数与文字。所有结论都是「历史描述」，
/// 不是涨跌预测，也不构成买卖建议。
enum NextNum {
    static func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }
    /// 直接收 Double：全球指数（`GlobalIndexQuote.changePercent`）和本机算出的各类
    /// 百分比/盈亏本来就是 Double，以前只有 Decimal 一个入口，调用处被迫层层转换。
    static func double(_ value: Double) -> Double { value }
    static func decimal(_ value: Double) -> Decimal {
        guard value.isFinite else { return 0 }
        return Decimal(string: String(format: "%.6f", value), locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }
    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }
    static func percent(_ value: Double, digits: Int = 3) -> String {
        String(format: "%.\(digits)f%%", value)
    }
    /// 指数点位等展示用。复用同一个 NumberFormatter，避免在 body 里反复构造。
    private static let displayFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        return formatter
    }()
    static func text(_ value: Double, digits: Int = 3) -> String {
        guard value.isFinite else { return "—" }
        displayFormatter.minimumFractionDigits = digits
        displayFormatter.maximumFractionDigits = digits
        return displayFormatter.string(from: NSNumber(value: value)) ?? "—"
    }
    static func signed(_ value: Double, digits: Int = 3) -> String {
        (value >= 0 ? "+" : "") + String(format: "%.\(digits)f", value)
    }
}

// MARK: - 技术信号（只读日 K）

/// 从日线推导的轻量技术信号。
///
/// 口径与老工程 `MarketSignals.swift` 一致：均线排列、MA20/MA60/MA250 结构、
/// 5 日动量、RSI14、MACD(12/26/9)、量比、KDJ 的 J 值。每一项都在 `notes` 里留下
/// 一句人话依据，界面上可以直接摊开给用户看「分数是怎么来的」。
struct NextTechnicalSignal: Equatable {
    var score: Int
    var label: String
    var notes: [String]
    var tags: [String]
    var close: Double
    var rsi: Double?
    var kdjJ: Double?
    var volumeRatio: Double?
    var macdHistogram: Double?
    var dif: Double?
    var dea: Double?
    var ma: [Int: Double] = [:]
    var isOversold = false
    var isOverbought = false

    var trend: String {
        guard let fast = ma[5], let mid = ma[10], let slow = ma[20] else { return "数据不足" }
        if fast > mid && mid > slow { return "多头排列" }
        if fast < mid && mid < slow { return "空头排列" }
        return "均线交织 · 震荡"
    }
}

enum NextSignalEngine {
    /// 不足 20 根有效日 K 直接返回 nil —— 数据不够就不出分，不用短样本冒充结论。
    static func evaluate(_ samples: [NextChartSample]) -> NextTechnicalSignal? {
        let ordered = samples
            .filter { $0.close > 0 }
            .sorted { $0.timestamp < $1.timestamp }
        let source = Array(ordered.suffix(640))
        guard source.count >= 20 else { return nil }
        let closes = source.map { NextNum.double($0.close) }
        let highs = source.map { NextNum.double($0.high ?? $0.close) }
        let lows = source.map { NextNum.double($0.low ?? $0.close) }
        let volumes = source.map { NextNum.double($0.volume ?? 0) }
        guard let latest = closes.last else { return nil }

        func average(_ count: Int) -> Double? {
            guard closes.count >= count else { return nil }
            return closes.suffix(count).reduce(0, +) / Double(count)
        }

        guard let ma5 = average(5), let ma10 = average(10), let ma20 = average(20) else { return nil }
        let ma60 = average(60)
        let ma120 = average(120)
        let ma250 = average(250)

        var raw = 0
        var notes: [String] = []

        if ma5 > ma10 && ma10 > ma20 { raw += 2; notes.append("短期均线多头排列") }
        else if ma5 < ma10 && ma10 < ma20 { raw -= 2; notes.append("短期均线空头排列") }
        else { notes.append("均线交织，震荡格局") }

        if let ma60 {
            if ma20 > ma60 { raw += 1; notes.append("MA20 在 MA60 上方") }
            else { raw -= 1; notes.append("MA20 在 MA60 下方") }
        }
        // 长周期结构：样本够才算，缺 MA250 不用短周期数据顶替。
        if let ma250 {
            if latest >= ma250 { raw += 1; notes.append("收盘在年线 MA250 上方") }
            else { raw -= 1; notes.append("收盘在年线 MA250 下方") }
            if let ma120 {
                if ma120 >= ma250 { raw += 1; notes.append("MA120 位于 MA250 上方") }
                else { raw -= 1; notes.append("MA120 位于 MA250 下方") }
            }
        }

        if latest >= ma20 { raw += 1; notes.append("收盘高于 MA20") }
        else { raw -= 1; notes.append("收盘低于 MA20") }

        if source.count >= 6 {
            let momentum = latest / closes[closes.count - 6] - 1
            if momentum >= 0.02 { raw += 1; notes.append("5 日动量为正") }
            else if momentum <= -0.02 { raw -= 1; notes.append("5 日动量为负") }
        }

        var rsiValue: Double?
        if closes.count >= 15 {
            let base = closes.count - 15
            var delta: [Double] = []
            for offset in 1..<15 { delta.append(closes[base + offset] - closes[base + offset - 1]) }
            let gain = delta.map { max(0, $0) }.reduce(0, +) / 14
            let loss = delta.map { max(0, -$0) }.reduce(0, +) / 14
            let rsi = loss == 0 ? (gain == 0 ? 50 : 100) : 100 - 100 / (1 + gain / loss)
            rsiValue = rsi
            if rsi < 30 { raw += 1; notes.append("RSI14 偏低（\(String(format: "%.3f", rsi))）") }
            else if rsi > 70 { raw -= 1; notes.append("RSI14 偏高（\(String(format: "%.3f", rsi))）") }
            else { notes.append("RSI14 中性（\(String(format: "%.3f", rsi))）") }
        }

        var macdHistogram: Double?
        var difValue: Double?
        var deaValue: Double?
        if closes.count >= 35 {
            var fast = closes[0], slow = closes[0], dea = 0.0, histogram = 0.0
            var dif = 0.0
            for (index, close) in closes.enumerated() {
                if index > 0 {
                    fast += (2.0 / 13.0) * (close - fast)
                    slow += (2.0 / 27.0) * (close - slow)
                }
                dif = fast - slow
                dea = index == 0 ? dif : dea + 0.2 * (dif - dea)
                histogram = 2 * (dif - dea)
            }
            macdHistogram = histogram; difValue = dif; deaValue = dea
            if histogram > 0 { raw += 1; notes.append("MACD 柱值为正") }
            else if histogram < 0 { raw -= 1; notes.append("MACD 柱值为负") }
        }

        var volumeRatio: Double?
        if source.count >= 21, volumes.count >= 21 {
            let baseline = volumes.suffix(21).dropLast().reduce(0, +) / 20
            if baseline > 0 {
                let ratio = volumes[volumes.count - 1] / baseline
                volumeRatio = ratio
                let change = closes[closes.count - 1] / closes[closes.count - 2] - 1
                if ratio >= 1.5 {
                    if change >= 0 { raw += 1; notes.append("放量上涨") }
                    else { raw -= 1; notes.append("放量下跌") }
                }
            }
        }

        var kdjJ: Double?
        if closes.count >= 9 {
            var k = 50.0, d = 50.0
            for index in 8..<closes.count {
                let high = highs[(index - 8)...index].max() ?? closes[index]
                let low = lows[(index - 8)...index].min() ?? closes[index]
                let rsv = high == low ? 50 : (closes[index] - low) / (high - low) * 100
                k = (2.0 / 3.0) * k + (1.0 / 3.0) * rsv
                d = (2.0 / 3.0) * d + (1.0 / 3.0) * k
            }
            kdjJ = 3 * k - 2 * d
        }

        let score = min(100, max(0, 50 + raw * 6))
        let label: String
        switch score {
        case 68...: label = "偏强"
        case 56..<68: label = "偏多"
        case 45..<56: label = "中性"
        case 33..<45: label = "偏空"
        default: label = "偏弱"
        }

        var tags: [String] = []
        if let macdHistogram, let difValue, let deaValue {
            tags.append(macdHistogram > 0 && difValue > deaValue ? "MACD多头" : (macdHistogram > 0 ? "MACD转强" : "MACD空头"))
        }
        let rsiOversold = (rsiValue ?? 50) < 30
        let rsiOverbought = (rsiValue ?? 50) > 70
        let jOversold = (kdjJ ?? 50) < 20
        let jOverbought = (kdjJ ?? 50) > 80
        if rsiOversold || jOversold { tags.append("超卖") }
        else if rsiOverbought || jOverbought { tags.append("超买") }
        if let volumeRatio, volumeRatio >= 1.8 { tags.append("放量") }
        tags.append(latest >= ma20 ? "站上MA20" : "破MA20")

        var ma: [Int: Double] = [5: ma5, 10: ma10, 20: ma20]
        if let ma60 { ma[60] = ma60 }
        if let ma120 { ma[120] = ma120 }
        if let ma250 { ma[250] = ma250 }

        return NextTechnicalSignal(
            score: score, label: label, notes: notes, tags: tags, close: latest,
            rsi: rsiValue, kdjJ: kdjJ, volumeRatio: volumeRatio,
            macdHistogram: macdHistogram, dif: difValue, dea: deaValue, ma: ma,
            isOversold: rsiOversold || jOversold, isOverbought: rsiOverbought || jOverbought)
    }
}

// MARK: - 股息率口径

enum NextDividendRules {
    /// 场内 ETF 代码白名单：15/16/18/50/51/52/56/58/59 开头。
    ///
    /// 特别注意 **508 / 180 必须排除** —— 那是 REITs，行情源给的「折溢价」字段
    /// 不是 IOPV，用它们算股息率会得到离谱的数值。
    static func isOnExchangeETF(_ code: String) -> Bool {
        let digits = code.lowercased()
        guard digits.count == 6, digits.allSatisfy(\.isNumber) else { return false }
        if digits.hasPrefix("508") || digits.hasPrefix("180") { return false }
        return ["15", "16", "18", "50", "51", "52", "56", "58", "59"].contains { digits.hasPrefix($0) }
    }

    /// 评分用的股息率（百分数）。
    ///
    /// - 场内 ETF：分母**优先用 IOPV（净值）**。场内价含折溢价，溢价 15% 的跨境 ETF
    ///   用场内价算股息率会被低估同样比例；红利策略看的是「按净值算的真实分红回报」。
    /// - 个股 / 无 IOPV 时：分母用现价。
    static func yieldPercent(code: String, perShare: Decimal, price: Decimal, iopv: Decimal?) -> Double? {
        guard perShare > 0, price > 0 else { return nil }
        var base = NextNum.double(price)
        if isOnExchangeETF(code), let iopv, iopv > 0 { base = NextNum.double(iopv) }
        guard base > 0, base.isFinite else { return nil }
        return NextNum.double(perShare) / base * 100
    }

    /// 股息率 → 评分加分。
    ///
    /// 档位刻意粗，并且**只加分、不扣分** —— 不分红不等于不好（成长股本来就不分红），
    /// 所以没有股息率时给 0 而不是负分。上界卡在 +14：一只股息率 8% 的标的也不该
    /// 只凭这一项顶进「可考虑」，技术面与仓位仍然要参与。高股息也可能是股价跌出来的
    /// （股息陷阱），所以这只是「更值得看一眼」，不是「闭眼买」。
    static func points(forYieldPercent value: Double?) -> Int {
        guard let value, value.isFinite, value > 0 else { return 0 }
        switch value {
        case 6...: return 14
        case 5..<6: return 11
        case 4..<5: return 8
        case 3..<4: return 5
        case 2..<3: return 2
        default: return 0
        }
    }
}

import SwiftUI

/// 红利买入时机打分（满分 100）。
///
/// 口径（全部本机可复算，不预测价格、不预测分红）：
/// - 股息率 40 分：近 12 个月每份**已核实**派息 ÷ 分母（ETF 有 IOPV 按净值，否则按现价），
///   达到用户设定的目标股息率即拿满，按比例给分。
/// - 价格位置 35 分：现价在近 180 个交易日高低区间中的位置，越靠下分越高。
/// - 高点回撤 15 分：相对近 180 个交易日高点回撤越深分越高（回撤 20% 拿满）。
/// - 分红稳定性 10 分：近三个自然年里有已核实分红的年份数（3 年 10 分 / 2 年 7 分 / 1 年 4 分）。
///
/// 哪项数据缺失，哪项计 0 分并记入 `missing`，界面明示，不拿中性分冒充。
struct DividendBuyScore: Equatable, Identifiable {
    var id: String { code }
    enum Tier: String, Equatable {
        case attention = "值得关注"
        case batch = "可分批"
        case observe = "观望"
        case wait = "等待"
    }
    let code: String
    let price: Decimal
    let perShare: Decimal
    /// 股息率分母：ETF 有 IOPV 时为净值，否则为现价。
    let yieldBase: Decimal
    let yieldPercent: Double
    let targetYieldPercent: Decimal
    let yieldPoints: Int
    let positionPoints: Int
    let drawdownPoints: Int
    let stabilityPoints: Int
    let windowLow: Decimal?
    let windowHigh: Decimal?
    let missing: [String]
    var total: Int { yieldPoints + positionPoints + drawdownPoints + stabilityPoints }
    var tier: Tier {
        switch total {
        case 80...: return .attention
        case 60..<80: return .batch
        case 40..<60: return .observe
        default: return .wait
        }
    }
}

/// 打分的唯一实现。纯函数：同样的输入必然得到同样的分数，用户可以逐项核对。
enum DividendBuyScoreEngine {
    /// 近 180 个交易日（约半年）的日 K 窗口。
    static let windowBars = 180
    /// 回撤满分线：相对窗口高点回撤 20% 即拿满回撤分。
    static let drawdownFullScale = 0.20

    /// - Parameters:
    ///   - perShare: 近 12 个月每份已核实派息（0 表示不打分）。
    ///   - price: 现价（nil 或 ≤0 表示不打分）。
    ///   - dividendEvents: 已合并的去重派息事件（调用方负责 merged）。
    ///   - today: `yyyy-MM-dd`，注入以便测试固定时间。
    static func evaluate(code: String, perShare: Decimal, price: Decimal?, iopv: Decimal?,
                         samples: [NextChartSample], dividendEvents: [NextETFDividendEvent],
                         today: String, targetYieldPercent: Decimal) -> DividendBuyScore? {
        guard perShare > 0, let price, price > 0 else { return nil }
        var missing: [String] = []
        var base = price
        if NextDividendRules.isOnExchangeETF(code), let net = iopv, net > 0 { base = net }

        // 1) 股息率 40 分：达到目标股息率拿满，按比例。
        let yieldPercent = NextNum.double(perShare) / NextNum.double(base) * 100
        var yieldPoints = 0
        if targetYieldPercent > 0 {
            let target = NextNum.double(targetYieldPercent)
            yieldPoints = Int((40 * min(yieldPercent / target, 1)).rounded())
        } else {
            missing.append("目标股息率")
        }

        // 2) 3) 位置与回撤共用同一个日 K 窗口；没有日 K 就都记缺失。
        let window = Array(samples.filter { $0.close > 0 }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(windowBars))
        var positionPoints = 0
        var drawdownPoints = 0
        var windowLow: Decimal?
        var windowHigh: Decimal?
        if !window.isEmpty {
            let lows = window.map { $0.low ?? $0.close }
            let highs = window.map { $0.high ?? $0.close }
            windowLow = lows.min()
            windowHigh = highs.max()
            if let low = windowLow, let high = windowHigh, high > low {
                let position = min(max(NextNum.double((price - low) / (high - low)), 0), 1)
                positionPoints = Int((35 * (1 - position)).rounded())
            } else {
                missing.append("日K区间")
            }
            if let high = windowHigh, high > 0 {
                let drawdown = min(max(NextNum.double((high - price) / high), 0), 1)
                drawdownPoints = Int((15 * min(drawdown / drawdownFullScale, 1)).rounded())
            } else {
                missing.append("日K高点")
            }
        } else {
            missing.append("日K")
        }

        // 4) 分红稳定性 10 分：近三个自然年（含今年）有已核实派息的年份数。
        let currentYear = Int(today.prefix(4)) ?? 0
        let years = Set(dividendEvents
            .filter { $0.isEstimated != true && $0.date <= today }
            .compactMap { Int($0.date.prefix(4)) }
            .filter { $0 >= currentYear - 2 && $0 <= currentYear })
        let stabilityPoints: Int
        switch years.count {
        case 3...: stabilityPoints = 10
        case 2: stabilityPoints = 7
        case 1: stabilityPoints = 4
        default: stabilityPoints = 0
        }

        return DividendBuyScore(code: code, price: price, perShare: perShare, yieldBase: base,
            yieldPercent: yieldPercent, targetYieldPercent: targetYieldPercent,
            yieldPoints: yieldPoints, positionPoints: positionPoints, drawdownPoints: drawdownPoints,
            stabilityPoints: stabilityPoints, windowLow: windowLow, windowHigh: windowHigh, missing: missing)
    }
}

// MARK: - 「值不值得买」打分

struct NextScoreLine: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let detail: String
    let points: Int
}

/// 雷达图的一个维度。`value` 归一化到 0–100，口径统一为「买入友好度」：越高越适合买入。
/// `detail` 是人话依据，`isEstimated` 为 true 表示数据不足、按中性 50 处理（界面上要标出来）。
struct NextScoreDimension: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let title: String
    let value: Double
    let detail: String
    var isEstimated = false
}

/// 一只标的的本机打分结果。`base` 是技术面分数，`lines` 是每一笔加减分的依据，
/// 两者相加就是 `score` —— 用户可以逐条核对，不需要信任黑箱。
struct NextWorthBuyAssessment: Equatable {
    var score: Int
    var action: String
    var base: Int
    var lines: [NextScoreLine]
    var dividendYieldPercent: Double?
    var dividendPerShare: Decimal?
    /// 现价在近 60 个交易日高低区间中的位置（0 = 区间最低，100 = 区间最高）。
    var pricePositionPercent: Double?
    var premiumPercent: Double?
    var costGapPercent: Double?
    var isIncomePlay: Bool
    var barCount: Int
    var notes: [String]
    /// 六维雷达：趋势 / 位置 / 估值 / 股息 / 仓位 / 流动性，全部归一化到 0–100。
    var dimensions: [NextScoreDimension]

    var totalAdjustment: Int { lines.reduce(0) { $0 + $1.points } }
    /// 六维均值，与 `score`（技术面基准 ± 修正）口径不同，只用来横向比较同一只标的的短板。
    var dimensionAverage: Double {
        guard !dimensions.isEmpty else { return 0 }
        return dimensions.reduce(0) { $0 + $1.value } / Double(dimensions.count)
    }
}

enum NextWorthBuyEngine {
    /// 综合打分。数据不足（少于 20 根日 K）返回 nil，界面应显示「数据不足，不出分」。
    ///
    /// 分项（与老工程「值不值得买」同一口径，并补了价格位置这一项）：
    /// 1. 技术面基准 0–100（均线 / 动量 / RSI / MACD / 量能 / KDJ）
    /// 2. 当日涨跌：`涨跌幅 × 3`，截断到 ±8
    /// 3. 股息率：2%→+2、3%→+5、4%→+8、5%→+11、6%+→+14，只加不减
    /// 4. 价格位置：近 60 日区间下 20% 加 3 分、上 20% 减 3 分
    /// 5. 溢折价：溢价 ≥2% 减 5、折价 ≥2% 减 2（折价也可能是流动性问题）
    /// 6. 仓位：达到单标的上限减 10、达到上限 80% 减 5
    ///
    /// 红利标的（股息率 ≥3%）的当日涨跌权重除以 3：对攒股息的人来说，
    /// 跌下去是股息率被抬高、更划算，不做这个修正会「越跌越不推荐」，正好反了。
    ///
    /// 除了总分，还产出 `dimensions` 六维雷达（趋势 / 位置 / 估值 / 股息 / 仓位 / 流动性），
    /// 全部归一化到 0–100、方向统一为「买入友好度」；数据不足的维度给中性 50 并标记 estimated。
    static func evaluate(code: String, price: Decimal, previousClose: Decimal,
                         samples: [NextChartSample], dividendPerShare: Decimal,
                         iopv: Decimal?, costPerUnit: Decimal?,
                         weightPercent: Double?, positionLimitPercent: Double?) -> NextWorthBuyAssessment? {
        guard let signal = NextSignalEngine.evaluate(samples) else { return nil }
        let ordered = samples.filter { $0.close > 0 }.sorted { $0.timestamp < $1.timestamp }
        var lines: [NextScoreLine] = []
        var notes: [String] = ["本机规则打分：技术面 + 股息率 + 价格位置 + 溢折价 + 仓位，不含任何模型预测。"]

        // 1) 当日涨跌
        var changePercent = 0.0
        if previousClose > 0, price > 0 { changePercent = (NextNum.double(price) / NextNum.double(previousClose) - 1) * 100 }

        // 2) 股息率
        let perShare = dividendPerShare > 0 ? dividendPerShare : 0
        let dividendYield = NextDividendRules.yieldPercent(code: code, perShare: perShare, price: price, iopv: iopv)
        let dividendPoints = NextDividendRules.points(forYieldPercent: dividendYield)
        if let dividendYield, dividendPoints > 0 {
            let base = NextDividendRules.isOnExchangeETF(code) && (iopv ?? 0) > 0 ? "按 IOPV 净值" : "按现价"
            lines.append(NextScoreLine(title: "股息率", detail: "\(NextNum.percent(dividendYield))（\(base)，近 12 个月每份 ¥\(NextMoney.text(perShare, digits: 3))）", points: dividendPoints))
        } else if perShare > 0, let dividendYield {
            lines.append(NextScoreLine(title: "股息率", detail: "\(NextNum.percent(dividendYield))，低于 2%，本项不加分", points: 0))
        } else {
            notes.append("没有可核实的近 12 个月派息记录，股息维度按 0 处理（不代表标的好坏）。")
        }
        let isIncomePlay = (dividendYield ?? 0) >= 3

        // 3) 当日涨跌（红利标的权重 / 3）
        let rawChange = NextNum.clamp(changePercent * 3, -8, 8)
        let changePoints = isIncomePlay ? rawChange / 3 : rawChange
        let changeRounded = Int(changePoints.rounded())
        if changeRounded != 0 {
            lines.append(NextScoreLine(title: "当日涨跌",
                                       detail: "\(NextNum.signed(changePercent))%" + (isIncomePlay ? "，红利型标的权重 ÷3" : ""),
                                       points: changeRounded))
        }

        // 4) 价格位置（近 60 日）
        var pricePosition: Double?
        if ordered.count >= 20 {
            let window = Array(ordered.suffix(60))
            let high = window.map { NextNum.double($0.high ?? $0.close) }.max() ?? 0
            let low = window.map { NextNum.double($0.low ?? $0.close) }.min() ?? 0
            let last = NextNum.double(ordered[ordered.count - 1].close)
            if high > low, last.isFinite {
                let position = NextNum.clamp((last - low) / (high - low) * 100, 0, 100)
                pricePosition = position
                if position <= 20 {
                    lines.append(NextScoreLine(title: "价格位置", detail: "现价处于近 \(window.count) 日区间下 \(Int(position.rounded()))%，位置偏低", points: 3))
                } else if position >= 80 {
                    lines.append(NextScoreLine(title: "价格位置", detail: "现价处于近 \(window.count) 日区间上 \(Int((100 - position).rounded()))%，位置偏高", points: -3))
                } else {
                    lines.append(NextScoreLine(title: "价格位置", detail: "现价处于近 \(window.count) 日区间中部（\(Int(position.rounded()))%），本项不加不减", points: 0))
                }
            }
        }

        // 5) 溢折价
        var premium: Double?
        if let iopv, iopv > 0, price > 0 {
            let value = (NextNum.double(price) / NextNum.double(iopv) - 1) * 100
            premium = value
            if abs(value) >= 2 {
                lines.append(NextScoreLine(title: value > 0 ? "场内溢价" : "场内折价",
                                           detail: "\(NextNum.signed(value))%（IOPV ¥\(NextMoney.text(iopv, digits: 3))）",
                                           points: value > 0 ? -5 : -2))
            }
        }

        // 6) 仓位
        if let weightPercent, let positionLimitPercent, positionLimitPercent > 0 {
            if weightPercent >= positionLimitPercent {
                lines.append(NextScoreLine(title: "仓位", detail: "已占 \(NextNum.percent(weightPercent, digits: 1))，达到单标的上限 \(NextNum.percent(positionLimitPercent, digits: 0))", points: -10))
            } else if weightPercent >= positionLimitPercent * 0.8 {
                lines.append(NextScoreLine(title: "仓位", detail: "已占 \(NextNum.percent(weightPercent, digits: 1))，接近单标的上限", points: -5))
            }
        }

        // 参考信息（不计分，但影响人怎么读这个分数）
        var costGap: Double?
        if let costPerUnit, costPerUnit > 0, price > 0 {
            let gap = (NextNum.double(price) / NextNum.double(costPerUnit) - 1) * 100
            costGap = gap
        }

        let base = signal.score
        let total = NextNum.clamp(Double(base + lines.reduce(0) { $0 + $1.points }), 1, 99)
        let score = Int(total.rounded())
        let action: String
        if score >= 65 { action = "可考虑" }
        else if score >= 48 { action = "等确认" }
        else { action = "谨慎" }

        if ordered.count < 60 {
            notes.append("日 K 只有 \(ordered.count) 根，价格位置与长周期均线参考有限；补足 60 根后更可靠。")
        }
        if isIncomePlay {
            notes.append("股息率 ≥3%，按「攒股息」口径降低了当日涨跌的权重；分数高不代表价格不会跌。")
        }
        if (premium ?? 0) >= 2 {
            notes.append("当前场内价格明显高于净值，买入即承担这部分溢价回落的可能。")
        }

        // 7) 雷达六维。每一项都归一化到 0–100，方向统一为「买入友好度」，
        //    数据不足的一律给中性 50 并把 isEstimated 置 true —— 不拿默认值冒充真实结论。
        var dimensions: [NextScoreDimension] = []

        dimensions.append(NextScoreDimension(
            key: "trend", title: "趋势",
            value: Double(base),
            detail: "技术面基准 \(base) 分：均线排列 / 动量 / RSI / MACD / 量能 / KDJ"))

        let positionValue = pricePosition.map { 100 - $0 } ?? 50
        dimensions.append(NextScoreDimension(
            key: "position", title: "位置",
            value: positionValue,
            detail: pricePosition.map { "现价处于近 60 日区间下 \(Int($0.rounded()))%，越靠下越接近买入区" }
                    ?? "日 K 不足 20 根，价格位置按中性处理",
            isEstimated: pricePosition == nil))

        var valuationValue = 50.0
        var valuationDetail = "无 IOPV 数据，估值维度按中性处理"
        var valuationEstimated = true
        if let premium {
            valuationValue = NextNum.clamp(70 - premium * 10, 0, 100)
            valuationDetail = premium >= 0
                ? "场内溢价 \(NextNum.signed(premium))%，溢价越高买入越不划算"
                : "场内折价 \(NextNum.signed(premium))%，折价买入相对有安全垫"
            valuationEstimated = false
        }
        dimensions.append(NextScoreDimension(
            key: "valuation", title: "估值",
            value: valuationValue, detail: valuationDetail, isEstimated: valuationEstimated))

        var dividendValue = 50.0
        var dividendDetail = "没有可核实的近 12 个月派息记录，按中性处理（不代表标的好坏）"
        var dividendEstimated = true
        if let dividendYield {
            dividendValue = NextNum.clamp(dividendYield / 6 * 100, 0, 100)
            dividendDetail = "股息率 \(NextNum.percent(dividendYield))，近 12 个月每份 ¥\(NextMoney.text(perShare, digits: 3))；6% 记满分"
            dividendEstimated = false
        }
        dimensions.append(NextScoreDimension(
            key: "dividend", title: "股息",
            value: dividendValue, detail: dividendDetail, isEstimated: dividendEstimated))

        var roomValue = 100.0
        var roomDetail = "未持有或未设单标的上限，仓位空间不打折"
        var roomEstimated = false
        if let weightPercent, let positionLimitPercent, positionLimitPercent > 0 {
            roomValue = NextNum.clamp(100 - weightPercent / positionLimitPercent * 100, 0, 100)
            roomDetail = "已占 \(NextNum.percent(weightPercent, digits: 1))，单标的上限 \(NextNum.percent(positionLimitPercent, digits: 0))，占得越满越不该加"
        }
        dimensions.append(NextScoreDimension(
            key: "room", title: "仓位",
            value: roomValue, detail: roomDetail, isEstimated: roomEstimated))

        var liquidityValue = 50.0
        var liquidityDetail = "成交量样本不足，流动性按中性处理"
        var liquidityEstimated = true
        if let ratio = signal.volumeRatio {
            switch ratio {
            case 2...: liquidityValue = 95
            case 1.2..<2: liquidityValue = 80
            case 0.8..<1.2: liquidityValue = 60
            default: liquidityValue = 30
            }
            liquidityDetail = "量比 \(String(format: "%.3f", ratio))（最近一日成交量 ÷ 前 20 日均量），越低越难按理想价格成交"
            liquidityEstimated = false
        }
        dimensions.append(NextScoreDimension(
            key: "liquidity", title: "流动性",
            value: liquidityValue, detail: liquidityDetail, isEstimated: liquidityEstimated))

        return NextWorthBuyAssessment(
            score: score, action: action, base: base, lines: lines,
            dividendYieldPercent: dividendYield, dividendPerShare: perShare > 0 ? perShare : nil,
            pricePositionPercent: pricePosition, premiumPercent: premium, costGapPercent: costGap,
            isIncomePlay: isIncomePlay, barCount: ordered.count, notes: notes,
            dimensions: dimensions)
    }
}

// MARK: - 标的体检（网格适合度）

struct NextGridCheck: Identifiable, Equatable {
    var id: String { code }
    let code: String
    let name: String
    let barCount: Int
    let score: Int
    let grade: Grade
    let annualVolatilityPercent: Double?
    let avgAmplitudePercent: Double?
    let avgTurnoverYi: Double?
    let rangeBoundRatio: Double?
    let atExtreme: Bool
    let isOnExchange: Bool
    let isETF: Bool
    let reasons: [String]
    let warnings: [String]

    enum Grade: String, Equatable {
        case suitable = "适合"
        case consider = "可考虑"
        case avoid = "不适合"
    }
}

/// 网格适合度：**规则版、可解释、可复算**，不是 AI 预测，也不保证收益。
///
/// 口径参考公开网格方法（华宝证券网格策略、ETF 网格课堂等一致结论）：
/// 1. 只做场内品种 —— 场外基金申赎费用高、到账慢；
/// 2. 流动性：日均成交额 ≥1 亿元为佳；
/// 3. 波动率适中：年化 15%–30% 最佳，过低没机会，过高容易击穿；
/// 4. 日均振幅 0.5%–2%：太小扣完费用没收益，太大补仓风险高；
/// 5. 震荡性：收盘长期贴近 MA20 比单边行情更适合；
/// 6. 避开刚创 60 日新高/新低的单边极端。
enum NextGridCheckEngine {
    static func isTradableCode(_ code: String) -> Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    struct Metrics: Equatable {
        let annualVolatilityPercent: Double?
        let avgAmplitudePercent: Double?
        let avgTurnoverYi: Double?
        let rangeBoundRatio: Double?
        let atExtreme: Bool
    }

    static func metrics(of samples: [NextChartSample]) -> Metrics {
        let source = samples.filter { $0.close > 0 }.sorted { $0.timestamp < $1.timestamp }.suffix(640)
        let bars = Array(source)
        guard bars.count >= 2 else {
            return Metrics(annualVolatilityPercent: nil, avgAmplitudePercent: nil, avgTurnoverYi: nil, rangeBoundRatio: nil, atExtreme: false)
        }
        let closes = bars.map { NextNum.double($0.close) }
        let highs = bars.map { NextNum.double($0.high ?? $0.close) }
        let lows = bars.map { NextNum.double($0.low ?? $0.close) }
        let volumes = bars.map { NextNum.double($0.volume ?? 0) }

        // 年化波动率：近 250 个交易日收益率标准差 × √252
        var returns: [Double] = []
        let volStart = max(1, closes.count - 251)
        for index in volStart..<closes.count where closes[index - 1] > 0 && closes[index] > 0 {
            returns.append(closes[index] / closes[index - 1] - 1)
        }
        var annualVolatility: Double?
        if returns.count >= 20 {
            let mean = returns.reduce(0, +) / Double(returns.count)
            let variance = returns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(returns.count)
            annualVolatility = variance.squareRoot() * 252.0.squareRoot() * 100
        }

        // 日均振幅：近 60 日 (高-低)/前收
        var amplitudes: [Double] = []
        let ampStart = max(1, closes.count - 61)
        for index in ampStart..<closes.count where closes[index - 1] > 0 {
            amplitudes.append((highs[index] - lows[index]) / closes[index - 1])
        }
        let avgAmplitude = amplitudes.isEmpty ? nil : amplitudes.reduce(0, +) / Double(amplitudes.count) * 100

        // 日均成交额：近 20 日，量（手）×100×收盘价，只判断数量级
        let turnStart = max(0, closes.count - 20)
        var turnovers: [Double] = []
        for index in turnStart..<closes.count where volumes[index] > 0 && closes[index] > 0 {
            turnovers.append(volumes[index] * 100 * closes[index])
        }
        let avgTurnover = turnovers.isEmpty ? nil : turnovers.reduce(0, +) / Double(turnovers.count) / 100_000_000

        // 震荡性：近 60 日收盘落在 MA20 ±5% 内的天数占比
        var boundCount = 0, boundTotal = 0
        let boundStart = max(20, closes.count - 60)
        if closes.count >= 21 {
            for index in boundStart..<closes.count {
                let slice = closes[(index - 20)..<index]
                let ma20 = slice.reduce(0, +) / 20
                guard ma20 > 0 else { continue }
                boundTotal += 1
                if abs(closes[index] / ma20 - 1) <= 0.05 { boundCount += 1 }
            }
        }
        let rangeBound = boundTotal >= 20 ? Double(boundCount) / Double(boundTotal) : nil

        // 单边极端：最新价处于近 60 日高低 1% 内
        var atExtreme = false
        let recentStart = max(0, closes.count - 60)
        if closes.count - recentStart >= 20 {
            let high = highs[recentStart...].max() ?? closes[closes.count - 1]
            let low = lows[recentStart...].min() ?? closes[closes.count - 1]
            let last = closes[closes.count - 1]
            if last >= high * 0.99 || (low > 0 && last <= low * 1.01) { atExtreme = true }
        }

        return Metrics(annualVolatilityPercent: annualVolatility, avgAmplitudePercent: avgAmplitude,
                       avgTurnoverYi: avgTurnover, rangeBoundRatio: rangeBound, atExtreme: atExtreme)
    }

    /// 流动性 30 分：≥1 亿满分，0.3 亿及格，低于 0.3 亿快速衰减。
    static func liquidityScore(_ turnoverYi: Double?) -> Double {
        guard let value = turnoverYi, value.isFinite, value > 0 else { return 0 }
        if value >= 1 { return 30 }
        if value >= 0.3 { return 12 + (value - 0.3) / 0.7 * 18 }
        return value / 0.3 * 12
    }

    /// 波动率 30 分：15%–30% 满分，5%–15% 线性上升，30%–60% 线性衰减。
    static func volatilityScore(_ annualPercent: Double?) -> Double {
        guard let value = annualPercent, value.isFinite, value > 0 else { return 0 }
        if value >= 15, value <= 30 { return 30 }
        if value >= 5 { return (value - 5) / 10 * 30 }
        if value <= 60 { return (60 - value) / 30 * 30 }
        return 0
    }

    /// 振幅 20 分：0.5%–2% 满分。
    static func amplitudeScore(_ avgPercent: Double?) -> Double {
        guard let value = avgPercent, value.isFinite, value >= 0 else { return 0 }
        if value >= 0.5, value <= 2 { return 20 }
        if value < 0.5 { return max(0, (value - 0.1) / 0.4 * 12) }
        return max(0, (4 - value) / 2 * 20)
    }

    /// 震荡性 20 分：贴 MA20 天数占比；处于 60 日极端扣 10。
    static func rangeBoundScore(_ ratio: Double?, atExtreme: Bool) -> Double {
        guard let ratio, ratio.isFinite else { return 0 }
        let base = NextNum.clamp(ratio, 0, 1) * 20
        return atExtreme ? max(0, base - 10) : base
    }

    static func evaluate(code: String, name: String, samples: [NextChartSample],
                         isOnExchange: Bool, barCount: Int? = nil) -> NextGridCheck {
        let metrics = metrics(of: samples)
        let usableBars = barCount ?? samples.filter { $0.close > 0 }.count
        var reasons: [String] = []
        var warnings: [String] = []
        var raw = liquidityScore(metrics.avgTurnoverYi)
            + volatilityScore(metrics.annualVolatilityPercent)
            + amplitudeScore(metrics.avgAmplitudePercent)
            + rangeBoundScore(metrics.rangeBoundRatio, atExtreme: metrics.atExtreme)
        raw = NextNum.clamp(raw, 0, 100)

        if let value = metrics.avgTurnoverYi {
            if value >= 1 { reasons.append("日均成交额 \(String(format: "%.3f", value)) 亿，流动性充足") }
            else if value >= 0.3 { reasons.append("日均成交额 \(String(format: "%.3f", value)) 亿，流动性尚可") }
            else { warnings.append("日均成交额仅 \(String(format: "%.3f", value)) 亿，委托可能难成交或滑点大") }
        }
        if let value = metrics.annualVolatilityPercent {
            if value >= 15, value <= 30 { reasons.append("年化波动率 \(String(format: "%.3f", value))%，处于 15%–30% 理想区间") }
            else if value < 15 { warnings.append("年化波动率仅 \(String(format: "%.3f", value))%，网格触发机会少") }
            else { warnings.append("年化波动率 \(String(format: "%.3f", value))% 偏高，价格容易击穿网格区间") }
        }
        if let value = metrics.avgAmplitudePercent {
            if value >= 0.5, value <= 2 { reasons.append("日均振幅 \(String(format: "%.3f", value))%，日内空间足够") }
            else if value < 0.5 { warnings.append("日均振幅仅 \(String(format: "%.3f", value))%，扣完费用后收益有限") }
            else { warnings.append("日均振幅 \(String(format: "%.3f", value))% 偏大，需要更宽的资金规划防破网") }
        }
        if let ratio = metrics.rangeBoundRatio {
            if ratio >= 0.7 { reasons.append("近 60 日有 \(Int((ratio * 100).rounded()))% 的交易日收盘贴近 MA20，走势偏震荡") }
            else if ratio < 0.4 { warnings.append("近 60 日仅 \(Int((ratio * 100).rounded()))% 的交易日贴近 MA20，单边特征明显，网格容易卖飞或套牢") }
        }
        if metrics.atExtreme { warnings.append("最新价处于近 60 日最高/最低附近，单边风险高，破网概率大") }

        let isETF = NextDividendRules.isOnExchangeETF(code)
        if !isOnExchange {
            warnings.append("场外基金：申赎费用高、到账慢，不适合网格；网格请选场内 ETF")
        } else if !isETF {
            warnings.append("个股受单一公司事件影响，不可预测性高于指数；网格更适合宽基或行业 ETF")
        }

        var grade: NextGridCheck.Grade
        if !isOnExchange { grade = .avoid }
        else if usableBars < 60 {
            grade = .avoid
            warnings.append("本机日 K 只有 \(usableBars) 根（至少需要 60 根），无法可靠评估；补日线后重评")
        } else if raw >= 75 { grade = .suitable }
        else if raw >= 50 { grade = .consider }
        else { grade = .avoid }
        if grade == .suitable, isOnExchange, !isETF { grade = .consider }
        if !isOnExchange { raw = min(raw, 20) }

        return NextGridCheck(code: code, name: name.isEmpty ? code : name, barCount: usableBars,
            score: Int(raw.rounded()), grade: grade,
            annualVolatilityPercent: metrics.annualVolatilityPercent,
            avgAmplitudePercent: metrics.avgAmplitudePercent,
            avgTurnoverYi: metrics.avgTurnoverYi,
            rangeBoundRatio: metrics.rangeBoundRatio, atExtreme: metrics.atExtreme,
            isOnExchange: isOnExchange, isETF: isETF, reasons: reasons, warnings: warnings)
    }
}

// MARK: - 账户诊断

struct NextAccountFinding: Identifiable, Equatable {
    enum Severity: String, Equatable { case act, watch, info }
    var id: String { title }
    let title: String
    let detail: String
    let severity: Severity
}

struct NextAccountReview: Equatable {
    var headline: String
    var findings: [NextAccountFinding]
    var footnotes: [String]
}

/// 账户级诊断：只看本机账本与报价，不读取新闻、不猜行情。
///
/// 规则（全部可复算）：单仓超限 / 目标偏离 / 现金缓冲 / 较成本回撤 / 集中度 /
/// 报价缺口 / 已实现盈亏摘要。
enum NextAccountAdvisor {
    static func review(book: NextBook, quotes: [String: NextQuote],
                       concentrationLimitPercent: Decimal,
                       targetWeights: [String: Decimal] = [:],
                       realizedTotal: Decimal? = nil) -> NextAccountReview? {
        let holdings = book.positions.filter { $0.units > 0 }
        var priced: [(position: NextPosition, value: Double, price: Double)] = []
        var missing: [NextPosition] = []
        for position in holdings {
            guard let quote = quotes[position.code], quote.price > 0 else { missing.append(position); continue }
            let price = NextNum.double(quote.price)
            priced.append((position, price * Double(position.units), price))
        }
        let cash = NextNum.double(book.cash)
        let invested = priced.reduce(0) { $0 + $1.value }
        let total = cash + invested
        guard total > 0 else { return nil }
        let cashWeight = cash / total * 100
        let limit = NextNum.double(concentrationLimitPercent)

        var findings: [NextAccountFinding] = []
        var footnotes: [String] = []

        for item in priced.sorted(by: { $0.value > $1.value }) {
            let weight = item.value / total * 100
            if limit > 0, weight > limit {
                findings.append(NextAccountFinding(
                    title: "\(item.position.name) 超过单仓上限",
                    detail: "占总资产 \(NextNum.percent(weight, digits: 1))，你设定的单标的上限是 \(NextNum.percent(limit, digits: 0))。先暂停继续加仓；若长期逻辑仍成立，可分批降到上限附近，而不是一次性砍仓。",
                    severity: .act))
            }
            if let target = targetWeights[item.position.code] {
                let drift = weight - NextNum.double(target)
                if abs(drift) >= 5 {
                    findings.append(NextAccountFinding(
                        title: "\(item.position.name) 偏离目标仓位",
                        detail: "当前 \(NextNum.percent(weight, digits: 1))，目标 \(NextNum.percent(NextNum.double(target), digits: 1))，偏离 \(NextNum.percent(abs(drift), digits: 1))（\(drift > 0 ? "超配" : "低配")）。先确认目标仍符合你的期限，再考虑调整。",
                        severity: .watch))
                }
            }
            if item.position.costPerUnit > 0, item.price > 0 {
                let gap = (item.price / NextNum.double(item.position.costPerUnit) - 1) * 100
                if gap <= -10 {
                    findings.append(NextAccountFinding(
                        title: "\(item.position.name) 较成本回撤 \(NextNum.percent(abs(gap), digits: 3))",
                        detail: "这是复核信号，不是卖出指令。检查原买入逻辑是否仍成立、仓位是否超限；不要只因为成本价就摊平。",
                        severity: .watch))
                }
            }
        }

        if cashWeight <= 5 {
            findings.append(NextAccountFinding(
                title: "现金缓冲偏低",
                detail: "现金只占 \(NextNum.percent(cashWeight, digits: 1))。新增买入前先核对未来支出与定投扣款，未突破仓位上限时再分批执行。",
                severity: .act))
        } else if cashWeight >= 60 {
            findings.append(NextAccountFinding(
                title: "现金占比偏高",
                detail: "现金占 \(NextNum.percent(cashWeight, digits: 1))。如果不是近期用款安排，可按目标仓位分批投入，不必因单日涨跌一次性进场。",
                severity: .watch))
        }

        if priced.count >= 2 {
            let topTwo = priced.sorted(by: { $0.value > $1.value }).prefix(2).reduce(0) { $0 + $1.value } / total * 100
            if topTwo >= 70 {
                findings.append(NextAccountFinding(
                    title: "前两大持仓合计 \(NextNum.percent(topTwo, digits: 0))",
                    detail: "集中度偏高，单一事件可能同时影响两个仓位。若两只跟踪同一指数或同一行业，实际暴露比这个数字更高。",
                    severity: .watch))
            }
        }

        if !missing.isEmpty {
            let names = missing.prefix(3).map { "\($0.name)(\($0.code))" }.joined(separator: "、")
            findings.append(NextAccountFinding(
                title: "\(missing.count) 只持仓缺报价",
                detail: "\(names) 暂无有效价格，未计入上面的占比与总资产。联网刷新后再看诊断，不要用缺数据的比例做决策。",
                severity: .info))
        }

        if findings.isEmpty {
            let top = priced.sorted(by: { $0.value > $1.value }).first
            findings.append(NextAccountFinding(
                title: "暂未触发仓位或现金警戒",
                detail: top.map { "最重的是 \($0.position.name)，占总资产 \(NextNum.percent($0.value / total * 100, digits: 1))。新增投入前先看它与其他持仓是否重复暴露。" } ?? "当前以现金为主，先按你的期限分批规划，不追随单日行情。",
                severity: .info))
        }

        if let realizedTotal, realizedTotal != 0 {
            footnotes.append("本机已实现盈亏合计 \(realizedTotal >= 0 ? "+" : "")¥\(NextMoney.text(realizedTotal))（按账本成交逐笔成本还原，未计分红）。")
        }
        footnotes.append("诊断依据：本机账本当前现金与持仓市值，行情来自最近一次成功刷新；不读取新闻和基本面。")
        footnotes.append("这些是规则提示，不是投资建议，也不预测涨跌。")

        let headline = "总资产约 ¥\(NextMoney.text(NextNum.decimal(total))) · 持仓 \(NextNum.percent(invested / total * 100, digits: 1)) · 现金 \(NextNum.percent(cashWeight, digits: 1)) · 共 \(holdings.count) 只持仓"
        return NextAccountReview(headline: headline, findings: Array(findings.prefix(6)), footnotes: footnotes)
    }
}

// MARK: - MACD（图表副图）

struct NextMACDPoint: Equatable {
    let dif: Double
    let dea: Double
    let histogram: Double
}

enum NextMACD {
    /// 标准 12/26/9，EMA 平滑系数 2/(N+1)。
    /// 返回与输入等长的数组；不足 34 根时对应位置为 nil（慢周期 + 信号周期还没走完），
    /// 不拿半截均线冒充满仓 MACD。
    static func series(_ closes: [Double], fast: Int = 12, slow: Int = 26, signal: Int = 9) -> [NextMACDPoint?] {
        guard !closes.isEmpty else { return [] }
        var fastEMA = closes[0]
        var slowEMA = closes[0]
        var dea = 0.0
        var result: [NextMACDPoint?] = []
        result.reserveCapacity(closes.count)
        let fastAlpha = 2.0 / (Double(fast) + 1)
        let slowAlpha = 2.0 / (Double(slow) + 1)
        let signalAlpha = 2.0 / (Double(signal) + 1)
        let warmup = slow + signal - 2
        for (index, close) in closes.enumerated() {
            if index > 0 {
                fastEMA += fastAlpha * (close - fastEMA)
                slowEMA += slowAlpha * (close - slowEMA)
            }
            let dif = fastEMA - slowEMA
            dea = index == 0 ? dif : dea + signalAlpha * (dif - dea)
            let histogram = 2 * (dif - dea)
            result.append(index >= warmup ? NextMACDPoint(dif: dif, dea: dea, histogram: histogram) : nil)
        }
        return result
    }
}

// MARK: - 证券名称簿

/// 代码 → 名称的本地记录。
///
/// 原来界面上大量位置只有 6 位代码（或者干脆显示"场内证券"），因为名称只散落在
/// 持仓、报价缓存和一份 4 条的硬编码字典里，任何一处缺失就没有名字可显示。
/// 这里做三件事：
/// 1. 任何一次拿到真实名称（报价、录入持仓、搜索目录）都记下来，**跨启动保留**；
/// 2. 查不到时回落到内置目录 `InstrumentCatalog`（200+ 常见标的）；
/// 3. 全都查不到才回落到代码本身 —— 宁可在代码旁留白，也不编一个假名字。
enum NextNameBook {
    private static let storageKey = "guanpan.names.v1"
    private static let lock = NSLock()
    private static var table: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
    }()

    static func normalize(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func name(for code: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return table[normalize(code)]
    }

    /// 记一条。返回是否真的写入了新名称，方便调用方决定要不要刷新界面。
    @discardableResult
    static func remember(_ name: String?, code: String) -> Bool {
        guard let name else { return false }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalize(code)
        guard !clean.isEmpty, key != clean.lowercased() else { return false }
        lock.lock()
        let changed = table[key] != clean
        if changed { table[key] = clean }
        let snapshot = changed ? table : [:]
        lock.unlock()
        if changed { UserDefaults.standard.set(snapshot, forKey: storageKey) }
        return changed
    }

    /// 批量记：一次报价回来就把整批名称收进簿子，只落盘一次。
    static func remember(pairs: [(code: String, name: String)]) {
        var changed = false
        lock.lock()
        for pair in pairs {
            let clean = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalize(pair.code)
            guard !clean.isEmpty, key != clean.lowercased(), table[key] != clean else { continue }
            table[key] = clean
            changed = true
        }
        let snapshot = changed ? table : [:]
        lock.unlock()
        if changed { UserDefaults.standard.set(snapshot, forKey: storageKey) }
    }

    /// 展示用：账本里存的名称优先（用户自己起的也算），其次名称簿，再次内置目录。
    static func display(_ stored: String?, code: String) -> String {
        if let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty, stored != code {
            return stored
        }
        return resolve(code)
    }

    static func resolve(_ code: String) -> String {
        if let name = name(for: code) { return name }
        if let catalog = InstrumentCatalog.name(for: code) { return catalog }
        return code
    }

    /// 已经"知道名字"的代码：既不是空、也不是把代码当名字。
    static func isResolved(_ code: String) -> Bool {
        resolve(code) != code
    }
}
