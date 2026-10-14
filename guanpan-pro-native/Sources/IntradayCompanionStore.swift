import Foundation

struct IntradayCompanionDecision {
    enum Level: String { case ready = "条件较匹配", wait = "等待确认", avoid = "暂不建议", invalid = "计划/数据不足" }
    var level: Level
    var reasons: [String]
    var summary: String { reasons.joined(separator: "；") }

    func title(for side: IntradayCompanionIntent.Side) -> String {
        switch (side, level) {
        case (.buy, .ready): return "回调与企稳条件较匹配，可考虑分批"
        case (.buy, .wait): return "先等止跌或反弹确认"
        case (.buy, .avoid): return "下行风险偏高，暂不建议抄底"
        case (.sell, .ready): return "出现多项减仓依据，可评估分批减仓"
        case (.sell, .wait): return "卖出依据不足，先观察持仓趋势"
        case (.sell, .avoid): return "目前没有足够理由支持卖出"
        case (_, .invalid): return "计划或行情数据不足，无法判断"
        }
    }
}

@MainActor extension PortfolioStore {
    private func companionDay(_ date: Date = .now) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func saveIntradayCompanionIntent(code: String, name: String,
                                     side: IntradayCompanionIntent.Side, quantity: Double) throws {
        guard !code.isEmpty, quantity.isFinite, quantity > 0 else { throw StoreError.invalidAlert }
        let intent = IntradayCompanionIntent(code: code, name: name, side: side, quantity: quantity)
        if let i = data.intradayCompanionIntents.firstIndex(where: { $0.code == code }) { data.intradayCompanionIntents[i] = intent }
        else { data.intradayCompanionIntents.append(intent) }
        save(label: "设置盘中 AI 陪伴")
    }
    func removeIntradayCompanionIntent(code: String) {
        data.intradayCompanionIntents.removeAll { $0.code == code }; save(label: "关闭盘中 AI 陪伴")
    }
    func intradayCompanionDecision(code: String, side: IntradayCompanionIntent.Side,
                                   quantity: Double, price explicit: Double? = nil) -> IntradayCompanionDecision {
        guard quantity > 0, quantity.isFinite else { return .init(level: .invalid, reasons: ["先填写有效份额"]) }
        let holding = data.holdings.first { $0.code == code && $0.kind == .etf }
        let price = explicit ?? data.quotes.first(where: { $0.code == code })?.price ?? holding?.current ?? 0
        guard price > 0 else { return .init(level: .invalid, reasons: ["缺少可核实的最新价格"]) }
        if side == .sell, (holding?.quantity ?? 0) <= 0 {
            return .init(level: .invalid, reasons: ["当前没有这只标的的持仓"])
        }
        if side == .sell, quantity > (holding?.quantity ?? 0) { return .init(level: .invalid, reasons: ["卖出份额超过当前持仓"]) }
        let amount = quantity * price
        let currentHoldingValue = (holding?.quantity ?? 0) * price
        let after = max(0, currentHoldingValue + (side == .buy ? amount : -amount))
        let weight = after / max(totalAsset, 0.01) * 100
        let limit = holding?.maxPositionPercent ?? (data.globalPositionLimitPercent > 0 ? data.globalPositionLimitPercent : data.investmentProfile.maxPositionPercent)
        if side == .buy, limit > 0, weight > limit { return .init(level: .avoid, reasons: ["买入后仓位约 \(weight.num(1))%，超过上限 \(limit.num(1))%"] ) }
        let profile = data.investmentProfile
        let riskName: String
        switch profile.risk {
        case "low", "conservative", "con", "保守": riskName = "保守"
        case "high", "aggressive", "agg", "激进": riskName = "激进"
        default: riskName = "平衡"
        }
        let styleName: String
        switch profile.style {
        case "scalp", "day": styleName = "超短线"
        case "short": styleName = "短线"
        case "mid", "medium": styleName = "中线"
        case "long": styleName = "长线定投"
        default: styleName = "波段"
        }
        let declaredPreference = profile.preference.trimmingCharacters(in: .whitespacesAndNewlines)
        let alreadyIncludesDip = declaredPreference.localizedCaseInsensitiveContains("抄底")
            || declaredPreference.localizedCaseInsensitiveContains("回调")
        let dipPreference = declaredPreference.isEmpty
            ? "喜欢抄底，偏好回调后分批布局（按你刚刚说明）"
            : (alreadyIncludesDip ? declaredPreference : "\(declaredPreference)；同时喜欢抄底、偏好回调后分批布局")
        var reasons = ["画像：\(styleName) · \(riskName) · 持有周期 \(profile.horizon) · 偏好：\(dipPreference)",
                       "若按此意图成交，单标的仓位约 \(weight.num(1))%；参考上限 \(limit.num(1))%（仅作风险提示）"]
        var strength = 0
        var sellRiskSignals = 0
        var dipSetup = false
        var stabilization = false
        let today = companionDay()
        let minutePoints = intradayBars(code: code, day: today)
        let prices = minutePoints.map(\.price)
        if !prices.isEmpty {
            let avg = prices.reduce(0, +) / Double(prices.count)
            if price < avg {
                dipSetup = true
                strength += 1
                reasons.append("现价低于今日分时均价，符合回调观察条件；这本身不是买点")
            } else {
                reasons.append("现价回到今日分时均价上方，短线有修复迹象")
                strength += 1
                stabilization = true
            }
        } else { reasons.append("今日分时样本不足，不能确认盘中低点或反弹") }
        if prices.count >= 6 {
            let recent = prices.suffix(3).reduce(0, +) / 3
            let prior = prices.suffix(6).prefix(3).reduce(0, +) / 3
            if recent > prior * 1.001 {
                stabilization = true
                strength += 1
                reasons.append("最近几分钟均价抬高，出现初步企稳迹象")
            } else if recent < prior * 0.999 {
                strength -= 2
                sellRiskSignals += 1
                reasons.append("最近几分钟仍在走低，暂不把下跌当成抄底信号")
            } else {
                reasons.append("最近几分钟横盘，暂未确认反弹")
            }
        }
        let completed = (dailyBars[code] ?? []).filter { $0.date < today }
        if completed.count >= 20 {
            let recentBars = Array(completed.suffix(20))
            let ma20 = recentBars.map(\.close).reduce(0, +) / 20
            if price < ma20 {
                dipSetup = true
                strength += 1
                sellRiskSignals += 1
                reasons.append("现价低于 MA20，属于回调区域；需看企稳和风险，不因破线自动买入")
            } else {
                reasons.append("现价在 MA20 上方，趋势确认较好，但不属于明显低位")
            }
            let low20 = recentBars.map(\.low).min() ?? ma20
            let high20 = recentBars.map(\.high).max() ?? ma20
            let rangePosition = high20 > low20 ? (price - low20) / (high20 - low20) : 0.5
            if rangePosition <= 0.2 {
                dipSetup = true
                strength += 1
                reasons.append("处于近 20 日区间低位，和你的抄底偏好相符")
            } else if rangePosition >= 0.8, side == .buy {
                strength -= 1
                reasons.append("已接近近 20 日区间高位，追买与抄底偏好不符")
            }
            if completed.count >= 60 {
                let ma60 = completed.suffix(60).map(\.close).reduce(0, +) / 60
                if price < ma20 && ma20 < ma60 {
                    strength -= 2
                    sellRiskSignals += 1
                    stabilization = false
                    reasons.append("MA20 低于 MA60 且现价在 MA20 下方，中期下行风险较高")
                }
            }
        }
        if let change = marketChanges[code] {
            reasons.append("当日涨跌 \((change * 100).pct(2))")
            if side == .buy {
                if change <= -0.003 && change > -0.03 { dipSetup = true; strength += 1; reasons.append("当日回落幅度可纳入分批观察") }
                if change <= -0.03 { strength -= 2; stabilization = false; reasons.append("当日跌幅较大，先观察是否止跌，避免接住加速下跌") }
                if change >= 0.03 { strength -= 1; reasons.append("当日涨幅较大，避免因上涨追买") }
            } else if change <= -0.02 {
                strength -= 1
                sellRiskSignals += 1
                reasons.append("明显走弱需复核持仓风险，但不能只因下跌就卖出")
            }
        }
        let currentHoldingWeight = currentHoldingValue / max(totalAsset, 0.01) * 100
        if side == .sell, let holding, let holdingLimit = holding.maxPositionPercent,
           currentHoldingWeight > holdingLimit {
            sellRiskSignals += 1
            reasons.append("当前仓位约 \(currentHoldingWeight.num(1))%，高于该标的上限 \(holdingLimit.num(1))%；本次计划后约 \(weight.num(1))%")
        } else if side == .sell, holding?.maxPositionPercent == nil,
                  profile.maxPositionPercent > 0, currentHoldingWeight > profile.maxPositionPercent {
            sellRiskSignals += 1
            reasons.append("当前仓位约 \(currentHoldingWeight.num(1))%，高于画像单仓上限 \(profile.maxPositionPercent.num(1))%；本次计划后约 \(weight.num(1))%")
        }
        if side == .sell, let holding, holding.cost > 0 {
            let pnlPercent = (price / holding.cost - 1) * 100
            reasons.append("当前相对持仓成本\(pnlPercent >= 0 ? "盈利" : "浮亏")约 \(abs(pnlPercent).num(2))%；盈亏本身不单独作为卖出理由")
        }
        let avoidText = profile.avoid.trimmingCharacters(in: .whitespacesAndNewlines)
        let holdingNameIsAvoided = holding.map { avoidText.localizedCaseInsensitiveContains($0.name) } ?? false
        let avoidBuy = side == .buy && !avoidText.isEmpty && (
            avoidText.localizedCaseInsensitiveContains(code)
            || holdingNameIsAvoided
            || (dipSetup && (avoidText.localizedCaseInsensitiveContains("抄底")
                             || avoidText.localizedCaseInsensitiveContains("下跌")))
            || (!dipSetup && (avoidText.localizedCaseInsensitiveContains("追涨")
                              || avoidText.localizedCaseInsensitiveContains("追高")
                              || avoidText.localizedCaseInsensitiveContains("高位买")))
        )
        if avoidBuy { strength -= 3; reasons.append("当前买入情景触发了你的画像回避项：\(avoidText)") }
        if side == .buy && riskName == "保守" && !stabilization {
            strength -= 1
            reasons.append("保守风险偏好：还没企稳时不建议仅因价格低而抄底")
        }
        if side == .buy && riskName == "激进" && dipSetup && stabilization { strength += 1 }
        let level: IntradayCompanionDecision.Level
        if side == .buy {
            let readyThreshold = riskName == "保守" ? 3 : (riskName == "激进" ? 1 : 2)
            level = dipSetup && stabilization && strength >= readyThreshold ? .ready : (strength <= -2 ? .avoid : .wait)
        } else {
            // 数量足够只代表账本份额校验通过。卖出建议要求至少两项相互独立的风险/仓位依据；
            // 单纯浮亏、日内下跌或用户填了卖出份额，都不会被当成卖出理由。
            let sellThreshold = (profile.style == "long" || riskName == "保守") ? 3 : 2
            if sellRiskSignals >= sellThreshold {
                level = .ready
                reasons.append("卖出判断来自上述多项趋势/仓位信号，仍建议按计划分批复核，不是自动下单")
            } else if sellRiskSignals == 1 {
                level = .wait
                reasons.append("目前只有一项减仓依据，尚不足以确认卖点")
            } else {
                level = .avoid
                reasons.append("份额充足只是可卖校验通过；当前没有足够技术或仓位理由支持卖出")
            }
        }
        return .init(level: level, reasons: reasons)
    }
    func evaluateIntradayCompanions() {
        var changed = false
        for i in data.intradayCompanionIntents.indices where data.intradayCompanionIntents[i].enabled {
            let intent = data.intradayCompanionIntents[i]
            let decision = intradayCompanionDecision(code: intent.code, side: intent.side, quantity: intent.quantity)
            let key = decision.level.rawValue + "|" + decision.summary
            guard key != intent.lastDecision else { continue }
            let previousLevel = intent.lastDecision.split(separator: "|", maxSplits: 1).first.map(String.init)
            data.intradayCompanionIntents[i].lastDecision = key
            changed = true
            // 价格百分比会随刷新变化，不能每次文字变动都推通知；只有结论档位改变才提醒。
            if previousLevel != decision.level.rawValue {
                data.intradayCompanionIntents[i].lastNotifiedAt = .now
                Task { try? await NativeNotifications.send(title: "观盘 Pro · 盘中 AI 陪伴", body: "\(intent.name)：\(decision.title(for: intent.side))。\(decision.summary)") }
            }
        }
        if changed { save(label: nil) }
    }

