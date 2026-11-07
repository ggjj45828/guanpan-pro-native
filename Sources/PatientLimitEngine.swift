import Foundation

// MARK: - ATR（真实波幅）
//
// 分级：计算定义 + 证据。ATR 只描述「这只标的近期一天通常走多少」，
// 用来决定挂单该退多远，**不是**买卖信号，也不预测方向。
//
// 两种口径：
// - wilder：Wilder 原始定义（先取前 period 个 TR 的均值，之后递推平滑）。默认。
// - simple：最近 period 个 TR 的算术平均。旧版「中长期网格」用的是这个近似，
//   保留它只为让那个页面的数字不因本次抽取而变化。
enum ATRMethod: String, Equatable, Sendable {
    case wilder
    case simple

    var title: String {
        switch self {
        case .wilder: return "Wilder 平滑"
        case .simple: return "简单平均"
        }
    }
}

struct ATRResult: Equatable, Sendable {
    /// ATR 绝对值（价格单位）。
    let value: Double
    /// ATR 占参考价的百分比。
    let percent: Double
    let period: Int
    let method: ATRMethod
    /// 实际参与计算的真实波幅个数（第一根没有前收，算不出 TR）。
    let trueRangeSamples: Int
    /// 最后一根是否还没收盘。未收盘时当日波幅可能继续扩大。
    let lastBarForming: Bool
    let notes: [String]
}

enum ATREngine {
    /// 真实波幅序列：max(高−低, |高−前收|, |低−前收|)。第一根缺前收，丢弃。
    static func trueRanges(_ bars: [DailyBar]) -> [Double] {
        guard bars.count > 1 else { return [] }
        var out: [Double] = []
        out.reserveCapacity(bars.count - 1)
        for index in 1..<bars.count {
            let bar = bars[index]
            let previousClose = bars[index - 1].close
            guard bar.high.isFinite, bar.low.isFinite, previousClose.isFinite,
                  bar.high > 0, bar.low > 0, previousClose > 0 else { continue }
            let range = bar.high - bar.low
            let upGap = abs(bar.high - previousClose)
            let downGap = abs(bar.low - previousClose)
            out.append(max(range, max(upGap, downGap)))
        }
        return out
    }

    /// 样本不足返回 nil——不拿半个月的波动冒充 14 日 ATR。
    static func calculate(bars: [DailyBar],
                          referencePrice: Double?,
                          period: Int = 14,
                          method: ATRMethod = .wilder,
                          lastBarForming: Bool = false) -> ATRResult? {
        let span = max(2, min(200, period))
        let ranges = trueRanges(bars)
        guard ranges.count >= span else { return nil }

        let value: Double
        switch method {
        case .simple:
            let window = Array(ranges.suffix(span))
            value = window.reduce(0, +) / Double(window.count)
        case .wilder:
            let seed = Array(ranges.prefix(span))
            var accumulator = seed.reduce(0, +) / Double(seed.count)
            if ranges.count > span {
                for index in span..<ranges.count {
                    accumulator = (accumulator * Double(span - 1) + ranges[index]) / Double(span)
                }
            }
            value = accumulator
        }
        guard value.isFinite, value > 0 else { return nil }

        var reference: Double = 0
        if let candidate = referencePrice, candidate.isFinite, candidate > 0 {
            reference = candidate
        } else if let last = bars.last, last.close.isFinite, last.close > 0 {
            reference = last.close
        }
        guard reference > 0 else { return nil }

        var notes: [String] = []
        if lastBarForming { notes.append("最后一根日线未收盘，当日真实波幅可能继续扩大") }
        if ranges.count < span * 2 { notes.append("真实波幅样本偏少（\(ranges.count) 个），ATR 只作参考") }

        return ATRResult(value: value,
                         percent: value / reference * 100,
                         period: span,
                         method: method,
                         trueRangeSamples: ranges.count,
                         lastBarForming: lastBarForming,
                         notes: notes)
    }
}

