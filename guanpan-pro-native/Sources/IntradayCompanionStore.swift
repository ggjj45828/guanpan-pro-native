import Foundation

struct IntradayCompanionDecision {
    enum Level: String { case ready = "可执行", wait = "等确认", avoid = "暂不建议", invalid = "无法执行" }
    var level: Level
    var reasons: [String]
    var summary: String { reasons.joined(separator: "；") }
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
        if side == .sell, quantity > (holding?.quantity ?? 0) { return .init(level: .invalid, reasons: ["卖出份额超过当前持仓"]) }
        let amount = quantity * price
        if side == .buy, amount > data.cash + 0.01 { return .init(level: .invalid, reasons: ["计划金额高于参考现金"]) }
        let after = max(0, (holding?.marketValue ?? 0) + (side == .buy ? amount : -amount))
        let weight = after / max(totalAsset, 0.01) * 100
        let limit = holding?.maxPositionPercent ?? (data.globalPositionLimitPercent > 0 ? data.globalPositionLimitPercent : data.investmentProfile.maxPositionPercent)
        if side == .buy, limit > 0, weight > limit { return .init(level: .avoid, reasons: ["买入后仓位约 \(weight.num(1))%，超过上限 \(limit.num(1))%"] ) }
        var reasons = ["成交后仓位约 \(weight.num(1))%"], strength = 0
        let today = companionDay()
        let prices = intradayBars.filter { $0.code == code && $0.day == today }.map(\.price)
        if !prices.isEmpty {
            let avg = prices.reduce(0, +) / Double(prices.count)
            strength += price >= avg ? 1 : -1; reasons.append(price >= avg ? "现价在分时均价上方" : "现价在分时均价下方")
        } else { reasons.append("分时样本不足，判断降级") }
        let completed = (dailyBars[code] ?? []).filter { $0.date < today }
        if completed.count >= 20 {
            let ma20 = completed.suffix(20).map(\.close).reduce(0, +) / 20
            strength += price >= ma20 ? 1 : -1; reasons.append(price >= ma20 ? "现价在 MA20 上方" : "现价在 MA20 下方")
        }
        if let change = marketChanges[code] { strength += change > 0.003 ? 1 : change < -0.003 ? -1 : 0; reasons.append("当日涨跌 \((change * 100).pct(2))") }
        let level: IntradayCompanionDecision.Level = side == .buy ? (strength >= 2 ? .ready : strength <= -2 ? .avoid : .wait) : (strength <= -2 ? .ready : strength >= 2 ? .wait : .ready)
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
                Task { try? await NativeNotifications.send(title: "观盘 Pro · 盘中 AI 陪伴", body: "\(intent.name)：\(decision.level.rawValue)。\(decision.summary)") }
            }
        }
        if changed { save(label: nil) }
    }

    func snapshotQuality(for day: String) -> PortfolioSnapshot.Quality {
        let funds = data.holdings.filter { $0.kind == .fund && $0.quantity > 0 }
        return funds.allSatisfy { fund in data.fundNAVHistory.contains { $0.code == fund.code && $0.date >= day } } ? .settled : .provisional
    }
    @discardableResult func backfillVerifiableSnapshots() -> (added: Int, skipped: Int) {
        let today = companionDay(), existing = Set(data.snapshots.map(\.date))
        var days = Set(dailyBars.values.flatMap { $0.map(\.date) }); days.formUnion(data.fundNAVHistory.map(\.date))
        let etfPrices = dailyBars.mapValues { Dictionary($0.map { ($0.date, $0.close) }, uniquingKeysWith: { _, newest in newest }) }
        let fundPrices = Dictionary(grouping: data.fundNAVHistory, by: \.code)
            .mapValues { Dictionary($0.map { ($0.date, $0.nav) }, uniquingKeysWith: { _, newest in newest }) }
        var added = 0, skipped = 0
        for day in days.filter({ $0 < today && !existing.contains($0) }).sorted() {
            guard let state = reconstructedState(on: day) else { skipped += 1; continue }
            var total = state.cash, complete = state.cash.isFinite && state.cash >= -0.01
            for position in state.positions where position.quantity > 0.000001 {
                let price = position.kind == .fund
                    ? fundPrices[position.code]?[day]
                    : etfPrices[position.code]?[day]
                guard let price, price.isFinite, price > 0 else { complete = false; break }
                total += position.quantity * price
            }
            guard complete else { skipped += 1; continue }
            data.snapshots.append(.init(date: day, total: total, cash: max(0, state.cash), recordedAt: nil,
                                        quality: .reconstructed,
                                        note: "按真实历史价格、持仓流水与现金流水反向重建")); added += 1
        }
        if added > 0 { data.snapshots.sort { $0.date < $1.date }; save(label: "补全可核实历史快照") }
        return (added, skipped)
    }

    private func reconstructedState(on day: String) -> (cash: Double, positions: [(code: String, kind: Holding.Kind, quantity: Double)])? {
        var quantities: [String: (Holding.Kind, Double)] = [:]
        for holding in data.holdings {
            quantities[holding.id] = (holding.kind, holding.quantity)
        }

        // ETF/证券份额按账本流水从今天反向回放。场外基金使用自己的确认流水，
        // 因为红利再投资不会必然生成一条证券 LedgerEntry。
        // 旧版 ETF 流水的 kind 可能是 nil；账本其它位置一直把 nil 解释为 ETF，
        // 历史快照也必须保持同一口径，否则会漏反推旧交易日前后的份额。
        for trade in data.ledger where (trade.kind ?? .etf) == .etf
            && (trade.affectsHoldings ?? true) && companionDay(trade.date) > day {
            let id = "etf-\(trade.code)"
            var row = quantities[id] ?? (.etf, 0)
            row.1 += trade.side == .buy ? -trade.quantity : trade.quantity
            quantities[id] = row
        }
        for trade in data.fundTransactions where trade.status == .confirmed && trade.effectiveDate > day {
            let id = "fund-\(trade.code)"
            var row = quantities[id] ?? (.fund, 0)
            switch trade.side {
            case .buy: row.1 -= trade.quantity
            case .sell: row.1 += trade.quantity
            case .dividend where trade.dividendMode == .reinvest: row.1 -= trade.quantity
            case .dividend: break
            }
            quantities[id] = row
        }
        guard quantities.values.allSatisfy({ $0.1.isFinite && $0.1 >= -0.001 }) else { return nil }

        var cash = data.cash
        for flow in data.cashFlows where companionDay(flow.date) > day && (flow.affectsCash ?? true) {
            cash -= flow.amount
        }
        for trade in data.ledger where trade.linkedCash && companionDay(trade.date) > day {
            if trade.side == .buy { cash += trade.gross + trade.fee }
            else { cash -= trade.gross - trade.fee }
        }
        for trade in data.fundTransactions where trade.status == .confirmed && trade.effectiveDate > day && trade.linkedCash && trade.side == .dividend && trade.dividendMode == .cash {
            cash -= trade.amount
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
