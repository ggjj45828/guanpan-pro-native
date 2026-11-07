import Foundation

// MARK: - 候选计划 → 风控 → 仓位纪律 → 实时触发 → 影子评估
//
// 移植自观盘max 的 Candidate / Risk Guard / PositionDiscipline / RealtimeTrigger /
// Shadow Scorecard 的计算口径，但**按 Pro 真实拥有的数据重新适配**：
//   · Pro 没有交易所时间戳信任分级、逐标的 Regime、策略资格授予、confirmedFills 对账，
//     这些校验一律输出「降级」finding 并压低置信度，绝不假装通过。
//   · 所有输出只表示「可人工复核」，不是下单许可；本文件不写账本、不发网络请求。
//   · 影子评估只在观测覆盖完整时才给 MFE/MAE，缺口处留 nil，不插值、不编造。

// MARK: 候选计划

enum CandidateDirection: String, Codable, CaseIterable, Equatable {
    case buy, sell
}

enum CandidateError: Error, LocalizedError {
    case invalidCode
    case invalidPrice
    case invalidZone
    case invalidQuantity
    case invalidWindow
    case invalidStop

    var errorDescription: String? {
        switch self {
        case .invalidCode: return "证券代码必须是 6 位纯数字"
        case .invalidPrice: return "价格必须大于 0 且为有限数"
        case .invalidZone: return "价格区间下沿不能高于上沿"
        case .invalidQuantity: return "数量必须大于 0"
        case .invalidWindow: return "有效期必须晚于创建时刻"
        case .invalidStop: return "失效价必须大于 0"
        }
    }
}

/// 一条「如果价格到了这里，我打算怎么做」的记录。不是订单，也不写 Ledger。
struct TradeCandidate: Identifiable, Codable, Equatable {
    let id: UUID
    let code: String
    let direction: CandidateDirection
    let lowerPrice: Double
    let upperPrice: Double
    let targetPrice: Double
    let quantity: Double
    let validFrom: Date
    let validUntil: Date
    let invalidationPrice: Double?
    let note: String
    let createdAt: Date

    init(id: UUID = UUID(), code: String, direction: CandidateDirection,
         lowerPrice: Double, upperPrice: Double, targetPrice: Double,
         quantity: Double, validFrom: Date, validUntil: Date,
         invalidationPrice: Double? = nil, note: String = "",
         createdAt: Date = Date()) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy({ $0.isNumber }) else {
            throw CandidateError.invalidCode
        }
        let prices = [lowerPrice, upperPrice, targetPrice]
        guard prices.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw CandidateError.invalidPrice
        }
        guard lowerPrice <= upperPrice else { throw CandidateError.invalidZone }
        guard quantity.isFinite, quantity > 0 else { throw CandidateError.invalidQuantity }
        guard validUntil > validFrom else { throw CandidateError.invalidWindow }
        if let stop = invalidationPrice {
            guard stop.isFinite, stop > 0 else { throw CandidateError.invalidStop }
        }
        self.id = id
        self.code = trimmed
        self.direction = direction
        self.lowerPrice = lowerPrice
        self.upperPrice = upperPrice
        self.targetPrice = targetPrice
        self.quantity = quantity
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.invalidationPrice = invalidationPrice
        self.note = note
        self.createdAt = createdAt
    }
}

// MARK: 仓位纪律

enum DisciplineAction { case buy, sell }

struct PositionDisciplinePolicy {
    var maxPortfolioExposure: Double = 0.90
    var maxSingleSecurityExposure: Double = 0.25
    var minimumCashReserve: Double = 0.05
    var baseBuyScoreThreshold: Int = 60
    var highExposureBuyScoreThreshold: Int = 85
    var cooldownAfterConsecutiveBuys: Int = 3
    var highExposureThreshold: Double = 0.70
    var dailyBuyLimit: Double? = nil
    var minimumSecondsBetweenTrades: Double = 0
    var protectedCoreFraction: Double? = nil

    static let standard = PositionDisciplinePolicy()
}

struct DisciplineSnapshot {
    let cash: Double
    let totalAssets: Double
    let totalSecurityValue: Double
    let currentSecurityValue: Double
    let currentUnits: Double
    let protectedCoreUnits: Double
    let unmatchedTSoldUnits: Double
    let dailyBuyAmount: Double
    let consecutiveBuyCount: Int?
    let secondsSinceLastFill: TimeInterval?
}

