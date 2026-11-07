import Foundation

// MARK: - Anti-Overtrading：由真实账本驱动交易行为门槛
//
// 观盘max 的 `cooldownAfterConsecutiveBuys` / `minimumSecondsBetweenTrades` /
// `dailyBuyLimit` 在 Pro 里原先只是常量，快照从没被账本填过，规则等于不生效。
// 本文件只做确定性计算：只读账本，不写账、不下单、不发网络请求。
//
// 两条诚实口径：
//   1. `affectsHoldings == false` 的导入历史「只留档、不改余额」，不参与
//      「今天交易了几次 / 连买几笔」的判断，但会在 evidenceCodes 里显式说明。
//   2. 出现未来时间戳、非法价格或数量，evidenceComplete = false 并 fail closed，
//      绝不把「不知道」当成 0 笔放行。

struct TradingBehaviorMetrics: Equatable {
    var consecutiveBuyCount: Int = 0
    var secondsSinceLastFill: TimeInterval?
    var dailyBuyAmount: Double = 0
    var dailyTradeCount: Int = 0
    var trailingTradeDays: Int = 0
    var trailingTradeCount: Int = 0
    var archiveOnlyFillCount: Int = 0
    var lastFillAt: Date?
    var evidenceCodes: [String] = []
    var evidenceComplete: Bool = true
    var asOf: Date
}

enum TradingBehaviorBuilder {
    /// 按真实成交流水推导行为指标。日期一律用 Asia/Shanghai 交易日键，
    /// 与 DailyTradeSummary 保持同一口径，避免「跨日连买」被算错。
    static func metrics(fills: [LedgerEntry], now: Date = Date(), lookbackDays: Int = 5) -> TradingBehaviorMetrics {
        var result = TradingBehaviorMetrics(asOf: now)
        guard now.timeIntervalSince1970.isFinite else {
            result.evidenceComplete = false
            result.evidenceCodes.append("invalid_evaluation_clock")
            return result
        }
        let span = max(1, lookbackDays)
        var ordered: [LedgerEntry] = []
        for fill in fills {
            if fill.affectsHoldings == false {
                result.archiveOnlyFillCount += 1
                continue
            }
            guard fill.date.timeIntervalSince1970.isFinite,
                  fill.price.isFinite, fill.price > 0,
                  fill.quantity.isFinite, fill.quantity > 0,
                  fill.fee.isFinite, fill.fee >= 0 else {
                result.evidenceComplete = false
                result.evidenceCodes.append("invalid_fill_excluded")
                continue
            }
            ordered.append(fill)
        }
        if result.archiveOnlyFillCount > 0 {
            result.evidenceCodes.append("archive_only_fills_excluded")
        }
        ordered.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let today = DailyTradeSummaryBuilder.dayKey(now)
        for fill in ordered where DailyTradeSummaryBuilder.dayKey(fill.date) == today {
            result.dailyTradeCount += 1
            if fill.side == .buy { result.dailyBuyAmount += fill.gross + max(0, fill.fee) }
        }
        for fill in ordered.reversed() {
            if fill.side == .buy { result.consecutiveBuyCount += 1 } else { break }
        }
        if let last = ordered.last {
            result.lastFillAt = last.date
            let elapsed = now.timeIntervalSince(last.date)
            if elapsed < 0 {
                result.evidenceComplete = false
                result.evidenceCodes.append("future_fill_timestamp")
            } else {
                result.secondsSinceLastFill = elapsed
            }
        } else {
            result.evidenceCodes.append("no_real_fills_on_record")
        }
        var days = Array(Set(ordered.map { DailyTradeSummaryBuilder.dayKey($0.date) }))
        days = days.filter { $0 <= today }.sorted().suffix(span).map { $0 }
        result.trailingTradeDays = days.count
        let recent = Set(days)
        result.trailingTradeCount = ordered.filter { recent.contains(DailyTradeSummaryBuilder.dayKey($0.date)) }.count
        return result
    }
}

struct OvertradingPolicy: Equatable {
    var cooldownAfterConsecutiveBuys: Int = 3
    var cooldownSeconds: TimeInterval = 1800
    var minimumSecondsBetweenTrades: TimeInterval = 0
    var dailyBuyLimit: Double? = nil
    var dailyTradeLimit: Int = 8
    var lookbackDays: Int = 5
    var churnThreshold: Int = 12
    var scoreBonusPerExcessBuy: Int = 5
    var churnScoreBonus: Int = 10
    var maxScoreBonus: Int = 25

