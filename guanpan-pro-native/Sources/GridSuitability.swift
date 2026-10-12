import Foundation

/// 网格适合度评估结果。**规则版、可解释、可复算**——不是 AI 预测，也不保证收益。
///
/// 评分口径参考公开网格交易方法（华宝证券网格策略、ETF 网格课堂等一致结论）：
/// 1. 只做场内品种：场外基金申购赎回费用高、到账慢，不适合网格；
/// 2. 流动性：日均成交额 ≥1 亿元为佳（委托容易成交、滑点小）；
/// 3. 波动率适中：年化 15%–30% 最佳——过低没交易机会，过高容易击穿网格；
/// 4. 日均振幅 0.5%–2%：太小网格收益有限，太大补仓风险高；
/// 5. 震荡性：收盘价长期贴近 MA20（区间往复）比单边行情更适合；
/// 6. 避开刚创 60 日新高/新低的单边极端（易卖飞或资金耗尽）。
struct GridSuitability: Identifiable {
    var id: String { code }
    let code: String
    let name: String
    /// 本地日线根数。评估需要至少 60 个交易日。
    let barCount: Int
    /// 0...100 综合分。
    let score: Int
    let grade: Grade
    /// 年化波动率（%），近一年（或全部样本不足一年时取全部）。
    let annualVolatilityPercent: Double?
    /// 日均振幅（%），近 60 个交易日。
    let avgDailyAmplitudePercent: Double?
    /// 日均成交额（亿元），近 20 个交易日；按腾讯日 K 成交量（手）×100×收盘价估算。
    let avgTurnoverYi: Double?
    /// 收盘价落在 MA20 ±5% 内的天数占比（0...1），近 60 个交易日；越高越「震荡」。
    let rangeBoundRatio: Double?
    /// 最新价是否处于 60 日高低点 1% 范围内（单边风险）。
    let atExtreme: Bool
    /// 是否场内品种（ETF / 证券）；场外基金为 false。
    let isOnExchange: Bool
    /// 是否 ETF（相对个股；个股波动不可预测，只建议到「可考虑」）。
    let isETF: Bool
    /// 加分理由（可解释）。
    let reasons: [String]
    /// 不适合理由 / 风险提示。
    let warnings: [String]

    enum Grade: String {
        case suitable = "适合"
        case consider = "可考虑"
        case avoid = "不适合"
    }
}

/// 网格适合度引擎：纯函数，输入日线与品种信息，输出评分与理由。
/// 所有分项都可解释：界面上展示的每一项数字都能在这里复算。
enum GridSuitabilityEngine {

    // MARK: - 代码类型判定

