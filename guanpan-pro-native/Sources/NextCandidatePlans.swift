import Foundation

// MARK: - AI 候选交易计划（建议，不是虚拟订单）

/// 计划只是「可以手工挂出的价格和份额」。未成交前：
/// 不改变持仓、不改变现金、不产生虚拟收益、不生成模拟持仓。
enum NextPlanKind: String, Codable, Equatable {
    case reverseT = "反T卖出"
    case forwardT = "正T买入"
    case gridBuy = "网格买入"
    case gridSell = "网格卖出"
    case waitBuy = "等回调观察"

    var side: String {
        switch self {
        case .reverseT, .gridSell: return "sell"
        case .forwardT, .gridBuy, .waitBuy: return "buy"
        }
    }
    var isSell: Bool { side == "sell" }
}

enum NextPlanState: String, Codable, Equatable {
    case active = "待观察"
    case triggered = "价格已触及"
    case partiallyConfirmed = "部分真实成交"
    case confirmed = "已成交确认"
    case expired = "已过期"
    case invalidated = "建议作废"
    case withdrawn = "已取消"

    var isOpen: Bool { self == .active || self == .triggered || self == .partiallyConfirmed }
}

struct NextCandidatePlan: Codable, Identifiable, Equatable {
    var id = UUID()
    let kind: NextPlanKind
    let code: String
    let name: String
    let limitPrice: Decimal
    let units: Int
    let createdAt: Date
    let expiresAt: Date
    /// 触发条件与取消条件必须写清楚，不能只有一个价格。
    let triggerNote: String
    let cancelNote: String
    var state: NextPlanState = .active
    var stateChangedAt: Date?
    var triggeredAt: Date?
    var confirmedAt: Date?
    // 生成时的数据依据（复盘与「判断为什么变了」用）
    let quoteSource: String
    let quoteTime: Date?
    let dailyBarCount: Int
    let minuteSampleCount: Int
    let confidenceLevel: String
    let rationale: String
    let expectedNetGain: Decimal?
    let expectedCostReduction: Decimal?
    let riskNote: String
    let marketState: String
    /// 行情突破这些边界时建议作废（趋势/区间失效）。
    let cancelAbove: Decimal?
    let cancelBelow: Decimal?
    /// 用户是否看过这条建议（画像里「看了没做」与「没看到」必须分开）。
    var viewedAt: Date? = nil
    /// 一键反馈：只放六个粗选项，画像学习直接吃这条信号。
    var feedback: NextPlanFeedback? = nil
    /// 真实成交时填写的价格/份额：与建议值不同即说明 AI 报价口径需要校正。
    var confirmedPrice: Decimal? = nil
    var confirmedUnits: Int? = nil
    var confirmedFee: Decimal? = nil
    /// Links this hand-traded candidate to the immutable evidence snapshot that produced it.
    /// Optional so older locally saved candidate plans remain decodable.
    var decisionMemoryID: UUID? = nil
    var remainingUnits: Int { max(0, units - (confirmedUnits ?? 0)) }
    /// Actual fills must remain recordable after a plan expires or is withdrawn:
    /// the plan is advisory, while the broker-confirmed trade is an account fact.
    var canConfirmRealFill: Bool { remainingUnits > 0 }

    var priceWasEdited: Bool {
        guard let confirmedPrice else { return false }
        return abs(confirmedPrice - limitPrice) > (Decimal(string: "0.0005") ?? 0)
    }
    var unitsWereEdited: Bool {
        guard state == .confirmed, let confirmedUnits else { return false }
        return confirmedUnits != units
    }

