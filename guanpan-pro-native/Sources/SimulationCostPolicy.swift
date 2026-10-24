import Foundation

/// Shared legacy simulation defaults; real trades continue to use user-entered fees.
@MainActor enum SimulationCostPolicy {
    static var version: String { UserDefaults.standard.string(forKey: "guanpan.simulation.feeVersion.v2") ?? "user-2026-10-v2" }
    static var extraSlippageTicks: Double {
        let raw = UserDefaults.standard.double(forKey: "guanpan.simulation.extraSlippageTicks.v2")
        return raw.isFinite ? min(100, max(0, raw)) : 0
    }
    static var stockMinimum: Double {
        guard let raw = UserDefaults.standard.object(forKey: "guanpan.simulation.stockMinimum.v2") as? Double,
              raw.isFinite, raw >= 0 else { return 5 }
        return raw
    }
    static func fee(isETF: Bool, side: String, amount: Double) -> Double {
        if isETF { return 0.10 }
        let defaults = UserDefaults.standard
        let rate = max(0, min(0.02, defaults.double(forKey: "guanpan.simulation.stockRate.v2")))
        let tax = max(0, min(0.02, defaults.double(forKey: "guanpan.simulation.stockSellTax.v2")))
        return max(stockMinimum, amount * rate) + (side == "sell" ? amount * tax : 0)
    }
    static var note: String {
        "费用版本 \(version)：ETF 每笔成交 0.10 元；额外滑点默认 0。股票佣金率/税费待确认，默认只按最低 5 元估算，可在设置修改。盘口价差不等于额外滑点。"
    }
    static var json: [String: Any] {
        let d = UserDefaults.standard
        return ["version": version, "etfFee": 1000, "stockMinimum": Int64((stockMinimum * 10000).rounded()),
            "stockRatePPM": d.bool(forKey: "guanpan.simulation.stockRateConfirmed.v2") ? Int((d.double(forKey: "guanpan.simulation.stockRate.v2") * 1_000_000).rounded()) as Any : NSNull(),
            "stockSellTaxPPM": d.bool(forKey: "guanpan.simulation.stockTaxConfirmed.v2") ? Int((d.double(forKey: "guanpan.simulation.stockSellTax.v2") * 1_000_000).rounded()) as Any : NSNull(),
            "extraSlippageTicks": Int(extraSlippageTicks)]
    }
}
