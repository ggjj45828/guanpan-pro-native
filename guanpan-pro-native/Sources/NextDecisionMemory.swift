import Foundation

// MARK: - AI 决策记忆（当时依据 → 后来发生了什么 → 为什么改判）
//
// 设计要求（逐条对应）：
// 1. 保存「当时」的行情 / 持仓 / NAS 研究 / 新闻 / 画像 / 建议 / 数据依据 / 风险 /
//    有效期 / 失效条件 —— 全部是快照，不是事后重算；
// 2. 记录「是否真实成交」——只有用户回填真实成交才算成交，AI 永远不自己认定；
// 3. 记录「后续结果」——由复盘人在新一次扫描后用当时价格与实际成交价对比得出；
// 4. 改判必须能解释「什么发生了变化」——由 `NextDecisionDiff.compare` 逐项比对得出，
//    不允许出现"模型觉得应该改"这种不可复算的理由。
//
// 本文件是纯函数 + 纯数据，不依赖 SwiftUI，也不读写账本。

/// 一条建议在生成时刻的完整证据快照。字段只增不减，旧备份解码时缺键即视为「当时没有」。
struct NextDecisionSnapshot: Codable, Equatable {
    /// 行情
    let price: String?
    let previousClose: String?
    let quoteSource: String?
    let quoteAt: Date?
    /// 持仓
    let units: Int
    let averageCost: String?
    /// NAS 长期分时
    let nasDays: Int?
    let nasVwap20: String?
    let nasCloseVsVwap20: Double?
    let nasAmplitude60: Double?
    let nasRoundTrips60: Double?
    let nasVolatility120: Double?
    let nasSupportP10: String?
    let nasResistanceP90: String?
    let nasStale: Bool?
    let nasEnoughForLongTerm: Bool?
    /// 跨市场研究在建议生成时的原始证据摘要。历史候选与可交易资格分开保存，供改判解释与复盘。
    /// Optional so archives written before this field continue to decode.
    let crossMarketEvidence: [String]?
    /// 新闻（只存标题与来源，不存正文）
    let newsTitles: [String]
    /// 画像
    let profileTags: [String]
    /// 结论
    let state: String
    let strategy: String
    let headline: String
    /// 数据依据
    let evidence: [String]
    /// 风险
    let risks: [String]
    /// 有效期与失效条件（来自计划本身；没有计划就是 nil）
    let validUntil: Date?
    let invalidConditions: [String]
    /// 当时给出的具体限价与份额（没有就是 nil）
    let limitPrice: String?
    let limitUnits: Int?
    let expectedNetGain: String?
    let expectedCostReduction: String?
    let confidenceLevel: String

    init(price: String? = nil, previousClose: String? = nil, quoteSource: String? = nil, quoteAt: Date? = nil,
         units: Int = 0, averageCost: String? = nil,
         nasDays: Int? = nil, nasVwap20: String? = nil, nasCloseVsVwap20: Double? = nil,
         nasAmplitude60: Double? = nil, nasRoundTrips60: Double? = nil, nasVolatility120: Double? = nil,
         nasSupportP10: String? = nil, nasResistanceP90: String? = nil,
         nasStale: Bool? = nil, nasEnoughForLongTerm: Bool? = nil,
         crossMarketEvidence: [String]? = nil,
         newsTitles: [String] = [], profileTags: [String] = [],
         state: String, strategy: String, headline: String,
         evidence: [String] = [], risks: [String] = [],
         validUntil: Date? = nil, invalidConditions: [String] = [],
         limitPrice: String? = nil, limitUnits: Int? = nil,
         expectedNetGain: String? = nil, expectedCostReduction: String? = nil,
         confidenceLevel: String) {
        self.price = price; self.previousClose = previousClose
        self.quoteSource = quoteSource; self.quoteAt = quoteAt
        self.units = units; self.averageCost = averageCost
        self.nasDays = nasDays; self.nasVwap20 = nasVwap20
        self.nasCloseVsVwap20 = nasCloseVsVwap20
        self.nasAmplitude60 = nasAmplitude60; self.nasRoundTrips60 = nasRoundTrips60
        self.nasVolatility120 = nasVolatility120
        self.nasSupportP10 = nasSupportP10; self.nasResistanceP90 = nasResistanceP90
        self.nasStale = nasStale; self.nasEnoughForLongTerm = nasEnoughForLongTerm
        self.crossMarketEvidence = crossMarketEvidence
        self.newsTitles = newsTitles; self.profileTags = profileTags
        self.state = state; self.strategy = strategy; self.headline = headline
        self.evidence = evidence; self.risks = risks
        self.validUntil = validUntil; self.invalidConditions = invalidConditions
        self.limitPrice = limitPrice; self.limitUnits = limitUnits
        self.expectedNetGain = expectedNetGain; self.expectedCostReduction = expectedCostReduction
        self.confidenceLevel = confidenceLevel
    }
}