    func validate() throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), !name.isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              limitPrice > 0, !limitPrice.isNaN, units > 0, units <= 100_000_000,
              expiresAt > createdAt, expiresAt.timeIntervalSince1970.isFinite,
              NextLedgerTimestamp.isPlausible(createdAt),
              dailyBarCount >= 0, minuteSampleCount >= 0,
              !triggerNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cancelNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !quoteSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !confidenceLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !marketState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cancelAbove.map({ !$0.isNaN && $0 > 0 }) ?? true,
              cancelBelow.map({ !$0.isNaN && $0 > 0 }) ?? true,
              cancelAbove.map({ above in cancelBelow.map({ above > $0 }) ?? true }) ?? true,
              expectedNetGain.map({ !$0.isNaN }) ?? true,
              expectedCostReduction.map({ !$0.isNaN }) ?? true,
              quoteTime.map({ NextLedgerTimestamp.isPlausible($0) }) ?? true,
              stateChangedAt.map({ NextLedgerTimestamp.isPlausible($0) && $0 >= createdAt }) ?? true,
              triggeredAt.map({ NextLedgerTimestamp.isPlausible($0) && $0 >= createdAt && $0 <= expiresAt }) ?? true,
              viewedAt.map({ NextLedgerTimestamp.isPlausible($0) && $0 >= createdAt }) ?? true,
              confirmedAt.map({ NextLedgerTimestamp.isPlausible($0) && $0 >= createdAt }) ?? true,
              confirmedUnits.map({ $0 > 0 }) ?? true,
              confirmedPrice.map({ !$0.isNaN && $0 > 0 }) ?? true,
              confirmedFee.map({ !$0.isNaN && $0 >= 0 }) ?? true,
              feedback.map({ NextLedgerTimestamp.isPlausible($0.createdAt) && $0.createdAt >= createdAt }) ?? true else {
            throw NextError.invalid("候选计划的证券、价格、份额或有效期无效")
        }
        let hasConfirmation = confirmedUnits != nil || confirmedPrice != nil || confirmedFee != nil || confirmedAt != nil
        guard !hasConfirmation || (confirmedUnits != nil && confirmedPrice != nil && confirmedFee != nil && confirmedAt != nil) else {
            throw NextError.invalid("候选计划的真实成交回填字段不完整")
        }
    }

    /// 只更新候选计划的真实成交反馈；账本写入由调用方在校验通过后单独提交。
    mutating func confirmRealFill(price: Decimal, units filledUnits: Int, fee: Decimal,
                                  at tradedAt: Date, now: Date) throws {
        let wasOpen = state.isOpen
        guard canConfirmRealFill, filledUnits > 0, filledUnits <= remainingUnits,
              price > 0, !price.isNaN, fee >= 0, !fee.isNaN,
              tradedAt.timeIntervalSince1970.isFinite,
              tradedAt >= createdAt, tradedAt <= now.addingTimeInterval(60) else {
            throw NextError.invalid("候选计划已结束，或本次成交价、手续费、时间及剩余份额无效")
        }
        let previousUnits = confirmedUnits ?? 0
        let totalUnits = previousUnits + filledUnits
        let previousPrice = confirmedPrice ?? price
        confirmedPrice = (previousPrice * Decimal(previousUnits) + price * Decimal(filledUnits)) / Decimal(totalUnits)
        confirmedUnits = totalUnits
        confirmedFee = (confirmedFee ?? 0) + fee
        confirmedAt = tradedAt
        if totalUnits == units {
            state = .confirmed
            stateChangedAt = now
        } else if wasOpen {
            state = .partiallyConfirmed
            stateChangedAt = now
        }
    }

    /// Rebuild plan progress from real ledger fills after an interrupted multi-file save.
    /// The ledger is the account source of truth; this never creates or changes a fill.
    func hasValidLedgerFillEvidence(_ fills: [NextFill], now: Date = Date()) -> Bool {
        let linked = fills.filter { $0.candidatePlanID == id }
        return !linked.isEmpty && Set(linked.map(\.id)).count == linked.count && linked.allSatisfy {
            $0.code == code && $0.side == kind.side && $0.units > 0
                && $0.price > 0 && !$0.price.isNaN && $0.fee >= 0 && !$0.fee.isNaN
                && $0.date >= createdAt && $0.date <= now.addingTimeInterval(60)
                && $0.date.timeIntervalSince1970.isFinite
        }
    }

    @discardableResult
    mutating func reconcileLedgerFills(_ fills: [NextFill]) -> Bool {
        let linked = fills.filter { $0.candidatePlanID == id }
        guard hasValidLedgerFillEvidence(fills) else { return false }

        var totalUnits = 0
        var weightedValue: Decimal = 0
        var totalFee: Decimal = 0
        var latestFill: Date?
        for fill in linked {
            let (nextUnits, overflow) = totalUnits.addingReportingOverflow(fill.units)
            guard !overflow else { return false }
            totalUnits = nextUnits
            weightedValue += fill.price * Decimal(fill.units)
            totalFee += fill.fee
            latestFill = max(latestFill ?? fill.date, fill.date)
        }
        guard totalUnits > 0, let latestFill else { return false }

        let averagePrice = weightedValue / Decimal(totalUnits)
        guard averagePrice > 0, !averagePrice.isNaN, totalFee >= 0, !totalFee.isNaN else { return false }
        let nextState: NextPlanState = totalUnits >= units ? .confirmed : (state.isOpen ? .partiallyConfirmed : state)
        let nextStateChangedAt = nextState == state ? stateChangedAt : latestFill
        let changed = confirmedUnits != totalUnits || confirmedPrice != averagePrice || confirmedFee != totalFee
            || confirmedAt != latestFill || state != nextState || stateChangedAt != nextStateChangedAt
        guard changed else { return false }
        confirmedUnits = totalUnits
        confirmedPrice = averagePrice
        confirmedFee = totalFee
        confirmedAt = latestFill
        state = nextState
        stateChangedAt = nextStateChangedAt
        return true
    }

    mutating func invalidate(reason: String, at now: Date) -> String? {
        guard state.isOpen else { return nil }
        state = .invalidated
        stateChangedAt = now
        let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty
            ? "\(name) 的重大事件使原计划失效，请重新分析"
            : "\(name) 的重大事件使原计划失效：\(detail)"
    }

    /// 状态迁移（只前进，不回退）：
    /// 过期 → 行情过期/价格突破作废边界 → 价格触及 → 等待用户确认成交。
    /// 返回值是给用户看的变更说明；无变化返回 nil。
    mutating func refresh(quote: NextQuote?, now: Date) -> String? {
        guard state.isOpen else { return nil }
        if now > expiresAt {
            state = .expired; stateChangedAt = now
            return "\(name) 的计划已过有效期，建议作废，重新分析后再决定"
        }
        guard let quote else {
            state = .invalidated; stateChangedAt = now
            return "\(name) 当前没有可核验行情，原计划自动作废；行情恢复后请重新分析"
        }
        guard quote.code == code else {
            state = .invalidated; stateChangedAt = now
            return "\(name) 收到的行情证券代码不匹配，原计划自动作废，避免误按其他证券价格操作"
        }
        guard quote.price > 0, !quote.price.isNaN else {
            state = .invalidated; stateChangedAt = now
            return "\(name) 的行情价格无效，原计划自动作废；请刷新行情后重新分析"
        }
        guard quote.hasReliableMarketTime else {
            state = .invalidated; stateChangedAt = now
            return "\(name) 的行情没有可核验的供应商时间，原计划自动作废；请使用带来源时间的行情重新分析"
        }
        if quote.time > now {
            state = .invalidated; stateChangedAt = now
            return "\(name) 的行情时间戳晚于当前时间，数据时钟异常，原计划自动作废"
        }
        if let age = quoteAge(quote, now), age > 120 {
            state = .invalidated; stateChangedAt = now
            return "\(name) 的行情已 \(age / 60) 分钟未更新，原计划自动作废，避免按旧价格挂单"
        }
        if let cancelAbove, quote.price > cancelAbove {
            state = .invalidated; stateChangedAt = now
            return "\(name) 已涨过作废线 ¥\(NextMoney.text(cancelAbove, digits: 3))，做T前提消失，计划自动作废"
        }
        if let cancelBelow, quote.price < cancelBelow {
            state = .invalidated; stateChangedAt = now
            return "\(name) 已跌破作废线 ¥\(NextMoney.text(cancelBelow, digits: 3))，区间失效，计划自动作废"
        }
        guard state == .active else { return nil }
        let hit = kind.isSell ? quote.price >= limitPrice : quote.price <= limitPrice
        if hit {
            state = .triggered; triggeredAt = now; stateChangedAt = now
            return "\(name) 现价 ¥\(NextMoney.text(quote.price, digits: 3)) 已触及计划价 ¥\(NextMoney.text(limitPrice, digits: 3))，请自行决定是否在券商挂单"
        }
        return nil
    }

    private func quoteAge(_ quote: NextQuote, _ now: Date) -> Int? {
        guard quote.time <= now else { return nil }
        return Int(now.timeIntervalSince(quote.time))
    }
}

enum NextCandidatePlanNewsGuard {
    /// Fresh major events withdraw an existing advisory plan.
    /// This rule never records a trade or changes the real ledger.
    static func invalidationReason(for plan: NextCandidatePlan, headlines: [NextNewsInput],
                                   now: Date) -> String? {
        let impact = NextNewsImpactEngine.evaluate(
            code: plan.code, name: plan.name, titles: headlines,
            hasTPlan: plan.kind == .reverseT || plan.kind == .forwardT,
            hasGridPlan: plan.kind == .gridBuy || plan.kind == .gridSell,
            now: now)
        guard impact.action.blocksPlan else { return nil }
        return impact.reasons.joined(separator: "；")
    }
}

/// Cross-market research is deliberately allowed to *remove* a stale plan, never
/// to create one.  This is a Risk Guard, not a second strategy engine: a live
/// divergence must have passed prospective replication on NAS and still be fresh
/// before it can pause an otherwise rule-engine-generated candidate plan.
enum NextCrossMarketRiskGuard {
    static func blockingReason(evidence: NextNASResearch.CrossMarketEvidence?, now: Date) -> String? {
        guard let evidence,
              evidence.eligibleForTradingSignal == true,
              evidence.validationState == "prospectively_replicated",
              evidence.currentMarketStatus == "open" else { return nil }
        guard let divergence = evidence.liveDivergences?.first(where: {
            $0.state == "observed_divergence" && $0.eligibleForTradingSignal == true && $0.isFresh(at: now)
        }) else { return nil }
        return "已通过预注册未来复现的 \(divergence.market) 跨市场观察出现新鲜背离；只暂停原候选计划并重新评估，不据此生成买卖价格"
    }

    static func apply(evidence: NextNASResearch.CrossMarketEvidence?, to item: NextGuidanceItem,
                      now: Date) -> NextGuidanceItem {
        guard let reason = blockingReason(evidence: evidence, now: now) else { return item }
        let tPlan: NextTPlannerResult? = item.tPlan?.isReady == true
            ? .notWorthwhile([reason]) : item.tPlan
        let gridPlan: NextGridPlannerResult? = item.gridPlan?.isReady == true
            ? .notRecommended([reason]) : item.gridPlan
        return NextGuidanceItem(code: item.code, name: item.name, state: item.state,
                                strategy: item.strategy, headline: "跨市场风险复核",
                                whyToday: item.whyToday + [reason], tPlan: tPlan, gridPlan: gridPlan,
                                recovery: item.recovery, confidence: item.confidence,
                                portfolioNote: item.portfolioNote,
                                riskNotes: item.riskNotes + [reason], score: item.score - 3,
                                rank: item.rank, isActionable: false,
                                profileNote: item.profileNote, newsImpact: item.newsImpact)
    }
}

// MARK: - 机会扫描：每天主动告诉「今天有没有值得操作的机会」

