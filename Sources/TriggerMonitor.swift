import Foundation

// MARK: - 生产盯盘：候选计划持久化 + 行情刷新时的状态机
//
// 2.26.0 的 `RealtimeTrigger.evaluate` 只在「规则验证台」里被点一次，
// 没有计划存储、没有水位、没有状态变更留痕 —— 按观盘max 清单这属于 `未完成`。
// 本文件把它接进真实刷新循环，边界不变：
//   · 只表示「价格进入过计划区间」，绝不是下单许可，也不写 Ledger。
//   · 报价时间戳必须单调；重复/乱序报价直接忽略，不推进状态。
//   · 非连续竞价直接跳过评估，不把收盘价当成盘中触发。
//   · 触发后锁存，等用户人工复核；价格离开区间不会把事件抹掉。

struct TriggerPlan: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var candidate: TradeCandidate
    var state: TriggerState = .waiting
    var isActive: Bool = true
    /// 已处理报价时间戳的单调水位，防重复 / 乱序回调推进状态。
    var previousQuoteTimestamp: Date? = nil
    var lastEvaluatedAt: Date? = nil
    var lastReasons: [String] = []
    var signalScore: Int = 0
    var confidence: Int = 0
    var lastQuotePrice: Double? = nil
    var linkedFillID: UUID? = nil
    var linkConfirmedByUser: Bool = false
    var note: String = ""
    var createdAt: Date = Date()

    init(id: UUID = UUID(), candidate: TradeCandidate, note: String = "", createdAt: Date = Date()) {
        self.id = id
        self.candidate = candidate
        self.note = note
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, candidate, state, isActive, previousQuoteTimestamp, lastEvaluatedAt
        case lastReasons, signalScore, confidence, lastQuotePrice
        case linkedFillID, linkConfirmedByUser, note, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        candidate = try c.decode(TradeCandidate.self, forKey: .candidate)
        state = try c.decodeIfPresent(TriggerState.self, forKey: .state) ?? .waiting
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        previousQuoteTimestamp = try c.decodeIfPresent(Date.self, forKey: .previousQuoteTimestamp)
        lastEvaluatedAt = try c.decodeIfPresent(Date.self, forKey: .lastEvaluatedAt)
        lastReasons = try c.decodeIfPresent([String].self, forKey: .lastReasons) ?? []
        signalScore = try c.decodeIfPresent(Int.self, forKey: .signalScore) ?? 0
        confidence = try c.decodeIfPresent(Int.self, forKey: .confidence) ?? 0
        lastQuotePrice = try c.decodeIfPresent(Double.self, forKey: .lastQuotePrice)
        linkedFillID = try c.decodeIfPresent(UUID.self, forKey: .linkedFillID)
        linkConfirmedByUser = try c.decodeIfPresent(Bool.self, forKey: .linkConfirmedByUser) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct TriggerEvent: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var planID: UUID
    /// 计划删除后仍能追溯是哪只标的；留痕不能只依赖外键。
    var code: String = ""
    var at: Date
    var from: TriggerState
    var to: TriggerState
    var reasons: [String]
    var quotePrice: Double?
    var confidence: Int

    private enum CodingKeys: String, CodingKey {
        case id, planID, code, at, from, to, reasons, quotePrice, confidence
    }

    init(id: UUID = UUID(), planID: UUID, code: String = "", at: Date,
         from: TriggerState, to: TriggerState,
         reasons: [String], quotePrice: Double?, confidence: Int) {
        self.id = id
        self.planID = planID
        self.code = code
        self.at = at
        self.from = from
        self.to = to
        self.reasons = reasons
        self.quotePrice = quotePrice
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        planID = try c.decode(UUID.self, forKey: .planID)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        at = try c.decode(Date.self, forKey: .at)
        from = try c.decodeIfPresent(TriggerState.self, forKey: .from) ?? .waiting
        to = try c.decode(TriggerState.self, forKey: .to)
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        quotePrice = try c.decodeIfPresent(Double.self, forKey: .quotePrice)
        confidence = try c.decodeIfPresent(Int.self, forKey: .confidence) ?? 0
    }
}

enum TriggerMonitorEngine {
    static func normalizedCode(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["sh", "sz", "bj"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }

    /// 一次刷新评估全部活跃计划。返回新的计划数组与本次新增的状态变更事件。
    static func evaluate(plans: [TriggerPlan],
                         quotes: [Quote],
                         session: MarketSessionStatus,
                         regime: MarketRegimeAssessment?,
                         now: Date = Date(),
                         maxQuoteAge: TimeInterval = 120) -> (plans: [TriggerPlan], events: [TriggerEvent]) {
        var updated: [TriggerPlan] = []
        var events: [TriggerEvent] = []
        for plan in plans {
            var next = plan
            guard plan.isActive else { updated.append(plan); continue }
            if session != .continuous {
                next.lastReasons = ["market_not_in_continuous_session"]
                next.lastEvaluatedAt = now
                updated.append(next)
                continue
            }
            guard let quote = quotes.first(where: { normalizedCode($0.code) == plan.candidate.code }) else {
                next.lastReasons = ["quote_missing_for_plan"]
                next.lastEvaluatedAt = now
                updated.append(next)
                continue
            }
            let stamp = quote.updatedAt ?? quote.fetchedAt
            if let stamp, let previous = plan.previousQuoteTimestamp, stamp <= previous {
                next.lastReasons = ["duplicate_or_out_of_order_quote_ignored"]
                updated.append(next)
                continue
            }
            if let stamp, stamp > now {
                next.lastReasons = ["quote_timestamp_in_future"]
                updated.append(next)
                continue
            }
            let assessment = RealtimeTrigger.evaluate(plan: plan.candidate, quote: quote,
                                                      previous: plan.state, session: session,
                                                      regime: regime, now: now,
                                                      maxQuoteAge: maxQuoteAge)
            let from = plan.state
            var to = assessment.state
            var reasons = assessment.reasons
            // 触发是一次事件；用户没复核前，价格离开区间不能把事件抹掉。
            if from == .triggered && to != .triggered {
                to = .triggered
                reasons.append("trigger_latched_awaiting_user_review")
            }
            if to == .expired || to == .invalidated { next.isActive = false }
            next.state = to
            next.lastReasons = reasons
            next.lastEvaluatedAt = now
            next.signalScore = assessment.signalScore
            next.confidence = assessment.confidence
            next.lastQuotePrice = quote.price
            if let stamp {
                next.previousQuoteTimestamp = max(plan.previousQuoteTimestamp ?? stamp, stamp)
            }
            if to != from && !isOperationalNoise(to) {
                events.append(TriggerEvent(planID: plan.id, code: plan.candidate.code,
                                            at: now, from: from, to: to,
                                            reasons: reasons, quotePrice: quote.price,
                                            confidence: assessment.confidence))
            }
            updated.append(next)
        }
        return (updated, events)
    }

    /// 报价过期 / 休市 / 暂停属于运行态抖动，只更新原因、不写事件，避免刷屏。
    private static func isOperationalNoise(_ state: TriggerState) -> Bool {
        switch state {
        case .quoteStale, .sessionClosed, .paused: return true
        default: return false
        }
    }
}
