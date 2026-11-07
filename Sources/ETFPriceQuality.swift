import Foundation

// MARK: - ETF 价格质量与数据有效性闸门
//
// 治理对应：策略仲裁第 1 优先级「真实数据有效性」。
//
// 职责边界：
//   · 只回答一件事——「现在这份数据够不够格支撑一个精确数字」。
//   · 不预测涨跌、不产生买卖建议、不进入任何评分体系。
//   · 输出是三级闸门（可用 / 降级 / 阻断）+ 具体缺口清单，供上层仲裁与界面标注。
//
// 为什么需要它：ETF 的「价格」不止一个来源（成交价、IOPV、境外指数、汇率），
// 任何一环过期或缺失，「精确估值 / 精确耐心限价」就是假精确。宁可给区间，不给假数字化。

/// 数据闸门三级。命名刻意避开字母评级体系。
enum PriceDataVerdict: String, Equatable, Sendable {
    /// 数据齐备且新鲜：可以给精确价与精确折溢价。
    case usable
    /// 有可解释的缺口：只给区间/带标注的数字，不得宣称精确。
    case degraded
    /// 关键数据不可信：禁止生成任何精确估值或执行价。
    case blocked

    var title: String {
        switch self {
        case .usable: return "数据可用"
        case .degraded: return "数据降级"
        case .blocked: return "数据阻断"
        }
    }
}

/// 具体缺口项。每一项都明确写清「是否阻断精确限价」，避免上层各判各的。
enum PriceDataIssue: String, Equatable, CaseIterable, Sendable {
    case priceMissing
    case priceInvalid
    case quoteStale
    case sourceUntrusted
    case manualOverride
    case iopvMissing
    case iopvStale
    case premiumWide
    case premiumExtreme
    case spreadWide
    case spreadExtreme
    case lowLiquidity
    case crossBorderLag
    case fxUnknown
    case overseasClosed

    var title: String {
        switch self {
        case .priceMissing: return "缺少价格"
        case .priceInvalid: return "价格非法"
        case .quoteStale: return "报价过期"
        case .sourceUntrusted: return "来源不可核验"
        case .manualOverride: return "手动覆盖价"
        case .iopvMissing: return "缺少 IOPV"
        case .iopvStale: return "IOPV 过期"
        case .premiumWide: return "折溢价偏宽"
        case .premiumExtreme: return "折溢价极端"
        case .spreadWide: return "买卖价差偏宽"
        case .spreadExtreme: return "买卖价差极端"
        case .lowLiquidity: return "流动性不足"
        case .crossBorderLag: return "跨境时差"
        case .fxUnknown: return "汇率未知"
        case .overseasClosed: return "境外休市"
        }
    }

    /// 是否直接阻断「精确限价/精确估值」。
    ///
    /// 判断依据只有一条：这个缺口会不会让价格本身失去意义。
    /// 折溢价偏宽、流动性不足不影响「价格是多少」，只影响「能不能精确折溢价」，
    /// 所以它们不阻断限价，只降级。
    var blocksExactPrice: Bool {
        switch self {
        case .priceMissing, .priceInvalid, .quoteStale, .sourceUntrusted, .manualOverride:
            return true
        case .premiumExtreme, .spreadExtreme, .overseasClosed, .fxUnknown:
            return true
        case .iopvMissing, .iopvStale, .premiumWide, .spreadWide, .lowLiquidity, .crossBorderLag:
            return false
        }
    }

    /// 是否影响「折溢价/净值」这一读数（与限价是两件事）。
    var blocksPremiumReading: Bool {
        switch self {
        case .iopvMissing, .iopvStale, .overseasClosed, .fxUnknown, .premiumExtreme:
            return true
        default:
            return false
        }
    }
}

/// 评估输入。刻意用扁平结构：所有字段来自已有行情/持仓，不引入新数据源。
struct ETFPriceInput: Equatable {
    var code: String
    var price: Double?
    var quoteAt: Date?
    var fetchedAt: Date?
    var source: String?
    var iopv: Double?
    var iopvAt: Date?
    var bid: Double?
    var ask: Double?
    /// 成交额（元）。用于判断流动性够不够支撑一笔耐心限价。
    var turnover: Double?
    var isCrossBorder: Bool = false
    var fxRateKnown: Bool = true
    /// 境外市场是否开市；nil = 未知。
    var overseasOpen: Bool? = nil
    var session: MarketSessionStatus
    var customHolidays: [String] = []