struct NextGuidanceItem: Equatable, Identifiable {
    var id: String { code }
    let code: String
    let name: String
    let state: NextMarketState
    let strategy: NextStrategyKind
    let headline: String
    let whyToday: [String]
    let tPlan: NextTPlannerResult?
    let gridPlan: NextGridPlannerResult?
    let recovery: NextRecoveryReading?
    let confidence: NextDataConfidence
    let portfolioNote: String?
    let riskNotes: [String]
    let score: Double
    let rank: Int
    let isActionable: Bool
    /// 画像对排序的影响说明：只在「因为你的习惯被降级/加优先」时出现。
    var profileNote: String? = nil
    /// 新闻对这只持仓当前计划的作用：没有相关新闻就是 nil，不塞空对象。
    var newsImpact: NextNewsImpact? = nil
}

struct NextDailyGuidance: Equatable {
    let generatedAt: Date
    let items: [NextGuidanceItem]
    let summary: String
    let noActionSummary: String
    let dataState: String

    var actionableItems: [NextGuidanceItem] { items.filter(\.isActionable) }
}

enum NextPortfolioRiskGuard {
    /// A grid contains buy tiers; it cannot remain actionable after the account
    /// concentration cap has been breached.
    static func apply(overweightNote: String?, to result: NextGridPlannerResult) -> NextGridPlannerResult {
        guard let overweightNote, case .ready = result else { return result }
        return .notRecommended([overweightNote, "组合上限优先于单只ETF的网格机会；先降低集中度或调整目标，再重新评估"])
    }

    /// Cash allocations are portfolio constraints, not explanatory AI prompt text.
    /// Check the worst case where every planned buy tier fills and no sell tier fills.
    static func cashReserveBlock(availableCash: Decimal, totalAssets: Decimal?,
                                 targetCashPercent: Decimal?, requiredCash: Decimal) -> String? {
        guard !requiredCash.isNaN, !availableCash.isNaN,
              requiredCash >= 0, availableCash >= 0 else {
            return "现金或买入资金需求无效；暂停新增买入计划"
        }
        guard requiredCash <= availableCash else {
            return "该买入计划需要 ¥\(NextMoney.text(requiredCash))，超过当前真实可用现金 ¥\(NextMoney.text(availableCash))；暂停新增买入计划"
        }
        guard let targetCashPercent else { return nil }
        guard !targetCashPercent.isNaN, targetCashPercent >= 0, targetCashPercent <= 100,
              let totalAssets, !totalAssets.isNaN, totalAssets > 0 else {
            return "现金储备目标或组合总资产无法核验；暂停新增买入计划"
        }
        let reserve = totalAssets * targetCashPercent / 100
        guard !reserve.isNaN else {
            return "现金储备计算结果无效；暂停新增买入计划"
        }
        let spendable = max(Decimal.zero, availableCash - reserve)
        guard !spendable.isNaN else {
            return "现金储备计算结果无效；暂停新增买入计划"
        }
        guard requiredCash <= spendable else {
            return "该买入计划最坏占用 ¥\(NextMoney.text(requiredCash))，超过现金扣除长期储备目标后的可用额 ¥\(NextMoney.text(spendable))；保留至少 ¥\(NextMoney.text(reserve)) 现金，暂停新增买入计划"
        }
        return nil
    }

    static func applyCashReserve(availableCash: Decimal, totalAssets: Decimal?,
                                 targetCashPercent: Decimal?, to result: NextGridPlannerResult) -> NextGridPlannerResult {
        guard case let .ready(plan) = result,
              let reason = cashReserveBlock(availableCash: availableCash, totalAssets: totalAssets,
                                            targetCashPercent: targetCashPercent,
                                            requiredCash: plan.maxCashUsage) else { return result }
        return .notRecommended([reason])
    }

    static func applyCashReserve(availableCash: Decimal, totalAssets: Decimal?,
                                 targetCashPercent: Decimal?, to result: NextTPlannerResult) -> NextTPlannerResult {
        guard case let .ready(plan) = result, plan.kind == .forward else { return result }
        let required = plan.buyPrice * Decimal(plan.units) + plan.feeTotal / 2
        guard let reason = cashReserveBlock(availableCash: availableCash, totalAssets: totalAssets,
                                            targetCashPercent: targetCashPercent,
                                            requiredCash: required) else { return result }
        return .notWorthwhile([reason])
    }

    static func currentPlanQuoteBlock(for plan: NextCandidatePlan, quote: NextQuote?, now: Date) -> String? {
        guard let quote, quote.code == plan.code, quote.isFreshForPricePlan(at: now) else {
            return "当前行情缺失、过期或来源时间不可核验，请刷新行情后重新保存计划"
        }
        if let cancelAbove = plan.cancelAbove, quote.price > cancelAbove {
            return "现价已越过候选计划上方失效线 ¥\(NextMoney.text(cancelAbove, digits: 3))，请重新分析"
        }
        if let cancelBelow = plan.cancelBelow, quote.price < cancelBelow {
            return "现价已越过候选计划下方失效线 ¥\(NextMoney.text(cancelBelow, digits: 3))，请重新分析"
        }
        return nil
    }

    static func candidateSaveBlock(for item: NextGuidanceItem, guidanceGeneratedAt: Date?,
                                   guidanceLedgerFingerprint: String?, currentLedgerFingerprint: String?,
                                   quote: NextQuote?, now: Date) -> String? {
        guard item.isActionable else {
            let reason = ([item.portfolioNote].compactMap { $0 } + item.riskNotes).first
            return reason.map { "最终指导已拦截该候选计划：\($0)" } ?? "最终指导当前不允许保存交易候选计划"
        }
        guard let guidanceGeneratedAt, guidanceGeneratedAt <= now,
              now.timeIntervalSince(guidanceGeneratedAt) <= 120 else {
            return "今日指导已过期或缺少生成时间，请刷新整个持仓决策后再保存"
        }
        guard let guidanceLedgerFingerprint, let currentLedgerFingerprint,
              guidanceLedgerFingerprint == currentLedgerFingerprint else {
            return "真实持仓、现金或成交流水在生成指导后已变化；请刷新指导，不能保存旧账户状态下的计划"
        }

        let expiry: Date
        let hasEnoughData: Bool
        if let result = item.tPlan, case let .ready(plan) = result {
            guard plan.code == item.code else { return "指导证券与做T计划证券不一致，已拒绝保存" }
            expiry = plan.validUntil
            hasEnoughData = plan.confidence.canPriceTPlan
        } else if let result = item.gridPlan, case let .ready(plan) = result {
            guard plan.code == item.code else { return "指导证券与网格计划证券不一致，已拒绝保存" }
            expiry = plan.validUntil
            hasEnoughData = plan.confidence.canPriceGridPlan
        } else {
            return "最终指导没有可保存的具体价格计划"
        }
        guard hasEnoughData else { return "生成计划时的数据置信度已不足，不能保存具体挂单建议" }
        guard expiry > now else { return "候选计划已过有效期，请刷新行情并重新分析" }
        guard NextMarketClock.canGenerateActionablePlan(now) else {
            return "当前不在已核验的A股交易时段，不能保存为当日可执行候选计划"
        }
        guard let quote, quote.code == item.code, quote.isFreshForPricePlan(at: now) else {
            return "当前行情缺失、过期或来源时间不可核验，请刷新行情后重新分析"
        }
        return nil
    }