struct DisciplineFinding: Identifiable, Equatable {
    let id: UUID
    let code: String
    let message: String
    let blocking: Bool

    init(id: UUID = UUID(), _ code: String, _ message: String, blocking: Bool = true) {
        self.id = id
        self.code = code
        self.message = message
        self.blocking = blocking
    }
}

struct DisciplinePreview {
    let allowedForReview: Bool
    let findings: [DisciplineFinding]
    let projectedExposure: Double
    let requiredScore: Int
}

enum PositionDisciplineGuard {
    /// 与观盘max 同一公式：暴露度越高，买入所需评分从 60 线性抬到 85。
    static func preview(action: DisciplineAction,
                        units: Double,
                        price: Double,
                        fee: Double = 0,
                        score: Int,
                        snapshot: DisciplineSnapshot,
                        policy: PositionDisciplinePolicy = .standard) -> DisciplinePreview {
        var findings: [DisciplineFinding] = []
        let totalAssets = max(0, snapshot.totalAssets)
        let currentExposure = totalAssets > 0 ? snapshot.totalSecurityValue / totalAssets : 0
        let progress = min(1, max(0, (currentExposure - policy.highExposureThreshold)
                                  / max(1e-6, policy.maxPortfolioExposure - policy.highExposureThreshold)))
        let base = Double(policy.baseBuyScoreThreshold)
        let high = Double(policy.highExposureBuyScoreThreshold)
        let requiredScore = Int(ceil(base + (high - base) * progress))

        let projectedSecurityValue = units * price
        let denominator = max(1e-6, totalAssets - fee)
        let projectedExposure = max(0, snapshot.totalSecurityValue
                                    + projectedSecurityValue - snapshot.currentSecurityValue) / denominator

        if action == .buy {
            let cashNeeded = projectedSecurityValue + fee
            if cashNeeded > snapshot.cash + 1e-6 {
                findings.append(.init("insufficient_cash", "现金不足：需要 \(cashNeeded.num(2))，可用 \(snapshot.cash.num(2))"))
            }
            if projectedExposure > policy.maxPortfolioExposure {
                findings.append(.init("portfolio_exposure_cap", "买入后组合暴露 \(projectedExposure.pct(1)) 超过上限 \(policy.maxPortfolioExposure.pct(0))"))
            }
            let single = totalAssets > 0 ? (snapshot.currentSecurityValue + projectedSecurityValue) / totalAssets : 0
            if single > policy.maxSingleSecurityExposure {
                findings.append(.init("single_security_cap", "单标的占比 \(single.pct(1)) 超过上限 \(policy.maxSingleSecurityExposure.pct(0))"))
            }
            let residualCash = max(0, snapshot.cash - cashNeeded)
            if totalAssets > 0 && residualCash / totalAssets < policy.minimumCashReserve {
                findings.append(.init("minimum_cash_reserve", "买入后现金储备低于 \(policy.minimumCashReserve.pct(0))"))
            }
            if let count = snapshot.consecutiveBuyCount, count >= policy.cooldownAfterConsecutiveBuys {
                findings.append(.init("buy_cooldown", "连续 \(count) 笔买入后需要冷却"))
            } else if snapshot.consecutiveBuyCount == nil && policy.cooldownAfterConsecutiveBuys > 0 {
                findings.append(.init("activity_history_unavailable",
                                      "缺少真实连买历史，冷却规则无法判定（证据降级）", blocking: false))
            }
            if let limit = policy.dailyBuyLimit, snapshot.dailyBuyAmount + cashNeeded > limit {
                findings.append(.init("daily_buy_limit", "超过当日买入上限 \(limit.num(2))"))
            }
            if let seconds = snapshot.secondsSinceLastFill, seconds < policy.minimumSecondsBetweenTrades {
                findings.append(.init("trade_too_soon", "距上一笔成交不足 \(Int(policy.minimumSecondsBetweenTrades)) 秒"))
            } else if snapshot.secondsSinceLastFill == nil && policy.minimumSecondsBetweenTrades > 0 {
                findings.append(.init("fill_timing_unavailable",
                                      "缺少上一笔成交时间，间隔规则无法判定（证据降级）", blocking: false))
            }
            if score < requiredScore {
                findings.append(.init("score_threshold_raised", "高暴露下买入需评分 ≥ \(requiredScore)，当前 \(score)"))
            }
        } else {
            let protectedUnits = policy.protectedCoreFraction.map { snapshot.currentUnits * $0 }
                ?? snapshot.protectedCoreUnits
            let sellable = max(0, snapshot.currentUnits - protectedUnits)
            if units > sellable + 1e-6 {
                findings.append(.init("protected_core", "可卖数量 \(sellable.num(0))，不得穿透保护底仓"))
            }
            if units > snapshot.currentUnits + 1e-6 {
                findings.append(.init("insufficient_units", "持有数量不足"))
            }
            if units > snapshot.unmatchedTSoldUnits + 1e-6 && snapshot.unmatchedTSoldUnits > 0 {
                findings.append(.init("t_share_unmatched", "存在未配平的做 T 份额，需先核对"))
            }
        }
        let blocking = findings.contains { $0.blocking }
        return DisciplinePreview(allowedForReview: !blocking,
                                 findings: findings,
                                 projectedExposure: projectedExposure,
                                 requiredScore: requiredScore)
    }
}

