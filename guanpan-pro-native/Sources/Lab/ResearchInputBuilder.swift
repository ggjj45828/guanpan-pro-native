import Foundation

@MainActor
enum ResearchInputBuilder {
    static func make(portfolio: PortfolioStore, channels: LabChannelCoordinator, at now: Int64) throws -> [String: Any] {
        let remote = (channels.marketDocument?["quality"] as? [String: Any])?["researchSnapshot"] as? [String: Any]
        let held = portfolio.data.holdings.filter { $0.kind == .etf }
        let definitions = held.filter { $0.quantity > 0 }.map { ["symbol": $0.code, "asset": "etf"] }
        let formatter = ISO8601DateFormatter()
        let instruments = definitions.map { p -> [String: Any] in
            let symbol = p["symbol"] as? String ?? ""
            var row: [String: Any] = ["symbol": symbol, "asset": p["asset"] ?? "etf", "source": "iOS 本机缓存", "evidenceIDs": ["local:\(symbol)"]]
            var candidates: [(Date, Double)] = []
            if let h = held.first(where: { $0.code == symbol }), let stamp = h.marketUpdatedAt { candidates.append((stamp, h.current)) }
            if let q = portfolio.data.quotes.first(where: { $0.code == symbol }), let stamp = q.updatedAt { candidates.append((stamp, q.price)) }
            if let best = candidates.filter({ $0.0.timeIntervalSince1970 * 1000 <= Double(now) && $0.1.isFinite && $0.1 > 0 }).max(by: { $0.0 < $1.0 }), let price = try? PhoneResearchEngine.units(best.1) {
                row["quote"] = ["at": Int64(best.0.timeIntervalSince1970 * 1000), "price": price]
            }
            row["bars"] = (portfolio.dailyBars[symbol] ?? []).compactMap { b -> [String: Any]? in
                guard let close = try? PhoneResearchEngine.units(b.close), let date = formatter.date(from: b.date + "T15:00:00+08:00") else { return nil }
                let at = Int64(date.timeIntervalSince1970 * 1000)
                return ["at": at, "availableAt": now, "close": close]
            }
            let cutoff = Date(timeIntervalSince1970: Double(now) / 1000).addingTimeInterval(-120 * 86_400)
            let minuteBars = portfolio.intradayDays(forCode: symbol).prefix(120).flatMap { portfolio.intradayBars(code: symbol, day: $0) }
            row["intradayBars"] = minuteBars
                .filter { $0.timestamp >= cutoff && $0.timestamp.timeIntervalSince1970 * 1000 <= Double(now) }
                .map { bar -> [String: Any] in
                    guard let price = try? PhoneResearchEngine.units(bar.price) else { return [:] }
                    var point: [String: Any] = ["at": Int64(bar.timestamp.timeIntervalSince1970 * 1000),
                        "availableAt": now, "day": bar.day, "price": price]
                    if let volume = bar.volume, volume.isFinite, volume > 0 { point["volume"] = volume }
                    if let iopv = bar.iopv, iopv.isFinite, iopv > 0, let iopvUnits = try? PhoneResearchEngine.units(iopv) { point["iopv"] = iopvUnits }
                    return point
                }
            row["intradaySource"] = "iOS 本机分时缓存；采集源和连续覆盖需核验"
            return row
        }
        var data = merge(remote: remote, local: instruments, at: now)
        let realHoldings = portfolio.data.holdings.filter { $0.kind == .etf && $0.quantity > 0 }.map { holding -> [String: Any] in
            let displayedCost = portfolio.displayedCost(for: holding)
            var row: [String: Any] = ["symbol": holding.code, "name": holding.name, "quantity": holding.quantity,
                "cost": holding.cost, "displayedCost": displayedCost,
                "marketValue": holding.marketValue,
                "pnl": (holding.current - displayedCost) * holding.quantity]
            let configuredLimit = holding.maxPositionPercent
                ?? (portfolio.data.globalPositionLimitPercent > 0
                    ? portfolio.data.globalPositionLimitPercent : portfolio.data.investmentProfile.maxPositionPercent)
            row["maxPositionPercent"] = configuredLimit
            row["limitSource"] = holding.maxPositionPercent != nil ? "逐只持仓设置" :
                portfolio.data.globalPositionLimitPercent > 0 ? "全局仓位设置" : "投资画像旧版设置或默认值"
            if let stamp = holding.marketUpdatedAt { row["quoteAt"] = Int64(stamp.timeIntervalSince1970 * 1000) }
            return row
        }
        let heldCodes = Set(realHoldings.compactMap { $0["symbol"] as? String })
        let rules = portfolio.data.etfTradeRules.compactMap { rule -> [String: Any]? in
            guard heldCodes.contains(rule.symbol), !rule.confirmationSource.isEmpty,
                  rule.confirmedAt.timeIntervalSince1970 * 1000 <= Double(now),
                  rule.lotSize > 0, rule.tickYuan > 0,
                  let tickUnits = try? PhoneResearchEngine.units(rule.tickYuan) else { return nil }
            var row: [String: Any] = [
                "symbol": rule.symbol, "settlement": rule.settlement.rawValue,
                "lotSize": rule.lotSize, "tickUnits": tickUnits,
                "feePerFillYuan": rule.feePerFillYuan,
                "confirmedAt": Int64(rule.confirmedAt.timeIntervalSince1970 * 1000),
                "confirmationSource": rule.confirmationSource
            ]
            if let sellable = rule.brokerSellableShares,
               let checked = rule.sellableCheckedAt,
               Double(now) - checked.timeIntervalSince1970 * 1000 <= 300_000,
               checked.timeIntervalSince1970 * 1000 <= Double(now) {
                row["brokerSellableShares"] = sellable
                row["sellableCheckedAt"] = Int64(checked.timeIntervalSince1970 * 1000)
            }
            return row
        }
        data["realPortfolio"] = ["asOf": now, "cash": portfolio.data.cash,
            "equity": portfolio.data.holdings.reduce(portfolio.data.cash) { $0 + $1.marketValue },
            "holdings": realHoldings, "verifiedTradingRules": rules,
            "holdingRoles": portfolio.data.dynamicInvestorProfile.holdingRules
                .filter { heldCodes.contains($0.symbol) }
                .map { ["symbol": $0.symbol, "role": $0.role.rawValue] },
            "ledger": portfolio.data.ledger.filter { $0.date.timeIntervalSince1970 * 1000 <= Double(now) }
                .suffix(500).map { ["at": Int64($0.date.timeIntervalSince1970 * 1000), "symbol": $0.code,
                    "side": $0.side.rawValue, "quantity": $0.quantity, "price": $0.price, "fee": $0.fee,
                    "affectsHoldings": $0.affectsHoldings ?? true] as [String: Any] }]
        data["profileState"] = ["temporaryPauses": portfolio.data.dynamicInvestorProfile.attributes
            .filter { $0.source == .temporary && $0.id.hasPrefix("pause:") &&
                $0.updatedAt.timeIntervalSince1970 * 1000 <= Double(now) &&
                Double(now) - $0.updatedAt.timeIntervalSince1970 * 1000 <= 86_400_000 }
            .map { String($0.id.dropFirst(6)) }]
        data["news"] = (remote?["news"] as? [[String: Any]] ?? []).filter { item in
            guard let symbol = item["symbol"] as? String,
                  let published = (item["at"] as? NSNumber)?.int64Value,
                  let available = (item["availableAt"] as? NSNumber)?.int64Value else { return false }
            let affected = item["affectedSymbols"] as? [String] ?? []
            let mapped = heldCodes.contains(symbol) || (symbol == "MARKET" &&
                (item["eventScope"] as? String == "market" ||
                    (item["eventScope"] as? String == "industry" && !heldCodes.isDisjoint(with: affected))))
            return mapped && published <= available && available <= now
        }
        if !channels.opportunityScan.isEmpty { data["nasOpportunityScan"] = channels.opportunityScan }
        return data
    }
    static func merge(remote: [String: Any]?, local: [[String: Any]], at: Int64) -> [String: Any] {
        let rows = remote?["instruments"] as? [[String: Any]] ?? []
        var merged = rows.map { old -> [String: Any] in
            guard let symbol = old["symbol"] as? String, let current = local.first(where: { $0["symbol"] as? String == symbol }) else { return old }
            var item = old
            let oldAt = ((old["quote"] as? [String: Any])?["at"] as? NSNumber)?.int64Value ?? 0
            let quote = current["quote"] as? [String: Any]
            let localAt = (quote?["at"] as? NSNumber)?.int64Value ?? 0
            if localAt > oldAt && localAt <= at {
                item["quote"] = quote
                item["source"] = "NAS 历史与基本面 + iOS 最新报价"
                item["evidenceIDs"] = Array(Set((old["evidenceIDs"] as? [String] ?? []) + (current["evidenceIDs"] as? [String] ?? []))).sorted()
            }
            let history = old["bars"] as? [[String: Any]] ?? []
            let known = Set(history.compactMap { ($0["at"] as? NSNumber)?.int64Value })
            item["bars"] = history + (current["bars"] as? [[String: Any]] ?? []).filter { !known.contains(($0["at"] as? NSNumber)?.int64Value ?? 0) }
            let oldMinutes = old["intradayBars"] as? [[String: Any]] ?? []
            let localMinutes = current["intradayBars"] as? [[String: Any]] ?? []
            let knownMinutes = Set(oldMinutes.compactMap { ($0["at"] as? NSNumber)?.int64Value })
            item["intradayBars"] = oldMinutes + localMinutes.filter { !knownMinutes.contains(($0["at"] as? NSNumber)?.int64Value ?? 0) }
            if let source = current["intradaySource"] as? String { item["intradaySource"] = source }
            return item
        }
        let symbols = Set(rows.compactMap { $0["symbol"] as? String })
        merged += local.filter { !symbols.contains($0["symbol"] as? String ?? "") }
        let mergedSymbols = Set(merged.compactMap { $0["symbol"] as? String })
        let books = (remote?["books"] as? [[String: Any]] ?? []).filter { book in
            guard let symbol = book["symbol"] as? String,
                  let bookAt = (book["at"] as? NSNumber)?.int64Value else { return false }
            return mergedSymbols.contains(symbol) && bookAt > 0 && bookAt <= at &&
                book["quantityUnit"] as? String == "shares"
        }
        return ["asOf": at, "scope": "merged-provided-instruments", "universeComplete": false,
                "instruments": merged, "books": books,
                "availabilityNote": "本机历史缓存无原始捕获时间，按本次研究时刻才可用；不用于伪造过去时点证据。"]
    }
}