    static func allocationAssessment(currentPercent: Double, concentrationLimit: Double,
                                     targetPercent: Double?) -> (blockingNote: String?, context: String?, priorityBoost: Double) {
        guard currentPercent.isFinite, concentrationLimit.isFinite,
              currentPercent >= 0, concentrationLimit > 0 else {
            return ("组合风险比例无法可靠计算；暂停新增买入计划", nil, 0)
        }
        if currentPercent > concentrationLimit {
            return ("该只占比 \(String(format: "%.1f", currentPercent))%，超过你设置的 \(String(format: "%.1f", concentrationLimit))% 组合上限", nil, 0)
        }
        guard let targetPercent, targetPercent.isFinite, targetPercent >= 0, targetPercent <= 100 else {
            // No configured target means no allocation preference signal.
            return (nil, nil, 0)
        }
        let gap = targetPercent - currentPercent
        if gap >= 0.5 {
            return (nil, "当前占比 \(String(format: "%.1f", currentPercent))%，低于你设定的目标 \(String(format: "%.1f", targetPercent))%（差 \(String(format: "%.1f", gap)) 个百分点）；仅作长期配置排序参考，仍须通过行情、资金和交易风险检查", min(1.5, gap * 0.05))
        }
        if gap <= -0.5 {
            return ("当前占比 \(String(format: "%.1f", currentPercent))%，已高于你设定的目标权重 \(String(format: "%.1f", targetPercent))%；暂停新增买入计划", nil, 0)
        }
        return (nil, "当前占比接近你设定的目标权重 \(String(format: "%.1f", targetPercent))%", 0)
    }
}

