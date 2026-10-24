import SwiftUI

struct ETFTradingRuleView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.visualTheme) private var theme
    private var tokens: DesignTokens { ThemeManager.tokens(theme) }

    var body: some View {
        List {
            Section {
                Text("具体 ETF 的 T+0/T+1、最小单位及可卖份额，请按券商显示与交易所资料逐只核对。未确认时，AI 不生成具体挂单价格。可卖份额只在短时间内有效。")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Link("查看上交所 ETF 回转交易说明",
                     destination: URL(string: "https://www.sse.com.cn/assortment/fund/etf/question/c/c_20240118_5734755.shtml")!)
            }
            Section("真实 ETF 持仓") {
                ForEach(store.data.holdings.filter { $0.kind == .etf && $0.quantity > 0 }) { holding in
                    NavigationLink {
                        ETFTradingRuleEditor(holding: holding)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(holding.name).font(.headline)
                            Text(holding.code).font(.caption).foregroundStyle(.secondary)
                            if let rule = store.data.etfTradeRules.first(where: { $0.symbol == holding.code }) {
                                Text(rule.settlement == .sameDay ? "已核对 T+0" : "已核对 T+1")
                                    .font(.caption).foregroundStyle(tokens.accent)
                            } else {
                                Text("交易规则未核对").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle("逐只核对交易规则")
    }
}

private struct ETFTradingRuleEditor: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding
    @State private var settlement: ETFTradeRule.Settlement = .nextDay
    @State private var lot = "100"
    @State private var tick = "0.001"
    @State private var fee = "0.10"
    @State private var sellable = ""
    @State private var source = ""
    @State private var error = ""

    var body: some View {
        Form {
            Section("请按券商核对 · \(holding.name)") {
                Picker("回转规则", selection: $settlement) {
                    Text("T+0").tag(ETFTradeRule.Settlement.sameDay)
                    Text("T+1").tag(ETFTradeRule.Settlement.nextDay)
                }.pickerStyle(.segmented)
                TextField("每手份额", text: $lot).keyboardType(.numberPad)
                TextField("最小价格变动（元）", text: $tick).keyboardType(.decimalPad)
                TextField("ETF 每笔手续费（元）", text: $fee).keyboardType(.decimalPad)
                TextField("券商当前可卖份额（可留空）", text: $sellable).keyboardType(.decimalPad)
                TextField("核对依据，例如券商证券详情", text: $source)
                Text("手工填入的可卖份额最多按 5 分钟内有效；过期需重新核对。未填时反T不生成具体份额。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("交易规则")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("确认保存") { save() } }
        }
        .onAppear {
            guard let rule = store.data.etfTradeRules.first(where: { $0.symbol == holding.code }) else { return }
            settlement = rule.settlement
            lot = String(rule.lotSize)
            tick = String(rule.tickYuan)
            fee = String(rule.feePerFillYuan)
            source = rule.confirmationSource
            if let shares = rule.brokerSellableShares { sellable = String(shares) }
        }
    }

    private func save() {
        let currentShares = store.data.holdings.first(where: { $0.code == holding.code && $0.kind == .etf })?.quantity ?? 0
        guard let lotSize = Int(lot), lotSize > 0, lotSize <= 100_000,
              let tickYuan = Double(tick), tickYuan.isFinite, tickYuan > 0, tickYuan <= 1,
              let feeYuan = Double(fee), feeYuan.isFinite, feeYuan >= 0,
              let sellableShares = sellable.isEmpty ? 0 : Double(sellable),
              sellableShares.isFinite, sellableShares >= 0,
              sellableShares <= currentShares + 1e-8,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "请核对交易单位、价格档位、手续费、可卖份额和依据。"
            return
        }
        let now = Date.now
        let rule = ETFTradeRule(symbol: holding.code, settlement: settlement, lotSize: lotSize,
                                tickYuan: tickYuan, feePerFillYuan: feeYuan, confirmedAt: now,
                                confirmationSource: source.trimmingCharacters(in: .whitespacesAndNewlines),
                                brokerSellableShares: sellable.isEmpty ? nil : sellableShares,
                                sellableCheckedAt: sellable.isEmpty ? nil : now)
        store.data.etfTradeRules.removeAll { $0.symbol == holding.code }
        store.data.etfTradeRules.append(rule)
        store.save(label: "逐只核对 ETF 交易规则")
        dismiss()
    }
}
