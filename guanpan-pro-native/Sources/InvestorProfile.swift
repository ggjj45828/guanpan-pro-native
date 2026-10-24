import Foundation

// MARK: - 建议 → 反馈 → 成交：一条完整轨迹

/// AI 每给出一次具体机会，就落一条轨迹。画像学习只认这条轨迹 + 真实成交，
/// 不认虚拟交易、不认模拟账户——没有真实行为就不给结论。
enum NextSuggestionOutcome: String, Codable, Equatable {
    case pending = "待观察"
    case saved = "已存为候选计划"
    case executed = "已真实成交"
    case ignored = "看了没做"
    case rejected = "明确否掉"
}

/// 用户在 AI 建议卡上的一键反馈。故意做成六个粗选项：填问卷的人少，
/// 点一下的人多；画像宁可少学一点，也不要靠一次问卷就定型。
enum NextPlanFeedbackKind: String, Codable, CaseIterable, Identifiable, Equatable {
    case fitsMe = "这个机会适合我"
    case tooAggressive = "价格太激进"
    case spreadTooSmall = "价差太小"
    case riskTooHigh = "风险太高"
    case wantToHold = "我想继续持有"
    case notNow = "暂时不想交易"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .fitsMe: return "hand.thumbsup"
        case .tooAggressive: return "arrow.up.arrow.down"
        case .spreadTooSmall: return "arrow.left.and.right"
        case .riskTooHigh: return "exclamationmark.triangle"
        case .wantToHold: return "lock"
        case .notNow: return "clock"
        }
    }
    /// 负向反馈 → 画像据此抬高门槛；正向 → 可作为「这类机会是对的」的证据。
    var isPositive: Bool { self == .fitsMe }
    var impliesHoldPreference: Bool { self == .wantToHold || self == .notNow }
}

struct NextPlanFeedback: Codable, Equatable {
    var kind: NextPlanFeedbackKind
    var note: String? = nil
    var createdAt: Date
}

struct NextSuggestionRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let code: String
    let name: String
    let kind: NextPlanKind
    /// 生成时的预期：跨期比较的一致性依据，绝不回填、绝不修正。
    let expectedNetGain: Decimal?
    let expectedSpreadPercent: Double?
    let expectedCostReduction: Decimal?
    let confidenceLevel: String
    let marketState: String
    let createdAt: Date
    var expiresAt: Date
    var viewedAt: Date? = nil
    var savedPlanID: UUID? = nil
    var feedback: NextPlanFeedback? = nil
    var outcome: NextSuggestionOutcome = .pending
    var executedAt: Date? = nil
    var executedPrice: Decimal? = nil
    var executedUnits: Int? = nil
    var executedNetGain: Decimal? = nil
    /// 用户改过价格/份额 → 说明 AI 的建议阈值与他的偏好有偏差，是最强的学习信号。
    var priceEdited: Bool = false
    var unitsEdited: Bool = false

    var isTStyle: Bool { kind == .reverseT || kind == .forwardT }
}

// MARK: - 画像属性

/// 三类信息必须分开存：用户明确规则（AI 不能改）、AI 学习偏好（可随真实行为调整）、
/// 当前状态（临时，不沉淀成长期结论）。
enum NextProfileSource: String, Codable, Equatable {
    case explicit = "你明确设定"
    case learned = "AI 从真实行为学习"
    case temporary = "当前状态（不沉淀）"
}

enum NextProfileTraitID: String, Codable, CaseIterable, Identifiable, Equatable {
    // 长期计划
    case horizon
    case drawdown
    case singleAssetRisk
    case sectorRisk
    case overseasRisk
    case cashFlow
    // 交易习惯
    case tradeFrequency
    case limitPatience
    case tAppetite
    case minSpread
    case minNetGain
    case trample
    // 网格
    case gridAppetite
    case gridWidth
    case gridTiers
    // 现金与执行
    case cashPreference
    case style
    case execution

    var id: String { rawValue }

    var title: String {
        switch self {
        case .horizon: return "投资期限"
        case .drawdown: return "账户回撤承受"
        case .singleAssetRisk: return "单资产风险"
        case .sectorRisk: return "行业集中度"
        case .overseasRisk: return "海外波动承受"
        case .cashFlow: return "现金流压力"
        case .tradeFrequency: return "交易频率"
        case .limitPatience: return "限价耐心"
        case .tAppetite: return "做 T 偏好"
        case .minSpread: return "最低可做价差"
        case .minNetGain: return "最低预期净收益"
        case .trample: return "踏空容忍"
        case .gridAppetite: return "网格偏好"
        case .gridWidth: return "网格宽度"
        case .gridTiers: return "最大档数"
        case .cashPreference: return "现金偏好"
        case .style: return "投资风格"
        case .execution: return "交易执行方式"
        }
    }

    var symbol: String {
        switch self {
        case .horizon: return "calendar"
        case .drawdown: return "waveform.path.ecg"
        case .singleAssetRisk: return "square.stack.3d.up"
        case .sectorRisk: return "circle.grid.2x2"
        case .overseasRisk: return "globe.asia.australia"
        case .cashFlow: return "banknote"
        case .tradeFrequency: return "repeat"
        case .limitPatience: return "hourglass"
        case .tAppetite: return "arrow.left.arrow.right"
        case .minSpread: return "percent"
        case .minNetGain: return "yensign.circle"
        case .trample: return "figure.walk.motion"
        case .gridAppetite: return "square.grid.3x3"
        case .gridWidth: return "arrow.left.and.right.square"
        case .gridTiers: return "list.number"
        case .cashPreference: return "tray.full"
        case .style: return "tag"
        case .execution: return "hand.raised"
        }
    }

    var group: String {
        switch self {
        case .horizon, .drawdown, .singleAssetRisk, .sectorRisk, .overseasRisk, .cashFlow: return "长期计划与风险"
        case .tradeFrequency, .limitPatience, .tAppetite, .minSpread, .minNetGain, .trample: return "交易习惯"
        case .gridAppetite, .gridWidth, .gridTiers: return "网格习惯"
        case .cashPreference, .style, .execution: return "现金、风格与执行"
        }
    }
}

struct NextProfileOption: Codable, Equatable, Identifiable {
    var id: String { value }
    let value: String
    let label: String
    let detail: String
}

struct NextProfileTrait: Codable, Equatable, Identifiable {
    let id: NextProfileTraitID
    var value: String
    var label: String
    var detail: String
    /// 0…1。样本不足时必须是 0，界面显示「数据还不够」，不许编一个数字出来。
    var confidence: Double
    var sampleCount: Int
    var windowDays: Int
    var source: NextProfileSource
    /// 用户锁定后，学习引擎永远不再覆盖它。
    var locked: Bool
    var basis: [String]
    var updatedAt: Date
    /// 数值型画像（价差%、净收益、档数）直接参与计算，避免从文案里反解析。
    var numeric: Double? = nil
    /// 用户说过「这个判断不准确」→ 冷却到指定时间前不再学习这一项。
    var mutedUntil: Date? = nil

    var isKnown: Bool { confidence > 0 }
    var confidenceText: String {
        guard confidence > 0 else { return "数据还不够" }
        return "AI 置信度 \(Int((confidence * 100).rounded()))%"
    }
    var isMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date()
    }
}

