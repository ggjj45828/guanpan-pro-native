import Foundation

// MARK: - 成交 ↔ Candidate 关联 + 今日 T vs HOLD 复盘
//
// 边界：关联只是「这笔成交可能来自这条候选计划」的复核建议，
// 不是成交事实的证明，更不会把计划改成 filled 或写进 Ledger。
// 只有用户明确确认才升级 confirmed；低置信 / 多候选 / 时间精度不足一律 pending。
//
// T vs HOLD 的口径：先卖后回补且数量配平时，做 T 与一直持有的**持仓数量相同**，
// 唯一差别是那笔净现金 —— 所以差额就是配对贡献 (卖价−回补价)×数量−分摊费用。
// 未配平的卖出需要可信的当日收盘价才能比较，Pro 没有该证据就留 nil，绝不编造。

enum CandidateLinkStatus: String, Codable, Equatable {
    case auto, pending, confirmed, rejected

    var title: String {
        switch self {
        case .auto: return "高置信自动关联"
        case .pending: return "待人工确认"
        case .confirmed: return "已人工确认"
        case .rejected: return "已排除"
        }
    }
}

struct CandidateFillLink: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var planID: UUID
    var fillID: UUID
    var code: String
    var side: String
    var confidence: Int
    var status: CandidateLinkStatus
    var reasons: [String]
    var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, planID, fillID, code, side, confidence, status, reasons, createdAt
    }

    init(id: UUID = UUID(), planID: UUID, fillID: UUID, code: String, side: String,
         confidence: Int, status: CandidateLinkStatus, reasons: [String], createdAt: Date = Date()) {
        self.id = id
        self.planID = planID
        self.fillID = fillID
        self.code = code
        self.side = side
        self.confidence = confidence
        self.status = status
        self.reasons = reasons
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        planID = try c.decode(UUID.self, forKey: .planID)
        fillID = try c.decode(UUID.self, forKey: .fillID)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        side = try c.decodeIfPresent(String.self, forKey: .side) ?? ""
        confidence = try c.decodeIfPresent(Int.self, forKey: .confidence) ?? 0
        status = try c.decodeIfPresent(CandidateLinkStatus.self, forKey: .status) ?? .pending
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

enum CandidateFillMatcher {
    /// 返回本次**新增**的关联建议；已存在的（含用户确认/排除）原样保留在调用方数据里。
    static func match(plans: [TriggerPlan],
                      fills: [LedgerEntry],
                      existing: [CandidateFillLink] = [],
                      now: Date = Date()) -> [CandidateFillLink] {
        let known = Set(existing.map { "\($0.planID.uuidString)|\($0.fillID.uuidString)" })
        struct ScoreHit {
            var planID: UUID
            var score: Int
            var reasons: [String]
            var exact: Bool
            var clean: Bool
        }
        var byFill: [UUID: (code: String, side: String, hits: [ScoreHit])] = [:]
        for fill in fills {
            guard fill.price.isFinite, fill.price > 0, fill.quantity.isFinite, fill.quantity > 0 else { continue }
            let code = TriggerMonitorEngine.normalizedCode(fill.code)
            guard code.count == 6, code.allSatisfy({ $0.isNumber }) else { continue }
            let clean = fill.affectsHoldings != false
            var hits: [ScoreHit] = []
            for plan in plans {
                let candidate = plan.candidate
                guard candidate.code == code else { continue }
                guard (candidate.direction == .buy && fill.side == .buy)
                        || (candidate.direction == .sell && fill.side == .sell) else { continue }
                let exactWindow = fill.date >= candidate.validFrom && fill.date <= candidate.validUntil
                let sameDay = DailyTradeSummaryBuilder.dayKey(fill.date)
                    == DailyTradeSummaryBuilder.dayKey(candidate.validFrom)
                guard exactWindow || sameDay else { continue }
                var score = 30 + 15
                var reasons = ["code_and_side_match"]
                if exactWindow {
                    score += 25
                    reasons.append("within_plan_window")
                } else {
                    score += 10
                    reasons.append("same_day_coarse_timestamp")
                }
                if fill.price >= candidate.lowerPrice && fill.price <= candidate.upperPrice {
                    score += 20
                    reasons.append("price_inside_plan_zone")
                } else if abs(fill.price - candidate.targetPrice) <= candidate.targetPrice * 0.005 {
                    score += 10
                    reasons.append("price_near_target")
                }
                let quantityGap = abs(fill.quantity - candidate.quantity) / max(1e-9, candidate.quantity)
                if quantityGap <= 0.10 {
                    score += 15
                    reasons.append("quantity_matches")
                } else if quantityGap <= 0.50 {
                    score += 5
                    reasons.append("quantity_close")
                }
                if !clean { reasons.append("archive_only_fill") }
                let capped = min(100, score)
                guard capped >= 60 else { continue }
                let key = "\(plan.id.uuidString)|\(fill.id.uuidString)"
                if known.contains(key) { continue }
                hits.append(ScoreHit(planID: plan.id, score: capped,
                                     reasons: reasons, exact: exactWindow, clean: clean))
            }
            if !hits.isEmpty {
                byFill[fill.id] = (code: code, side: fill.side.rawValue, hits: hits)
            }
        }
        // 每笔成交只留最高分候选；多个候选同分时不自动关联。
        struct BestHit {
            var fillID: UUID
            var code: String
            var side: String
            var planID: UUID
            var score: Int
            var reasons: [String]
            var exact: Bool
            var clean: Bool
            var ambiguous: Bool
        }
        var bestPerFill: [BestHit] = []
        for (fillID, group) in byFill {
            let sorted = group.hits.sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.planID.uuidString < rhs.planID.uuidString
            }
            guard let best = sorted.first else { continue }
            let ambiguous = sorted.count > 1 && sorted[1].score >= best.score
            var reasons = best.reasons
            if sorted.count > 1 { reasons.append("multiple_candidate_plans") }
            bestPerFill.append(BestHit(fillID: fillID, code: group.code, side: group.side,
                                       planID: best.planID, score: best.score, reasons: reasons,
                                       exact: best.exact, clean: best.clean, ambiguous: ambiguous))
        }
        // 一条计划也只关联一笔成交，避免把一次计划拆成多笔事实。
        var usedPlans = Set<UUID>()
        var output: [CandidateFillLink] = []
        for item in bestPerFill.sorted(by: { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.fillID.uuidString < rhs.fillID.uuidString
        }) {
            guard usedPlans.insert(item.planID).inserted else { continue }
            var reasons = item.reasons
            let auto = item.score >= 85 && item.exact && item.clean && !item.ambiguous
            if !auto { reasons.append("requires_user_review") }
            let status: CandidateLinkStatus = auto ? .auto : .pending
            output.append(CandidateFillLink(planID: item.planID, fillID: item.fillID,
                                            code: item.code, side: item.side,
                                            confidence: item.score,
                                            status: status, reasons: reasons, createdAt: now))
        }
        return output
    }
}