    init(code: String, price: Double?, quoteAt: Date? = nil, fetchedAt: Date? = nil,
         source: String? = nil, iopv: Double? = nil, iopvAt: Date? = nil,
         bid: Double? = nil, ask: Double? = nil, turnover: Double? = nil,
         isCrossBorder: Bool = false, fxRateKnown: Bool = true, overseasOpen: Bool? = nil,
         session: MarketSessionStatus, customHolidays: [String] = []) {
        self.code = code
        self.price = price
        self.quoteAt = quoteAt
        self.fetchedAt = fetchedAt
        self.source = source
        self.iopv = iopv
        self.iopvAt = iopvAt
        self.bid = bid
        self.ask = ask
        self.turnover = turnover
        self.isCrossBorder = isCrossBorder
        self.fxRateKnown = fxRateKnown
        self.overseasOpen = overseasOpen
        self.session = session
        self.customHolidays = customHolidays
    }
}

/// 评估结果。
struct ETFPriceQuality: Equatable {
    let code: String
    let verdict: PriceDataVerdict
    let issues: [PriceDataIssue]
    /// 折溢价百分数（正=溢价，负=折价）；无 IOPV 时为 nil，绝不填 0。
    let premiumPercent: Double?
    /// 买卖价差百分数（相对中间价）。
    let spreadPercent: Double?
    let quoteAge: TimeInterval?
    let iopvAge: TimeInterval?
    /// 人话说明，逐条可读。
    let notes: [String]
    /// 降级时给出的价格容差（百分数），用于「给区间不给假精确」。
    let priceBandPercent: Double

    var allowsExactPrice: Bool { verdict == .usable }
    var allowsExactLimitPrice: Bool { verdict != .blocked }
    var allowsPremiumReading: Bool { !issues.contains { $0.blocksPremiumReading } }
    var blockingIssues: [PriceDataIssue] { issues.filter { $0.blocksExactPrice } }
    var issueTitles: [String] { issues.map(\.title) }
}

// MARK: - 引擎

enum ETFPriceQualityEngine {
    /// 常规 ETF 折溢价警戒/阻断线（百分数）。
    static let premiumWarnPercent: Double = 1.0
    static let premiumBlockPercent: Double = 3.0
    /// 跨境 ETF 折溢价天然更宽（时差 + 汇率 + 境外未开市），阈值放宽但要标注。
    static let crossBorderPremiumWarnPercent: Double = 1.5
    static let crossBorderPremiumBlockPercent: Double = 4.5
    /// 买卖价差（相对中间价，百分数）。
    static let spreadWarnPercent: Double = 0.30
    static let spreadBlockPercent: Double = 0.80
    /// 低于这个成交额（元）视为流动性不足，只能给区间。
    static let minimumTurnover: Double = 5_000_000
    /// IOPV 盘中容忍年龄（秒）。超过就认为折溢价读数不可信。
    static let iopvMaxAge: TimeInterval = 90

