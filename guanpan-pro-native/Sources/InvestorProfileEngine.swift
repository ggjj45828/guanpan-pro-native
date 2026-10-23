import Foundation

/// Learns only from confirmed ledger entries and feedback tied to saved AI decisions.
/// A profile can reorder suitable opportunities; it never creates a market signal or relaxes a safety gate.
enum InvestorProfileEngine {
    /// A linked broker fill counts as executing a candidate only when the saved
    /// point-in-time plan actually covered its side, size, limit and time.
    static func tradeMatchesCandidate(_ trade: LedgerEntry, decision: AdvisorDecisionRecord) -> Bool {
        guard trade.code == decision.symbol, trade.affectsHoldings != false,
              trade.date >= decision.createdAt,
              let raw = decision.evidenceSnapshotJSON?.data(using: .utf8),
              let snapshot = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let plan = snapshot["plan"] as? [String: Any],
              let expiry = (plan["validUntil"] as? NSNumber)?.doubleValue,
              expiry.isFinite, trade.date.timeIntervalSince1970 * 1000 <= expiry,
              trade.quantity.isFinite, trade.quantity > 0,
              trade.price.isFinite, trade.price > 0 else { return false }
        func covers(_ expectedSide: LedgerEntry.Side, _ key: String, _ size: Double) -> Bool {
            guard trade.side == expectedSide, size.isFinite, size > 0,
                  trade.quantity <= size + 0.000001,
                  let limit = (plan[key] as? NSNumber)?.doubleValue,
                  limit.isFinite, limit > 0 else { return false }
            return expectedSide == .buy ? trade.price <= limit + 0.000001
                : trade.price + 0.000001 >= limit
        }
        switch (plan["type"] as? String) ?? "" {
        case "reverseT" where decision.action == "反T候选":
            return covers(.sell, "sellLimitYuan", (plan["quantity"] as? NSNumber)?.doubleValue ?? 0)
        case "positiveT" where decision.action == "正T候选":
            return covers(.buy, "buyLimitYuan", (plan["quantity"] as? NSNumber)?.doubleValue ?? 0)
        case "grid" where decision.action == "网格候选":
            let bands = plan["bands"] as? [[String: Any]] ?? []
            return bands.contains { band in
                let size = (band["quantity"] as? NSNumber)?.doubleValue ?? 0
                guard size.isFinite, size > 0, trade.quantity <= size + 0.000001 else { return false }
                let key = trade.side == .buy ? "buyLimitYuan" : "sellLimitYuan"
                guard let limit = (band[key] as? NSNumber)?.doubleValue,
                      limit.isFinite, limit > 0 else { return false }
                return trade.side == .buy ? trade.price <= limit + 0.000001
                    : trade.price + 0.000001 >= limit
            }
        default: return false
        }
    }

    /// Reviews only confirmed ledger entries linked to one saved decision.
    /// FIFO matching keeps partial fills and fees attached to the quantities that actually matched.
    static func matchedDecisionTrades(_ entries: [LedgerEntry]) -> (quantity: Double, net: Double)? {
        var pending: [(side: LedgerEntry.Side, quantity: Double, price: Double, feePerShare: Double)] = []
        var matched = 0.0
        var net = 0.0
        for entry in entries.sorted(by: { $0.date < $1.date }) where
            entry.quantity.isFinite && entry.quantity > 0 && entry.price.isFinite && entry.price > 0 &&
            entry.fee.isFinite && entry.fee >= 0 {
            var remaining = entry.quantity
            while remaining > 0.000001, let first = pending.first, first.side != entry.side {
                let amount = min(remaining, first.quantity)
                let buyPrice = first.side == .buy ? first.price : entry.price
                let sellPrice = first.side == .sell ? first.price : entry.price
                net += (sellPrice - buyPrice) * amount
                    - first.feePerShare * amount - entry.fee / entry.quantity * amount
                matched += amount
                remaining -= amount
                let pendingRemainder = first.quantity - amount
                pending.removeFirst()
                if pendingRemainder > 0.000001 {
                    pending.insert((first.side, pendingRemainder, first.price, first.feePerShare), at: 0)
                }
            }
            if remaining > 0.000001 {
                pending.append((entry.side, remaining, entry.price, entry.fee / entry.quantity))
            }
        }
        return matched > 0 ? (matched, net) : nil
    }