// MARK: 风控

struct RiskFinding: Identifiable, Equatable {
    let id: UUID
    let code: String
    let message: String
    /// blocking = 直接否决；false = 降级项，只压低置信度。
    let blocking: Bool

    init(id: UUID = UUID(), _ code: String, _ message: String, blocking: Bool = true) {
        self.id = id
        self.code = code
        self.message = message
        self.blocking = blocking
    }
}

struct RiskAssessment {
    let allowedForReview: Bool
    let findings: [RiskFinding]
    let discipline: DisciplinePreview
    let confidence: Int

    var blockingFindings: [RiskFinding] { findings.filter { $0.blocking } }
}

enum RiskGuard {
    /// 只做「能不能进入人工复核」的判断。返回 true 也不代表可以下单。
    static func evaluate(candidate: TradeCandidate,
                         quote: Quote?,
                         session: MarketSessionStatus,
                         regime: MarketRegimeAssessment?,
                         snapshot: DisciplineSnapshot,
                         score: Int,
                         behavior: OvertradingAssessment? = nil,
                         now: Date = Date(),
                         maxQuoteAge: TimeInterval = 120) -> RiskAssessment {
        var findings: [RiskFinding] = []
        var degraded = 0

        // 报价：Pro 没有交易所时间戳信任分级，只能核对本地获取时间与更新时间。
        if let quote {
            let exchangeTime = quote.updatedAt
            let fetched = quote.fetchedAt
            if let fetched {
                let age = now.timeIntervalSince(fetched)
                if age > maxQuoteAge || age < -maxQuoteAge {
                    findings.append(.init("quote_stale", "报价本地获取于 \(Int(abs(age))) 秒前，超过 \(Int(maxQuoteAge)) 秒阈值"))
                }
            } else {
                findings.append(.init("quote_fetch_time_missing", "缺少本地获取时刻，无法判定新鲜度"))
            }
            if exchangeTime == nil {
                findings.append(.init("exchange_timestamp_unverified", "无交易所时间戳，证据等级降一级", blocking: false))
                degraded += 1
            }
            if candidate.direction == .buy && candidate.targetPrice > quote.price * 1.0001 {
                findings.append(.init("chase_price", "买入目标价 \(candidate.targetPrice.num(3)) 高于最新价 \(quote.price.num(3))，拒绝追价"))
            }
        } else {
            findings.append(.init("quote_missing", "没有可用报价"))
        }

        if session != .continuous {
            findings.append(.init("session_not_continuous", "当前不是连续竞价（\(session.title)），不进入触发判断"))
        }

        if let regime {
            if regime.riskLevel >= .r3Severe {
                findings.append(.init("regime_severe", "市场状态 \(regime.riskLevel.title)，暂停买入复核"))
            }
            if [.riskOff, .extremeRisk, .uncertain, .dataUnreliable].contains(regime.regime) {
                findings.append(.init("regime_risk_off", "市场状态为 \(regime.regime.title)，暂停买入复核"))
            }
            if let asOf = regime.dataAsOf, now.timeIntervalSince(asOf) > 5 * 86400 {
                findings.append(.init("regime_stale", "市场状态数据超过 5 天"))
            }
            // Pro 的 Regime 是大盘级，不是逐标的；按 F 的口径这必须降级。
            findings.append(.init("regime_not_per_security", "仅有大盘级市场状态，无逐标的状态，证据等级降一级", blocking: false))
            degraded += 1
        } else {
            findings.append(.init("regime_missing", "没有市场状态评估，无法判断风险档"))
        }

        // ETF/场内按 100 份整数倍；场外基金交给调用方判断，这里不猜。
        if candidate.quantity.rounded() != candidate.quantity {
            findings.append(.init("units_not_integer_lot", "份额必须是整数"))
        }

        let action: DisciplineAction = candidate.direction == .buy ? .buy : .sell
        let discipline = PositionDisciplineGuard.preview(
            action: action, units: candidate.quantity, price: candidate.targetPrice,
            fee: 0, score: score, snapshot: snapshot)
        for item in discipline.findings {
            findings.append(.init("discipline_" + item.code, item.message, blocking: item.blocking))
        }

        // Anti-Overtrading：门槛由真实账本推导，缺省时明确降级而不是静默放行。
        if let behavior {
            for item in behavior.findings {
                findings.append(.init("behavior_" + item.code, item.message, blocking: item.blocking))
            }
            if behavior.requiredScoreBonus > 0 {
                let needed = discipline.requiredScore + behavior.requiredScoreBonus
                if score < needed {
                    findings.append(.init("behavior_score_threshold_raised",
                                          "近期交易行为把买入评分门槛提高到 ≥ \(needed)，当前 \(score)"))
                }
            }
            if !behavior.metrics.evidenceComplete { degraded += 1 }
        } else {
            findings.append(.init("behavior_history_not_supplied",
                                  "未提供真实成交历史推导的行为门槛，证据等级降一级", blocking: false))
            degraded += 1
        }

        let blocked = findings.contains { $0.blocking }
        let confidence: Int
        if blocked || quote == nil || regime == nil || session != .continuous {
            confidence = 0
        } else {
            confidence = max(0, 100 - degraded * 20)
        }
        return RiskAssessment(allowedForReview: !blocked,
                              findings: findings,
                              discipline: discipline,
                              confidence: confidence)
    }
}