enum NextOpportunityScanner {
    /// 扫描全部真实持仓，按「成功概率 × 风险 × 流动性 × 成本 × 数据可信度」排序。
    /// 不预测涨跌；不交易是正常结论。
    static func scan(book: NextBook, quotes: [String: NextQuote], daily: [String: [NextChartSample]],
                     intraday: [String: [NextChartSample]], rules: [String: NextInstrumentRules],
                     orderBooks: [String: NextOrderBookSnapshot] = [:],
                     goal: NextGoal, nasConfigured: Bool = false, nasReachable: Bool? = nil,
                     nasProbedAt: Date? = nil, profile: NextInvestorProfile? = nil,
                     research: [String: NextNASResearch] = [:],
                     news: [String: [NextNewsInput]] = [:],
                     now: Date) -> NextDailyGuidance {
        let matchingQuotes = quotes.reduce(into: [String: NextQuote]()) { result, pair in
            if pair.key == pair.value.code { result[pair.key] = pair.value }
        }
        let total = book.total(using: matchingQuotes)
        let heldPositions = book.positions.filter { $0.units > 0 }
        let portfolioValuationReliable = !heldPositions.isEmpty && heldPositions.allSatisfy { position in
            guard let quote = matchingQuotes[position.code] else { return false }
            return quote.code == position.code && quote.isFreshForPricePlan(at: now)
        }
        let reliablePortfolioQuotes = portfolioValuationReliable ? matchingQuotes : [:]
        var items: [NextGuidanceItem] = []

        for position in book.positions where position.units > 0 {
            let quote = matchingQuotes[position.code]
            // A provider's future-dated bar must not affect strategy selection, confidence, or plans.
            let bars = (daily[position.code] ?? []).filter { $0.close > 0 && $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp }
            let minutes = (intraday[position.code] ?? []).filter { $0.close > 0 && $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp }
            let reading = NextMarketStateEngine.classify(daily: bars, intraday: minutes, quote: quote, now: now)
            let gridCheck = NextGridCheckEngine.evaluate(code: position.code, name: position.name, samples: bars,
                                                         isOnExchange: NextDividendRules.isOnExchangeETF(position.code))
            let stats = NextIntradayStatsEngine.compute(samples: minutes, previousClose: quote?.previousClose)
            let oscillating = stats.vwapCrossings >= 2 && (stats.amplitudePercent ?? 0) >= 0.8
            var strategy = NextStrategySelector.select(state: reading, grid: gridCheck, hasPosition: true,
                                                       oscillating: oscillating, now: now)
            // NAS 长期统计：在场才有，没有就是没有。它参与「网格区间收敛」和「置信度降档」，
            // 但绝不改写行情事实，也绝不替本地算价格。
            let nasStats = research[position.code]?.minuteStats
            let nasRange = NextNasRange(stats: nasStats)
            var nasNotes: [String] = []
            if let stats = nasStats {
                if let w20 = stats.window(20), let deviation = w20.closeVsVwapPercent {
                    nasNotes.append("NAS 20 日 VWAP ¥\(w20.vwap)，现价偏离 \(String(format: "%+.2f", deviation))%（\(w20.daysUsed) 天 · \(Int((w20.minuteCoverage * 100).rounded()))% 分钟覆盖）")
                }
                if let w60 = stats.window(60), let amplitude = w60.amplitudeMedianPercent,
                   let trips = w60.roundTripsMedian {
                    nasNotes.append("NAS 60 日日内振幅中位数 \(String(format: "%.2f", amplitude))%、日均往返 \(String(format: "%.1f", trips)) 次")
                }
                if let w120 = stats.window(120), let volatility = w120.volatilityPercent {
                    nasNotes.append("NAS 120 日波动率 \(String(format: "%.2f", volatility))%")
                }
                if !stats.quality.enoughForLongTerm {
                    nasNotes.append("NAS 分时归档仅 \(stats.days) 天 / 覆盖 \(Int((stats.quality.minuteCoverage * 100).rounded()))%，还不足以支撑长期结论")
                }
            }
            var confidence = NextDataConfidence.assess(quote: quote, now: now, dailyBarCount: bars.count,
                                                       minuteSampleCount: minutes.filter { $0.close > 0 }.count,
                                                       intradayLatestAt: minutes.filter { $0.close > 0 }.map(\.timestamp).max(),
                                                       dailyLatestAt: bars.map(\.timestamp).max())
            if let stats = nasStats, stats.freshness.stale {
                confidence = confidence.downgraded("NAS 长期分时已过期：\(stats.freshness.reason ?? "最后一天 \(stats.lastDay ?? "未知")")")
            }

            // 组合级判断：单只超配时，价格再好也只能观察。
            var portfolioNote: String?
            var allocationContext: String?
            var allocationPriority = 0.0
            if !portfolioValuationReliable {
                portfolioNote = "组合内并非所有真实持仓都有新鲜且带来源时间的行情；组合权重无法核验，暂停新增买入计划"
            } else if let quote, let total, total > 0 {
                let weight = NextNum.double(quote.price * Decimal(position.units) / total * 100)
                let assessment = NextPortfolioRiskGuard.allocationAssessment(
                    currentPercent: weight,
                    concentrationLimit: NextNum.double(goal.concentrationLimit),
                    targetPercent: goal.targetWeights[position.code].map { NextNum.double($0) })
                portfolioNote = assessment.blockingNote
                allocationContext = assessment.context
                allocationPriority = assessment.priorityBoost
            }

            var tPlan: NextTPlannerResult?
            var gridPlan: NextGridPlannerResult?
            var riskNotes: [String] = []
            var headline = strategy.kind.rawValue
            // 画像上限与 NAS 长期统计一起进计划：这是硬约束，不是提示。
            let caps = NextPlanCaps.make(profile: profile, nasStats: nasStats, book: book,
                                         code: position.code,
                                         lotSize: rules[position.code]?.lotSize ?? 100, now: now)
            let tacticalRoleNote = caps.tacticalTradingBlockReason
            if let reason = tacticalRoleNote, (strategy.kind == .tTrade || strategy.kind == .grid) {
                strategy = NextStrategyReading(kind: .hold,
                    reasons: strategy.reasons + [reason],
                    warnings: strategy.warnings + ["长期核心仓身份优先于短期震荡信号"],
                    referencePrice: nil)
            }
            headline = strategy.kind.rawValue

            switch strategy.kind {
            case .tTrade:
                var result = NextTradeTPlanner.plan(kind: .reverse, book: book, quote: quote, daily: bars,
                                                    intraday: minutes, rules: rules[position.code],
                                                    orderBook: orderBooks[position.code],
                                                    caps: caps, now: now)
                if case let .insufficientData(_, reasons) = result {
                    // 反T做不了（如可卖份额不足）时，尝试正T。
                    let forward = NextTradeTPlanner.plan(kind: .forward, book: book, quote: quote, daily: bars,
                                                         intraday: minutes, rules: rules[position.code],
                                                         orderBook: orderBooks[position.code],
                                                         caps: caps, now: now)
                    if case .ready = forward {
                        result = forward
                        headline = NextTKind.forward.rawValue
                    } else {
                        riskNotes.append(contentsOf: reasons)
                    }
                }
                let reserveChecked = NextPortfolioRiskGuard.applyCashReserve(availableCash: book.cash,
                    totalAssets: total, targetCashPercent: goal.targetCashPercent, to: result)
                if case let .notWorthwhile(reasons) = reserveChecked, case .ready = result {
                    portfolioNote = reasons.first
                    headline = "现金储备约束 · 暂停正T"
                }
                result = reserveChecked
                tPlan = result
                if case let .ready(plan) = result {
                    headline = plan.kind.rawValue
                    riskNotes.append(plan.trampleRisk)
                    riskNotes.append(plan.continuedDropRisk)
                    if portfolioNote != nil {
                        riskNotes.append("组合仓位已超上限：正T的买入腿不建议执行")
                    }
                }
            case .grid:
                let calculated = NextGridPlanner.plan(book: book, quote: quote, daily: bars, gridCheck: gridCheck,
                                                      rules: rules[position.code], nasRange: nasRange,
                                                      orderBook: orderBooks[position.code],
                                                      caps: caps, now: now)
                var result = NextPortfolioRiskGuard.apply(overweightNote: portfolioNote, to: calculated)
                if portfolioNote == nil {
                    let reserveChecked = NextPortfolioRiskGuard.applyCashReserve(availableCash: book.cash,
                        totalAssets: total, targetCashPercent: goal.targetCashPercent, to: result)
                    if case let .notRecommended(reasons) = reserveChecked, case .ready = result {
                        portfolioNote = reasons.first
                    }
                    result = reserveChecked
                }
                gridPlan = result
                if case let .ready(plan) = result {
                    headline = "网格 · \(plan.tiers.count) 档 / 间距 \(String(format: "%.2f", plan.spacingPercent))%"
                } else if portfolioNote != nil {
                    headline = "组合风险约束 · 暂停网格"
                }
            case .hold, .waitBuy, .pauseAdd, .reduce, .noTrade:
                break
            }

            var tNetGain: Decimal?
            if let tPlan, case let .ready(plan) = tPlan { tNetGain = plan.netGain }
            let recovery = NextRecoveryAnalyzer.analyze(book: book, quotes: reliablePortfolioQuotes,
                                                        quote: quote, rules: rules[position.code],
                                                        goal: goal, tNetGain: tNetGain, now: now)

            var actionable = false
            if let tPlan, case .ready = tPlan, portfolioNote == nil { actionable = true }
            if let gridPlan, case .ready = gridPlan { actionable = true }

            var score = 0.0
            if portfolioNote == nil, let tPlan, case let .ready(plan) = tPlan {
                score += 2.5 + min(3.0, NextNum.double(plan.netGain / Decimal(100)))
            }
            if let gridPlan, case .ready = gridPlan { score += 2.5 }
            score += allocationPriority
            if reading.state == .trendingUp { score += 1.5 }
            if reading.state == .anomalous { score -= 3 }
            if let turnover = gridCheck.avgTurnoverYi, turnover < 0.3 { score -= 2 }
            switch confidence.level {
            case .high: score += 1
            case .medium: break
            case .low: score -= 1
            case .blocked: score -= 3
            }
            if !actionable { score -= 1 }

            var whyToday = reading.reasons + nasNotes
            if let tacticalRoleNote { whyToday.append(tacticalRoleNote) }
            if let allocationContext { whyToday.append(allocationContext) }
            if let rsi = reading.signal?.rsi { whyToday.append("RSI14 \(String(format: "%.1f", rsi))") }
            if oscillating { whyToday.append("今日价格穿越 VWAP \(stats.vwapCrossings) 次，日内反复震荡") }
            if let amplitude = stats.amplitudePercent, amplitude > 0 {
                whyToday.append("今日振幅 \(String(format: "%.2f", amplitude))%")
            }

            // 画像只影响推荐优先级：不改「有没有机会」、不改风险与数据门槛、不改任何价格。
            var profileNote: String?
            if let profile {
                let adjustment = NextProfileEngine.adjustment(tPlan: tPlan, gridPlan: gridPlan,
                                                             isActionable: actionable, profile: profile)
                score *= adjustment.multiplier
                if adjustment.verdict != .neutral { profileNote = adjustment.explanation }
            }
            // 新闻 → 这只真实持仓 → 当前计划：重大事件可以收回计划，但不能凭空造出新计划。
            let impact = NextNewsImpactEngine.evaluate(code: position.code, name: position.name,
                                                       titles: news[position.code] ?? [],
                                                       hasTPlan: tPlan?.isReady == true,
                                                       hasGridPlan: gridPlan?.isReady == true, now: now)
            if impact.action.blocksPlan {
                // 重大事件会在 apply() 里收回计划；这里只降排序，避免它排在最前面。
                score -= 2.5
            }

            let baseItem = NextGuidanceItem(code: position.code, name: position.name, state: reading.state,
                                            strategy: strategy.kind, headline: headline, whyToday: whyToday,
                                            tPlan: tPlan, gridPlan: gridPlan, recovery: recovery,
                                            confidence: confidence, portfolioNote: portfolioNote,
                                            riskNotes: riskNotes + reading.warnings + strategy.warnings,
                                            score: score, rank: 0, isActionable: actionable,
                                            profileNote: profileNote,
                                            newsImpact: impact.isEmpty ? nil : impact)
            let newsApplied = NextNewsImpactEngine.apply(impact, to: baseItem)
            // NAS research may only hard-stop a plan after prospective replication
            // and a fresh explicit live observation.  It can never create a plan.
            items.append(NextCrossMarketRiskGuard.apply(
                evidence: research[position.code]?.crossMarket, to: newsApplied, now: now))
        }

        let sorted = items.sorted { $0.score == $1.score ? $0.code < $1.code : $0.score > $1.score }
        let ranked = sorted.enumerated().map { index, item in
            NextGuidanceItem(code: item.code, name: item.name, state: item.state, strategy: item.strategy,
                             headline: item.headline, whyToday: item.whyToday, tPlan: item.tPlan,
                             gridPlan: item.gridPlan, recovery: item.recovery, confidence: item.confidence,
                             portfolioNote: item.portfolioNote, riskNotes: item.riskNotes, score: item.score,
                             rank: index + 1, isActionable: item.isActionable, profileNote: item.profileNote,
                             newsImpact: item.newsImpact)
        }

        let actionable = ranked.filter(\.isActionable)
        // 有机会但被画像门槛拦下的，必须如实说出来——不能假装今天什么都没发生。
        let heldBack = ranked.filter { $0.isActionable && $0.profileNote != nil }
        let summary: String
        if actionable.isEmpty {
            summary = ranked.isEmpty ? "还没有真实持仓，先录入持仓再生成今日指导。" : "今天不建议交易，继续持有。"
        } else {
            let names = actionable.prefix(3).map { "\($0.name)（\($0.headline)）" }.joined(separator: "、")
            summary = heldBack.isEmpty
                ? "今天有 \(actionable.count) 只值得关注：\(names)"
                : "今天有 \(actionable.count) 只出现机会，其中 \(heldBack.count) 只低于你通常执行的门槛：\(names)"
        }
        let noAction = ranked.filter { !$0.isActionable }.map { "\($0.name)：\($0.strategy.rawValue)" }.joined(separator: "；")
        let held = book.positions.filter { $0.units > 0 }
        let freshQuoteCount = held.filter { position in
            guard let quote = quotes[position.code] else { return false }
            return quote.hasReliableMarketTime && quote.isFresh(at: now)
        }.count
        let quoteState = held.isEmpty
            ? "没有真实持仓"
            : (freshQuoteCount == held.count
                ? "实时行情 \(freshQuoteCount)/\(held.count) 只持仓可核验"
                : "新鲜可核验行情 \(freshQuoteCount)/\(held.count) 只持仓")

        let nasProbeAge = nasProbedAt.map { now.timeIntervalSince($0) }
        let nasProbeRecent = nasProbeAge.map { $0 >= 0 && $0 <= 360 } == true
        let nasOnline = nasConfigured && nasReachable == true && nasProbeRecent
        let nasConfirmedOffline = nasConfigured && nasReachable == false && nasProbeRecent
        let heldResearch = held.compactMap { research[$0.code]?.minuteStats }
        let usableResearchCount = heldResearch.filter {
            !$0.freshness.stale && $0.quality.enoughForLongTerm
        }.count
        let nasState: String
        if !nasConfigured {
            nasState = "NAS 未配置"
        } else if nasOnline {
            if usableResearchCount > 0 {
                nasState = "NAS 在线 · \(usableResearchCount) 只持仓有新鲜长期研究"
            } else if !heldResearch.isEmpty {
                nasState = "NAS 在线，但长期研究已过期或质量不足"
            } else {
                nasState = "NAS 在线，但尚无持仓长期研究数据"
            }
        } else if nasConfirmedOffline && usableResearchCount > 0 {
            nasState = "NAS 当前不可达 · 使用本机缓存的 \(usableResearchCount) 只有效长期研究"
        } else if nasConfirmedOffline && !heldResearch.isEmpty {
            nasState = "NAS 当前不可达 · 本机研究缓存已过期或质量不足"
        } else if nasConfirmedOffline {
            nasState = "NAS 当前不可达 · 长期研究数据缺失"
        } else if usableResearchCount > 0 {
            nasState = "NAS 连接待检测 · 使用本机缓存的 \(usableResearchCount) 只有效长期研究"
        } else if !heldResearch.isEmpty {
            nasState = "NAS 连接待检测 · 本机研究缓存已过期或质量不足"
        } else {
            nasState = "NAS 连接状态待检测 · 长期研究数据缺失"
        }
        let dataState = "\(quoteState) · \(nasState)"

        return NextDailyGuidance(generatedAt: now, items: ranked, summary: summary,
                                 noActionSummary: noAction.isEmpty ? "全部持仓都可以继续持有。" : "不建议操作：" + noAction,
                                 dataState: dataState)
    }
}

