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
    var remainingUnits: Int { max(0, units - (confirmedUnits ?? 0)) }

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
              limitPrice > 0, !limitPrice.isNaN, units > 0,
              expiresAt > createdAt,
              !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NextError.invalid("候选计划的证券、价格、份额或有效期无效")
        }
    }

    /// 只更新候选计划的真实成交反馈；账本写入由调用方在校验通过后单独提交。
    mutating func confirmRealFill(price: Decimal, units filledUnits: Int, fee: Decimal,
                                  at tradedAt: Date, now: Date) throws {
        guard state.isOpen, now <= expiresAt, filledUnits > 0, filledUnits <= remainingUnits,
              price > 0, !price.isNaN, fee >= 0, !fee.isNaN,
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
        stateChangedAt = now
        state = totalUnits == units ? .confirmed : .partiallyConfirmed
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
        guard let quote, quote.code == code else { return nil }
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

enum NextOpportunityScanner {
    /// 扫描全部真实持仓，按「成功概率 × 风险 × 流动性 × 成本 × 数据可信度」排序。
    /// 不预测涨跌；不交易是正常结论。
    static func scan(book: NextBook, quotes: [String: NextQuote], daily: [String: [NextChartSample]],
                     intraday: [String: [NextChartSample]], rules: [String: NextInstrumentRules],
                     orderBooks: [String: NextOrderBookSnapshot] = [:],
                     goal: NextGoal, nasAvailable: Bool, profile: NextInvestorProfile? = nil,
                     research: [String: NextNASResearch] = [:],
                     news: [String: [NextNewsInput]] = [:],
                     now: Date) -> NextDailyGuidance {
        let total = book.total(using: quotes)
        var items: [NextGuidanceItem] = []

        for position in book.positions where position.units > 0 {
            let quote = quotes[position.code]
            let bars = daily[position.code] ?? []
            let minutes = intraday[position.code] ?? []
            let reading = NextMarketStateEngine.classify(daily: bars, intraday: minutes, quote: quote, now: now)
            let gridCheck = NextGridCheckEngine.evaluate(code: position.code, name: position.name, samples: bars,
                                                         isOnExchange: NextDividendRules.isOnExchangeETF(position.code))
            let stats = NextIntradayStatsEngine.compute(samples: minutes, previousClose: quote?.previousClose)
            let oscillating = stats.vwapCrossings >= 2 && (stats.amplitudePercent ?? 0) >= 0.8
            let strategy = NextStrategySelector.select(state: reading, grid: gridCheck, hasPosition: true,
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
                                                       minuteSampleCount: minutes.filter { $0.close > 0 }.count)
            if let stats = nasStats, stats.freshness.stale {
                confidence = confidence.downgraded("NAS 长期分时已过期：\(stats.freshness.reason ?? "最后一天 \(stats.lastDay ?? "未知")")")
            }

            // 组合级判断：单只超配时，价格再好也只能观察。
            var portfolioNote: String?
            if let quote, let total, total > 0 {
                let weight = NextNum.double(quote.price * Decimal(position.units) / total * 100)
                if weight > NextNum.double(goal.concentrationLimit) {
                    portfolioNote = "该只占比 \(String(format: "%.1f", weight))%，已超过你设置的 \(NextNum.text(NextNum.double(goal.concentrationLimit)))% 组合上限：价格再有吸引力也不建议继续增加"
                }
            }

            var tPlan: NextTPlannerResult?
            var gridPlan: NextGridPlannerResult?
            var riskNotes: [String] = []
            var headline = strategy.kind.rawValue
            // 画像上限与 NAS 长期统计一起进计划：这是硬约束，不是提示。
            let caps = NextPlanCaps.make(profile: profile, nasStats: nasStats, book: book,
                                         code: position.code,
                                         lotSize: rules[position.code]?.lotSize ?? 100, now: now)

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
                tPlan = result
                if case let .ready(plan) = result {
                    headline = plan.kind.rawValue
                    riskNotes.append(plan.trampleRisk)
                    if portfolioNote != nil {
                        riskNotes.append("组合仓位已超上限：正T的买入腿不建议执行")
                    }
                }
            case .grid:
                let result = NextGridPlanner.plan(book: book, quote: quote, daily: bars, gridCheck: gridCheck,
                                                  rules: rules[position.code], nasRange: nasRange,
                                                  orderBook: orderBooks[position.code],
                                                  caps: caps, now: now)
                gridPlan = result
                if case let .ready(plan) = result {
                    headline = "网格 · \(plan.tiers.count) 档 / 间距 \(String(format: "%.2f", plan.spacingPercent))%"
                }
            case .hold, .waitBuy, .pauseAdd, .reduce, .noTrade:
                break
            }

            var tNetGain: Decimal?
            if let tPlan, case let .ready(plan) = tPlan { tNetGain = plan.netGain }
            let recovery = NextRecoveryAnalyzer.analyze(book: book, quote: quote, rules: rules[position.code],
                                                        goal: goal, tNetGain: tNetGain, now: now)

            var actionable = false
            if let tPlan, case .ready = tPlan, portfolioNote == nil { actionable = true }
            if let gridPlan, case .ready = gridPlan { actionable = true }

            var score = 0.0
            if let tPlan, case let .ready(plan) = tPlan {
                score += 2.5 + min(3.0, NextNum.double(plan.netGain / Decimal(100)))
            }
            if let gridPlan, case .ready = gridPlan { score += 2.5 }
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
            items.append(NextNewsImpactEngine.apply(impact, to: baseItem))
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
        let dataState: String
        if quotes.isEmpty { dataState = "断网/无行情 · 仅本地缓存与离线规则" }
        else if nasAvailable { dataState = "NAS 长期研究可用 · 实时行情正常" }
        else { dataState = "NAS 离线 · 仅实时行情 + 本地规则，长期统计缺失" }

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
    let guidance: NextDailyGuidance
    let holdingsLines: [String]
    let nasResearchLines: [String]
    let newsLines: [String]
    /// 本次在线 AI 实际收到的画像结论（可解释性：用户能查「AI 用了哪些画像信息」）。
    let profileLines: [String]
    let promptBlock: String
}

enum NextDecisionContextBuilder {
    static func build(guidance: NextDailyGuidance, book: NextBook, quotes: [String: NextQuote],
                      nasResearchLines: [String], newsLines: [String], profileLines: [String] = [],
                      now: Date) -> NextDecisionContext {
        var holdings: [String] = []
        for position in book.positions where position.units > 0 {
            let quote = quotes[position.code]
            let priceText = quote.map {
                "现价 ¥\(NextMoney.text($0.price, digits: 3))，来源 \($0.source)，行情时间 \($0.time.formatted(date: .numeric, time: .shortened))，\($0.isFresh(at: now) ? "新鲜" : "已过期/需核对")"
            } ?? "无报价"
            let weight: String
            if let total = book.total(using: quotes), total > 0, let quote {
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
                line += "；网格 \(plan.tiers.count) 档，间距 \(String(format: "%.2f", plan.spacingPercent))%，最大占用 ¥\(NextMoney.text(plan.maxCashUsage))"
            }
            if case .insufficientData(_, let reasons) = item.tPlan {
                line += "；数据不足不出价（\(reasons.first ?? "")）"
            }
            if let note = item.portfolioNote { line += "；组合：\(note)" }
            planLines.append(line)
        }
        let promptBlock = """
        你是观盘顾问，一位只基于用户真实持仓工作的投资顾问。以下是本次统一决策上下文，只能在此基础上给建议：
        【账户】现金 ¥\(NextMoney.text(book.cash))；持仓 \(book.positions.count) 只。
        【持仓】\(holdings.joined(separator: "\n"))
        【A股交易日历】\(NextMarketClock.sessionDescription(now))。休市日、周末、盘前、午休和收盘后不得描述为“今天可挂”；只能引用规则引擎给出的有效候选计划，计划缺失就明确说没有当日可执行价格。
        【市场状态与候选计划】\(planLines.joined(separator: "\n"))
        【NAS 长期研究】\(nasResearchLines.isEmpty ? "暂无（NAS 离线或未返回）" : nasResearchLines.joined(separator: "\n"))
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
        """
        return NextDecisionContext(generatedAt: now, guidance: guidance, holdingsLines: holdings,
                                   nasResearchLines: nasResearchLines, newsLines: newsLines,
                                   profileLines: profileLines, promptBlock: promptBlock)
    }
}
