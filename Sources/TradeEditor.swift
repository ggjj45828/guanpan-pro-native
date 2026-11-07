import SwiftUI

// MARK: - 成交录入表单（受 Tools/theme_contract.json 管理）
// 文字与固定确认区一律走 ThemeSemantics；从 ContentView.swift 抽出来是为了
// 让静态合同能精确管住这条「键盘 → 录入 → 底部确认」的高频流程。

struct TradeEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearance) private var appearance

    private var s: ThemeSemantics { .of(appearance) }
    private var layout: ThemeLayout { ThemeLayout.of(appearance) }
    let holding: Holding
    @State private var side: LedgerEntry.Side = .buy
    @State private var quantity = ""
    @State private var price = ""
    @State private var fee = "0"
    @State private var linkCash = false
    @State private var tradeDate = Date.now
    @State private var settlementDate = Date.now
    @State private var error = ""
    @State private var feeEstimateText = ""
    @State private var estimatedRedemptionLots: [FundLotRedemption]?
    @State private var estimatedFeeValue: Double?
    @State private var estimatedQuantity = ""
    @State private var estimatedTradeDay = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(holding.name) {
                    Picker("方向", selection: $side) { Text("买入").tag(LedgerEntry.Side.buy); Text("卖出").tag(LedgerEntry.Side.sell) }.pickerStyle(.segmented)
                    TextField("份额", text: $quantity).keyboardType(.decimalPad)
                    TextField("成交价/净值", text: $price).keyboardType(.decimalPad)
                    TextField("手续费", text: $fee).keyboardType(.decimalPad)
                    if holding.kind == .fund {
                        if side == .sell {
                            Button("按所选批次策略估算赎回费") { estimateFundFee() }
                            if !feeEstimateText.isEmpty { Text(feeEstimateText).font(.footnote).foregroundStyle(s.ink2).fixedSize(horizontal: false, vertical: true) }
                        }
                        DatePicker("申请日期", selection: $tradeDate, displayedComponents: .date)
                        DatePicker("确认/净值生效日", selection: $settlementDate, displayedComponents: .date)
                    } else {
                        DatePicker("成交日期", selection: $tradeDate, displayedComponents: .date)
                    }
                    if holding.kind == .etf { Toggle("联动本程序现金", isOn: $linkCash) }
                }
                if !error.isEmpty { Text(error).foregroundStyle(s.danger) }
                Text(holding.kind == .etf ? "ETF 手续费默认按每笔 0.10 元填写，可按券商实收修改；卖出盈亏按当前成本价计算。是否联动参考现金逐笔选择。" : "基金申赎费优先以实际扣费为准。可按基金合同配置费率与赎回批次策略；估算不等于销售平台最终扣费，交易不会连接销售平台。")
                    .font(.footnote).foregroundStyle(s.ink2).fixedSize(horizontal: false, vertical: true)
            }
            .scrollContentBackground(.hidden)
            .themedSheetBackground()
            .themedFormBackground(s)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { confirmBar }
            .navigationTitle("记一笔交易")
            .keyboardDoneToolbar()
            .onChange(of: quantity) { _, _ in clearFundFeeEstimate() }
            .onChange(of: tradeDate) { _, _ in clearFundFeeEstimate() }
            .onChange(of: side) { _, _ in clearFundFeeEstimate() }
            .onAppear {
                linkCash = holding.kind == .etf && store.data.cashLinkedByDefault
                fee = holding.kind == .etf ? "0.10" : "0"
                settlementDate = tradeDate
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }
    /// 固定底部确认区：键盘弹起时随 safeArea 上移，不会被 Form 滚走。
    private var confirmBar: some View {
        Button {
            save()
        } label: {
            Text("入账")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: AppLayout.minimumTapHeight)
                .background(s.accent, in: RoundedRectangle(cornerRadius: layout.radius, style: .continuous))
                .foregroundStyle(s.onAccent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("入账这笔交易")
        .themedConfirmBar(s)
    }

    private func save() {
        guard let q = Double(quantity), let p = Double(price), let f = Double(fee) else { error = "请输入有效数字"; return }
        do { try store.recordTrade(code: holding.code, kind: holding.kind, side: side, quantity: q, price: p,
            fee: f, linkedCash: linkCash, date: tradeDate,
            settlementDate: holding.kind == .fund ? settlementDate : nil,
            fundRedemptionLots: estimatedQuantity == quantity && estimatedTradeDay == dayKey(tradeDate) ? estimatedRedemptionLots : nil,
            fundFeeWasEstimated: holding.kind == .fund && side == .sell
                && estimatedFeeValue.map { abs($0 - f) <= 0.005 } == true); dismiss() }
        catch { self.error = error.localizedDescription }
    }

    private func estimateFundFee() {
        guard let shares = Double(quantity), let nav = Double(price), shares > 0, nav > 0 else {
            feeEstimateText = "先填写有效赎回份额和净值。"; return
        }
        guard let estimate = store.estimateFundRedemptionFee(code: holding.code, shares: shares, nav: nav, on: tradeDate) else {
            feeEstimateText = "无法可靠估算：请先录入完整持有批次，并按基金合同设置全部适用费率档。"; return
        }
        fee = String(format: "%.2f", estimate.total)
        estimatedFeeValue = estimate.total
        estimatedRedemptionLots = estimate.redemptionLots
        estimatedQuantity = quantity
        estimatedTradeDay = dayKey(tradeDate)
        let detail = estimate.parts.map { String(format: "%@买入 · %d天 %.2f份 × %.3f%%", $0.purchaseDate, $0.days, $0.shares, $0.ratePercent) }.joined(separator: "；")
        feeEstimateText = "批次估算 \((estimate.total).cny())：\(detail)。请与实际扣费核对后再入账。"
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func clearFundFeeEstimate() {
        estimatedRedemptionLots = nil
        estimatedFeeValue = nil
        estimatedQuantity = ""
        estimatedTradeDay = ""
    }
}