    static func refresh(_ profile: DynamicInvestorProfile, ledger: [LedgerEntry],
                        decisions: [AdvisorDecisionRecord], snapshots: [PortfolioSnapshot],
                        now: Date = .now) -> DynamicInvestorProfile {
        var result = profile
        let decisionIDs = Set(decisions.map(\.id))
        let validFeedback = profile.feedback.filter {
            decisionIDs.contains($0.decisionID) && $0.createdAt <= now &&
            $0.createdAt >= now.addingTimeInterval(-120 * 86_400)
        }
        let trades = ledger.filter {
            $0.affectsHoldings != false && $0.date <= now &&
            $0.date >= now.addingTimeInterval(-120 * 86_400) &&
            $0.quantity > 0 && $0.price > 0 && $0.quantity.isFinite && $0.price.isFinite
        }
        let distinctDays = Set(trades.map { Calendar.current.startOfDay(for: $0.date) }).count
        if trades.count < 5 || distinctDays < 3 {
            result.attributes.removeAll { $0.source != .explicit && ["tradingFrequency", "typicalTicket"].contains($0.id) }
        }
        if trades.count >= 5 && distinctDays >= 3 {
            let monthly = Double(trades.count) / 4
            let value = monthly < 2 ? "低频择机" : monthly < 6 ? "正常" : "较积极"
            upsert("tradingFrequency", value: value, confidence: min(0.85, 0.45 + Double(trades.count) * 0.02),
                   count: trades.count, reason: "近120天有\(trades.count)笔真实成交，分布于\(distinctDays)个交易日；不含导入但未影响持仓的历史流水。",
                   into: &result, now: now)

            let tickets = trades.map { $0.gross }.sorted()
            let median = tickets[tickets.count / 2]
            if median.isFinite {
                upsert("typicalTicket", value: String(format: "%.0f元", median),
                       confidence: min(0.85, 0.4 + Double(trades.count) * 0.02),
                       count: trades.count, reason: "真实成交金额的中位数，降低单笔大额交易的影响。",
                       into: &result, now: now)
            }
        }
        let feedbackByDecision = Dictionary(grouping: validFeedback, by: \.decisionID)
        let latestFeedback = feedbackByDecision.values.compactMap { $0.max(by: { $0.createdAt < $1.createdAt }) }
        result.attributes.removeAll { $0.source == .temporary && $0.id.hasPrefix("pause:") }
        let latestBySymbol = Dictionary(grouping: latestFeedback, by: \.symbol)
        for (symbol, entries) in latestBySymbol {
            guard let latest = entries.max(by: { $0.createdAt < $1.createdAt }),
                  latest.kind == .notNow,
                  latest.createdAt >= now.addingTimeInterval(-86_400) else { continue }
            result.attributes.append(InvestorProfileAttribute(
                id: "pause:" + symbol, value: "暂不主动交易", confidence: 1,
                source: .temporary, sampleCount: 1,
                reason: "您在该持仓的最新AI判断上选择了暂时不交易；24小时后自动失效。",
                updatedAt: latest.createdAt, locked: false))
        }
        if latestFeedback.count < 5 {
            result.attributes.removeAll { $0.source != .explicit && $0.id == "opportunityPreference" }
        }
        if latestFeedback.count >= 5 {
            let cautious = latestFeedback.filter {
                [.smallSpread, .highRisk, .notNow, .preferHold].contains($0.kind)
            }.count
            let value = Double(cautious) / Double(latestFeedback.count) >= 0.6 ? "偏好等待更稳妥的机会" : "愿意评估交易机会"
            upsert("opportunityPreference", value: value,
                   confidence: min(0.8, 0.4 + Double(latestFeedback.count) * 0.025),
                   count: latestFeedback.count,
                   reason: "近120天\(latestFeedback.count)次不同AI判断的最新反馈；不会把一次重复点击当成多次样本。",
                   into: &result, now: now)
        }
        let cashPoints = snapshots.filter {
            $0.recordedAt.map { $0 <= now && $0 >= now.addingTimeInterval(-120 * 86_400) } ?? false
        }.filter { $0.total > 0 && $0.cash >= 0 && $0.total.isFinite && $0.cash.isFinite }
        if cashPoints.count < 10 {
            result.attributes.removeAll { $0.source != .explicit && $0.id == "observedCashReserve" }
        }
        if cashPoints.count >= 10 {
            let ratios = cashPoints.map { min(1, $0.cash / $0.total) }.sorted()
            let median = ratios[ratios.count / 2]
            upsert("observedCashReserve", value: String(format: "%.0f%%", median * 100),
                   confidence: min(0.75, 0.4 + Double(cashPoints.count) * 0.01),
                   count: cashPoints.count, reason: "近120天账户快照现金比例中位数；只描述实际状态，不推断你的最低现金规则。",
                   into: &result, now: now)
        }
        let decisionByID = Dictionary(uniqueKeysWithValues: decisions.map { ($0.id, $0) })
        let ledgerByID = Dictionary(uniqueKeysWithValues: trades.map { ($0.id, $0) })
        let executed = Set(profile.realTradeLinks.compactMap { link -> UUID? in
            guard let decision = decisionByID[link.decisionID],
                  let trade = ledgerByID[link.ledgerID],
                  tradeMatchesCandidate(trade, decision: decision) else { return nil }
            return decision.id
        })
        if executed.count < 3 {
            result.attributes.removeAll { $0.source != .explicit && $0.id == "observedStrategyExecution" }
        } else {
            upsert("observedStrategyExecution", value: "曾实际执行短线候选",
                   confidence: min(0.8, 0.45 + Double(executed.count) * 0.04),
                   count: executed.count,
                   reason: "至少\(executed.count)次不同AI做T/网格候选在有效期内关联了方向、份额及限价相符的券商真实流水；只描述行为，不代表以后应频繁交易。",
                   into: &result, now: now)
        }
        return result
    }