// MARK: - 统一决策上下文（一个账户、一份建议）

/// NAS 机会扫描、手机离线规则、在线大模型三方必须先汇入同一份上下文，
/// 最终只允许输出一份综合建议——不允许 NAS 说买、手机说卖。
struct NextDecisionContext: Equatable {
    let generatedAt: Date
    let ledgerFingerprint: String
    let quoteSnapshot: [String: NextQuote]
    let dailyBarsSnapshot: [String: [NextChartSample]]
    let intradayBarsSnapshot: [String: [NextChartSample]]
    let nasResearchSnapshot: [String: NextNASResearch]
    let newsSnapshot: [String: [NextNewsInput]]
    let profileSnapshot: NextInvestorProfile?
    let goalSnapshot: NextGoal?
    let guidance: NextDailyGuidance
    let holdingsLines: [String]
    let portfolioLines: [String]
    let portfolioCorrelationLines: [String]
    let nasResearchLines: [String]
    let crossMarketLines: [String]
    let newsLines: [String]
    /// 本次在线 AI 实际收到的画像结论（可解释性：用户能查「AI 用了哪些画像信息」）。
    let profileLines: [String]
    let promptBlock: String
}

/// An online answer is useful only while the exact account and evidence snapshot
/// used for its prompt is still current. Network latency must not turn old advice
/// into today's guidance after a fill, quote, research, news, or profile update.
enum NextDecisionContextFreshness {
    static func rejectionReason(sent: NextDecisionContext, current: NextDecisionContext,
                                now: Date, maximumAge: TimeInterval = 120) -> String? {
        guard sent.generatedAt <= now, now.timeIntervalSince(sent.generatedAt) <= maximumAge,
              sent.guidance.generatedAt <= now,
              now.timeIntervalSince(sent.guidance.generatedAt) <= maximumAge else {
            return "在线分析返回时，本次决策上下文已超过有效期；请刷新后重新分析"
        }
        guard sent.ledgerFingerprint == current.ledgerFingerprint else {
            return "在线分析期间真实持仓、现金或成交流水发生变化；旧回答已作废，请按新账本重新分析"
        }
        guard sent.quoteSnapshot == current.quoteSnapshot else {
            return "在线分析期间行情发生变化；旧回答已作废，请刷新行情后重新分析"
        }
        guard sent.dailyBarsSnapshot == current.dailyBarsSnapshot,
              sent.intradayBarsSnapshot == current.intradayBarsSnapshot,
              sent.nasResearchSnapshot == current.nasResearchSnapshot,
              sent.newsSnapshot == current.newsSnapshot,
              sent.profileSnapshot == current.profileSnapshot,
              sent.goalSnapshot == current.goalSnapshot else {
            return "在线分析期间日K/分时、NAS研究、新闻或投资画像发生变化；旧回答已作废，请重新分析"
        }
        guard sent.guidance == current.guidance,
              sent.holdingsLines == current.holdingsLines,
              sent.portfolioLines == current.portfolioLines,
              sent.portfolioCorrelationLines == current.portfolioCorrelationLines,
              sent.nasResearchLines == current.nasResearchLines,
              sent.crossMarketLines == current.crossMarketLines,
              sent.newsLines == current.newsLines,
              sent.profileLines == current.profileLines else {
            return "在线分析期间 NAS研究、新闻、画像或规则指导发生变化；旧回答已作废，请重新分析"
        }
        let plansAreCurrent = sent.guidance.items.filter(\.isActionable).allSatisfy { item in
            let tPlanIsCurrent: Bool
            if case let .ready(plan)? = item.tPlan { tPlanIsCurrent = plan.validUntil > now }
            else { tPlanIsCurrent = true }
            let gridPlanIsCurrent: Bool
            if case let .ready(plan)? = item.gridPlan { gridPlanIsCurrent = plan.validUntil > now }
            else { gridPlanIsCurrent = true }
            return tPlanIsCurrent && gridPlanIsCurrent
        }
        guard plansAreCurrent else {
            return "在线分析返回时，候选计划已经到期；旧回答已作废，请刷新后重新分析"
        }
        if sent.guidance.items.contains(where: \.isActionable),
           !NextMarketClock.canGenerateActionablePlan(now) {
            return "在线分析返回时已不在可生成计划的交易时段；旧操作指导已作废"
        }
        return nil
    }
}

