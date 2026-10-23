import SwiftUI

struct SimulationFeeSettingsView: View {
    @EnvironmentObject private var lab: InvestmentLabStore
    @State private var minimum = "5"
    @State private var rate = ""
    @State private var tax = ""
    @State private var slip = "0"
    @State private var message = ""
    var body: some View {
        Form {
            Section("ETF 固定费用") {
                Text("买入、卖出每个成交事件固定 0.10 元，不随成交金额变化。多次部分成交各自记录费用。")
            }
            Section("股票估算 · 按实际券商规则确认") {
                TextField("最低佣金（元）", text: $minimum).keyboardType(.decimalPad)
                TextField("佣金率（%，空白表示待确认）", text: $rate).keyboardType(.decimalPad)
                TextField("卖出税费率（%，空白表示待确认）", text: $tax).keyboardType(.decimalPad)
            }
            Section("额外滑点") {
                TextField("额外价格档数（整数，默认 0）", text: $slip).keyboardType(.numberPad)
                Text("盘口本身的买卖价差仍按盘口价格处理，不会被额外滑点重复计费。")
            }
            Button("保存为新的模拟费用版本") { save() }
            Text(message.isEmpty ? SimulationCostPolicy.note : message).font(.caption)
        }
        .scrollContentBackground(.hidden).navigationTitle("模拟费用版本")
        .onAppear {
            let d = UserDefaults.standard
            minimum = String(SimulationCostPolicy.stockMinimum)
            slip = String(Int(SimulationCostPolicy.extraSlippageTicks))
            if d.bool(forKey: "guanpan.simulation.stockRateConfirmed.v2") { rate = String(d.double(forKey: "guanpan.simulation.stockRate.v2") * 100) }
            if d.bool(forKey: "guanpan.simulation.stockTaxConfirmed.v2") { tax = String(d.double(forKey: "guanpan.simulation.stockSellTax.v2") * 100) }
        }
    }
    private func save() {
        guard let minFee = Double(minimum), minFee.isFinite, (0...10000).contains(minFee),
              let ticks = Int(slip), (0...100).contains(ticks) else { message = "请检查最低佣金和滑点"; return }
        let r = rate.isEmpty ? nil : Double(rate), t = tax.isEmpty ? nil : Double(tax)
        guard (rate.isEmpty || r.map { $0.isFinite && (0...2).contains($0) } == true),
              (tax.isEmpty || t.map { $0.isFinite && (0...2).contains($0) } == true) else { message = "请检查百分比，未知可留空"; return }
        let version = "fee-" + UUID().uuidString
        let policy: [String: Any] = ["version": version, "etfFee": 1000, "stockMinimum": Int64((minFee * 10000).rounded()),
            "stockRatePPM": r.map { Int(($0 * 10000).rounded()) as Any } ?? NSNull(),
            "stockSellTaxPPM": t.map { Int(($0 * 10000).rounded()) as Any } ?? NSNull(), "extraSlippageTicks": ticks]
        if lab.state != nil, !lab.action(["type": "feePolicy", "policy": policy]) { message = lab.message; return }
        let d = UserDefaults.standard
        var history = d.array(forKey: "guanpan.simulation.feeHistory.v2") as? [[String: Any]] ?? []
        if let bytes = try? JSONSerialization.data(withJSONObject: policy), let string = String(data: bytes, encoding: .utf8) {
            history.append(["version": version, "at": Date().timeIntervalSince1970, "json": string])
        }
        d.set(history, forKey: "guanpan.simulation.feeHistory.v2")
        d.set(minFee, forKey: "guanpan.simulation.stockMinimum.v2")
        d.set((r ?? 0) / 100, forKey: "guanpan.simulation.stockRate.v2")
        d.set((t ?? 0) / 100, forKey: "guanpan.simulation.stockSellTax.v2")
        d.set(r != nil, forKey: "guanpan.simulation.stockRateConfirmed.v2")
        d.set(t != nil, forKey: "guanpan.simulation.stockTaxConfirmed.v2")
        d.set(Double(ticks), forKey: "guanpan.simulation.extraSlippageTicks.v2")
        d.set(version, forKey: "guanpan.simulation.feeVersion.v2")
        message = "已保存费用版本；已有挂单继续使用创建时的版本。真实交易费用仍由用户填写。"
    }
}