// MARK: 实时触发

enum TriggerState: String, Codable, Equatable {
    case waiting, approaching, triggered, paused
    case quoteStale, sessionClosed, expired, invalidated

    var title: String {
        switch self {
        case .waiting: return "等待"
        case .approaching: return "接近区间"
        case .triggered: return "已触发"
        case .paused: return "暂停"
        case .quoteStale: return "报价过期"
        case .sessionClosed: return "非交易时段"
        case .expired: return "计划过期"
        case .invalidated: return "已失效"
        }
    }
}

struct TriggerAssessment {
    let state: TriggerState
    let signalScore: Int
    let confidence: Int
    let reasons: [String]
    let quoteAge: TimeInterval?
}

enum RealtimeTrigger {
    /// 默认新鲜度 120 秒、接近阈值 0.3%，与观盘max 一致。
    static func evaluate(plan: TradeCandidate,
                         quote: Quote?,
                         previous: TriggerState = .waiting,
                         session: MarketSessionStatus,
                         regime: MarketRegimeAssessment?,
                         now: Date = Date(),
                         maxQuoteAge: TimeInterval = 120,
                         approachDistance: Double = 0.003) -> TriggerAssessment {
        func result(_ state: TriggerState, _ reasons: [String], _ age: TimeInterval?, _ score: Int) -> TriggerAssessment {
            let full = state == .triggered && session == .continuous
                && (quote?.updatedAt != nil) && regime != nil
            return TriggerAssessment(state: state, signalScore: score,
                                     confidence: full ? 100 : 0,
                                     reasons: reasons, quoteAge: age)
        }
        if now > plan.validUntil {
            return result(.expired, ["已超过计划有效期"], nil, 0)
        }
        guard let quote else {
            return result(.quoteStale, ["没有可用报价"], nil, 0)
        }
        let fetched = quote.fetchedAt ?? quote.updatedAt
        let age = fetched.map { now.timeIntervalSince($0) }
        if let age, age > maxQuoteAge || age < -maxQuoteAge {
            return result(.quoteStale, ["报价超过 \(Int(maxQuoteAge)) 秒"], age, 0)
        }
        if session != .continuous {
            return result(.sessionClosed, ["当前\(session.title)"], age, 0)
        }
        if let stop = plan.invalidationPrice {
            let broken = plan.direction == .buy ? quote.price <= stop : quote.price >= stop
            if broken { return result(.invalidated, ["触及失效价 \(stop.num(3))"], age, 0) }
        }
        if let regime, regime.riskLevel >= .r4Extreme && plan.direction == .buy {
            return result(.paused, ["R4 极端风险暂停买入触发"], age, 0)
        }
        let price = quote.price
        let inZone = price >= plan.lowerPrice && price <= plan.upperPrice
        let hitTarget = plan.direction == .buy ? price <= plan.targetPrice : price >= plan.targetPrice
        if inZone || hitTarget {
            return result(.triggered, ["最新价 \(price.num(3)) 落入计划区间"], age, 100)
        }
        let nearLower = price > plan.upperPrice
            && price <= plan.upperPrice * (1 + approachDistance)
        let nearUpper = price < plan.lowerPrice
            && price >= plan.lowerPrice * (1 - approachDistance)
        let approaching = plan.direction == .buy ? nearLower : nearUpper
        if approaching {
            return result(.approaching, ["距区间上/下沿不足 \(approachDistance.pct(1))"], age, 60)
        }
        return result(.waiting, ["最新价 \(price.num(3)) 未进入区间"], age, 0)
    }
}