/// Online models are explanatory only. Reject actionable price text unless the exact
/// decimal is present in the deterministic rule-engine plan supplied to this call.
enum NextAIOutputGuard {
    private static let actionPricePatterns = [
        #"(?:卖出|买回|买入|卖|买|挂单|限价|建议卖价|建议买价)\s*(?:价)?[^\n。；;]{0,40}?(?:¥|￥)?\s*(\d+\.\d{1,4})"#,
        #"(?:卖出|买回|买入|卖|买|挂单|限价)[^\n。；;]{0,40}?(?:¥|￥)\s*(\d+(?:\.\d{1,4})?)"#,
        #"(?:建议卖价|建议买价|卖出价|买回价|买入价|限价)\s*[:：]?\s*(\d+(?:\.\d{1,4})?)\s*(?:元)?"#,
        #"(\d+\.\d{1,4})\s*(?:元)?\s*(?:卖出|买回|买入|挂单|限价)"#
    ]
    private static let actionUnitPatterns = [
        #"(?:卖出|买回|买入|卖|买|挂单|限价)[^\n。；;]{0,28}?(\d+)\s*(?:份|股)"#,
        #"(\d+)\s*(?:份|股)[^\n。；;]{0,16}?(?:卖出|买回|买入|挂单|限价)"#
    ]
    private static let financialClaimPatterns = [
        #"(?:预计|预估|理论)?(?:净收益|毛收益|收益|毛价差|价差|等效降本|降本|成本降低|手续费|胜率|成功率|触达概率|资金占用|持仓占比|现金占比|回本涨幅)[^\n。；;]{0,20}?(?:¥|￥)?\s*\d+(?:\.\d+)?\s*(?:元|%|倍|/份)?"#,
        #"(?:¥|￥)\s*\d+(?:\.\d+)?\s*(?:元)?[^\n。；;]{0,20}?(?:净收益|毛收益|收益|价差|降本|成本降低|手续费|资金占用)"#,
        #"\d+(?:\.\d+)?\s*(?:元/份|元每份|%|倍)?[^\n。；;]{0,12}?(?:净收益|毛收益|收益|降本|成本降低|手续费|胜率|成功率|触达概率)"#
    ]
    // DecisionContext currently has no verified issuer/fundamental data feed.
    // Reject numeric fundamentals from an LLM until such evidence is explicitly
    // supplied and bound to the same security/context.
    private static let unsupportedFundamentalPatterns = [
        #"(?:市盈率|动态市盈率|静态市盈率|PE\s*\(?(?:TTM)?\)?|P/E)[^\n。；;]{0,12}?\d+(?:\.\d+)?\s*(?:倍)?"#,
        #"(?:市净率|PB\s*\(?(?:MRQ)?\)?|P/B|市销率|PS\s*\(?(?:TTM)?\)?|P/S)[^\n。；;]{0,12}?\d+(?:\.\d+)?\s*(?:倍)?"#,
        #"(?:ROE|ROA|EPS|净资产收益率|资产回报率|每股收益|资产负债率|股息率|分红率)[^\n。；;]{0,12}?\d+(?:\.\d+)?\s*%?"#,
        #"(?:营收|营业收入|净利润|归母净利润|毛利率|净利率|营收增长|利润增长)[^\n。；;]{0,16}?(?:¥|￥)?\s*\d+(?:\.\d+)?\s*(?:亿元|万元|元|%)?"#,
        #"\d+(?:\.\d+)?\s*(?:倍|亿元|万元|元|%)?[^\n。；;]{0,12}?(?:市盈率|动态市盈率|静态市盈率|PE\s*\(?(?:TTM)?\)?|P/E|市净率|PB\s*\(?(?:MRQ)?\)?|P/B|市销率|PS\s*\(?(?:TTM)?\)?|P/S|ROE|ROA|EPS|净资产收益率|资产回报率|每股收益|资产负债率|股息率|分红率|营收|营业收入|净利润|归母净利润|毛利率|净利率)"#
    ]

    /// Numeric financial results belong to deterministic plan/account cards. The
    /// language model may explain them, but must not restate or recalculate them.
    static func containsUnverifiedFinancialClaim(_ text: String) -> Bool {
        for pattern in financialClaimPatterns + unsupportedFundamentalPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return true }
        }
        return false
    }

    static func containsUnverifiedActionPrice(_ text: String, guidance: NextDailyGuidance) -> Bool {
        // Validate each actionable sentence against its own security. A global
        // whitelist would let the model copy ETF A's valid price onto ETF B.
        let actionable = guidance.items.filter(\.isActionable)
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: "。！？；;\n"))
        for sentence in sentences where containsActionMetrics(sentence) {
            let referenced = guidance.items.filter {
                sentence.contains($0.code) || sentence.localizedCaseInsensitiveContains($0.name)
            }
            // An explicit reference to a withdrawn holding cannot borrow another
            // holding's actionable plan, even when the numeric values happen to match.
            guard referenced.allSatisfy(\.isActionable) else { return true }
            let matched = referenced.filter(\.isActionable)
            let item: NextGuidanceItem
            if matched.count == 1 {
                item = matched[0]
            } else if matched.isEmpty, actionable.count == 1, let only = actionable.first {
                // A single actionable holding is unambiguous even if prose omits its name.
                item = only
            } else {
                return true
            }

            var approvedPrices = Set<Decimal>()
            var approvedUnits = Set<Int>()
            if case .ready(let plan) = item.tPlan {
                approvedPrices.insert(plan.sellPrice)
                approvedPrices.insert(plan.buyPrice)
                approvedUnits.insert(plan.units)
            }
            if case .ready(let plan) = item.gridPlan {
                approvedPrices.insert(plan.upper)
                approvedPrices.insert(plan.lower)
                for tier in plan.tiers {
                    approvedPrices.insert(tier.price)
                    approvedUnits.insert(tier.units)
                }
            }
            if containsUnverifiedAction(sentence, approvedPrices: approvedPrices, approvedUnits: approvedUnits) {
                return true
            }
        }
        return false
    }

    private static func containsActionMetrics(_ text: String) -> Bool {
        for pattern in actionPricePatterns + actionUnitPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return true }
        }
        return false
    }

    static func containsUnverifiedAction(_ text: String, approvedPrices: Set<Decimal>, approvedUnits: Set<Int>) -> Bool {
        for pattern in actionPricePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1,
                      let valueRange = Range(match.range(at: 1), in: text) else { continue }
                guard let decimal = Decimal(string: String(text[valueRange])),
                      approvedPrices.contains(where: { abs($0 - decimal) < Decimal(string: "0.000001")! }) else { return true }
            }
        }
        for pattern in actionUnitPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1,
                      let valueRange = Range(match.range(at: 1), in: text),
                      let units = Int(text[valueRange]), approvedUnits.contains(units) else { return true }
            }
        }
        return false
    }
}