    static func evaluate(_ input: ETFPriceInput, now: Date = Date()) -> ETFPriceQuality {
        var issues: [PriceDataIssue] = []
        var notes: [String] = []

        // ① 价格本身：没有合法价格，后面全部不成立。
        guard let price = input.price, price.isFinite, price > 0 else {
            let issue: PriceDataIssue = (input.price == nil) ? .priceMissing : .priceInvalid
            return ETFPriceQuality(code: input.code, verdict: .blocked, issues: [issue],
                                   premiumPercent: nil, spreadPercent: nil,
                                   quoteAge: nil, iopvAge: nil,
                                   notes: [issue == .priceMissing ? "没有可用价格，估值与限价均不成立" : "价格非法（非正数或非有限数），估值与限价均不成立"],
                                   priceBandPercent: 0)
        }

        // ② 报价新鲜度与来源可信度（复用全 App 同一套口径，非交易时段按最近交易日判）。
        let temporal = QuoteTemporal(quoteTimestamp: input.quoteAt,
                                     fetchedAt: input.fetchedAt,
                                     source: input.source,
                                     session: input.session)
        let freshness = temporal.freshness(at: now, custom: input.customHolidays)

        var quoteAge: TimeInterval? = nil
        if let quoteAt = input.quoteAt {
            let age = now.timeIntervalSince(quoteAt)
            quoteAge = age.isFinite ? age : nil
        }

        switch freshness {
        case .fresh:
            break
        case .stale:
            issues.append(.quoteStale)
            notes.append("报价已过期（时段：\(input.session.title)），不能当作实时价使用")
        case .unverified:
            issues.append(.sourceUntrusted)
            notes.append("报价来源不可核验，不能当作交易所实时价")
        }

        if QuoteSourceTrust.isManual(input.source) {
            issues.append(.manualOverride)
            notes.append("这是手动覆盖价，不是行情，禁止用于自动估值")
        }

        // ③ IOPV 与折溢价。
        var premiumPercent: Double? = nil
        var iopvAge: TimeInterval? = nil

        if let iopv = input.iopv, iopv.isFinite, iopv > 0 {
            premiumPercent = (price - iopv) / iopv * 100

            if let iopvAt = input.iopvAt {
                let age = now.timeIntervalSince(iopvAt)
                iopvAge = age.isFinite ? age : nil
                if let age = iopvAge, age > iopvMaxAge, input.session == .continuous {
                    issues.append(.iopvStale)
                    notes.append("IOPV 已 \(Int(age / 60)) 分钟未更新，折溢价读数不可信")
                }
            }

            if let premium = premiumPercent {
                let warn = input.isCrossBorder ? crossBorderPremiumWarnPercent : premiumWarnPercent
                let block = input.isCrossBorder ? crossBorderPremiumBlockPercent : premiumBlockPercent
                let magnitude = abs(premium)
                if magnitude >= block {
                    issues.append(.premiumExtreme)
                    notes.append("折溢价 \(String(format: "%.2f", premium))%，超出 \(String(format: "%.1f", block))% 阻断线，价格与净值严重脱节")
                } else if magnitude >= warn {
                    issues.append(.premiumWide)
                    notes.append("折溢价 \(String(format: "%.2f", premium))%，偏宽（警戒 \(String(format: "%.1f", warn))%）")
                }
            }
        } else {
            issues.append(.iopvMissing)
            notes.append("没有 IOPV，无法计算折溢价；可以看价格，但不能声称「贵/便宜」")
        }

        // ④ 买卖价差。
        var spreadPercent: Double? = nil
        if let bid = input.bid, let ask = input.ask,
           bid.isFinite, ask.isFinite, bid > 0, ask > 0, ask >= bid {
            let mid = (bid + ask) / 2
            if mid > 0 {
                let spread = (ask - bid) / mid * 100
                spreadPercent = spread
                if spread >= spreadBlockPercent {
                    issues.append(.spreadExtreme)
                    notes.append("买卖价差 \(String(format: "%.2f", spread))%，盘口太薄，限价可能无法成交")
                } else if spread >= spreadWarnPercent {
                    issues.append(.spreadWide)
                    notes.append("买卖价差 \(String(format: "%.2f", spread))%，偏宽")
                }
            }
        }

        // ⑤ 流动性。
        if let turnover = input.turnover, turnover.isFinite, turnover >= 0, turnover < minimumTurnover {
            issues.append(.lowLiquidity)
            notes.append("成交额 \(Int(turnover / 10_000)) 万元，低于 \(Int(minimumTurnover / 10_000)) 万元，耐心限价的成交概率偏低")
        }

        // ⑥ 跨境特有风险。
        if input.isCrossBorder {
            issues.append(.crossBorderLag)
            notes.append("跨境 ETF：存在境内外时差，折溢价与 IOPV 天然滞后")

            if !input.fxRateKnown {
                issues.append(.fxUnknown)
                notes.append("汇率未知，无法折算净值")
            }
            if let open = input.overseasOpen, open == false {
                issues.append(.overseasClosed)
                notes.append("境外市场休市，IOPV 冻结，折溢价无意义")
            } else if input.overseasOpen == nil {
                notes.append("境外是否开市未知，谨慎解读折溢价")
            }
        }

        // ⑦ 结论。
        let blocked = issues.contains { $0.blocksExactPrice }
        let verdict: PriceDataVerdict = blocked ? .blocked : (issues.isEmpty ? .usable : .degraded)
        let band: Double = verdict == .blocked ? 0 : (verdict == .degraded ? 0.5 : 0)

        if issues.isEmpty {
            notes.append("数据齐备：报价新鲜、来源可核验、折溢价在合理区间")
        }

        return ETFPriceQuality(code: input.code, verdict: verdict, issues: issues,
                               premiumPercent: premiumPercent, spreadPercent: spreadPercent,
                               quoteAge: quoteAge, iopvAge: iopvAge,
                               notes: notes, priceBandPercent: band)
    }
}
