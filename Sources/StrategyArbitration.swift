import Foundation

// MARK: - 策略仲裁（Strategy Arbitration）
//
// 治理对应：统一仲裁优先级
//   真实数据有效性 > 组合风险 Risk Guard > 市场状态 > 技术证据 > AI > Candidate
//
// 设计原则：
//   · 高优先级层「一票否决」，低优先级层不得翻案。MACD 再漂亮，数据过期或组合超限也必须停。
//   · AI 只负责解释与措辞，永远不改变仲裁结论（避免「模型情绪化下单」）。
//   · Candidate 永不自动执行：即使全部通过，也只到「可进入候选」为止，执行仍由人确认。
//   · 本模块不打分、不排名，只输出「现在允许做什么」以及「是谁决定的」。

/// 仲裁层级，顺序即优先级（数字越小越优先）。
enum ArbitrationLayer: String, CaseIterable, Comparable, Sendable {
    case dataValidity
    case riskBudget
    case marketRegime
    case technicalEvidence
    case aiAdvisor
    case candidate

    var priority: Int {
        switch self {
        case .dataValidity: return 0
        case .riskBudget: return 1
        case .marketRegime: return 2
        case .technicalEvidence: return 3
        case .aiAdvisor: return 4
        case .candidate: return 5
        }
    }

    var title: String {
        switch self {
        case .dataValidity: return "真实数据有效性"
        case .riskBudget: return "组合风险"
        case .marketRegime: return "市场状态"
        case .technicalEvidence: return "技术证据"
        case .aiAdvisor: return "AI 顾问"
        case .candidate: return "交易候选"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.priority < rhs.priority }
}

/// 仲裁结论。刻意不叫「买入/卖出信号」。
enum ArbitrationVerdict: String, Equatable, Sendable {
    /// 数据不可信：禁止生成精确估值/限价。
    case blockedByData
    /// 组合风险否决：不允许新增买入。
    case blockedByRisk
    /// 市场状态不允许：只能等。
    case waitForMarket
    /// 证据不足或方向不利：只观察。
    case observeOnly
    /// 可进入候选准备（仍需人工确认，不自动执行）。
    case candidateEligible
    /// 已有候选在跟踪中。
    case candidateActive

    var title: String {
        switch self {
        case .blockedByData: return "数据阻断"
        case .blockedByRisk: return "风险否决"
        case .waitForMarket: return "等待市场"
        case .observeOnly: return "仅观察"
        case .candidateEligible: return "可备选"
        case .candidateActive: return "候选跟踪中"
        }
    }

    /// 给人的一句话行动口径。
    var allowedAction: String {
        switch self {
        case .blockedByData: return "不给精确价：先把数据补齐，再看结论"
        case .blockedByRisk: return "不允许新增买入：先降集中度或补现金"
        case .waitForMarket: return "只等不做：市场风险过高，忍耐也是一种操作"
        case .observeOnly: return "只观察：证据不足以支撑动作"
        case .candidateEligible: return "可登记候选：仍需人工确认后执行"
        case .candidateActive: return "跟踪已有候选：不新增计划"
        }
    }

    /// 是否允许给出精确限价（数据阻断时只能给区间）。
    var allowsExactLimitPrice: Bool {
        self != .blockedByData
    }
}

/// 仲裁输入。全部来自已有引擎输出，不新增数据源。
struct ArbitrationInput {
    var code: String
    var priceQuality: ETFPriceQuality?
    var riskBudget: RiskBudgetAssessment?
    var regime: MarketRegimeAssessment?
    var dailyTrend: MACDTrend?
    var divergence: MACDDivergence?
    var patternHitCount: Int = 0
    var aiSuggestionText: String?
    var candidatePresent: Bool = false

    init(code: String, priceQuality: ETFPriceQuality? = nil,
         riskBudget: RiskBudgetAssessment? = nil,
         regime: MarketRegimeAssessment? = nil,
         dailyTrend: MACDTrend? = nil,
         divergence: MACDDivergence? = nil,
         patternHitCount: Int = 0,
         aiSuggestionText: String? = nil,
         candidatePresent: Bool = false) {
        self.code = code
        self.priceQuality = priceQuality
        self.riskBudget = riskBudget
        self.regime = regime
        self.dailyTrend = dailyTrend
        self.divergence = divergence
        self.patternHitCount = patternHitCount
        self.aiSuggestionText = aiSuggestionText
        self.candidatePresent = candidatePresent
    }
}

/// 仲裁结果。
struct ArbitrationDecision: Equatable {
    let verdict: ArbitrationVerdict
    /// 是哪一层做的最终决定。
    let decidedBy: ArbitrationLayer
    let headline: String
    /// 逐层说明，供界面与 AI 解释复用。
    let reasons: [String]
    /// 被高优先级压制、因此没能决定的层（诚实交代「它们也看了」）。
    let suppressedLayers: [ArbitrationLayer]
    /// 数据阻断时只能给区间。
    let allowsExactLimitPrice: Bool
    /// 恒为 false：本 App 不自动执行任何交易。
    let allowsAutomaticExecution: Bool = false