/// 用户对这条建议的处置。**只有** `filled` 代表真实成交，且必须带真实成交价与份数。
enum NextDecisionOutcome: String, Codable, Equatable {
    case pending = "未处理"
    case filled = "已真实成交"
    case skipped = "我放弃了"
    case expired = "已过期未成交"
    case invalidated = "条件失效作废"

    var isFilled: Bool { self == .filled }
}

struct NextDecisionReview: Codable, Equatable {
    /// 复盘结论，例如「按计划价成交，价格随后回到 VWAP，往返 1 次」
    var note: String
    /// 实际成交价 / 实际份数（真实成交才有）
    var filledPrice: String?
    var filledUnits: Int?
    /// 事后价格（复盘时点）
    var laterPrice: String?
    /// 按实际成交价与事后价算出的结果，仅作复盘记录，不计入任何收益
    var laterChangePercent: Double?
    var reviewedAt: Date?

    init(note: String = "", filledPrice: String? = nil, filledUnits: Int? = nil,
         laterPrice: String? = nil, laterChangePercent: Double? = nil, reviewedAt: Date? = nil) {
        self.note = note; self.filledPrice = filledPrice; self.filledUnits = filledUnits
        self.laterPrice = laterPrice; self.laterChangePercent = laterChangePercent
        self.reviewedAt = reviewedAt
    }
}

struct NextDecisionRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let code: String
    let name: String
    let createdAt: Date
    let snapshot: NextDecisionSnapshot
    var outcome: NextDecisionOutcome = .pending
    var outcomeAt: Date?
    var review = NextDecisionReview()
    /// 改判轨迹：每次重新判断都把「什么发生了变化」写进来，不允许静默改口。
    var revisions: [NextDecisionRevision] = []

    var isOpen: Bool { outcome == .pending }

    /// 用新的快照生成一次改判记录。结论或关键数字变了才有记录。
    mutating func revise(with snapshot: NextDecisionSnapshot, at time: Date) -> NextDecisionRevision? {
        let changes = NextDecisionDiff.compare(old: self.snapshot, new: snapshot)
        guard !changes.isEmpty else { return nil }
        let revision = NextDecisionRevision(at: time, fromHeadline: self.snapshot.headline,
                                            toHeadline: snapshot.headline, changes: changes)
        revisions.append(revision)
        return revision
    }
}

struct NextDecisionRevision: Codable, Identifiable, Equatable {
    var id = UUID()
    let at: Date
    let fromHeadline: String
    let toHeadline: String
    /// 「什么发生了变化」：每条都能追回具体字段与当时数值。
    let changes: [String]
}

// MARK: - 变化说明

enum NextDecisionDiff {
    /// 价格变动超过这个百分比才算「价格变了」，否则只是行情抖动，不值得改判。
    static let priceMoveThresholdPercent = 0.6
    /// VWAP 偏离变动超过这个百分点才算「位置变了」。
    static let vwapDeviationThreshold = 0.5