struct NextProfileThresholds: Codable, Equatable {
    /// 只有预期价差 ≥ 这个值才值得打扰你（默认 0.4%，随真实执行上浮）。
    var minTSpreadPercent: Double = 0.4
    /// 只有预期净收益 ≥ 这个金额才值得做一次（扣完两笔手续费）。
    var minTNetGain: Double = 5
    /// 单次做 T 份额上限占可用份额比例。
    var maxTUnitsRatio: Double = 0.3
    var gridMaxTiers: Int = 4
    /// 网格最大资金占用占现金比例。
    var gridMaxCashRatio: Double = 0.5
    /// 最低现金储备（占总资产比例）。
    var cashFloorRatio: Double = 0.05
    /// 30 天内可接受的做 T 次数上限；超过后只提示、不主动推荐。
    var tTradeFrequencyCap: Int = 4
}

/// 长期核心仓 / 行业机动仓。同一套画像不能套到所有标的：
/// 核心仓允许波动、不因技术信号轻易卖；机动仓才可以做 T、网格、主动降本。
struct NextInstrumentRole: Codable, Equatable {
    enum Role: String, Codable, Equatable {
        case core = "长期核心仓"
        case tactical = "行业机动仓"
        case undecided = "未分类"
    }
    var role: Role = .undecided
    var source: NextProfileSource = .learned
    var locked = false
    var reason: String = ""
    var updatedAt = Date()
}

struct NextProfileLearningSummary: Codable, Equatable {
    var updatedAt = Date()
    var fillSampleCount = 0
    var suggestionSampleCount = 0
    var executedCount = 0
    var ignoredCount = 0
    var anomalyCount = 0
    var windowDays = 90
    var notes: [String] = []
}

// MARK: - 画像本体

struct NextInvestorProfile: Codable, Equatable {
    var version = 1
    var traits: [String: NextProfileTrait] = [:]
    var thresholds = NextProfileThresholds()
    var instrumentRoles: [String: NextInstrumentRole] = [:]
    var summary = NextProfileLearningSummary()
    var updatedAt = Date()

    func trait(_ id: NextProfileTraitID) -> NextProfileTrait? { traits[id.rawValue] }

    var knownTraits: [NextProfileTrait] {
        NextProfileTraitID.allCases.compactMap { traits[$0.rawValue] }
    }