    var title: String { verdict.title }
    var action: String { verdict.allowedAction }
}

// MARK: - 引擎

enum StrategyArbitration {
    static func decide(_ input: ArbitrationInput) -> ArbitrationDecision {
        var reasons: [String] = []

        // ── 第 1 关：真实数据有效性（一票否决）
        guard let quality = input.priceQuality else {
            return make(.blockedByData, by: .dataValidity,
                        headline: "没有价格质量结论，按数据不可用处理",
                        reasons: ["缺少价格质量评估，无法给出任何精确数字"],
                        allowsExactLimitPrice: false)
        }
        switch quality.verdict {
        case .blocked:
            let blockers = quality.blockingIssues.isEmpty
                ? quality.issueTitles
                : quality.blockingIssues.map(\.title)
            return make(.blockedByData, by: .dataValidity,
                        headline: "数据不可信：\(blockers.prefix(2).joined(separator: "、"))",
                        reasons: quality.notes,
                        allowsExactLimitPrice: false)
        case .degraded:
            reasons.append("数据降级：\(quality.issueTitles.joined(separator: "、"))；只给区间（±\(String(format: "%.1f", quality.priceBandPercent))%）")
        case .usable:
            reasons.append("数据可用：报价新鲜、来源可核验")
        }

        // ── 第 2 关：组合风险（一票否决）
        if let risk = input.riskBudget {
            if risk.hasVeto {
                let detail = risk.findings.first(where: { $0.severity == .veto })?.detail ?? risk.summary
                return make(.blockedByRisk, by: .riskBudget,
                            headline: "组合风险否决：\(detail)",
                            reasons: reasons + risk.findings.map(\.detail),
                            allowsExactLimitPrice: quality.allowsExactLimitPrice)
            }
            if risk.worstSeverity == .warn {
                reasons.append("组合风险提醒：\(risk.summary)")
            } else {
                reasons.append("组合结构在政策范围内")
            }
        } else {
            reasons.append("未取得组合风险预算，按不否决处理（建议补齐）")
        }

        // ── 第 3 关：市场状态
        if let regime = input.regime {
            if regime.riskLevel >= .r2High {
                return make(.waitForMarket, by: .marketRegime,
                            headline: "市场状态不允许：\(regime.regime.title) · \(regime.riskLevel.title)",
                            reasons: reasons + ["指数环境风险过高，个股技术信号再强也不加仓"],
                            allowsExactLimitPrice: quality.allowsExactLimitPrice)
            }
            if regime.riskLevel == .r1Elevated {
                reasons.append("市场风险升高（\(regime.riskLevel.title)）：即使成立也只做小仓位")
            } else {
                reasons.append("市场状态：\(regime.regime.title) · \(regime.riskLevel.title)")
            }
        } else {
            reasons.append("市场状态不可用：不据此加仓，仅按个股证据观察")
        }

        // ── 第 4 关：技术证据
        guard let trend = input.dailyTrend else {
            return make(.observeOnly, by: .technicalEvidence,
                        headline: "没有日线 MACD 证据",
                        reasons: reasons + ["技术证据缺失，不构成任何动作依据"],
                        allowsExactLimitPrice: quality.allowsExactLimitPrice)
        }

        switch trend {
        case .dataInsufficient:
            return make(.observeOnly, by: .technicalEvidence,
                        headline: "技术数据不足",
                        reasons: reasons + ["日线样本不足，MACD 结论不成立"],
                        allowsExactLimitPrice: quality.allowsExactLimitPrice)
        case .bearish, .weakening:
            return make(.observeOnly, by: .technicalEvidence,
                        headline: "技术证据偏空：\(trend.title)",
                        reasons: reasons + ["日线动能不利，不做左侧介入"],
                        allowsExactLimitPrice: quality.allowsExactLimitPrice)
        case .neutral:
            reasons.append("日线动能中性：无方向优势")
        case .shortTermRebound:
            reasons.append("零轴下反弹只算动能修复，不等于趋势反转")
        case .bullishImproving:
            reasons.append("日线多头动能增强")
        }

        // 顶背离优先降级：价格新高但动能没跟上。
        if input.divergence == .bearish {
            return make(.observeOnly, by: .technicalEvidence,
                        headline: "顶背离：动能未跟随价格新高",
                        reasons: reasons + ["出现顶背离观察信号，优先减仓思路而非加仓"],
                        allowsExactLimitPrice: quality.allowsExactLimitPrice)
        }
        if input.divergence == .bullish {
            reasons.append("底背离观察：可能止跌，仍需收盘确认")
        }
        if input.patternHitCount > 0 {
            reasons.append("命中 \(input.patternHitCount) 个 K 线形态（实验级观察证据）")
        }

        // 只有「多头动能增强 + 至少一个形态配合」才够格备选，避免单指标定生死。
        if trend == .bullishImproving, input.patternHitCount > 0 {
            if input.candidatePresent {
                return make(.candidateActive, by: .candidate,
                            headline: "证据成立且已有候选在跟踪",
                            reasons: reasons + ["候选由人工确认执行，系统不自动下单"],
                            allowsExactLimitPrice: quality.allowsExactLimitPrice)
            }
            return make(.candidateEligible, by: .candidate,
                        headline: "证据成立：可登记候选（需人工确认）",
                        reasons: reasons + ["AI 只作解释，不改变本结论"],
                        allowsExactLimitPrice: quality.allowsExactLimitPrice)
        }

        return make(.observeOnly, by: .technicalEvidence,
                    headline: "证据不足以支撑动作：\(trend.title)",
                    reasons: reasons + ["缺少形态/量价配合时，单项 MACD 不单独成事"],
                    allowsExactLimitPrice: quality.allowsExactLimitPrice)
    }

    private static func make(_ verdict: ArbitrationVerdict,
                             by layer: ArbitrationLayer,
                             headline: String,
                             reasons: [String],
                             allowsExactLimitPrice: Bool) -> ArbitrationDecision {
        let suppressed = ArbitrationLayer.allCases.filter { $0 > layer }
        return ArbitrationDecision(verdict: verdict,
                                   decidedBy: layer,
                                   headline: headline,
                                   reasons: reasons,
                                   suppressedLayers: suppressed,
                                   allowsExactLimitPrice: allowsExactLimitPrice)
    }
}