enum NextDecisionContextBuilder {
    static func build(guidance: NextDailyGuidance, book: NextBook, quotes: [String: NextQuote],
                      nasResearchLines: [String], crossMarketLines: [String] = [],
                      newsLines: [String], profileLines: [String] = [], goal: NextGoal = NextGoal(),
                      portfolioReview: NextAccountReview? = nil,
                      dailyBars: [String: [NextChartSample]] = [:],
                      intradayBars: [String: [NextChartSample]] = [:],
                      nasResearchSnapshot: [String: NextNASResearch] = [:],
                      newsSnapshot: [String: [NextNewsInput]] = [:],
                      profileSnapshot: NextInvestorProfile? = nil,
                      goalSnapshot: NextGoal? = nil,
                      now: Date) -> NextDecisionContext {
        var holdings: [String] = []
        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "zh_CN")
        timestampFormatter.dateStyle = .short
        timestampFormatter.timeStyle = .short
        let heldPositions = book.positions.filter { $0.units > 0 }
        let portfolioQuotesTrusted = !heldPositions.isEmpty && heldPositions.allSatisfy { position in
            guard let quote = quotes[position.code] else { return false }
            return quote.code == position.code && quote.isFreshForPricePlan(at: now)
        }
        let trustedPortfolioTotal = portfolioQuotesTrusted ? book.total(using: quotes) : nil
        let portfolioCorrelationLines = NextPortfolioCorrelationEngine.contextLines(
            book: book, dailyBars: dailyBars, now: now)
        for position in book.positions where position.units > 0 {
            let quote = quotes[position.code]
            let priceText = quote.map {
                "现价 ¥\(NextMoney.text($0.price, digits: 3))，来源 \($0.source)，行情时间 \(timestampFormatter.string(from: $0.time))，\($0.isFresh(at: now) ? "新鲜" : "已过期/需核对")"
            } ?? "无报价"
            let weight: String
            if let total = trustedPortfolioTotal, total > 0, let quote {
                weight = "，占比 \(NextNum.text(NextNum.double(quote.price * Decimal(position.units) / total * 100), digits: 1))%"
            } else { weight = "" }
            holdings.append("\(position.name)(\(position.code)) 持有 \(position.units) 份，成本 ¥\(NextMoney.text(position.costPerUnit, digits: 3))，\(priceText)\(weight)")
        }
        var planLines: [String] = []
        for item in guidance.items {
            var line = "【\(item.name)】状态 \(item.state.rawValue) → 建议 \(item.strategy.rawValue)（\(item.headline)）"
            if case .ready(let plan) = item.tPlan {
                line += "；候选：\(plan.kind.rawValue) 卖出 ¥\(NextMoney.text(plan.sellPrice, digits: 3)) / 买回 ¥\(NextMoney.text(plan.buyPrice, digits: 3)) × \(plan.units) 份，净收益约 ¥\(NextMoney.text(plan.netGain))，等效降本 ¥\(NextMoney.text(plan.costReductionPerUnit, digits: 3))/份，置信度 \(plan.confidence.level.rawValue)"
            }
            if case .ready(let plan) = item.gridPlan {
                let tiers = plan.tiers.map { tier in
                    let gain = tier.expectedNetGain.map { "，往返净收益约 ¥\(NextMoney.text($0))（已扣双边手续费）" } ?? "，无可配对对侧档，不估收益"
                    return "\(tier.side == "buy" ? "买" : "卖") ¥\(NextMoney.text(tier.price, digits: 3)) × \(tier.units) 份\(gain)"
                }.joined(separator: "；")
                line += "；网格 \(plan.tiers.count) 档，间距 \(String(format: "%.2f", plan.spacingPercent))%，最大占用 ¥\(NextMoney.text(plan.maxCashUsage))；档位：\(tiers)"
            }
            if case .insufficientData(_, let reasons) = item.tPlan {
                line += "；数据不足不出价（\(reasons.first ?? "")）"
            }
            if let note = item.portfolioNote { line += "；组合：\(note)" }
            if !item.whyToday.isEmpty { line += "；规则依据：\(item.whyToday.joined(separator: "；"))" }
            if !item.riskNotes.isEmpty { line += "；风险：\(item.riskNotes.joined(separator: "；"))" }
            if let profileNote = item.profileNote { line += "；画像门槛：\(profileNote)" }
            if let impact = item.newsImpact, !impact.reasons.isEmpty {
                line += "；新闻影响：\(impact.reasons.joined(separator: "；"))"
            }
            planLines.append(line)
        }
        var allocationLines = goal.targetWeights.sorted { $0.key < $1.key }.map { entry in
            let name = book.positions.first(where: { $0.code == entry.key })?.name ?? entry.key
            return "\(name)(\(entry.key)) 长期目标 \(NextNum.text(NextNum.double(entry.value), digits: 1))%"
        }
        if let targetCash = goal.targetCashPercent {
            allocationLines.append("长期现金储备目标 \(NextNum.text(NextNum.double(targetCash), digits: 1))%（ETF目标未分配比例）；若没有通过价格、数据和组合风险检查的机会，应保留现金")
        }
        var portfolioLines: [String] = []
        if let portfolioReview {
            portfolioLines.append(portfolioReview.headline)
            portfolioLines += portfolioReview.findings.map { "\($0.title)：\($0.detail)" }
            portfolioLines += portfolioReview.footnotes
        } else {
            portfolioLines.append("组合体检未提供；不得据此假设现金缓冲、集中度或目标偏差正常")
        }
        let correlationSection = portfolioCorrelationLines.isEmpty
            ? "真实持仓日K共同样本不足；不推断ETF成分重叠或相关关系"
            : portfolioCorrelationLines.joined(separator: "\n")
        let promptBlock = """
        你是观盘顾问，一位只基于用户真实持仓工作的投资顾问。以下是本次统一决策上下文，只能在此基础上给建议：
        【账户】现金 ¥\(NextMoney.text(book.cash))；持仓 \(book.positions.count) 只。
        【长期配置】\(allocationLines.isEmpty ? "未设置ETF目标权重；按组合风险和真实机会判断，不强行投入现金。" : allocationLines.joined(separator: "；"))
        【组合级风险体检】\(portfolioLines.joined(separator: "；"))
        【持仓间历史共振】\(correlationSection)
        【持仓】\(holdings.joined(separator: "\n"))
        【A股交易日历】\(NextMarketClock.sessionDescription(now))。休市日、周末、盘前、午休和收盘后不得描述为“今天可挂”；只能引用规则引擎给出的有效候选计划，计划缺失就明确说没有当日可执行价格。
        【市场状态与候选计划】\(planLines.joined(separator: "\n"))
        【NAS 长期研究】\(nasResearchLines.isEmpty ? "暂无（NAS 离线或未返回）" : nasResearchLines.joined(separator: "\n"))
        【跨市场验证】\(crossMarketLines.isEmpty ? "NAS尚无可引用的跨市场分钟研究；必须说明证据不足，不得凭经验推断某海外市场会领先持仓。" : crossMarketLines.joined(separator: "\n"))
        【新闻线索】\(newsLines.isEmpty ? "暂无（本次不含新闻判断）" : newsLines.joined(separator: "\n"))
        新闻输入是手机或NAS取得的搜索聚合标题，不含正文；来源与发布时间必须一并考虑。标题未经原文核实，不得仅凭标题断言事件已发生；重要线索应降低置信度、提示核实，并说明可能影响哪只持仓和哪项计划。
        【投资画像】\(profileLines.isEmpty ? "暂无足够行为样本，按默认门槛处理" : profileLines.joined(separator: "\n"))
        【今日结论】\(guidance.summary)
        硬性约束：
        1. 具体挂单价与份额只能引用上面的候选计划数值，禁止自行生成任何新价格；
        2. 候选计划标注「数据不足」的标的，直接回答今天无法给出可靠挂单价，不得给出伪精确价格；
        3. 最终只输出一份统一建议：做T/网格/持有/减仓/不交易（不交易是合法结论），并说明理由、风险、失效条件；
        4. 如果本次判断与上次不同，必须指出是哪个数据变化导致（行情、状态、新闻或持仓）；
        5. 投资画像只决定「推荐优先级」和「表达方式」，绝不能修改行情事实、不能降低数据质量与风险门槛、不能为了迎合偏好制造交易机会；当机会低于画像门槛时，如实说「有机会但低于你的执行门槛，因此不主动推荐」；
        6. 不要输出画像里的原始成交明细，只引用上面的结论。
        7. 跨市场关系即使历史统计标为稳定候选，也必须先经过预注册的未来未见样本复现，并由NAS明确标记可用于风险判断；否则只能描述为历史研究，不得改变做T/网格/加仓结论。缺失/过期/样本不足必须说「暂无可靠证据/没有稳定领先关系」，不得编造市场关系或概率。
        8. 跨市场市场状态为 closed、stale 或 unknown 时，只能将其解释为历史关系研究，不能描述成今天的海外实时方向信号；开放市场的最新点超过数据新鲜度门槛也必须忽略。
        9. 在线AI只解释理由和风险，不复述或重算任何交易价格、份额、收益、手续费、降本、胜率、仓位占比等金融数值；这些精确数值只由页面中的规则计划与真实账户卡片展示。
        10. 持仓间相关性只基于实际共同日K样本描述历史价格共振；样本不足必须明示，不得称作ETF成分重叠、因果或未来预测，也不能单独决定交易。
        """
        let trustedQuoteSnapshot = quotes.filter { $0.key == $0.value.code }
        return NextDecisionContext(generatedAt: now, ledgerFingerprint: book.syncFingerprint,
                                   quoteSnapshot: trustedQuoteSnapshot, dailyBarsSnapshot: dailyBars,
                                   intradayBarsSnapshot: intradayBars,
                                   nasResearchSnapshot: nasResearchSnapshot, newsSnapshot: newsSnapshot,
                                   profileSnapshot: profileSnapshot, goalSnapshot: goalSnapshot,
                                   guidance: guidance, holdingsLines: holdings,
                                   portfolioLines: portfolioLines,
                                   portfolioCorrelationLines: portfolioCorrelationLines,
                                   nasResearchLines: nasResearchLines, crossMarketLines: crossMarketLines,
                                   newsLines: newsLines,
                                   profileLines: profileLines, promptBlock: promptBlock)
    }
}