struct TodayTComparison {
    let day: String
    let date: Date
    let fillCount: Int
    let roundTrips: [TradeRoundTrip]
    let tContribution: Double
    /// 配平部分的 T vs HOLD 差额；没有配对回合时为 nil（不是 0）。
    let holdDifferential: Double?
    let unpairedSellQuantity: Double
    let feesTotal: Double
    let feesAllocated: Double
    let coverageComplete: Bool
    let reasonCodes: [String]
    let evidenceLevel: String
}

enum TodayReviewBuilder {
    static func build(data: PortfolioData, now: Date = Date()) -> TodayTComparison {
        let key = DailyTradeSummaryBuilder.dayKey(now)
        let summary = DailyTradeSummaryBuilder.build(data: data, limitDays: 60)
            .first { $0.day == key }
        guard let summary else {
            return TodayTComparison(day: key, date: now, fillCount: 0, roundTrips: [],
                                    tContribution: 0, holdDifferential: nil,
                                    unpairedSellQuantity: 0, feesTotal: 0, feesAllocated: 0,
                                    coverageComplete: false,
                                    reasonCodes: ["no_fills_today"], evidenceLevel: "ledger_only")
        }
        let trips = summary.roundTrips
        let contribution = summary.intradayContribution
        let allocated = trips.reduce(0) { $0 + $1.feeShare }
        var pending: [String: Double] = [:]
        for fill in summary.fills {
            let bucket = "\(fill.code)|\((fill.kind ?? .etf).rawValue)"
            if fill.side == .sell {
                pending[bucket, default: 0] += fill.quantity
            } else {
                pending[bucket] = max(0, (pending[bucket] ?? 0) - fill.quantity)
            }
        }
        let unpaired = pending.values.reduce(0, +)
        var codes = ["ledger_only_no_market_price"]
        if trips.isEmpty { codes.append("no_round_trips_today") }
        if unpaired > 1e-9 { codes.append("unpaired_sells_need_trusted_closing_price") }
        return TodayTComparison(day: key, date: summary.date,
                                fillCount: summary.fills.count,
                                roundTrips: trips,
                                tContribution: contribution,
                                holdDifferential: trips.isEmpty ? nil : contribution,
                                unpairedSellQuantity: unpaired,
                                feesTotal: summary.fees,
                                feesAllocated: allocated,
                                coverageComplete: unpaired <= 1e-9,
                                reasonCodes: codes,
                                evidenceLevel: "ledger_only")
    }
}
