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
            state?["rulesUnconfirmed"] = positions.filter { $0["tradingRuleConfirmed"] as? Bool != true }.compactMap { $0["symbol"] }
        }
        guard let state else { throw InvestmentLabStore.LabError.message("账户数据不可用") }
        if let quality = channels.marketDocument?["quality"] as? [String: Any], let data = quality["researchSnapshot"] as? [String: Any] {
            return (state, data)
        }
        let held = portfolio.data.holdings.filter { $0.kind == .etf }
        let seed = state["seed"] as? [String: Any] ?? [:]
        let catalog = state["catalog"] as? [String: [String: Any]] ?? [:]
        let definitions = (seed["positions"] as? [[String: Any]] ?? []) + Array(catalog.values)
        let formatter = ISO8601DateFormatter()
        let instruments = definitions.map { p -> [String: Any] in
            let symbol = p["symbol"] as? String ?? ""
            var row: [String: Any] = ["symbol": symbol, "asset": p["asset"] ?? "etf", "source": "iOS 本机缓存", "evidenceIDs": ["local:\(symbol)"]]
            if let h = held.first(where: { $0.code == symbol }), let stamp = h.marketUpdatedAt,
               h.current.isFinite, h.current > 0, let price = try? InvestmentLabStore.units(h.current) {
                row["quote"] = ["at": Int64(stamp.timeIntervalSince1970 * 1000), "price": price]
            }
            row["bars"] = (portfolio.dailyBars[symbol] ?? []).compactMap { b -> [String: Any]? in
                guard let close = try? InvestmentLabStore.units(b.close), let date = formatter.date(from: b.date + "T15:00:00+08:00") else { return nil }
                let at = Int64(date.timeIntervalSince1970 * 1000)
                return ["at": at, "availableAt": at, "close": close]
            }
            return row
        }
        return (state, ["asOf": now, "scope": "local-confirmed-instruments", "instruments": instruments])
    }
}