    /// 逐项比对两个快照，返回人类可读的变化说明。空数组表示「什么都没变」。
    static func compare(old: NextDecisionSnapshot, new: NextDecisionSnapshot) -> [String] {
        var changes: [String] = []
        if old.state != new.state {
            changes.append("市场状态从「\(old.state)」变为「\(new.state)」")
        }
        if old.strategy != new.strategy {
            changes.append("策略从「\(old.strategy)」变为「\(new.strategy)」")
        }
        if old.headline != new.headline {
            changes.append("结论从「\(old.headline)」变为「\(new.headline)」")
        }
        if let move = priceMove(from: old.price, to: new.price) {
            changes.append("价格从 ¥\(old.price ?? "—") 变为 ¥\(new.price ?? "—")（\(String(format: "%+.2f", move))%）")
        }
        if let before = old.nasCloseVsVwap20, let after = new.nasCloseVsVwap20,
           abs(before - after) >= vwapDeviationThreshold {
            changes.append("相对 20 日 VWAP 的偏离从 \(String(format: "%+.2f", before))% 变为 \(String(format: "%+.2f", after))%")
        }
        if old.nasStale != new.nasStale, let stale = new.nasStale {
            changes.append(stale ? "NAS 长期分时变成过期数据，结论降档" : "NAS 长期分时恢复新鲜，结论回到原档")
        }
        if old.nasDays != new.nasDays, let days = new.nasDays {
            changes.append("NAS 分时归档从 \(old.nasDays.map(String.init) ?? "无") 天变为 \(days) 天")
        }
        if old.limitPrice != new.limitPrice {
            changes.append("限价从 ¥\(old.limitPrice ?? "无") 变为 ¥\(new.limitPrice ?? "无")")
        }
        if old.limitUnits != new.limitUnits {
            changes.append("份额从 \(old.limitUnits.map(String.init) ?? "无") 份变为 \(new.limitUnits.map(String.init) ?? "无") 份")
        }
        if old.validUntil != new.validUntil {
            changes.append("有效期从 \(dateText(old.validUntil)) 变为 \(dateText(new.validUntil))")
        }
        let addedNews = Set(new.newsTitles).subtracting(Set(old.newsTitles))
        if !addedNews.isEmpty {
            changes.append("新增新闻 \(addedNews.count) 条：\(Array(addedNews).prefix(2).joined(separator: "；"))")
        }
        let addedRisks = Set(new.risks).subtracting(Set(old.risks))
        if !addedRisks.isEmpty {
            changes.append("新增风险 \(addedRisks.count) 条：\(Array(addedRisks).prefix(2).joined(separator: "；"))")
        }
        if old.confidenceLevel != new.confidenceLevel {
            changes.append("数据置信度从 \(old.confidenceLevel) 变为 \(new.confidenceLevel)")
        }
        if old.units != new.units {
            changes.append("持仓从 \(old.units) 份变为 \(new.units) 份")
        }
        let oldCrossMarket = Set(old.crossMarketEvidence ?? [])
        let newCrossMarket = Set(new.crossMarketEvidence ?? [])
        let addedCrossMarket = newCrossMarket.subtracting(oldCrossMarket).sorted()
        let removedCrossMarket = oldCrossMarket.subtracting(newCrossMarket).sorted()
        if !addedCrossMarket.isEmpty {
            changes.append("跨市场证据新增：\(addedCrossMarket.prefix(2).joined(separator: "；"))")
        }
        if !removedCrossMarket.isEmpty {
            changes.append("跨市场证据撤回或更新：\(removedCrossMarket.prefix(2).joined(separator: "；"))")
        }
        return changes
    }

    static func priceMove(from oldText: String?, to newText: String?) -> Double? {
        guard let oldText, let newText,
              let old = Decimal(string: oldText), let new = Decimal(string: newText), old > 0 else { return nil }
        let move = NextNum.double((new - old) / old * 100)
        guard abs(move) >= priceMoveThresholdPercent else { return nil }
        return move
    }

