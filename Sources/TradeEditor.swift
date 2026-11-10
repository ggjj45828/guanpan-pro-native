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
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(holding.name) {
                    Picker("方向", selection: $side) { Text("买入").tag(LedgerEntry.Side.buy); Text("卖出").tag(LedgerEntry.Side.sell) }.pickerStyle(.segmented)
                    TextField("份额", text: $quantity).keyboardType(.decimalPad)
                    TextField("成交价", text: $price).keyboardType(.decimalPad)
                    TextField("手续费", text: $fee).keyboardType(.decimalPad)
                    DatePicker("成交日期", selection: $tradeDate, displayedComponents: .date)
                    Toggle("联动本程序现金", isOn: $linkCash)
                }
                if !error.isEmpty { Text(error).foregroundStyle(s.danger) }
                Text("ETF 手续费默认按每笔 0.10 元填写，可按券商实收修改；卖出盈亏按当前成本价计算。是否联动参考现金逐笔选择。")
                    .font(.footnote).foregroundStyle(s.ink2).fixedSize(horizontal: false, vertical: true)
            }
            .scrollContentBackground(.hidden)
            .themedSheetBackground()
            .themedFormBackground(s)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { confirmBar }
            .navigationTitle("记一笔交易")
            .keyboardDoneToolbar()
            .onAppear {
                linkCash = store.data.cashLinkedByDefault
                fee = "0.10"
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
        do { try store.recordTrade(code: holding.code, kind: .etf, side: side, quantity: q, price: p,
            fee: f, linkedCash: linkCash, date: tradeDate,
            settlementDate: nil,
            fundRedemptionLots: nil,
            fundFeeWasEstimated: false); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