// MARK: - 耐心限价
//
// 设计原则（与治理一致）：
// 1. 先看数据能不能信。价格质量被阻断时，**一个精确价都不给**——不给假精确。
// 2. 挂单价由 ATR 决定退让幅度，不从「目标价」倒推。退让越深，价格越好、成交越难。
// 3. 数量受组合风险预算约束（RiskBudgetEngine.maxDeployable），整手向下取整；
//    额度不足一手就说不足，不凑单。
// 4. 「近 N 日有几次盘中触及该价」是可数的历史事实，用它替代编造的成交概率。
// 5. 挂单不保证成交；跌破失效价说明前提破了，撤单而不是接飞刀。
enum LimitStyle: String, CaseIterable, Equatable, Sendable {
    /// 只挂深度回踩，宁愿不成交。
    case patient
    /// 标准：以 1×ATR 回踩为主。
    case balanced
    /// 积极：接受浅回踩，换成交概率。
    case eager

    var title: String {
        switch self {
        case .patient: return "耐心（等深回踩）"
        case .balanced: return "均衡（标准回踩）"
        case .eager: return "积极（浅回踩）"
        }
    }

    /// 推荐档位在三档里的序号（0 最浅、2 最深）。
    var preferredBandIndex: Int {
        switch self {
        case .eager: return 0
        case .balanced: return 1
        case .patient: return 2
        }
    }
}

/// 入参含 `[DailyBar]`，而 `DailyBar` 未实现 `Equatable`/`Sendable`，
/// 所以这里不声明这两个协议——不要为了「看着整齐」加上去，会编译不过。
struct PatientLimitInput {
    let code: String
    /// 现价（来自行情）。拿不到就只能退回最近收盘，并在结论里说明。
    let price: Double?
    let bars: [DailyBar]
    /// 价格质量闸门结果。为 nil 表示没算过——按「未验证」处理，不给精确价。
    let priceQuality: ETFPriceQuality?
    /// 组合层面「这只还能加多少钱」。nil 或 ≤0 表示没有额度。
    let deployableAmount: Double?
    let ownedShares: Double
    let lotSize: Int
    let style: LimitStyle
    /// 挂单有效期（交易日）。
    let validityDays: Int
    /// 最后一根日线是否还没收盘。
    let lastBarForming: Bool

    init(code: String,
         price: Double?,
         bars: [DailyBar],
         priceQuality: ETFPriceQuality?,
         deployableAmount: Double?,
         ownedShares: Double,
         lotSize: Int = 100,
         style: LimitStyle = .balanced,
         validityDays: Int = 5,
         lastBarForming: Bool = false) {
        self.code = code
        self.price = price
        self.bars = bars
        self.priceQuality = priceQuality
        self.deployableAmount = deployableAmount
        self.ownedShares = ownedShares
        self.lotSize = lotSize
        self.style = style
        self.validityDays = validityDays
        self.lastBarForming = lastBarForming
    }
}

struct PatientLimitBand: Identifiable, Equatable, Sendable {
    /// shallow / standard / deep
    let id: String
    let title: String
    let price: Double
    /// 相对参考价的折价幅度（正数表示低于参考价）。
    let discountPercent: Double
    /// 退让了多少个 ATR。
    let atrMultiple: Double
    let shares: Int
    let amount: Double
    /// 近 lookback 个交易日里，最低价触及过该价位的天数。
    let touchCount: Int
    let lookback: Int
    let note: String?

    var isAffordable: Bool { shares > 0 }
}