    static func dateText(_ date: Date?) -> String {
        guard let date else { return "无" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 决策记忆仓库（只做内存整理，持久化由 App 层负责）

enum NextDecisionMemory {
    /// A manual ledger fill may be associated only with the same holding's still-pending
    /// decision from the same Shanghai trading day. The UI must let the user choose it;
    /// matching by code/time alone is never treated as proof that a fill followed advice.
    static func canLinkManualFill(_ record: NextDecisionRecord, code: String, at time: Date) -> Bool {
        guard record.code == code, record.outcome == .pending,
              record.createdAt <= time, time.timeIntervalSince1970.isFinite else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.isDate(record.createdAt, inSameDayAs: time)
    }

    /// Resolve a saved manual-trade candidate to today's pending evidence record.
    /// Revisions preserve the original immutable snapshot, so matching by the latest price
    /// would incorrectly fail after an intraday repricing; code/day/strategy is the stable key.
    static func matchingRecordID(for plan: NextCandidatePlan, records: [NextDecisionRecord]) -> UUID? {
        let isGrid = plan.kind == .gridBuy || plan.kind == .gridSell
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return records
            .filter { record in
                guard record.code == plan.code, record.outcome == .pending,
                      calendar.isDate(record.createdAt, inSameDayAs: plan.createdAt) else { return false }
                if isGrid { return record.snapshot.strategy.contains("网格") }
                return record.snapshot.strategy.localizedCaseInsensitiveContains("t") || record.snapshot.strategy.contains("做T")
            }
            .max(by: { $0.createdAt < $1.createdAt })?.id
    }

    /// Store a user-confirmed broker fill; price-touch events never call this.
    @discardableResult
    static func confirmFill(_ record: inout NextDecisionRecord, price: Decimal, units: Int,
                            at time: Date) -> Bool {
        guard price > 0, !price.isNaN, units > 0,
              time.timeIntervalSince1970.isFinite, time >= record.createdAt else { return false }
        record.outcome = .filled
        record.outcomeAt = time
        record.review.filledPrice = NextMoney.text(price, digits: 4)
        record.review.filledUnits = units
        record.review.reviewedAt = nil
        record.review.note = "券商真实成交已由用户确认；后续行情到达后再复盘"
        return true
    }

    /// Only a fresh, supplier-timestamped quote observed after the confirmed fill may
    /// become the later-price point used by a review.
    static func laterReviewPrice(for record: NextDecisionRecord, quote: NextQuote?, now: Date) -> Decimal? {
        guard record.outcome == .filled, let quote,
              quote.isFreshForPricePlan(at: now),
              quote.time > (record.outcomeAt ?? record.createdAt) else { return nil }
        return quote.price
    }

    /// 将 NAS 跨市场 DTO 压成有界、可追溯的快照；仅记事实和验证状态，不把相关性包装成交易信号。
    private static func crossMarketSnapshot(_ evidence: NextNASResearch.CrossMarketEvidence?) -> [String]? {
        guard let evidence else { return nil }
        var rows = [
            "state=\(evidence.state)",
            "validation=\(evidence.validationState ?? "unknown")",
            "eligibleForTradingSignal=\(evidence.eligibleForTradingSignal.map { String($0) } ?? "unknown")",
            "bestMarket=\(evidence.bestMarket ?? "unknown")",
            "bestLagMinutes=\(evidence.bestLagMinutes.map(String.init) ?? "unknown")",
            "sampleCount=\(evidence.sampleCount.map(String.init) ?? "unknown")",
            "currentMarketStatus=\(evidence.currentMarketStatus ?? "unknown")",
            "source=\(evidence.source ?? "unknown")",
            "asOf=\(evidence.asOf ?? "unknown")"
        ]
        if let winRate = evidence.conditionalWinRate {
            rows.append("conditionalWinRate=\(String(format: "%.4f", winRate))")
        }
        for item in evidence.liveDivergences ?? [] {
            rows.append("liveDivergence=\(item.market)|\(item.state)|window=\(item.windowMinutes.map(String.init) ?? "unknown")|leader=\(item.leaderReturnPercent.map { String(format: "%.4f", $0) } ?? "unknown")|asset=\(item.assetReturnPercent.map { String(format: "%.4f", $0) } ?? "unknown")|eligible=\(item.eligibleForTradingSignal.map { String($0) } ?? "unknown")|expires=\(item.expiresAt ?? "unknown")")
        }
        if let fx = evidence.currencyContext {
            rows.append("currency=\(fx.pair ?? "unknown")|state=\(fx.state)|return=\(fx.fxReturnPercent.map { String(format: "%.4f", $0) } ?? "unknown")|source=\(fx.source ?? "unknown")|asOf=\(fx.asOf ?? "unknown")|eligible=\(fx.eligibleForTradingSignal.map { String($0) } ?? "unknown")")
        }
        for item in evidence.overnightAbsorption ?? [] {
            rows.append("overnight=\(item.market)|\(item.state)|samples=\(item.sampleCount)|start=\(item.sampleStartDay ?? "unknown")|end=\(item.sampleEndDay ?? "unknown")|eligible=\(item.eligibleForTradingSignal.map { String($0) } ?? "unknown")")
        }
        if let tail = evidence.tailToNextDay {
            rows.append("tailToNextDay=\(tail.state)|samples=\(tail.sampleCount)|start=\(tail.sampleStartDay ?? "unknown")|end=\(tail.sampleEndDay ?? "unknown")|eligible=\(tail.eligibleForTradingSignal.map { String($0) } ?? "unknown")")
        }
        for row in evidence.rollingValidity ?? [] {
            for window in row.windows {
                rows.append("rolling=\(row.market)|lag=\(row.lagMinutes)|horizon=\(row.horizonMinutes)|window=\(window.windowSessions)|samples=\(window.sampleCount)|state=\(window.state)|eligible=\(window.eligibleForTradingSignal.map { String($0) } ?? "unknown")")
            }
        }
        return Array(rows.prefix(64))
    }

    /// 从一条指导生成「当时」的快照。全部字段取自本次真实的行情 / 持仓 / NAS / 新闻 / 画像，
    /// 不允许调用方传入「后来」的数字。
    static func snapshot(item: NextGuidanceItem, quote: NextQuote?, position: NextPosition?,
                         research: NextNASResearch?, news: [NextNewsInput],
                         profile: NextInvestorProfile?) -> NextDecisionSnapshot {
        let stats = research?.minuteStats
        let w20 = stats?.window(20)
        let w60 = stats?.window(60)
        let w120 = stats?.window(120)
        var limitPrice: String?
        var limitUnits: Int?
        var validUntil: Date?
        var invalidConditions: [String] = []
        var expectedNetGain: String?
        var expectedCostReduction: String?
        if let tPlan = item.tPlan, case let .ready(plan) = tPlan {
            let isSell = plan.kind == .reverse
            limitPrice = "\(isSell ? plan.sellPrice : plan.buyPrice)"
            limitUnits = plan.units
            validUntil = plan.validUntil
            invalidConditions = plan.cancelConditions
            expectedNetGain = "\(plan.netGain)"
            expectedCostReduction = "\(plan.costReductionPerUnit)"
        } else if let gridPlan = item.gridPlan, case let .ready(plan) = gridPlan {
            let buy = plan.tiers.first { $0.side == "buy" }
            limitPrice = buy.map { "\($0.price)" }
            limitUnits = buy?.units
            validUntil = plan.validUntil
            invalidConditions = plan.pauseConditions
        }
        return NextDecisionSnapshot(
            price: quote.map { "\($0.price)" },
            previousClose: quote.map { "\($0.previousClose)" },
            quoteSource: quote?.source,
            quoteAt: quote?.time,
            units: position?.units ?? 0,
            averageCost: position.map { "\($0.bookCost)" },
            nasDays: stats?.days,
            nasVwap20: w20?.vwap,
            nasCloseVsVwap20: w20?.closeVsVwapPercent,
            nasAmplitude60: w60?.amplitudeMedianPercent,
            nasRoundTrips60: w60?.roundTripsMedian,
            nasVolatility120: w120?.volatilityPercent,
            nasSupportP10: w20?.supportP10 ?? w20?.support,
            nasResistanceP90: w20?.resistanceP90 ?? w20?.resistance,
            nasStale: stats?.freshness.stale,
            nasEnoughForLongTerm: stats?.quality.enoughForLongTerm,
            crossMarketEvidence: crossMarketSnapshot(research?.crossMarket),
            newsTitles: news.map(\.title),
            profileTags: profile?.styleTags ?? [],
            state: item.state.rawValue,
            strategy: item.strategy.rawValue,
            headline: item.headline,
            evidence: item.whyToday,
            risks: item.riskNotes,
            validUntil: validUntil,
            invalidConditions: invalidConditions,
            limitPrice: limitPrice,
            limitUnits: limitUnits,
            expectedNetGain: expectedNetGain,
            expectedCostReduction: expectedCostReduction,
            confidenceLevel: item.confidence.level.rawValue)
    }

    /// 只把「今天有动作或有机会」的持仓写进记忆：全是持有的不需要每天刷一条。
    static func records(from guidance: NextDailyGuidance, quotes: [String: NextQuote], book: NextBook,
                        research: [String: NextNASResearch], news: [String: [NextNewsInput]],
                        profile: NextInvestorProfile?) -> [NextDecisionRecord] {
        guidance.items.compactMap { item in
            let hasPlan = item.tPlan?.isReady == true || item.gridPlan?.isReady == true
            let crossMarketBlocked = NextCrossMarketRiskGuard.blockingReason(
                evidence: research[item.code]?.crossMarket, now: guidance.generatedAt) != nil
            guard hasPlan || item.newsImpact?.action.blocksPlan == true || crossMarketBlocked else { return nil }
            let snapshot = snapshot(item: item, quote: quotes[item.code],
                                    position: book.positions.first { $0.code == item.code },
                                    research: research[item.code], news: news[item.code] ?? [],
                                    profile: profile)
            return NextDecisionRecord(code: item.code, name: item.name,
                                      createdAt: guidance.generatedAt, snapshot: snapshot)
        }
    }

    /// 同一天同一只证券只保留最新一条「待处理」记录，避免刷一次页面就堆一条。
    static func merge(existing: [NextDecisionRecord], incoming: [NextDecisionRecord],
                      calendar: Calendar = .current) -> [NextDecisionRecord] {
        var result = existing
        for record in incoming {
            if let index = result.firstIndex(where: {
                $0.code == record.code && $0.outcome == .pending
                    && calendar.isDate($0.createdAt, inSameDayAs: record.createdAt)
            }) {
                // 同一天同一只：保留原记录，但把改判写进轨迹，不改「当时」的快照。
                _ = result[index].revise(with: record.snapshot, at: record.createdAt)
            } else {
                result.append(record)
            }
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    /// 计划到期/条件失效的自动迁移。只改状态，不改快照，不产生任何成交。
    static func expire(_ records: [NextDecisionRecord], at now: Date,
                       quoteFor: (String) -> NextQuote?) -> [NextDecisionRecord] {
        records.map { record in
            var copy = record
            guard copy.outcome == .pending else { return copy }
            if let validUntil = copy.snapshot.validUntil, validUntil < now {
                copy.outcome = .expired
                copy.outcomeAt = now
                copy.review.note = "计划有效期已过（\(NextDecisionDiff.dateText(validUntil))），未记录到真实成交"
                return copy
            }
            // 失效条件里写明「突破区间」的，用当时给的限价做一次事实核对。
            // A stale/cache-only quote cannot invalidate a plan: do not turn old data into a new event.
            if let quote = quoteFor(copy.code), quote.isFreshForPricePlan(at: now),
               let limitText = copy.snapshot.limitPrice,
               let limit = Decimal(string: limitText), limit > 0,
               copy.snapshot.strategy.contains("做T") {
                let gap = NextNum.double((quote.price - limit) / limit * 100)
                if abs(gap) > 5 {
                    copy.outcome = .invalidated
                    copy.outcomeAt = now
                    copy.review.note = "现价 ¥\(quote.price) 已偏离计划价 ¥\(limit) 达 \(String(format: "%+.2f", gap))%，原计划失效"
                }
            }
            return copy
        }
    }

    /// 复盘：用真实成交价与事后价算出这次到底怎样。**不写入任何收益账户**。
    static func review(_ record: NextDecisionRecord, laterPrice: Decimal?, at now: Date) -> NextDecisionReview {
        var review = record.review
        guard let laterPrice else {
            review.reviewedAt = nil
            review.note = "暂缺成交后新鲜且可信的行情；保留待复盘状态，后续刷新再计算"
            return review
        }
        review.laterPrice = "\(laterPrice)"
        if let filledText = review.filledPrice, let filled = Decimal(string: filledText), filled > 0 {
            review.laterChangePercent = NextNum.double((laterPrice - filled) / filled * 100)
            let direction = (laterPrice - filled) >= 0 ? "上涨" : "下跌"
            review.note = "按 ¥\(filledText) 真实成交 \(review.filledUnits ?? 0) 份，此后\(direction) \(String(format: "%.2f", abs(review.laterChangePercent ?? 0)))%（仅复盘记录，不计入收益）"
        } else {
            let compare = record.snapshot.limitPrice.flatMap { Decimal(string: $0) }
            if let compare, compare > 0 {
                let gap = NextNum.double((laterPrice - compare) / compare * 100)
                review.note = "未记录真实成交；计划价 ¥\(compare) 与当前价 ¥\(laterPrice) 相差 \(String(format: "%+.2f", gap))%"
            } else {
                review.note = "未记录真实成交，且当时没有给出限价"
            }
        }
        review.reviewedAt = now
        return review
    }

    /// 待处理条目的「现在还能不能用」：过期 / 条件失效 / 仍有效。
    static func freshness(_ record: NextDecisionRecord, at now: Date) -> String {
        guard record.outcome == .pending else { return record.outcome.rawValue }
        guard let validUntil = record.snapshot.validUntil else { return "待处理（无有效期）" }
        if validUntil < now { return "已过期（有效期 \(NextDecisionDiff.dateText(validUntil))）" }
        let minutes = Int(validUntil.timeIntervalSince(now) / 60)
        return "待处理（还有 \(max(1, minutes)) 分钟有效期）"
    }
}