    var styleTags: [String] {
        (traits[NextProfileTraitID.style.rawValue]?.label ?? "")
            .split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func role(for code: String) -> NextInstrumentRole {
        instrumentRoles[code] ?? NextInstrumentRole()
    }

    /// 画像只影响推荐优先级与门槛，不参与「有没有机会」的判断。
    mutating func setTrait(_ trait: NextProfileTrait) { traits[trait.id.rawValue] = trait }

    private enum CodingKeys: String, CodingKey { case version, traits, thresholds, instrumentRoles, summary, updatedAt }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        traits = try values.decodeIfPresent([String: NextProfileTrait].self, forKey: .traits) ?? [:]
        thresholds = try values.decodeIfPresent(NextProfileThresholds.self, forKey: .thresholds) ?? NextProfileThresholds()
        instrumentRoles = try values.decodeIfPresent([String: NextInstrumentRole].self, forKey: .instrumentRoles) ?? [:]
        summary = try values.decodeIfPresent(NextProfileLearningSummary.self, forKey: .summary) ?? NextProfileLearningSummary()
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// 每个属性的可选项与默认值。界面「修改」直接用这张表，不再各写一套。
enum NextProfileCatalog {
    static func options(for id: NextProfileTraitID) -> [NextProfileOption] {
        switch id {
        case .horizon:
            return [opt("short", "短期", "3 年内要用到这笔钱"),
                    opt("mid", "中期", "3–7 年"),
                    opt("long", "长期", "7–15 年，能忍受中途大幅回撤"),
                    opt("veryLong", "超长期", "15 年以上，只看长期复利")]
        case .drawdown:
            return riskOptions(labels: ("低", "中", "高"), details: ("回撤 10% 就会想减仓", "回撤 20% 左右仍能拿住", "回撤 30% 以上仍按计划执行"))
        case .singleAssetRisk, .sectorRisk, .overseasRisk:
            return riskOptions(labels: ("低", "中", "高"), details: ("单只/单一行业占比希望控制得比较小", "能接受中等集中度", "愿意为重仓承担更大波动"))
        case .cashFlow:
            return [opt("tight", "有压力", "近期需要用钱，仓位腾挪空间小"),
                    opt("ok", "正常", "短期内不需要动用投资资金"),
                    opt("ample", "宽裕", "还有持续新增资金可投")]
        case .tradeFrequency:
            return [opt("low", "低频择机", "一个月最多一两次，只做看得懂的机会"),
                    opt("normal", "正常", "一个月几次，机会合适就做"),
                    opt("high", "积极", "几乎每天都会看有没有可做的机会")]
        case .limitPatience:
            return [opt("patient", "耐心限价", "愿意挂单多日等目标价，不为成交调价"),
                    opt("normal", "正常", "能等一两天，价格偏离就重挂"),
                    opt("impatient", "要快成交", "希望当天就能成交，不愿等")]
        case .tAppetite:
            return [opt("none", "不做 T", "只做长期配置，不参与日内往返"),
                    opt("low", "低频 · 高质量", "只做价差明显、把握大的机会"),
                    opt("normal", "正常", "有机会就做，价差合理即可"),
                    opt("high", "积极", "小价差也愿意做，靠次数积累")]
        case .trample:
            return riskOptions(labels: ("低", "中", "高"), details: ("更怕卖飞，倾向先买后卖", "两种都接受", "更怕套住，愿意先卖后买"))
        case .gridAppetite:
            return [opt("none", "不使用网格", "不希望资金被多个买档占用"),
                    opt("wide", "宽网格 · 少档", "档数少、间距大，省心"),
                    opt("normal", "震荡时用", "行情震荡时才启用"),
                    opt("active", "积极网格", "长期挂着，接受资金占用")]
        case .gridWidth:
            return [opt("narrow", "窄网格", "间距 0.4%–1%"), opt("normal", "中等", "间距 1%–2.5%"), opt("wide", "宽网格", "间距 2.5% 以上")]
        case .cashPreference:
            return [opt("wait", "愿意等待机会", "宁可留现金，也不追着买"),
                    opt("balanced", "均衡", "留一部分现金，其余按计划配置"),
                    opt("invested", "有钱就买", "到账就配置，不喜欢空仓")]
        case .style:
            return []   // 多标签，由学习直接生成
        case .execution:
            return [opt("manual", "AI 建议 + 手工下单", "AI 只给价格和份额，成交由你在券商手工完成")]
        case .minSpread, .minNetGain, .gridTiers:
            return []   // 数值型：用输入框
        }
    }

    static func isNumeric(_ id: NextProfileTraitID) -> Bool {
        id == .minSpread || id == .minNetGain || id == .gridTiers
    }

    static func numericUnit(_ id: NextProfileTraitID) -> String {
        switch id {
        case .minSpread: return "%"
        case .minNetGain: return "元"
        case .gridTiers: return "档"
        default: return ""
        }
    }

    private static func opt(_ value: String, _ label: String, _ detail: String) -> NextProfileOption {
        NextProfileOption(value: value, label: label, detail: detail)
    }

    private static func riskOptions(labels: (String, String, String), details: (String, String, String)) -> [NextProfileOption] {
        [opt("low", labels.0, details.0), opt("mid", labels.1, details.1), opt("high", labels.2, details.2)]
    }
}

// MARK: - 排序调整（画像只影响优先级，不改变事实）

struct NextProfileAdjustment: Equatable {
    enum Verdict: String, Equatable {
        case aligned = "符合你的习惯"
        case belowThreshold = "低于你的执行门槛"
        case preferenceBlocked = "与你的偏好不符"
        case neutral = "无画像偏好"
    }
    var multiplier: Double = 1
    var verdict: Verdict = .neutral
    var explanation: String? = nil
    var isBlocked: Bool { verdict == .preferenceBlocked }
}

// MARK: - 学习引擎

enum NextProfileEngine {
    static let behaviorWindowDays = 90
    static let temporaryWindowDays = 30
    static let minFillSamples = 5
    static let minSuggestionSamples = 6
    static let minExecutedSamples = 3
    static let coreHoldingDays = 180

    // MARK: 学习入口

    /// 全部结论都从「真实持仓 + 真实成交 + 真实反馈」推导；数据不够时保留上一次结论并标注置信度，
    /// 绝不因为一两笔交易就重写画像。
    static func learn(book: NextBook, goal: NextGoal, quotes: [String: NextQuote],
                      suggestions: [NextSuggestionRecord], plans: [NextCandidatePlan],
                      daily: [String: [NextChartSample]], previous: NextInvestorProfile,
                      now: Date = Date()) -> NextInvestorProfile {
        var profile = previous
        var summary = NextProfileLearningSummary()
        summary.updatedAt = now
        summary.windowDays = behaviorWindowDays

        let windowStart = now.addingTimeInterval(-Double(behaviorWindowDays) * 86_400)
        let tempStart = now.addingTimeInterval(-Double(temporaryWindowDays) * 86_400)
        let fills = book.fills.filter { $0.date >= windowStart && $0.date <= now }
        let allFills = book.fills.filter { $0.date <= now }
        summary.fillSampleCount = fills.count
        summary.suggestionSampleCount = suggestions.filter { $0.createdAt >= windowStart }.count

        // 异常单过滤：单笔金额 ≥ 组合 35%，或份额 ≥ 该标的总份额 50%。
        // 这种「一次性行为」（急用钱、调仓）不能改写风格，只能进当前状态。
        let equity = equityValue(book: book, quotes: quotes)
        let anomalyIDs = anomalyFillIDs(fills: fills, book: book, equity: equity)
        summary.anomalyCount = anomalyIDs.count
        if !anomalyIDs.isEmpty {
            summary.notes.append("过滤了 \(anomalyIDs.count) 笔一次性大额成交，不据此改写长期画像（可能是一次性资金需求或再平衡）")
        }
        let normalFills = fills.filter { !anomalyIDs.contains($0.id) }
        let buys = normalFills.filter { $0.side == "buy" }
        let sells = normalFills.filter { $0.side == "sell" }

        // 1) 长期计划（用户明确设定，AI 不改）
        let horizonTrait = trait(.horizon, value: horizonValue(goal.years), label: horizonLabel(goal.years),
                                 detail: "按你设定的 \(goal.years) 年投资期限", confidence: 0.95,
                                 samples: 1, window: 0, source: .explicit, basis: ["你在投资计划里设定 \(goal.years) 年"], now: now)
        profile.setTrait(respectExplicit(horizonTrait, previous: previous))

        // 2) 账户回撤承受：来自真实净值曲线的实际承受，而不是问卷
        let drawdown = maxDrawdown(history: book.history.sorted { $0.date < $1.date })
        let boughtDuringDrawdown = buys.contains { fill in
            guard let point = book.history.filter({ $0.date <= fill.date }).max(by: { $0.date < $1.date }) else { return false }
            return point.total < (maxEquity(before: fill.date, history: book.history) ?? point.total) * 0.92
        }
        let drawdownTrait = drawdownTraitValue(drawdown: drawdown, boughtDuringDrawdown: boughtDuringDrawdown,
                                               historyCount: book.history.count, now: now)
        profile.setTrait(respectExplicit(drawdownTrait, previous: previous))

        // 3) 集中度：单资产 / 行业 / 海外
        let weights = positionWeights(book: book, quotes: quotes)
        let maxWeight = weights.values.max() ?? 0
        let single = riskTrait(.singleAssetRisk, value: maxWeight,
                               low: 20, high: NextNum.double(goal.concentrationLimit),
                               detail: { level in
                                   switch level {
                                   case "low": return "最大单只占比 \(pctText(maxWeight))%，习惯分散"
                                   case "mid": return "最大单只占比 \(pctText(maxWeight))%，集中度中等"
                                   default: return "最大单只占比 \(pctText(maxWeight))%，愿意重仓单只"
                                   }
                               }, samples: weights.count, basis: weights.isEmpty ? [] : ["当前持仓权重分布（\(weights.count) 只）"])
        profile.setTrait(respectExplicit(single, previous: previous))

        let sectorWeights = groupWeights(book: book, quotes: quotes, groups: Self.sectorKeywords)
        let sectorMax = sectorWeights.values.max() ?? 0
        let topSector = sectorWeights.max { $0.value < $1.value }?.key
        let sector = riskTrait(.sectorRisk, value: sectorMax, low: 35, high: 60,
                               detail: { level in
                                   guard let topSector else { return "还看不出行业集中倾向" }
                                   switch level {
                                   case "low": return "最大行业 \(topSector) 占 \(pctText(sectorMax))%，分散度较高"
                                   case "mid": return "最大行业 \(topSector) 占 \(pctText(sectorMax))%，集中度中等"
                                   default: return "最大行业 \(topSector) 占 \(pctText(sectorMax))%，行业押注明显"
                                   }
                               }, samples: weights.count,
                               basis: sectorWeights.isEmpty ? [] : sectorWeights.sorted { $0.value > $1.value }.prefix(2).map { "\($0.key) 占 \(pctText($0.value))%" })
        profile.setTrait(respectExplicit(sector, previous: previous))

        let overseasWeights = groupWeights(book: book, quotes: quotes, groups: ["海外/跨境": Self.overseasKeywords])
        let overseas = overseasWeights["海外/跨境"] ?? 0
        let overseasTrait = riskTrait(.overseasRisk, value: overseas, low: 15, high: 40,
                                      detail: { level in
                                          switch level {
                                          case "low": return "海外资产占 \(pctText(overseas))%，以 A 股为主"
                                          case "mid": return "海外资产占 \(pctText(overseas))%，跨市场配置"
                                          default: return "海外资产占 \(pctText(overseas))%，接受跨市场波动"
                                          }
                                      }, samples: weights.count,
                                      basis: ["按名称识别跨境/海外品种，仅作波动承受的参考"])
        profile.setTrait(respectExplicit(overseasTrait, previous: previous))

        // 4) 现金流压力：真实出入金而不是猜
        let moves = book.cashMovements.filter { $0.date >= windowStart }
        let outflow = moves.filter { $0.amount < 0 }
        let outflowRatio = equity.map { out -> Double in
            guard out > 0 else { return 0 }
            return NextNum.double(outflow.reduce(Decimal.zero) { $0 + abs($1.amount) } / out * 100)
        }
        let flowTrait = cashFlowTrait(outflowCount: outflow.count, outflowPercent: outflowRatio ?? 0,
                                     cashRatio: cashRatio(book: book, quotes: quotes), now: now)
        profile.setTrait(respectExplicit(flowTrait, previous: previous))

        // 5) 交易频率（90 天 → 折算到 30 天）
        let per30 = Double(normalFills.count) * 30.0 / Double(behaviorWindowDays)
        var freqTrait = frequencyTrait(per30: per30, samples: normalFills.count, now: now)
        // 当前状态：最近 30 天 vs 90 天差异过大 → 只记临时状态，不改长期结论
        let recent = normalFills.filter { $0.date >= tempStart }
        let recentPer30 = Double(recent.count) * 30.0 / Double(temporaryWindowDays)
        if let learned = profile.trait(.tradeFrequency), learned.isKnown, learned.source == .learned,
           per30 > 0.5, recentPer30 < per30 * 0.35 {
            profile.setTrait(trait(.tradeFrequency, value: "cooling", label: "最近在减少交易",
                                   detail: "最近 30 天成交 \(recent.count) 笔，明显低于近 90 天的节奏（折合 \(fmt1(per30)) 笔/月）；这只是当前状态，不改写长期习惯",
                                   confidence: 0.5, samples: recent.count, window: temporaryWindowDays,
                                   source: .temporary,
                                   basis: ["近 90 天 \(normalFills.count) 笔成交，近 30 天 \(recent.count) 笔"], now: now))
        } else {
            freqTrait = respectExplicit(freqTrait, previous: previous)
            profile.setTrait(freqTrait)
        }

        // 6) 限价耐心：计划挂出到真实成交的等待时长 + 撤销/过期率
        let resolved = plans.filter { $0.createdAt >= windowStart }
        let confirmed = resolved.filter { $0.state == .confirmed }
        let waits = confirmed.compactMap { plan -> Double? in
            guard let at = plan.confirmedAt else { return nil }
            return at.timeIntervalSince(plan.createdAt) / 3600
        }
        let cancelRate = resolved.isEmpty ? 0 : Double(resolved.filter { $0.state == .expired || $0.state == .invalidated || $0.state == .withdrawn }.count) / Double(resolved.count)
        let patienceTrait = patienceTrait(medianWaitHours: median(waits), cancelRate: cancelRate,
                                          samples: resolved.count, now: now)
        profile.setTrait(respectExplicit(patienceTrait, previous: previous))

        // 7) 建议轨迹：曝光 / 执行 / 忽略 / 反馈
        let windowSuggestions = suggestions.filter { $0.createdAt >= windowStart }
        let tSuggestions = windowSuggestions.filter(\.isTStyle)
        let executed = tSuggestions.filter { $0.outcome == .executed }
        let ignored = tSuggestions.filter { $0.outcome == .ignored || $0.outcome == .rejected }
        summary.executedCount = executed.count
        summary.ignoredCount = ignored.count

        let executedSpreads = executed.compactMap(\.expectedSpreadPercent)
        let executedGains = executed.compactMap { $0.expectedNetGain.map { NextNum.double($0) } }
        let ignoredSpreads = ignored.compactMap(\.expectedSpreadPercent)

        let appetiteTrait = tAppetiteTrait(suggestions: tSuggestions, executed: executed, ignored: ignored, now: now)
        profile.setTrait(respectExplicit(appetiteTrait, previous: previous))

        // 8) 数值门槛：只从「真的成交过」的机会里学；样本不足就保持默认并说明
        if let previousTrait = profile.trait(.minSpread), previousTrait.locked || previousTrait.source == .explicit {
            // 用户锁定，不动
        } else if executedSpreads.count >= minExecutedSamples {
            let learnedValue = percentile(executedSpreads, 0.2)
            profile.thresholds.minTSpreadPercent = max(0.3, min(3.0, learnedValue))
            profile.setTrait(trait(.minSpread, value: "learned",
                                   label: String(format: "%.2f%% 以上才做", profile.thresholds.minTSpreadPercent),
                                   detail: "你实际成交的 \(executedSpreads.count) 次做 T，预期价差最低的一批约 \(String(format: "%.2f", learnedValue))%；低于这个价差的机会以后不主动推荐",
                                   confidence: confidence(samples: executedSpreads.count, minSamples: minExecutedSamples, consistency: 0.9),
                                   samples: executedSpreads.count, window: behaviorWindowDays, source: .learned,
                                   basis: ["已执行做 T 的预期价差：\(executedSpreads.map { String(format: "%.2f%%", $0) }.joined(separator: "、"))"],
                                   numeric: profile.thresholds.minTSpreadPercent, now: now))
        } else if previous.trait(.minSpread) == nil {
            profile.setTrait(trait(.minSpread, value: "default",
                                   label: String(format: "默认 %.2f%%", profile.thresholds.minTSpreadPercent),
                                   detail: "还没足够多的真实做 T 成交（需要 \(minExecutedSamples) 次），先按默认门槛，不做个性化推荐",
                                   confidence: 0, samples: executedSpreads.count, window: behaviorWindowDays, source: .learned,
                                   basis: ["等待真实成交样本：已有 \(executedSpreads.count)/\(minExecutedSamples)"],
                                   numeric: profile.thresholds.minTSpreadPercent, now: now))
        }

        if let previousTrait = profile.trait(.minNetGain), previousTrait.locked || previousTrait.source == .explicit {
            // 锁定
        } else if executedGains.count >= minExecutedSamples {
            let learned = percentile(executedGains, 0.2)
            profile.thresholds.minTNetGain = max(1, min(500, learned))
            profile.setTrait(trait(.minNetGain, value: "learned",
                                   label: "≥ ¥\(String(format: "%.0f", profile.thresholds.minTNetGain))",
                                   detail: "你成交过的做 T 净收益最低一批约 ¥\(String(format: "%.0f", learned))；净收益低于这个数不再打扰你",
                                   confidence: confidence(samples: executedGains.count, minSamples: minExecutedSamples, consistency: 0.85),
                                   samples: executedGains.count, window: behaviorWindowDays, source: .learned,
                                   basis: ["已执行做 T 的净收益：\(executedGains.map { String(format: "¥%.0f", $0) }.joined(separator: "、"))"],
                                   numeric: profile.thresholds.minTNetGain, now: now))
        } else if previous.trait(.minNetGain) == nil {
            profile.setTrait(trait(.minNetGain, value: "default",
                                   label: "≥ ¥\(String(format: "%.0f", profile.thresholds.minTNetGain))",
                                   detail: "净收益样本不足（\(executedGains.count)/\(minExecutedSamples)），先按默认值 ¥\(String(format: "%.0f", profile.thresholds.minTNetGain))",
                                   confidence: 0, samples: executedGains.count, window: behaviorWindowDays, source: .learned,
                                   basis: ["等待真实成交样本"], numeric: profile.thresholds.minTNetGain, now: now))
        }

        // 用户改价的次数 → 说明 AI 报价口径偏了，记录但不自动改价
        let editedCount = tSuggestions.filter { $0.priceEdited }.count
        if editedCount >= 2, !executed.isEmpty {
            summary.notes.append("你有 \(editedCount) 次修改了 AI 建议价格：AI 报价偏激进，界面会同时显示你的成交价，学习以真实成交价为准")
        }

        // 9) 踏空容忍：反 T（先卖后买）占比越高，越能接受卖飞
        let reverseCount = executed.filter { $0.kind == .reverseT }.count
        let forwardCount = executed.filter { $0.kind == .forwardT }.count
        let trampleTrait: NextProfileTrait
        if reverseCount + forwardCount >= minExecutedSamples {
            let share = Double(reverseCount) / Double(reverseCount + forwardCount)
            let value = share >= 0.65 ? "high" : (share >= 0.35 ? "mid" : "low")
            let label = value == "high" ? "高（更怕套住）" : (value == "mid" ? "中" : "低（更怕卖飞）")
            trampleTrait = trait(.trample, value: value, label: label,
                                 detail: "已执行的做 T 中反 T（先卖后买）\(reverseCount) 次、正 T \(forwardCount) 次",
                                 confidence: confidence(samples: reverseCount + forwardCount, minSamples: minExecutedSamples, consistency: 0.8),
                                 samples: reverseCount + forwardCount, window: behaviorWindowDays, source: .learned,
                                 basis: ["反 T \(reverseCount) 次 / 正 T \(forwardCount) 次"], now: now)
        } else {
            trampleTrait = previous.trait(.trample) ?? trait(.trample, value: "mid", label: "中",
                                                             detail: "做 T 成交样本还不够，先按「两种都接受」处理",
                                                             confidence: 0, samples: reverseCount + forwardCount,
                                                             window: behaviorWindowDays, source: .learned,
                                                             basis: ["等待真实成交样本"], now: now)
        }
        profile.setTrait(respectExplicit(trampleTrait, previous: previous))

        // 10) 网格：真的挂过/成交过才算偏好
        let gridPlans = resolved.filter { $0.kind == .gridBuy || $0.kind == .gridSell }
        let gridWidths = gridPlans.compactMap { plan -> Double? in
            guard let upper = plan.cancelAbove, let lower = plan.cancelBelow, lower > 0 else { return nil }
            return NextNum.double((upper - lower) / lower * 100)
        }
        let gridTrait = gridAppetiteTrait(planCount: gridPlans.count, confirmedCount: gridPlans.filter { $0.state == .confirmed }.count,
                                          medianWidth: median(gridWidths), now: now, previous: previous)
        profile.setTrait(respectExplicit(gridTrait, previous: previous))
        if let width = median(gridWidths), gridWidths.count >= 2 {
            let value = width < 1.2 ? "narrow" : (width < 2.5 ? "normal" : "wide")
            let label = value == "narrow" ? "窄网格" : (value == "normal" ? "中等宽度" : "宽网格")
            profile.setTrait(respectExplicit(trait(.gridWidth, value: value, label: label,
                                                   detail: "你挂过的网格区间中位宽度约 \(String(format: "%.2f", width))%",
                                                   confidence: confidence(samples: gridWidths.count, minSamples: 2, consistency: 0.75),
                                                   samples: gridWidths.count, window: behaviorWindowDays, source: .learned,
                                                   basis: ["网格计划区间宽度：\(gridWidths.map { String(format: "%.2f%%", $0) }.joined(separator: "、"))"],
                                                   numeric: width, now: now), previous: previous))
        }

        // 11) 现金偏好：现金比例 + 现金充足时是否急着买
        let cashPct = cashRatio(book: book, quotes: quotes)
        let cashTrait = cashPreferenceTrait(cashPercent: cashPct, buys: buys.count, outflowCount: outflow.count, now: now)
        profile.setTrait(respectExplicit(cashTrait, previous: previous))

        // 12) 风格标签：多标签，不是单选
        let styleTrait = styleTagsTrait(profile: profile, now: now)
        profile.setTrait(styleTrait)

        // 13) 执行方式：全局硬规则，明确设定，AI 永不修改
        profile.setTrait(trait(.execution, value: "manual", label: "AI 建议 + 手工下单",
                               detail: "AI 只输出价格与份额，成交必须你在券商手工完成；系统不会自动下单，也不使用虚拟交易训练画像",
                               confidence: 1.0, samples: 1, window: 0, source: .explicit, locked: true,
                               basis: ["产品硬性规则：不自动交易、不建模拟账户"], now: now))

        // 14) 长期核心仓 / 机动仓：用户锁定优先，其余按真实持有行为推断
        let mergedRoles = mergeRoles(book: book, fills: allFills, weights: weights,
                                     previous: profile.instrumentRoles, now: now)
        profile.instrumentRoles = mergedRoles

        summary.notes.append(contentsOf: learningNotes(summary: summary, executedSpreadCount: executedSpreads.count,
                                                       ignoredSpreadCount: ignoredSpreads.count))
        profile.summary = summary
        profile.updatedAt = now
        return profile
    }

    // MARK: 画像参与排序

    /// 只调整「推荐优先级」——不改变有没有机会、不改变风险与数据门槛。
    static func adjustment(for item: NextGuidanceItem, profile: NextInvestorProfile) -> NextProfileAdjustment {
        adjustment(tPlan: item.tPlan, gridPlan: item.gridPlan, isActionable: item.isActionable, profile: profile)
    }

    static func adjustment(tPlan: NextTPlannerResult?, gridPlan: NextGridPlannerResult?,
                           isActionable: Bool, profile: NextInvestorProfile) -> NextProfileAdjustment {
        var result = NextProfileAdjustment()
        guard isActionable else { return result }
        if let tResult = tPlan, case let .ready(plan) = tResult {
            let spread = spreadPercent(sell: plan.sellPrice, buy: plan.buyPrice)
            let gain = NextNum.double(plan.netGain)
            let minSpread = profile.thresholds.minTSpreadPercent
            let minGain = profile.thresholds.minTNetGain
            let appetite = profile.trait(.tAppetite)
            let noT = appetite?.value == "none" && appetite?.isKnown == true

            if noT {
                result.verdict = .preferenceBlocked
                result.multiplier = 0.35
                result.explanation = "你的画像显示不做日内往返：这只确实存在做 T 空间，但按你的偏好不主动推荐交易"
            } else if spread < minSpread || gain < minGain {
                result.verdict = .belowThreshold
                result.multiplier = 0.55
                result.explanation = "预期价差 \(String(format: "%.2f", spread))%、净收益 ¥\(String(format: "%.0f", gain))，低于你通常执行的门槛（\(String(format: "%.2f", minSpread))% / ¥\(String(format: "%.0f", minGain))）：机会存在，但不主动推荐交易"
            } else {
                result.verdict = .aligned
                result.multiplier = spread >= minSpread * 1.5 ? 1.15 : 1.05
                result.explanation = "预期价差 \(String(format: "%.2f", spread))% 达到你历史上会执行的水平"
            }
            return result
        }
        if let gResult = gridPlan, case let .ready(grid) = gResult {
            let appetite = profile.trait(.gridAppetite)
            if appetite?.value == "none" && appetite?.isKnown == true {
                result.verdict = .preferenceBlocked
                result.multiplier = 0.4
                result.explanation = "你的画像显示不使用网格：区间本身适合，但按你的偏好不主动推荐"
            } else if grid.tiers.count > profile.thresholds.gridMaxTiers {
                result.verdict = .belowThreshold
                result.multiplier = 0.85
                result.explanation = "网格 \(grid.tiers.count) 档超过你设定的最多 \(profile.thresholds.gridMaxTiers) 档，建议压缩档数"
            } else {
                result.verdict = .aligned
                result.multiplier = 1.05
            }
        }
        return result
    }

    /// 做 T 份额上限：画像给的是「单次可接受份额占可用份额比例」。
    static func cappedTUnits(_ units: Int, available: Int, profile: NextInvestorProfile) -> Int {
        guard available > 0 else { return units }
        let cap = max(100, Int(Double(available) * max(0.1, min(1.0, profile.thresholds.maxTUnitsRatio))))
        return min(units, cap)
    }

    /// 网格档数上限：画像可以压缩，但不能放宽风险判断。
    static func cappedGridTiers(_ tiers: Int, profile: NextInvestorProfile) -> Int {
        max(2, min(tiers, profile.thresholds.gridMaxTiers))
    }

    /// 给在线 AI 的最小结构化画像上下文：只给结论与门槛，不上传成交明细。
    static func promptLines(profile: NextInvestorProfile, limit: Int = 6) -> [String] {
        var lines: [String] = []
        let priority: [NextProfileTraitID] = [.horizon, .style, .tAppetite, .tradeFrequency, .limitPatience,
                                             .cashPreference, .gridAppetite, .drawdown, .execution]
        for id in priority {
            guard let trait = profile.trait(id), trait.isKnown, !trait.isMuted else { continue }
            lines.append("\(trait.id.title)：\(trait.label)（置信度 \(Int((trait.confidence * 100).rounded()))%）")
            if lines.count >= limit { break }
        }
        lines.append("你的执行门槛：做 T 预期价差 ≥ \(String(format: "%.2f", profile.thresholds.minTSpreadPercent))%、净收益 ≥ ¥\(String(format: "%.0f", profile.thresholds.minTNetGain))、单次份额 ≤ 可用份额 \(Int((profile.thresholds.maxTUnitsRatio * 100).rounded()))%")
        return lines
    }

    static func spreadPercent(sell: Decimal, buy: Decimal) -> Double {
        guard buy > 0 else { return 0 }
        return NextNum.double((sell - buy) / buy * 100)
    }

    // MARK: 各属性推导

    private static func respectExplicit(_ candidate: NextProfileTrait, previous: NextInvestorProfile) -> NextProfileTrait {
        guard let old = previous.trait(candidate.id) else { return candidate }
        if old.locked { return old }
        if old.source == .explicit && candidate.source != .explicit {
            // 用户明确设定的规则不能被学习覆盖；只把最新依据补进去。
            var kept = old
            kept.basis = candidate.basis
            return kept
        }
        if old.isMuted { return old }
        return candidate
    }

    private static func trait(_ id: NextProfileTraitID, value: String, label: String, detail: String,
                              confidence: Double, samples: Int, window: Int, source: NextProfileSource,
                              locked: Bool = false, basis: [String], numeric: Double? = nil,
                              now: Date) -> NextProfileTrait {
        NextProfileTrait(id: id, value: value, label: label, detail: detail, confidence: confidence,
                         sampleCount: samples, windowDays: window, source: source, locked: locked,
                         basis: basis, updatedAt: now, numeric: numeric)
    }

    private static func confidence(samples: Int, minSamples: Int, consistency: Double) -> Double {
        guard samples >= minSamples, minSamples > 0 else { return 0 }
        let ramp = 1 - exp(-Double(samples) / Double(minSamples) * 1.15)
        return max(0.2, min(0.95, (0.42 + 0.58 * ramp) * max(0.4, min(1.0, consistency))))
    }

    private static func horizonValue(_ years: Int) -> String {
        if years < 3 { return "short" }
        if years < 7 { return "mid" }
        if years < 15 { return "long" }
        return "veryLong"
    }
    private static func horizonLabel(_ years: Int) -> String {
        if years < 3 { return "短期（\(years) 年）" }
        if years < 7 { return "中期（\(years) 年）" }
        if years < 15 { return "长期（\(years) 年）" }
        return "超长期（\(years) 年）"
    }

    private static func drawdownTraitValue(drawdown: Double?, boughtDuringDrawdown: Bool,
                                           historyCount: Int, now: Date) -> NextProfileTrait {
        guard let drawdown, historyCount >= 20 else {
            return trait(.drawdown, value: "unknown", label: "还不够判断",
                         detail: "账户净值样本不足（\(historyCount)/20），无法判断你实际能承受多大回撤；这里不会猜一个数字",
                         confidence: 0, samples: historyCount, window: behaviorWindowDays, source: .learned,
                         basis: ["需要至少 20 个净值快照"], now: now)
        }
        // 实际经历的最大回撤 + 回撤期间是否继续买入 = 真实承受力，而不是嘴上说的。
        let level: String
        if drawdown >= 25 || (drawdown >= 18 && boughtDuringDrawdown) { level = "high" }
        else if drawdown >= 12 { level = "mid" }
        else { level = "low" }
        let label = level == "high" ? "高" : (level == "mid" ? "中" : "低")
        var detail = "历史最大回撤约 \(String(format: "%.1f", drawdown))%"
        if boughtDuringDrawdown { detail += "，且在回撤中继续买入" }
        return trait(.drawdown, value: level, label: label, detail: detail,
                     confidence: confidence(samples: historyCount / 10, minSamples: 2, consistency: 0.8),
                     samples: historyCount, window: behaviorWindowDays, source: .learned,
                     basis: ["净值快照 \(historyCount) 个", "回撤期买入：\(boughtDuringDrawdown ? "有" : "无")"],
                     numeric: drawdown, now: now)
    }

    private static func riskTrait(_ id: NextProfileTraitID, value: Double, low: Double, high: Double,
                                  detail: (String) -> String, samples: Int, basis: [String]) -> NextProfileTrait {
        guard samples >= 2, value > 0 else {
            return NextProfileTrait(id: id, value: "unknown", label: "还不够判断",
                                    detail: "持仓数量不足（\(samples) 只），无法形成结论",
                                    confidence: 0, sampleCount: samples, windowDays: behaviorWindowDays,
                                    source: .learned, locked: false, basis: basis, updatedAt: Date(), numeric: value)
        }
        let level = value >= high ? "high" : (value >= low ? "mid" : "low")
        let label = level == "high" ? "高" : (level == "mid" ? "中" : "低")
        return NextProfileTrait(id: id, value: level, label: label, detail: detail(level),
                                confidence: confidence(samples: samples, minSamples: 2, consistency: 0.75),
                                sampleCount: samples, windowDays: behaviorWindowDays,
                                source: .learned, locked: false, basis: basis, updatedAt: Date(), numeric: value)
    }

    private static func cashFlowTrait(outflowCount: Int, outflowPercent: Double, cashRatio: Double, now: Date) -> NextProfileTrait {
        let level: String
        if outflowCount >= 3 && outflowPercent >= 8 { level = "tight" }
        else if cashRatio >= 20 { level = "ample" }
        else { level = "ok" }
        let label = level == "tight" ? "有压力" : (level == "ample" ? "宽裕" : "正常")
        let detail: String
        switch level {
        case "tight": detail = "近 90 天有 \(outflowCount) 次转出，合计约占总资产 \(pctText(outflowPercent))%，仓位腾挪空间要留出来"
        case "ample": detail = "现金占比 \(pctText(cashRatio))%，还有余量等机会"
        default: detail = "近 90 天资金进出平稳，现金占比 \(pctText(cashRatio))%"
        }
        return trait(.cashFlow, value: level, label: label, detail: detail,
                     confidence: confidence(samples: max(1, outflowCount) + 2, minSamples: 3, consistency: 0.7),
                     samples: max(1, outflowCount), window: behaviorWindowDays, source: .learned,
                     basis: ["近 90 天转出 \(outflowCount) 次", "现金占比 \(pctText(cashRatio))%"], now: now)
    }

    private static func frequencyTrait(per30: Double, samples: Int, now: Date) -> NextProfileTrait {
        guard samples >= minFillSamples else {
            return trait(.tradeFrequency, value: "unknown", label: "还不够判断",
                         detail: "近 90 天只有 \(samples) 笔真实成交（需要 \(minFillSamples) 笔）",
                         confidence: 0, samples: samples, window: behaviorWindowDays, source: .learned,
                         basis: ["需要至少 \(minFillSamples) 笔真实成交"], numeric: per30, now: now)
        }
        let value = per30 < 2 ? "low" : (per30 < 8 ? "normal" : "high")
        let label = value == "low" ? "低频择机" : (value == "normal" ? "正常" : "积极")
        return trait(.tradeFrequency, value: value, label: label,
                     detail: "近 90 天 \(samples) 笔真实成交，折合约 \(fmt1(per30)) 笔/月",
                     confidence: confidence(samples: samples, minSamples: minFillSamples, consistency: 0.85),
                     samples: samples, window: behaviorWindowDays, source: .learned,
                     basis: ["近 90 天成交 \(samples) 笔"], numeric: per30, now: now)
    }

    private static func patienceTrait(medianWaitHours: Double?, cancelRate: Double, samples: Int, now: Date) -> NextProfileTrait {
        guard samples >= 3, let wait = medianWaitHours else {
            return trait(.limitPatience, value: "unknown", label: "还不够判断",
                         detail: "候选计划样本不足（\(samples)/3），看不出你是愿意挂单等，还是想马上成交",
                         confidence: 0, samples: samples, window: behaviorWindowDays, source: .learned,
                         basis: ["需要至少 3 条已结束的候选计划"], now: now)
        }
        let value: String
        if wait >= 20 || cancelRate <= 0.15 { value = "patient" }
        else if wait >= 3 { value = "normal" }
        else { value = "impatient" }
        let label = value == "patient" ? "耐心限价" : (value == "normal" ? "正常" : "要快成交")
        return trait(.limitPatience, value: value, label: label,
                     detail: "计划挂出到成交中位等待 \(fmt1(wait)) 小时，撤销/过期率 \(pctText(cancelRate * 100))%",
                     confidence: confidence(samples: samples, minSamples: 3, consistency: 0.8),
                     samples: samples, window: behaviorWindowDays, source: .learned,
                     basis: ["已结束计划 \(samples) 条", "中位等待 \(fmt1(wait)) 小时"], numeric: wait, now: now)
    }

    private static func tAppetiteTrait(suggestions: [NextSuggestionRecord], executed: [NextSuggestionRecord],
                                       ignored: [NextSuggestionRecord], now: Date) -> NextProfileTrait {
        guard suggestions.count >= minSuggestionSamples else {
            return trait(.tAppetite, value: "unknown", label: "还不够判断",
                         detail: "近 90 天只有 \(suggestions.count) 次做 T 建议（需要 \(minSuggestionSamples) 次），先按不主动推荐处理",
                         confidence: 0, samples: suggestions.count, window: behaviorWindowDays, source: .learned,
                         basis: ["需要至少 \(minSuggestionSamples) 次建议记录"], now: now)
        }
        let rate = Double(executed.count) / Double(suggestions.count)
        let spreads = executed.compactMap(\.expectedSpreadPercent).sorted()
        let ignoredSpreads = ignored.compactMap(\.expectedSpreadPercent).sorted()
        let value: String
        if rate <= 0.05 && executed.isEmpty { value = "none" }
        else if rate <= 0.35 { value = "low" }
        else if rate <= 0.7 { value = "normal" }
        else { value = "high" }
        let label: String
        switch value {
        case "none": label = "不做 T"
        case "low": label = "低频 · 高质量"
        case "normal": label = "正常"
        default: label = "积极"
        }
        var detail = "近 90 天 \(suggestions.count) 次做 T 建议，你实际成交 \(executed.count) 次（\(pctText(rate * 100))%）"
        if let lowestExecuted = spreads.first, let bestIgnored = ignoredSpreads.last, executed.count >= 2 {
            if bestIgnored < lowestExecuted {
                detail += "；没做的建议里最高价差 \(String(format: "%.2f%%", bestIgnored))%，低于你实际执行的最低 \(String(format: "%.2f%%", lowestExecuted))%"
            }
        }
        return trait(.tAppetite, value: value, label: label, detail: detail,
                     confidence: confidence(samples: suggestions.count, minSamples: minSuggestionSamples,
                                            consistency: 0.55 + 0.45 * min(1.0, rate * 2)),
                     samples: suggestions.count, window: behaviorWindowDays, source: .learned,
                     basis: ["建议 \(suggestions.count) 次 / 成交 \(executed.count) 次",
                             "明确否掉 \(ignored.count) 次"], numeric: rate, now: now)
    }

    private static func gridAppetiteTrait(planCount: Int, confirmedCount: Int, medianWidth: Double?,
                                          now: Date, previous: NextInvestorProfile) -> NextProfileTrait {
        if let old = previous.trait(.gridAppetite), old.locked { return old }
        guard planCount >= 2 else {
            return trait(.gridAppetite, value: "unknown", label: "还不够判断",
                         detail: "还没有足够的网格计划记录（\(planCount)/2），先不替你决定用不用网格",
                         confidence: 0, samples: planCount, window: behaviorWindowDays, source: .learned,
                         basis: ["需要至少 2 次网格计划记录"], now: now)
        }
        let value: String
        if confirmedCount == 0 { value = "none" }
        else if let width = medianWidth, width >= 4 { value = "wide" }
        else { value = "normal" }
        let label: String
        switch value {
        case "none": label = "不使用网格"
        case "wide": label = "宽网格 · 少档"
        default: label = "震荡时用"
        }
        return trait(.gridAppetite, value: value, label: label,
                     detail: "近 90 天 \(planCount) 个网格计划，成交 \(confirmedCount) 个",
                     confidence: confidence(samples: planCount, minSamples: 2, consistency: 0.7),
                     samples: planCount, window: behaviorWindowDays, source: .learned,
                     basis: ["网格计划 \(planCount) 个", "成交 \(confirmedCount) 个"], now: now)
    }

    private static func cashPreferenceTrait(cashPercent: Double, buys: Int, outflowCount: Int, now: Date) -> NextProfileTrait {
        let value: String
        if cashPercent >= 25 { value = "wait" }
        else if cashPercent >= 8 { value = "balanced" }
        else { value = (buys >= 4 && outflowCount == 0) ? "invested" : "balanced" }
        let label = value == "wait" ? "愿意等待机会" : (value == "invested" ? "有钱就买" : "均衡")
        let detail: String
        switch value {
        case "wait": detail = "现金占比 \(pctText(cashPercent))%，宁可留着等更好的价格"
        case "invested": detail = "现金占比 \(pctText(cashPercent))%，资金到账基本都会配置出去"
        default: detail = "现金占比 \(pctText(cashPercent))%，留一部分机动"
        }
        return trait(.cashPreference, value: value, label: label, detail: detail,
                     confidence: confidence(samples: max(2, buys), minSamples: 3, consistency: 0.7),
                     samples: max(2, buys), window: behaviorWindowDays, source: .learned,
                     basis: ["现金占比 \(pctText(cashPercent))%", "近 90 天买入 \(buys) 笔"], numeric: cashPercent, now: now)
    }

    private static func styleTagsTrait(profile: NextInvestorProfile, now: Date) -> NextProfileTrait {
        var tags: [String] = []
        if let horizon = profile.trait(.horizon), horizon.value == "long" || horizon.value == "veryLong" { tags.append("长期配置") }
        if let patience = profile.trait(.limitPatience), patience.value == "patient", patience.isKnown { tags.append("耐心限价") }
        if let freq = profile.trait(.tradeFrequency), freq.value == "low", freq.isKnown { tags.append("低频择机") }
        if let appetite = profile.trait(.tAppetite), appetite.isKnown, appetite.value != "none" { tags.append("主动降本") }
        if let overseas = profile.trait(.overseasRisk), overseas.isKnown, overseas.value != "low" { tags.append("跨市场配置") }
        if let sector = profile.trait(.sectorRisk), sector.isKnown, sector.value == "high" { tags.append("行业机会交易") }
        if let cash = profile.trait(.cashPreference), cash.value == "wait" { tags.append("现金优先") }
        if tags.isEmpty { tags.append("还在学习") }
        let known = profile.knownTraits.filter { $0.isKnown }
        let avg = known.isEmpty ? 0 : known.map(\.confidence).reduce(0, +) / Double(known.count)
        return trait(.style, value: tags.joined(separator: "|"), label: tags.joined(separator: " · "),
                     detail: "标签来自真实持仓、真实成交与你的反馈，多标签并存；不是让你选一个类型",
                     confidence: min(0.9, avg), samples: known.count, window: behaviorWindowDays,
                     source: .learned, basis: ["\(known.count) 项画像已有足够样本"], now: now)
    }

    private static func mergeRoles(book: NextBook, fills: [NextFill], weights: [String: Double],
                                   previous: [String: NextInstrumentRole], now: Date) -> [String: NextInstrumentRole] {
        var roles = previous
        for position in book.positions where position.units > 0 {
            if let old = roles[position.code], old.locked || old.source == .explicit { continue }
            let codeFills = fills.filter { $0.code == position.code }.sorted { $0.date < $1.date }
            let firstBuy = codeFills.first(where: { $0.side == "buy" })?.date ?? position.acquiredAt
            let holdDays = firstBuy.map { now.timeIntervalSince($0) / 86_400 } ?? 0
            let recentSells = codeFills.filter { $0.side == "sell" && $0.date >= now.addingTimeInterval(-90 * 86_400) }
            let weight = weights[position.code] ?? 0
            var role = NextInstrumentRole()
            role.updatedAt = now
            role.source = .learned
            if holdDays >= Double(coreHoldingDays) && recentSells.isEmpty && weight >= 5 {
                role.role = .core
                role.reason = "持有约 \(Int(holdDays)) 天、近 90 天没有卖出、占比 \(pctText(weight))%，按长期核心仓对待"
            } else if !codeFills.isEmpty && recentSells.count >= 2 {
                role.role = .tactical
                role.reason = "近 90 天有 \(recentSells.count) 次卖出，按行业机动仓对待"
            } else if holdDays > 0 && holdDays < 30 {
                role.role = .tactical
                role.reason = "建仓约 \(Int(holdDays)) 天，尚未证明是长期仓，先按机动仓处理"
            } else {
                role.role = .undecided
                role.reason = "样本还不足：持有 \(Int(holdDays)) 天、成交 \(codeFills.count) 笔"
            }
            roles[position.code] = role
        }
        // 已清仓的标的不保留角色结论，避免画像里堆一堆过期判断
        let liveCodes = Set(book.positions.filter { $0.units > 0 }.map(\.code))
        roles = roles.filter { liveCodes.contains($0.key) || $0.value.locked }
        return roles
    }

    private static func learningNotes(summary: NextProfileLearningSummary, executedSpreadCount: Int,
                                      ignoredSpreadCount: Int) -> [String] {
        var notes: [String] = []
        if summary.fillSampleCount < minFillSamples {
            notes.append("真实成交只有 \(summary.fillSampleCount) 笔（需要 \(minFillSamples) 笔）：交易频率、限价耐心这些结论暂时不下")
        }
        if summary.suggestionSampleCount < minSuggestionSamples {
            notes.append("做 T 建议记录 \(summary.suggestionSampleCount) 次（需要 \(minSuggestionSamples) 次）：做 T 偏好正在积累，暂不据此过滤机会")
        }
        if executedSpreadCount > 0 && executedSpreadCount < minExecutedSamples {
            notes.append("已成交的做 T 样本 \(executedSpreadCount) 次（需要 \(minExecutedSamples) 次）才能校准你的最低价差门槛")
        }
        if ignoredSpreadCount >= 3 && executedSpreadCount == 0 {
            notes.append("有 \(ignoredSpreadCount) 次建议你没有执行：等成交样本出现后再判断是价差不够还是时机不对")
        }
        return notes
    }

    // MARK: 基础统计

    private static func equityValue(book: NextBook, quotes: [String: NextQuote]) -> Decimal? {
        book.total(using: quotes)
    }

    private static func cashRatio(book: NextBook, quotes: [String: NextQuote]) -> Double {
        guard let total = book.total(using: quotes), total > 0 else { return 0 }
        return NextNum.double(book.cash / total * 100)
    }

    private static func positionWeights(book: NextBook, quotes: [String: NextQuote]) -> [String: Double] {
        guard let total = book.total(using: quotes), total > 0 else { return [:] }
        var result: [String: Double] = [:]
        for position in book.positions where position.units > 0 {
            let value = (quotes[position.code]?.price ?? position.costPerUnit) * Decimal(position.units)
            result[position.code] = NextNum.double(value / total * 100)
        }
        return result
    }

    private static func groupWeights(book: NextBook, quotes: [String: NextQuote],
                                     groups: [String: [String]]) -> [String: Double] {
        guard let total = book.total(using: quotes), total > 0 else { return [:] }
        var result: [String: Double] = [:]
        for position in book.positions where position.units > 0 {
            let value = (quotes[position.code]?.price ?? position.costPerUnit) * Decimal(position.units)
            let percent = NextNum.double(value / total * 100)
            for (name, keywords) in groups where keywords.contains(where: { position.name.contains($0) }) {
                result[name, default: 0] += percent
                break
            }
        }
        return result
    }

    private static let sectorKeywords: [String: [String]] = [
        "半导体/芯片": ["半导体", "芯片", "集成电路", "科创芯片"],
        "医药/医疗": ["医药", "医疗", "生物", "创新药", "疫苗"],
        "军工/高端制造": ["军工", "国防", "航天", "机器人", "高端装备"],
        "消费/食品": ["消费", "食品", "白酒", "家电", "旅游"],
        "金融/券商": ["证券", "券商", "银行", "保险", "金融"],
        "新能源/电力": ["新能源", "光伏", "储能", "电池", "电力", "碳中和"],
        "红利/价值": ["红利", "价值", "低波"],
        "科技/软件": ["科技", "软件", "计算机", "通信", "人工智能", "云计算", "传媒", "游戏"],
        "宽基/综合": ["300", "500", "1000", "50", "A50", "A500", "创业板", "科创50", "中证", "全指"]
    ]

    private static let overseasKeywords: [String] = ["纳指", "纳斯达克", "标普", "道琼斯", "日经", "恒生", "港股",
                                                     "中概", "德国", "法国", "东南亚", "越南", "沙特", "亚太", "全球",
                                                     "海外", "QDII", "美国", "欧洲"]

    private static func anomalyFillIDs(fills: [NextFill], book: NextBook, equity: Decimal?) -> Set<UUID> {
        var ids = Set<UUID>()
        let amounts = fills.map { $0.price * Decimal($0.units) }.sorted()
        let medianAmount = median(amounts.map { NextNum.double($0) }) ?? 0
        for fill in fills {
            let amount = fill.price * Decimal(fill.units)
            let positionUnits = book.positions.first(where: { $0.code == fill.code })?.units ?? 0
            let shareOfPosition = positionUnits > 0 ? Double(fill.units) / Double(positionUnits) : 0
            let shareOfEquity = equity.map { eq -> Double in
                guard eq > 0 else { return 0 }
                return NextNum.double(amount / eq * 100)
            } ?? 0
            if shareOfPosition >= 0.5 || shareOfEquity >= 35
                || (medianAmount > 0 && NextNum.double(amount) >= medianAmount * 8) {
                ids.insert(fill.id)
            }
        }
        return ids
    }

    private static func maxEquity(before date: Date, history: [NextAssetPoint]) -> Decimal? {
        history.filter { $0.date <= date }.map(\.total).max()
    }

    private static func maxDrawdown(history: [NextAssetPoint]) -> Double? {
        guard history.count >= 2 else { return nil }
        var peak = NextNum.double(history[0].total)
        var worst = 0.0
        for point in history {
            let value = NextNum.double(point.total)
            if value > peak { peak = value }
            guard peak > 0 else { continue }
            worst = max(worst, (peak - value) / peak * 100)
        }
        return worst
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let rank = max(0, min(1, p)) * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down))
        let high = min(sorted.count - 1, low + 1)
        let weight = rank - Double(low)
        return sorted[low] * (1 - weight) + sorted[high] * weight
    }

    private static func fmt1(_ value: Double) -> String { String(format: "%.1f", value) }
    private static func pctText(_ value: Double) -> String { String(format: "%.1f", value) }
}