// MARK: 影子评估（只读，不写账本）

struct ShadowObservation {
    let timestamp: Date
    let price: Double
}

struct ShadowHorizon: Identifiable {
    var id: Int { seconds }
    let seconds: Int
    let expectedAt: Date
    let observedPrice: Double?
    let relativeChange: Double?
    let directionalChange: Double?
}

struct ShadowEvaluation {
    let horizons: [ShadowHorizon]
    let coverageComplete: Bool
    let maxGapSeconds: TimeInterval
    let mfe: Double?
    let mae: Double?
    let reasonCodes: [String]
}

enum CandidateShadow {
    /// 只看触发之后的真实观测。缺口不插值；覆盖不完整时 MFE/MAE 一律 nil。
    static func evaluate(plan: TradeCandidate,
                         triggerAt: Date,
                         triggerPrice: Double,
                         observations: [ShadowObservation],
                         now: Date = Date(),
                         maxGap: TimeInterval = 120,
                         tolerance: TimeInterval = 120) -> ShadowEvaluation {
        let sorted = observations.filter { $0.timestamp > triggerAt && $0.price.isFinite && $0.price > 0 }
            .sorted { $0.timestamp < $1.timestamp }
        var codes: [String] = []
        if sorted.isEmpty { codes.append("no_post_trigger_observations") }
        var largestGap = triggerAt.distance(to: sorted.first?.timestamp ?? triggerAt)
        if sorted.count > 1 {
            for idx in 1..<sorted.count {
                largestGap = max(largestGap, sorted[idx].timestamp.timeIntervalSince(sorted[idx - 1].timestamp))
            }
        }
        let last = sorted.last?.timestamp ?? triggerAt
        largestGap = max(largestGap, now.timeIntervalSince(last))
        let complete = !sorted.isEmpty && largestGap <= maxGap
        if !complete { codes.append("outcome_coverage_incomplete") }

        let horizons = [300, 900, 1800, 3600].map { seconds -> ShadowHorizon in
            let expected = triggerAt.addingTimeInterval(Double(seconds))
            let candidate = sorted.min { lhs, rhs in
                abs(lhs.timestamp.timeIntervalSince(expected)) < abs(rhs.timestamp.timeIntervalSince(expected))
            }
            let usable = candidate.flatMap { obs -> (Double, Double, Double)? in
                guard abs(obs.timestamp.timeIntervalSince(expected)) <= tolerance else { return nil }
                let raw = (obs.price - triggerPrice) / max(1e-9, triggerPrice)
                return (obs.price, raw, plan.direction == .buy ? raw : -raw)
            }
            let observed = usable?.0
            let raw = usable?.1
            let directional = usable?.2
            return ShadowHorizon(seconds: seconds, expectedAt: expected,
                                 observedPrice: observed,
                                 relativeChange: raw,
                                 directionalChange: directional)
        }
        let changes = sorted.map { ($0.price - triggerPrice) / max(1e-9, triggerPrice) }
        return ShadowEvaluation(horizons: horizons,
                                coverageComplete: complete,
                                maxGapSeconds: largestGap,
                                mfe: complete ? changes.max() : nil,
                                mae: complete ? changes.min() : nil,
                                reasonCodes: codes)
    }
}