    /// 是否可交易的场内代码（6 位数字，且带交易所基金/证券前缀特征）。
    /// 指数代码（sh000001 / usIXIC 等）不可交易，不参与评估。
    static func isTradableCode(_ code: String) -> Bool {
        // 用 ASCII 字节检查，避免全角数字等 Unicode 数字被误认为行情代码。
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    /// 是否 ETF 代码（沪市 51/56/58、深市 15/16/18/159 开头等）。
    /// 与 GridEngine.isGridETF 同一套口径：网格工具面向场内基金。
    static func isETFCode(_ code: String) -> Bool {
        let digits = code.lowercased().replacingOccurrences(of: "^(sh|sz|bj)", with: "", options: .regularExpression)
        return digits.range(of: "^(51|56|58|159|150|16|18)|^(15|16|18)\\d{4}$", options: .regularExpression) != nil
    }

    // MARK: - 指标计算

    struct Metrics {
        let annualVolatilityPercent: Double?
        let avgDailyAmplitudePercent: Double?
        let avgTurnoverYi: Double?
        let rangeBoundRatio: Double?
        let atExtreme: Bool
    }

    /// 从日线（按日期升序）计算网格相关指标。样本不足的项返回 nil，不外推。
    static func metrics(of bars: [DailyBar]) -> Metrics {
        let source = Array(bars.suffix(640))
        guard source.count >= 2 else {
            return Metrics(annualVolatilityPercent: nil, avgDailyAmplitudePercent: nil,
                           avgTurnoverYi: nil, rangeBoundRatio: nil, atExtreme: false)
        }
        // 年化波动率：近 250 日（不足取全部）日收益率标准差 × √252。
        let volWindow = Array(source.suffix(251))
        var returns: [Double] = []
        returns.reserveCapacity(volWindow.count - 1)
        for index in 1..<volWindow.count {
            let previous = volWindow[index - 1].close
            guard previous > 0, volWindow[index].close > 0 else { continue }
            returns.append(volWindow[index].close / previous - 1)
        }
        var annualVolatilityPercent: Double?
        if returns.count >= 20 {
            let mean = returns.reduce(0, +) / Double(returns.count)
            let variance = returns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(returns.count)
            annualVolatilityPercent = variance.squareRoot() * (252.0).squareRoot() * 100
        }
        // 日均振幅：近 60 日 (high-low)/前收。用前收做基准，与行情软件口径一致。
        let ampWindow = Array(source.suffix(61))
        var amplitudes: [Double] = []
        for index in 1..<ampWindow.count {
            let previousClose = ampWindow[index - 1].close
            guard previousClose > 0 else { continue }
            amplitudes.append((ampWindow[index].high - ampWindow[index].low) / previousClose)
        }
        let avgDailyAmplitudePercent = amplitudes.isEmpty ? nil : amplitudes.reduce(0, +) / Double(amplitudes.count) * 100
        // 日均成交额：近 20 日。腾讯日 K 成交量单位为「手」，1 手 = 100 份；
        // 成交额 ≈ 量 × 100 × 收盘价（以收盘价近似均价，只用于数量级判断）。
        let turnoverWindow = Array(source.suffix(20))
        let turnovers = turnoverWindow.compactMap { bar -> Double? in
            guard bar.volume > 0, bar.close > 0 else { return nil }
            return bar.volume * 100 * bar.close
        }
        let avgTurnoverYi = turnovers.isEmpty ? nil : turnovers.reduce(0, +) / Double(turnovers.count) / 100_000_000
        // 震荡性：近 60 日收盘价落在 MA20 ±5% 内的天数占比。
        let boundWindow = Array(source.suffix(60))
        var boundCount = 0, boundTotal = 0
        if boundWindow.count >= 21 {
            for index in 20..<boundWindow.count {
                let ma20 = boundWindow[index - 20..<index].reduce(0) { $0 + $1.close } / 20
                guard ma20 > 0 else { continue }
                boundTotal += 1
                if abs(boundWindow[index].close / ma20 - 1) <= 0.05 { boundCount += 1 }
            }
        }
        let rangeBoundRatio = boundTotal >= 20 ? Double(boundCount) / Double(boundTotal) : nil
        // 单边极端：最新价处于近 60 日最高/最低 1% 范围内。
        var atExtreme = false
        if boundWindow.count >= 20, let last = boundWindow.last {
            let high = boundWindow.map(\.high).max() ?? last.close
            let low = boundWindow.map(\.low).min() ?? last.close
            if last.close >= high * 0.99 || (low > 0 && last.close <= low * 1.01) { atExtreme = true }
        }
        return Metrics(annualVolatilityPercent: annualVolatilityPercent,
                       avgDailyAmplitudePercent: avgDailyAmplitudePercent,
                       avgTurnoverYi: avgTurnoverYi,
                       rangeBoundRatio: rangeBoundRatio, atExtreme: atExtreme)
    }

    // MARK: - 评分

    /// 流动性得分（30 分）：日均成交额 ≥1 亿满分，0.3 亿及格线，低于 0.3 亿快速衰减。
    static func liquidityScore(turnoverYi: Double?) -> Double {
        guard let t = turnoverYi, t.isFinite, t > 0 else { return 0 }
        if t >= 1 { return 30 }
        if t >= 0.3 { return 12 + (t - 0.3) / 0.7 * 18 }
        return t / 0.3 * 12
    }

    /// 波动率得分（30 分）：年化 15%–30% 满分；5%–15% 线性上升；30%–60% 线性衰减。
    static func volatilityScore(annualPercent: Double?) -> Double {
        guard let v = annualPercent, v.isFinite, v > 0 else { return 0 }
        if v >= 15, v <= 30 { return 30 }
        if v >= 5 { return (v - 5) / 10 * 30 }
        if v <= 60 { return (60 - v) / 30 * 30 }
        return 0
    }

    /// 日均振幅得分（20 分）：0.5%–2% 满分；低于 0.5% 收益有限；高于 2% 破网风险升。
    static func amplitudeScore(avgPercent: Double?) -> Double {
        guard let a = avgPercent, a.isFinite, a >= 0 else { return 0 }
        if a >= 0.5, a <= 2 { return 20 }
        if a < 0.5 { return max(0, (a - 0.1) / 0.4 * 12) }
        return max(0, (4 - a) / 2 * 20)
    }

    /// 震荡性得分（20 分）：收盘贴近 MA20 的天数占比；处于 60 日极端时扣分。
    static func rangeBoundScore(ratio: Double?, atExtreme: Bool) -> Double {
        guard let r = ratio, r.isFinite else { return 0 }
        let base = max(0, min(1, r)) * 20
        return atExtreme ? max(0, base - 10) : base
    }

    /// 综合评估。bars 为本地日线（升序）；latestPrice 仅作展示兜底。
    static func evaluate(code: String, name: String, bars: [DailyBar],
                         isOnExchange: Bool, latestPrice: Double?) -> GridSuitability {
        let m = metrics(of: bars)
        var reasons: [String] = []
        var warnings: [String] = []
        var score = liquidityScore(turnoverYi: m.avgTurnoverYi)
            + volatilityScore(annualPercent: m.annualVolatilityPercent)
            + amplitudeScore(avgPercent: m.avgDailyAmplitudePercent)
            + rangeBoundScore(ratio: m.rangeBoundRatio, atExtreme: m.atExtreme)
        score = max(0, min(100, score))

        // 理由与警告（可解释：每个判断都对应上面的分项）。
        if let t = m.avgTurnoverYi {
            if t >= 1 { reasons.append("日均成交额 \(String(format: "%.2f", t)) 亿，流动性充足") }
            else if t >= 0.3 { reasons.append("日均成交额 \(String(format: "%.2f", t)) 亿，流动性尚可") }
            else { warnings.append("日均成交额仅 \(String(format: "%.2f", t)) 亿，流动性不足，委托可能难成交或滑点大") }
        }
        if let v = m.annualVolatilityPercent {
            if v >= 15, v <= 30 { reasons.append("年化波动率 \(String(format: "%.1f", v))%，处于 15%–30% 的理想区间") }
            else if v < 15 { warnings.append("年化波动率仅 \(String(format: "%.1f", v))%，波动偏小，网格触发机会少") }
            else { warnings.append("年化波动率 \(String(format: "%.1f", v))% 偏高，价格容易击穿网格区间") }
        }
        if let a = m.avgDailyAmplitudePercent {
            if a >= 0.5, a <= 2 { reasons.append("日均振幅 \(String(format: "%.2f", a))%，网格有足够的日内空间") }
            else if a < 0.5 { warnings.append("日均振幅仅 \(String(format: "%.2f", a))%，扣完费用后网格收益有限") }
            else { warnings.append("日均振幅 \(String(format: "%.2f", a))% 偏大，需要更宽的资金规划防破网") }
        }
        if let r = m.rangeBoundRatio {
            if r >= 0.7 { reasons.append("近 60 日有 \(Int((r * 100).rounded()))% 的交易日收盘贴近 MA20，走势偏震荡，适合网格") }
            else if r < 0.4 { warnings.append("近 60 日仅 \(Int((r * 100).rounded()))% 的交易日收盘贴近 MA20，单边特征明显，网格容易卖飞或套牢") }
        }
        if m.atExtreme { warnings.append("最新价处于近 60 日最高/最低附近，单边行情风险高，破网概率大") }

        let isETF = isETFCode(code)
        if !isOnExchange {
            warnings.append("场外基金：申购赎回费用高、到账慢，不适合网格交易；网格请选场内 ETF")
        } else if !isETF {
            warnings.append("个股价格受单一公司事件影响，不可预测性高于指数；网格更适合宽基或行业 ETF")
        }

        // 分级：分数门槛 + 硬性否决（场外 / 数据不足 → 不适合）。
        var grade: GridSuitability.Grade
        if !isOnExchange { grade = .avoid }
        else if bars.count < 60 {
            grade = .avoid
            warnings.append("本地日线只有 \(bars.count) 个交易日（至少需要 60 个），无法可靠评估；点「补日线」后重评")
        }
        else if score >= 75 { grade = .suitable }
        else if score >= 50 { grade = .consider }
        else { grade = .avoid }
        // 个股再适合也只到「可考虑」。
        if grade == .suitable, isOnExchange, !isETF { grade = .consider }
        if !isOnExchange { score = min(score, 20) }

        return GridSuitability(code: code, name: name.isEmpty ? code : name, barCount: bars.count,
            score: Int(score.rounded()), grade: grade,
            annualVolatilityPercent: m.annualVolatilityPercent,
            avgDailyAmplitudePercent: m.avgDailyAmplitudePercent,
            avgTurnoverYi: m.avgTurnoverYi, rangeBoundRatio: m.rangeBoundRatio,
            atExtreme: m.atExtreme, isOnExchange: isOnExchange, isETF: isETF,
            reasons: reasons, warnings: warnings)
    }
}