    /// 当天快照的结算状态。
    ///
    /// **只用于「今天」这一条**：历史快照的 quality 和数值一样，写入即冻结
    /// （见 `clearStaleSnapshotBackfillNotes`），不会再被重算 —— 所以下面
    /// `day != today` 那半段只是给按日查询留的，正常流程走不到。
    func snapshotQuality(for day: String) -> PortfolioSnapshot.Quality {
        let funds = data.holdings.filter { $0.kind == .fund && $0.quantity > 0 }
        return funds.allSatisfy { fund in
            let points = data.fundNAVHistory.filter { $0.code == fund.code }
            if day == companionDay() {
                // 今日快照要等今天实际取到新公布净值；昨天的近似净值不能让它提前显示已结算。
                guard let latest = points.max(by: { $0.date < $1.date }) else { return false }
                if let fetchedAt = latest.fetchedAt { return companionDay(fetchedAt) == day }
                return latest.date == day
            }
            guard let latest = points.filter({ $0.date <= day }).max(by: { $0.date < $1.date }) else { return false }
            return calendarDayDistance(from: latest.date, to: day).map { $0 <= 4 } ?? false
        } ? .settled : .provisional
    }

    /// **历史快照一经写入即定稿：迟到的净值不再回头改写它。**
    ///
    /// 这是用户 2026-10-14 当面确认的口径，也是这个 App 里最容易写反的一处。
    /// 场外基金净值滞后公布是常态（美股 / QDII 常晚一个交易日以上），所以
    /// **14 号那天能取到的最新净值，可能标着 9 号** —— 14 号的账户就值这么多。
    /// 事后拿真正属于 9 号的那份净值回头重算 9 号（或 14 号）的快照，会坏两件事：
    /// ① 用户当天明明看到的数字，过一天自己变了 —— 快照就不再是「账实核对」的记录；
    /// ② 区间收益被追溯修改，复盘时无法归因到某一天。
    /// 所以 `total` / `cash` / `quality` 落盘即冻结，只有**今天**那一条随行情刷新
    /// （当天还没结束，尚未定稿，见 `refreshTodaySnapshotIfPresent`）。
    /// 净值公布得慢这件事，靠界面把「这条快照用的是哪个净值日」标出来解释，而不是改数。
    ///
    /// 本函数只做迁移：把老版本 `reconcileProvisionalSnapshotsAfterNAVUpdate`
    /// 留下的「迟到净值到达后会回补」这类已经不成立的说明清掉，数值一个都不动。
    @discardableResult func clearStaleSnapshotBackfillNotes() -> Int {
        var changed = 0
        for index in data.snapshots.indices {
            guard let note = data.snapshots[index].note else { continue }
            guard note.contains("迟到净值") || note.contains("按净值日期检查") else { continue }
            data.snapshots[index].note = data.snapshots[index].quality == .provisional
                ? "记录时仍有场外基金未公布当日净值；该日总资产按当时能取到的最新已公布净值估值"
                : nil
            changed += 1
        }
        return changed
    }