struct PatientLimitPlan: Equatable, Sendable {
    let code: String
    /// 是否允许给出精确（单一）挂单价。数据降级/阻断时为 false，只给区间。
    let allowsExactPrice: Bool
    let referencePrice: Double?
    /// 参考价来源说明：「现价」/「最近收盘（无有效现价）」。
    let referenceSource: String
    let atr: ATRResult?
    /// true 表示 ATR 不可用，用了缺省 2% 波动估算。
    let atrAssumed: Bool
    let style: LimitStyle
    let bands: [PatientLimitBand]
    let recommendedBandID: String?
    /// 收盘跌破此价则原判断失效，应撤单。
    let invalidationPrice: Double?
    let validityDays: Int
    let deployableAmount: Double
    let blocked: Bool
    let blockedReasons: [String]
    let notes: [String]

    /// 三档合起来打算买多少。
    var totalShares: Int { bands.reduce(0) { $0 + $1.shares } }
    var totalAmount: Double { bands.reduce(0) { $0 + $1.amount } }
}

enum PatientLimitEngine {
    /// 三档退让幅度（ATR 倍数）：浅回踩 / 标准耐心 / 深度耐心。
    static let bandMultipliers: [Double] = [0.5, 1.0, 1.5]
    /// 额度分配：越深越重，浅档最轻。
    static let bandWeights: [Double] = [0.30, 0.35, 0.35]
    /// 触及统计回看天数。
    static let touchLookback = 60
    /// ATR 缺失时的缺省日波动（2%）。
    static let assumedAtrPercent = 2.0
    /// 失效价 = 参考价 − 2.5×ATR。
    static let invalidationMultiplier = 2.5