    static let standard = OvertradingPolicy()
}

struct OvertradingFinding: Identifiable, Equatable {
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

struct OvertradingAssessment: Equatable {
    let metrics: TradingBehaviorMetrics
    let findings: [OvertradingFinding]
    /// 在风控基础门槛之上追加的评分要求；只抬高门槛，绝不降低。
    let requiredScoreBonus: Int
    let cooldownUntil: Date?
    let allowedForReview: Bool
    let confidence: Int
    let reasonCodes: [String]
}

enum AntiOvertrading {
    /// baseRequiredScore 只是展示用：本函数返回的是「再加多少分」，不改动原门槛。
    static func assess(fills: [LedgerEntry],
                       now: Date = Date(),
                       policy: OvertradingPolicy = .standard,
                       baseRequiredScore: Int = 60) -> OvertradingAssessment {
        let m = TradingBehaviorBuilder.metrics(fills: fills, now: now, lookbackDays: policy.lookbackDays)
        var findings: [OvertradingFinding] = []
        var codes = m.evidenceCodes
        var cooldownUntil: Date? = nil
        var bonus = 0

        if !m.evidenceComplete {
            findings.append(.init("activity_history_unavailable",
                                  "成交历史不完整或含未来时间戳，行为门槛无法判定，已拦截"))
            codes.append("fail_closed")
        } else {
            if policy.cooldownAfterConsecutiveBuys > 0,
               m.consecutiveBuyCount >= policy.cooldownAfterConsecutiveBuys {
                findings.append(.init("buy_cooldown",
                                      "连续 \(m.consecutiveBuyCount) 笔买入，达到 \(policy.cooldownAfterConsecutiveBuys) 笔冷却线"))
                codes.append("buy_cooldown")
                if let last = m.lastFillAt { cooldownUntil = last.addingTimeInterval(policy.cooldownSeconds) }
                let excess = max(0, m.consecutiveBuyCount - policy.cooldownAfterConsecutiveBuys + 1)
                bonus += excess * policy.scoreBonusPerExcessBuy
            }
            if policy.minimumSecondsBetweenTrades > 0,
               let elapsed = m.secondsSinceLastFill,
               elapsed < policy.minimumSecondsBetweenTrades {
                findings.append(.init("trade_too_soon",
                                      "距上一笔成交 \(Int(elapsed)) 秒，低于 \(Int(policy.minimumSecondsBetweenTrades)) 秒间隔"))
                codes.append("trade_too_soon")
            }
            if let limit = policy.dailyBuyLimit, m.dailyBuyAmount > limit {
                findings.append(.init("daily_buy_limit",
                                      "当日买入 \(m.dailyBuyAmount.num(2)) 超过上限 \(limit.num(2))"))
                codes.append("daily_buy_limit")
            }
            if m.dailyTradeCount >= policy.dailyTradeLimit {
                findings.append(.init("daily_trade_limit",
                                      "当日已成交 \(m.dailyTradeCount) 笔，达到 \(policy.dailyTradeLimit) 笔上限"))
                codes.append("daily_trade_limit")
            }
            if m.trailingTradeCount > policy.churnThreshold {
                findings.append(.init("recent_churn",
                                      "近 \(m.trailingTradeDays) 个交易日成交 \(m.trailingTradeCount) 笔，过度交易倾向，买入评分门槛上调",
                                      blocking: false))
                codes.append("recent_churn")
                bonus += policy.churnScoreBonus
            }
        }
        let capped = min(policy.maxScoreBonus, max(0, bonus))
        let blocked = findings.contains { $0.blocking }
        let confidence = m.evidenceComplete ? (m.archiveOnlyFillCount > 0 ? 80 : 100) : 0
        if capped > 0 { codes.append("required_score_plus_\(capped)_base_\(baseRequiredScore)") }
        return OvertradingAssessment(metrics: m,
                                     findings: findings,
                                     requiredScoreBonus: capped,
                                     cooldownUntil: cooldownUntil,
                                     allowedForReview: !blocked,
                                     confidence: confidence,
                                     reasonCodes: codes)
    }
}