    func recordManualSnapshot(date: String, total: Double, cash: Double? = nil) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date,
              date <= companionDay(), total.isFinite, total >= 0 else {
            throw StoreError.invalidManualSnapshot
        }
        // 总资产手动校正不应强迫用户拆分现金。已有日期保留该日现金；
        // 新建日期优先沿用最近一条不晚于该日的快照现金，没有历史基准才用当前参考现金。
        let existing = data.snapshots.first { $0.date == date }
        let priorCash = data.snapshots.filter { $0.date <= date }.max { $0.date < $1.date }?.cash
        let resolvedCash = cash ?? existing?.cash ?? priorCash ?? data.cash
        guard resolvedCash.isFinite, resolvedCash >= 0 else { throw StoreError.invalidManualSnapshot }
        let point = PortfolioSnapshot(date: date, total: total, cash: min(resolvedCash, total), recordedAt: nil,
                                      quality: .manual, note: "手动录入并核实的真实总资产；现金沿用快照")
        if let index = data.snapshots.firstIndex(where: { $0.date == date }) { data.snapshots[index] = point }
        else { data.snapshots.append(point) }
        data.snapshots.sort { $0.date < $1.date }
        save(label: "手动校正历史快照")
    }

    private func calendarDayDistance(from start: String, to end: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let a = formatter.date(from: start), let b = formatter.date(from: end) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.dateComponents([.day], from: a, to: b).day
    }
    /// 补建「此前没有记录的日期」的快照，全部标 `.reconstructed`（事后推算，蓝标）。
    ///
    /// **只填空缺，绝不改已有记录** —— 已经记过的日期会在下面的 `existing` 集合里被跳过，
    /// 所以它永远不会碰用户当天看到的那个数字（见 `clearStaleSnapshotBackfillNotes` 的口径）。
    @discardableResult func backfillVerifiableSnapshots(audit: Bool = true) -> (added: Int, skipped: Int) {
        let today = companionDay(), existing = Set(data.snapshots.map(\.date))
        var days = Set(dailyBars.values.flatMap { $0.map(\.date) }); days.formUnion(data.fundNAVHistory.map(\.date))
        // 绝不能把“行情缓存最早的一天”当成账户起点。此前这会在账户尚未建立、
        // 甚至持仓尚未出现的日期，补出一串 0 元或错误现金的伪快照。
        let activityDays = data.ledger.filter { ($0.kind ?? .etf) == .etf && ($0.affectsHoldings ?? true) }
            .map { companionDay($0.date) }
            + data.cashFlows.filter { $0.affectsCash ?? true }.map { companionDay($0.date) }
            + data.fundTransactions.filter { $0.status == .confirmed }.map(\.effectiveDate)
        guard let accountStartDay = activityDays.filter({ !$0.isEmpty }).min() else {
            return (added: 0, skipped: 0)
        }
        let etfPrices = dailyBars.mapValues { Dictionary($0.map { ($0.date, $0.close) }, uniquingKeysWith: { _, newest in newest }) }
        let fundPrices = Dictionary(grouping: data.fundNAVHistory.filter { $0.nav.isFinite && $0.nav > 0 }, by: \.code)
            .mapValues { $0.sorted { $0.date < $1.date } }
        var added = 0, skipped = 0
        for day in days.filter({ $0 >= accountStartDay && $0 < today && !existing.contains($0) }).sorted() {
            guard let state = reconstructedState(on: day) else { skipped += 1; continue }
            var total = state.cash, complete = state.cash.isFinite && state.cash >= -0.01
            for position in state.positions where position.quantity > 0.000001 {
                let price: Double?
                if position.kind == .fund {
                    // 境外/QDII 净值通常次日公布；净值日期仍是它代表的估值日。
                    // 用截至目标日最近的已公布净值，避免“日期不完全相等”导致整日资产和盈亏被漏算。
                    price = fundPrices[position.code]?.last(where: { $0.date <= day })?.nav
                } else {
                    price = etfPrices[position.code]?[day]
                }
                guard let price, price.isFinite, price > 0 else { complete = false; break }
                total += position.quantity * price
            }
            guard complete else { skipped += 1; continue }
            data.snapshots.append(.init(date: day, total: total, cash: max(0, state.cash), recordedAt: nil,
                                        quality: .reconstructed,
                                        note: "事后推算（当天没有记录）：按流水与历史价格反推，场外基金用截至当日最近已公布净值")); added += 1
        }
        if added > 0 {
            data.snapshots.sort { $0.date < $1.date }
            save(label: audit ? "补全可核实历史快照" : nil)
        }
        return (added, skipped)
    }

    func removeSnapshot(date: String) {
        guard data.snapshots.contains(where: { $0.date == date }) else { return }
        data.snapshots.removeAll { $0.date == date }
        save(label: "删除历史快照")
    }

    @discardableResult func removeReconstructedSnapshots() -> Int {
        let before = data.snapshots.count
        data.snapshots.removeAll { $0.quality == .reconstructed }
        let removed = before - data.snapshots.count
        if removed > 0 { save(label: "清除历史重建快照") }
        return removed
    }

    private func reconstructedState(on day: String) -> (cash: Double, positions: [(code: String, kind: Holding.Kind, quantity: Double)])? {
        // 历史快照会永久影响收益曲线，不能把今天手工录入的持仓猜成过去已持有。
        // 先验证有效流水能完整解释当前份额，再按目标日正向重放；缺少期初基线时宁可留空。
        let etfTrades = data.ledger.filter {
            ($0.kind ?? .etf) == .etf && ($0.affectsHoldings ?? true)
        }
        let fundTrades = data.fundTransactions.filter { $0.status == .confirmed }
        var currentByID: [String: Double] = [:]
        for holding in data.holdings { currentByID[holding.id] = holding.quantity }

        var explainedNow: [String: Double] = [:]
        for trade in etfTrades {
            explainedNow["etf-\(trade.code)", default: 0] += trade.side == .buy ? trade.quantity : -trade.quantity
        }
        for trade in fundTrades {
            let id = "fund-\(trade.code)"
            switch trade.side {
            case .buy: explainedNow[id, default: 0] += trade.quantity
            case .sell: explainedNow[id, default: 0] -= trade.quantity
            case .dividend where trade.dividendMode == .reinvest: explainedNow[id, default: 0] += trade.quantity
            case .dividend: break
            }
        }
        let allIDs = Set(currentByID.keys).union(explainedNow.keys)
        guard allIDs.allSatisfy({ id in
            let actual = currentByID[id, default: 0]
            let explained = explainedNow[id, default: 0]
            return actual.isFinite && explained.isFinite && abs(actual - explained) <= max(0.02, abs(actual) * 0.000_001)
        }) else { return nil }

        var quantities: [String: (Holding.Kind, Double)] = [:]
        for trade in etfTrades where companionDay(trade.date) <= day {
            let id = "etf-\(trade.code)"
            var row = quantities[id] ?? (.etf, 0)
            row.1 += trade.side == .buy ? trade.quantity : -trade.quantity
            quantities[id] = row
        }
        for trade in fundTrades where trade.effectiveDate <= day {
            let id = "fund-\(trade.code)"
            var row = quantities[id] ?? (.fund, 0)
            switch trade.side {
            case .buy: row.1 += trade.quantity
            case .sell: row.1 -= trade.quantity
            case .dividend where trade.dividendMode == .reinvest: row.1 += trade.quantity
            case .dividend: break
            }
            quantities[id] = row
        }
        guard quantities.values.allSatisfy({ $0.1.isFinite && $0.1 >= -0.001 }) else { return nil }

        var cash = data.cash
        for flow in data.cashFlows where companionDay(flow.date) > day && (flow.affectsCash ?? true) {
            cash -= flow.amount
        }
        // 基金手工交易同时有证券 ledger 与基金确认流水；现金只能各还原一次，避免重复回滚。
        for trade in etfTrades where trade.linkedCash && companionDay(trade.date) > day {
            if trade.side == .buy { cash += trade.gross + trade.fee }
            else { cash -= trade.gross - trade.fee }
        }
        for trade in fundTrades where trade.effectiveDate > day && trade.linkedCash {
            switch trade.side {
            case .buy: cash += trade.amount + trade.fee
            case .sell: cash -= trade.amount - trade.fee
            case .dividend where trade.dividendMode == .cash: cash -= trade.amount
            case .dividend: break
            }
        }
        guard cash.isFinite, cash >= -0.01 else { return nil }
        let positions = quantities.compactMap { key, value -> (String, Holding.Kind, Double)? in
            let prefix = value.0 == .etf ? "etf-" : "fund-"
            guard key.hasPrefix(prefix) else { return nil }
            return (String(key.dropFirst(prefix.count)), value.0, max(0, value.1))
        }
        return (max(0, cash), positions)
    }
}
