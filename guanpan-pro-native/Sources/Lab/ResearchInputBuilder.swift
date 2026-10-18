import Foundation

@MainActor
enum ResearchInputBuilder {
    static func make(portfolio: PortfolioStore, lab: InvestmentLabStore, channels: LabChannelCoordinator, at now: Int64, useVirtual: Bool, forceVirtual: Bool = false) throws -> (state: [String: Any], data: [String: Any]) {
        var state = (forceVirtual || useVirtual) ? lab.state : nil
        if forceVirtual && state == nil { throw InvestmentLabStore.LabError.message("请先创建独立虚拟实验") }
        if state == nil {
            // A temporary research copy only, no implicit persisted virtual account creation.
            let positions = try portfolio.data.holdings.filter { $0.kind == .etf && $0.quantity > 0 }.map { h -> [String: Any] in
                guard h.quantity.isFinite, h.quantity.rounded() == h.quantity, h.quantity < 100_000_000 else { throw InvestmentLabStore.LabError.message("研究份额无效") }
                let isETF = portfolio.isTencentETFCode(h.code)
                let confirmed = (lab.accounts["A"]?["positions"] as? [[String: Any]])?.first { $0["symbol"] as? String == h.code }?["tPlusOne"] as? Bool
                return ["symbol": h.code, "asset": isETF ? "etf" : "stock", "quantity": Int(h.quantity), "cost": try InvestmentLabStore.units(h.cost, allowNegative: true),
                    "price": try InvestmentLabStore.units(h.current), "tick": isETF ? 10 : 100, "lot": 100, "tPlusOne": confirmed ?? false,
                    "tradingRuleConfirmed": confirmed != nil]
            }
            state = try lab.call("create", [["at": now, "cash": try InvestmentLabStore.units(portfolio.data.cash), "positions": positions], UUID().uuidString]) as? [String: Any]
            state?["researchOnly"] = true
            state?["allocationTargets"] = portfolio.data.allocationTargets.filter { $0.kind == .etf }.map { ["symbol": $0.code, "name": $0.name, "targetPercent": $0.targetPercent] as [String: Any] }
            let profile = try JSONSerialization.jsonObject(with: JSONEncoder().encode(portfolio.data.investmentProfile))
            state?["investmentProfile"] = profile
            state?["rulesUnconfirmed"] = positions.filter { $0["tradingRuleConfirmed"] as? Bool != true }.compactMap { $0["symbol"] }
        }
        guard let state else { throw InvestmentLabStore.LabError.message("账户数据不可用") }
        let remote = (channels.marketDocument?["quality"] as? [String: Any])?["researchSnapshot"] as? [String: Any]
        let held = portfolio.data.holdings.filter { $0.kind == .etf }
        let seed = state["seed"] as? [String: Any] ?? [:]
        let catalog = state["catalog"] as? [String: [String: Any]] ?? [:]
        let definitions = (seed["positions"] as? [[String: Any]] ?? []) + Array(catalog.values)
        let formatter = ISO8601DateFormatter()
        let instruments = definitions.map { p -> [String: Any] in
            let symbol = p["symbol"] as? String ?? ""
            var row: [String: Any] = ["symbol": symbol, "asset": p["asset"] ?? "etf", "source": "iOS 本机缓存", "evidenceIDs": ["local:\(symbol)"]]
            var candidates: [(Date, Double)] = []
            if let h = held.first(where: { $0.code == symbol }), let stamp = h.marketUpdatedAt { candidates.append((stamp, h.current)) }
            if let q = portfolio.data.quotes.first(where: { $0.code == symbol }), let stamp = q.updatedAt { candidates.append((stamp, q.price)) }
            if let best = candidates.filter({ $0.0.timeIntervalSince1970 * 1000 <= Double(now) && $0.1.isFinite && $0.1 > 0 }).max(by: { $0.0 < $1.0 }), let price = try? InvestmentLabStore.units(best.1) {
                row["quote"] = ["at": Int64(best.0.timeIntervalSince1970 * 1000), "price": price]
            }
            row["bars"] = (portfolio.dailyBars[symbol] ?? []).compactMap { b -> [String: Any]? in
                guard let close = try? InvestmentLabStore.units(b.close), let date = formatter.date(from: b.date + "T15:00:00+08:00") else { return nil }
                let at = Int64(date.timeIntervalSince1970 * 1000)
                return ["at": at, "availableAt": now, "close": close]
            }
            return row
        }
        return (state, merge(remote: remote, local: instruments, at: now))
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
            return item
        }
        let symbols = Set(rows.compactMap { $0["symbol"] as? String })
        merged += local.filter { !symbols.contains($0["symbol"] as? String ?? "") }
        return ["asOf": at, "scope": "merged-provided-instruments", "universeComplete": false, "instruments": merged,
                "availabilityNote": "本机历史缓存无原始捕获时间，按本次研究时刻才可用；不用于伪造过去时点证据。"]
    }
}