    static func plan(_ input: PatientLimitInput) -> PatientLimitPlan {
        let lot = max(1, input.lotSize)
        var blockedReasons: [String] = []
        var notes: [String] = []

        // 第 1 关：数据有效性。阻断就不给精确价。
        let quality = input.priceQuality
        let verdict = quality?.verdict ?? .degraded
        if verdict == .blocked {
            blockedReasons.append("价格数据被阻断（\(quality?.notes.first ?? "无有效价格或关键数据过期")），不给挂单价")
        } else if verdict == .degraded {
            notes.append("价格数据降级：\(quality?.notes.first ?? "存在数据缺口")。只给区间，不宣称精确价")
        }

        // 参考价：现价优先，其次最近收盘。
        var reference: Double = 0
        var referenceSource = "现价"
        if let candidate = input.price, candidate.isFinite, candidate > 0 {
            reference = candidate
        } else if let last = input.bars.last, last.close.isFinite, last.close > 0 {
            reference = last.close
            referenceSource = "最近收盘（无有效现价）"
            notes.append("没有任何有效现价，只能以最近收盘作参考")
        } else {
            blockedReasons.append("既无现价也无历史收盘，无法定价")
        }

        // 第 2 关：组合风险预算。
        let deployable = max(0, input.deployableAmount ?? 0)
        if deployable <= 0 {
            blockedReasons.append("组合风险预算没有可加仓额度（现金下限或集中度已到顶）")
        }

        guard reference > 0 else {
            return PatientLimitPlan(code: input.code,
                                    allowsExactPrice: false,
                                    referencePrice: nil,
                                    referenceSource: "—",
                                    atr: nil,
                                    atrAssumed: false,
                                    style: input.style,
                                    bands: [],
                                    recommendedBandID: nil,
                                    invalidationPrice: nil,
                                    validityDays: input.validityDays,
                                    deployableAmount: deployable,
                                    blocked: true,
                                    blockedReasons: blockedReasons,
                                    notes: notes)
        }

        // 第 3 关：波动幅度。ATR 不可用就退到缺省 2%，并明确标注是假设。
        let measured = ATREngine.calculate(bars: input.bars,
                                           referencePrice: reference,
                                           period: 14,
                                           method: .wilder,
                                           lastBarForming: input.lastBarForming)
        let atrAssumed = measured == nil
        let atrValue: Double
        if let measured {
            atrValue = measured.value
            notes.append(contentsOf: measured.notes)
        } else {
            atrValue = reference * assumedAtrPercent / 100
            notes.append("日线不足 15 根，算不出 14 日 ATR；按缺省 \(assumedAtrPercent.numText(1))% 日波动估算，不是实测值")
        }

        let blocked = !blockedReasons.isEmpty
        let allowsExact = verdict == .usable && !blocked

        // 第 4 关：三档价位与数量。
        var bands: [PatientLimitBand] = []
        let bandTitles = ["浅回踩", "标准耐心", "深度耐心"]
        let bandIDs = ["shallow", "standard", "deep"]
        for index in bandMultipliers.indices {
            let multiple = bandMultipliers[index]
            let price = reference - atrValue * multiple
            guard price.isFinite, price > 0 else { continue }
            let budget = deployable * bandWeights[index]
            let shares: Int
            var note: String? = nil
            if budget <= 0 {
                shares = 0
                note = "无额度"
            } else {
                let rawLots = budget / (price * Double(lot))
                let lots = rawLots.isFinite ? Int(max(0, min(1_000_000.0, floor(rawLots)))) : 0
                shares = lots * lot
                if shares == 0 {
                    note = "该档预算 \(budget.cnyText()) 不足一手（约 \((price * Double(lot)).cnyText())）"
                }
            }
            let window = Array(input.bars.suffix(touchLookback))
            let touches = window.filter { $0.low.isFinite && $0.low > 0 && $0.low <= price }.count
            bands.append(PatientLimitBand(id: bandIDs[index],
                                          title: bandTitles[index],
                                          price: price,
                                          discountPercent: (reference - price) / reference * 100,
                                          atrMultiple: multiple,
                                          shares: shares,
                                          amount: Double(shares) * price,
                                          touchCount: touches,
                                          lookback: window.count,
                                          note: note))
        }

        let preferredIndex = min(input.style.preferredBandIndex, max(0, bands.count - 1))
        let recommended = bands.isEmpty ? nil : bands[preferredIndex].id

        // 第 5 关：失效价。跌破说明「回踩」变成「破位」，前提不成立。
        let invalidationRaw = reference - atrValue * invalidationMultiplier
        let invalidation = invalidationRaw.isFinite && invalidationRaw > 0 ? invalidationRaw : nil

        if let quality, let premium = quality.premiumPercent, premium > 1 {
            notes.append("当前溢价 \(String(format: "%.2f", premium))%，溢价时挂单等于买贵，等回落或折价再挂更合理")
        }
        if let quality, quality.notes.contains(where: { $0.contains("成交额") }) {
            notes.append("成交额偏低，深档挂单可能长时间不成交")
        }
        if input.ownedShares > 0 {
            notes.append("已有持仓 \(Int(min(input.ownedShares, 1_000_000_000))) 份，本次只在额度内加仓")
        }
        notes.append("总投入不超过 \(min(deployable, bands.reduce(0) { $0 + $1.amount }).cnyText())，整手向下取整，余额留现金")

        return PatientLimitPlan(code: input.code,
                                allowsExactPrice: allowsExact,
                                referencePrice: reference,
                                referenceSource: referenceSource,
                                atr: measured,
                                atrAssumed: atrAssumed,
                                style: input.style,
                                bands: bands,
                                recommendedBandID: blocked ? nil : recommended,
                                invalidationPrice: invalidation,
                                validityDays: max(1, input.validityDays),
                                deployableAmount: deployable,
                                blocked: blocked,
                                blockedReasons: blockedReasons,
                                notes: notes)
    }
}

// MARK: - 引擎内部用的极简数字转文字
//
// 引擎不依赖 SwiftUI，也不该依赖视图层的格式化扩展，所以这里自带一个最小实现。
private extension Double {
    func numText(_ digits: Int) -> String {
        String(format: "%.\(digits)f", self)
    }

    func cnyText() -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return "¥" + (formatter.string(from: NSNumber(value: self)) ?? String(format: "%.0f", self))
    }
}