    private static func upsert(_ id: String, value: String, confidence: Double, count: Int,
                               reason: String, into profile: inout DynamicInvestorProfile, now: Date) {
        guard count > (profile.rejectedEvidenceCounts[id] ?? -1) else { return }
        if let index = profile.attributes.firstIndex(where: { $0.id == id }) {
            guard !profile.attributes[index].locked && profile.attributes[index].source != .explicit else { return }
            let old = profile.attributes[index]
            guard old.value != value || old.sampleCount != count || old.reason != reason else { return }
            profile.attributes[index] = InvestorProfileAttribute(
                id: id, value: value, confidence: confidence, source: .learned,
                sampleCount: count, reason: reason, updatedAt: now, locked: false)
        } else {
            profile.attributes.append(InvestorProfileAttribute(
                id: id, value: value, confidence: confidence, source: .learned,
                sampleCount: count, reason: reason, updatedAt: now, locked: false))
        }
    }

    static func onlineSummary(_ profile: DynamicInvestorProfile,
                              existingSettings: InvestmentProfile) -> [String: Any] {
        [
            "attributes": profile.attributes.map {
                ["key": $0.id, "value": $0.value, "confidence": $0.confidence,
                 "source": $0.source.rawValue, "locked": $0.locked] as [String: Any]
            },
            "holdingRules": profile.holdingRules.map {
                ["symbol": $0.symbol, "role": $0.role.rawValue]
            },
            "existingSettings": [
                "horizon": existingSettings.horizon,
                "riskCode": existingSettings.risk,
                "maxPositionPercent": existingSettings.maxPositionPercent,
                "provenance": "旧版手动配置或默认值，尚不能确认是否由用户明确设定"
            ] as [String: Any]
        ]
    }
}
